# Evented WebSocket + Handler-API Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one WebSocket handler (`WsHandler{on_open?, on_message, on_close?}`) identically on the threaded (`app.serve`) and evented (`app.serveEvented`) backends, by unifying the handler API on a message callback and wiring WS into the reactor's non-blocking event loop.

**Architecture:** Replace slice-2's blocking `WsConn.read()` loop with a framework-driven callback model. A shared `pump(buf, *start, *end, conn, handler)` core parses complete frames and invokes `on_message`. `WsConn` becomes a vtable handle (`send`/`close`/`state`) so one type serves both backends. The threaded backend runs the read loop and calls `pump`; the reactor adds a `resp.upgrade` branch to `conn.step` (serialize 101 → new `StepResult.upgraded`) and a new `WsSession` (`reactor/ws_session.zig`) that the worker drives per readable/writable event, with bounded outbound buffering for backpressure.

**Tech Stack:** Zig 0.16.0; reactor `Transport`/`IoResult` vtable, `poller`/timer wheel, `std.Io.Writer.fixed`; the slice-1 `parseFrame`/`writeFrame` codec.

## Global Constraints

- Zig `0.16.0`. Ships as **v0.15.0** (bump `build.zig.zon` in the docs task — currently `0.14.0`).
- **Breaking API change (acceptable pre-1.0):** `WsConn.read()` is **removed**; `onUpgrade` takes a `ws.Handler` struct (was a bare `fn(*WsConn) void`). The v0.14.0 threaded echo handler + its e2e are rewritten to the callback form in this slice.
- **Both backends.** Reactor changes confined to `src/reactor/conn.zig`, `src/reactor/worker.zig`, and a new `src/reactor/ws_session.zig`. Non-WS reactor traffic must be byte-for-byte unaffected (new branches gated on `resp.upgrade != null` / `slot.ws != null`).
- **Import direction:** `ws.zig` imports only `std`. `reactor/ws_session.zig` imports `ws.zig` + `reactor/transport.zig` (NOT `worker.zig`/`server.zig`). No cycle.
- **`WsConn` is one vtable type for both backends:** `{ ctx: *anyopaque, vtable: *const VTable{send,close}, state_ptr: *anyopaque, arena }`. `send`/`close` dispatch through the vtable; `state(T)` is `@ptrCast(@alignCast(self.state_ptr))` (a direct cast — the app must be parameterized by a **pointer** state type, the zax convention).
- **`Upgrade` carries `state_ptr`** captured by the extractor from `ctx.state`, so both backends (including the type-erased reactor worker) read `up.state_ptr` uniformly.
- **`pump` semantics:** single frames (no reassembly); `on_message(conn, frame)` per data frame; unmask in place (payload borrows the buffer until the next pump iteration); returns `.closed` on a close frame or any parse error, `.need_more` otherwise (leftover compacted to front). Ping/pong delivered to `on_message`. **No auto-pong, no RFC close-reply** (slice 4).
- **Evented send backpressure:** non-blocking write; partial → buffer remainder in a per-session outbound buffer + signal want_write; writable event drains it then resumes reads; **outbound-buffer overflow → close**.
- Max frame size = the connection read buffer (`Options.read_buffer_size`).
- RFC handshake: `acceptKey("dGhlIHNhbXBsZSBub25jZQ==")` == `"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`.
- Tests live **in-file** as `test "..."` blocks (root `refAllDecls` pulls them in). Build/test: `zig build test --summary all`.

---

## File Structure

- **`src/ws.zig`** (modify) — refactor `WsConn` to a vtable handle; add `Handler`, `SendError`, `pump`; change `Upgrade` to `{accept, handler, state_ptr}`; **remove `read()`** and the slice-2 `WsConn` recv/socket fields. (Keep `acceptKey`/`Opcode`/`Frame`/`parseFrame`/`writeFrame`.)
- **`src/extract/websocket.zig`** (modify) — `onUpgrade(handler)` + capture `state_ptr` from `ctx.state`.
- **`src/server.zig`** (modify) — threaded `handleConn` takeover: framework-driven `pump` loop + `on_open`/`on_close` + a threaded `WsConn` vtable; update the threaded echo e2e to the callback API.
- **`src/reactor/conn.zig`** (modify) — `ws_upgrade` field, `serializeUpgrade`, the dispatch-branch + `StepResult.upgraded` + wrote_all check.
- **`src/reactor/ws_session.zig`** (create) — the evented per-connection WS driver (`onReadable`/`onWritable`/send vtable/backpressure).
- **`src/reactor/worker.zig`** (modify) — `Slot.ws` field, `.upgraded` handling, run-loop routing to `WsSession`, close→`on_close`, minimal idle timeout.
- **`src/root.zig`** (modify) — `pub const WsHandler`.
- **`README.md` / `CHANGELOG.md` / `docs/getting-started.md` / `build.zig.zon`** (modify, docs task).

Tasks build bottom-up: shared core → extractor → threaded refactor → reactor conn → WsSession → worker wiring → docs.

---

### Task 1: Unify `src/ws.zig` on the callback model (`Handler`, `WsConn` vtable, `pump`)

Refactor the connection layer to the framework-driven callback model. Deliverable: `pump` extracts frames and calls `on_message`; `WsConn` is a backend-agnostic vtable handle; `read()` is gone.

**Files:**
- Modify: `src/ws.zig` (replace the slice-2 `WsConn`/`Upgrade`/`Handler` block; keep the codec + its tests)
- Modify: `src/root.zig` (add `WsHandler`)

**Interfaces:**
- Consumes: `Opcode`, `Frame`, `parseFrame`, `writeFrame` (codec); the `buildMaskedFrame` test helper.
- Produces:
  - `Handler = struct { on_open: ?*const fn(*WsConn) void = null, on_message: *const fn(*WsConn, Frame) void, on_close: ?*const fn(*WsConn) void = null }`
  - `SendError = error{WriteFailed}`
  - `WsConn = struct { ctx: *anyopaque, vtable: *const VTable, state_ptr: *anyopaque, arena: std.mem.Allocator, pub const VTable = struct { send: *const fn(*anyopaque, Opcode, []const u8) SendError!void, close: *const fn(*anyopaque) void }, pub fn send/close/state }`
  - `Upgrade = struct { accept: [28]u8, handler: Handler, state_ptr: *anyopaque }`
  - `PumpResult = enum { need_more, closed }`
  - `pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler) PumpResult`
  - In root: `pub const WsHandler = ws.Handler`

- [ ] **Step 1: Replace the slice-2 `WsConn`/`Upgrade`/`Handler` definitions**

In `src/ws.zig`, delete the slice-2 `Handler`, `Upgrade`, and `WsConn` (the one with `io`/`socket`/`buf`/`read`/`compact`) and replace with:

```zig
/// Lifecycle + message callbacks. `on_message` required; `on_open`/`on_close`
/// optional. They run on the connection's owning context (threaded: its thread;
/// evented: the worker thread — must NOT block).
pub const Handler = struct {
    on_open: ?*const fn (conn: *WsConn) void = null,
    on_message: *const fn (conn: *WsConn, frame: Frame) void,
    on_close: ?*const fn (conn: *WsConn) void = null,
};

pub const SendError = error{WriteFailed};

/// Carried on a Response to signal takeover; consumed by each backend's takeover
/// path. `state_ptr` is the app-state pointer captured by the extractor.
pub const Upgrade = struct {
    accept: [28]u8,
    handler: Handler,
    state_ptr: *anyopaque,
};

/// Backend-agnostic connection handle. One type, two backends: the vtable
/// supplies threaded (blocking writeFrame+flush) or evented (non-blocking,
/// buffered) send/close.
pub const WsConn = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    /// The app-state pointer (the router's AppState, which must be a pointer).
    state_ptr: *anyopaque,
    arena: std.mem.Allocator,

    pub const VTable = struct {
        send: *const fn (ctx: *anyopaque, opcode: Opcode, payload: []const u8) SendError!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn send(self: *WsConn, opcode: Opcode, payload: []const u8) SendError!void {
        return self.vtable.send(self.ctx, opcode, payload);
    }
    pub fn close(self: *WsConn) void {
        self.vtable.close(self.ctx);
    }
    /// App state. `T` MUST be the app-state pointer type (e.g. `*Db`).
    pub fn state(self: *WsConn, comptime T: type) T {
        return @ptrCast(@alignCast(self.state_ptr));
    }
};

pub const PumpResult = enum { need_more, closed };

/// Parse complete client frames from `buf[start..end]`, calling
/// `handler.on_message(conn, frame)` per data frame and advancing `start`.
/// Returns `.closed` on a close frame or any parse error; otherwise `.need_more`
/// with leftover bytes compacted to the front (start=0, end=leftover.len).
/// Unmask is in place: each `frame.payload` borrows `buf` only until the next
/// iteration. Ping/pong are delivered to `on_message` (no auto-pong this slice).
pub fn pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler) PumpResult {
    while (start.* < end.*) {
        const parsed = parseFrame(buf[start.*..end.*]) catch |e| switch (e) {
            error.Incomplete => break, // need more bytes
            else => return .closed, // protocol error -> end
        };
        start.* += parsed.consumed;
        if (parsed.frame.opcode == .close) return .closed;
        handler.on_message(conn, parsed.frame);
    }
    // Compact leftover to the front so the caller can append more bytes.
    const leftover = end.* - start.*;
    if (start.* != 0 and leftover != 0) {
        std.mem.copyForwards(u8, buf[0..leftover], buf[start.*..end.*]);
    }
    start.* = 0;
    end.* = leftover;
    return .need_more;
}
```

- [ ] **Step 2: Replace the slice-2 `WsConn` unit tests with `pump` + vtable tests**

Delete the slice-2 `WsConn.read`/`send`/`state` tests (they reference the removed `read`/socket fields) and the frame-larger-than-buffer test. Add:

```zig
// Test sink: records sends and closes through the WsConn vtable.
const TestSink = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    closed: bool = false,
    gpa: std.mem.Allocator,
    fn send(ctx: *anyopaque, opcode: Opcode, payload: []const u8) SendError!void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        writeFrame(blkWriter(self), opcode, payload) catch return error.WriteFailed;
    }
    fn close(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
    // Minimal std.Io.Writer over the ArrayList for capturing send bytes.
    fn blkWriter(self: *TestSink) *std.Io.Writer {
        _ = self;
        unreachable; // replaced below — see note
    }
};
```

NOTE for the implementer: the `TestSink` above is illustrative. Implement the sink so `send` records the serialized frame bytes — the simplest correct form is to serialize with `writeFrame` into a fixed buffer and append to an `ArrayListUnmanaged(u8)`:

```zig
const TestSink = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    closed: bool = false,
    gpa: std.mem.Allocator,
    last_state: *anyopaque = undefined,

    const vtable = WsConn.VTable{ .send = sendFn, .close = closeFn };

    fn sendFn(ctx: *anyopaque, opcode: Opcode, payload: []const u8) SendError!void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        var scratch: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&scratch);
        writeFrame(&w, opcode, payload) catch return error.WriteFailed;
        self.sent.appendSlice(self.gpa, w.buffered()) catch return error.WriteFailed;
    }
    fn closeFn(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

test "ws: pump dispatches one masked text frame to on_message" {
    const Capture = struct {
        var last: []const u8 = "";
        var count: usize = 0;
        fn onMsg(conn: *WsConn, f: Frame) void {
            _ = conn;
            last = f.payload;
            count += 1;
        }
    };
    Capture.count = 0;
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 1, 2, 3, 4 };
    const frame = buildMaskedFrame(&buf, true, .text, key, "hello");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var dummy_state: u8 = 0;
    var conn = WsConn{ .ctx = &sink, .vtable = &TestSink.vtable,
        .state_ptr = @ptrCast(&dummy_state), .arena = std.testing.allocator };
    var start: usize = 0;
    var end: usize = frame.len;
    const r = pump(&buf, &start, &end, &conn, .{ .on_message = Capture.onMsg });
    try std.testing.expectEqual(PumpResult.need_more, r);
    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expectEqualStrings("hello", Capture.last);
    try std.testing.expectEqual(@as(usize, 0), end); // fully consumed
}

test "ws: pump returns closed on a close frame and stops" {
    const Capture = struct {
        var count: usize = 0;
        fn onMsg(conn: *WsConn, f: Frame) void { _ = conn; _ = f; count += 1; }
    };
    Capture.count = 0;
    var buf: [128]u8 = undefined;
    const key = [4]u8{ 9, 9, 9, 9 };
    const f1 = buildMaskedFrame(buf[0..], true, .text, key, "aa");
    _ = buildMaskedFrame(buf[f1.len..], true, .close, key, "");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var st: u8 = 0;
    var conn = WsConn{ .ctx = &sink, .vtable = &TestSink.vtable, .state_ptr = @ptrCast(&st), .arena = std.testing.allocator };
    var start: usize = 0;
    var end: usize = buf.len; // whole buffer not valid; set to the two frames' length:
    end = f1.len + 4; // close frame for "" is 2 hdr + 4 mask = 6; build returns that
    // Recompute precisely from the builder return lengths:
    // (the close frame length is whatever buildMaskedFrame produced)
    const closeLen = buildMaskedFrame(buf[f1.len..], true, .close, key, "").len;
    end = f1.len + closeLen;
    const r = pump(&buf, &start, &end, &conn, .{ .on_message = Capture.onMsg });
    try std.testing.expectEqual(PumpResult.closed, r);
    try std.testing.expectEqual(@as(usize, 1), Capture.count); // "aa" delivered, close stops
}

test "ws: pump returns need_more and preserves a partial frame" {
    const Capture = struct {
        var count: usize = 0;
        fn onMsg(conn: *WsConn, f: Frame) void { _ = conn; _ = f; count += 1; }
    };
    Capture.count = 0;
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 1, 1, 1, 1 };
    const frame = buildMaskedFrame(&buf, true, .text, key, "hello world");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var st: u8 = 0;
    var conn = WsConn{ .ctx = &sink, .vtable = &TestSink.vtable, .state_ptr = @ptrCast(&st), .arena = std.testing.allocator };
    var start: usize = 0;
    var end: usize = frame.len - 3; // 3 payload bytes short
    const r = pump(&buf, &start, &end, &conn, .{ .on_message = Capture.onMsg });
    try std.testing.expectEqual(PumpResult.need_more, r);
    try std.testing.expectEqual(@as(usize, 0), Capture.count);
    try std.testing.expectEqual(@as(usize, frame.len - 3), end); // leftover preserved at front
    try std.testing.expectEqual(@as(usize, 0), start);
}

test "ws: WsConn.send and close route through the vtable" {
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var st: u8 = 0;
    var conn = WsConn{ .ctx = &sink, .vtable = &TestSink.vtable, .state_ptr = @ptrCast(&st), .arena = std.testing.allocator };
    try conn.send(.text, "Hi");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'H', 'i' }, sink.sent.items);
    conn.close();
    try std.testing.expect(sink.closed);
}

test "ws: WsConn.state returns the app-state pointer" {
    const Db = struct { n: u8 };
    var db = Db{ .n = 7 };
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = WsConn{ .ctx = &sink, .vtable = &TestSink.vtable, .state_ptr = @ptrCast(&db), .arena = std.testing.allocator };
    try std.testing.expectEqual(@as(*Db, &db), conn.state(*Db));
}
```

(The `end` recomputation dance in the close test is awkward; the implementer should simplify by capturing each `buildMaskedFrame(...).len` into a `const` as the frames are built and summing them — keep the assertion that `pump` delivers exactly one `on_message` then `.closed`.)

- [ ] **Step 3: Run, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — references to the removed `read()` elsewhere (`server.zig`, the extractor) won't compile yet. That is expected; Tasks 2–3 update those call sites. (If you want an isolated green checkpoint, comment out the threaded takeover temporarily — but the cross-file updates land in Tasks 2–3; it is acceptable for `ws.zig`'s own tests to be the verification here, with the full suite going green at Task 3.)

NOTE to implementer & controller: Tasks 1–3 are a single compile unit (removing `read()` breaks `server.zig`/`websocket.zig` until they are updated). Implement Task 1's code, then proceed to Tasks 2 and 3; the first point the **full** suite compiles green is the end of Task 3. Each task still commits its own slice.

- [ ] **Step 4: Add the root export**

In `src/root.zig`, in the `// --- WebSocket (Phase 5) ---` block, add:

```zig
pub const WsHandler = ws.Handler;
```

- [ ] **Step 5: Commit**

```bash
git add src/ws.zig src/root.zig
git commit -m "feat(ws): unify WsConn on a vtable handle + callback pump (removes read)"
```

---

### Task 2: `WebSocket.onUpgrade(handler)` + capture `state_ptr`

Update the extractor to the handler struct and capture the app-state pointer. Deliverable: `onUpgrade(handler)` returns a `Response` whose `upgrade` carries `{accept, handler, state_ptr}`.

**Files:**
- Modify: `src/extract/websocket.zig`

**Interfaces:**
- Consumes: `ws.Handler`, `ws.Upgrade`, `ws.acceptKey`; `ctx.state`.
- Produces: `pub fn onUpgrade(self, handler: ws.Handler) Response` setting `r.upgrade = .{ .accept, .handler, .state_ptr = @ptrCast(ctx_state_captured) }`.

- [ ] **Step 1: Capture `state_ptr` in `fromContext`**

In `src/extract/websocket.zig`, add a `state_ptr` field to the `WebSocket` struct and capture it from `ctx.state` (the app-state pointer):

```zig
pub const WebSocket = struct {
    key: []const u8,
    state_ptr: *anyopaque,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{NotWebSocketUpgrade}!@This() {
        // ... existing header validation (hasToken upgrade/connection, version 13, key) ...
        const key = ctx.req.header("sec-websocket-key") orelse return error.NotWebSocketUpgrade;
        return .{ .key = key, .state_ptr = @ptrCast(ctx.state) };
    }
    // onUpgrade below
};
```

(`@ptrCast(ctx.state)` requires `ctx.state` to be a pointer — the zax app-state convention. Keep the existing `hasToken` helper and the Upgrade/Connection/Version/Key checks exactly as shipped.)

- [ ] **Step 2: Update `onUpgrade` to take a `Handler`**

```zig
    pub fn onUpgrade(self: @This(), handler: ws.Handler) Response {
        var accept: [28]u8 = undefined;
        _ = ws.acceptKey(self.key, &accept);
        var r = Response.fromStatus(.switching_protocols);
        r.upgrade = .{ .accept = accept, .handler = handler, .state_ptr = self.state_ptr };
        return r;
    }
```

- [ ] **Step 3: Update the extractor tests for the new shapes**

The existing `fromContext` accept/reject tests need a `state` on the fake context. Update `ctxWith` to include a state pointer, and update the `onUpgrade` test to pass a `Handler`:

```zig
fn ctxWith(req: *const FakeReq) struct { req: *const FakeReq, state: *u8 } {
    return .{ .req = req, .state = &dummy_state };
}
var dummy_state: u8 = 0;

test "WebSocket.onUpgrade builds a 101 with the RFC accept value" {
    const req = FakeReq{ .pairs = &valid_pairs };
    const w = try WebSocket.fromContext(ctxWith(&req));
    const H = struct {
        fn onMsg(conn: *ws.WsConn, f: ws.Frame) void { _ = conn; _ = f; }
    };
    const resp = w.onUpgrade(.{ .on_message = H.onMsg });
    try testing.expectEqual(@import("../http/response.zig").Status.switching_protocols, resp.status);
    try testing.expect(resp.upgrade != null);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &resp.upgrade.?.accept);
}
```

(The fromContext accept/reject tests are otherwise unchanged except that `ctxWith` now supplies `state`.)

- [ ] **Step 4: Commit** (suite is not yet fully green — `server.zig` updates in Task 3)

```bash
git add src/extract/websocket.zig
git commit -m "feat(ws): onUpgrade takes a Handler struct + captures app state ptr"
```

---

### Task 3: Threaded `handleConn` takeover via the callback model + e2e update

Rewrite the threaded takeover to drive the handler with `pump`, and update the threaded echo e2e. Deliverable: the full suite compiles green again and the threaded WS echo works on the new API.

**Files:**
- Modify: `src/server.zig` (the `if (resp.upgrade) |up|` branch in `handleConn`; the `wsEchoHandler` + echo e2e + observer test)

**Interfaces:**
- Consumes: `ws.pump`, `ws.WsConn`, `ws.Handler`, `ws.writeFrame`, `ws.Frame`; `up.handler`, `up.accept`, `up.state_ptr`.

- [ ] **Step 1: Replace the takeover branch body**

In `handleConn`, replace the slice-2 takeover branch (everything inside `if (resp.upgrade) |up| { ... }`, keeping the access-log observer block and the hand-written 101) with the callback-driven version. The 101 handshake bytes + the observer record are unchanged; the difference is how the connection is driven after the handshake:

```zig
                if (resp.upgrade) |up| {
                    // (access-log observer block for the 101 request — unchanged)

                    // Write the 101 handshake by hand (unchanged from v0.14.0).
                    w.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch break;
                    w.writeAll("Upgrade: websocket\r\n") catch break;
                    w.writeAll("Connection: Upgrade\r\n") catch break;
                    w.writeAll("Sec-WebSocket-Accept: ") catch break;
                    w.writeAll(&up.accept) catch break;
                    w.writeAll("\r\n\r\n") catch break;
                    w.flush() catch break;

                    // Threaded WsConn: send = blocking writeFrame+flush; close = flag.
                    const ThreadedSink = struct {
                        writer: *std.Io.Writer,
                        closed: bool = false,
                        const vt = ws.WsConn.VTable{ .send = sendFn, .close = closeFn };
                        fn sendFn(ctx: *anyopaque, opcode: ws.Opcode, payload: []const u8) ws.SendError!void {
                            const s: *@This() = @ptrCast(@alignCast(ctx));
                            ws.writeFrame(s.writer, opcode, payload) catch return error.WriteFailed;
                            s.writer.flush() catch return error.WriteFailed;
                        }
                        fn closeFn(ctx: *anyopaque) void {
                            const s: *@This() = @ptrCast(@alignCast(ctx));
                            s.closed = true;
                        }
                    };
                    var sink = ThreadedSink{ .writer = w };
                    var conn = ws.WsConn{ .ctx = &sink, .vtable = &ThreadedSink.vt,
                        .state_ptr = up.state_ptr, .arena = arena.allocator() };

                    // Seed the frame buffer with any pipelined post-handshake bytes.
                    cr.consume(consumed);
                    cr.compact();
                    var start: usize = 0;
                    var end: usize = cr.buffered().len;

                    if (up.handler.on_open) |f| f(&conn);

                    // Framework-driven read loop: read -> pump -> on_message.
                    while (!sink.closed) {
                        if (ws.pump(read_buf, &start, &end, &conn, up.handler) == .closed) break;
                        if (sink.closed) break;
                        // Blocking read more bytes into read_buf[end..].
                        const msg = stream.socket.receiveTimeout(io, read_buf[end..], idle_to) catch break;
                        if (msg.data.len == 0) break; // EOF
                        end += msg.data.len;
                        // If the buffer is full and pump made no progress, the frame
                        // exceeds the buffer -> stop (matches the evented cap).
                        if (end == read_buf.len and start == 0) {
                            // pump on next loop will parse if a full small frame fits;
                            // if still Incomplete with a full buffer it returns need_more
                            // and we'd loop forever — guard: break when no room to grow.
                        }
                    }
                    if (up.handler.on_close) |f| f(&conn);
                    break; // -> defer stream.close
                }
```

NOTE (oversize-frame guard): after `pump` returns `need_more`, if `end == read_buf.len` and `start == 0` (buffer full, no complete frame), break — the frame can never fit. Add that as an explicit check right after the `pump` call:

```zig
                        const pr = ws.pump(read_buf, &start, &end, &conn, up.handler);
                        if (pr == .closed) break;
                        if (sink.closed) break;
                        if (end == read_buf.len) break; // frame larger than buffer -> stop
```

Replace the `while` body's pump+guard accordingly (single `pump` call per iteration, then the oversize guard, then the blocking read).

- [ ] **Step 2: Update `wsEchoHandler` to the callback API**

```zig
fn wsEchoOnMessage(conn: *@import("ws.zig").WsConn, frame: @import("ws.zig").Frame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}
fn wsEchoHandler(sock: @import("extract/websocket.zig").WebSocket) Response {
    return sock.onUpgrade(.{ .on_message = wsEchoOnMessage });
}
```

(The existing `"end-to-end: websocket upgrade, handshake, and echo"` test and the observer-101 test keep their wire assertions — the bytes on the socket are identical; only the handler shape changed. No assertion changes needed beyond the handler swap.)

- [ ] **Step 3: Run the full suite, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the suite compiles again; the threaded WS echo e2e + observer test pass; all prior suites green.

- [ ] **Step 4: Commit**

```bash
git add src/server.zig
git commit -m "feat(ws): threaded takeover drives the unified callback handler"
```

---

### Task 4: Reactor `conn.zig` — upgrade detection + 101 + `StepResult.upgraded`

Teach the reactor's state machine to recognize an upgrade response, send the 101, and signal the worker to switch the slot into WS mode. Deliverable: a dispatch returning `resp.upgrade` serializes a 101 and `step` returns `StepResult.upgraded`.

**Files:**
- Modify: `src/reactor/conn.zig` (add `ws_upgrade` field, `serializeUpgrade`, the dispatch branch, the wrote_all check; import `ws.zig`)
- Modify: the `StepResult` enum (in `conn.zig`) to add `upgraded`

**Interfaces:**
- Consumes: `ws.Upgrade`; `serializeResponse`/`pumpWrite` machinery.
- Produces: `StepResult.upgraded`; `Conn.ws_upgrade: ?ws.Upgrade`; the leftover bytes reachable as `conn.read_buf[conn.r_start..conn.r_end]` after `.upgraded`.

- [ ] **Step 1: Add the `upgraded` StepResult + import + field + serializeUpgrade**

In `src/reactor/conn.zig`:

```zig
const ws = @import("../ws.zig"); // near the other imports
```

Add to `StepResult` (after `done_close`):

```zig
    /// The response was a WebSocket upgrade and the 101 has been fully written.
    /// The worker must switch this slot into WS mode (see reactor/ws_session.zig),
    /// seeding it with conn.read_buf[r_start..r_end] (pipelined post-handshake bytes)
    /// and conn.ws_upgrade (the handler + state ptr).
    upgraded,
```

Add a `Conn` field (near the other Task-4 fields):

```zig
    /// Set when dispatch returned a WebSocket upgrade. After the 101 is written,
    /// `step` returns `.upgraded` and the worker reads this.
    ws_upgrade: ?ws.Upgrade = null,
```

Add a method (next to `serializeResponse`):

```zig
    /// Serialize the 101 WebSocket handshake by hand into `write_buf` (the generic
    /// Response writer would emit content-length: 0 / connection: close). Sets
    /// w_len/w_off like serializeResponse.
    pub fn serializeUpgrade(self: *Conn, accept: [28]u8) error{ResponseTooLarge}!usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        const writeAll = struct {
            fn f(wr: *std.Io.Writer, s: []const u8) error{ResponseTooLarge}!void {
                wr.writeAll(s) catch return error.ResponseTooLarge;
            }
        }.f;
        try writeAll(&w, "HTTP/1.1 101 Switching Protocols\r\n");
        try writeAll(&w, "Upgrade: websocket\r\n");
        try writeAll(&w, "Connection: Upgrade\r\n");
        try writeAll(&w, "Sec-WebSocket-Accept: ");
        try writeAll(&w, &accept);
        try writeAll(&w, "\r\n\r\n");
        self.w_len = w.end;
        self.w_off = 0;
        return self.w_len;
    }
```

- [ ] **Step 2: Add the dispatch branch** (in `step`, immediately after `var resp = d.dispatch(&p.request, self.arena);` at conn.zig:573, BEFORE the `pull_streamer` handling)

```zig
                            if (resp.upgrade) |up| {
                                self.ws_upgrade = up;
                                if (self.serializeUpgrade(up.accept)) |_| {} else |_| {
                                    // 101 won't fit (absurdly small write_buf) — 500 + close.
                                    self.ws_upgrade = null;
                                    var e500 = Response.fromStatus(.internal_server_error);
                                    e500.keep_alive = false;
                                    _ = self.serializeResponse(e500) catch {};
                                    self.close_after_write = true;
                                    self.state = .writing;
                                    continue;
                                }
                                self.state = .writing; // drain the 101, then signal upgraded
                                continue;
                            }
```

- [ ] **Step 3: Add the wrote_all check** (in the writing arm's "Normal (non-streaming) path", at conn.zig:793, as the FIRST statement before `self.served += 1;`)

```zig
                            // WebSocket: the 101 handshake finished writing — hand off
                            // to the worker, which switches this slot into WS mode.
                            if (self.ws_upgrade != null) return .upgraded;
```

- [ ] **Step 4: Add a FakeTransport unit test** (in the `conn.zig` test region)

```zig
test "Conn.step: an upgrade response serializes a 101 and returns .upgraded" {
    var ft = transport_mod.FakeTransport.init(testing.allocator,
        &.{"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"});
    defer ft.deinit();
    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);

    // Dispatcher that returns an upgrade Response (mimics the WebSocket extractor).
    const Disp = struct {
        var st: u8 = 0;
        fn onMsg(conn: *ws.WsConn, f: ws.Frame) void { _ = conn; _ = f; }
        fn dispatchFn(ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = ctx; _ = req; _ = ar;
            var accept: [28]u8 = undefined;
            _ = ws.acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
            var r = Response.fromStatus(.switching_protocols);
            r.upgrade = .{ .accept = accept, .handler = .{ .on_message = onMsg }, .state_ptr = @ptrCast(&st) };
            return r;
        }
    };
    const d = Dispatcher{ .ctx = undefined, .dispatchFn = Disp.dispatchFn };
    const t = ft.transport();
    const result = c.step(t, d);
    try testing.expectEqual(conn_StepResult_upgraded(), result); // see note
    try testing.expect(c.ws_upgrade != null);
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}
```

NOTE: write `result == .upgraded` directly (`try testing.expectEqual(StepResult.upgraded, result)`); the `conn_StepResult_upgraded()` placeholder above is just to flag that the enum value is `StepResult.upgraded`. Also: if `step` returns `.want_write` (the 101 didn't drain in one `pumpWrite` because `FakeTransport` wrote it all at once it will be `.upgraded`; FakeTransport writes accept fully), the test may need to call `step` again on the writable re-arm — but `FakeTransport.writeFn` writes everything in one call, so `pumpWrite` reaches `wrote_all` in one `step`, yielding `.upgraded` directly.

- [ ] **Step 5: Run, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the new conn test passes; the reactor still serves normal traffic (the upgrade branch is gated on `resp.upgrade`).

- [ ] **Step 6: Commit**

```bash
git add src/reactor/conn.zig
git commit -m "feat(ws): reactor conn detects upgrade, sends 101, returns .upgraded"
```

---

### Task 5: `src/reactor/ws_session.zig` — the evented WS driver

Create the non-blocking per-connection WS driver: read → pump → on_message, with bounded outbound buffering for backpressured sends. Deliverable: `WsSession.onReadable`/`onWritable` drive frames and handle partial writes, unit-tested with `FakeTransport`.

**Files:**
- Create: `src/reactor/ws_session.zig`

**Interfaces:**
- Consumes: `ws.{WsConn, Handler, Frame, Opcode, writeFrame, pump, SendError}`; `transport.{Transport, IoResult}`; `conn.StepResult`.
- Produces:
  - `WsSession.init(read_buf, out_buf, handler, state_ptr, arena) WsSession`
  - `WsSession.seed(bytes) void` (copy leftover post-handshake bytes into read_buf)
  - `WsSession.onOpen() void`, `onReadable(t) StepResult`, `onWritable(t) StepResult`, `onClose() void`
  - `WsSession.conn` (the evented `WsConn` whose vtable points back at the session)

- [ ] **Step 1: Write the failing tests** (create `src/reactor/ws_session.zig` with tests first)

```zig
//! Evented per-connection WebSocket driver. After the reactor sends the 101
//! (see conn.zig), the worker owns one of these per upgraded slot and routes
//! readable/writable events to it. Non-blocking: reads available bytes, parses
//! frames via ws.pump, calls on_message; sends are buffered into out_buf with
//! drain-on-writable backpressure (overflow -> close).

const std = @import("std");
const ws = @import("../ws.zig");
const transport_mod = @import("transport.zig");
const conn_mod = @import("conn.zig");

const Transport = transport_mod.Transport;
const StepResult = conn_mod.StepResult;

// (implementation in Step 3)

const testing = std.testing;

fn echoOnMessage(conn: *ws.WsConn, frame: ws.Frame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}

test "WsSession: a masked frame arriving in one read is echoed unmasked" {
    // zero mask key -> payload bytes unchanged
    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    var ft = transport_mod.FakeTransport.init(testing.allocator, &.{&text_frame});
    defer ft.deinit();
    var rbuf: [256]u8 = undefined;
    var obuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st: u8 = 0;
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator());
    const t = ft.transport();
    const r = sess.onReadable(t); // read the frame, echo it; next read -> closed handled separately
    // The echoed server frame is 0x81,0x02,'h','i'
    try testing.expect(std.mem.indexOf(u8, ft.written.items, &[_]u8{ 0x81, 0x02, 'h', 'i' }) != null);
    try testing.expect(r == .want_read or r == .done_close);
}

test "WsSession: a close frame yields done_close" {
    const close_frame = [_]u8{ 0x88, 0x80, 0x00, 0x00, 0x00, 0x00 };
    var ft = transport_mod.FakeTransport.init(testing.allocator, &.{&close_frame});
    defer ft.deinit();
    var rbuf: [64]u8 = undefined;
    var obuf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st: u8 = 0;
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator());
    try testing.expectEqual(StepResult.done_close, sess.onReadable(ft.transport()));
}

test "WsSession: backpressured send buffers and drains on writable" {
    // Force the transport to block after 2 written bytes so the echo can't fully send.
    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    var ft = transport_mod.FakeTransport.init(testing.allocator, &.{&text_frame});
    defer ft.deinit();
    ft.write_block_after_bytes = 2; // partial write of the 4-byte echo frame
    var rbuf: [64]u8 = undefined;
    var obuf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st: u8 = 0;
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator());
    const t = ft.transport();
    const r1 = sess.onReadable(t);
    try testing.expectEqual(StepResult.want_write, r1); // remainder buffered
    const r2 = sess.onWritable(t); // drain the rest
    try testing.expect(r2 == .want_read or r2 == .done_close);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, ft.written.items);
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — `WsSession` undefined.

- [ ] **Step 3: Implement `WsSession`** (insert above the test region)

```zig
pub const WsSession = struct {
    read_buf: []u8,
    r_start: usize = 0,
    r_end: usize = 0,
    out_buf: []u8,
    o_start: usize = 0,
    o_end: usize = 0,
    handler: ws.Handler,
    conn: ws.WsConn,
    cur_t: ?Transport = null, // set for the duration of onReadable/onWritable so send() can write
    closing: bool = false,

    const vtable = ws.WsConn.VTable{ .send = sendFn, .close = closeFn };

    pub fn init(read_buf: []u8, out_buf: []u8, handler: ws.Handler, state_ptr: *anyopaque, arena: std.mem.Allocator) WsSession {
        var s = WsSession{
            .read_buf = read_buf,
            .out_buf = out_buf,
            .handler = handler,
            .conn = undefined,
        };
        s.conn = ws.WsConn{ .ctx = undefined, .vtable = &vtable, .state_ptr = state_ptr, .arena = arena };
        return s;
    }
    // The caller must fix up `conn.ctx = &session` after the session is at its
    // final address (see `bind`), because `&self` inside init is the temporary.
    pub fn bind(self: *WsSession) void {
        self.conn.ctx = self;
    }

    /// Copy pipelined post-handshake bytes into the read buffer.
    pub fn seed(self: *WsSession, bytes: []const u8) void {
        @memcpy(self.read_buf[0..bytes.len], bytes);
        self.r_start = 0;
        self.r_end = bytes.len;
    }

    pub fn onOpen(self: *WsSession) void {
        if (self.handler.on_open) |f| f(&self.conn);
    }
    pub fn onClose(self: *WsSession) void {
        if (self.handler.on_close) |f| f(&self.conn);
    }

    /// Readable event: drain anything still pending out (it shouldn't, but be safe),
    /// then read available bytes and pump frames.
    pub fn onReadable(self: *WsSession, t: Transport) StepResult {
        self.cur_t = t;
        defer self.cur_t = null;

        // First, try any already-buffered frames (pipelined / seeded).
        if (ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler) == .closed)
            return .done_close;
        if (self.closing) return .done_close;

        // Read more, then pump again.
        if (self.r_end == self.read_buf.len) return .done_close; // frame larger than buffer
        switch (t.read(self.read_buf[self.r_end..])) {
            .ok => |n| {
                if (n == 0) return .done_close;
                self.r_end += n;
                if (ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler) == .closed)
                    return .done_close;
            },
            .would_block => {}, // nothing new; fall through
            .closed => return .done_close,
        }
        if (self.closing) return .done_close;
        // If a send backpressured, we owe a write before reading more.
        if (self.o_end > self.o_start) return .want_write;
        return .want_read;
    }

    /// Writable event: drain the outbound buffer; resume reading when empty.
    pub fn onWritable(self: *WsSession, t: Transport) StepResult {
        self.cur_t = t;
        defer self.cur_t = null;
        switch (self.drainOut(t)) {
            .closed => return .done_close,
            .blocked => return .want_write,
            .empty => return .want_read,
        }
    }

    // ---- send vtable ----
    fn sendFn(ctx: *anyopaque, opcode: ws.Opcode, payload: []const u8) ws.SendError!void {
        const self: *WsSession = @ptrCast(@alignCast(ctx));
        if (self.closing) return error.WriteFailed;
        // Serialize the frame into the tail of out_buf.
        var w = std.Io.Writer.fixed(self.out_buf[self.o_end..]);
        ws.writeFrame(&w, opcode, payload) catch {
            // out_buf overflow -> backpressure limit exceeded -> close.
            self.closing = true;
            return error.WriteFailed;
        };
        self.o_end += w.end;
        // Try to drain immediately if we have a transport (we do, inside onReadable).
        if (self.cur_t) |t| {
            switch (self.drainOut(t)) {
                .closed => {
                    self.closing = true;
                    return error.WriteFailed;
                },
                .blocked, .empty => {},
            }
        }
    }
    fn closeFn(ctx: *anyopaque) void {
        const self: *WsSession = @ptrCast(@alignCast(ctx));
        self.closing = true;
    }

    const DrainResult = enum { empty, blocked, closed };
    fn drainOut(self: *WsSession, t: Transport) DrainResult {
        while (self.o_start < self.o_end) {
            switch (t.write(self.out_buf[self.o_start..self.o_end])) {
                .ok => |n| self.o_start += n,
                .would_block => return .blocked,
                .closed => return .closed,
            }
        }
        self.o_start = 0;
        self.o_end = 0;
        return .empty;
    }
};
```

NOTE on `bind`: because `init` returns the session by value, `conn.ctx` cannot point at the final address inside `init`. The worker (Task 6) must call `session.bind()` once the `WsSession` is stored at its permanent slot address. The unit tests above store `sess` as a local — they must call `sess.bind()` after `init` (add that line to each test before the first `onReadable`).

- [ ] **Step 4: Fix the tests to call `bind()`**

Add `sess.bind();` immediately after each `WsSession.init(...)` in the Step-1 tests (before the first `onReadable`/`onWritable`).

- [ ] **Step 5: Run, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the three `WsSession` tests pass (echo, close→done_close, backpressure drain).

- [ ] **Step 6: Commit**

```bash
git add src/reactor/ws_session.zig
git commit -m "feat(ws): evented WsSession — non-blocking pump + bounded backpressure"
```

---

### Task 6: Worker wiring — `Slot.ws`, `.upgraded` handling, event routing, close, idle timeout + evented e2e

Wire the `WsSession` into the worker: switch a slot into WS mode on `.upgraded`, route its events, and close cleanly. Deliverable: a loopback echo over `app.serveEvented`.

**Files:**
- Modify: `src/reactor/worker.zig` (`Slot.ws` field + out buffer; `handleStepResult` `.upgraded`; `Worker.run` routing; `closeSlot`/`drainAll` on_close; `expiredCb` idle)
- Modify: `src/server.zig` (an evented WS echo e2e test)

**Interfaces:**
- Consumes: `ws_session.WsSession`, `conn.ws_upgrade`, `conn.read_buf[r_start..r_end]`, `sockTransport`, the poller/timer.

- [ ] **Step 1: Add `ws` + an out buffer to `Slot`**

In `src/reactor/worker.zig`, import the session and extend `Slot`:

```zig
const ws_session = @import("ws_session.zig");
// ... in Slot:
    ws: ?ws_session.WsSession = null,
    ws_out_buf: []u8 = &.{}, // outbound WS buffer (lazily allocated on upgrade)
```

In `ensureBuffers` (or on upgrade), allocate `ws_out_buf` the same size as `write_buf` when first needed:

```zig
    fn ensureWsOut(self: *Slot, gpa: std.mem.Allocator) !void {
        if (self.ws_out_buf.len == 0) self.ws_out_buf = try gpa.alloc(u8, self.write_size);
    }
```

Free `ws_out_buf` in `Slot.deinit` (`if (self.ws_out_buf.len != 0) gpa.free(self.ws_out_buf);`).

- [ ] **Step 2: Handle `.upgraded` in `handleStepResult`**

Add a case to the `switch (result)`:

```zig
            .upgraded => {
                const slot = &self.slots[slot_idx];
                const up = c.ws_upgrade.?;
                self.ensureSlotWsOut(slot_idx) catch {
                    self.closeSlot(slot_idx, fd);
                    return;
                };
                slot.ws = ws_session.WsSession.init(
                    slot.read_buf, slot.ws_out_buf, up.handler, up.state_ptr, slot.arena.allocator(),
                );
                slot.ws.?.bind();
                // Seed with pipelined post-handshake bytes (conn.read_buf[r_start..r_end]).
                slot.ws.?.seed(c.read_buf[c.r_start..c.r_end]);
                slot.ws.?.onOpen();
                // Arm read; set idle deadline.
                self.poller.mod(fd, @intCast(slot_idx), true, false) catch {
                    self.closeWsSlot(slot_idx, fd);
                    return;
                };
                self.armWsIdle(slot_idx, c);
            },
```

Add helpers (near `closeSlot`):

```zig
    fn ensureSlotWsOut(self: *Worker, slot_idx: usize) !void {
        try self.slots[slot_idx].ensureWsOut(self.gpa);
    }
    fn armWsIdle(self: *Worker, slot_idx: usize, c: *Conn) void {
        if (c.idle_timeout_ms == 0) { self.timer.remove(slot_idx); return; }
        c.deadline_ns = monotonicNow() + @as(i96, c.idle_timeout_ms) * 1_000_000;
        self.timer.insert(slot_idx, c.deadline_ns);
    }
    /// Close a WS slot, firing on_close first.
    fn closeWsSlot(self: *Worker, slot_idx: usize, fd: i32) void {
        const slot = &self.slots[slot_idx];
        if (slot.ws) |*sess| sess.onClose();
        slot.ws = null;
        self.closeSlot(slot_idx, fd);
    }
```

(`monotonicNow` is already used in this file; reuse it.)

- [ ] **Step 3: Route events to the session in `Worker.run`**

Replace the connection-event block (`worker.zig:328–344`) so a WS slot routes to its session:

```zig
                } else {
                    const slot_idx: usize = @intCast(ev.data);
                    if (slot_idx >= self.opts.max_connections) continue;
                    const slot = &self.slots[slot_idx];
                    if (!slot.active) continue;
                    const fd = slot.fd;

                    if (ev.hup) {
                        if (slot.ws != null) self.closeWsSlot(slot_idx, fd) else self.closeSlot(slot_idx, fd);
                        continue;
                    }

                    const t = sockTransport(fd);
                    if (slot.ws != null) {
                        const result = if (ev.writable)
                            slot.ws.?.onWritable(t)
                        else
                            slot.ws.?.onReadable(t);
                        // Refresh idle deadline on activity, then re-arm.
                        if (result != .done_close) self.armWsIdle(slot_idx, &slot.conn);
                        switch (result) {
                            .want_read => self.poller.mod(fd, @intCast(slot_idx), true, false) catch self.closeWsSlot(slot_idx, fd),
                            .want_write => self.poller.mod(fd, @intCast(slot_idx), false, true) catch self.closeWsSlot(slot_idx, fd),
                            .want_stream_repoll => {}, // not used for WS
                            .upgraded => {}, // not reachable for WS
                            .done_close => self.closeWsSlot(slot_idx, fd),
                        }
                        continue;
                    }

                    const result = slot.conn.step(t, self.dispatcher);
                    self.handleStepResult(slot_idx, fd, result, &slot.conn);
                }
```

(`ev.writable` is part of the decoded `Event`; if the poller's `Event` exposes the writable flag under a different name, use that — check `poller_mod.eventFromRaw`'s returned struct.)

- [ ] **Step 4: Fire `on_close` for WS slots in `drainAll`** (graceful shutdown)

In `drainAll`, before closing each active slot, fire on_close for WS slots:

```zig
        for (self.slots, 0..) |*slot, i| {
            if (!slot.active) continue;
            if (slot.ws) |*sess| { sess.onClose(); slot.ws = null; }
            self.poller.del(slot.fd);
            // ... unchanged ...
        }
```

- [ ] **Step 5: Fire `on_close` on idle-timeout expiry**

In `expiredCb` (the timer callback), if the expired slot is a WS slot, close via `closeWsSlot` instead of `onDeadline`. Locate `expiredCb` and add at its top (after fetching the slot):

```zig
        if (slot.ws != null) { worker.closeWsSlot(slot_idx, slot.fd); return; }
```

(Match `expiredCb`'s actual signature/closure for reaching the `Worker`. If `expiredCb` is a free function taking a context, thread the worker pointer as it already does for `onDeadline`.)

- [ ] **Step 6: Write the evented echo e2e** (in `src/server.zig` test region)

```zig
test "end-to-end (evented): websocket upgrade, handshake, and echo" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18098;
    // Launch the evented backend (1 worker is enough for the test).
    var ev = try app.serveEventedStart(io, .{ .ip4 = .loopback(port) }, 1); // see note
    defer ev.stop(io);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    cw.interface.writeAll(upgrade_req) catch unreachable;
    cw.interface.flush() catch unreachable;

    var tries: usize = 0;
    while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) : (tries += 1) {
        if (tries > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    const head_end = std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n").? + 4;
    try testing.expect(std.mem.indexOf(u8, cr.interface.buffered()[0..head_end], "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, cr.interface.buffered()[0..head_end], "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    cr.interface.toss(head_end);

    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    cw.interface.writeAll(&text_frame) catch unreachable;
    cw.interface.flush() catch unreachable;

    var t2: usize = 0;
    while (cr.interface.buffered().len < 4) : (t2 += 1) {
        if (t2 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, cr.interface.buffered()[0..4]);
}
```

NOTE (serveEvented launch helper): the test references `app.serveEventedStart(...)` / `ev.stop(...)` as a stand-in. Use whatever the existing `serveEvented` e2e tests (`server.zig:2946+`) use to start the evented backend on a background thread and stop it — mirror that exact harness (it already exists for the evented HTTP e2e). If the existing harness blocks (`serveEvented` runs the workers inline), start it via `io.async` like the threaded `startTestApp`, and signal shutdown with `app.requestShutdown(io)` + awaiting the future, exactly as the evented HTTP e2e does. Do NOT invent a new launch API — reuse the established one.

- [ ] **Step 7: Run, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the evented echo e2e passes (real loopback through the reactor); the threaded echo e2e still passes; all reactor HTTP tests still pass.

- [ ] **Step 8: Commit**

```bash
git add src/reactor/worker.zig src/server.zig
git commit -m "feat(ws): reactor worker drives WsSession — evented upgrade + echo e2e"
```

---

### Task 7: Docs + version bump (v0.15.0)

Document both-backend WebSocket and the API change; bump the version. Deliverable: README/CHANGELOG/getting-started reflect the unified callback API on both backends; `build.zig.zon` is `0.15.0`.

**Files:**
- Modify: `build.zig.zon` (`.version = "0.14.0"` → `"0.15.0"`)
- Modify: `README.md`, `CHANGELOG.md`, `docs/getting-started.md`

**Interfaces:**
- Consumes: the public API from Tasks 1–6 (`zax.WebSocket`, `zax.WsHandler`, `zax.WsConn`).
- Produces: nothing (docs/version only).

- [ ] **Step 1: Bump the version** (`build.zig.zon`)

```zig
    .version = "0.15.0",
```

- [ ] **Step 2: Update the README WebSocket section** (`README.md`)

Replace the `## WebSocket (in progress)` body with:

```markdown
## WebSocket (in progress)

WebSocket runs on **both** server backends — threaded (`app.serve`) and evented
(`app.serveEvented`). Declare an endpoint with the `WebSocket` extractor and supply
a handler: `on_message` is required; `on_open` and `on_close` are optional.

```zig
fn echo(conn: *zax.WsConn, frame: zax.WsFrame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}

fn handler(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(.{ .on_message = echo }); // .on_open / .on_close optional
}
// app.get("/echo", handler);  -> identical under app.serve and app.serveEvented
```

The server performs the RFC 6455 handshake, then calls your `on_message` once per
client frame (`conn.send(opcode, payload)` writes a frame back; `conn.state(T)`
reaches app state; `conn.close()` ends the connection). One frame per callback (no
reassembly yet); a close frame, EOF, or protocol error ends the connection (firing
`on_close`). Non-upgrade requests to a WebSocket route get `426 Upgrade Required`.
Still to come: fragmentation reassembly, automatic ping/pong and the RFC close
handshake, configurable frame-size caps, and cross-connection broadcast.
```

- [ ] **Step 3: CHANGELOG** (`CHANGELOG.md`, under `## [Unreleased]`)

Add under `### Added`:

```markdown
- **Evented WebSocket support** — WebSocket handlers now run on the evented (reactor) backend (`app.serveEvented`) as well as the threaded backend, with the same handler. The reactor performs the handshake non-blocking and drives the handler per readable event; `conn.send` is non-blocking with bounded outbound buffering (drained on writable; closes on overflow).
```

Add a `### Changed` section (above `### Added` if none exists):

```markdown
### Changed

- **WebSocket handler API unified (breaking).** The blocking `while (conn.read())` loop is replaced by a callback handler: `onUpgrade(.{ .on_message = fn, .on_open = ?fn, .on_close = ?fn })`. `WsConn.read()` is removed; `WsConn` now exposes `send`/`close`/`state`. The same handler runs on both `app.serve` and `app.serveEvented`. (Pre-1.0 API change.)
```

- [ ] **Step 4: getting-started** (`docs/getting-started.md`)

Replace the WebSocket echo section's code with the callback form:

```markdown
## WebSocket echo (threaded or evented)

```zig
fn echo(conn: *zax.WsConn, frame: zax.WsFrame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}

fn handler(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(.{ .on_message = echo });
}

// try app.get("/echo", handler);  -> works under app.serve and app.serveEvented
```

The server handshakes, then calls `echo` once per client frame. A close frame or
disconnect ends the connection.
```

- [ ] **Step 5: Verify the build is still green**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add build.zig.zon README.md CHANGELOG.md docs/getting-started.md
git commit -m "docs(ws): evented WebSocket + unified callback API; bump to 0.15.0"
```

---

## Self-Review

**Spec coverage:**
- Unified `WsHandler{on_open?, on_message, on_close?}` driving both backends → Tasks 1 (core), 3 (threaded), 6 (evented). ✓
- `WsConn` vtable handle (send/close/state); `read()` removed → Task 1. ✓
- Shared `pump` frame loop → Task 1; used by threaded (Task 3) and evented (Task 5). ✓
- `Upgrade{accept, handler, state_ptr}` + extractor `onUpgrade(handler)` + state capture → Tasks 1–2. ✓
- Reactor `resp.upgrade` → 101 → `StepResult.upgraded` → Task 4. ✓
- `reactor/ws_session.zig` non-blocking read/pump/on_message + bounded backpressure → Task 5. ✓
- Worker `Slot.ws`, `.upgraded` init, event routing, close→on_close, idle timeout → Task 6. ✓
- 426 for non-upgrade (already shipped; extractor path unchanged) → reused, no task needed. ✓
- Both e2e (threaded updated, evented new) → Tasks 3, 6. ✓
- Docs + version 0.15.0 → Task 7. ✓
- No auto-pong/close-reply/reassembly (slice 4) → `pump` semantics, Global Constraints. ✓

**Placeholder scan:** The plan flags two spots needing implementer judgment with explicit guidance, not silent gaps: (a) the `TestSink`/`end`-recomputation simplification in Task 1 Step 2; (b) the `serveEventedStart`/`ev.stop` stand-in in Task 6 Step 6 (reuse the existing evented HTTP e2e harness). Both name exactly what to do. The `expiredCb` and `ev.writable` edits say "match the actual signature/field name" because they depend on local names in `worker.zig`/`poller` the implementer will read. All code blocks are otherwise complete.

**Type consistency:** `WsConn{ctx, vtable, state_ptr, arena}` + `VTable{send,close}`, `Handler{on_open?,on_message,on_close?}`, `Upgrade{accept,handler,state_ptr}`, `SendError=error{WriteFailed}`, `pump(buf,*start,*end,*WsConn,Handler) PumpResult`, `StepResult.upgraded`, `WsSession.{init,bind,seed,onOpen,onReadable,onWritable,onClose}` — consistent across Tasks 1/3/4/5/6. `state(T)` is a direct `@ptrCast` everywhere (app state is a pointer; `Upgrade.state_ptr` set via `@ptrCast(ctx.state)`). The threaded and evented send vtables both satisfy `VTable.send`'s signature.

**Cross-file compile note (recorded for the controller):** Tasks 1–3 form one compile unit — removing `WsConn.read()` breaks `server.zig`/`websocket.zig` until Tasks 2–3 land. The full suite is expected RED between Task 1 and Task 3 and GREEN at the end of Task 3. Each task still commits independently; the task reviewer for Tasks 1–2 should verify the code against the spec rather than requiring a green full-suite mid-sequence (the implementer reports `ws.zig`'s own tests + which call sites remain to update).

**Note on `state(T)` mechanism change vs the spec:** the spec sketched `state(T)` as `@as(*T, @ptrCast(...)).*` (deref of `&app.state`). The plan refines this to a **direct** `@ptrCast` of `Upgrade.state_ptr` (the app-state pointer captured from `ctx.state`), because the reactor worker cannot reach `&app.state` type-erased but the extractor can capture `ctx.state`. Behavior is identical (`state(T)` returns the app-state pointer); the mechanism is uniform across both backends. This is an implementation refinement, not a behavior change.
