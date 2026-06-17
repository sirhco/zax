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
        // SPIKE RESULT — std.Io.Evented cannot serve TCP in Zig 0.16, so we
        // refuse up front instead of attempting it.
        //
        // What was tried (preserved in git history at the first spike commit):
        // construct std.Io.Evented, run Api.serve inside a fiber via
        // io.async()/future.await() (the fiber-entry model DOES work). But the
        // serve aborts: the macOS (Dispatch) and Linux (Uring) backends wire
        // their net ops (netListenIp/netAccept/netSend/netRead/...) to
        // `*Unavailable` stubs — only the BSD Kqueue backend implements
        // listen/accept, and it isn't selected on macOS or Linux. listen()
        // therefore fails (error.NetworkDown) and the evented runtime aborts
        // inside the fiber (SIGABRT) rather than returning a catchable error.
        // zax's Io abstraction is pluggable and correct; std's evented backends
        // simply lack socket IO. See
        // docs/superpowers/specs/2026-06-17-evented-io-decision.md.
        std.debug.print(
            "ZAX_IO=evented unsupported: std.Io.Evented has no TCP on this platform " ++
                "in Zig 0.16 (Dispatch/Uring net ops are Unavailable stubs). " ++
                "See docs/superpowers/specs/2026-06-17-evented-io-decision.md\n",
            .{},
        );
        std.process.exit(1);
    } else {
        std.debug.print("zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, io=threaded)\n", .{ port, nodelay });
        try app.serve(init.io, .{ .ip4 = .loopback(port) });
    }
}
