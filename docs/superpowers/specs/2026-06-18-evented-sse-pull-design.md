# Design — pull-model SSE helper (`ssePull`)

**Status:** approved 2026-06-18. Branch `feat/evented-sse-pull` (off main).

## Problem

zax has two streaming models:
- **push** (`Response.stream` / `Response.sse`): the handler writes events imperatively to a
  blocking `*Writer`. Works on the threaded backend only — the evented reactor is non-blocking and
  cannot hand the handler a blocking writer.
- **pull** (`Response.streamPull`): the driver calls `nextFn(*Ctx, buf) -> PullResult` repeatedly.
  Works on **both** backends (the evented reactor parks a not-ready producer on its timer wheel since
  v0.3.0; the threaded driver loops).

Consequently the **`sse()` helper is threaded-only**. To emit Server-Sent Events on the evented
backend today, a user must hand-roll SSE framing inside a raw `streamPull` producer. This is the
remaining streaming gap after v0.3.0 (item #2 of the streaming follow-ups).

## Goal

A first-class, **pull-model** SSE helper that works on both backends, reusing the existing,
unit-tested SSE wire formatter (`src/http/sse.zig: formatEvent` / `formatComment`) and the existing
`streamPull` path. Purely additive: no change to `sse()`, `stream`, `streamPull`, or the reactor.

Non-goals: HTTP chunked transfer-encoding / keep-alive-after-stream (all streaming stays
connection-close framing); a whole-stream idle cap; making the *push* `sse()` run on evented.

## API

New, in `src/http/response.zig`:

```zig
/// One step of a pull-model SSE producer.
pub const SsePull = union(enum) {
    event: sse_mod.Event,    // a full SSE event (event/data/id/retry) — framed via formatEvent
    comment: []const u8,     // an SSE comment line (": text") — keepalive heartbeat, via formatComment
    not_ready,               // no event available yet → emits a 0-byte chunk
    done,                    // end of stream
};

/// Build a pull-model SSE (`text/event-stream`) response. `nextFn` is called repeatedly; zax
/// frames each returned event/comment into the driver's write buffer. Connection-close framing.
/// Works on both backends. `context` must outlive the request (use the request arena).
pub fn ssePull(
    comptime Ctx: type,
    context: *Ctx,
    comptime nextFn: fn (*Ctx) SsePull,
) Response
```

The returned `Response` has `content_type = "text/event-stream"`, `keep_alive = false`, and a
`pull_streamer` whose erased `nextFn(buf)` bridges to the user `nextFn`:

| user `nextFn(ctx)` returns | erased `nextFn(buf)` does | `PullResult` |
|----------------------------|---------------------------|--------------|
| `.event = e`   | `var w = Writer.fixed(buf); formatEvent(&w, e)` | `.chunk = w.buffered().len` (bytes written) |
| `.comment = t` | `formatComment(&w, t)` | `.chunk = w.end` |
| `.not_ready`   | — | `.chunk = 0` |
| `.done`        | — | `.done` |
| framing overflows `buf` | `formatEvent`/`formatComment` returns `error.WriteFailed` | `.err` |

This mirrors the existing `streamPull` `Erased.call` closure pattern exactly; the only new logic is
the `SsePull → PullResult` switch + the `Writer.fixed` framing.

## Behavior / semantics

- **Framing:** reuses `sse.formatEvent` (event/id/retry lines + one `data:` line per `\n`-split line
  + blank terminator) and `sse.formatComment`. Zero new allocation — frames into the buffer the
  driver already owns.
- **`not_ready`:** emits a 0-byte chunk. On the **evented** backend this parks the connection on the
  timer wheel and re-polls after `EventedOptions.stream_repoll_ms` (the v0.3.0 sparse-SSE fix) — no
  busy-spin. On the **threaded** backend the pull driver loops on a 0-byte chunk (busy-spins), so for
  sparse/long-idle SSE on threaded, prefer the existing push `sse()` (the handler blocks naturally
  between events). This is the documented contract: `ssePull` is the evented-native SSE path.
- **Oversize event:** if a single framed event/comment exceeds the driver write buffer (4 KB on the
  threaded driver's fixed chunk buffer; `write_buffer_size`, default 8 KB, on evented), framing
  returns `.err` and the connection closes. Documented as the max event size. SSE events are
  typically small; multi-chunk carry-over is intentionally out of scope for v1.
- **Framing:** connection-close (`keep_alive = false`), consistent with `sse()`/`stream`/`streamPull`.

## Components / boundaries

- `src/http/sse.zig` — unchanged. `formatEvent`/`formatComment`/`Event` are already `pub` and
  unit-tested; `ssePull` reuses them.
- `src/http/response.zig` — adds the `SsePull` union and the `ssePull` function. The new code is a
  pure function of (user `nextFn` result, buffer) → `PullResult`; testable without a socket.
- `src/reactor/conn.zig` — **no code change**; `ssePull` produces a `pull_streamer`, which the
  reactor already drives (including the v0.3.0 `chunk(0)` park). Add an integration test only.
- `src/server.zig` — no change; the threaded `writeResponse` pull loop already drives `pull_streamer`.

## Testing

Unit (`src/http/response.zig` test block):
1. `ssePull` builds a `Response` with `pull_streamer != null`, `content_type == "text/event-stream"`,
   `keep_alive == false`, empty body.
2. Wrapped producer framing: an `.event` yields exactly the bytes `formatEvent` would (compare against
   a `formatEvent`-into-fixed-buffer reference); `.comment` yields the `": text\n"` form.
3. `.not_ready` → `PullResult{ .chunk = 0 }`; `.done` → `PullResult.done`.
4. Oversize: an event larger than the supplied buffer → `PullResult.err`.

Reactor integration (`src/reactor/conn.zig` test block, fake transport — reuse the Item 1 / pull
patterns):
5. Drive an `ssePull` producer that yields one event, then `not_ready`, then a second event, then
   `done`: assert the head is `text/event-stream` + `connection: close`, both events appear correctly
   framed in the written bytes, the `not_ready` step returns `.want_stream_repoll` (parks), and the
   stream closes cleanly on `done`.

(Threaded driving is already covered by the existing `streamPull` tests; no separate threaded test
needed beyond the unit framing tests.)

## Verification

- `zig build test --summary all` — baseline 213/216 mac (3 Linux-epoll skips); after this feature:
  baseline + new tests, 0 failures, on mac (kqueue) and Linux (epoll, via Docker).
- Manual: an evented server with an `ssePull` handler emitting an event/second; `curl -N` shows events
  arriving in real time; CPU idle between events (no busy-spin).

## Docs

- `docs/evented-backend.md`: in the Streaming section, add `ssePull` as the evented-native SSE path
  with a short example; keep the note that push `sse()` is threaded-only.
- `CHANGELOG.md`: add an entry under the next unreleased version.
