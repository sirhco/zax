//! Transport interface and fake in-memory test double.
//!
//! `Transport` is a vtable-based abstraction over a readable/writable byte
//! stream. The real implementation (Task 8) will wrap a non-blocking POSIX
//! socket; here we expose only the interface plus `FakeTransport` so that the
//! connection state-machine can be unit-tested on any platform without sockets.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// IoResult
// ---------------------------------------------------------------------------

/// The result of a single non-blocking read or write.
pub const IoResult = union(enum) {
    /// Bytes transferred; value is the count.
    ok: usize,
    /// The operation would block — caller should arm the event loop and retry.
    would_block,
    /// The peer closed the connection (EOF on read, broken pipe on write).
    closed,
};

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// A tiny vtable wrapping a non-blocking byte stream.
///
/// Both `readFn` and `writeFn` must be non-blocking: they return immediately
/// with `.would_block` rather than blocking the calling thread.
pub const Transport = struct {
    context: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, buf: []u8) IoResult,
    writeFn: *const fn (ctx: *anyopaque, buf: []const u8) IoResult,

    pub fn read(self: Transport, buf: []u8) IoResult {
        return self.readFn(self.context, buf);
    }

    pub fn write(self: Transport, buf: []const u8) IoResult {
        return self.writeFn(self.context, buf);
    }
};

// ---------------------------------------------------------------------------
// FakeTransport — test double
// ---------------------------------------------------------------------------

/// An in-memory `Transport` driven by scripted data.
///
/// Reads return successive slices from `reads`. Once all chunks are consumed
/// the next read returns `.closed` (unless `closed_after_reads` is set to an
/// earlier index). A one-shot `.would_block` is injected after `block_after`
/// successful reads; the read that would have blocked is retried normally on
/// the subsequent call. Writes append bytes to the `written` list.
pub const FakeTransport = struct {
    /// Scripted read chunks.
    reads: []const []const u8,
    /// Index of the next scripted chunk to return.
    read_idx: usize = 0,
    /// After this many successful reads, return `.would_block` once then resume.
    /// Defaults to `maxInt(usize)` (never block).
    block_after: usize = std.math.maxInt(usize),
    /// Set to `true` internally when the one-shot block has been fired.
    blocked_once: bool = false,
    /// Bytes accumulated by `writeFn`.
    written: std.ArrayListUnmanaged(u8),
    /// Allocator used for `written`; stored so vtable fns can append without
    /// the caller threading an allocator through every write call.
    gpa: std.mem.Allocator,
    /// If set, return `.closed` after this many successful reads instead of
    /// waiting until `reads` is exhausted.
    closed_after_reads: ?usize = null,

    pub fn init(gpa: std.mem.Allocator, reads: []const []const u8) FakeTransport {
        return .{
            .reads = reads,
            .written = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *FakeTransport) void {
        self.written.deinit(self.gpa);
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{
            .context = self,
            .readFn = readFn,
            .writeFn = writeFn,
        };
    }

    // -- vtable implementations --

    fn readFn(ctx: *anyopaque, buf: []u8) IoResult {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));

        // Check explicit early-close threshold.
        if (self.closed_after_reads) |limit| {
            if (self.read_idx >= limit) return .closed;
        }

        // One-shot would_block injection.
        if (!self.blocked_once and self.read_idx >= self.block_after) {
            self.blocked_once = true;
            return .would_block;
        }

        // Scripts exhausted → closed.
        if (self.read_idx >= self.reads.len) return .closed;

        const chunk = self.reads[self.read_idx];
        self.read_idx += 1;

        const n = @min(chunk.len, buf.len);
        @memcpy(buf[0..n], chunk[0..n]);
        return .{ .ok = n };
    }

    fn writeFn(ctx: *anyopaque, buf: []const u8) IoResult {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        self.written.appendSlice(self.gpa, buf) catch return .closed;
        return .{ .ok = buf.len };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FakeTransport: returns scripted read chunks then closed" {
    var ft = FakeTransport.init(testing.allocator, &.{ "GET / HTTP/1.1\r\n", "\r\n" });
    defer ft.deinit();
    const t = ft.transport();
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), (t.read(&buf)).ok); // first chunk
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n", buf[0..16]);
    try testing.expectEqual(@as(usize, 2), (t.read(&buf)).ok); // "\r\n"
    try testing.expect((t.read(&buf)) == .closed); // scripts exhausted
}

test "FakeTransport: write() accumulates into `written`" {
    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    const t = ft.transport();
    _ = t.write("HTTP/1.1 200 OK\r\n");
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", ft.written.items);
}

test "FakeTransport: would_block injected once at block_after" {
    var ft = FakeTransport.init(testing.allocator, &.{ "a", "b" });
    defer ft.deinit();
    ft.block_after = 1;
    const t = ft.transport();
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), (t.read(&buf)).ok);
    try testing.expect((t.read(&buf)) == .would_block); // injected
    try testing.expectEqual(@as(usize, 1), (t.read(&buf)).ok); // resumes
}
