# Design — inbound chunked transfer-encoding request bodies (streaming gap #4)

**Status:** approved 2026-06-19. Branch `feat/inbound-chunked` (off main `a18193d`).

## Problem

zax rejects every request carrying `Transfer-Encoding: chunked` with **411 Length
Required**, on both backends:

- threaded: `src/server.zig:657-661` — `if (parsed.request.isChunked()) → 411 + close`.
- evented: `src/reactor/conn.zig:294-296` — `error.ChunkedNotSupported → 411`.

There is **no inbound chunked decoder**. `src/http/chunked.zig` is encode-only
(`writeChunk` / `writeTerminator` / `ChunkedWriter`, used by outbound streaming from
gap #1). A chunked request body is a legitimate, RFC 7230 §4.1 client behavior (POST
without a known length, e.g. streamed uploads); rejecting it is a compliance gap.

Gap #4 of the streaming follow-ups: decode inbound chunked request bodies so handlers
receive the same `[]const u8` body the Content-Length path produces.

## Goal

Accept `Transfer-Encoding: chunked` requests on **both** backends: decode the body in
place, attach it as a zero-copy `[]const u8` slice (exactly what `Bytes`/`Json`/`Form`
extractors already read via `ctx.req.body`), and continue the keep-alive loop. The
existing `max_body_size` limit bounds the **decoded** length.

### Decisions (confirmed with Chris)
- **Always-on (remove the 411).** Standard HTTP/1.1 server behavior; no opt-in knob.
- **Both backends.** The 411 lives on both; fixing one is an inconsistent footgun.
- **Tolerate chunk extensions and trailers.** Parse the hex size, skip any `;ext` to
  the line CRLF; after the terminating `0`-chunk, skip trailer header lines to the final
  blank line. Max-permissive, matches mainstream servers.

Non-goals: streaming decode of bodies larger than the read buffer (same buffer-bound
limitation as the Content-Length path today); exposing trailer header values to handlers
(skipped, not surfaced); outbound trailers.

## Key constraints

1. **Zero-copy body.** Extractors (`src/extract/{bytes,json,form}.zig`) all read
   `ctx.req.body: []const u8`. The decoder must yield one contiguous slice into the read
   buffer — so decode **in place**: concatenate chunk data over the removed chunk
   headers. Write-position ≤ read-position at every step (headers are pure overhead being
   removed), so the overlapping copy is a forward copy (`std.mem.copyForwards`).
2. **Encoded ≠ decoded length.** Both backends currently advance past a request by
   `head_len + body.len` (`conn.zig:493`, `server.zig:667`). For chunked, the bytes
   consumed from the wire (chunk headers + data + CRLFs + terminator + trailers) exceed
   `body.len`. The advance must use the **encoded** consumed length, or keep-alive /
   pipelining corrupts the next request. → add an explicit encoded-length field to
   `parser.Parsed`.
3. **Incremental availability.** The evented backend reads in pieces; the decoder must
   distinguish "need more bytes" from "done" from "malformed". The threaded backend fills
   until the same decoder reports done.
4. **Bounded by the read buffer.** Like Content-Length today, the entire encoded chunked
   body must fit in the read buffer. If the buffer fills before the terminator → 413.

## Components

### Modified: `src/http/chunked.zig` (add an in-place decoder)

```zig
pub const DecodeResult = union(enum) {
    /// Fully decoded. `body_len` = decoded byte count (now at buf[0..body_len]).
    /// `consumed` = encoded bytes eaten from buf (chunk sizes + data + CRLFs +
    /// terminator + trailers) — what the caller advances the stream past.
    done: struct { body_len: usize, consumed: usize },
    /// Buffer does not yet contain a complete chunked body — read more, retry.
    incomplete,
    /// Malformed chunk framing (bad hex size, missing CRLF) → 400.
    malformed,
    /// Decoded length would exceed `max` → 413.
    too_large,
};

/// Decode a chunked request body IN PLACE. `buf` is the bytes starting at the
/// first chunk-size line (i.e. immediately after the request head). On `.done`,
/// the decoded body occupies `buf[0..body_len]`; bytes after `buf[consumed..]`
/// (a pipelined next request) are untouched. `max` caps the decoded length
/// (0 = unbounded). Tolerates chunk extensions (`<hex>;ext=val`) by skipping to
/// the CRLF, and trailer headers after the `0`-chunk by skipping to the final
/// blank line.
pub fn decodeInPlace(buf: []u8, max: usize) DecodeResult;
```

**Two-pass and repeat-safe.** Because both backends call `decodeInPlace` repeatedly on
a buffer that grows as bytes arrive, it must NOT mutate the buffer until it knows the
whole body is present — otherwise a partial compaction followed by `.incomplete` corrupts
the input for the next call. So:

- **Pass 1 (validate + measure, no writes):** walk the chunks. Parse each chunk-size line
  (CRLF absent → `.incomplete`; no valid hex digit → `.malformed`; skip any `;extension`
  to the CRLF). For `size > 0`, require `size` data bytes + trailing CRLF buffered (absent
  → `.incomplete`; bad CRLF → `.malformed`); accumulate `total`, and `total > max` (max≠0)
  → `.too_large`. For `size == 0`, skip trailer lines to the final blank line (not yet
  buffered → `.incomplete`); record `consumed` = end of final CRLF. Pass 1 leaves `buf`
  byte-for-byte unchanged on every return.
- **Pass 2 (compact, only when complete):** re-walk and `std.mem.copyForwards` each
  chunk's data to the write cursor `w` (`w ≤ read cursor` always, so the overlapping copy
  is forward-safe). Return `.done{ .body_len = w, .consumed }`.

Pure function, no allocation, no IO — unit-testable in isolation.

### Modified: `src/http/parser.zig` (encoded body length)

Add to `Parsed`:
```zig
/// Encoded body bytes after the head (Content-Length value, or the full encoded
/// length of a chunked body). The stream is advanced by `head_len + body_consumed`.
body_consumed: usize = 0,
```
`parseHead` leaves the default `0`; each backend's `readBody` sets it (= `clen` for
Content-Length, = `consumed` for chunked).

### Modified: `src/server.zig` (threaded backend)

- Delete the 411 block (`657-661`).
- `readBody` (`949-962`): branch on `parsed.request.isChunked()`.
  - Content-Length path (unchanged): after attaching `body`, set
    `parsed.body_consumed = clen`.
  - Chunked path: loop `cr.fill()` until `decodeInPlace(cr.buffered()[head_len..], max)`
    returns non-`.incomplete`; on buffer full (`error.BufferFull`) → `error.BodyTooLarge`;
    on `.malformed` → new `error.MalformedBody`; on `.too_large` → `error.BodyTooLarge`;
    on `.done{body_len, consumed}` → `parsed.request.body =
    cr.buffered()[head_len .. head_len + body_len]`, `parsed.body_consumed = consumed`.
- `handleConn` consumed calc (`667`): `parsed.head_len + parsed.body_consumed`.
- `RequestError` + `terminalResponse` (`964+`): add `error.MalformedBody → .bad_request`
  (400).

### Modified: `src/reactor/conn.zig` (evented backend)

- Delete the 411 rejection (`294-296`) and the `ChunkedNotSupported` error variant
  (`81`) + its mapping (`473`).
- `readBody` (`292-338`): branch on `p.request.isChunked()`.
  - Content-Length path (unchanged): set `result.body_consumed = clen`.
  - Chunked path: `state = .reading_body`; loop `t.read` into `read_buf[r_end..]`, then
    `decodeInPlace(read_buf[head_abs .. r_end], max)`:
    `.incomplete` + `.would_block` → `.need_more`; `.incomplete` + buffer full
    (`r_end == read_buf.len`) → `.failed = error.BodyTooLarge`; `.malformed` →
    `.failed = error.Malformed` (already → 400 at `472`); `.too_large` →
    `.failed = error.BodyTooLarge`; `.done{body_len, consumed}` →
    `result.request.body = read_buf[head_abs .. head_abs + body_len]`,
    `result.body_consumed = consumed`.
- `.parsed` advance (`493`): `const consumed = p.head_len + p.body_consumed;`.

## Data flow (evented chunked POST)

```
reading_head → parse head, isChunked() → reading_body
  → read into read_buf; decodeInPlace(read_buf[head_abs..r_end], max)
       .incomplete + would_block → need_more (re-arm read)
       .incomplete + buffer full  → 413
       .malformed                 → 400
       .too_large                 → 413
       .done{body_len, consumed}  → body = read_buf[head_abs..+body_len]
                                     body_consumed = consumed
  → dispatch (handler sees contiguous body) → advance r_start += head_len + consumed
```

## Error handling

- Malformed framing (bad hex, missing CRLF) → **400 Bad Request**.
- Decoded body over `max_body_size`, or encoded body overflows the read buffer before the
  terminator → **413 Payload Too Large** (reuses existing `BodyTooLarge`).
- Peer close mid-body → existing closed-connection handling (unchanged).

## Behavior change & test impact

- The two existing "chunked → 411" tests (`server.zig` ~`:1046`, `conn.zig` ~`:873`) now
  assert successful decode (200 + decoded body) — they are rewritten as part of the
  feature, not deleted.
- Content-Length requests: unchanged (the new `body_consumed` equals the old `body.len`).

## Testing

Unit — `src/http/chunked.zig` `decodeInPlace` (pure, exhaustive):
1. Single chunk: `"5\r\nhello\r\n0\r\n\r\n"` → `body_len=5` (`"hello"`), `consumed=` full.
2. Multi-chunk: `"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"` → `"hello world"` (concatenation
   correct, in-place overlap correct).
3. Chunk extension: `"5;foo=bar\r\nhello\r\n0\r\n\r\n"` → `"hello"` (extension skipped).
4. Trailers: `"5\r\nhello\r\n0\r\nX-Trace: 1\r\n\r\n"` → `"hello"`, consumed includes the
   trailer block.
5. Incomplete: truncated input (no terminator; partial size line; data shorter than size)
   → `.incomplete`.
6. Malformed: bad hex size (`"zz\r\n..."`), missing data CRLF → `.malformed`.
7. Too large: decoded length > `max` → `.too_large`.
8. Empty body: `"0\r\n\r\n"` → `body_len=0`.

Threaded e2e — `src/server.zig` (loopback, mirror existing body tests): POST with
`Transfer-Encoding: chunked`, multi-chunk body → 200, handler observes the full decoded
body; a second request on the same connection proves keep-alive survived. Malformed
chunk → 400.

Evented integration — `src/reactor/conn.zig` (fake transport): drive a chunked POST,
including a split delivery (bytes arrive across two `read`s → `.need_more` then `.parsed`)
to exercise incremental decode; assert decoded body + that `r_start` advanced by the
encoded length (next pipelined request parses correctly).

## Verification

- `zig build test --summary all` — baseline 235/238 mac (3 Linux-epoll skips); after this
  feature, baseline + new tests, 0 failures, on mac (kqueue) and Linux (epoll via Docker).
- Manual: `curl -v -H "Transfer-Encoding: chunked" --data-binary @file URL` (curl chunks
  when length is unknown) returns 200 with the body echoed; a malformed chunk → 400.

## Docs

- `docs/evented-backend.md` (and any request/body docs): note chunked request bodies are
  now decoded on both backends (bounded by `max_body_size`/read buffer; extensions and
  trailers tolerated but not surfaced).
- `CHANGELOG.md`: entry under `[Unreleased]`.
