//! `Bytes` — the raw request body as a borrowed `[]const u8`. A body extractor,
//! so it must be a handler's last parameter (and cannot coexist with Json/Form).

const std = @import("std");

pub const Bytes = struct {
    value: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = true;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .value = ctx.req.body };
    }
};

const testing = std.testing;
const Request = @import("../http/request.zig").Request;

test "Bytes returns the raw body" {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{ .method = .POST, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "raw\x00bytes" };
    const b = try Bytes.fromContext(.{ .req = &S.req });
    try testing.expectEqualStrings("raw\x00bytes", b.value);
}
