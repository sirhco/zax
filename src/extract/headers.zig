//! `Headers` — read arbitrary request headers from a handler. Names are matched
//! case-insensitively (RFC 9110). Values are borrowed slices into the request
//! buffer (zero-copy); only `getAll` allocates (into the arena).

const std = @import("std");
const Header = @import("../http/request.zig").Header;

pub const Headers = struct {
    /// Borrowed view of the parsed request header list (zero-copy).
    list: []const Header,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .list = ctx.req.headers };
    }

    /// First value matching `name` (case-insensitive), or null.
    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        for (self.list) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Whether any header matches `name` (case-insensitive).
    pub fn has(self: @This(), name: []const u8) bool {
        return self.get(name) != null;
    }

    /// All values matching `name` (case-insensitive), in request order.
    /// Arena-allocated; empty slice when none match.
    pub fn getAll(self: @This(), arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.list) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(arena, h.value);
        }
        return out.toOwnedSlice(arena);
    }

    /// Raw header list for iteration.
    pub fn all(self: @This()) []const Header {
        return self.list;
    }

    /// Number of headers on the request.
    pub fn count(self: @This()) usize {
        return self.list.len;
    }
};

// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWith(headers: []const Header) struct { req: *const Request } {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version_minor = 1,
        .headers = headers,
        .body = "",
    };
    return .{ .req = &S.req };
}

test "Headers.get: first match, case-insensitive" {
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "X-Test", .value = "hello" },
        .{ .name = "Content-Type", .value = "text/plain" },
    }));
    try testing.expectEqualStrings("hello", h.get("x-test").?);
    try testing.expectEqualStrings("hello", h.get("X-TEST").?);
    try testing.expectEqualStrings("text/plain", h.get("content-type").?);
}

test "Headers.get: missing header returns null" {
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "X-Test", .value = "hello" },
    }));
    try testing.expectEqual(@as(?[]const u8, null), h.get("x-missing"));
}

test "Headers.get: first match wins when duplicate names" {
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "Accept", .value = "text/html" },
        .{ .name = "accept", .value = "application/json" },
    }));
    try testing.expectEqualStrings("text/html", h.get("accept").?);
}

test "Headers.has: true when present, false when absent" {
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "Authorization", .value = "Bearer tok" },
    }));
    try testing.expect(h.has("authorization"));
    try testing.expect(h.has("AUTHORIZATION"));
    try testing.expect(!h.has("x-missing"));
}

test "Headers.getAll: multi-value in request order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "Accept", .value = "text/html" },
        .{ .name = "X-Foo", .value = "bar" },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "ACCEPT", .value = "image/webp" },
    }));
    const vals = try h.getAll(arena.allocator(), "accept");
    try testing.expectEqual(@as(usize, 3), vals.len);
    try testing.expectEqualStrings("text/html", vals[0]);
    try testing.expectEqualStrings("application/json", vals[1]);
    try testing.expectEqualStrings("image/webp", vals[2]);
}

test "Headers.getAll: single match -> len 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "X-Foo", .value = "only" },
    }));
    const vals = try h.getAll(arena.allocator(), "x-foo");
    try testing.expectEqual(@as(usize, 1), vals.len);
    try testing.expectEqualStrings("only", vals[0]);
}

test "Headers.getAll: no match -> empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try Headers.fromContext(ctxWith(&.{
        .{ .name = "X-Foo", .value = "bar" },
    }));
    const vals = try h.getAll(arena.allocator(), "x-missing");
    try testing.expectEqual(@as(usize, 0), vals.len);
}

test "Headers.count and all reflect the raw list" {
    const hdrs: []const Header = &.{
        .{ .name = "A", .value = "1" },
        .{ .name = "B", .value = "2" },
        .{ .name = "C", .value = "3" },
    };
    const h = try Headers.fromContext(ctxWith(hdrs));
    try testing.expectEqual(@as(usize, 3), h.count());
    const raw = h.all();
    try testing.expectEqual(@as(usize, 3), raw.len);
    try testing.expectEqualStrings("A", raw[0].name);
    try testing.expectEqualStrings("C", raw[2].name);
}

test "Headers: empty header slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const h = try Headers.fromContext(ctxWith(&.{}));
    try testing.expectEqual(@as(usize, 0), h.count());
    try testing.expectEqual(@as(?[]const u8, null), h.get("any"));
    try testing.expect(!h.has("any"));
    const vals = try h.getAll(arena.allocator(), "any");
    try testing.expectEqual(@as(usize, 0), vals.len);
}
