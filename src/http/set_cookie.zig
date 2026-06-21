//! `SetCookie` — build a `Set-Cookie` response header value (RFC 6265). The
//! cookie value is emitted raw (symmetric with the `Cookies` read extractor,
//! which does not percent-decode); `serialize` validates the name and value.
//! Note: browsers require `Secure` when `SameSite=None` — set `.secure = true`
//! in that case (not auto-enforced here).

const std = @import("std");

pub const SameSite = enum { strict, lax, none };

pub const SetCookie = struct {
    name: []const u8,
    value: []const u8,
    /// Max-Age in seconds. 0 expires the cookie immediately. null omits it.
    max_age: ?i64 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    pub const Error = error{ InvalidCookieName, InvalidCookieValue, OutOfMemory };

    /// Serialize to a `Set-Cookie` header VALUE (no "set-cookie:" prefix), into
    /// `arena`. Validates the name (RFC 6265 token) and value (cookie-octet).
    pub fn serialize(self: SetCookie, arena: std.mem.Allocator) Error![]const u8 {
        if (!isValidName(self.name)) return error.InvalidCookieName;
        if (!isValidValue(self.value)) return error.InvalidCookieValue;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, self.name);
        try out.append(arena, '=');
        try out.appendSlice(arena, self.value);

        if (self.max_age) |ma| {
            var nbuf: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{ma}) catch unreachable;
            try out.appendSlice(arena, "; Max-Age=");
            try out.appendSlice(arena, ns);
        }
        if (self.domain) |d| {
            try out.appendSlice(arena, "; Domain=");
            try out.appendSlice(arena, d);
        }
        if (self.path) |p| {
            try out.appendSlice(arena, "; Path=");
            try out.appendSlice(arena, p);
        }
        if (self.secure) try out.appendSlice(arena, "; Secure");
        if (self.http_only) try out.appendSlice(arena, "; HttpOnly");
        if (self.same_site) |ss| {
            try out.appendSlice(arena, "; SameSite=");
            try out.appendSlice(arena, switch (ss) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            });
        }
        return out.toOwnedSlice(arena);
    }
};

/// RFC 6265 cookie-name = token (RFC 7230): VCHAR minus separators/whitespace.
fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return false,
            else => {},
        }
    }
    return true;
}

/// RFC 6265 cookie-octet: %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E —
/// i.e. no CTL, no space, no `"` `,` `;` `\`. Empty value is allowed.
fn isValidValue(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x21 or c > 0x7e) return false;
        switch (c) {
            '"', ',', ';', '\\' => return false,
            else => {},
        }
    }
    return true;
}

// ----------------------------------------------------------------------------
const testing = std.testing;

fn ser(arena: std.mem.Allocator, c: SetCookie) ![]const u8 {
    return c.serialize(arena);
}

test "SetCookie: full attribute set serializes in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try ser(arena.allocator(), .{
        .name = "sid",
        .value = "abc",
        .max_age = 3600,
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
    try testing.expectEqualStrings(
        "sid=abc; Max-Age=3600; Domain=example.com; Path=/; Secure; HttpOnly; SameSite=Lax",
        s,
    );
}

test "SetCookie: minimal is just name=value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a=b", try ser(arena.allocator(), .{ .name = "a", .value = "b" }));
}

test "SetCookie: SameSite variants render Strict/Lax/None" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("k=v; SameSite=Strict", try ser(a, .{ .name = "k", .value = "v", .same_site = .strict }));
    try testing.expectEqualStrings("k=v; SameSite=Lax", try ser(a, .{ .name = "k", .value = "v", .same_site = .lax }));
    try testing.expectEqualStrings("k=v; SameSite=None", try ser(a, .{ .name = "k", .value = "v", .same_site = .none }));
}

test "SetCookie: Max-Age=0 (delete) and empty value allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("x=; Max-Age=0", try ser(arena.allocator(), .{ .name = "x", .value = "", .max_age = 0 }));
}

test "SetCookie: invalid name rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "", .value = "v" }));
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "a b", .value = "v" }));
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "a;b", .value = "v" }));
}

test "SetCookie: invalid value rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a b" }));
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a;b" }));
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a\"b" }));
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a\\b" }));
}
