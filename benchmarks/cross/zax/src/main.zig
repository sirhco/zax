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
    // A/B knob for the bench harness: ZAX_NODELAY=0 leaves Nagle on so the
    // run.sh AB=1 mode can measure the on-vs-off tail delta. Default = on.
    const nodelay = if (init.environ_map.get("ZAX_NODELAY")) |v| !std.mem.eql(u8, v, "0") else true;

    // IO backend selector: ZAX_IO=evented -> std.Io.Evented (GCD on macOS, io_uring on Linux)
    // Anything else (incl. unset) -> init.io (std.Io.Threaded, one thread per connection).
    const use_evented = if (init.environ_map.get("ZAX_IO")) |v| std.mem.eql(u8, v, "evented") else false;

    var db = Db{};
    var app = try Api.init(init.gpa, &db, .{ .tcp_nodelay = nodelay });
    defer app.deinit();

    try app.get("/", hello);
    try app.get("/users/:id", user);
    try app.post("/echo", echo);

    const port: u16 = 8081;

    if (use_evented) {
        // std.Io.Evented on macOS is std.Io.Dispatch (GCD-backed fiber scheduler).
        // Construction: init() wires the calling stack frame as the "main fiber".
        // Server code must run inside a fiber spawned via io.async(), because
        // acceptLoop() calls blocking-async ops (accept, read, write) that require
        // a fiber context for suspension/resumption.
        //
        // NOTE: ev.deinit() is intentionally omitted. Dispatch.deinit() calls
        // ev.backing_allocator.free(ev.main_loop_stack[0..main_loop_stack_size])
        // but slicing a [*]align(N)u8 with a comptime-known length yields
        // *align(N)[N]u8 (size=.one), not []align(N)u8 (size=.slice), so
        // Allocator.free's comptime assert fires. This is a Zig 0.16 std bug.
        // For a bench server that runs until SIGKILL the OS reclaims all resources.
        var ev: std.Io.Evented = undefined;
        try ev.init(init.gpa, .{});
        const ev_io = ev.io();
        const backend = comptime @tagName(@import("builtin").os.tag);
        std.debug.print("zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, io=evented/" ++ backend ++ ")\n", .{ port, nodelay });
        var future = ev_io.async(Api.serve, .{ &app, ev_io, .{ .ip4 = .loopback(port) } });
        try future.await(ev_io);
    } else {
        std.debug.print("zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, io=threaded)\n", .{ port, nodelay });
        try app.serve(init.io, .{ .ip4 = .loopback(port) });
    }
}
