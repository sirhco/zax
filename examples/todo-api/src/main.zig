//! todo-api — a REST/CRUD JSON API on zax. Demonstrates mutable shared state
//! (App(*Store) + an atomic spinlock), the Json/Path/State extractors, JSON
//! responses with real status codes, and observability (metrics + access log).
//!
//!   zig build run    # serve on http://127.0.0.1:8082
//!   zig build test   # unit-test the store + handlers

const std = @import("std");
const zax = @import("zax");

const Todo = struct { id: u32, title: []const u8, done: bool };
const NewTodo = struct { title: []const u8 };
const Patch = struct { title: ?[]const u8 = null, done: ?bool = null };

/// In-memory store. Mutated by handlers on multiple threads → guarded by an atomic spinlock.
/// Methods copy results OUT into the caller's request arena under the lock, so the
/// handler serializes JSON lock-free and immune to concurrent mutation.
/// In Zig 0.16 `std.Thread.Mutex` was removed; `std.Io.Mutex.lock` requires an
/// `Io` instance. We replicate the same tiny atomic-spinlock pattern used by
/// `zax.AccessLogger` in `src/observe.zig` — short critical sections, so
/// contention is brief.
const Spinlock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Spinlock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spinlock) void {
        self.locked.store(false, .release);
    }
};

const Store = struct {
    gpa: std.mem.Allocator,
    mu: Spinlock = .{},
    items: std.ArrayListUnmanaged(Todo) = .empty,
    next_id: u32 = 1,

    fn deinit(self: *Store) void {
        for (self.items.items) |t| self.gpa.free(t.title);
        self.items.deinit(self.gpa);
    }

    fn list(self: *Store, arena: std.mem.Allocator) ![]Todo {
        self.mu.lock();
        defer self.mu.unlock();
        const out = try arena.alloc(Todo, self.items.items.len);
        for (self.items.items, out) |src, *dst| dst.* = .{ .id = src.id, .title = try arena.dupe(u8, src.title), .done = src.done };
        return out;
    }

    fn add(self: *Store, arena: std.mem.Allocator, title: []const u8) !Todo {
        self.mu.lock();
        defer self.mu.unlock();
        const owned = try self.gpa.dupe(u8, title); // store-owned copy (request body is request-scoped)
        errdefer self.gpa.free(owned);
        const t = Todo{ .id = self.next_id, .title = owned, .done = false };
        try self.items.append(self.gpa, t);
        self.next_id += 1;
        return .{ .id = t.id, .title = try arena.dupe(u8, owned), .done = false };
    }

    fn get(self: *Store, arena: std.mem.Allocator, id: u32) !?Todo {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.items.items) |t| if (t.id == id)
            return Todo{ .id = t.id, .title = try arena.dupe(u8, t.title), .done = t.done };
        return null;
    }

    fn update(self: *Store, arena: std.mem.Allocator, id: u32, patch: Patch) !?Todo {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.items.items) |*t| if (t.id == id) {
            if (patch.title) |nt| {
                const owned = try self.gpa.dupe(u8, nt);
                self.gpa.free(t.title);
                t.title = owned;
            }
            if (patch.done) |d| t.done = d;
            return Todo{ .id = t.id, .title = try arena.dupe(u8, t.title), .done = t.done };
        };
        return null;
    }

    fn remove(self: *Store, id: u32) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.items.items, 0..) |t, i| if (t.id == id) {
            self.gpa.free(t.title);
            _ = self.items.orderedRemove(i);
            return true;
        };
        return false;
    }
};

const Api = zax.App(*Store);

// --- Handlers ---
fn listTodos(s: zax.State(*Store), a: zax.Alloc) !zax.Response {
    const todos = try s.value.list(a.value);
    return zax.Response.json(a.value, todos);
}

fn createTodo(s: zax.State(*Store), a: zax.Alloc, body: zax.Json(NewTodo)) !zax.Response {
    if (body.value.title.len == 0) return zax.Response.fromStatus(.bad_request);
    const t = try s.value.add(a.value, body.value.title);
    var r = try zax.Response.json(a.value, t);
    r.status = .created; // 201
    return r;
}

fn getTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 }), a: zax.Alloc) !zax.Response {
    const t = (try s.value.get(a.value, p.value.id)) orelse return zax.Response.fromStatus(.not_found);
    return zax.Response.json(a.value, t);
}

fn updateTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 }), a: zax.Alloc, body: zax.Json(Patch)) !zax.Response {
    const t = (try s.value.update(a.value, p.value.id, body.value)) orelse return zax.Response.fromStatus(.not_found);
    return zax.Response.json(a.value, t);
}

fn deleteTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 })) zax.Response {
    return if (s.value.remove(p.value.id)) zax.Response.fromStatus(.no_content) else zax.Response.fromStatus(.not_found);
}

fn metrics(s: zax.State(*Store), a: zax.Alloc) !zax.Response {
    _ = s;
    // writePrometheus takes *std.Io.Writer; allocate a large-enough buffer in
    // the request arena and use a fixed writer, then slice the written bytes.
    const buf = try a.value.alloc(u8, 4096);
    var w = std.Io.Writer.fixed(buf);
    try global_metrics.writePrometheus(&w);
    return zax.Response.text(w.buffered());
}

var global_metrics: zax.Metrics = .{};

pub fn main(init: std.process.Init) !void {
    var store = Store{ .gpa = init.gpa };
    defer store.deinit();
    var app = try Api.init(init.gpa, &store, .{});
    defer app.deinit();

    // AccessLogger requires a *std.Io.Writer. Build a file writer for stderr
    // (std.Io.File.Writer wraps std.Io.Writer as its `interface` field) then
    // point AccessLogger at that interface.
    var log_buf: [256]u8 = undefined;
    var stderr_fw: std.Io.File.Writer = .init(.stderr(), init.io, &log_buf);
    var access = zax.AccessLogger{ .writer = &stderr_fw.interface };
    try app.observe(access.observer());
    try app.observe(global_metrics.observer());

    try app.get("/todos", listTodos);
    try app.post("/todos", createTodo);
    try app.get("/todos/:id", getTodo);
    try app.put("/todos/:id", updateTodo);
    try app.delete("/todos/:id", deleteTodo);
    try app.get("/metrics", metrics);

    std.debug.print("todo-api listening on http://127.0.0.1:8082\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8082) });
}

// --- Tests (store logic; no sockets) ---
const testing = std.testing;

test "store add/get/update/remove" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var s = Store{ .gpa = testing.allocator };
    defer s.deinit();

    const a = try s.add(ar, "buy milk");
    try testing.expectEqual(@as(u32, 1), a.id);
    try testing.expectEqualStrings("buy milk", a.title);

    const g = (try s.get(ar, 1)).?;
    try testing.expectEqualStrings("buy milk", g.title);
    try testing.expect(!g.done);

    const u = (try s.update(ar, 1, .{ .done = true })).?;
    try testing.expect(u.done);

    try testing.expect(s.remove(1));
    try testing.expect((try s.get(ar, 1)) == null);
}
