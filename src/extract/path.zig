//! `Path(T)` — bind captured URL path parameters to `T`.
//!  - `T` a struct: each field is filled from the same-named `:param`.
//!  - `T` a scalar: filled from the single captured parameter.
//! Parameter values are borrowed slices into the request path (zero-copy);
//! scalar fields are parsed from them.

const std = @import("std");
const scalar = @import("scalar.zig");
const url = @import("../url.zig");

pub const Error = error{ MissingPathParam, InvalidScalar, InvalidEnum };

pub fn Path(comptime T: type) type {
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) !@This() {
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    var v: T = undefined;
                    inline for (s.fields) |f| {
                        const raw = find(ctx.params, f.name) orelse return error.MissingPathParam;
                        const decoded = try url.decode(ctx.arena, raw, false);
                        @field(v, f.name) = try scalar.parse(f.type, decoded);
                    }
                    return .{ .value = v };
                },
                else => {
                    if (ctx.params.len == 0) return error.MissingPathParam;
                    const decoded = try url.decode(ctx.arena, ctx.params[0].value, false);
                    return .{ .value = try scalar.parse(T, decoded) };
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

const FakeCtx = struct { params: []const Param, arena: std.mem.Allocator };

fn fakeCtx(params: []const Param, arena: std.mem.Allocator) FakeCtx {
    return .{ .params = params, .arena = arena };
}

test "Path binds struct fields from named params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = [_]Param{
        .{ .name = "org", .value = "zig" },
        .{ .name = "id", .value = "42" },
    };
    const P = Path(struct { org: []const u8, id: u64 });
    const p = try P.fromContext(fakeCtx(&params, arena.allocator()));
    try testing.expectEqualStrings("zig", p.value.org);
    try testing.expectEqual(@as(u64, 42), p.value.id);
}

test "Path scalar binds single param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = [_]Param{.{ .name = "id", .value = "7" }};
    const p = try Path(u32).fromContext(fakeCtx(&params, arena.allocator()));
    try testing.expectEqual(@as(u32, 7), p.value);
}

test "Path missing param errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = [_]Param{.{ .name = "org", .value = "zig" }};
    const P = Path(struct { org: []const u8, id: u64 });
    try testing.expectError(error.MissingPathParam, P.fromContext(fakeCtx(&params, arena.allocator())));
}

test "Path decodes percent-encoded params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = [_]Param{.{ .name = "name", .value = "John%20Doe" }};
    const P = Path(struct { name: []const u8 });
    const p = try P.fromContext(fakeCtx(&params, arena.allocator()));
    try testing.expectEqualStrings("John Doe", p.value.name);
}
