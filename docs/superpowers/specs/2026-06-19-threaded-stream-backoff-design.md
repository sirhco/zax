# Design — threaded streamPull chunk(0) backoff + idle cap

**Status:** approved 2026-06-19. Branch `feat/threaded-stream-backoff` (off main `173083e`).

## Problem

On the THREADED backend, a pull-streamed response (`Response.streamPull` / `Response.ssePull`)
whose producer returns `chunk(0)` (not-ready — e.g. a sparse SSE stream) **busy-loops**:

```zig
// src/server.zig:783
.chunk => |n| {
    if (n == 0) continue; // empty chunk: call next again (busy-loop unchanged on threaded)
```

The `continue` re-calls `ps.next()` immediately with no wait, pinning a CPU core (the
thread-per-connection model means one wedged stream spins one whole worker thread). The
evented backend already solved this in v0.3.0/v0.6.0 with a timer-wheel re-poll
(`stream_repoll_ms`) plus a whole-stream idle cap (`stream_idle_timeout_ms`); the threaded
path was never updated.

## Goal

Replace the threaded busy-loop with a backoff sleep between re-polls, and add the same
whole-stream idle cap the evented backend has — achieving full cross-backend parity (same
knob names, same semantics, same hard-close-truncate behavior).

Non-goals: changing the evented path; changing non-streamed or push-streamed responses;
push-chunked threaded e2e coverage (separate item).

### Decisions (confirmed with Chris)
- **`stream_repoll_ms` default 5** — mirror `EventedOptions.stream_repoll_ms`. Fixes the
  busy-loop out of the box (5ms sleep between repolls). `0` = legacy busy-loop (opt-out).
  This is a behavior change, strictly better (no CPU spin).
- **`stream_idle_timeout_ms` default 0 (off)** — mirror `EventedOptions.stream_idle_timeout_ms`.
  On cap, **hard-close truncate**: stop and close the connection WITHOUT writing the chunked
  terminator, so the client detects the incomplete stream — identical to the evented idle cap.

## Key facts (threaded path)

- The busy-loop lives in `writeResponse` (`src/server.zig:775-797`), the pull branch.
- `writeResponse(w, resp, chunked) bool` currently has NO `io` parameter. `io: Io` is in
  scope at the one streaming caller (`handleConn`, `src/server.zig:682`) and at the
  `terminalResponse` error callers.
- Sleep primitive: `Io.sleep(io, Io.Duration.fromMilliseconds(ms), .awake)` (used elsewhere
  in the file, e.g. `:1697`).
- Monotonic time: `nowNs(io) i96` (`src/server.zig:863`) — already used for trace-latency;
  reuse it for the idle clock (no new helper, no import of the reactor's `monotonicNow`).
- A `writeResponse` return of `false` means "caller closes the connection" (the caller is
  `if (!writeResponse(...)) break;`). Returning `false` on idle-cap IS the truncate close —
  no terminator written, connection dropped.

## Components

### Modified: `src/server.zig` `Options` (~:126)

Add two fields mirroring `EventedOptions`:
```zig
/// Sleep (ms) between re-polls of a not-ready (`chunk(0)`) pull-stream producer
/// on the threaded backend; 0 = legacy busy-loop.
stream_repoll_ms: u32 = 5,
/// Whole-stream idle cap (ms): close a threaded pull stream that has produced no
/// data for this long; 0 = disabled. Hard-close (truncate, no chunked terminator).
stream_idle_timeout_ms: u32 = 0,
```

### Modified: `src/server.zig` `writeResponse` (~:775)

New signature: `fn writeResponse(w: *Io.Writer, resp: Response, chunked: bool, io: Io, repoll_ms: u32, idle_ms: u32) bool`.

Pull branch logic:
```zig
if (resp.pull_streamer) |ps| {
    resp.writeHead(w, chunked) catch return false;
    var chunk_buf: [4096]u8 = undefined;
    var last_produce: i96 = nowNs(io); // idle window starts at stream start
    while (true) {
        switch (ps.next(&chunk_buf)) {
            .chunk => |n| {
                if (n == 0) {
                    // Whole-stream idle cap: no data for too long → hard close (truncate).
                    if (idle_ms != 0 and nowNs(io) - last_produce > @as(i96, idle_ms) * 1_000_000)
                        return false; // caller closes; NO terminator
                    if (repoll_ms != 0)
                        Io.sleep(io, Io.Duration.fromMilliseconds(repoll_ms), .awake) catch {};
                    continue;
                }
                last_produce = nowNs(io); // real data resets the idle window
                if (chunked) {
                    chunked_mod.writeChunk(w, chunk_buf[0..n]) catch return false;
                } else {
                    w.writeAll(chunk_buf[0..n]) catch return false;
                }
            },
            .done => break,
            .err => return false,
        }
    }
    if (chunked) chunked_mod.writeTerminator(w) catch return false;
    w.flush() catch return false;
    return true;
}
```
The push-stream and buffered branches are unchanged (the new `io`/`repoll_ms`/`idle_ms`
params are simply unused there).

### Modified: `src/server.zig` callers

- Streaming caller (`handleConn`, ~:682):
  `if (!writeResponse(w, resp, chunked, io, self.opts.stream_repoll_ms, self.opts.stream_idle_timeout_ms)) break;`
- `terminalResponse` (~:982) gains an `io: Io` parameter and passes `io, 0, 0` to each of its
  `writeResponse(w, Response.fromStatus(...), false, ...)` calls (error responses are never
  pull-streamed, so the repoll/idle args are unused). Update `terminalResponse`'s call sites
  in `handleConn` (the `readHead`/`readBody` catch blocks) to pass `io`.

## Data flow (threaded pull, backoff + cap)

```
writeResponse pull branch → last_produce = nowNs(io)
  → next(buf)
       .chunk(n>0) → last_produce = nowNs(io); writeChunk/writeAll
       .chunk(0)   → if idle_ms && nowNs-last_produce > cap → return false (truncate close)
                     else if repoll_ms → Io.sleep(repoll_ms); continue
       .done       → writeTerminator (chunked) → flush → keep-alive (return true)
```

## Error handling

- Idle cap hit → `return false` → caller closes the connection; no terminator (truncate).
- `repoll_ms == 0` → no sleep (legacy busy-loop opt-out).
- Producer `.err` / write failures → `return false` (unchanged).

## Behavior change & test impact

- Default `stream_repoll_ms = 5`: a threaded `chunk(0)` producer now sleeps 5ms between
  re-polls instead of spinning — no CPU burn, output identical. Producers that always have
  data ready (`chunk(n>0)`) never hit the sleep → zero overhead for the common case.
- `stream_idle_timeout_ms = 0` by default → no idle cap unless set.
- No change to non-streamed, push-streamed, or evented responses.

## Testing

Threaded e2e (`src/server.zig`, loopback, mirror existing streaming tests):
1. **Backoff produces correct stream:** a `streamPull` producer that returns `chunk(0)` a few
   times, then real chunks, then `.done` → client receives the full correct body (proves the
   sleep path doesn't drop/duplicate data and the stream completes). With `stream_repoll_ms`
   set small (e.g. 1ms) so the test is fast.
2. **Idle cap truncates:** a producer that returns `chunk(0)` forever, `stream_idle_timeout_ms`
   small → the connection closes and the response body does NOT contain the chunked terminator
   `0\r\n\r\n` (truncated), mirroring the evented idle-cap test.
3. **repoll_ms == 0 legacy:** (optional, to lock the opt-out) a producer returning `chunk(0)`
   then immediately data with `stream_repoll_ms = 0` still completes correctly (no sleep path).

## Verification

- `zig build test --summary all` — baseline 251/254 mac (3 Linux-epoll skips); after this
  feature, baseline + new tests, 0 failures.
- Manual: a threaded `streamPull` SSE endpoint with a sparse producer no longer pins a CPU
  core while idle (observe via `top`); a stuck producer with `stream_idle_timeout_ms` set
  closes after the cap.

## Docs

- `docs/evented-backend.md` (or the streaming docs): note the threaded backend now also
  backs off (`Options.stream_repoll_ms`, default 5ms) instead of busy-looping on a not-ready
  pull producer, and supports the same `Options.stream_idle_timeout_ms` idle cap — full parity
  with the evented backend.
- `CHANGELOG.md`: entry under `[Unreleased]`.
