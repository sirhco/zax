//! `Query(T)` — bind URL query-string fields to struct `T`. Each field maps to a
//! `key=value` pair. Optional fields (`?T`) default to null when absent; required
//! fields error if missing. Values are parsed via the shared scalar parser.
//!
//! v1 limitation: no percent-decoding yet (raw bytes), and repeated keys take the
//! first occurrence. Both are noted for a later pass.

const std = @import("std");
const scalar = @import("scalar.zig");

pub const Error = error{ MissingQueryParam, InvalidScalar, InvalidEnum };

pub fn Query(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Query(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) Error!@This() {
            var v: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const raw = find(ctx.req.query, f.name);
                switch (@typeInfo(f.type)) {
                    .optional => |o| {
                        @field(v, f.name) = if (raw) |r| try scalar.parse(o.child, r) else null;
                    },
                    else => {
                        const r = raw orelse return error.MissingQueryParam;
                        @field(v, f.name) = try scalar.parse(f.type, r);
                    },
                }
            }
            return .{ .value = v };
        }
    };
}

/// Find the first `key=value` whose key equals `name` in a `&`-separated query.
fn find(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWithQuery(q: []const u8) struct { req: *const Request } {
    const S = struct {
        var req: Request = undefined;
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
    return .{ .req = &S.req };
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
    try testing.expectError(error.MissingQueryParam, Q.fromContext(ctxWithQuery("page=1")));
}
