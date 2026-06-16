# Zax — streaming body primitive (C-c1) design

Date: 2026-06-15
Status: approved, ready for implementation planning
Scope: sub-project C-c1 of theme C — the architectural streaming primitive. SSE
(C-c2), file serving (C-c3), and chunked transfer-encoding are later sub-projects,
out of scope here.

## Context

Zax responses are fully buffered: a handler returns a `Response{ status,
content_type, body: []const u8, headers, location, keep_alive }` and the server's
`Response.write()` emits `content-length` + the buffered body. There is no way for
a handler to produce a body incrementally (large downloads, server-sent events,
generated streams). The connection `Io.Writer` lives in `handleConn`, not in
handlers, so streaming needs a channel from the handler to that writer.

Goal: let a handler return a streamed-body response that the server frames and
whose bytes the handler writes directly to the connection.

## Decisions (from brainstorming)

- **Framing: connection-close.** A streamed response omits `content-length`, sends
  `connection: close`, writes the body, and closes the socket (client reads to
  EOF). Simple and correct; the trade-off is no keep-alive for a streamed
  response. Chunked transfer-encoding (which preserves keep-alive) is a later
  enhancement.
- **Handler API: the `Response` carries a stream callback (Model A).** The handler
  returns a `Response` whose body is a type-erased streamer `{context, func}`,
  built via an ergonomic helper that hides the erasure. This keeps the
  "handler returns `Response`" model and matches Axum's streaming-body shape.

## Architecture

```
handler → Response.stream(Ctx, ctx, func, content_type)   // ctx is arena-allocated
        → Response{ stream = Streamer{context, func}, content_type, keep_alive=false }
server (handleConn):
   resp.stream != null ?
     → resp.writeHead(w)                 // status + content-type + headers + connection: close, NO content-length
     → streamer.func(context, w)         // handler writes body bytes to the socket
     → flush ; close (connection-close, break the keep-alive loop)
   else → existing buffered write path
```

### Component 1 — `Response.Streamer` + field (`src/http/response.zig`)

```zig
pub const Streamer = struct {
    context: *const anyopaque,
    func: *const fn (context: *const anyopaque, w: *Writer) anyerror!void,
};
```

Add to `Response`:

```zig
/// When set, the body is produced by `stream.func` (connection-close framing);
/// `body`/`content-length` are not used.
stream: ?Streamer = null,
```

### Component 2 — head emitter refactor (`Response.write`)

Factor the header block so buffered and streamed responses share it and stay
byte-identical:

```zig
fn writeHeaders(self: Response, w: *Writer, content_length: ?usize) Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
    if (content_length) |n| try w.print("content-length: {d}\r\n", .{n});
    try w.print("content-type: {s}\r\n", .{self.content_type});
    for (self.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
    try w.writeAll(if (self.keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
    try w.writeAll("\r\n");
}

pub fn write(self: Response, w: *Writer) Writer.Error!void {
    try self.writeHeaders(w, self.body.len);
    try w.writeAll(self.body);
}

/// Head for a streamed (connection-close) response: no content-length, no body.
pub fn writeHead(self: Response, w: *Writer) Writer.Error!void {
    try self.writeHeaders(w, null);
}
```

The buffered `write` produces the exact same bytes as today (`writeHeaders`
emits status, content-length, content-type, headers, location, connection in the
existing order), so all golden-bytes tests stay green.

### Component 3 — builders

```zig
/// Build a streamed response. `func` receives the arena-allocated `context` and
/// the connection writer, and writes the body bytes directly. The streamer's
/// context must outlive the request (use the request arena).
pub fn stream(
    comptime Ctx: type,
    context: *const Ctx,
    comptime func: fn (*const Ctx, *Writer) anyerror!void,
    content_type: []const u8,
) Response {
    const Erased = struct {
        fn call(c: *const anyopaque, w: *Writer) anyerror!void {
            return func(@ptrCast(@alignCast(c)), w);
        }
    };
    return .{
        .content_type = content_type,
        .stream = .{ .context = context, .func = &Erased.call },
        .keep_alive = false,
    };
}
```

### Component 4 — server write path (`src/server.zig`)

`writeResponse` handles both shapes:

```zig
fn writeResponse(w: *Io.Writer, resp: Response) bool {
    if (resp.stream) |s| {
        resp.writeHead(w) catch return false;
        s.func(s.context, w) catch return false;
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}
```

`handleConn`: a streamed response is connection-close. Before writing, set
`resp.keep_alive = persistent and (resp.stream == null)`; after writing a streamed
response, break the loop (close):

```zig
var resp = self.dispatch(&parsed.request, &arena);
const streamed = resp.stream != null;
resp.keep_alive = persistent and !streamed;
if (!writeResponse(w, resp)) break;
if (streamed) break;          // connection-close after a stream
cr.consume(consumed);
served += 1;
if (!persistent) break;
```

### Component 5 — export (`src/root.zig`)

Expose the writer type for handler streamer signatures:

```zig
pub const Writer = std.Io.Writer;
```

(So handlers write `fn (*const Ctx, *zax.Writer) anyerror!void`.)

## Error handling

- A streamer that errors mid-stream: the head was already sent, so the server
  cannot send an error response. `writeResponse` returns false → `handleConn`
  breaks and closes the connection. (Acceptable; documented.)
- A streamed response never participates in keep-alive (connection-close).

## Testing

**Unit (`response.zig`):**
- `writeHead` emits status + content-type + `connection: close`, and NO
  `content-length` line.
- Buffered `write` is byte-unchanged (existing golden-bytes tests stay green).
- `stream(Ctx, ctx, func, ct)` round-trips: invoking the built `Streamer.func`
  with the erased context calls through to the typed `func` (assert the bytes a
  test streamer writes to a fixed-buffer `Writer`).

**Socket integration (`server.zig`):** a handler returning
`Response.stream(...)` that writes N lines; the client reads to EOF and asserts
the streamed body and the absence of a `content-length` header, plus
`connection: close`.

## Files

- Modify: `src/http/response.zig` (`Streamer`, `stream` field, `writeHeaders`
  refactor, `writeHead`, `stream` builder, tests).
- Modify: `src/server.zig` (`writeResponse` streamed path, `handleConn`
  connection-close-after-stream, integration test).
- Modify: `src/root.zig` (`pub const Writer`).
- Docs: README + `docs/getting-started.md` — a short streaming note.

## Risks & edge cases

- **Golden-bytes regression.** The `writeHeaders` refactor must reproduce the
  current buffered bytes exactly. Mitigated by the existing serialization tests
  plus an explicit no-content-length assertion for the streamed head.
- **Context lifetime.** The streamer's `context` must live until the body is
  written. Handlers allocate it in the request arena (alive through `write`).
  Documented in the `stream` builder.
- **Streamer error after headers.** Unrecoverable on the wire → close. Documented.
- **`anyerror` in `Streamer.func`.** Kept broad so handler stream logic can fail
  with any error; the server only cares whether it succeeded.

## Out of scope

SSE (`text/event-stream` + event API — C-c2), file serving (C-c3), chunked
transfer-encoding (keep-alive for streamed responses), and backpressure/flow
control beyond what the `Io.Writer` provides.
