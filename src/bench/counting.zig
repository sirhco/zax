//! A thread-safe `std.mem.Allocator` wrapper for the benchmark harness that
//! tracks cumulative bytes *requested* via an atomic counter. The server
//! allocates on multiple threads (`Io.Threaded`), so counting must be atomic.
//!
//! Pure std only (no `zax`/`Io`), so the `test` blocks below run under
//! `zig build test` via the bench test target.

const std = @import("std");

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    bytes: std.atomic.Value(usize) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Cumulative bytes requested across all successful (re)allocations.
    pub fn bytesAllocated(self: *const CountingAllocator) usize {
        return self.bytes.load(.monotonic);
    }

    pub fn reset(self: *CountingAllocator) void {
        self.bytes.store(0, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (p != null) _ = self.bytes.fetchAdd(len, .monotonic);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (ok and new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (p != null and new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        // Counter is cumulative bytes requested; freeing does not decrement.
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

const testing = std.testing;

test "counts cumulative bytes on alloc; free does not decrement" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const p = try a.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), c.bytesAllocated());
    const q = try a.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 164), c.bytesAllocated());
    a.free(p);
    a.free(q);
    try testing.expectEqual(@as(usize, 164), c.bytesAllocated());
}

test "reset zeroes the counter" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const p = try a.alloc(u8, 32);
    defer a.free(p);
    c.reset();
    try testing.expectEqual(@as(usize, 0), c.bytesAllocated());
}

test "delegates correctly (allocations are usable)" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const buf = try a.alloc(u8, 8);
    defer a.free(buf);
    @memset(buf, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[7]);
}
