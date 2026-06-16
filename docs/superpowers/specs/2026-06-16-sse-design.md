# Zax — Server-Sent Events (C-c2) design

Date: 2026-06-16
Status: approved, ready for implementation planning
Scope: sub-project C-c2 of theme C — an ergonomic SSE helper layered on the
shipped streaming primitive. File serving (C-c3) is separate, out of scope.

## Context

C-c1 shipped `Response.stream(comptime Ctx, *const Ctx, comptime func: fn(*const
Ctx, *Writer) anyerror!void, content_type)`: a handler returns a streamed-body
response and writes the body bytes directly to the connection writer
(connection-close framing). SSE is a thin layer on top: the content type is
`text/event-stream` and the body is a sequence of events in a simple line
format. Goal: let a handler emit typed events without hand-writing the wire
bytes.

SSE wire format (per event): optional `event: <name>`, `id: <id>`,
`retry: <ms>` lines, then one `data: <line>` per line of the payload, then a
blank line terminating the event. A line starting with `:` is a comment
(used for keep-alive pings).

## Decision (from brainstorming)

- **Auto-flush per event.** `Sse.send`/`comment` write the bytes and flush, so
  each event reaches the client immediately (SSE's real-time intent). The cost
  (a flush per event) is acceptable at SSE cadence.

## Architecture

```
handler → Response.sse(Ctx, ctx, fn)            // fn: fn(*const Ctx, *Sse)
        → Response.stream(Ctx, ctx, wrap, "text/event-stream")   // reuse C-c1
server → writes head (connection-close) → wrap builds Sse{w} → fn(ctx, &sse)
       → sse.send(event) formats + flushes each event to the socket
       → fn returns (or errors on client disconnect) → connection closes
```

### Component 1 — `src/http/sse.zig` (new)

Imports only `std` (so `response.zig` can import it without a cycle).
`const Writer = std.Io.Writer;`.

```zig
pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8 = "",
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// Write one SSE event block (no flush). Emits event/id/retry lines when set,
/// one `data:` line per `\n`-split line of `e.data`, then a blank terminator.
pub fn formatEvent(w: *Writer, e: Event) Writer.Error!void {
    if (e.event) |x| try w.print("event: {s}\n", .{x});
    if (e.id) |x| try w.print("id: {s}\n", .{x});
    if (e.retry) |x| try w.print("retry: {d}\n", .{x});
    var it = std.mem.splitScalar(u8, e.data, '\n');
    while (it.next()) |line| try w.print("data: {s}\n", .{line});
    try w.writeByte('\n');
}

/// Write an SSE comment line (`: <text>`) — used for keep-alive (no flush).
pub fn formatComment(w: *Writer, text: []const u8) Writer.Error!void {
    try w.print(": {s}\n", .{text});
}

/// Event writer over the connection writer. Each method flushes (real-time).
pub const Sse = struct {
    w: *Writer,

    pub fn send(self: *Sse, e: Event) Writer.Error!void {
        try formatEvent(self.w, e);
        try self.w.flush();
    }
    pub fn data(self: *Sse, s: []const u8) Writer.Error!void {
        return self.send(.{ .data = s });
    }
    pub fn comment(self: *Sse, text: []const u8) Writer.Error!void {
        try formatComment(self.w, text);
        try self.w.flush();
    }
};
```

### Component 2 — `Response.sse` (`src/http/response.zig`)

`response.zig` imports `sse.zig` (e.g. `const sse = @import("sse.zig");`). Add to
the `Response` struct, after the `stream` builder:

```zig
/// Build an SSE (`text/event-stream`) streamed response. `func` receives the
/// arena-allocated `context` and an `Sse` event writer. Connection-close framing
/// (like `stream`); each event is flushed as it is sent.
pub fn sse(
    comptime Ctx: type,
    context: *const Ctx,
    comptime func: fn (*const Ctx, *sse.Sse) anyerror!void,
) Response {
    const Wrap = struct {
        fn run(c: *const Ctx, w: *Writer) anyerror!void {
            var s = sse.Sse{ .w = w };
            return func(c, &s);
        }
    };
    return Response.stream(Ctx, context, Wrap.run, "text/event-stream");
}
```

### Component 3 — exports (`src/root.zig`)

```zig
pub const sse = @import("http/sse.zig");
pub const Sse = sse.Sse;
pub const SseEvent = sse.Event;
```

## Data flow / disconnect

- A streamed SSE response is connection-close: the connection stays open for as
  long as `func` runs. A finite feed returns and closes; an infinite loop runs
  until the client disconnects, at which point `flush` returns an error, the
  streamer's `try` propagates, and the connection closes. (Inherited from C-c1.)

## Testing

**Unit (`sse.zig`, fixed-buffer `Writer`):**
- `formatEvent` with all fields + multi-line data:
  `Event{ .event = "tick", .id = "5", .retry = 1000, .data = "a\nb" }` →
  `"event: tick\nid: 5\nretry: 1000\ndata: a\ndata: b\n\n"`.
- `formatEvent(.{ .data = "x" })` → `"data: x\n\n"`.
- `formatComment(w, "ping")` → `": ping\n"`.

**Socket integration (`server.zig`):** a handler returning `Response.sse(...)`
that sends two events and a comment; the client reads to EOF and asserts
`content-type: text/event-stream`, `connection: close`, and the expected event
bytes.

## Files

- New: `src/http/sse.zig` (+ unit tests).
- Modify: `src/http/response.zig` (`sse.zig` import, `Response.sse`), `src/root.zig`
  (exports), `src/server.zig` (integration test).
- Docs: README + `docs/getting-started.md` — a short SSE note.

## Risks & edge cases

- **Flush on a fixed-buffer `Writer`.** `Sse.send` flushes, which is awkward to
  unit-test on a fixed buffer; therefore the byte-format tests target the
  no-flush `formatEvent`/`formatComment`, and the flush path is exercised by the
  real-socket integration test.
- **Empty `data`.** `formatEvent(.{})` emits a single empty `data: \n` line plus
  the blank terminator — valid SSE (an event with empty data). Acceptable.
- **No import cycle.** `response.zig` → `sse.zig` → `std` only.

## Out of scope

`Last-Event-ID` reconnect handling, automatic heartbeats (the handler sends a
`comment` itself), chunked transfer-encoding, and client-side reconnection.
