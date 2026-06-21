//! Cross-framework benchmark server — httpz (karlseguin/http.zig).
//! Three routes matched 1:1 with the zax and axum/Go servers:
//!   GET  /            -> "hello"
//!   GET  /users/:id   -> the captured id (echoes the path param)
//!   POST /echo        -> JSON echo of {"msg": "..."}
//!   GET  /large       -> buffered ~PAYLOAD_KB KB JSON body
//! Listen on 127.0.0.1:8084 (ReleaseFast, no logging).

const std = @import("std");
const httpz = @import("httpz");

/// Module-level storage for the pre-built large-payload body.
/// Allocated once at startup from init.gpa and never freed (process lifetime).
var large_body: []const u8 = "";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Large-payload route: PAYLOAD_KB=N sets the response size in kilobytes (default 64).
    const payload_kb: usize = if (init.environ_map.get("PAYLOAD_KB")) |v|
        std.fmt.parseUnsigned(usize, v, 10) catch 64
    else
        64;
    {
        const n = @max(payload_kb * 1024, 16);
        const buf = try allocator.alloc(u8, n);
        const prefix = "{\"data\":\"";
        const suffix = "\"}";
        @memcpy(buf[0..prefix.len], prefix);
        const fill_end = n - suffix.len;
        @memset(buf[prefix.len..fill_end], 'x');
        @memcpy(buf[fill_end..n], suffix);
        large_body = buf;
    }

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
    router.get("/large", largeFn, .{});

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

fn largeFn(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.body = large_body;
}
