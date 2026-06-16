//! `Cookies` — access request cookies by name. Parses the `Cookie` header lazily
//! via `get`. Cookie values are returned raw (opaque; not percent-decoded).

const std = @import("std");

pub const Cookies = struct {
    /// Raw `Cookie` header value (or "" when absent).
    header: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .header = ctx.req.header("cookie") orelse "" };
    }

    /// Return the first cookie value matching `name`, or null.
    pub fn get(self: Cookies, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.header, ';');
        while (it.next()) |pair| {
            const p = std.mem.trim(u8, pair, " \t");
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
        }
        return null;
    }
};

const testing = std.testing;
const Request = @import("../http/request.zig").Request;
const Header = @import("../http/request.zig").Header;

fn ctxWithCookie(value: []const u8) struct { req: *const Request } {
    const S = struct {
        var req: Request = undefined;
        var headers: [1]Header = undefined;
    };
    S.headers = .{.{ .name = "Cookie", .value = value }};
    S.req = .{
        .method = .GET,
        .target = "",
        .path = "",
        .query = "",
        .version_minor = 1,
        .headers = &S.headers,
        .body = "",
    };
    return .{ .req = &S.req };
}

test "Cookies.get finds values and trims OWS" {
    const c = try Cookies.fromContext(ctxWithCookie("sid=abc; theme=dark"));
    try testing.expectEqualStrings("abc", c.get("sid").?);
    try testing.expectEqualStrings("dark", c.get("theme").?);
    try testing.expectEqual(@as(?[]const u8, null), c.get("missing"));
}

test "Cookies with no header yields no cookies" {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{ .method = .GET, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "" };
    const c = try Cookies.fromContext(.{ .req = &S.req });
    try testing.expectEqual(@as(?[]const u8, null), c.get("sid"));
}
