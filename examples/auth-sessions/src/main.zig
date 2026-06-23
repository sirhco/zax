//! auth-sessions — cookie sessions + a guard middleware on zax. POST /login sets a
//! session cookie; a middleware reads the Cookies extractor and rejects requests to
//! protected routes with 401 when the session is missing/invalid.
//!
//!   zig build run    # serve on http://127.0.0.1:8083
//!   zig build test   # unit-test the session store

const std = @import("std");
const zax = @import("zax");

/// Tiny atomic spinlock — `std.Thread.Mutex` was removed in Zig 0.16.
/// Pattern mirrors `src/observe.zig` in the zax library itself.
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

const Sessions = struct {
    gpa: std.mem.Allocator,
    mutex: Spinlock = .{},
    map: std.StringHashMapUnmanaged([]const u8) = .empty, // token -> user

    fn deinit(self: *Sessions) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.map.deinit(self.gpa);
    }

    fn create(self: *Sessions, user: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Demo token: not cryptographically strong — a real app would use a CSPRNG.
        var buf: [16]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = "0123456789abcdef"[(self.map.count() + i) % 16];
        const token = try self.gpa.dupe(u8, &buf);
        try self.map.put(self.gpa, token, try self.gpa.dupe(u8, user));
        return token;
    }

    /// Returns the user for a token (arena-duped), or null. Lock-safe copy-out.
    fn userFor(self: *Sessions, arena: std.mem.Allocator, token: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(token)) |u| return try arena.dupe(u8, u);
        return null;
    }

    fn destroy(self: *Sessions, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(token)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
    }
};

const Api = zax.App(*Sessions);
const Creds = struct { user: []const u8, pass: []const u8 };

/// Guard middleware: requires a valid `session` cookie, else 401.
fn requireAuth(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const cookies = try zax.Cookies.fromContext(ctx);
    const token = cookies.get("session") orelse return zax.Response.fromStatus(.unauthorized);
    const user = (try ctx.state.userFor(ctx.arena, token)) orelse return zax.Response.fromStatus(.unauthorized);
    _ = user; // a real app would stash this for downstream handlers
    return next.run();
}

fn index() zax.Response {
    return zax.Response.text("public homepage — POST /login to get a session\n");
}

fn login(s: zax.State(*Sessions), a: zax.Alloc, body: zax.Json(Creds)) !zax.Response {
    // Demo auth: accept any non-empty user with pass == "secret".
    if (body.value.user.len == 0 or !std.mem.eql(u8, body.value.pass, "secret"))
        return zax.Response.fromStatus(.unauthorized);
    const token = try s.value.create(body.value.user);
    const r = zax.Response.text("logged in\n");
    return r.withCookie(a.value, .{ .name = "session", .value = token, .path = "/", .http_only = true, .same_site = .lax });
}

fn me(cookies: zax.Cookies, s: zax.State(*Sessions), a: zax.Alloc) !zax.Response {
    const token = cookies.get("session").?; // guard guarantees presence
    const user = (try s.value.userFor(a.value, token)).?;
    const body = try std.fmt.allocPrint(a.value, "you are: {s}\n", .{user});
    return zax.Response.text(body);
}

fn logout(cookies: zax.Cookies, s: zax.State(*Sessions), a: zax.Alloc) !zax.Response {
    if (cookies.get("session")) |token| s.value.destroy(token);
    const r = zax.Response.text("logged out\n");
    return r.expireCookie(a.value, "session", "/");
}

pub fn main(init: std.process.Init) !void {
    var sessions = Sessions{ .gpa = init.gpa };
    defer sessions.deinit();
    var app = try Api.init(init.gpa, &sessions, .{});
    defer app.deinit();

    try app.get("/", index);
    try app.post("/login", login);
    try app.post("/logout", logout);
    // Protected: requireAuth runs before the handler.
    try app.getWith("/me", .{&requireAuth}, me);

    std.debug.print("auth-sessions listening on http://127.0.0.1:8083\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8083) });
}

const testing = std.testing;

test "sessions create / userFor / destroy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = Sessions{ .gpa = testing.allocator };
    defer s.deinit();
    const token = try s.create("ada");
    try testing.expectEqualStrings("ada", (try s.userFor(arena.allocator(), token)).?);
    s.destroy(token);
    try testing.expect((try s.userFor(arena.allocator(), token)) == null);
}
