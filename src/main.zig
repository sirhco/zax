//! Zax demo server, using the Zig 0.16.0 "Juicy Main" entry point: the runtime
//! hands us a ready allocator (`init.gpa`) and Io implementation (`init.io`).
//! Run with `zig build run`, then:
//!   curl localhost:8080/
//!   curl localhost:8080/users/42
//!   curl -X POST localhost:8080/users -d '{"name":"ada"}'

const std = @import("std");
const zax = @import("zax");

/// Read-only application state, shared across all handlers without locks.
const Db = struct { banner: []const u8 };

const Api = zax.App(*const Db);

/// Example middleware: stamp every response with a header (post-processing).
fn poweredBy(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-powered-by", "zax");
}

fn index() zax.Response {
    return zax.Response.text("Hello from Zax\n");
}

fn getUser(p: zax.Path(struct { id: u64 }), a: zax.Alloc) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "user {d}\n", .{p.value.id});
    return zax.Response.text(body);
}

// `Json` consumes the body, so it must be the last parameter.
fn createUser(
    s: zax.State(*const Db),
    a: zax.Alloc,
    body: zax.Json(struct { name: []const u8 }),
) !zax.Response {
    const out = try std.fmt.allocPrint(a.value, "{s}: created user {s}\n", .{ s.value.banner, body.value.name });
    return zax.Response.jsonRaw(out);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var db = Db{ .banner = "zax-demo" };
    var app = try Api.init(init.gpa, &db, .{});
    defer app.deinit();

    try app.use(&poweredBy);
    try app.get("/", index);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);

    const port: u16 = 8080;
    std.debug.print("zax listening on http://127.0.0.1:{d}\n", .{port});
    try app.serve(io, .{ .ip4 = .loopback(port) });
}
