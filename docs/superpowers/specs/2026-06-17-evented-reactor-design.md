# Design spec — evented reactor backend for zax (Linux epoll, v1)

## Context

Benchmarking (see `2026-06-17-latency-stall-findings.md`, `benchmarks/cross/results.md`)
proved zax's request hot path is excellent — **best p50 of zax/axum/go/httpz (0.054ms)** —
but its `std.Io.Threaded` thread-per-connection backend is the ceiling: core-pinned on Linux,
zax does ~115k req/s with p99.9 ~53ms, while **httpz (Zig, evented epoll) hits ~400k req/s
with p99.9 ~0.40ms on the identical box** (axum/tokio matches it). The gap is the concurrency
model, not Zig, the kernel, or the request code. `std.Io.Evented` would be the clean fix but
its TCP ops are unimplemented upstream on Linux/macOS (`2026-06-17-evented-io-decision.md`), and
a patched std means a custom toolchain we won't maintain.

**This spec:** add zax's own evented backend — a non-blocking epoll reactor living in zax,
built on stock Zig — as an **opt-in, additive** alternative to the threaded backend. Goal:
close the throughput + tail gap to httpz/axum while keeping zax's lean request path (so an
evented zax can plausibly be the *fastest* of the four: best median + evented throughput).

## Decisions (confirmed in brainstorming)

1. **Bespoke reactor, reuse the rest.** Replace only the socket IO + keep-alive loop with a
   non-blocking epoll-driven state machine. **Reuse unchanged:** `parser.zig`, the radix
   router, `response.zig` serialization, `dispatch` (middleware + handler), all handlers,
   extractors, observers, `request_id`. NOT an `std.Io` VTable impl (that needs fibers — the
   hard part we're avoiding).
2. **Linux epoll first**, behind a thin poller interface with a `kqueue` slot for later.
   `Io.Threaded` (`app.serve`) stays the default and the only path on non-Linux.
3. **N shared-nothing workers + `SO_REUSEPORT`** (httpz/nginx model), default N = ncpu.
4. **v1 buffered responses only; true streaming stays on the threaded backend** (capped
   buffer for streamed responses on the evented path).

## Architecture

```
app.serveEvented(addr, .{ .workers = 0 })   // 0 = ncpu; Linux-only
        │
        ├── spawn worker[0..N]  (OS threads, shared-nothing)
        │      each worker owns:
        │        - listen socket  (SO_REUSEPORT, same addr)   → kernel balances accepts
        │        - epoll instance
        │        - its connections + read/write buffers + per-conn arena (reused)
        │        - a coarse timer wheel (deadlines)
        │
        └── per connection: a non-blocking STATE MACHINE (transport-abstracted)
              ReadingHead → ReadingBody → Dispatching → Writing
                          → (KeepAliveIdle → ReadingHead | Close)
```

### Components & boundaries

- **`src/reactor/poller.zig`** — interface: `add(fd, events)`, `mod(fd, events)`, `del(fd)`,
  `wait(timeout) -> []Event`. Implemented now by `epoll.zig`; `kqueue.zig` is a later slot.
  *Depends on:* OS syscalls. *Used by:* the worker loop.
- **`src/reactor/conn.zig`** — the per-connection **state machine**, the heart of v1. Pure
  logic over a **transport interface** (`read(buf) -> n | error.WouldBlock | error.Closed`,
  `write(buf) -> n | error.WouldBlock | error.Closed`) — NOT a raw fd. Owns the connection's
  state enum, read/write buffer cursors, arena, deadline. Calls the reused
  `parser.parseHead` / `dispatch` / `response.write`. *Depends on:* parser, router, response,
  dispatch — all existing, Io-agnostic. *Used by:* the worker, driven by epoll readiness.
- **`src/reactor/worker.zig`** — owns the listen socket, epoll, connection set, timer wheel;
  the accept + event loop; drives each ready connection's state machine one step; sweeps
  expired deadlines. *Depends on:* poller, conn, timer wheel.
- **`src/reactor/timer.zig`** — per-worker coarse timer wheel (~1s buckets, O(1)
  insert/expire) for read/idle deadlines.
- **`src/server.zig`** — add `pub fn serveEvented(self, addr, opts) !void` on `App` (Linux
  only; `error.EventedUnsupported` elsewhere). Existing `serve(io, addr)` untouched.

### Connection state machine (v1 core)

States and transitions (each step is non-blocking; on `WouldBlock` the connection yields
back to epoll, re-armed for the needed readiness):

- **ReadingHead** — on readable: `recv` into read buffer; feed accumulated bytes to
  `parser.parseHead` (zero-copy, reused). `error.Incomplete` → stay, wait for more. Complete
  → set read deadline; reject chunked (`411`, reused); → ReadingBody.
- **ReadingBody** — read until `head_len + content_length` buffered (reuse `max_body_size`
  validation; `413` on exceed) → Dispatching.
- **Dispatching** — call the existing `dispatch(req, arena, rid)` (router + middleware +
  handler, all reused) → a `Response`. Fire the observer hook (reused). If `resp.streamer`
  (streamed): buffer it up to the write-buffer cap; over cap → `500` + close. Serialize the
  `Response` into the write buffer via `response.write` (reused) → Writing.
- **Writing** — non-blocking `send` from `write_buf[offset..]`; partial/`WouldBlock` → store
  offset, arm `EPOLLOUT`, resume here on writable. Fully sent → decide keep-alive (reuse
  `keep_alive` + `max_keep_alive_requests` + request persistence).
- **KeepAliveIdle** — set idle deadline; `compact()` leftover pipelined bytes; if buffered
  data remains, immediately → ReadingHead (pipelining); else wait for readable.
- **Close** — on error/timeout/non-persistent: shutdown, `del` from epoll, free slot.

### Timeouts
Reuse `read_timeout_ms` / `idle_timeout_ms`. Per-worker coarse timer wheel; each connection's
deadline updated on state entry. `epoll_wait` timeout = time to next tick. On wake, expire the
due bucket: read-deadline → `408` + close; idle-deadline → silent close.

### Threading & memory
N workers, shared-nothing (no locks, no cross-worker state). Each worker pre-allocates its
connection slots + read/write buffers + per-conn arenas, reused across connections (mirrors
today's per-connection arena `reset(.retain_capacity)`). Worker count via
`opts.workers` (0 = ncpu).

**Shutdown:** each worker registers an `eventfd` (or self-pipe) in its epoll so a blocked
`epoll_wait` can be woken. `App.requestShutdown` sets the shared `shutting_down` flag, closes
the listen sockets, and signals every worker's eventfd; each worker stops accepting, drains
in-flight connections, then exits. `serveEvented` blocks running the workers and returns once
all have drained (mirrors `serve`/`acceptLoop`'s lifecycle, so tests can spawn-then-shutdown
exactly like the existing threaded tests).

### Error handling & limits
Per-worker `opts.max_connections` (accept + immediate close, or stop arming, at the cap).
RST/`EPIPE`/read-0 → Close. Malformed → existing error responses. fd-exhaustion → log + shed,
worker survives. Accept loop drains via `EPOLLIN` on the listen socket (edge- or
level-triggered — level-triggered for v1 simplicity).

## API

```zig
// Linux only; additive. Existing serve(io, addr) unchanged and still default.
pub const EventedOptions = struct {
    workers: usize = 0,          // 0 = ncpu
    max_connections: usize = 0,  // per worker; 0 = unbounded
    // read/write buffer sizes, keep_alive, timeouts, max_body_size, request_id, etc.
    // continue to come from the App's existing Options.
};
pub fn serveEvented(self: *App, addr: net.IpAddress, opts: EventedOptions) !void;
```

## Testing

- **Unit (runs in the normal `zig build test`, any platform incl. macOS):** drive
  `conn.zig`'s state machine with a **fake in-memory transport** — scripted partial reads,
  pipelined requests, `WouldBlock` on write (backpressure), keep-alive cycles, oversized
  body, malformed head, deadline expiry. Assert state transitions + exact output bytes. The
  state machine is poller-/fd-free, so all the hard logic is testable off-Linux.
- **Integration (Docker/Linux):** real epoll reactor over loopback — keep-alive, pipelining,
  write backpressure (slow reader), timeouts, `max_connections`.
- **Perf (Docker cross-bench):** add an evented zax variant; compare vs httpz/axum/go,
  targeting httpz-class throughput/tail while keeping zax's best-in-class p50.

## Evented backend status (updated after v2)

Most original v1 limitations have since been resolved. Current state:

**Resolved in v2:**
- **macOS / BSD support** — the reactor is no longer Linux-only. A `kqueue` backend
  (`src/reactor/kqueue.zig`) runs the evented reactor natively on macOS and the BSDs;
  `poller.zig` selects `epoll` (Linux) vs `kqueue` (Darwin/BSD) by `builtin.os.tag`. The
  reactor's integration tests run natively in `zig build test` on macOS.
- **`request_id` on the evented path** — `Options.request_id` now works under `serveEvented`
  (validated/generated rid, `x-request-id` response header, observer `AccessRecord`), sharing
  the threaded backend's `computeRid`.
- **Write-stall deadline** — a peer that stalls mid-write is now reaped after `read_timeout_ms`
  (the `writing` state arms a deadline; `onDeadline` closes it). Peer close/RST was already caught.
- **True streaming** — `Response.streamPull()` + `PullStreamer` stream a body in bounded
  chunks without buffering the whole thing (connection-close framing), backpressure-aware, on
  both backends. (The legacy push `Response.streamer` on the evented path still buffers up to
  the write buffer / 500-on-overflow; prefer `streamPull` for large/unbounded bodies.)

**Remaining limitations (by design):**
1. **Handlers must not use `ctx.io` for blocking IO.** A handler that does blocking IO (e.g.
   the `Files` extractor) stalls the whole worker event loop — no accepts, timers, or other
   connections progress. Use sync/compute-only extractors (Path, Query, Json, State, …) under
   `serveEvented`. (Same constraint every single-threaded reactor has.)
2. **`PullStreamer` is produce-on-demand.** `nextFn` should return `chunk>0` (data ready) or
   `done`. A producer that returns `chunk=0` ("nothing yet, retry") busy-polls — fine for
   files/generators, but **sparse/long-idle SSE** (waiting on external events) is a v2 item
   (needs a producer-driven readiness signal). The provided SSE helper produces on demand.
3. **No keep-alive on streamed responses.** Streaming uses connection-close framing (no chunked
   transfer-encoding), matching the existing push-streamer model — a streamed connection closes
   after the body.
4. **Worst-case `max` under cloud-VM overcommit.** Shared-nothing workers don't work-steal, so
   a hypervisor-stolen worker's connections wait (tokio migrates them). p99.9 stays best-in-class;
   only the rare `max` is affected, and only on overcommitted VMs (not dedicated hosts).

Backend default: **`serve` (threaded) remains the default and portable path; `serveEvented` is
opt-in** (Linux + macOS/BSD). See `docs/evented-backend.md`.

## Out of scope (v1)
kqueue/macOS-native reactor, true (unbuffered) streaming on evented, TLS, HTTP/2. The
threaded backend remains for non-Linux, streaming, and as the portable default. Phasing keeps
v1 to: Linux epoll, N-worker `SO_REUSEPORT`, buffered HTTP/1.1 keep-alive + pipelining,
timeouts, full reuse of router/extractors/middleware/observers.

## Success criteria
1. `serveEvented` on Linux serves the cross-bench's 3 routes correctly (parity with `serve`).
2. State-machine unit tests pass in `zig build test` on macOS (no epoll) — baseline grows
   from 155.
3. Docker cross-bench: evented zax materially closes the throughput + p99.9 gap toward
   httpz/axum (target: multi-hundred-k req/s, sub-few-ms p99.9), p50 stays best-in-class.
4. Threaded backend + all existing tests unchanged (purely additive).
