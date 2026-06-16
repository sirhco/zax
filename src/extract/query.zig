//! `Query(T)` — bind URL query-string fields to struct `T`. Each field maps to a
//! `key=value` pair. Optional fields (`?T`) default to null when absent; required
//! fields error (`error.MissingField`) if missing. Binding, percent/plus decoding,
//! and scalar parsing are delegated to `urlencoded.bind` over `ctx.req.query`.

const std = @import("std");
const urlencoded = @import("urlencoded.zig");

pub fn Query(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Query(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) !@This() {
            return .{ .value = try urlencoded.bind(T, ctx.req.query, ctx.arena) };
        }
    };
}

// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWithQuery(q: []const u8) struct { req: *const Request, arena: std.mem.Allocator } {
    const S = struct {
        var req: Request = undefined;
        var arena: std.heap.ArenaAllocator = undefined;
    };
    S.req = .{
        .method = .GET,
        .target = "",
        .path = "",
        .query = q,
        .version_minor = 1,
        .headers = &.{},
        .body = "",
    };
    S.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return .{ .req = &S.req, .arena = S.arena.allocator() };
}

test "Query binds required and optional fields" {
    const Q = Query(struct { active: bool, page: ?u32, q: ?[]const u8 });
    const r = try Q.fromContext(ctxWithQuery("active=true&page=3"));
    try testing.expectEqual(true, r.value.active);
    try testing.expectEqual(@as(?u32, 3), r.value.page);
    try testing.expectEqual(@as(?[]const u8, null), r.value.q);
}

test "Query missing required field errors" {
    const Q = Query(struct { active: bool });
    try testing.expectError(error.MissingField, Q.fromContext(ctxWithQuery("page=1")));
}

test "Query decodes percent and plus" {
    const Q = Query(struct { q: []const u8 });
    const r = try Q.fromContext(ctxWithQuery("q=a+b%26c"));
    try testing.expectEqualStrings("a b&c", r.value.q);
}
