//! `Path(T)` — bind captured URL path parameters to `T`.
//!  - `T` a struct: each field is filled from the same-named `:param`.
//!  - `T` a scalar: filled from the single captured parameter.
//! Parameter values are borrowed slices into the request path (zero-copy);
//! scalar fields are parsed from them.

const std = @import("std");
const scalar = @import("scalar.zig");

pub const Error = error{ MissingPathParam, InvalidScalar, InvalidEnum };

pub fn Path(comptime T: type) type {
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) Error!@This() {
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    var v: T = undefined;
                    inline for (s.fields) |f| {
                        const raw = find(ctx.params, f.name) orelse return error.MissingPathParam;
                        @field(v, f.name) = try scalar.parse(f.type, raw);
                    }
                    return .{ .value = v };
                },
                else => {
                    if (ctx.params.len == 0) return error.MissingPathParam;
                    return .{ .value = try scalar.parse(T, ctx.params[0].value) };
                },
            }
        }
    };
}

fn find(params: anytype, name: []const u8) ?[]const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

// ----------------------------------------------------------------------------
const testing = std.testing;
const Param = @import("../router/radix.zig").Param;

const FakeCtx = struct { params: []const Param };

test "Path binds struct fields from named params" {
    const params = [_]Param{
        .{ .name = "org", .value = "zig" },
        .{ .name = "id", .value = "42" },
    };
    const P = Path(struct { org: []const u8, id: u64 });
    const p = try P.fromContext(FakeCtx{ .params = &params });
    try testing.expectEqualStrings("zig", p.value.org);
    try testing.expectEqual(@as(u64, 42), p.value.id);
}

test "Path scalar binds single param" {
    const params = [_]Param{.{ .name = "id", .value = "7" }};
    const p = try Path(u32).fromContext(FakeCtx{ .params = &params });
    try testing.expectEqual(@as(u32, 7), p.value);
}

test "Path missing param errors" {
    const params = [_]Param{.{ .name = "org", .value = "zig" }};
    const P = Path(struct { org: []const u8, id: u64 });
    try testing.expectError(error.MissingPathParam, P.fromContext(FakeCtx{ .params = &params }));
}
