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

pub const WsSession = struct {
    read_buf: []u8,
    r_start: usize = 0,
    r_end: usize = 0,
    out_buf: []u8,
    o_start: usize = 0,
    o_end: usize = 0,
    handler: ws.Handler,
    reasm: ws.Reassembler,
    conn: ws.WsConn,
    cur_t: ?Transport = null, // set for the duration of onReadable/onWritable so send() can write
    closing: bool = false,

    const vtable = ws.WsConn.VTable{ .send = sendFn, .close = closeFn };

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
    // The caller must fix up `conn.ctx = &session` after the session is at its
    // final address (see `bind`), because `&self` inside init is the temporary.
    pub fn bind(self: *WsSession) void {
        self.conn.ctx = self;
    }

    /// Copy pipelined post-handshake bytes into the read buffer.
    pub fn seed(self: *WsSession, bytes: []const u8) void {
        std.mem.copyForwards(u8, self.read_buf[0..bytes.len], bytes);
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
        std.debug.assert(@intFromPtr(self.conn.ctx) == @intFromPtr(self));
        self.cur_t = t;
        defer self.cur_t = null;

        // First, try any already-buffered frames (pipelined / seeded).
        if (ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler, &self.reasm) == .closed) {
            _ = self.drainOut(t); // best-effort flush of the close-reply
            return .done_close;
        }
        if (self.closing) return .done_close;

        // Read more, then pump again.
        // `ws.pump` compacts leftover to the front (r_start := 0) on every return,
        // so r_start == 0 here; r_end == read_buf.len then means a single incomplete
        // frame fills the whole buffer and can never complete -> close.
        if (self.r_end == self.read_buf.len and self.r_start == 0) return .done_close;
        switch (t.read(self.read_buf[self.r_end..])) {
            .ok => |n| {
                if (n == 0) return .done_close;
                self.r_end += n;
                if (ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler, &self.reasm) == .closed) {
                    _ = self.drainOut(t); // best-effort flush of the close-reply
                    return .done_close;
                }
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
        std.debug.assert(@intFromPtr(self.conn.ctx) == @intFromPtr(self));
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
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator(), 1 << 20);
    sess.bind();
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
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator(), 1 << 20);
    sess.bind();
    try testing.expectEqual(StepResult.done_close, sess.onReadable(ft.transport()));
}

test "WsSession: seed handles a source that overlaps its own read buffer (pipelined frame)" {
    var rbuf: [64]u8 = undefined;
    var obuf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var st: u8 = 0;
    // Place a known 6-byte payload at offset 10 within rbuf, then seed from that
    // overlapping sub-slice (simulates conn.read_buf[r_start..r_end] aliasing).
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6 };
    @memcpy(rbuf[10..16], &payload);
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator(), 1 << 20);
    sess.bind();
    sess.seed(rbuf[10..16]); // overlapping source within the same buffer
    try testing.expectEqual(@as(usize, 0), sess.r_start);
    try testing.expectEqual(@as(usize, 6), sess.r_end);
    try testing.expectEqualSlices(u8, &payload, sess.read_buf[0..6]);
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
    var sess = WsSession.init(&rbuf, &obuf, .{ .on_message = echoOnMessage }, @ptrCast(&st), arena.allocator(), 1 << 20);
    sess.bind();
    const t = ft.transport();
    const r1 = sess.onReadable(t);
    try testing.expectEqual(StepResult.want_write, r1); // remainder buffered
    try testing.expectEqual(@as(usize, 2), ft.written.items.len); // partial write of the 4-byte echo
    const r2 = sess.onWritable(t); // drain the rest
    try testing.expect(r2 == .want_read or r2 == .done_close);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, ft.written.items);
}
