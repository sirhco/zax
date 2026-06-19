//! HTTP/1.1 chunked transfer-encoding wire framing.

const std = @import("std");
const Writer = std.Io.Writer;

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
