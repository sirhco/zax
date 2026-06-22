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
