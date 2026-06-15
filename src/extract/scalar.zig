//! Shared scalar string->value parsing used by the Path and Query extractors.
//! Bytes are borrowed; `[]const u8` parses to itself (zero-copy).

const std = @import("std");

pub const ParseError = error{ InvalidScalar, InvalidEnum };

pub fn parse(comptime T: type, s: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, s, 10) catch error.InvalidScalar,
        .float => std.fmt.parseFloat(T, s) catch error.InvalidScalar,
        .bool => parseBool(s) orelse error.InvalidScalar,
        .@"enum" => std.meta.stringToEnum(T, s) orelse error.InvalidEnum,
        .pointer => |p| if (T == []const u8 or (p.size == .slice and p.child == u8 and p.is_const))
            s
        else
            @compileError("unsupported scalar pointer type: " ++ @typeName(T)),
        else => @compileError("unsupported scalar type: " ++ @typeName(T)),
    };
}

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

const testing = std.testing;

test "parse ints, floats, bools, strings, enums" {
    try testing.expectEqual(@as(u64, 42), try parse(u64, "42"));
    try testing.expectEqual(@as(i32, -7), try parse(i32, "-7"));
    try testing.expectApproxEqAbs(@as(f64, 3.5), try parse(f64, "3.5"), 1e-9);
    try testing.expectEqual(true, try parse(bool, "true"));
    try testing.expectEqual(false, try parse(bool, "0"));
    try testing.expectEqualStrings("hello", try parse([]const u8, "hello"));

    const Color = enum { red, green, blue };
    try testing.expectEqual(Color.green, try parse(Color, "green"));
    try testing.expectError(error.InvalidEnum, parse(Color, "mauve"));
    try testing.expectError(error.InvalidScalar, parse(u8, "notnum"));
}
