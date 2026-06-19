# Design — chunked transfer-encoding for streamed responses (keep-alive after stream)

**Status:** approved 2026-06-18. Branch `feat/chunked-streaming` (off main).

## Problem

Every streamed response in zax (`stream`, `streamPull`, `sse`, `ssePull`) uses **connection-close
framing**: the head carries `connection: close` and no `content-length`, the body is written raw, and
the connection closes afterward. This is the only way to delimit an unknown-length body in HTTP/1.1
*without* chunked transfer-encoding. The cost: a connection cannot be reused after a stream — every
streamed response burns its connection, defeating keep-alive (and, for SSE/long-poll patterns,
forcing a fresh TCP+handshake per stream).

Gap #1 of the streaming follow-ups: add **HTTP/1.1 chunked transfer-encoding** so a streamed response
keeps the connection alive when the client supports it.

## Goal

When the client is HTTP/1.1 and persistent, stream the body with `Transfer-Encoding: chunked` and keep
the connection in the keep-alive loop. Otherwise fall back to today's connection-close framing. Applies
to **all four** streaming APIs (`stream`, `sse`, `streamPull`, `ssePull`) on **both** backends.

Non-goals: HTTP trailers; fixing the threaded `streamPull` `chunk(0)` busy-loop (separate gap);
inbound chunked *request* bodies (separate gap, currently 411).

## Trigger (auto, per request)

The framing decision is made by the **driver** (which holds the request), not the handler. For a
streamed response:

```
chunked = persistent
        = server keep_alive enabled
          AND request.isPersistent()              // HTTP/1.1 default, or Connection: keep-alive
          AND (served + 1) < max_keep_alive_requests
```

- `chunked == true`  → head emits `transfer-encoding: chunked` + `connection: keep-alive`, body is
  chunk-framed, and the connection continues the keep-alive loop after the terminator.
- `chunked == false` → today's behavior: `connection: close`, raw body, close after.

The evented conn already computes exactly this `persistent` value (`src/reactor/conn.zig:451-453`);
the threaded handler computes the same in its keep-alive loop. HTTP/1.0, `Connection: close`, exceeding
the request cap, or server keep-alive disabled all fall back to connection-close — no API change for
handlers, and connection-close stays the safe default for non-persistent clients.

## Components

### New: `src/http/chunked.zig`

Pure framing helpers + a Writer adapter. One responsibility: HTTP/1.1 chunked transfer-encoding.

```zig
const Writer = std.Io.Writer;

/// Write one chunk: `<hexlen>\r\n<data>\r\n`. A zero-length `data` writes nothing
/// (a 0-length chunk is the end-of-stream marker and must only be emitted by
/// `writeTerminator`).
pub fn writeChunk(w: *Writer, data: []const u8) Writer.Error!void;

/// Write the end-of-stream marker: `0\r\n\r\n`.
pub fn writeTerminator(w: *Writer) Writer.Error!void;

/// A `std.Io.Writer` that frames everything written through it as chunked
/// transfer-encoding onto an underlying writer, for the push streaming path
/// (`stream`/`sse`) whose handler writes bytes directly. Each drain emits a
/// chunk via `writeChunk`; `finish()` emits the terminator. Never emits a
/// 0-length data chunk (an empty drain writes nothing).
pub const ChunkedWriter = struct {
    // wraps an underlying *Writer; see implementation for buffer strategy
    pub fn init(underlying: *Writer, buf: []u8) ChunkedWriter;
    pub fn writer(self: *ChunkedWriter) *Writer;
    pub fn finish(self: *ChunkedWriter) Writer.Error!void; // flush + terminator
};
```

`writeChunk`/`writeTerminator` are used by the **pull** drivers (both backends). `ChunkedWriter` is
used by the **push** path (threaded only — push streaming does not run on the evented reactor).

### Modified: `src/http/response.zig`

`writeHead` gains a `chunked: bool` parameter (or a sibling `writeHeadChunked`). When `chunked`:
emit `transfer-encoding: chunked` and `connection: keep-alive`, omit `content-length`. When not:
today's streamed head (`connection: close`, no `content-length`). `writeHeaders`/`write` (buffered
responses) are unchanged. The streamed constructors (`stream`/`streamPull`/`sse`/`ssePull`) are
unchanged — they still build a streamed `Response`; the driver decides framing.

### Modified: `src/server.zig` (threaded driver)

`writeResponse` (currently `src/server.zig:774-803`) takes the framing decision (a `chunked: bool`,
computed by the caller from `req.isPersistent()` + server keep-alive + cap):
- **Pull branch** (`resp.pull_streamer`): `writeHead(chunked)`, then for each `next(buf)`:
  `.chunk(n>0)` → `writeChunk` (when chunked) or raw `writeAll` (when not); `.chunk(0)` → continue
  (no frame); `.done` → `writeTerminator` (when chunked) then flush; `.err` → return false (close).
- **Push branch** (`resp.streamer`): `writeHead(chunked)`. When chunked, wrap `w` in a `ChunkedWriter`,
  run `s.func(ctx, chunked_writer)`, then `finish()`. When not chunked, today's direct write.
- The keep-alive loop continues after a chunked stream (does not close); closes after a connection-close
  stream (today's behavior).

### Modified: `src/reactor/conn.zig` (evented driver)

At the pull-streamer dispatch branch (`src/reactor/conn.zig:461-475`), replace "always close after
stream":
- When `persistent`: serialize the head as chunked (`transfer-encoding: chunked` + keep-alive); set a
  `stream_chunked = true` flag on the conn; do **not** set `close_after_write`.
- When not `persistent`: today's behavior (connection-close head, `close_after_write = true`).

In the streaming write pump (the `chunk(n)`/`chunk(0)`/`done` sites from the v0.3.0 work):
- `chunk(n>0)` → if `stream_chunked`, frame via `chunked.writeChunk` into the write buffer before
  pumping; else raw (today).
- `chunk(0)` → park on the timer wheel (today's v0.3.0 behavior — no frame emitted).
- `.done` → if `stream_chunked`, emit `chunked.writeTerminator`, then transition back into the
  keep-alive loop (serve the next request) instead of closing; else close (today).

Note: framing into the fixed write buffer must account for the chunk header/trailer overhead
(`<hexlen>\r\n … \r\n`); a producer chunk that fills the whole buffer leaves no room for the frame —
the pump frames `chunked.writeChunk(buf_slice)` where `buf_slice` is the producer's `n` bytes and the
header/trailer are written around it (use a small scratch for the `<hexlen>\r\n` prefix + `\r\n`
suffix, or reserve space). The implementation plan pins the exact buffer strategy.

## Data flow (evented pull, chunked)

```
dispatch → pull_streamer + persistent
  → serializeHead(chunked=true)             // transfer-encoding: chunked, connection: keep-alive
  → pump: next(buf)
       .chunk(n>0) → writeChunk → socket
       .chunk(0)   → park (timer), re-poll  // NO frame
       .done       → writeTerminator (0\r\n\r\n) → keep-alive loop (next request)
```

## Error handling

- Producer `.err` → close the connection (cannot signal mid-stream error in chunked framing without
  trailers; closing is the honest failure).
- Head-serialize failure (`ResponseTooLarge`) → today's 500 + close path, unchanged.
- A framed chunk that does not fit the write buffer → the pump handles partial writes/backpressure as
  today (the frame bytes are part of the write buffer contents); if the framing overhead cannot fit at
  all (pathological tiny buffer), close. The plan specifies the buffer reservation.

## Behavior change & test impact

- HTTP/1.1 keep-alive clients now receive **chunked** streamed bodies and **reuse** the connection.
  This is correct HTTP/1.1 behavior and strictly better than close-per-stream.
- Connection-close framing remains for HTTP/1.0, `Connection: close`, over the request cap, or server
  keep-alive disabled.
- Existing tests that force `keep_alive = false` (e.g. the conn pull-streamer tests set
  `c.keep_alive = false`) stay connection-close → **unaffected**.
- Any test that drives a streamed response on a *persistent* request and asserts `connection: close`
  must be updated to assert `transfer-encoding: chunked` + keep-alive. These updates are part of the
  feature.

## Testing

Unit (`src/http/chunked.zig`):
1. `writeChunk("hi")` → `"2\r\nhi\r\n"`; `writeChunk("")` writes nothing; a larger payload uses the
   correct lowercase hex length.
2. `writeTerminator` → `"0\r\n\r\n"`.
3. `ChunkedWriter`: writing `"ab"` then `"cde"` then `finish()` → `"2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n"`;
   a zero-length write emits nothing.

Unit (`src/http/response.zig`): `writeHead(chunked=true)` emits `transfer-encoding: chunked` +
`connection: keep-alive`, no `content-length`; `writeHead(chunked=false)` emits `connection: close`.

Evented integration (`src/reactor/conn.zig`, fake transport): drive a persistent request
(`HTTP/1.1`, keep-alive) to a `streamPull`/`ssePull` producer; assert the head has
`transfer-encoding: chunked` + `connection: keep-alive`, the body is correctly chunk-framed, ends with
`0\r\n\r\n`, and the conn then serves a **second** request on the same connection (proves keep-alive).
A separate test with `Connection: close` asserts the connection-close fallback (no chunked framing).

Threaded integration (`src/server.zig` e2e over a real loopback socket, following existing streaming
e2e tests): a persistent request to a pull stream and to a push (`stream`/`sse`) stream → chunked
framing + a second request served on the same socket.

## Verification

- `zig build test --summary all` — baseline 219/222 mac (3 Linux-epoll skips); after this feature
  baseline + new tests, 0 failures, on mac (kqueue) and Linux (epoll via Docker).
- Manual: `curl -v` (HTTP/1.1) against a `streamPull` endpoint shows `Transfer-Encoding: chunked` and a
  reusable connection; `curl --http1.0` shows `Connection: close` + close framing.

## Docs

- `docs/evented-backend.md`: note streamed responses now keep-alive via chunked encoding on HTTP/1.1
  persistent clients (close fallback otherwise).
- `CHANGELOG.md`: entry under `[Unreleased]`.
