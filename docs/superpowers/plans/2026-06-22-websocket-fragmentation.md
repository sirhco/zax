# WebSocket Fragmentation + Control Frames + Message Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete RFC 6455's message layer: `on_message` receives whole reassembled messages, the framework auto-pongs pings and runs the close-reply handshake, and reassembly is bounded by `ws_max_message_size` — once, in the shared `pump`, so both backends get it.

**Architecture:** Turn the stateless shared `pump` (`src/ws.zig`) into a stateful reassembler by adding a `*Reassembler` parameter. `pump` joins continuation frames into whole messages (delivered with `fin = true`), auto-responds to control frames (ping→pong, close→close-reply), and enforces the message cap (over→close `1009`; protocol errors→close `1002`). The single-frame `fin = 1` message stays zero-copy; only fragmented messages allocate a per-connection accumulator. Both backends (threaded loop in `server.zig`, evented `WsSession`) own a `Reassembler` and pass it to `pump`.

**Tech Stack:** Zig 0.16.0; the slice-1 `parseFrame`/`writeFrame` codec; `WsConn` vtable `send` (auto-replies work on both backends).

## Global Constraints

- Zig `0.16.0`. Ships as **v0.16.0** (bump `build.zig.zon` in the docs task — currently `0.15.0`).
- **Both backends via the shared `pump`.** Reactor changes confined to `reactor/ws_session.zig`, `reactor/worker.zig`; threaded to `server.zig`; the core to `ws.zig`. No `error.zig`, extractor, or handshake changes.
- **Compile unit:** adding the `*Reassembler` parameter to `pump` breaks all 3 call sites (`server.zig`, `ws_session.zig` ×2). The full `zig build test` is RED between Task 1 and Task 2; GREEN at end of Task 2. Task 1 verifies via `zig test src/ws.zig` (imports only std → standalone-testable).
- **`on_message` delivers whole messages** (`fin = true`, `opcode = text/binary`); continuation/ping/pong/close NEVER reach it. The `on_message` signature is unchanged.
- **Control-frame policy:** ping → `conn.send(.pong, payload)` (not delivered); pong → ignored; close → send a close-reply (echo the peer's close payload) then `.closed`; unknown opcode (data or control) → close `1002`.
- **Size cap:** `Options.ws_max_message_size: usize = 1 << 20` (1 MiB). Reassembly over it → close `1009`. A single frame is already bounded by `read_buffer_size`.
- **Accumulator:** lazy `arena.alloc(max_message_size)` on the first fragment, reused for the connection's lifetime; single-frame messages never allocate.
- **Close codes:** `1009` (message too big), `1002` (protocol error), big-endian 2-byte close payload.
- RFC handshake unchanged; `acceptKey("dGhlIHNhbXBsZSBub25jZQ==")` == `"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`.
- Tests in-file as `test "..."` blocks (root `refAllDecls`). Build/test: `zig build test --summary all`.

---

## File Structure

- **`src/ws.zig`** (modify) — add `Reassembler`, `sendClose`/`sendCloseCode`/`appendFragment` helpers; rework `pump` to take `*Reassembler` and do reassembly + control-frame policy + caps. Update the existing `pump` unit tests (they call the old signature) + add reassembly/control/cap tests.
- **`src/server.zig`** (modify) — `Options.ws_max_message_size`; construct a `Reassembler` in the threaded takeover and pass it to `pump`; add `.ws_max_message_size` to the `WorkerOpts` built in `serveEvented`.
- **`src/reactor/ws_session.zig`** (modify) — `reasm: ws.Reassembler` field; `init` gains a `max_message_size` param; pass `&self.reasm` to both `pump` calls; best-effort drain the close-reply before `done_close`.
- **`src/reactor/worker.zig`** (modify) — `WorkerOpts.ws_max_message_size`; pass it to `WsSession.init`.
- **`README.md` / `CHANGELOG.md` / `docs/getting-started.md` / `build.zig.zon`** (modify, docs task).

Tasks: T1 core (RED) → T2 wire both backends (GREEN) → T3 cross-backend e2e → T4 docs.

---

### Task 1: `Reassembler` + stateful `pump` in `src/ws.zig`

Rework the shared frame loop into a reassembler. Deliverable: `pump` joins fragments into whole messages, auto-handles control frames, enforces the cap — all unit-tested via `zig test src/ws.zig`.

**Files:**
- Modify: `src/ws.zig`

**Interfaces:**
- Consumes: `Opcode`, `Frame`, `parseFrame`, `writeFrame`, `WsConn`, `Handler`, `PumpResult`; `buildMaskedFrame` test helper.
- Produces:
  - `Reassembler = struct { arena: std.mem.Allocator, max_message_size: usize, msg_buf: ?[]u8 = null, msg_len: usize = 0, msg_opcode: Opcode = .text, fragmenting: bool = false }`
  - `pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler, r: *Reassembler) PumpResult`

- [ ] **Step 1: Replace the `pump` body + add `Reassembler` and helpers**

In `src/ws.zig`, replace the existing `pump` function (and its doc comment) with:

```zig
/// Per-connection reassembly state + control-frame policy. Owned by each backend
/// (one per upgraded connection). The single-frame message path never touches the
/// accumulator (zero-copy); only fragmented messages allocate `msg_buf` (lazily,
/// once, sized to `max_message_size`, reused).
pub const Reassembler = struct {
    arena: std.mem.Allocator,
    max_message_size: usize,
    msg_buf: ?[]u8 = null,
    msg_len: usize = 0,
    msg_opcode: Opcode = .text,
    fragmenting: bool = false,
};

/// Send a framework-initiated close with a 2-byte big-endian status code.
fn sendCloseCode(conn: *WsConn, code: u16) void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, code, .big);
    conn.send(.close, &payload) catch {};
}

/// Reply to a peer close: echo their close payload (which carries their code) when
/// present, else send an empty close. Best-effort.
fn sendClose(conn: *WsConn, payload: []const u8) void {
    conn.send(.close, if (payload.len >= 2) payload else "") catch {};
}

/// Append `payload` to the reassembly buffer; false if it would exceed the cap or
/// the buffer cannot be allocated.
fn appendFragment(r: *Reassembler, payload: []const u8) bool {
    if (r.msg_len + payload.len > r.max_message_size) return false;
    if (r.msg_buf == null) {
        r.msg_buf = r.arena.alloc(u8, r.max_message_size) catch return false;
    }
    @memcpy(r.msg_buf.?[r.msg_len..][0..payload.len], payload);
    r.msg_len += payload.len;
    return true;
}

/// Parse complete client frames from `buf[start..end]`, joining continuation frames
/// into whole messages (delivered to `on_message` with `fin = true`), auto-responding
/// to control frames (ping→pong, close→close-reply), and enforcing `r.max_message_size`.
/// Returns `.closed` on a close frame, protocol error, or over-cap (after sending the
/// appropriate close frame); else `.need_more` with leftover compacted to the front.
/// Single-frame `fin = 1` messages are delivered zero-copy (payload borrows `buf`).
pub fn pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler, r: *Reassembler) PumpResult {
    while (start.* < end.*) {
        const parsed = parseFrame(buf[start.*..end.*]) catch |e| switch (e) {
            error.Incomplete => break, // need more bytes
            else => {
                sendCloseCode(conn, 1002); // protocol error
                return .closed;
            },
        };
        start.* += parsed.consumed;
        const f = parsed.frame;

        if (f.opcode.isControl()) {
            switch (f.opcode) {
                .ping => conn.send(.pong, f.payload) catch {},
                .pong => {}, // ignore
                .close => {
                    sendClose(conn, f.payload);
                    return .closed;
                },
                else => { // unknown control opcode (0xB–0xF) — fail the connection
                    sendCloseCode(conn, 1002);
                    return .closed;
                },
            }
            continue;
        }

        switch (f.opcode) {
            .continuation => {
                if (!r.fragmenting) {
                    sendCloseCode(conn, 1002); // continuation with no message in progress
                    return .closed;
                }
                if (!appendFragment(r, f.payload)) {
                    sendCloseCode(conn, 1009); // message too big
                    return .closed;
                }
                if (f.fin) {
                    handler.on_message(conn, .{ .fin = true, .opcode = r.msg_opcode, .payload = r.msg_buf.?[0..r.msg_len] });
                    r.fragmenting = false;
                    r.msg_len = 0;
                }
            },
            .text, .binary => {
                if (r.fragmenting) {
                    sendCloseCode(conn, 1002); // new data frame mid-message
                    return .closed;
                }
                if (f.fin) {
                    handler.on_message(conn, f); // single-frame message: zero-copy
                } else {
                    r.msg_opcode = f.opcode;
                    r.msg_len = 0;
                    r.fragmenting = true;
                    if (!appendFragment(r, f.payload)) {
                        sendCloseCode(conn, 1009);
                        return .closed;
                    }
                }
            },
            else => { // unknown data opcode (0x3–0x7)
                sendCloseCode(conn, 1002);
                return .closed;
            },
        }
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

- [ ] **Step 2: Update the existing `pump` unit tests to the new signature + add reassembly/control/cap tests**

The slice-3 `pump` tests call the 5-arg signature; they need a `Reassembler`. Update the `TestSink` to be the shared fixture and rewrite/extend the tests. Replace the existing `pump` test block with:

```zig
// Test sink: records every frame sent through the WsConn vtable, as raw bytes.
const TestSink = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    closed: bool = false,
    gpa: std.mem.Allocator,
    const vt = WsConn.VTable{ .send = sendFn, .close = closeFn };
    fn sendFn(ctx: *anyopaque, opcode: Opcode, payload: []const u8) SendError!void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        var scratch: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&scratch);
        writeFrame(&w, opcode, payload) catch return error.WriteFailed;
        self.sent.appendSlice(self.gpa, w.buffered()) catch return error.WriteFailed;
    }
    fn closeFn(ctx: *anyopaque) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

// Capture for on_message: records the last delivered message + a count.
const MsgCapture = struct {
    var last: [256]u8 = undefined;
    var last_len: usize = 0;
    var last_opcode: Opcode = .text;
    var count: usize = 0;
    fn reset() void {
        count = 0;
        last_len = 0;
    }
    fn onMsg(conn: *WsConn, f: Frame) void {
        _ = conn;
        @memcpy(last[0..f.payload.len], f.payload);
        last_len = f.payload.len;
        last_opcode = f.opcode;
        count += 1;
    }
};

fn makeConn(sink: *TestSink) WsConn {
    return .{ .ctx = sink, .vtable = &TestSink.vt, .state_ptr = @ptrCast(sink), .arena = std.testing.allocator };
}

fn makeReasm(arena: std.mem.Allocator, cap: usize) Reassembler {
    return .{ .arena = arena, .max_message_size = cap };
}

test "ws: pump delivers a single-frame text message (zero-copy)" {
    MsgCapture.reset();
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 1, 2, 3, 4 };
    const frame = buildMaskedFrame(&buf, true, .text, key, "hello");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = frame.len;
    try std.testing.expectEqual(PumpResult.need_more, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqual(@as(usize, 1), MsgCapture.count);
    try std.testing.expectEqualStrings("hello", MsgCapture.last[0..MsgCapture.last_len]);
    try std.testing.expectEqual(@as(?[]u8, null), r.msg_buf); // accumulator never allocated
}

test "ws: pump reassembles a two-frame fragmented message" {
    MsgCapture.reset();
    var buf: [128]u8 = undefined;
    const key = [4]u8{ 9, 9, 9, 9 };
    const f1 = buildMaskedFrame(buf[0..], false, .text, key, "Hel"); // fin=0 text
    const f2len = buildMaskedFrame(buf[f1.len..], true, .continuation, key, "lo").len; // fin=1 continuation
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = f1.len + f2len;
    try std.testing.expectEqual(PumpResult.need_more, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqual(@as(usize, 1), MsgCapture.count);
    try std.testing.expectEqualStrings("Hello", MsgCapture.last[0..MsgCapture.last_len]);
    try std.testing.expectEqual(Opcode.text, MsgCapture.last_opcode);
}

test "ws: pump auto-ponds a ping and still reassembles" {
    MsgCapture.reset();
    var buf: [128]u8 = undefined;
    const key = [4]u8{ 2, 2, 2, 2 };
    // text fin=0 "ab", ping "pq", continuation fin=1 "cd"
    const a = buildMaskedFrame(buf[0..], false, .text, key, "ab");
    const b = buildMaskedFrame(buf[a.len..], true, .ping, key, "pq");
    const c = buildMaskedFrame(buf[a.len + b.len ..], true, .continuation, key, "cd");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = a.len + b.len + c.len;
    _ = pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r);
    try std.testing.expectEqual(@as(usize, 1), MsgCapture.count);
    try std.testing.expectEqualStrings("abcd", MsgCapture.last[0..MsgCapture.last_len]);
    // A pong (0x8A) with payload "pq" was sent.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 0x02, 'p', 'q' }, sink.sent.items);
}

test "ws: pump drops a pong and delivers nothing" {
    MsgCapture.reset();
    var buf: [32]u8 = undefined;
    const key = [4]u8{ 3, 3, 3, 3 };
    const frame = buildMaskedFrame(&buf, true, .pong, key, "x");
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = frame.len;
    try std.testing.expectEqual(PumpResult.need_more, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqual(@as(usize, 0), MsgCapture.count);
    try std.testing.expectEqual(@as(usize, 0), sink.sent.items.len);
}

test "ws: pump replies to a close and returns closed" {
    MsgCapture.reset();
    var buf: [32]u8 = undefined;
    const key = [4]u8{ 4, 4, 4, 4 };
    // close with a 2-byte code 1000 (0x03E8)
    const frame = buildMaskedFrame(&buf, true, .close, key, &[_]u8{ 0x03, 0xE8 });
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = frame.len;
    try std.testing.expectEqual(PumpResult.closed, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqual(@as(usize, 0), MsgCapture.count);
    // A close (0x88) echoing the 2-byte code was sent.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xE8 }, sink.sent.items);
}

test "ws: pump closes with 1009 when reassembly exceeds the cap" {
    MsgCapture.reset();
    var buf: [128]u8 = undefined;
    const key = [4]u8{ 5, 5, 5, 5 };
    // cap = 4; "Hel" (3) then continuation "loo" (3) -> 6 > 4 -> 1009
    const f1 = buildMaskedFrame(buf[0..], false, .text, key, "Hel");
    const f2len = buildMaskedFrame(buf[f1.len..], true, .continuation, key, "loo").len;
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 4);
    var start: usize = 0;
    var end: usize = f1.len + f2len;
    try std.testing.expectEqual(PumpResult.closed, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqual(@as(usize, 0), MsgCapture.count);
    // A close (0x88) with code 1009 (0x03F1) was sent.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xF1 }, sink.sent.items);
}

test "ws: pump rejects an orphan continuation with 1002" {
    MsgCapture.reset();
    var buf: [32]u8 = undefined;
    const key = [4]u8{ 6, 6, 6, 6 };
    const frame = buildMaskedFrame(&buf, true, .continuation, key, "x"); // no message in progress
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = frame.len;
    try std.testing.expectEqual(PumpResult.closed, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xEA }, sink.sent.items); // 1002 = 0x03EA
}

test "ws: pump rejects a new data frame mid-fragment with 1002" {
    MsgCapture.reset();
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 7, 7, 7, 7 };
    const f1 = buildMaskedFrame(buf[0..], false, .text, key, "ab"); // fin=0
    const f2len = buildMaskedFrame(buf[f1.len..], true, .text, key, "cd").len; // new data frame, not continuation
    var sink = TestSink{ .gpa = std.testing.allocator };
    defer sink.sent.deinit(std.testing.allocator);
    var conn = makeConn(&sink);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var r = makeReasm(ar.allocator(), 1 << 20);
    var start: usize = 0;
    var end: usize = f1.len + f2len;
    try std.testing.expectEqual(PumpResult.closed, pump(&buf, &start, &end, &conn, .{ .on_message = MsgCapture.onMsg }, &r));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xEA }, sink.sent.items); // 1002
}
```

NOTE on close codes used in assertions: `1000 = 0x03E8`, `1002 = 0x03EA`, `1009 = 0x03F1`. The pong opcode byte is `0x8A` (FIN|pong); close is `0x88`.

- [ ] **Step 3: Run the ws.zig tests standalone, expect PASS**

Run: `zig test src/ws.zig`
Expected: PASS — all reassembly/control/cap tests plus the codec tests. (The full `zig build test` is RED until Task 2 updates the call sites; that is by design — note it but do not try to fix `server.zig`/`ws_session.zig` here.)

- [ ] **Step 4: Commit**

```bash
git add src/ws.zig
git commit -m "feat(ws): stateful pump — reassembly + auto control frames + message cap"
```

---

### Task 2: Wire the `Reassembler` through both backends

Update all three `pump` call sites + config so the full build compiles and the unit tests run. Deliverable: full `zig build test` GREEN again, with reassembly active on both backends.

**Files:**
- Modify: `src/server.zig` (`Options.ws_max_message_size`; threaded takeover `Reassembler`; `WorkerOpts` in `serveEvented`)
- Modify: `src/reactor/ws_session.zig` (`reasm` field; `init` param; pass to `pump`; close-reply drain)
- Modify: `src/reactor/worker.zig` (`WorkerOpts.ws_max_message_size`; pass to `WsSession.init`)

**Interfaces:**
- Consumes: `ws.Reassembler` (Task 1); `pump`'s new 6-arg signature.

- [ ] **Step 1: Add `ws_max_message_size` to `Options`** (`src/server.zig`, in `pub const Options`)

```zig
    /// Maximum reassembled WebSocket message size (bytes). A message exceeding this
    /// is rejected with a 1009 close. A single frame is separately bounded by
    /// `read_buffer_size`.
    ws_max_message_size: usize = 1 << 20,
```

- [ ] **Step 2: Construct a `Reassembler` in the threaded takeover + pass it to `pump`** (`src/server.zig`, the takeover loop near line 736)

Immediately before `if (up.handler.on_open) |f| f(&conn);`, add:

```zig
                    var reasm = ws_mod.Reassembler{ .arena = arena.allocator(), .max_message_size = self.opts.ws_max_message_size };
```

Change the `pump` call in the loop to pass `&reasm`:

```zig
                        const pr = ws_mod.pump(read_buf, &start, &end, &conn, up.handler, &reasm);
```

- [ ] **Step 3: Add the `reasm` field + `init` param to `WsSession` + pass to `pump`** (`src/reactor/ws_session.zig`)

Add the field (next to `handler`):

```zig
    reasm: ws.Reassembler,
```

Update `init` to take `max_message_size` and initialize `reasm`:

```zig
    pub fn init(read_buf: []u8, out_buf: []u8, handler: ws.Handler, state_ptr: *anyopaque, arena: std.mem.Allocator, max_message_size: usize) WsSession {
        var s = WsSession{
            .read_buf = read_buf,
            .out_buf = out_buf,
            .handler = handler,
            .conn = undefined,
            .reasm = .{ .arena = arena, .max_message_size = max_message_size },
        };
        s.conn = ws.WsConn{ .ctx = undefined, .vtable = &vtable, .state_ptr = state_ptr, .arena = arena };
        return s;
    }
```

Pass `&self.reasm` to both `pump` calls in `onReadable`, and best-effort drain the close-reply before closing. Replace the two `if (ws.pump(...) == .closed) return .done_close;` sites with:

```zig
        if (ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler, &self.reasm) == .closed) {
            _ = self.drainOut(t); // best-effort flush of the close-reply
            return .done_close;
        }
```

(Apply the same replacement to BOTH pump call sites — the one over already-buffered bytes and the one after `t.read`.)

- [ ] **Step 4: Thread the cap through the worker** (`src/reactor/worker.zig`)

Add to `WorkerOpts` (next to `read_buffer_size`):

```zig
    ws_max_message_size: usize,
```

Pass it at the `WsSession.init` call (the `.upgraded` arm):

```zig
                slot.ws = ws_session.WsSession.init(
                    slot.read_buf, slot.ws_out_buf, up.handler, up.state_ptr, slot.arena.allocator(), self.opts.ws_max_message_size,
                );
```

- [ ] **Step 5: Populate `WorkerOpts.ws_max_message_size` in `serveEvented`** (`src/server.zig`, the `WorkerOpts{ ... }` literal near line 519)

Add the field:

```zig
                .ws_max_message_size = self.opts.ws_max_message_size,
```

- [ ] **Step 6: Run the full suite, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the build compiles again; all `ws.zig` unit tests run under the build; the existing threaded + evented echo e2e still pass (a single-frame `hi` is delivered as a one-frame message — unchanged behavior). NOTE: takes a few minutes (loopback e2e) — run in the FOREGROUND and wait for the final pass/fail line.

- [ ] **Step 7: Commit**

```bash
git add src/server.zig src/reactor/ws_session.zig src/reactor/worker.zig
git commit -m "feat(ws): wire Reassembler through threaded + evented backends + cap option"
```

---

### Task 3: Cross-backend e2e (fragmentation, ping, close)

Prove the message layer end-to-end on both backends. Deliverable: loopback e2e for a fragmented message, a ping→pong, and a close handshake, on threaded AND evented.

**Files:**
- Modify: `src/server.zig` (add e2e tests near the existing WS echo e2e)

**Interfaces:**
- Consumes: the existing WS echo e2e harness (`wsEchoHandler`, the threaded `startTestApp` / evented `serveEvented` harness, the loopback connect helpers). Reuse them exactly.

- [ ] **Step 1: Add the threaded fragmentation/ping/close e2e**

Find the existing `"end-to-end: websocket upgrade, handshake, and echo"` test (threaded) and add, right after it, a test that reuses the same setup (same `wsEchoHandler`, `startTestApp`, port `18100`) but exercises the new behaviors. Use the zero-mask-key trick (mask key `00 00 00 00` → masked payload == plaintext). After the 101 handshake (assert as the echo test does), then:

```zig
    // (handshake already asserted: 101 + Sec-WebSocket-Accept) — then:

    // 1. Fragmented message: text fin=0 "Hel" + continuation fin=1 "lo" -> echoed whole "Hello".
    const frag1 = [_]u8{ 0x01, 0x83, 0x00, 0x00, 0x00, 0x00, 'H', 'e', 'l' }; // opcode text(0x1), fin=0
    const frag2 = [_]u8{ 0x80, 0x82, 0x00, 0x00, 0x00, 0x00, 'l', 'o' };       // opcode continuation(0x0), fin=1
    cw.interface.writeAll(&frag1) catch unreachable;
    cw.interface.writeAll(&frag2) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t1: usize = 0;
    while (cr.interface.buffered().len < 7) : (t1 += 1) {
        if (t1 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    // server echoes the whole message as one text frame: 0x81, 0x05, "Hello"
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' }, cr.interface.buffered()[0..7]);
    cr.interface.toss(7);

    // 2. Ping -> pong. masked ping (0x89) "pq" -> server sends pong (0x8A) "pq".
    const ping = [_]u8{ 0x89, 0x82, 0x00, 0x00, 0x00, 0x00, 'p', 'q' };
    cw.interface.writeAll(&ping) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t2: usize = 0;
    while (cr.interface.buffered().len < 4) : (t2 += 1) {
        if (t2 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 0x02, 'p', 'q' }, cr.interface.buffered()[0..4]);
    cr.interface.toss(4);

    // 3. Close -> close-reply then EOF. masked close (0x88) with code 1000.
    const close = [_]u8{ 0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8 };
    cw.interface.writeAll(&close) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t3: usize = 0;
    while (cr.interface.buffered().len < 4) : (t3 += 1) {
        if (t3 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    // server echoes a close frame (0x88) with the same code, then closes.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xE8 }, cr.interface.buffered()[0..4]);
```

Wrap this in a full `test "end-to-end: websocket fragmentation, ping, and close (threaded)"` block that mirrors the echo e2e's app setup + handshake (copy the handshake-assertion portion; do NOT factor it out — keep the test self-contained), using a fresh port `18100`.

- [ ] **Step 2: Add the evented version**

Mirror the same test against the evented backend — copy the existing `"end-to-end (evented): websocket upgrade, handshake, and echo"` test's `serveEvented` harness setup, port `18101`, and run the identical fragmentation/ping/close byte exchanges + assertions from Step 1. Name it `test "end-to-end (evented): websocket fragmentation, ping, and close"`.

- [ ] **Step 3: Run the full suite, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — the two new e2e (threaded + evented) pass over real loopback; all prior tests green. Run in the FOREGROUND; wait for the final pass/fail line.

- [ ] **Step 4: Commit**

```bash
git add src/server.zig
git commit -m "test(ws): e2e fragmentation, ping/pong, and close handshake (both backends)"
```

---

### Task 4: Docs + version bump (v0.16.0)

Document the completed message layer; bump the version. Deliverable: README/CHANGELOG/getting-started reflect whole-message delivery + auto control frames + the cap; `build.zig.zon` is `0.16.0`.

**Files:**
- Modify: `build.zig.zon` (`.version = "0.15.0"` → `"0.16.0"`)
- Modify: `README.md`, `CHANGELOG.md`, `docs/getting-started.md`

**Interfaces:**
- Consumes: the public behavior from Tasks 1–3.
- Produces: nothing (docs/version only).

- [ ] **Step 1: Bump the version** (`build.zig.zon`)

```zig
    .version = "0.16.0",
```

- [ ] **Step 2: Update the README WebSocket section** (`README.md`)

In the `## WebSocket (in progress)` section, update the description of `on_message` and add the control-frame/cap behavior. Replace the paragraph that describes `on_message` / frame delivery with:

```markdown
The server performs the RFC 6455 handshake, then calls your `on_message` once per
**whole message** — continuation frames are reassembled for you, so `msg.payload` is
the complete message (`msg.opcode` is `.text` or `.binary`). The framework handles
control frames itself: it replies to pings with pongs and performs the close
handshake; those never reach `on_message`. Reassembled messages are bounded by
`ws_max_message_size` (default 1 MiB); a larger message is rejected with a `1009`
close. `conn.send(opcode, payload)` writes a message back; `conn.state(T)` reaches
app state; `conn.close()` ends the connection. WebSocket is feature-complete for the
core protocol; cross-connection broadcast is a future addition.
```

(Drop any earlier "one frame per read (no reassembly yet)" wording.)

- [ ] **Step 3: CHANGELOG** (`CHANGELOG.md`, under `## [Unreleased]`)

Add under `### Added`:

```markdown
- **WebSocket fragmentation, control frames, and message cap** — `on_message` now receives whole reassembled messages (continuation frames joined). The framework auto-replies to pings with pongs and performs the RFC 6455 close handshake (no longer raw TCP close). Reassembled messages are bounded by the new `ws_max_message_size` option (default 1 MiB); over-cap → `1009` close, protocol violations → `1002` close. Single-frame messages stay zero-copy. Both backends. WebSocket core protocol is now feature-complete.
```

Add under `### Changed`:

```markdown
- **WebSocket `on_message` now delivers whole messages, not raw frames.** Continuation/ping/pong/close frames no longer reach `on_message` (the framework reassembles messages and handles control frames). Handlers that echo `(msg.opcode, msg.payload)` are unaffected.
```

- [ ] **Step 4: getting-started** (`docs/getting-started.md`)

In the WebSocket echo section, add a one-line note under the code block:

```markdown
`on_message` receives complete messages — fragmentation is reassembled for you, and
pings/pongs and the close handshake are handled automatically.
```

- [ ] **Step 5: Verify the build is still green**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add build.zig.zon README.md CHANGELOG.md docs/getting-started.md
git commit -m "docs(ws): document whole-message delivery + control frames + cap; bump to 0.16.0"
```

---

## Self-Review

**Spec coverage:**
- `Reassembler` + stateful `pump` (join fragments → whole messages) → Task 1. ✓
- Auto-pong, pong-drop, close-reply → Task 1 (control-frame switch). ✓
- `ws_max_message_size` cap → `1009` close; protocol errors → `1002` → Task 1; option in Task 2. ✓
- Single-frame zero-copy preserved → Task 1 (the `.text/.binary` `fin` path; test asserts `msg_buf == null`). ✓
- Both backends wired → Task 2 (threaded + evented + worker + serveEvented). ✓
- Close-reply best-effort flush on evented → Task 2 (drainOut before done_close). ✓
- E2e fragmentation/ping/close on both backends → Task 3. ✓
- `on_message` whole-message behavior change documented → Task 4 (Changed). ✓
- Docs + version 0.16.0 → Task 4. ✓
- No auto-ping initiation, no broadcast (out of scope) → omitted by design. ✓

**Placeholder scan:** No TBD/vague steps. Every code step is complete; close-code byte values are concrete (`1000=0x03E8`, `1002=0x03EA`, `1009=0x03F1`); frame opcode bytes concrete (`0x81` text, `0x88` close, `0x8A` pong). Task 3 directs reuse of the existing e2e harness rather than re-deriving it (the harness names — `wsEchoHandler`, `startTestApp`, `serveEvented` setup — are the real ones from the slice-3 e2e the implementer copies from).

**Type consistency:** `Reassembler{arena, max_message_size, msg_buf:?[]u8, msg_len, msg_opcode, fragmenting}`, `pump(buf,*start,*end,*WsConn,Handler,*Reassembler) PumpResult`, `WsSession.init(read_buf,out_buf,handler,state_ptr,arena,max_message_size)`, `WorkerOpts.ws_max_message_size`, `Options.ws_max_message_size` — consistent across Tasks 1–3. `on_message` signature unchanged (`fn(*WsConn, Frame) void`). The 3 pump call sites all updated in Task 2.

**Cross-file compile note (for the controller):** Task 1 changes `pump`'s signature → `server.zig` and `ws_session.zig` (×2) won't compile until Task 2. Full `zig build test` is expected RED between Task 1 and Task 2; Task 1 verifies via `zig test src/ws.zig`. Full suite GREEN at end of Task 2. The task reviewer for Task 1 should judge the code against the spec, not require a green full-suite mid-sequence.

**Note on the zero-mask-key e2e trick:** client frames must be masked (mask bit set), but a mask key of `00 00 00 00` leaves payload bytes unchanged, so the e2e byte literals are readable while still exercising the real unmask path. Test-fixture convenience, not a protocol shortcut.
