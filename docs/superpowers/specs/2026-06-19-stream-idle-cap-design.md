# Design — whole-stream idle cap for evented pull streams (streaming gap #3)

**Status:** approved 2026-06-19. Branch `feat/stream-idle-cap` (off main).

## Problem

The evented reactor supports true pull-streaming (`Response.streamPull` /
`Response.ssePull`). When a pull producer returns `chunk(0)` (not-ready — e.g. a
sparse SSE stream with no event to send yet), the connection **parks** on the
timer wheel and re-polls every `stream_repoll_ms` (default 5ms). This sparse-SSE
readiness park shipped in v0.3.0.

The park has **no absolute lifetime / idle cap**: a producer that returns
`chunk(0)` *forever* re-polls indefinitely, so a stuck or dead-slow producer
pins a worker slot + fd permanently. This was explicitly deferred from the
Item-1 sparse-SSE park review.

Gap #3 of the streaming follow-ups: add a knob that closes a stream which has
produced **no data** for N ms.

## Goal

Add an **opt-in** `stream_idle_timeout_ms` knob. While a pull stream is parked
re-polling a not-ready producer, if no real chunk (n>0) has been produced for
more than the configured window, **hard-close** the connection. Evented backend
only.

Non-goals: the threaded `streamPull` `chunk(0)` busy-loop (separate gap);
inbound chunked request bodies (separate gap, 411); a per-chunk write-stall cap
(already covered by the existing `read_timeout_ms`-based write deadline);
graceful end-of-stream on cap (we truncate — see below).

## Decisions

- **Default `stream_idle_timeout_ms = 0` (disabled / opt-in).** Mirrors
  `stream_repoll_ms`'s 0=legacy convention. Zero behavior change unless set.
- **Evented backend only.** Matches the gap location (the reactor park path).
- **Hard close (truncate) on cap.** Close the socket WITHOUT writing the final
  `0\r\n\r\n` chunked terminator, so the client sees a truncated/incomplete
  chunked body — the correct failure signal. A graceful terminator would falsely
  signal a clean end-of-stream from a stuck producer.

## Key constraint & resolution: single deadline per conn

Each `Conn` has exactly **one** deadline slot, `deadline_ns: i96`
(`src/reactor/conn.zig:212`). The repoll park already uses it
(`deadline_ns = monotonicNow() + stream_repoll_ms * 1_000_000`). An idle cap is
a *second* timeout, but we do **not** add a second timer — that would require
refactoring the single-deadline model the reactor relies on.

**Insight:** the `chunk(0)` branch in `step()` runs on *every* repoll cycle:

- `stream_repoll_ms > 0` — timer fires → `onDeadline(.streaming)` → `.want_write`
  → worker re-drives `step()` → `w_len == 0` → `next()` → `chunk(0)` again.
- `stream_repoll_ms == 0` (busy-spin escape hatch) — `step()` loops on `chunk(0)`
  via `.want_write`.

So we track `last_produce_ns` (monotonic stamp of the last real chunk, also set
at stream start) and evaluate the absolute idle budget **at the `chunk(0)`
decision point** in `step()`. This covers both repoll modes uniformly, with no
new timer infrastructure. Check granularity ≈ `stream_repoll_ms` (5ms) ≪ idle
cap (seconds) — fine.

## Components (purely additive, minimal blast radius)

### Modified: `src/reactor/conn.zig`

New `Conn` fields (after `stream_repoll_ms`, ~:204):

```zig
/// Whole-stream idle cap (ms): close a pull stream that has produced no data
/// for this long. 0 disables (default — no cap, legacy behavior).
stream_idle_timeout_ms: u32 = 0,
/// Monotonic stamp (ns) of the last real chunk produced; also set at stream
/// start. Used only to evaluate `stream_idle_timeout_ms`.
last_produce_ns: i96 = 0,
```

- **Stream start** (where `pull_streamer` is assigned, ~:517): `last_produce_ns =
  monotonicNow()` so the idle window is measured from stream start.
- **Both `chunk(0)` sites** (~:571 and ~:630), before re-parking: if
  `stream_idle_timeout_ms != 0` and
  `(now - last_produce_ns) > @as(i96, stream_idle_timeout_ms) * 1_000_000` →
  hard close:
  ```zig
  self.pull_streamer = null;
  self.state = .closing;
  return .done_close;   // NO loadChunkedTerminator → truncated body
  ```
  Reuse the single `monotonicNow()` read already taken for the repoll deadline.
- **Real-chunk path** (the `n > 0` branches at both sites): `self.last_produce_ns
  = now;` to reset the idle window whenever data flows.

### Modified: `src/reactor/worker.zig`

- `WorkerOpts` (after `stream_repoll_ms`, ~:76): `stream_idle_timeout_ms: u32 = 0,`
- `applyConnConfig` (~:790): `conn.stream_idle_timeout_ms = opts.stream_idle_timeout_ms;`

### Modified: `src/server.zig`

- `EventedOptions` (after `stream_repoll_ms`, :178): `stream_idle_timeout_ms: u32 = 0,`
  with a doc comment.
- `serveEvented` `worker_opts` build (~:518): `.stream_idle_timeout_ms = opts.stream_idle_timeout_ms,`

## Data flow (evented pull, idle cap armed)

```
dispatch → pull_streamer set → last_produce_ns = now
  → pump: next(buf)
       .chunk(n>0) → last_produce_ns = now → frame/write → continue
       .chunk(0)   → if (now - last_produce_ns) > cap → hard close (truncate)
                     else park (timer, stream_repoll_ms), re-poll
       .done       → terminator (chunked) / close — unchanged
```

## Error handling

- Cap hit → `.done_close`, no terminator. The truncated chunked body is the
  honest failure signal (same spirit as the producer `.err` path).
- Disabled (`stream_idle_timeout_ms == 0`) → the `!= 0` guard short-circuits
  before any clock math; the park behaves exactly as today.

## Behavior change & test impact

- No change to any existing flow when the knob is unset (default 0). Existing
  sparse-SSE park tests re-poll indefinitely as today → **unaffected**.
- New behavior only when a user sets `stream_idle_timeout_ms > 0`.

## Testing

Unit (`src/reactor/conn.zig`, fake transport, runs on mac):

1. **Cap fires:** producer returns `chunk(0)` forever, `stream_idle_timeout_ms`
   small → after the window elapses, the `chunk(0)` step returns `.done_close`,
   conn → `.closing`, and **no** `0\r\n\r\n` terminator is written.
2. **Window resets:** producer yields a real chunk (n>0) before the cap → window
   resets (`last_produce_ns` advances), stream continues past the original
   deadline.
3. **Disabled (legacy):** `stream_idle_timeout_ms == 0` → `chunk(0)` forever
   never caps (re-polls / parks as today).
4. **Busy-spin mode:** `stream_repoll_ms == 0` + `stream_idle_timeout_ms` set →
   the busy-spin `chunk(0)` path also closes after the window.

Config propagation: `EventedOptions.stream_idle_timeout_ms` → `WorkerOpts` →
`applyConnConfig` reaches the conn.

## Verification

- `zig build test --summary all` — baseline 230/233 mac (3 Linux-epoll skips);
  after this feature, baseline + new tests, 0 failures.
- Regression: with `stream_idle_timeout_ms == 0`, sparse-SSE park behaves
  exactly as today.
- Zero overhead when disabled (the `!= 0` guard short-circuits).

## Docs

- `docs/evented-backend.md`: document the knob (semantics, default, hard-close
  behavior, interaction with `stream_repoll_ms`).
- `CHANGELOG.md`: entry under `[Unreleased]`.
