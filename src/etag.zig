//! ETag middleware: Wyhash ETag + If-None-Match → 304.
//! Mirrors compress.zig structure.

const std = @import("std");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

/// ETag middleware configuration.
pub const Etag = struct {
    /// When true, emit `W/"<hash>"` (weak validator) instead of `"<hash>"`.
    weak: bool = false,
};

/// Compute a quoted ETag string for `body` using Wyhash.
/// Strong: `"<16hex>"` (18 chars). Weak: `W/"<16hex>"` (21 chars).
fn formatTag(arena: std.mem.Allocator, weak: bool, body: []const u8) ![]const u8 {
    const h: u64 = std.hash.Wyhash.hash(0, body);
    return if (weak)
        std.fmt.allocPrint(arena, "W/\"{x:0>16}\"", .{h})
    else
        std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{h});
}

/// Return the opaque tag portion of a raw ETag value:
/// trim whitespace, strip a leading `W/` prefix and trim again.
fn opaque_tag(raw: []const u8) []const u8 {
    var t = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, t, "W/")) t = std.mem.trim(u8, t[2..], " \t");
    return t;
}

/// RFC 7232 weak ETag comparison against an If-None-Match header value.
/// Returns true if `our_tag` matches any entry in the comma-separated list,
/// or if the list is `*`.
fn matches(if_none_match: []const u8, our_tag: []const u8) bool {
    const h = std.mem.trim(u8, if_none_match, " \t");
    if (std.mem.eql(u8, h, "*")) return true;
    const want = opaque_tag(our_tag);
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok| {
        const cand = std.mem.trim(u8, tok, " \t");
        if (cand.len == 0) continue;
        if (std.mem.eql(u8, opaque_tag(cand), want)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "matches: exact strong match" {
    const testing = std.testing;
    try testing.expect(matches("\"abc\"", "\"abc\""));
    try testing.expect(!matches("\"abc\"", "\"abd\""));
}

test "matches: wildcard * matches anything" {
    const testing = std.testing;
    try testing.expect(matches("*", "\"abc\""));
    try testing.expect(matches("*", "W/\"xyz\""));
}

test "matches: weak comparison cross-type" {
    const testing = std.testing;
    // weak header vs strong tag
    try testing.expect(matches("W/\"abc\"", "\"abc\""));
    // strong header vs weak tag
    try testing.expect(matches("\"abc\"", "W/\"abc\""));
}

test "matches: comma list with whitespace and trailing comma" {
    const testing = std.testing;
    // hit via weak entry in list
    try testing.expect(matches(" \"x\" , W/\"abc\" , ", "\"abc\""));
    // miss
    try testing.expect(!matches("\"x\", \"y\"", "\"abc\""));
}

test "formatTag: strong and weak properties" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = "hello world";
    const strong = try formatTag(alloc, false, body);
    const weak = try formatTag(alloc, true, body);

    // strong: exactly 18 chars, starts and ends with "
    try testing.expectEqual(@as(usize, 18), strong.len);
    try testing.expectEqual('"', strong[0]);
    try testing.expectEqual('"', strong[strong.len - 1]);

    // weak: starts with W/"
    try testing.expect(std.mem.startsWith(u8, weak, "W/\""));

    // same opaque tag (same 16-hex body)
    try testing.expectEqualStrings(opaque_tag(strong), opaque_tag(weak));
}
