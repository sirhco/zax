//! Path-segment radix/trie router, generic over a terminal payload type `T`.
//! Segments are split on '/'. A segment written ":name" matches any single
//! segment and captures it. Captured parameter values are `[]const u8` slices
//! into the path passed to `match` (zero-copy); parameter names are slices into
//! the pattern stored at insert time.
//!
//! A segment written "*name" is a catch-all: it must be the terminal
//! (last) segment and matches one or more remaining segments, capturing the
//! entire tail (slashes included) zero-copy into the named param. The empty
//! tail is not matched ("/assets/*path" matches "/assets/x" and "/assets/a/b"
//! but not bare "/assets" or "/assets/").
//!
//! Precedence at a node is static > param > wildcard: "/users/me" wins over
//! "/users/:id" for the path "/users/me", and a static or single-segment param
//! match wins over a catch-all at the same node. If a higher-precedence subtree
//! dead-ends, the matcher falls back to the next kind, so a catch-all still
//! captures paths that a sibling param could not complete (e.g. with both
//! "/a/:id" and "/a/*rest", the path "/a/x/y" falls through to "*rest").

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const MatchError = error{TooManyParams};

pub fn Tree(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Match = struct {
            value: T,
            params: []const Param,
        };

        const Node = struct {
            static: std.StringHashMapUnmanaged(*Node) = .{},
            param_child: ?*Node = null,
            param_name: []const u8 = "",
            wildcard_child: ?*Node = null,
            slot: ?T = null,

            fn deinit(node: *Node, gpa: Allocator) void {
                var it = node.static.valueIterator();
                while (it.next()) |child| child.*.deinit(gpa);
                node.static.deinit(gpa);
                if (node.param_child) |child| child.deinit(gpa);
                if (node.wildcard_child) |child| child.deinit(gpa);
                gpa.destroy(node);
            }
        };

        gpa: Allocator,
        root: *Node,

        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const root = try gpa.create(Node);
            root.* = .{};
            return .{ .gpa = gpa, .root = root };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit(self.gpa);
            self.* = undefined;
        }

        /// Walk/insert `pattern`, returning a pointer to the terminal payload
        /// slot. The slot is `null` if the terminal was freshly created, letting
        /// the caller distinguish "new route" from "route already registered".
        pub fn getOrPutSlot(self: *Self, pattern: []const u8) Allocator.Error!*?T {
            var node = self.root;
            var segs = std.mem.splitScalar(u8, pattern, '/');
            while (segs.next()) |seg| {
                if (seg.len == 0) continue;
                if (seg[0] == ':') {
                    const name = seg[1..];
                    if (node.param_child == null) {
                        const child = try self.gpa.create(Node);
                        child.* = .{ .param_name = name };
                        node.param_child = child;
                    }
                    node = node.param_child.?;
                } else if (seg[0] == '*') {
                    const name = seg[1..];
                    if (node.wildcard_child == null) {
                        const child = try self.gpa.create(Node);
                        child.* = .{ .param_name = name };
                        node.wildcard_child = child;
                    }
                    node = node.wildcard_child.?;
                } else {
                    const gop = try node.static.getOrPut(self.gpa, seg);
                    if (!gop.found_existing) {
                        const child = try self.gpa.create(Node);
                        child.* = .{};
                        gop.value_ptr.* = child;
                    }
                    node = gop.value_ptr.*;
                }
            }
            return &node.slot;
        }

        /// Match `path`, filling captured params into `params_buf`. Returns null
        /// when no route's terminal payload is set for the path.
        pub fn match(self: *Self, path: []const u8, params_buf: []Param) MatchError!?Match {
            const segs = std.mem.splitScalar(u8, path, '/');
            return matchNode(self.root, path, segs, params_buf, 0);
        }

        /// Recursive matcher. Tries children in precedence order static > param >
        /// wildcard, falling back to the next kind when a chosen subtree
        /// dead-ends. `n` is the number of params captured so far in
        /// `params_buf`. The segment iterator is passed by value so each branch
        /// resumes from the same position independently.
        fn matchNode(
            node: *Node,
            path: []const u8,
            segs: std.mem.SplitIterator(u8, .scalar),
            params_buf: []Param,
            n: usize,
        ) MatchError!?Match {
            // Advance to the next non-empty segment.
            var it = segs;
            const seg = while (it.next()) |s| {
                if (s.len != 0) break s;
            } else {
                // No more segments: this node is the terminal for the path.
                const value = node.slot orelse return null;
                return .{ .value = value, .params = params_buf[0..n] };
            };

            // 1. Static child (exact literal) wins first.
            if (node.static.get(seg)) |child| {
                if (try matchNode(child, path, it, params_buf, n)) |m| return m;
            }

            // 2. Param child (single segment capture) next.
            if (node.param_child) |child| {
                if (n == params_buf.len) return error.TooManyParams;
                params_buf[n] = .{ .name = child.param_name, .value = seg };
                if (try matchNode(child, path, it, params_buf, n + 1)) |m| return m;
            }

            // 3. Wildcard child (catch-all) last: captures the rest of the path.
            if (node.wildcard_child) |child| {
                if (child.slot) |value| {
                    if (n == params_buf.len) return error.TooManyParams;
                    const offset = @intFromPtr(seg.ptr) - @intFromPtr(path.ptr);
                    params_buf[n] = .{ .name = child.param_name, .value = path[offset..] };
                    return .{ .value = value, .params = params_buf[0 .. n + 1] };
                }
            }

            return null;
        }
    };
}

// ----------------------------------------------------------------------------
// Tests  (payload type = usize for isolation from the handler machinery)
// ----------------------------------------------------------------------------
const testing = std.testing;

fn put(tree: *Tree(usize), pattern: []const u8, v: usize) !void {
    const slot = try tree.getOrPutSlot(pattern);
    slot.* = v;
}

test "static routes match and miss" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/", 1);
    try put(&tree, "/users", 2);
    try put(&tree, "/users/me", 3);

    var pb: [8]Param = undefined;
    try testing.expectEqual(@as(usize, 1), (try tree.match("/", &pb)).?.value);
    try testing.expectEqual(@as(usize, 2), (try tree.match("/users", &pb)).?.value);
    try testing.expectEqual(@as(usize, 3), (try tree.match("/users/me", &pb)).?.value);
    try testing.expect((try tree.match("/nope", &pb)) == null);
    try testing.expect((try tree.match("/users/x", &pb)) == null);
}

test "param capture is zero-copy into the path" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/users/:id", 7);

    const path = "/users/42";
    var pb: [8]Param = undefined;
    const m = (try tree.match(path, &pb)).?;
    try testing.expectEqual(@as(usize, 7), m.value);
    try testing.expectEqual(@as(usize, 1), m.params.len);
    try testing.expectEqualStrings("id", m.params[0].name);
    try testing.expectEqualStrings("42", m.params[0].value);
    // Captured value points inside `path`.
    const base = @intFromPtr(path.ptr);
    const vp = @intFromPtr(m.params[0].value.ptr);
    try testing.expect(vp >= base and vp < base + path.len);
}

test "multiple params and mixed static/param segments" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/org/:org/repo/:repo", 9);

    var pb: [8]Param = undefined;
    const m = (try tree.match("/org/zig/repo/zax", &pb)).?;
    try testing.expectEqual(@as(usize, 9), m.value);
    try testing.expectEqual(@as(usize, 2), m.params.len);
    try testing.expectEqualStrings("org", m.params[0].name);
    try testing.expectEqualStrings("zig", m.params[0].value);
    try testing.expectEqualStrings("repo", m.params[1].name);
    try testing.expectEqualStrings("zax", m.params[1].value);
}

test "static beats param at the same node" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/users/:id", 1);
    try put(&tree, "/users/me", 2);

    var pb: [8]Param = undefined;
    try testing.expectEqual(@as(usize, 2), (try tree.match("/users/me", &pb)).?.value);
    try testing.expectEqual(@as(usize, 1), (try tree.match("/users/99", &pb)).?.value);
}

test "getOrPutSlot reports new vs existing" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    const s1 = try tree.getOrPutSlot("/a");
    try testing.expect(s1.* == null);
    s1.* = 5;
    const s2 = try tree.getOrPutSlot("/a");
    try testing.expectEqual(@as(?usize, 5), s2.*);
}

test "TooManyParams when capture buffer is too small" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/:a/:b/:c", 1);
    var pb: [2]Param = undefined;
    try testing.expectError(error.TooManyParams, tree.match("/1/2/3", &pb));
}

test "catch-all captures multi-segment tail" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/assets/*path", 1);

    const p = "/assets/css/app.css";
    var pb: [8]Param = undefined;
    const m = (try tree.match(p, &pb)).?;
    try testing.expectEqual(@as(usize, 1), m.value);
    try testing.expectEqual(@as(usize, 1), m.params.len);
    try testing.expectEqualStrings("path", m.params[0].name);
    try testing.expectEqualStrings("css/app.css", m.params[0].value);
    // Zero-copy: tail points inside `p`.
    const base = @intFromPtr(p.ptr);
    const vp = @intFromPtr(m.params[0].value.ptr);
    try testing.expect(vp >= base and vp < base + p.len);
}

test "catch-all captures a single-segment tail" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/assets/*path", 1);
    var pb: [8]Param = undefined;
    const m = (try tree.match("/assets/x", &pb)).?;
    try testing.expectEqualStrings("x", m.params[0].value);
}

test "catch-all does NOT match the bare prefix (empty tail)" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/assets/*path", 1);
    var pb: [8]Param = undefined;
    try testing.expect((try tree.match("/assets", &pb)) == null);
    try testing.expect((try tree.match("/assets/", &pb)) == null);
}

test "static and param beat catch-all at the same node" {
    var tree = try Tree(usize).init(testing.allocator);
    defer tree.deinit();
    try put(&tree, "/a/*rest", 1);
    try put(&tree, "/a/:id", 2);
    try put(&tree, "/a/exact", 3);
    var pb: [8]Param = undefined;
    try testing.expectEqual(@as(usize, 3), (try tree.match("/a/exact", &pb)).?.value); // static
    try testing.expectEqual(@as(usize, 2), (try tree.match("/a/99", &pb)).?.value);    // param (single seg)
    try testing.expectEqual(@as(usize, 1), (try tree.match("/a/x/y", &pb)).?.value);   // wildcard (deeper)
}
