//! `Alloc` — hand a handler the per-request arena allocator so it can build
//! dynamic response bodies. Anything allocated here is freed when the request's
//! arena is released, so handlers never free manually. Unlike Axum (where Rust
//! handlers allocate freely), Zig handlers need an explicit allocator; this is
//! the idiomatic way to get the request-scoped one.

const std = @import("std");

pub const Alloc = struct {
    value: std.mem.Allocator,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .value = ctx.arena };
    }
};

const testing = std.testing;

test "Alloc yields the request arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = try Alloc.fromContext(.{ .arena = arena.allocator() });
    const s = try a.value.dupe(u8, "scratch");
    try testing.expectEqualStrings("scratch", s);
}
