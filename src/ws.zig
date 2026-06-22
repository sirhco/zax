//! WebSocket protocol primitives (RFC 6455) — pure, no server integration.
//! `acceptKey` computes the handshake accept value; `parseFrame` decodes and
//! unmasks one client frame (in place); `writeFrame` serializes one unmasked
//! server frame. Connection upgrade/takeover, fragmentation reassembly, and
//! control-frame semantics are later sub-features.

const std = @import("std");

/// RFC 6455 GUID appended to the client key before hashing.
pub const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) >= 0x8;
    }
};

/// Compute `Sec-WebSocket-Accept` for a client `Sec-WebSocket-Key`. Writes the
/// 28-byte base64 value into `out` and returns the slice. No allocation.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(magic);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// One decoded WebSocket frame. `payload` is a zero-copy (unmasked) slice into
/// the buffer passed to `parseFrame`.
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

pub const ParseError = error{
    /// `buf` does not yet contain the whole frame — read more and retry.
    Incomplete,
    /// A client→server frame was not masked (RFC 6455 violation).
    UnmaskedClientFrame,
    /// A control frame (opcode ≥ 0x8) carried > 125 bytes.
    ControlFrameTooLong,
    /// A control frame had FIN = 0.
    FragmentedControlFrame,
};

pub const Parsed = struct { frame: Frame, consumed: usize };

/// Parse ONE client frame from `buf`, unmasking the payload IN PLACE. Returns
/// the frame and total bytes consumed, or `Incomplete` if `buf` lacks the full
/// frame. (Single-frame: no cross-frame reassembly.)
pub fn parseFrame(buf: []u8) ParseError!Parsed {
    if (buf.len < 2) return error.Incomplete;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    const len7: u7 = @truncate(b1 & 0x7F);

    // All length checks use the subtraction form (`buf.len - off < N`) to stay
    // overflow-safe: `off <= buf.len` is guaranteed at each point.
    var off: usize = 2;
    var len: usize = len7;
    if (len7 == 126) {
        if (buf.len - off < 2) return error.Incomplete;
        len = std.mem.readInt(u16, buf[off..][0..2], .big);
        off += 2;
    } else if (len7 == 127) {
        if (buf.len - off < 8) return error.Incomplete;
        len = std.mem.readInt(u64, buf[off..][0..8], .big);
        off += 8;
    }

    if (!masked) return error.UnmaskedClientFrame;
    if (buf.len - off < 4) return error.Incomplete;
    const key = buf[off..][0..4].*;
    off += 4;

    if (opcode.isControl()) {
        if (!fin) return error.FragmentedControlFrame;
        if (len > 125) return error.ControlFrameTooLong;
    }

    // `buf.len - off` is safe: off <= buf.len after the mask-key check above.
    // Using subtraction (not `off + len`) avoids usize overflow on a hostile length.
    if (buf.len - off < len) return error.Incomplete;
    const payload = buf[off..][0..len];
    for (payload, 0..) |*byte, i| {
        byte.* ^= key[i % 4];
    }
    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = payload }, .consumed = off + len };
}

/// Serialize ONE server frame (FIN = 1, unmasked) to `w`: header (with the
/// minimal 7/16/64-bit length form) + `payload`.
pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try w.writeByte(@intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try w.writeByte(126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(127);
        try w.writeInt(u64, @intCast(payload.len), .big);
    }
    try w.writeAll(payload);
}

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
    socket: std.Io.net.Socket,
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

// Test helper: build a masked client frame into `out`, return the used slice.
fn buildMaskedFrame(out: []u8, fin: bool, opcode: Opcode, key: [4]u8, payload: []const u8) []u8 {
    out[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    var i: usize = 0;
    if (payload.len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload.len));
        i = 2;
    } else if (payload.len <= 0xFFFF) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        i = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        i = 10;
    }
    @memcpy(out[i..][0..4], &key);
    i += 4;
    for (payload, 0..) |b, j| out[i + j] = b ^ key[j % 4];
    return out[0 .. i + payload.len];
}

test "ws: parseFrame decodes a masked text frame" {
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const frame = buildMaskedFrame(&buf, true, .text, key, "Hello");
    const parsed = try parseFrame(frame);
    try std.testing.expect(parsed.frame.fin);
    try std.testing.expectEqual(Opcode.text, parsed.frame.opcode);
    try std.testing.expectEqualStrings("Hello", parsed.frame.payload);
    try std.testing.expectEqual(frame.len, parsed.consumed);
}

test "ws: parseFrame 16-bit length form" {
    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 256);
    var buf: [256]u8 = undefined;
    const key = [4]u8{ 1, 2, 3, 4 };
    const frame = buildMaskedFrame(&buf, true, .binary, key, &payload);
    const parsed = try parseFrame(frame);
    try std.testing.expectEqual(@as(usize, 200), parsed.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, parsed.frame.payload);
}

test "ws: parseFrame 64-bit length header" {
    const key = [4]u8{ 9, 8, 7, 6 };
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 7) % 256);
    var buf: [512]u8 = undefined;
    buf[0] = 0x82; // FIN + binary
    buf[1] = 0x80 | 127;
    std.mem.writeInt(u64, buf[2..10], @intCast(payload.len), .big);
    @memcpy(buf[10..14], &key);
    for (payload, 0..) |b, j| buf[14 + j] = b ^ key[j % 4];
    const frame = buf[0 .. 14 + payload.len];
    const parsed = try parseFrame(frame);
    try std.testing.expectEqual(@as(usize, 300), parsed.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, parsed.frame.payload);
}

test "ws: parseFrame reports Incomplete at each boundary" {
    const key = [4]u8{ 0x10, 0x20, 0x30, 0x40 };
    var buf: [64]u8 = undefined;
    const frame = buildMaskedFrame(&buf, true, .text, key, "abcdef"); // 2-byte header + 4-byte mask key + 6-byte payload = 12 bytes
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..1])); // < 2 bytes: no full header
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..2])); // header only, no mask key
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..5])); // partial mask key (3 of 4)
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..9])); // 3 of 6 payload bytes
}

test "ws: parseFrame rejects an unmasked client frame" {
    var buf = [_]u8{ 0x81, 0x03, 'a', 'b', 'c' }; // FIN+text, mask bit 0, len 3
    try std.testing.expectError(error.UnmaskedClientFrame, parseFrame(&buf));
}

test "ws: parseFrame rejects an oversized control frame" {
    const key = [4]u8{ 1, 1, 1, 1 };
    var payload: [126]u8 = undefined;
    @memset(&payload, 0x55);
    var buf: [200]u8 = undefined;
    const frame = buildMaskedFrame(&buf, true, .ping, key, &payload); // 126 bytes → len7==126 form
    try std.testing.expectError(error.ControlFrameTooLong, parseFrame(frame));
}

test "ws: parseFrame rejects a fragmented control frame" {
    const key = [4]u8{ 2, 2, 2, 2 };
    var buf: [32]u8 = undefined;
    const frame = buildMaskedFrame(&buf, false, .close, key, "x"); // FIN = 0
    try std.testing.expectError(error.FragmentedControlFrame, parseFrame(frame));
}

test "ws: parseFrame decodes control opcodes" {
    const key = [4]u8{ 3, 3, 3, 3 };
    inline for (.{ Opcode.close, Opcode.ping, Opcode.pong }) |op| {
        var buf: [32]u8 = undefined;
        const frame = buildMaskedFrame(&buf, true, op, key, "hi");
        const parsed = try parseFrame(frame);
        try std.testing.expectEqual(op, parsed.frame.opcode);
    }
}

test "ws: acceptKey RFC 6455 vector" {
    var out: [28]u8 = undefined;
    const got = acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "ws: Opcode.isControl classifies control opcodes" {
    try std.testing.expect(!Opcode.continuation.isControl());
    try std.testing.expect(!Opcode.text.isControl());
    try std.testing.expect(!Opcode.binary.isControl());
    try std.testing.expect(Opcode.close.isControl());
    try std.testing.expect(Opcode.ping.isControl());
    try std.testing.expect(Opcode.pong.isControl());
}

test "ws: writeFrame small payload emits exact bytes" {
    var out: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, .text, "Hi");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'H', 'i' }, w.buffered());
}

test "ws: writeFrame 16-bit length header" {
    var payload: [200]u8 = undefined;
    @memset(&payload, 0xAB);
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, .binary, &payload);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]); // FIN + binary
    try std.testing.expectEqual(@as(u8, 126), bytes[1]); // 16-bit form
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, bytes[2..4], .big));
    try std.testing.expectEqual(@as(usize, 4 + 200), bytes.len);
}

test "ws: writeFrame 64-bit length header" {
    const big = 70_000; // > 0xFFFF → 64-bit form
    const payload = try std.testing.allocator.alloc(u8, big);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xCD);
    const out = try std.testing.allocator.alloc(u8, big + 16);
    defer std.testing.allocator.free(out);
    var w = std.Io.Writer.fixed(out);
    try writeFrame(&w, .binary, payload);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 127), bytes[1]); // 64-bit form
    try std.testing.expectEqual(@as(u64, big), std.mem.readInt(u64, bytes[2..10], .big));
    try std.testing.expectEqual(@as(usize, 10 + big), bytes.len);
}

test "ws: build → parseFrame → writeFrame round-trips the payload" {
    const original = "round-trip payload \x00\x01\x02 with bytes";
    const key = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };
    var inbuf: [128]u8 = undefined;
    const masked = buildMaskedFrame(&inbuf, true, .binary, key, original);
    const parsed = try parseFrame(masked);
    try std.testing.expectEqualStrings(original, parsed.frame.payload);

    var out: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, parsed.frame.opcode, parsed.frame.payload);
    const server_bytes = w.buffered();
    // server frame: byte0 = 0x80|binary, byte1 = len (unmasked, < 126), then payload
    try std.testing.expectEqual(@as(u8, 0x82), server_bytes[0]);
    try std.testing.expectEqual(@as(u8, @intCast(original.len)), server_bytes[1]);
    try std.testing.expectEqualStrings(original, server_bytes[2..]);
}

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
