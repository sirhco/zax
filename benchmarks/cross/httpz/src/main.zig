//! Cross-framework benchmark server — httpz (karlseguin/http.zig).
//! Three routes matched 1:1 with the zax and axum/Go servers:
//!   GET  /            -> "hello"
//!   GET  /users/:id   -> the captured id (echoes the path param)
//!   POST /echo        -> JSON echo of {"msg": "..."}
//! Listen on 127.0.0.1:8084 (ReleaseFast, no logging).

const std = @import("std");
const httpz = @import("httpz");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var server = try httpz.Server(void).init(init.io, allocator, .{
        .address = .localhost(8084),
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", hello, .{});
    router.get("/users/:id", user, .{});
    router.post("/echo", echo, .{});

    try server.listen();
}

fn hello(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "hello";
}

fn user(req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id") orelse "";
    res.body = id;
}

const EchoMsg = struct { msg: []const u8 };

fn echo(req: *httpz.Request, res: *httpz.Response) !void {
    const parsed = try req.json(EchoMsg) orelse {
        res.status = 400;
        res.body = "bad request";
        return;
    };
    try res.json(EchoMsg{ .msg = parsed.msg }, .{});
}
