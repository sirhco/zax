//! hello-service — a minimal Zax application, as a standalone package that
//! depends on Zax through build.zig.zon (see ../build.zig.zon). It exercises
//! the public API: State, Path, Query, Json, and Alloc extractors, middleware,
//! and the Juicy Main entry point.
//!
//!   zig build run     # serve on http://127.0.0.1:8081
//!   zig build test    # unit-test the handlers (no sockets needed)

const std = @import("std");
const zax = @import("zax");

/// Read-only application state, shared across handlers without locks.
const Store = struct { greeting: []const u8 };

const Api = zax.App(*const Store);

// --- Middleware: stamp every response (post-processing) ---
fn poweredBy(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-powered-by", "zax");
}

// --- Handlers ---
fn health() zax.Response {
    return zax.Response.text("ok\n");
}

fn greet(
    s: zax.State(*const Store),
    p: zax.Path(struct { name: []const u8 }),
    a: zax.Alloc,
) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "Hi {s}, {s}\n", .{ p.value.name, s.value.greeting });
    return zax.Response.text(body);
}

fn search(
    q: zax.Query(struct { q: []const u8, limit: ?u32 }),
    a: zax.Alloc,
) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "q={s} limit={?d}\n", .{ q.value.q, q.value.limit });
    return zax.Response.text(body);
}

// Json consumes the body, so it must be the last parameter.
fn echo(a: zax.Alloc, body: zax.Json(struct { name: []const u8 })) !zax.Response {
    const out = try std.fmt.allocPrint(a.value, "{{\"echo\":\"{s}\"}}", .{body.value.name});
    return zax.Response.jsonRaw(out);
}

pub fn main(init: std.process.Init) !void {
    var store = Store{ .greeting = "welcome to zax" };
    var app = try Api.init(init.gpa, &store, .{});
    defer app.deinit();

    try app.use(&poweredBy);
    try app.get("/health", health);
    try app.get("/greet/:name", greet);
    try app.get("/search", search);
    try app.post("/echo", echo);

    std.debug.print("hello-service listening on http://127.0.0.1:8081\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8081) });
}

// --- Handler unit tests ---
// Handlers are plain functions; test them by constructing the extractor values
// directly (each extractor is a struct with a public `value` field) and calling
// the handler. No sockets, no server — fast and deterministic.
const testing = std.testing;

test "health handler" {
    try testing.expectEqualStrings("ok\n", health().body);
}

test "greet handler formats name + state greeting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const store = Store{ .greeting = "hi there" };
    const r = try greet(
        .{ .value = &store },
        .{ .value = .{ .name = "ada" } },
        .{ .value = arena.allocator() },
    );
    try testing.expectEqualStrings("Hi ada, hi there\n", r.body);
}

test "search handler renders optional query field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try search(
        .{ .value = .{ .q = "zig", .limit = 5 } },
        .{ .value = arena.allocator() },
    );
    try testing.expectEqualStrings("q=zig limit=5\n", r.body);
}

test "echo handler serializes JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try echo(
        .{ .value = arena.allocator() },
        .{ .value = .{ .name = "grace" } },
    );
    try testing.expectEqualStrings("{\"echo\":\"grace\"}", r.body);
}
