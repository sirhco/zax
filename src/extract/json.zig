//! `Json(T)` — parse the request body as JSON into `T`. This is the only
//! allocating extractor: parsing uses the per-request arena (`ctx.arena`), so
//! everything is freed when the request's arena is released. Because it consumes
//! the body, `Json` must be a handler's last parameter (enforced at comptime by
//! the dispatcher via `zax_is_body`).

const std = @import("std");

pub const Error = error{InvalidJson};

pub fn Json(comptime T: type) type {
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = true;

        pub fn fromContext(ctx: anytype) Error!@This() {
            const v = std.json.parseFromSliceLeaky(T, ctx.arena, ctx.req.body, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidJson;
            return .{ .value = v };
        }
    };
}

// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWithBody(arena: std.mem.Allocator, body: []const u8) struct {
    arena: std.mem.Allocator,
    req: *const Request,
} {
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
    return .{ .arena = arena, .req = &S.req };
}

test "Json parses body into T using the arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const User = struct { id: u64, name: []const u8 };
    const J = Json(User);
    const r = try J.fromContext(ctxWithBody(arena.allocator(), "{\"id\":5,\"name\":\"ada\"}"));
    try testing.expectEqual(@as(u64, 5), r.value.id);
    try testing.expectEqualStrings("ada", r.value.name);
}

test "Json malformed body errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const J = Json(struct { id: u64 });
    try testing.expectError(error.InvalidJson, J.fromContext(ctxWithBody(arena.allocator(), "{not json")));
}
