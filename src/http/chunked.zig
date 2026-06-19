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
                .vtable = &.{ .drain = drain, .sendFile = std.Io.Writer.unimplementedSendFile },
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

const testing = std.testing;

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
