//! Bind an `x-www-form-urlencoded` source (`k=v&k=v`) to a struct. Used by both
//! the Query extractor (source = query string) and the Form extractor (source =
//! request body). Each field value is percent-decoded (plus_as_space = true)
//! then scalar-parsed. Optional (`?T`) fields default to null when absent.

const std = @import("std");
const scalar = @import("scalar.zig");
const url = @import("../url.zig");

/// Bind `source` to `T`. Returns `error.MissingField` if a required (non-optional)
/// field is absent. Decoding allocates into `arena` only when a value needs it.
pub fn bind(comptime T: type, source: []const u8, arena: std.mem.Allocator) !T {
    if (@typeInfo(T) != .@"struct") @compileError("urlencoded.bind: T must be a struct");
    var v: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const raw = find(source, f.name);
        switch (@typeInfo(f.type)) {
            .optional => |o| {
                @field(v, f.name) = if (raw) |r|
                    try scalar.parse(o.child, try url.decode(arena, r, true))
                else
                    null;
            },
            else => {
                const r = raw orelse return error.MissingField;
                @field(v, f.name) = try scalar.parse(f.type, try url.decode(arena, r, true));
            },
        }
    }
    return v;
}

/// Find the first `key=value` whose key equals `name` in an `&`-separated source.
fn find(source: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, source, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "bind: required + optional fields with decoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { name: []const u8, page: ?u32, note: ?[]const u8 };
    const v = try bind(T, "name=ada+lovelace&page=3&note=x%26y", arena.allocator());
    try testing.expectEqualStrings("ada lovelace", v.name);
    try testing.expectEqual(@as(?u32, 3), v.page);
    try testing.expectEqualStrings("x&y", v.note.?);
}

test "bind: missing required field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { name: []const u8 };
    try testing.expectError(error.MissingField, bind(T, "page=1", arena.allocator()));
}

test "bind: absent optional is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { q: ?[]const u8 };
    const v = try bind(T, "", arena.allocator());
    try testing.expectEqual(@as(?[]const u8, null), v.q);
}
