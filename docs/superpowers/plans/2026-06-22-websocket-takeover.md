# WebSocket Threaded Upgrade + Takeover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the slice-1 RFC 6455 codec into the threaded server: an Axum-style `WebSocket` extractor whose `onUpgrade(cb)` hands a live `WsConn` to a user callback after the server performs the handshake and takes over the socket.

**Architecture:** The handler reuses the normal extractor/dispatch path. `WebSocket.fromContext` validates the handshake headers; `onUpgrade(cb)` returns a `Response` carrying an `Upgrade{accept, cb}` payload. `handleConn` (the only scope that owns the socket) detects `resp.upgrade`, writes the `101` by hand, builds a `WsConn` over the connection's existing read buffer (seeded with any pipelined bytes), and invokes the callback. `WsConn.read()` parses one client frame at a time (unmasking in place); `WsConn.send()` serializes one server frame. Single-threaded per connection; threaded backend only (reactor untouched).

**Tech Stack:** Zig 0.16.0; `std.net.Socket.receiveTimeout`, `std.Io.Writer`, `std.ascii.indexOfIgnoreCase`; the slice-1 `src/ws.zig` codec.

## Global Constraints

- Zig `0.16.0`. This slice ships as **v0.14.0** (bump `build.zig.zon` in Task 4 — currently `0.13.0`).
- **Threaded backend only.** ZERO changes to `src/reactor/*` or the evented path (`serveEvented`).
- **Additive:** new file `src/extract/websocket.zig`; `WsConn`/`Upgrade`/`Handler` added to `src/ws.zig`; one optional field on `Response`; one `handleConn` branch; one `error.zig` classify arm; root exports. No existing route/handler behavior changes; non-upgrade traffic is gated out (`resp.upgrade == null`).
- **Import direction:** `response.zig` → `ws.zig` and `extract/websocket.zig` → {`ws.zig`, `response.zig`}. `ws.zig` imports only `std` (never `response`/`server`). Do not introduce a cycle.
- **`conn.read()` returns single FRAMES** (no reassembly); returns `null` on a close frame, EOF, or any parse/read error. **No auto-pong, no RFC close-reply** (slice 4) — loop end → raw TCP close.
- **Unmask in place:** `WsConn.read` returns a `Frame` whose `payload` borrows the read buffer; valid only until the next `read()`.
- **Single-threaded per connection:** `conn.send()` only from inside the callback. No registry, no cross-thread send.
- **Max frame size** = the connection read buffer (`Options.read_buffer_size`); a frame that can't fit → `read()` returns `null`. Configurable cap is slice 4.
- **State type-erasure:** `WsConn.state(T)` requires `T` be the app-state type the router is parameterized by (`App(AppState)` → `T == AppState`, typically a pointer).
- RFC handshake: `acceptKey("dGhlIHNhbXBsZSBub25jZQ==")` == `"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`.
- Tests live **in-file** as `test "..."` blocks (`src/root.zig`'s `refAllDecls` pulls them in). Build/test: `zig build test --summary all`.

---

## File Structure

- **`src/ws.zig`** (modify) — append `Handler`, `Upgrade`, `WsConn` (read/send/state/compact) + unit tests. Codec stays; gains `std.net`/`std.Io` use only.
- **`src/http/response.zig`** (modify) — import `ws.zig`; add `upgrade: ?ws.Upgrade = null`.
- **`src/extract/websocket.zig`** (create) — the `WebSocket` extractor (`fromContext`, `onUpgrade`) + unit tests.
- **`src/error.zig`** (modify) — one `classify` arm: `error.NotWebSocketUpgrade` → `426`.
- **`src/server.zig`** (modify) — `handleConn` takeover branch + the echo e2e test.
- **`src/root.zig`** (modify) — `pub const WebSocket`, `pub const WsConn`.
- **`README.md` / `CHANGELOG.md` / `docs/getting-started.md` / `build.zig.zon`** (modify, Task 4).

Tasks build bottom-up so each compiles and tests alone: WsConn → extractor+Response field+classify → handleConn wiring+e2e → docs+version.

---

### Task 1: `WsConn` + `Upgrade` + `Handler` in `src/ws.zig`

Append the connection layer to the slice-1 codec module. Deliverable: `WsConn.read` parses buffered client frames (close/protocol-error → `null`), `WsConn.send` writes a server frame, `WsConn.state` returns the app-state pointer — all unit-tested over seeded buffers.

**Files:**
- Modify: `src/ws.zig` (append after `writeFrame`, before the slice-1 test block; tests go in the test region)
- Modify: `src/root.zig` (add `pub const WsConn` in the WebSocket block)

**Interfaces:**
- Consumes: `Opcode`, `Frame`, `parseFrame`, `writeFrame` (slice 1); the file-scope `buildMaskedFrame` test helper (slice 1).
- Produces:
  - `pub const Handler = *const fn (conn: *WsConn) void`
  - `pub const Upgrade = struct { accept: [28]u8, cb: Handler }`
  - `pub const WsConn = struct { io: std.Io, socket: std.net.Socket, w: *std.Io.Writer, buf: []u8, start: usize, end: usize, state_ptr: *anyopaque, arena: std.mem.Allocator, idle_timeout: std.Io.Timeout, pub fn read(*WsConn) ?Frame, pub fn send(*WsConn, Opcode, []const u8) std.Io.Writer.Error!void, pub fn state(*WsConn, comptime T: type) T }`
  - In root: `pub const WsConn = ws.WsConn`

- [ ] **Step 1: Write the failing tests** (append to the test region of `src/ws.zig`)

```zig
test "ws: WsConn.read returns a buffered masked text frame" {
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 1, 2, 3, 4 };
    const frame = buildMaskedFrame(&buf, true, .text, key, "hello");
    var st: u8 = 0;
    var conn = WsConn{ .io = undefined, .socket = undefined, .w = undefined, .buf = &buf,
        .start = 0, .end = frame.len, .state_ptr = @ptrCast(&st),
        .arena = std.testing.allocator, .idle_timeout = undefined };
    const f = conn.read() orelse return error.TestUnexpectedResult;
    try std.testing.expect(f.fin);
    try std.testing.expectEqual(Opcode.text, f.opcode);
    try std.testing.expectEqualStrings("hello", f.payload);
}

test "ws: WsConn.read returns two pipelined frames then null on close" {
    var buf: [128]u8 = undefined;
    const key = [4]u8{ 9, 9, 9, 9 };
    const f1 = buildMaskedFrame(buf[0..], true, .text, key, "aa");
    const f2 = buildMaskedFrame(buf[f1.len..], true, .close, key, "");
    var st: u8 = 0;
    var conn = WsConn{ .io = undefined, .socket = undefined, .w = undefined, .buf = &buf,
        .start = 0, .end = f1.len + f2.len, .state_ptr = @ptrCast(&st),
        .arena = std.testing.allocator, .idle_timeout = undefined };
    const a = conn.read() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("aa", a.payload);
    try std.testing.expectEqual(@as(?Frame, null), conn.read()); // close frame -> null, no recv
}

test "ws: WsConn.read returns null on a protocol error (unmasked client frame)" {
    var buf = [_]u8{ 0x81, 0x03, 'a', 'b', 'c' }; // FIN+text, mask bit 0, len 3
    var st: u8 = 0;
    var conn = WsConn{ .io = undefined, .socket = undefined, .w = undefined, .buf = &buf,
        .start = 0, .end = buf.len, .state_ptr = @ptrCast(&st),
        .arena = std.testing.allocator, .idle_timeout = undefined };
    try std.testing.expectEqual(@as(?Frame, null), conn.read());
}

test "ws: WsConn.send writes an unmasked server frame" {
    var out: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    var st: u8 = 0;
    var conn = WsConn{ .io = undefined, .socket = undefined, .w = &w, .buf = &.{},
        .start = 0, .end = 0, .state_ptr = @ptrCast(&st),
        .arena = std.testing.allocator, .idle_timeout = undefined };
    try conn.send(.text, "Hi");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'H', 'i' }, w.buffered());
}

test "ws: WsConn.state returns the app-state pointer" {
    const Db = struct { n: u8 };
    var db = Db{ .n = 7 };
    var sp: *Db = &db;
    var conn = WsConn{ .io = undefined, .socket = undefined, .w = undefined, .buf = &.{},
        .start = 0, .end = 0, .state_ptr = @ptrCast(&sp),
        .arena = std.testing.allocator, .idle_timeout = undefined };
    try std.testing.expectEqual(@as(*Db, &db), conn.state(*Db));
}
```

- [ ] **Step 2: Run them, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — `WsConn` (and `Handler`/`Upgrade`) not defined.

- [ ] **Step 3: Implement `Handler`, `Upgrade`, `WsConn`** (insert after `writeFrame`, before the slice-1 test block)

```zig
/// The server-side callback invoked after a successful upgrade. Runs on the
/// connection's own thread and owns the socket for its lifetime.
pub const Handler = *const fn (conn: *WsConn) void;

/// Carried on a `Response` to signal "take over this connection". Built by
/// `WebSocket.onUpgrade`; consumed by the server's `handleConn`.
pub const Upgrade = struct {
    accept: [28]u8, // precomputed Sec-WebSocket-Accept (by value — no borrow)
    cb: Handler,
};

/// A live, taken-over WebSocket connection. Single-threaded: only the callback's
/// thread touches it. Reads one frame per `read()` over `buf`, recv'ing more from
/// the socket as needed; `payload` borrows `buf` until the next `read()`.
pub const WsConn = struct {
    io: std.Io,
    socket: std.net.Socket,
    w: *std.Io.Writer,
    buf: []u8, // staging buffer; max frame size == buf.len
    start: usize = 0, // unconsumed window [start, end)
    end: usize = 0,
    state_ptr: *anyopaque,
    arena: std.mem.Allocator,
    idle_timeout: std.Io.Timeout,

    fn compact(self: *WsConn) void {
        if (self.start == 0) return;
        const len = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..len], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = len;
    }

    /// Next frame, or null on a close frame / EOF / parse-or-read error. The
    /// returned `payload` borrows `buf` and is valid only until the next read().
    pub fn read(self: *WsConn) ?Frame {
        while (true) {
            if (self.end > self.start) {
                if (parseFrame(self.buf[self.start..self.end])) |parsed| {
                    self.start += parsed.consumed;
                    if (parsed.frame.opcode == .close) return null;
                    return parsed.frame;
                } else |e| switch (e) {
                    error.Incomplete => {}, // fall through to recv
                    else => return null, // protocol error -> end the loop
                }
            }
            self.compact();
            if (self.end == self.buf.len) return null; // frame larger than buffer
            const msg = self.socket.receiveTimeout(self.io, self.buf[self.end..], self.idle_timeout) catch return null;
            if (msg.data.len == 0) return null; // EOF
            self.end += msg.data.len;
        }
    }

    /// Serialize one unmasked server frame and flush.
    pub fn send(self: *WsConn, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void {
        try writeFrame(self.w, opcode, payload);
        try self.w.flush();
    }

    /// App state, type-erased. `T` MUST be the app-state type the router is
    /// parameterized by (typically a pointer, e.g. `*Db`).
    pub fn state(self: *WsConn, comptime T: type) T {
        return @as(*T, @ptrCast(@alignCast(self.state_ptr))).*;
    }
};
```

- [ ] **Step 4: Run the tests, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — 5 new `WsConn` tests green plus the slice-1 suite.

- [ ] **Step 5: Export `WsConn` from root** (`src/root.zig`, in the `// --- WebSocket (Phase 5) ---` block, under `WsFrame`)

```zig
pub const WsConn = ws.WsConn;
```

- [ ] **Step 6: Run the suite again, expect PASS**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add src/ws.zig src/root.zig
git commit -m "feat(ws): WsConn (read/send/state) + Upgrade/Handler types"
```

---

### Task 2: `WebSocket` extractor + `Response.upgrade` + 426 classification

Add the extractor that validates the handshake and produces the upgrade `Response`, the optional field that carries it, and the error→status mapping. Deliverable: `WebSocket.fromContext` accepts/rejects handshake requests, `onUpgrade` builds a `101` response with the right accept value, and a rejected upgrade classifies to `426`.

**Files:**
- Create: `src/extract/websocket.zig`
- Modify: `src/http/response.zig` (import `ws`; add the `upgrade` field)
- Modify: `src/error.zig` (one `classify` arm)
- Modify: `src/root.zig` (add `pub const WebSocket`)

**Interfaces:**
- Consumes: `ws.Upgrade`, `ws.Handler`, `ws.acceptKey` (Task 1 / slice 1); `Response.fromStatus`; `Context` (`ctx.req.header(name)` — case-insensitive).
- Produces:
  - `pub const WebSocket = struct { key: []const u8, pub const zax_is_extractor = true, pub const zax_is_body = false, pub fn fromContext(ctx) error{NotWebSocketUpgrade}!WebSocket, pub fn onUpgrade(self, cb: ws.Handler) Response }`
  - `Response.upgrade: ?ws.Upgrade = null`
  - `classify(error.NotWebSocketUpgrade).status == .upgrade_required`
  - In root: `pub const WebSocket = @import("extract/websocket.zig").WebSocket`

- [ ] **Step 1: Add the `upgrade` field to `Response`** (`src/http/response.zig`)

Near the top imports add:

```zig
const ws = @import("../ws.zig");
```

In the `Response` struct, alongside the other optional fields (e.g. right after the `pull_streamer` field), add:

```zig
    /// Set by the `WebSocket` extractor's `onUpgrade` to signal a protocol
    /// takeover. When present, the threaded server writes the 101 handshake and
    /// hands the socket to `upgrade.cb` instead of writing this as a normal
    /// response. Ignored by the generic serializer.
    upgrade: ?ws.Upgrade = null,
```

- [ ] **Step 2: Add the classify arm** (`src/error.zig`, in `classify`, in the extractor-tags group)

```zig
        error.NotWebSocketUpgrade => .{ .status = .upgrade_required, .reason = "upgrade required" },
```

- [ ] **Step 3: Write the failing extractor + classify tests**

Create `src/extract/websocket.zig` with ONLY the tests first (so the build fails on the missing `WebSocket` type and the new behavior):

```zig
//! `WebSocket` extractor (RFC 6455 handshake). Used in a normal handler; its
//! `onUpgrade(cb)` returns a Response that the threaded server turns into a 101 +
//! socket takeover (see `server.zig` handleConn). Validation only here — framing
//! lives in `ws.zig`, takeover in the server.

const std = @import("std");
const ws = @import("../ws.zig");
const Response = @import("../http/response.zig").Response;
const classify = @import("../error.zig").classify;

// (implementation inserted in Step 5)

const testing = std.testing;

// Minimal fake request exposing the case-insensitive `header` lookup the
// extractor uses, so fromContext can be tested without a full server.
const FakeReq = struct {
    pairs: []const [2][]const u8,
    fn header(self: *const FakeReq, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
        return null;
    }
};

fn ctxWith(req: *const FakeReq) struct { req: *const FakeReq } {
    return .{ .req = req };
}

const valid_pairs = [_][2][]const u8{
    .{ "Upgrade", "websocket" },
    .{ "Connection", "Upgrade" },
    .{ "Sec-WebSocket-Version", "13" },
    .{ "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==" },
};

test "WebSocket.fromContext accepts a valid handshake" {
    const req = FakeReq{ .pairs = &valid_pairs };
    const w = try WebSocket.fromContext(ctxWith(&req));
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", w.key);
}

test "WebSocket.fromContext rejects each missing handshake header" {
    // Drop one header at a time; each omission must reject.
    inline for (.{ "Upgrade", "Connection", "Sec-WebSocket-Version", "Sec-WebSocket-Key" }) |drop| {
        var pairs: [3][2][]const u8 = undefined;
        var i: usize = 0;
        inline for (valid_pairs) |p| {
            if (!std.mem.eql(u8, p[0], drop)) {
                pairs[i] = p;
                i += 1;
            }
        }
        const req = FakeReq{ .pairs = &pairs };
        try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&req)));
    }
}

test "WebSocket.fromContext rejects a non-13 version" {
    const pairs = [_][2][]const u8{
        .{ "Upgrade", "websocket" }, .{ "Connection", "Upgrade" },
        .{ "Sec-WebSocket-Version", "8" }, .{ "Sec-WebSocket-Key", "x" },
    };
    const req = FakeReq{ .pairs = &pairs };
    try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&req)));
}

test "WebSocket.onUpgrade builds a 101 with the RFC accept value" {
    const req = FakeReq{ .pairs = &valid_pairs };
    const w = try WebSocket.fromContext(ctxWith(&req));
    const dummy = struct {
        fn run(_: *ws.WsConn) void {}
    }.run;
    const resp = w.onUpgrade(dummy);
    try testing.expectEqual(Response.Status.switching_protocols, resp.status);
    try testing.expect(resp.upgrade != null);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &resp.upgrade.?.accept);
}

test "classify maps NotWebSocketUpgrade to 426" {
    try testing.expectEqual(
        @import("../http/response.zig").Status.upgrade_required,
        classify(error.NotWebSocketUpgrade).status,
    );
}
```

- [ ] **Step 4: Run, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — `WebSocket` undefined (and `src/extract/websocket.zig` not yet imported anywhere; see Step 6 for wiring).

- [ ] **Step 5: Implement the extractor** (insert in `src/extract/websocket.zig` after the imports, before the tests)

```zig
/// RFC 6455 upgrade handshake extractor. `fromContext` validates the request;
/// `onUpgrade` attaches the takeover callback to a 101 Response.
pub const WebSocket = struct {
    /// Sec-WebSocket-Key (borrows request memory; consumed only in `onUpgrade`).
    key: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{NotWebSocketUpgrade}!@This() {
        const up = ctx.req.header("upgrade") orelse return error.NotWebSocketUpgrade;
        if (std.ascii.indexOfIgnoreCase(up, "websocket") == null) return error.NotWebSocketUpgrade;

        const conn = ctx.req.header("connection") orelse return error.NotWebSocketUpgrade;
        if (std.ascii.indexOfIgnoreCase(conn, "upgrade") == null) return error.NotWebSocketUpgrade;

        const ver = ctx.req.header("sec-websocket-version") orelse return error.NotWebSocketUpgrade;
        if (!std.mem.eql(u8, ver, "13")) return error.NotWebSocketUpgrade;

        const key = ctx.req.header("sec-websocket-key") orelse return error.NotWebSocketUpgrade;
        return .{ .key = key };
    }

    pub fn onUpgrade(self: @This(), cb: ws.Handler) Response {
        var accept: [28]u8 = undefined;
        _ = ws.acceptKey(self.key, &accept);
        var r = Response.fromStatus(.switching_protocols);
        r.upgrade = .{ .accept = accept, .cb = cb };
        return r;
    }
};
```

- [ ] **Step 6: Wire the module into the build + root export** (`src/root.zig`)

In the `// --- WebSocket (Phase 5) ---` block add:

```zig
pub const WebSocket = @import("extract/websocket.zig").WebSocket;
```

(This import is what pulls `src/extract/websocket.zig`'s tests into `zig build test` via root's `refAllDecls`.)

- [ ] **Step 7: Run, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — extractor + classify tests green, slice-1 + Task-1 suites green.

- [ ] **Step 8: Commit**

```bash
git add src/extract/websocket.zig src/http/response.zig src/error.zig src/root.zig
git commit -m "feat(ws): WebSocket upgrade extractor + Response.upgrade + 426"
```

---

### Task 3: `handleConn` takeover branch + echo e2e

Detect `resp.upgrade` in the threaded connection loop, write the `101`, build a `WsConn` over the existing read buffer, and run the callback. Deliverable: a real loopback echo — client upgrades, the server returns `101` with the correct accept, then echoes a frame.

**Files:**
- Modify: `src/server.zig` (`handleConn`: add the upgrade branch after `dispatch`; add `const ws = @import("ws.zig");` and a test-scope `const WebSocket = @import("extract/websocket.zig").WebSocket;` if not already imported; add the e2e test)

**Interfaces:**
- Consumes: `resp.upgrade` (Task 2); `ws.WsConn` (Task 1); `cr` (`ConnReader`: `buffered`/`consume`/`compact`), `stream.socket` (`net.Socket`), `w` (`*Io.Writer`), `idle_to` (`Io.Timeout`), `consumed`, `self.state`.
- Produces: end-to-end takeover behavior (no new public API).

- [ ] **Step 1: Write the failing echo e2e** (append to the test region of `src/server.zig`)

```zig
fn wsEchoHandler(sock: @import("extract/websocket.zig").WebSocket) Response {
    return sock.onUpgrade(struct {
        fn run(conn: *@import("ws.zig").WsConn) void {
            while (conn.read()) |f| conn.send(f.opcode, f.payload) catch break;
        }
    }.run);
}

test "end-to-end: websocket upgrade, handshake, and echo" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18097;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // 1. Send the handshake and assert 101 + accept value.
    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    cw.interface.writeAll(upgrade_req) catch unreachable;
    cw.interface.flush() catch unreachable;
    while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) {
        cr.interface.fillMore() catch unreachable;
    }
    const head_end = std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n").? + 4;
    const head = cr.interface.buffered()[0..head_end];
    try testing.expect(std.mem.indexOf(u8, head, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    cr.interface.toss(head_end);

    // 2. Send a masked text frame "hi" (zero mask key -> payload bytes unchanged).
    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    cw.interface.writeAll(&text_frame) catch unreachable;
    cw.interface.flush() catch unreachable;

    // 3. Read the echoed unmasked server frame: 0x81, 0x02, 'h', 'i'.
    while (cr.interface.buffered().len < 4) cr.interface.fillMore() catch unreachable;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, cr.interface.buffered()[0..4]);
    cr.interface.toss(4);

    // 4. Send a masked close frame; the server ends the loop and closes the socket.
    const close_frame = [_]u8{ 0x88, 0x80, 0x00, 0x00, 0x00, 0x00 };
    cw.interface.writeAll(&close_frame) catch unreachable;
    cw.interface.flush() catch unreachable;
    // After close, the server closes -> the client read sees EOF (fillMore errors).
    const eof = blk: {
        cr.interface.fillMore() catch break :blk true;
        break :blk cr.interface.buffered().len == 0;
    };
    try testing.expect(eof);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — the server still treats the `101` as a normal response (no takeover), so the echo never arrives (the assertion on the echoed frame fails or the read blocks/EOFs early).

- [ ] **Step 3: Ensure the `ws` import exists in `src/server.zig`**

Near the other top-level imports add (if not already present):

```zig
const ws = @import("ws.zig");
```

- [ ] **Step 4: Add the takeover branch in `handleConn`** (`src/server.zig`)

Immediately after `var resp = self.dispatch(io, &parsed.request, &arena, rid);` and **before** the `x-request-id` injection / `streamed` / `writeResponse` logic, insert:

```zig
                if (resp.upgrade) |up| {
                    // Write the 101 handshake by hand (the generic Response writer
                    // would emit content-length: 0 and connection: close).
                    w.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch break;
                    w.writeAll("Upgrade: websocket\r\n") catch break;
                    w.writeAll("Connection: Upgrade\r\n") catch break;
                    w.writeAll("Sec-WebSocket-Accept: ") catch break;
                    w.writeAll(&up.accept) catch break;
                    w.writeAll("\r\n\r\n") catch break;
                    w.flush() catch break;

                    // Hand the socket to the callback. Reuse the connection read
                    // buffer: drop the request bytes, move any pipelined frame
                    // bytes to the front, then read frames from there + the socket.
                    cr.consume(consumed);
                    cr.compact();
                    var conn = ws.WsConn{
                        .io = io,
                        .socket = stream.socket,
                        .w = w,
                        .buf = read_buf,
                        .start = 0,
                        .end = cr.buffered().len,
                        .state_ptr = @ptrCast(&self.state),
                        .arena = arena.allocator(),
                        .idle_timeout = idle_to,
                    };
                    up.cb(&conn);
                    break; // takeover done -> close (defer stream.close)
                }
```

- [ ] **Step 5: Run, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the echo e2e is green, all prior suites green, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/server.zig
git commit -m "feat(ws): threaded handleConn upgrade takeover + echo e2e"
```

---

### Task 4: Docs + version bump (v0.14.0)

Document the shipped capability and bump the version. Deliverable: README/CHANGELOG reflect the threaded echo handler; `build.zig.zon` is `0.14.0`.

**Files:**
- Modify: `build.zig.zon` (`.version = "0.13.0"` → `"0.14.0"`)
- Modify: `README.md` (WebSocket section)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `### Added`)
- Modify: `docs/getting-started.md` (short echo example)

**Interfaces:**
- Consumes: the public API from Tasks 1–3 (`zax.WebSocket`, `zax.WsConn`).
- Produces: nothing (docs/version only).

- [ ] **Step 1: Bump the version** (`build.zig.zon`)

Change:

```zig
    .version = "0.13.0",
```

to:

```zig
    .version = "0.14.0",
```

- [ ] **Step 2: Update the README WebSocket section** (`README.md`)

Replace the existing `## WebSocket (in progress)` section body (added in slice 1) with:

```markdown
## WebSocket (in progress)

WebSocket support is landing across several releases. The pure RFC 6455 codec
(`zax.ws`) and a **threaded connection upgrade + echo/handler API** now ship.

Declare an endpoint with the `WebSocket` extractor; `onUpgrade` hands the live
connection to your callback after the server performs the handshake:

```zig
fn echo(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(struct {
        fn run(conn: *zax.WsConn) void {
            while (conn.read()) |frame| // one frame per read (no reassembly yet)
                conn.send(frame.opcode, frame.payload) catch break;
        }
    }.run);
}
// app.get("/echo", echo);
```

`conn.read()` returns one client frame at a time (unmasked in place) and `null`
on a close frame, EOF, or protocol error; `conn.send(opcode, payload)` writes one
server frame; `conn.state(T)` reaches the app state. This release is the threaded
backend only and single-threaded per connection. Still to come: the evented
(reactor) backend, fragmentation reassembly, automatic ping/pong and the RFC
close handshake, configurable frame-size caps, and cross-connection broadcast.
```

- [ ] **Step 3: Add the CHANGELOG entry** (`CHANGELOG.md`, first bullet under `## [Unreleased]` → `### Added`)

```markdown
- **WebSocket threaded upgrade + handler API** (`zax.WebSocket` extractor, `zax.WsConn`) — second WebSocket slice. A handler takes the `WebSocket` extractor and calls `onUpgrade(cb)`; the threaded server validates the RFC 6455 handshake, sends `101 Switching Protocols` with the computed `Sec-WebSocket-Accept`, and hands the socket to `cb` as a `*WsConn`. `conn.read()` decodes and unmasks one client frame at a time (returning `null` on a close frame, EOF, or protocol error); `conn.send(opcode, payload)` writes one server frame; `conn.state(T)` reaches app state. Non-upgrade requests to a WebSocket route get `426 Upgrade Required`. Threaded backend only, single-threaded per connection. Evented support, fragmentation reassembly, automatic ping/pong, the RFC close handshake, and configurable size caps follow in later releases.
```

- [ ] **Step 4: Add a getting-started example** (`docs/getting-started.md`)

Append a short section at the end of the file:

```markdown
## WebSocket echo (threaded backend)

```zig
fn echo(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(struct {
        fn run(conn: *zax.WsConn) void {
            while (conn.read()) |frame|
                conn.send(frame.opcode, frame.payload) catch break;
        }
    }.run);
}

// try app.get("/echo", echo);
```

The server performs the RFC 6455 handshake and hands `conn` to your callback.
`conn.read()` yields one frame at a time and returns `null` when the peer sends a
close frame (or the connection ends); `conn.send` writes a frame back.
```

- [ ] **Step 5: Verify the build is still green**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add build.zig.zon README.md CHANGELOG.md docs/getting-started.md
git commit -m "docs(ws): document threaded upgrade/echo + bump to 0.14.0"
```

---

## Self-Review

**Spec coverage:**
- `WebSocket` extractor (Axum-style), `fromContext` validation, `onUpgrade` → Task 2. ✓
- `Response.upgrade` field signal mechanism → Task 2. ✓
- `WsConn` read (single frames, null on close/EOF/error) / send / state → Task 1. ✓
- `handleConn` takeover: 101 by hand, reuse read buffer + leftover, call cb, close → Task 3. ✓
- 426 for non-upgrade requests (extractor reject → classify) → Task 2. ✓
- Echo e2e (the slice-1-deferred end-to-end) → Task 3. ✓
- Unmask-in-place / borrow lifetime, no auto-pong/close-reply, single-threaded, max-frame=buffer → Task 1 + Global Constraints. ✓
- Threaded only, reactor untouched → Global Constraints; no task touches `reactor/*`. ✓
- Root exports `WebSocket`, `WsConn` → Tasks 1–2. ✓
- Docs + version 0.14.0 → Task 4. ✓
- One `error.zig` touch (classify arm) is the only pipeline-integration change → Task 2, matches the spec's stated allowance. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step has complete code; every test step has the full test. The handshake bytes, frame bytes (zero mask key), and accept vector are concrete. ✓

**Type consistency:** `WsConn` field set and methods (`read() ?Frame`, `send(Opcode, []const u8) !void`, `state(comptime T) T`) match across Tasks 1/3 and the e2e. `Upgrade{ accept: [28]u8, cb: Handler }`, `Handler = *const fn(*WsConn) void`, `Response.upgrade: ?ws.Upgrade`, `WebSocket.onUpgrade(self, cb) Response`, `error.NotWebSocketUpgrade` — consistent across Tasks 1/2/3. The e2e handler signature `fn(WebSocket) Response` matches the extractor + `intoResponse`. `state_ptr` is set as `@ptrCast(&self.state)` (Task 3) and read as `@as(*T, @ptrCast(@alignCast(...))).* ` (Task 1) — address-of-field both sides. ✓

**Note on the `state(T)` mechanism:** `WsConn` is intentionally non-generic (so `Upgrade`/`Response.upgrade`/`Handler` don't ripple generics through `Response`). State is type-erased via `*anyopaque` pointing at the App's `state` field; `state(T)` requires `T == AppState`. This is a deliberate design choice from the spec, not an oversight.

**Note on the e2e zero-mask-key trick:** client frames must be masked (mask bit set), but a mask key of `00 00 00 00` leaves the payload bytes unchanged, so the test avoids masking arithmetic while still exercising the real unmask path (`payload[i] ^ 0`). This is test-fixture convenience, not a protocol shortcut in the implementation.
