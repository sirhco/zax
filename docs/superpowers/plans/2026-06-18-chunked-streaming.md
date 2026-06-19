# Chunked transfer-encoding for streamed responses — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream responses with HTTP/1.1 `Transfer-Encoding: chunked` (keep-alive after the stream) when the client is persistent; otherwise keep today's connection-close framing. All four streaming APIs (`stream`, `sse`, `streamPull`, `ssePull`), both backends.

**Architecture:** A new `src/http/chunked.zig` provides the wire framing (`writeChunk`/`writeTerminator`) and a `ChunkedWriter` (a `std.Io.Writer` that frames the push handler's writes). The drivers decide framing per request (`chunked = persistent`): the pull drivers frame each producer chunk; the push path (threaded only) wraps the writer in `ChunkedWriter`. `Response.writeHead` gains a `chunked` parameter. Connection-close remains the fallback.

**Tech Stack:** Zig 0.16, `std.Io.Writer` (custom `VTable.drain`), the existing reactor conn state machine and threaded keep-alive loop.

## Global Constraints

- Zig 0.16 — no `std.Thread.Mutex`.
- Additive where possible; the only behavior change is that **persistent HTTP/1.1 clients now get chunked streams + connection reuse** (was always close). Connection-close stays the fallback (HTTP/1.0, `Connection: close`, over the keep-alive cap, or server keep-alive disabled).
- A **zero-length data chunk must never be emitted** as a chunk frame — `0\r\n\r\n` is the end-of-stream terminator. `chunk(0)`/not-ready parks (no frame); only `.done` emits the terminator.
- Framing decision is computed by the driver from `request.isPersistent()` (already in `src/reactor/conn.zig:451-453` and `src/server.zig:666-668`), server `keep_alive`, and the request cap. Handlers and the streamed constructors are unchanged.
- Reuse `std.Io.Writer` idioms already in the repo (`Writer.fixed`, `w.buffered()`). The custom `ChunkedWriter.drain` follows the `std.Io.Writer.Discarding.drain` pattern (slice/pattern/splat, returns bytes-consumed-from-`data`).
- Test baseline: `zig build test --summary all` = **219/222 passed, 3 skipped** (3 = Linux-only epoll tests on macOS — expected; don't touch).

---

### Task 1: `chunked.zig` — framing primitives

**Files:**
- Create: `src/http/chunked.zig`
- Modify: register the module for tests — add `_ = @import("http/chunked.zig");` to the test aggregation in `src/root.zig` (find the existing `test { _ = @import(...); }` block / module list and follow it; if modules are pulled in transitively via `response.zig`, instead add the import where the other `http/*` test modules are referenced).

**Interfaces:**
- Produces:
  - `pub fn writeChunk(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void`
  - `pub fn writeTerminator(w: *std.Io.Writer) std.Io.Writer.Error!void`

- [ ] **Step 1: Write the failing tests**

Create `src/http/chunked.zig` with ONLY the tests first (no impl yet) to watch them fail — but since the file is new, write the test block referencing not-yet-existing fns:

```zig
//! HTTP/1.1 chunked transfer-encoding wire framing.

const std = @import("std");
const Writer = std.Io.Writer;

// (implementation added in Step 3)

const testing = std.testing;

test "writeChunk frames hex length + CRLFs" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeChunk(&w, "hi");
    try testing.expectEqualStrings("2\r\nhi\r\n", w.buffered());
}

test "writeChunk uses lowercase hex for larger lengths" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    const data = "x" ** 26; // 26 = 0x1a
    try writeChunk(&w, data);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "1a\r\n"));
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\r\n"));
}

test "writeChunk with empty data writes nothing" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeChunk(&w, "");
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "writeTerminator is 0 CRLF CRLF" {
    var buf: [16]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeTerminator(&w);
    try testing.expectEqualStrings("0\r\n\r\n", w.buffered());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: compile error — `writeChunk`/`writeTerminator` undefined. (Ensure the new file is reachable from the test build — see the Files note; if it is not yet imported anywhere, the test build won't see it. Add the import in Step 3's commit.)

- [ ] **Step 3: Implement the primitives**

Add to `src/http/chunked.zig` (above the test block):

```zig
/// Write one chunk: `<hexlen>\r\n<data>\r\n`. Empty `data` writes nothing — a
/// zero-length chunk is the end-of-stream marker (`writeTerminator`) and must
/// never be emitted for "no data this round".
pub fn writeChunk(w: *Writer, data: []const u8) Writer.Error!void {
    if (data.len == 0) return;
    try w.print("{x}\r\n", .{data.len});
    try w.writeAll(data);
    try w.writeAll("\r\n");
}

/// Write the end-of-stream marker `0\r\n\r\n`.
pub fn writeTerminator(w: *Writer) Writer.Error!void {
    try w.writeAll("0\r\n\r\n");
}
```

Register the module so its tests run: in `src/root.zig`, add `_ = @import("http/chunked.zig");` alongside the other `http/*` test imports (read the file's test aggregation block first and match it).

- [ ] **Step 4: Run to verify pass**

Run: `zig build test --summary all`
Expected: PASS — baseline + 4 new tests (223/226 passed, 3 skipped), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/http/chunked.zig src/root.zig
git commit -m "feat(http): chunked.zig — chunked transfer-encoding framing primitives"
```

---

### Task 2: `chunked.zig` — `ChunkedWriter` (push path)

**Files:**
- Modify: `src/http/chunked.zig`

**Interfaces:**
- Consumes: `writeTerminator` (Task 1).
- Produces:
  - `pub const ChunkedWriter = struct { ... pub fn init(under: *std.Io.Writer, buf: []u8) ChunkedWriter; pub fn writer(self: *ChunkedWriter) *std.Io.Writer; pub fn finish(self: *ChunkedWriter) std.Io.Writer.Error!void; }`

- [ ] **Step 1: Write the failing test**

Add to the `src/http/chunked.zig` test block:

```zig
test "ChunkedWriter frames each flush as a chunk + finish emits terminator" {
    var under_buf: [128]u8 = undefined;
    var under = Writer.fixed(&under_buf);

    var cw_buf: [64]u8 = undefined;
    var cw = ChunkedWriter.init(&under, &cw_buf);
    const w = cw.writer();

    try w.writeAll("ab");
    try w.flush();        // → "2\r\nab\r\n"
    try w.writeAll("cde");
    try cw.finish();      // flush "cde" → "3\r\ncde\r\n", then terminator "0\r\n\r\n"

    try testing.expectEqualStrings("2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n", under.buffered());
}

test "ChunkedWriter: empty flush emits no chunk" {
    var under_buf: [64]u8 = undefined;
    var under = Writer.fixed(&under_buf);
    var cw_buf: [32]u8 = undefined;
    var cw = ChunkedWriter.init(&under, &cw_buf);
    try cw.writer().flush();   // nothing buffered → no chunk
    try cw.finish();           // just the terminator
    try testing.expectEqualStrings("0\r\n\r\n", under.buffered());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: compile error — `ChunkedWriter` undefined.

- [ ] **Step 3: Implement `ChunkedWriter`**

Add to `src/http/chunked.zig`. The `drain` follows `std.Io.Writer.Discarding.drain` (`lib/std/Io/Writer.zig:2227`): `data` always has ≥1 slice; the last is the `pattern` repeated `splat` times; the return value is bytes consumed **from `data`** (the buffer is consumed by setting `w.end = 0`). It writes ONE chunk containing `buffer[0..end]` ++ all data bytes; it must emit nothing when the total is zero (never a 0-length chunk).

```zig
/// A `std.Io.Writer` that frames everything written through it as chunked
/// transfer-encoding onto an underlying writer. For the push streaming path
/// (`stream`/`sse`), whose handler writes bytes directly. Each drain/flush
/// emits one chunk; `finish()` flushes then writes the terminator. A drain
/// with nothing pending emits no chunk (a 0-length chunk would be the
/// end-of-stream marker).
pub const ChunkedWriter = struct {
    under: *Writer,
    interface: Writer,

    pub fn init(under: *Writer, buf: []u8) ChunkedWriter {
        return .{
            .under = under,
            .interface = .{
                .vtable = &.{ .drain = drain, .sendFile = std.Io.Writer.unreachableSendFile },
                .buffer = buf,
            },
        };
    }

    pub fn writer(self: *ChunkedWriter) *Writer {
        return &self.interface;
    }

    /// Flush any buffered bytes as a final chunk, then write the terminator.
    pub fn finish(self: *ChunkedWriter) Writer.Error!void {
        try self.interface.flush();
        try writeTerminator(self.under);
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *ChunkedWriter = @alignCast(@fieldParentPtr("interface", w));
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var data_len: usize = pattern.len * splat;
        for (slice) |b| data_len += b.len;
        const total = w.end + data_len;
        if (total == 0) return 0; // nothing pending — never emit a 0-length chunk
        try self.under.print("{x}\r\n", .{total});
        if (w.end > 0) try self.under.writeAll(w.buffer[0..w.end]);
        for (slice) |b| try self.under.writeAll(b);
        var i: usize = 0;
        while (i < splat) : (i += 1) try self.under.writeAll(pattern);
        try self.under.writeAll("\r\n");
        w.end = 0;
        return data_len;
    }
};
```

Note: confirm `std.Io.Writer.unreachableSendFile` is the right symbol for an unsupported `sendFile` (it exists at `lib/std/Io/Writer.zig:2328` as `unreachableDrain`'s sibling — verify the exact pub name; if it's `failingSendFile`, use that). Push handlers never `sendFile`, so any never-called impl is fine.

- [ ] **Step 4: Run to verify pass**

Run: `zig build test --summary all`
Expected: PASS — 225/228 passed, 3 skipped, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/http/chunked.zig
git commit -m "feat(http): ChunkedWriter — frame push streaming writes as chunked"
```

---

### Task 3: `Response.writeHead(chunked)`

**Files:**
- Modify: `src/http/response.zig` (`writeHead` ~line 257-261, `writeHeaders` ~239-249)
- Test: same file

**Interfaces:**
- Consumes: nothing new.
- Produces: `pub fn writeHead(self: Response, w: *Writer, chunked: bool) Writer.Error!void`
  - **Signature change** (adds `chunked`). All callers must pass it: `src/reactor/conn.zig:352` (`serializeHead`) and any threaded streamed-head path (Task 5 introduces those). The buffered path `write`/`writeHeaders` is unchanged.

- [ ] **Step 1: Write the failing tests**

Add to the `src/http/response.zig` test block:

```zig
test "writeHead chunked=true emits transfer-encoding chunked + keep-alive, no content-length" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain" };
    try r.writeHead(&w, true);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: keep-alive\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-length") == null);
}

test "writeHead chunked=false emits connection close" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain" };
    try r.writeHead(&w, false);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding") == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: compile error — `writeHead` now takes 3 args; existing call sites (`conn.zig:352`) and these tests won't match until updated. (This is expected — Step 3 updates the signature; the `conn.zig` caller is updated here too so the tree compiles.)

- [ ] **Step 3: Implement**

Replace `writeHead` (and the streamed branch of `writeHeaders`) in `src/http/response.zig`:

```zig
/// Emit the response head. `content_length` is emitted only when given.
/// When `chunked` is true (streamed + keep-alive), emit `transfer-encoding:
/// chunked` and `connection: keep-alive`; otherwise honor `self.keep_alive`.
fn writeHeadersFramed(self: Response, w: *Writer, content_length: ?usize, chunked: bool) Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
    if (content_length) |n| try w.print("content-length: {d}\r\n", .{n});
    if (chunked) try w.writeAll("transfer-encoding: chunked\r\n");
    try w.print("content-type: {s}\r\n", .{self.content_type});
    for (self.headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
    const ka = chunked or self.keep_alive;
    try w.writeAll(if (ka) "connection: keep-alive\r\n" else "connection: close\r\n");
    try w.writeAll("\r\n");
}

/// Write the head for a streamed response. `chunked` selects chunked
/// transfer-encoding (+ keep-alive) vs connection-close framing.
pub fn writeHead(self: Response, w: *Writer, chunked: bool) Writer.Error!void {
    try self.writeHeadersFramed(w, null, chunked);
}
```

Keep the existing `writeHeaders(self, w, content_length)` for the buffered `write` path by delegating: `try self.writeHeadersFramed(w, content_length, false);` (so buffered responses are unaffected). Update the call in `src/reactor/conn.zig:352` from `resp.writeHead(&w)` to `resp.writeHead(&w, self.stream_chunked)` — but `stream_chunked` is added in Task 4; for THIS task, update the call to `resp.writeHead(&w, false)` to keep the tree compiling and behavior identical, and Task 4 flips it to `self.stream_chunked`.

- [ ] **Step 4: Run to verify pass**

Run: `zig build test --summary all`
Expected: PASS — 227/230 passed, 3 skipped, 0 failures (no behavior change yet — all streamed heads still pass `false`).

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig src/reactor/conn.zig
git commit -m "feat(http): writeHead(chunked) — chunked/keep-alive vs close streamed head"
```

---

### Task 4: Evented backend — chunked pull framing + keep-alive

**Files:**
- Modify: `src/reactor/conn.zig` (field + helpers near the conn struct; the pull-dispatch branch ~461-477; the two `chunk` sites ~526-543 and ~574-595; the two `.done` sites ~544-549 and ~596-602; the keep-alive reset ~619-623; `serializeHead` ~350-360)
- Test: same file (pull-streamer test block)

**Interfaces:**
- Consumes: `chunked.writeTerminator` (Task 1), `Response.writeHead(chunked)` (Task 3).
- Produces: connection-internal behavior only (no new public API).

- [ ] **Step 1: Write the failing integration tests**

Add to the pull-streamer test section of `src/reactor/conn.zig`. Use an HTTP/1.1 request **without** `Connection: close` so it is persistent, and `c.keep_alive = true`:

```zig
test "conn: chunked streamPull on a persistent request — chunked head, framed body, second request served" {
    const TwoChunk = struct {
        i: usize = 0,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            const chunks = [_][]const u8{ "one", "two" };
            if (c.i >= chunks.len) return .done;
            const ch = chunks[c.i];
            c.i += 1;
            @memcpy(buf[0..ch.len], ch);
            return .{ .chunk = ch.len };
        }
    };
    // Two pipelined persistent requests on one connection.
    const raw = "GET /s HTTP/1.1\r\nHost: x\r\n\r\nGET /s HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx1 = TwoChunk{};
    var ctx2 = TwoChunk{};
    const Disp = struct {
        a: *TwoChunk,
        b: *TwoChunk,
        n: usize = 0,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            const c = if (s.n == 0) s.a else s.b;
            s.n += 1;
            return Response.streamPull(TwoChunk, c, TwoChunk.next, "text/plain");
        }
    };
    var sd = Disp{ .a = &ctx1, .b = &ctx2 };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = Disp.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true; // persistent
    const t = ft.transport();

    var guard: usize = 0;
    var result = c.step(t, d);
    while (result != .done_close and guard < 100) : (guard += 1) {
        if (result == .want_read) break; // entered keep-alive idle after first stream + pipelined consumed
        result = c.step(t, d);
    }

    const out = ft.written.items;
    // Chunked head + framed chunks + terminator for the FIRST stream.
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding: chunked") != null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: keep-alive") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3\r\none\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3\r\ntwo\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0\r\n\r\n") != null);
    // Second request was dispatched (proves the connection survived the stream).
    try testing.expectEqual(@as(usize, 2), sd.n);
}

test "conn: streamPull on a Connection: close request stays connection-close (no chunked)" {
    const OneChunk = struct {
        done: bool = false,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            if (c.done) return .done;
            c.done = true;
            @memcpy(buf[0..3], "abc");
            return .{ .chunk = 3 };
        }
    };
    const raw = "GET /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OneChunk{};
    const Disp = struct {
        p: *OneChunk,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(OneChunk, s.p, OneChunk.next, "text/plain");
        }
    };
    var sd = Disp{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = Disp.dispatch };
    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true;
    const t = ft.transport();
    var guard: usize = 0;
    var result = c.step(t, d);
    while (result != .done_close and guard < 50) : (guard += 1) result = c.step(t, d);
    const out = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, out, "connection: close") != null);
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding") == null);
    try testing.expect(std.mem.indexOf(u8, out, "abc") != null); // raw body, not framed
    try testing.expectEqual(StepResult.done_close, result);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: the chunked test FAILS (no `transfer-encoding: chunked` in output — today streams force close); the close-fallback test passes.

- [ ] **Step 3: Implement chunked pull framing**

In `src/reactor/conn.zig`:

(a) Add a field + const to the `Conn` struct (near `stream_repoll_ms`):
```zig
/// When true, the active pull stream is framed as chunked transfer-encoding
/// and the connection is kept alive after the terminator. Set at dispatch
/// from `persistent`; cleared on each keep-alive reset.
stream_chunked: bool = false,
```
And a file-level const near the top of the struct/impl:
```zig
/// Front bytes of `write_buf` reserved for a chunk's `<hexlen>\r\n` header so a
/// producer chunk can be framed in place without shifting its data.
const chunk_hdr_reserve: usize = 16;
```

(b) `serializeHead` (line ~350): add a `chunked` param and pass it through:
```zig
pub fn serializeHead(self: *Conn, resp: Response, chunked: bool) error{ResponseTooLarge}!usize {
    var w = std.Io.Writer.fixed(self.write_buf);
    resp.writeHead(&w, chunked) catch {
        self.w_len = w.end;
        self.w_off = 0;
        return error.ResponseTooLarge;
    };
    self.w_len = w.end;
    self.w_off = 0;
    return self.w_len;
}
```

(c) The pull-dispatch branch (~461-477): set `stream_chunked = persistent`, serialize chunked head, and only close when not chunked:
```zig
if (resp.pull_streamer) |ps| {
    self.stream_chunked = persistent;
    resp.keep_alive = persistent; // header disposition (writeHead(chunked) drives the actual line)
    if (self.on_response) |hook| hook(&p.request, &resp);
    if (self.serializeHead(resp, self.stream_chunked)) |_| {} else |_| {
        var e500 = Response.fromStatus(.internal_server_error);
        e500.keep_alive = false;
        _ = self.serializeResponse(e500) catch {};
        self.stream_chunked = false;
        self.close_after_write = true;
        self.state = .writing;
        continue;
    }
    self.pull_streamer = ps;
    self.close_after_write = !self.stream_chunked; // chunked → keep-alive after terminator
    self.state = .writing;
    continue;
}
```

(d) Add two small helpers to `Conn` (near `pumpWrite`):
```zig
/// Buffer slice handed to the producer's `next`. When chunked, reserve the
/// header prefix and a 2-byte CRLF suffix so the chunk can be framed in place.
fn pullDst(self: *Conn) []u8 {
    if (self.stream_chunked) return self.write_buf[chunk_hdr_reserve .. self.write_buf.len - 2];
    return self.write_buf;
}

/// After the producer wrote `n` bytes at `write_buf[chunk_hdr_reserve..]`,
/// frame them as `<hexlen>\r\n<data>\r\n` in place and set w_off/w_len.
fn frameChunk(self: *Conn, n: usize) void {
    var hbuf: [chunk_hdr_reserve]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "{x}\r\n", .{n}) catch unreachable; // fits: n < buf.len
    const data_start = chunk_hdr_reserve;
    const hdr_start = data_start - hdr.len;
    @memcpy(self.write_buf[hdr_start..data_start], hdr);
    self.write_buf[data_start + n] = '\r';
    self.write_buf[data_start + n + 1] = '\n';
    self.w_off = hdr_start;
    self.w_len = data_start + n + 2;
}

/// Load the chunked end-of-stream terminator into write_buf and clear the
/// streamer so the normal wrote_all path runs (served++ + keep-alive).
fn loadChunkedTerminator(self: *Conn) void {
    const term = "0\r\n\r\n";
    @memcpy(self.write_buf[0..term.len], term);
    self.w_off = 0;
    self.w_len = term.len;
    self.pull_streamer = null;
    self.deadline_ns = no_deadline;
}
```

(e) The `w_len == 0` guard `chunk` site (~526-543): pass `pullDst()` to `next`, and frame when chunked:
```zig
switch (ps.next(self.pullDst())) {
    .chunk => |n| {
        if (n == 0) {
            // ... unchanged park / escape-hatch logic ...
        }
        if (self.stream_chunked) {
            self.frameChunk(n);
        } else {
            self.w_off = 0;
            self.w_len = n;
        }
        self.deadline_ns = no_deadline;
    },
    .done => {
        if (self.stream_chunked) {
            self.loadChunkedTerminator();
            // fall through to pumpWrite below; terminator writes, then the
            // wrote_all path (pull_streamer now null) does served++ + keep-alive.
        } else {
            self.pull_streamer = null;
            self.served += 1;
            self.state = .closing;
            return .done_close;
        }
    },
    .err => { self.pull_streamer = null; self.state = .closing; return .done_close; },
}
```
(Keep the existing `n == 0` park block exactly as-is; only the `n > 0` assignment and the `.done` arm change.)

(f) The `wrote_all` refill `chunk` site (~574-602): same pattern, but `.done` chunked uses `continue` (loop re-enters `.writing` to pump the terminator):
```zig
switch (ps.next(self.pullDst())) {
    .chunk => |n| {
        if (n == 0) {
            // ... unchanged park / escape-hatch ...
        }
        if (self.stream_chunked) self.frameChunk(n) else { self.w_off = 0; self.w_len = n; }
        self.deadline_ns = no_deadline;
        continue;
    },
    .done => {
        if (self.stream_chunked) {
            self.loadChunkedTerminator();
            continue; // pump terminator; wrote_all (streamer null) → served++ + keep-alive
        }
        self.pull_streamer = null;
        self.served += 1;
        self.state = .closing;
        return .done_close;
    },
    .err => { self.pull_streamer = null; self.state = .closing; return .done_close; },
}
```

(g) The keep-alive reset in the normal `wrote_all` path (~619-623): clear `stream_chunked`:
```zig
// Keep-alive: reset for next request.
self.close_after_write = false;
self.stream_chunked = false;
_ = self.arena.reset(.retain_capacity);
self.compact();
self.state = .reading_head;
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test --summary all`
Expected: PASS — the chunked test now shows `transfer-encoding: chunked`, `3\r\none\r\n`, `3\r\ntwo\r\n`, `0\r\n\r\n`, and `sd.n == 2`; the close-fallback test still passes. Existing pull-streamer/ssePull tests that set `c.keep_alive = false` stay connection-close (unaffected). 229/232 passed, 3 skipped, 0 failures (count approximate — confirm 0 failures).

If a prior pull-streamer/ssePull test used `c.keep_alive = true` AND a persistent request AND asserted `connection: close`, update it to assert chunked (this is the intended behavior change). List any such updates in the commit.

- [ ] **Step 5: Commit**

```bash
git add src/reactor/conn.zig
git commit -m "feat(reactor): chunked transfer-encoding + keep-alive for evented pull streams"
```

---

### Task 5: Threaded backend — chunked pull + push framing + keep-alive

**Files:**
- Modify: `src/server.zig` — `writeResponse` (~774-803), `handleConn` keep-alive loop (~680-705)
- Test: same file (e2e streaming tests, following the existing loopback e2e pattern, e.g. around `src/server.zig:1010-1100`)

**Interfaces:**
- Consumes: `chunked.writeChunk`/`writeTerminator`/`ChunkedWriter` (Tasks 1-2), `Response.writeHead(chunked)` (Task 3).

- [ ] **Step 1: Write the failing e2e test**

Add a streaming e2e test following the file's existing loopback harness (find the helper that boots a server on a port + sends a raw request + reads the response; mirror it). Pseudostructure (adapt to the real harness in the file):

```zig
test "threaded: persistent request to a pull stream → chunked framing + connection reused" {
    // boot a server with a route that returns Response.streamPull(...) of "one","two"
    // send: "GET /s HTTP/1.1\r\nHost: x\r\n\r\n" then a SECOND request on the same socket
    // assert the first response head has "transfer-encoding: chunked" + "connection: keep-alive",
    //   body contains "3\r\none\r\n" and "3\r\ntwo\r\n" and "0\r\n\r\n",
    // assert the SECOND request gets a response on the same socket (keep-alive worked).
}
```

(Use the exact e2e helpers already in `src/server.zig`'s test section — `cr`/`cw` interfaces, `readResp`, the route-registration boilerplate. Match their style; do not invent a new harness.)

- [ ] **Step 2: Run to verify failure**

Run: `zig build test --summary all`
Expected: FAILS — today the threaded stream sends `connection: close` and closes after the stream (no second response).

- [ ] **Step 3: Implement**

(a) `writeResponse` (`src/server.zig:774-803`) — add a `chunked: bool` param and frame accordingly:
```zig
fn writeResponse(w: *Io.Writer, resp: Response, chunked: bool) bool {
    // Pull-streamed response.
    if (resp.pull_streamer) |ps| {
        resp.writeHead(w, chunked) catch return false;
        var chunk_buf: [4096]u8 = undefined;
        while (true) {
            switch (ps.next(&chunk_buf)) {
                .chunk => |n| {
                    if (n == 0) continue; // not ready (busy-loop unchanged on threaded)
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
    // Push-streamed response.
    if (resp.streamer) |s| {
        resp.writeHead(w, chunked) catch return false;
        if (chunked) {
            var cw_buf: [4096]u8 = undefined;
            var cw = chunked_mod.ChunkedWriter.init(w, &cw_buf);
            s.func(s.context, cw.writer()) catch return false;
            cw.finish() catch return false;
        } else {
            s.func(s.context, w) catch return false;
        }
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}
```
Add the import at the top of `src/server.zig`: `const chunked_mod = @import("http/chunked.zig");` (match the existing `@import` style/paths in the file).

Note: the non-streamed `writeResponse` callers (e.g. `src/server.zig:654`, `terminalResponse`) must pass `false`. Update those call sites.

(b) `handleConn` loop (`src/server.zig:680-705`):
```zig
const streamed = resp.streamer != null or resp.pull_streamer != null;
const chunked = streamed and persistent;
resp.keep_alive = persistent and !streamed; // unchanged for buffered; streamed head driven by writeHead(chunked)
if (!writeResponse(w, resp, chunked)) break;
// ... observer block unchanged ...
if (streamed and !chunked) break; // close only after a connection-close stream
```
(The `if (streamed) break;` at line 705 becomes `if (streamed and !chunked) break;`.)

- [ ] **Step 4: Run to verify pass**

Run: `zig build test --summary all`
Expected: PASS — the new e2e test sees chunked framing + a second response on the same socket. Existing non-streaming e2e tests unaffected (they pass `chunked = false`). 231/234 passed (approx), 3 skipped, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): chunked transfer-encoding + keep-alive for threaded streams"
```

---

### Task 6: Docs + CHANGELOG + final verification

**Files:**
- Modify: `docs/evented-backend.md` (Streaming section)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

- [ ] **Step 1: Update `docs/evented-backend.md`**

In the Streaming section, add a short paragraph:

```markdown
### Keep-alive after a stream (chunked transfer-encoding)

Streamed responses are sent with **`Transfer-Encoding: chunked`** and keep the connection alive
when the client is HTTP/1.1 and persistent (the default unless it sent `Connection: close`). The
connection is then reused for the next request. HTTP/1.0 clients, `Connection: close`, exceeding
`max_keep_alive_requests`, or a server with keep-alive disabled fall back to connection-close
framing. This applies to all streaming APIs (`stream`, `sse`, `streamPull`, `ssePull`) on both
backends; a not-ready (`chunk(0)`) producer never emits a zero-length chunk (only end-of-stream does).
```

- [ ] **Step 2: Update `CHANGELOG.md`** — under `## [Unreleased]` → `### Added`:

```markdown
- **Chunked transfer-encoding for streamed responses.** Streamed responses (`stream`, `sse`,
  `streamPull`, `ssePull`) now use `Transfer-Encoding: chunked` and keep the connection alive for
  HTTP/1.1 persistent clients, on both backends; connection-close framing remains the fallback
  for HTTP/1.0 / `Connection: close` / keep-alive-disabled.
```

- [ ] **Step 3: Final verification**

Run: `zig build test --summary all`
Expected: 0 failures, 3 skipped, on macOS (kqueue). Confirm the count and that all new tests pass. (Linux/epoll verification runs in CI/Docker — the framing is platform-agnostic; the evented integration test uses the fake transport.)

Manual (optional): `curl -v http://127.0.0.1:PORT/stream` (HTTP/1.1) shows `Transfer-Encoding: chunked` and a kept-alive connection; `curl --http1.0 -v` shows `Connection: close`.

- [ ] **Step 4: Commit**

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(streaming): chunked transfer-encoding + keep-alive after stream"
```

---

## Self-Review

- **Spec coverage:** framing primitives + ChunkedWriter → Tasks 1-2; `writeHead(chunked)` → Task 3; auto-by-request trigger + evented pull framing + keep-alive → Task 4; threaded pull + push framing + loop continuation → Task 5; docs/changelog/verify → Task 6. All spec sections covered. The spec's "evented buffer-reservation strategy" is pinned in Task 4 (`chunk_hdr_reserve = 16`, `pullDst`/`frameChunk` right-aligned header).
- **Placeholder scan:** the threaded e2e test (Task 5 Step 1) is given as structure-to-adapt because it must mirror the file's existing loopback harness rather than invent one — the implementer fills it against the real helpers. All other steps carry complete code.
- **Type consistency:** `writeHead(self, w, chunked: bool)` is used consistently (Task 3 defines; Tasks 4-5 call). `writeResponse(w, resp, chunked: bool)` defined in Task 5 with all call sites updated. `stream_chunked` / `chunk_hdr_reserve` / `pullDst` / `frameChunk` / `loadChunkedTerminator` defined and used within Task 4. `ChunkedWriter.init/writer/finish` defined in Task 2, used in Task 5.

## Risk notes for the executor

- **Task 4 is the hard one.** The `.done`-when-chunked path deliberately reuses the existing normal `wrote_all` keep-alive reset by setting `pull_streamer = null` and loading the terminator — do NOT also `served += 1` in the `.done` arm (the normal path does it). Verify `served` increments exactly once per streamed request.
- **Never emit a 0-length chunk.** `writeChunk("")` is a no-op (Task 1), `ChunkedWriter.drain` returns early on empty (Task 2), and the `chunk(0)` park path emits no frame (Task 4) — three independent guards.
- **`ChunkedWriter.drain` return value** is bytes consumed *from `data`* (not including the buffer); the buffer is consumed by `w.end = 0`. Follow the `Discarding.drain` model exactly.
- **Buffer math (Task 4):** with `chunk_hdr_reserve = 16` and a 2-byte trailing reserve, the producer gets `write_buf[16 .. len-2]`; `n ≤ len-18`, so `hex(n)` is ≤ 8 digits + `\r\n` ≤ 10 ≤ 16 — the header always fits the reserve. The default evented `write_buffer_size` is 8 KB.
