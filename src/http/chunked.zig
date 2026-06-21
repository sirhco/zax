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

pub const DecodeResult = union(enum) {
    /// Fully decoded. body_len = decoded bytes at buf[0..body_len];
    /// consumed = encoded bytes eaten (chunk sizes + data + CRLFs + terminator + trailers).
    done: struct { body_len: usize, consumed: usize },
    /// Buffer lacks a complete chunked body — read more and retry.
    incomplete,
    /// Malformed chunk framing → 400.
    malformed,
    /// Decoded length would exceed `max` → 413.
    too_large,
};

/// Decode a chunked request body IN PLACE. `buf` starts at the first chunk-size
/// line. On `.done`, the decoded body is buf[0..body_len]; bytes at
/// buf[consumed..] (a pipelined next request) are untouched. `max` caps decoded
/// length (0 = unbounded). Tolerates chunk extensions (`<hex>;...`) and trailer
/// headers after the 0-chunk (both skipped, not surfaced).
///
/// TWO-PASS and REPEAT-SAFE: pass 1 validates framing + measures WITHOUT writing,
/// so calling this repeatedly on a growing buffer (incremental reads) never
/// corrupts the input — `.incomplete`/`.malformed`/`.too_large` leave `buf`
/// untouched. Only a complete body triggers pass 2 (the in-place compaction).
pub fn decodeInPlace(buf: []u8, max: usize) DecodeResult {
    // --- Pass 1: validate + measure, NO mutation ---
    var i: usize = 0;
    var total: usize = 0;
    const consumed = blk: {
        while (true) {
            const line_end = std.mem.indexOfPos(u8, buf, i, "\r\n") orelse return .incomplete;
            var size_end = line_end;
            if (std.mem.indexOfScalarPos(u8, buf[0..line_end], i, ';')) |semi| size_end = semi;
            const size_tok = buf[i..size_end];
            if (size_tok.len == 0) return .malformed;
            const size = std.fmt.parseInt(usize, size_tok, 16) catch return .malformed;
            const data_start = line_end + 2;
            if (size == 0) {
                // last chunk: skip trailer header lines to the final blank line.
                var j = data_start;
                while (true) {
                    const te = std.mem.indexOfPos(u8, buf, j, "\r\n") orelse return .incomplete;
                    if (te == j) break :blk te + 2; // empty line → end of body
                    j = te + 2;
                }
            }
            // Use subtraction to avoid usize overflow on attacker-supplied size.
            // data_start <= buf.len always holds (line_end was found within buf).
            if (size > buf.len - data_start) return .incomplete;
            if (buf.len - data_start - size < 2) return .incomplete;
            if (buf[data_start + size] != '\r' or buf[data_start + size + 1] != '\n') return .malformed;
            // total <= max invariant: total starts 0; each iteration adds size only
            // after this guard, so total <= max always when the guard runs.
            if (max != 0 and size > max - total) return .too_large;
            total += size;
            i = data_start + size + 2;
        }
    };

    // --- Pass 2: compact in place (forward copy, dest <= src) ---
    var ri: usize = 0;
    var w: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, buf, ri, "\r\n").?;
        var size_end = line_end;
        if (std.mem.indexOfScalarPos(u8, buf[0..line_end], ri, ';')) |semi| size_end = semi;
        const size = std.fmt.parseInt(usize, buf[ri..size_end], 16) catch unreachable;
        const data_start = line_end + 2;
        if (size == 0) break;
        std.mem.copyForwards(u8, buf[w .. w + size], buf[data_start .. data_start + size]);
        w += size;
        ri = data_start + size + 2;
    }
    return .{ .done = .{ .body_len = w, .consumed = consumed } };
}

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

test "decodeInPlace: single chunk" {
    var buf = "5\r\nhello\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expect(r == .done);
    try std.testing.expectEqual(@as(usize, 5), r.done.body_len);
    try std.testing.expectEqual(buf.len, r.done.consumed);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
}

test "decodeInPlace: multi-chunk concatenates" {
    var buf = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello world", buf[0..r.done.body_len]);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: chunk extension skipped" {
    var buf = "5;foo=bar\r\nhello\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
}

test "decodeInPlace: trailers skipped, counted in consumed" {
    var buf = "5\r\nhello\r\n0\r\nX-Trace: 1\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: empty body" {
    var buf = "0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqual(@as(usize, 0), r.done.body_len);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: incomplete (no terminator)" {
    var buf = "5\r\nhel".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .incomplete);
}

test "decodeInPlace: incomplete (data shorter than size)" {
    var buf = "5\r\nhi\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .incomplete);
}

test "decodeInPlace: malformed hex size" {
    var buf = "zz\r\nhello\r\n0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .malformed);
}

test "decodeInPlace: malformed missing data CRLF" {
    var buf = "5\r\nhelloXX0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .malformed);
}

test "decodeInPlace: too_large" {
    var buf = "5\r\nhello\r\n0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 4) == .too_large);
}

test "decodeInPlace: oversized chunk size does not overflow" {
    var buf = "fffffffffffffffe\r\nhi\r\n0\r\n\r\n".*;
    // Must NOT panic; size far exceeds buffer → incomplete, never a crash.
    const r = decodeInPlace(&buf, 0);
    try std.testing.expect(r == .incomplete);
}

test "fuzz: decodeInPlace never panics on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const n = smith.sliceWithHash(&buf, 0x9002);
            _ = decodeInPlace(buf[0..n], 4096); // bounded max
            const n2 = smith.sliceWithHash(&buf, 0x9003);
            _ = decodeInPlace(buf[0..n2], 0);   // unbounded max
        }
    }.one, .{ .corpus = &.{
        "5\r\nhello\r\n0\r\n\r\n",
        "5;ext=1\r\nhello\r\n0\r\nX-T: 1\r\n\r\n",
        "0\r\n\r\n",
        "zz\r\nbad\r\n",
        "fffffffffffffffe\r\nhi\r\n0\r\n\r\n",
        "",
    } });
}
