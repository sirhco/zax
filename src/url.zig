//! URL percent-decoding for a single component (path segment, query/form value).
//! Zero-copy fast path: a component with no '%' (and no '+' in plus mode) is
//! returned unchanged. Otherwise it is decoded into the arena (decoded length is
//! always <= input length). Malformed '%' sequences are copied literally.

const std = @import("std");

pub fn decode(arena: std.mem.Allocator, raw: []const u8, plus_as_space: bool) std.mem.Allocator.Error![]const u8 {
    const has_pct = std.mem.indexOfScalar(u8, raw, '%') != null;
    const has_plus = plus_as_space and std.mem.indexOfScalar(u8, raw, '+') != null;
    if (!has_pct and !has_plus) return raw; // fast path: zero-copy

    const out = try arena.alloc(u8, raw.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                out[j] = c;
                i += 1;
                j += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                out[j] = c;
                i += 1;
                j += 1;
                continue;
            };
            out[j] = hi * 16 + lo;
            i += 3;
            j += 1;
        } else if (plus_as_space and c == '+') {
            out[j] = ' ';
            i += 1;
            j += 1;
        } else {
            out[j] = c;
            i += 1;
            j += 1;
        }
    }
    return out[0..j];
}

const testing = std.testing;

test "decode: clean input is returned zero-copy (same pointer)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "plain-value";
    const out = try decode(arena.allocator(), raw, true);
    try testing.expectEqual(raw.ptr, out.ptr); // no allocation
}

test "decode: percent sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("John Doe", try decode(arena.allocator(), "John%20Doe", false));
    try testing.expectEqualStrings("a&b", try decode(arena.allocator(), "a%26b", false));
    try testing.expectEqualStrings("a+b", try decode(arena.allocator(), "a%2Bb", true)); // %2B is literal '+'
}

test "decode: plus means space only in plus mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b", try decode(arena.allocator(), "a+b", true));
    try testing.expectEqualStrings("a+b", try decode(arena.allocator(), "a+b", false));
}

test "decode: malformed percent copied literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("100% x", try decode(arena.allocator(), "100%25 x", true)); // valid -> '%'
    try testing.expectEqualStrings("a%2", try decode(arena.allocator(), "a%2", false)); // truncated
    try testing.expectEqualStrings("a%zz", try decode(arena.allocator(), "a%zz", false)); // non-hex
}
