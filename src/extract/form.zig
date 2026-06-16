//! `Form(T)` — parse an `x-www-form-urlencoded` request body into struct `T`,
//! via the shared urlencoded binder (same semantics as Query, but from the body).
//! Consumes the body, so it must be a handler's last parameter (like Json).

const std = @import("std");
const urlencoded = @import("urlencoded.zig");

pub fn Form(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Form(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = true;

        pub fn fromContext(ctx: anytype) !@This() {
            return .{ .value = try urlencoded.bind(T, ctx.req.body, ctx.arena) };
        }
    };
}

const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWithBody(arena: std.mem.Allocator, body: []const u8) struct { req: *const Request, arena: std.mem.Allocator } {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{
        .method = .POST,
        .target = "",
        .path = "",
        .query = "",
        .version_minor = 1,
        .headers = &.{},
        .body = body,
    };
    return .{ .req = &S.req, .arena = arena };
}

test "Form binds a urlencoded body with decoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const F = Form(struct { name: []const u8, tags: []const u8 });
    const r = try F.fromContext(ctxWithBody(arena.allocator(), "name=ada&tags=x%2Cy"));
    try testing.expectEqualStrings("ada", r.value.name);
    try testing.expectEqualStrings("x,y", r.value.tags);
}

test "Form missing field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const F = Form(struct { name: []const u8 });
    try testing.expectError(error.MissingField, F.fromContext(ctxWithBody(arena.allocator(), "x=1")));
}
