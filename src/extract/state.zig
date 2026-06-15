//! `State(T)` — inject the application's shared, read-only state into a handler.
//! The router is parameterized by one concrete app-state type; `State(T)` simply
//! hands it through, so `T` must match that type. Read-only sharing means no
//! reference counting and no runtime lock for reads — typically `T` is a
//! `*const Something` (e.g. a connection pool).

const std = @import("std");

pub fn State(comptime T: type) type {
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) error{}!@This() {
            const Got = @TypeOf(ctx.state);
            if (Got != T) @compileError(
                "State(" ++ @typeName(T) ++ ") does not match app state type " ++ @typeName(Got),
            );
            return .{ .value = ctx.state };
        }
    };
}

// ----------------------------------------------------------------------------
const testing = std.testing;

test "State passes the app state through read-only" {
    const Db = struct { name: []const u8 };
    var db = Db{ .name = "primary" };
    const ctx = .{ .state = &db };
    const s = try State(*Db).fromContext(ctx);
    try testing.expectEqualStrings("primary", s.value.name);
    // Same pointer — no copy, read-only sharing.
    try testing.expectEqual(@as(*Db, &db), s.value);
}
