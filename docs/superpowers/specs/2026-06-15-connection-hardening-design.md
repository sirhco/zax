# Zax — connection hardening (limits + timeouts) design

Date: 2026-06-15
Status: approved, ready for implementation planning
Scope: theme B of the post-v0.1.0 roadmap (robustness/security), bundled into one
spec covering request-size limits and read/idle timeouts. Themes C–F remain out
of scope.

## Context

Zax v0.1.0 has three production-safety holes in the connection read path
(`src/server.zig`):

1. **No request-body size limit, wrong status.** `attachBody` buffers the whole
   body inside the fixed read buffer (`Options.read_buffer_size`, default 16 KiB).
   A body larger than the buffer can never satisfy the fill loop, so `fillMore`
   errors and the request collapses to **400** — there is no explicit limit and
   no `413`.
2. **Header limits map to the wrong status.** `readHead`'s `HeadTooLarge` (buffer
   full) and the parser's `TooManyHeaders` (>64 fields) both surface as **400**;
   they should be **431**.
3. **No timeouts → slowloris/idle DoS.** Reading the head/body via the buffered
   `Io.Reader` (`fillMore` → `recv` with no timeout) blocks a thread-pool task
   indefinitely on a slow or idle client. Keep-alive idle connections likewise
   pin a task until the client disconnects.

Goal: close these holes with configurable body/header limits returning correct
statuses, and read/idle timeouts that bound how long a connection can occupy a
worker.

## Decisions (from brainstorming)

- **One spec** covers both limits and timeouts (they share the read path).
- **Body stays zero-copy**, bounded by the read buffer. `Content-Length` over the
  effective limit is rejected with **413** before the body is read. Large-body
  streaming is explicitly out of scope (theme C).
- **Read path moves from the buffered `Io.Reader` to a manual timed-receive
  loop** using `Socket.receiveTimeout(io, buf, Io.Timeout)`. The parser already
  works on a `[]const u8`, so head/body remain zero-copy slices into a
  connection-owned buffer; compaction (the `toss`/`rebase` equivalent) is done
  manually.
- **Two timeout knobs:** `read_timeout_ms` (one deadline covering a request's full
  head+body, armed when its first byte arrives) and `idle_timeout_ms` (max wait
  for the next request on a keep-alive connection). `0` disables either.

## Verified primitives (Zig 0.16.0)

- `std.Io.net.Socket.receiveTimeout(s: *const Socket, io, buffer: []u8, timeout:
  Io.Timeout) ReceiveTimeoutError!IncomingMessage` — returns `error.Timeout` on
  expiry. `IncomingMessage` reports the byte count received.
- `Io.Timeout = union(enum){ none, duration: Clock.Duration, deadline:
  Clock.Timestamp }`. `Clock.Timestamp.fromNow(io, duration)` builds a deadline;
  a single `.deadline` reused across receives bounds the whole head/body read.
- `Clock.Duration.fromMilliseconds(i64) Duration` and `Clock.Duration.sleep(io)`
  (used in tests to wait past a deadline).
- A `Stream` owns its `Socket` (`stream.socket`), so a connection can read via
  `stream.socket.receiveTimeout` and still write via `stream.writer`.

## Architecture

```
handleConn(stream):
  ConnReader over stream.socket + a connection buffer
  loop (keep-alive):
    fill(idle deadline)  ─ Timeout/EOF ─▶ close
    fill(read deadline) until parseHead ok
        ├ BufferFull ─▶ 431 + close
        └ Timeout    ─▶ 408 + close
    isChunked         ─▶ 411 + close
    Content-Length > limit ─▶ 413 + close
    fill(read deadline) until body present
        ├ BufferFull ─▶ 413 + close
        └ Timeout    ─▶ 408 + close
    dispatch → write response → compact() → repeat
```

Writing (responses) is unchanged (`stream.writer`). `dispatch` is unchanged.

### Component 1 — Options (`src/server.zig`)

```zig
/// Reject a request body whose Content-Length exceeds this. 0 = bounded only by
/// the read buffer. The effective limit is min(max_body_size, read_buffer_size −
/// head length); an over-limit body returns 413.
max_body_size: usize = 0,
/// Deadline (ms) for receiving a request's full head + body once its first byte
/// arrives. Defeats slow-trickle (slowloris). 0 = no timeout.
read_timeout_ms: u32 = 30_000,
/// Max wait (ms) for the next request on a keep-alive connection. 0 = no timeout.
idle_timeout_ms: u32 = 60_000,
```

`0` maps to `Io.Timeout.none` (blocking receive = current behavior), so the
defaults do not affect existing fast tests.

### Component 2 — statuses (`src/http/response.zig`)

Add to `Status` (+ reasons): `request_timeout = 408` ("Request Timeout"),
`payload_too_large = 413` ("Payload Too Large"),
`request_header_fields_too_large = 431` ("Request Header Fields Too Large").

### Component 3 — `ConnReader` (new, in `src/server.zig`)

A small struct owning the connection read buffer and receive cursor:

```zig
const ConnReader = struct {
    socket: net.Socket,
    io: Io,
    buf: []u8,
    start: usize = 0, // first unconsumed byte
    end: usize = 0,   // one past last received byte

    const FillError = error{ Timeout, BufferFull, Closed };

    fn buffered(self: *const ConnReader) []const u8;        // buf[start..end]
    fn fill(self: *ConnReader, timeout: Io.Timeout) FillError!void;
    fn consume(self: *ConnReader, n: usize) void;           // start += n
    fn compact(self: *ConnReader) void;                     // memmove buf[start..end] to front
};
```

- `fill`: if `end == buf.len`, first `compact()`; if still full → `error.BufferFull`.
  Otherwise `receiveTimeout(io, buf[end..], timeout)`; 0 bytes received → `error.Closed`;
  `error.Timeout` propagates; else advance `end`.
- `compact`: `std.mem.copyForwards(u8, buf[0..len], buf[start..end])`, reset
  `start = 0`, `end = len`. Used between requests (pipelining-safe) and when the
  buffer fills mid-read.

### Component 4 — read helpers (`src/server.zig`, replacing the `Io.Reader` versions)

```zig
const RequestError = error{
    HeaderFieldsTooLarge, // -> 431
    BodyTooLarge,         // -> 413
    Timeout,              // -> 408
    Chunked,              // -> 411
    Closed,               // -> close, no response
    Malformed,            // -> 400
};

// Fill until parseHead succeeds; arms the read deadline on first progress.
fn readHead(cr: *ConnReader, hs, read_to: Io.Timeout, idle_to: Io.Timeout) RequestError!parser.Parsed;
// Validate Content-Length against the effective limit, then fill until the body is buffered.
fn readBody(cr: *ConnReader, parsed: *parser.Parsed, max_body: usize, read_to: Io.Timeout) RequestError!void;
```

- The first `fill` in `readHead` uses `idle_to` (waiting for the next request);
  once any byte arrives, subsequent fills use `read_to`. `error.Closed` before any
  byte → clean connection close.
- Effective body limit in `readBody` = `min(max_body or buffer, buffer − head_len)`;
  `Content-Length` over it → `error.BodyTooLarge` (before reading the body).

### Component 5 — `handleConn` rewrite (`src/server.zig`)

Replaces the current `Stream.reader`-based loop. Per the architecture diagram:
build a `ConnReader` over `stream.socket` and a `gpa`-allocated buffer
(`read_buffer_size`); compute `read_to`/`idle_to` from Options each iteration;
on a `RequestError`, write the mapped terminal status (except `Closed`/`Timeout`
on idle → silent close) and break; otherwise dispatch, write, `compact`, and loop
while persistent and under `max_keep_alive_requests`. The write buffer and
per-request arena are unchanged.

Status mapping: `HeaderFieldsTooLarge`→431, `BodyTooLarge`→413, `Timeout`
(mid-request)→408, `Chunked`→411, `Malformed`→400, `Closed`→silent close. These
terminal error responses set `connection: close`.

## Error handling

- Timeouts and limit violations are terminal for the connection: send the mapped
  status (best effort) and close. An idle timeout / pre-request close sends
  nothing.
- `receiveTimeout` errors other than `Timeout` (reset, unexpected) → `error.Closed`
  → close.

## Testing

**Deterministic (real sockets, existing harness):**
- Body whose `Content-Length` exceeds a small `max_body_size` → **413**.
- A request head larger than the read buffer (use a tiny `read_buffer_size`, or
  many headers) → **431**.
- Chunked request body → **411** (regression of existing behavior, now via the
  new path).
- All existing keep-alive / pipelining / error-mapping / 405-Allow tests stay
  green (the `ConnReader` rewrite must preserve them).

**Timing (small timeouts ~100 ms, run 3× for stability):**
- Slowloris: connect, send a partial head (`"GET / HTTP/1.1\r\n"`) and stop; wait
  past `read_timeout_ms` (via `Clock.Duration.sleep`); read the socket → a **408**
  response, then EOF.
- Idle: send one full request and read its response, then stall; wait past
  `idle_timeout_ms`; the next socket read → **EOF** (server closed), no response.

**Risk:** timing tests can flake on a loaded machine. Mitigation: use small but
not tiny timeouts (~100–200 ms), sleep comfortably past them, and run the suite
3× as in prior phases.

## Files

- Modify: `src/server.zig` (Options fields, `ConnReader`, `readHead`/`readBody`
  rewrite, `handleConn` rewrite, status mapping, tests).
- Modify: `src/http/response.zig` (408/413/431 statuses).
- Modify: `src/root.zig` only if new public types need exporting (none expected;
  Options/Status already exported).
- Docs: README "limitations" update (timeouts + size limits now exist; note the
  body-bounded-by-buffer constraint); `docs/getting-started.md` a short note on
  the limit/timeout Options.

## Risks & edge cases

- **Read-path rewrite is the main risk.** It must reproduce: pipelining (multiple
  requests already in `buf`), keep-alive compaction, `Connection: close`,
  HTTP/1.0 default-close, and the exact body framing. Mitigated by keeping the
  parser untouched and re-running the full existing suite.
- **`max_body_size` vs buffer:** because the body is buffered in the read buffer,
  the real ceiling is `read_buffer_size`. `max_body_size` is a policy cap on top;
  a value larger than the buffer is effectively clamped (a body that fits the cap
  but not the buffer → 413). Documented.
- **Timeout `0`** must mean "blocking" (`Io.Timeout.none`) so opting out restores
  current behavior exactly.
- **`compact` correctness** with overlapping ranges: use `std.mem.copyForwards`.

## Out of scope

Large-body streaming / arena buffering (theme C), per-route limits, request line
length limits beyond the buffer bound, HTTP/2, and TLS (theme already decided:
reverse proxy).
