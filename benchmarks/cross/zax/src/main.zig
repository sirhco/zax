//! Cross-framework benchmark server — zax.
//! Three routes matched 1:1 with the axum and Go std-lib servers:
//!   GET  /            -> "hello"
//!   GET  /users/{id}  -> the captured id (echoes the path param)
//!   POST /echo        -> JSON echo of {"msg": "..."}
//! Run: `zig build -Doptimize=ReleaseFast run` (listens on :8081).

const std = @import("std");
const zax = @import("zax");

const Db = struct {};
const Api = zax.App(*const Db);

fn hello() zax.Response {
    return zax.Response.text("hello");
}

fn user(p: zax.Path(struct { id: []const u8 })) zax.Response {
    return zax.Response.text(p.value.id);
}

// `Json` consumes the body, so it must be the last parameter.
fn echo(a: zax.Alloc, body: zax.Json(struct { msg: []const u8 })) !zax.Response {
    return zax.Response.json(a.value, .{ .msg = body.value.msg });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var db = Db{};
    var app = try Api.init(init.gpa, &db, .{});
    defer app.deinit();

    try app.get("/", hello);
    try app.get("/users/:id", user);
    try app.post("/echo", echo);

    const port: u16 = 8081;
    std.debug.print("zax bench server on http://127.0.0.1:{d}\n", .{port});
    try app.serve(io, .{ .ip4 = .loopback(port) });
}
