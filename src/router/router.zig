//! Router: maps (Method, path) to a handler, layered over the radix `Tree`.
//! Generic over the `Handler` payload type so the server can instantiate it with
//! its own type-erased handler (built by the comptime extractor system) while
//! tests use a trivial stand-in.
//!
//! Match outcomes mirror HTTP semantics: a path with no route is `not_found`
//! (404); a path that exists but not for this method is `method_not_allowed`
//! (405) and carries the set of allowed methods for the `Allow` header.

const std = @import("std");
const radix = @import("radix.zig");
const Method = @import("../http/request.zig").Method;

pub const Param = radix.Param;
pub const MethodSet = std.EnumSet(Method);

pub fn Router(comptime Handler: type) type {
    return struct {
        const Self = @This();

        const MethodTable = struct {
            entries: std.EnumArray(Method, ?Handler) = std.EnumArray(Method, ?Handler).initFill(null),
        };

        pub const Found = struct {
            handler: Handler,
            params: []const Param,
        };

        pub const Outcome = union(enum) {
            found: Found,
            method_not_allowed: MethodSet,
            not_found,
        };

        tree: radix.Tree(MethodTable),

        pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return .{ .tree = try radix.Tree(MethodTable).init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
        }

        /// Register `handler` for `method` at `pattern`. Re-registering the same
        /// method+pattern overwrites the previous handler.
        pub fn register(self: *Self, method: Method, pattern: []const u8, handler: Handler) std.mem.Allocator.Error!void {
            const slot = try self.tree.getOrPutSlot(pattern);
            if (slot.* == null) slot.* = .{};
            slot.*.?.entries.set(method, handler);
        }

        // Convenience verbs.
        pub fn get(self: *Self, pattern: []const u8, handler: Handler) !void {
            return self.register(.GET, pattern, handler);
        }
        pub fn post(self: *Self, pattern: []const u8, handler: Handler) !void {
            return self.register(.POST, pattern, handler);
        }
        pub fn put(self: *Self, pattern: []const u8, handler: Handler) !void {
            return self.register(.PUT, pattern, handler);
        }
        pub fn delete(self: *Self, pattern: []const u8, handler: Handler) !void {
            return self.register(.DELETE, pattern, handler);
        }

        pub fn match(self: *Self, method: Method, path: []const u8, params_buf: []Param) radix.MatchError!Outcome {
            const m = (try self.tree.match(path, params_buf)) orelse return .not_found;
            if (m.value.entries.get(method)) |handler| {
                return .{ .found = .{ .handler = handler, .params = m.params } };
            }
            // Path exists but not for this method: report 405 + allowed set.
            var allowed = MethodSet.initEmpty();
            inline for (std.meta.tags(Method)) |tag| {
                if (m.value.entries.get(tag) != null) allowed.insert(tag);
            }
            return .{ .method_not_allowed = allowed };
        }
    };
}

// ----------------------------------------------------------------------------
// Tests  (Handler stand-in = a niladic fn pointer)
// ----------------------------------------------------------------------------
const testing = std.testing;
const TestHandler = *const fn () usize;

fn h1() usize {
    return 1;
}
fn h2() usize {
    return 2;
}

test "routes by method, 404 and 405" {
    var r = try Router(TestHandler).init(testing.allocator);
    defer r.deinit();
    try r.get("/users/:id", h1);
    try r.post("/users", h2);

    var pb: [8]Param = undefined;

    // Found GET with param capture.
    switch (try r.match(.GET, "/users/42", &pb)) {
        .found => |f| {
            try testing.expectEqual(@as(usize, 1), f.handler());
            try testing.expectEqualStrings("id", f.params[0].name);
            try testing.expectEqualStrings("42", f.params[0].value);
        },
        else => return error.TestUnexpectedResult,
    }

    // Found POST.
    switch (try r.match(.POST, "/users", &pb)) {
        .found => |f| try testing.expectEqual(@as(usize, 2), f.handler()),
        else => return error.TestUnexpectedResult,
    }

    // Unknown path -> 404.
    try testing.expect((try r.match(.GET, "/nope", &pb)) == .not_found);

    // Known path, wrong method -> 405 with allowed = {POST}.
    switch (try r.match(.DELETE, "/users", &pb)) {
        .method_not_allowed => |allowed| {
            try testing.expect(allowed.contains(.POST));
            try testing.expect(!allowed.contains(.DELETE));
            try testing.expect(!allowed.contains(.GET));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "re-register overwrites handler" {
    var r = try Router(TestHandler).init(testing.allocator);
    defer r.deinit();
    try r.get("/x", h1);
    try r.get("/x", h2);
    var pb: [4]Param = undefined;
    switch (try r.match(.GET, "/x", &pb)) {
        .found => |f| try testing.expectEqual(@as(usize, 2), f.handler()),
        else => return error.TestUnexpectedResult,
    }
}
