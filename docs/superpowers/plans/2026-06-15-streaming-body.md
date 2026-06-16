# Streaming Body Primitive (C-c1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a handler return a streamed-body `Response` that the server frames (connection-close) and whose bytes the handler writes directly to the connection.

**Architecture:** Add a type-erased `Response.stream` callback. Refactor `write()` to share a `writeHeaders(w, ?content_length)` head emitter so buffered and streamed paths stay byte-identical; `writeHead` emits the streamed head (no content-length). The server detects a streamed response, writes the head, invokes the callback, and closes the connection.

**Tech Stack:** Zig 0.16.0, `std.Io`. Spec: `docs/superpowers/specs/2026-06-15-streaming-body-design.md`. Branch: `feat/streaming-body`.

**Conventions:** Tests via `zig build test --summary all`. TDD per task. Do NOT touch main.

---

## File Structure

- **Modify** `src/http/response.zig` — `writeHeaders`/`writeHead` refactor, `Streamer` type, `stream` field, `stream` builder, tests.
- **Modify** `src/server.zig` — `writeResponse` streamed path, `handleConn` connection-close-after-stream, integration test.
- **Modify** `src/root.zig` — `pub const Writer`.
- **Modify** `README.md`, `docs/getting-started.md` — streaming note.

---

## Task 1: Refactor `write` into `writeHeaders` + add `writeHead`

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing test** — add to the test section:

```zig
test "writeHead omits content-length and sets connection close" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain; charset=utf-8" };
    r.writeHead(&w) catch unreachable;
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "content-length:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-type: text/plain; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n")); // head ends at the blank line; no body
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|writeHead"`
Expected: compile error — `Response` has no `writeHead`.

- [ ] **Step 3: Refactor `write` and add `writeHead`** — in `src/http/response.zig`, replace the current `write` method:

```zig
    /// Serialize a complete HTTP/1.1 response (head + body) to `w`.
    pub fn write(self: Response, w: *Writer) Writer.Error!void {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        try w.print("content-length: {d}\r\n", .{self.body.len});
        try w.print("content-type: {s}\r\n", .{self.content_type});
        for (self.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
        try w.writeAll(if (self.keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
        try w.writeAll("\r\n");
        try w.writeAll(self.body);
    }
```

with:

```zig
    /// Emit the response head. `content_length` is emitted only when given
    /// (a streamed response omits it).
    fn writeHeaders(self: Response, w: *Writer, content_length: ?usize) Writer.Error!void {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        if (content_length) |n| try w.print("content-length: {d}\r\n", .{n});
        try w.print("content-type: {s}\r\n", .{self.content_type});
        for (self.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
        try w.writeAll(if (self.keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
        try w.writeAll("\r\n");
    }

    /// Serialize a complete HTTP/1.1 response (head + buffered body) to `w`.
    pub fn write(self: Response, w: *Writer) Writer.Error!void {
        try self.writeHeaders(w, self.body.len);
        try w.writeAll(self.body);
    }

    /// Write the head for a streamed (connection-close) response: no
    /// content-length, no body. The caller writes the body afterward.
    pub fn writeHead(self: Response, w: *Writer) Writer.Error!void {
        try self.writeHeaders(w, null);
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the new `writeHead` test AND every existing golden-bytes serialization test (the buffered `write` is byte-identical: `writeHeaders(body.len)` then body, same order as before).

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "refactor(http): share writeHeaders between write and new writeHead"
```

---

## Task 2: `Streamer` type, `stream` field, and `stream` builder

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing test** — add to the test section:

```zig
test "stream builder round-trips the typed context" {
    const Ctx = struct { msg: []const u8 };
    const Impl = struct {
        fn run(c: *const Ctx, w: *Writer) anyerror!void {
            try w.writeAll(c.msg);
        }
    };
    var ctx = Ctx{ .msg = "hello" };
    const r = Response.stream(Ctx, &ctx, Impl.run, "text/plain");
    try testing.expect(r.stream != null);
    try testing.expectEqualStrings("text/plain", r.content_type);
    try testing.expect(r.keep_alive == false);

    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try r.stream.?.func(r.stream.?.context, &w);
    try testing.expectEqualStrings("hello", w.buffered());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|Streamer|stream"`
Expected: compile error — no `Streamer`, no `stream` field/builder.

- [ ] **Step 3: Add the `Streamer` type** — in `src/http/response.zig`, add at module level, just before `pub const Response = struct {` (the file has `const Writer = std.Io.Writer;` near the top):

```zig
/// A type-erased streamed-body producer: `func` writes the body bytes directly
/// to the connection writer, using `context` (which must outlive the request —
/// allocate it in the request arena).
pub const Streamer = struct {
    context: *const anyopaque,
    func: *const fn (context: *const anyopaque, w: *Writer) anyerror!void,
};
```

- [ ] **Step 4: Add the `stream` field** — in the `Response` struct, add after the `keep_alive` field:

```zig
    /// When set, the body is produced by `stream.func` (connection-close
    /// framing); `body`/`content-length` are not used.
    stream: ?Streamer = null,
```

- [ ] **Step 5: Add the `stream` builder** — add this method to the `Response` struct (after the `json` constructor / before `withHeader`):

```zig
    /// Build a streamed (connection-close) response. `func` receives the
    /// arena-allocated `context` and the connection writer, and writes the body
    /// bytes directly. `context` must outlive the request (use the request arena).
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

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): Response.Streamer + stream builder"
```

---

## Task 3: Server streamed-write path + connection-close + Writer export + integration

**Files:** Modify `src/server.zig`, `src/root.zig`

- [ ] **Step 1: Write the failing integration test** — add to the test section of `src/server.zig` (uses existing helpers `TestApp`, `Db`, `startTestApp`, `Response`, `Io`, `net`, `testing`):

```zig
const Lines = struct { n: usize };
fn writeLines(c: *const Lines, w: *Io.Writer) anyerror!void {
    var i: usize = 0;
    while (i < c.n) : (i += 1) try w.print("line{d}\n", .{i});
}
fn streamHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(Lines);
    c.* = .{ .n = 3 };
    return Response.stream(Lines, c, writeLines, "text/plain");
}

test "streaming: connection-close streamed body over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/stream", streamHandler);

    const port: u16 = 18140;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll("GET /stream HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    // Read to EOF (the server closes after a streamed, connection-close response).
    var rb: [4096]u8 = undefined;
    var rdr = cs.reader(io, &rb);
    while (true) rdr.interface.fillMore() catch break;
    const resp = rdr.interface.buffered();

    try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "content-length:") == null);
    try testing.expect(std.mem.endsWith(u8, resp, "line0\nline1\nline2\n"));

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|FAIL|connection: close"`
Expected: FAIL — the server currently buffered-writes a streamed response (its `body` is empty), so the streamed bytes never appear.

- [ ] **Step 3: Export `Writer` from `src/root.zig`** — add after the `Status`/`Response` exports (near `pub const Response = response.Response;`):

```zig
pub const Writer = std.Io.Writer;
pub const Streamer = response.Streamer;
```

- [ ] **Step 4: Handle the streamed path in `writeResponse`** — in `src/server.zig`, replace the current `writeResponse`:

```zig
fn writeResponse(w: *Io.Writer, resp: Response) bool {
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}
```

with:

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

- [ ] **Step 5: Force connection-close after a stream in `handleConn`** — in `src/server.zig`, find the dispatch+write block in `handleConn`:

```zig
                var resp = self.dispatch(&parsed.request, &arena);
                resp.keep_alive = persistent;
                if (!writeResponse(w, resp)) break;

                cr.consume(consumed);
                served += 1;
                if (!persistent) break;
```

Replace it with:

```zig
                var resp = self.dispatch(&parsed.request, &arena);
                const streamed = resp.stream != null;
                resp.keep_alive = persistent and !streamed;
                if (!writeResponse(w, resp)) break;
                if (streamed) break; // connection-close framing: close after a stream

                cr.consume(consumed);
                served += 1;
                if (!persistent) break;
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the streaming integration test plus every existing test (buffered responses unaffected; non-streamed `resp.stream` is null so behavior is identical).

- [ ] **Step 7: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig src/root.zig
git commit -m "feat(server): stream Response.stream bodies with connection-close framing"
```

---

## Task 4: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README streaming note** — in `README.md`, in the `## Responses` section, add a row to the constructor table (after the `Response.json` row):

```markdown
| `Response.stream(Ctx, ctx, fn, ct)` | streamed body (connection-close) written by `fn` |
```

And add this paragraph immediately after that table:

```markdown
A streamed response writes its body incrementally to the connection (no
`Content-Length`, `connection: close`); the `ctx` must be arena-allocated. Useful
for large/generated bodies:

​```zig
const Lines = struct { n: usize };
fn writeLines(c: *const Lines, w: *zax.Writer) anyerror!void {
    var i: usize = 0; while (i < c.n) : (i += 1) try w.print("line {d}\n", .{i});
}
fn handler(a: zax.Alloc) !zax.Response {
    const c = try a.value.create(Lines); c.* = .{ .n = 100 };
    return zax.Response.stream(Lines, c, writeLines, "text/plain");
}
​```
```

(Replace the `​` zero-width markers with plain triple backticks in the file.)

- [ ] **Step 2: getting-started note** — in `docs/getting-started.md`, in the `### Responses` subsection, append:

```markdown

For large or generated bodies, `Response.stream(Ctx, ctx, fn, "text/plain")`
writes the body incrementally (connection-close, no Content-Length).
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document Response.stream streaming bodies"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines (Task 1 +1, Task 2 +1, Task 3 +1 = +3 over the 87 baseline → 90).

- [ ] Live smoke (optional): `zig build run` — the demo has no stream route; the integration test covers streaming end-to-end.

---

## Self-review notes (already applied)

- **Spec coverage:** writeHeaders/writeHead refactor (Task 1); Streamer + field + builder (Task 2); server streamed path + connection-close + Writer export + integration (Task 3); docs (Task 4). All spec components covered.
- **Type consistency:** `Streamer{context: *const anyopaque, func: *const fn(*const anyopaque, *Writer) anyerror!void}`; `Response.stream(comptime Ctx, *const Ctx, comptime fn(*const Ctx, *Writer) anyerror!void, content_type) Response`; `writeHead`/`writeHeaders(w, ?usize)`; `pub const Writer = std.Io.Writer`. Consistent across tasks and matches the existing `write` signature (`*Writer`).
- **No placeholders:** complete code in every step; the README's nested fences use an explicit zero-width-marker note.
- **Golden-bytes safety:** Task 1's buffered `write` is byte-identical (`writeHeaders(body.len)` then body); existing serialization tests gate it. Task 3's non-streamed path is unchanged (`resp.stream` null).
- **Connection-close correctness:** Task 3 forces `keep_alive=false` for streamed responses and breaks the loop after, matching the spec's connection-close framing.
```
