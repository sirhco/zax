//! Cross-framework benchmark server — zax.
//! Three routes matched 1:1 with the axum and Go std-lib servers:
//!   GET  /            -> "hello"
//!   GET  /users/{id}  -> the captured id (echoes the path param)
//!   POST /echo        -> JSON echo of {"msg": "..."}
//! Run: `zig build -Doptimize=ReleaseFast run` (listens on :8081).
//!
//! Self-shutdown timer: set ZAX_RUN_SECS=N to have the server stop itself after
//! N seconds (calls app.requestShutdown, which dumps the trace summary if
//! -Dtrace-latency=true was used at build time). Unset / 0 = run forever.

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

/// Timer task: sleep run_secs seconds then call requestShutdown so acceptLoop
/// exits and the trace summary is dumped. Runs concurrently with acceptLoop on
/// the same io. app must remain valid until this task completes (it lives in
/// main's stack for the entire serve lifetime).
const ShutdownCtx = struct {
    app: *Api,
    io: std.Io,
    run_secs: u64,

    fn run(ctx: *ShutdownCtx) void {
        std.Io.sleep(
            ctx.io,
            .{ .nanoseconds = ctx.run_secs * std.time.ns_per_s },
            .awake,
        ) catch {};
        ctx.app.requestShutdown(ctx.io);
    }
};

pub fn main(init: std.process.Init) !void {
    // A/B knob for the bench harness: ZAX_NODELAY=0 leaves Nagle on so the
    // run.sh AB=1 mode can measure the on-vs-off tail delta. Default = on.
    const nodelay = if (init.environ_map.get("ZAX_NODELAY")) |v| !std.mem.eql(u8, v, "0") else true;

    // Worker-pool cap knob: ZAX_MAX_INFLIGHT=N limits concurrent in-flight connections.
    // 0 = unbounded (default; unchanged behavior). INFLIGHT=N in run.sh sets this.
    const max_in_flight: usize = if (init.environ_map.get("ZAX_MAX_INFLIGHT")) |v|
        std.fmt.parseUnsigned(usize, v, 10) catch 0
    else
        0;

    // Keep-alive knob (E2): ZAX_KEEPALIVE=0 disables HTTP keep-alive so each
    // request uses a fresh connection. Default (unset / any other value) = on.
    const keep_alive = if (init.environ_map.get("ZAX_KEEPALIVE")) |v| !std.mem.eql(u8, v, "0") else true;

    // Thread-count knob (E4): ZAX_THREADS=N constructs a dedicated Threaded I/O
    // backend with async_limit=N instead of reusing init.io. N=0 or unset → use
    // init.io unchanged (today's default behavior).
    const threads_n: usize = if (init.environ_map.get("ZAX_THREADS")) |v|
        std.fmt.parseUnsigned(usize, v, 10) catch 0
    else
        0;

    // IO backend selector: ZAX_IO=evented -> std.Io.Evented (GCD on macOS, io_uring on Linux)
    // Anything else (incl. unset) -> init.io (std.Io.Threaded, one thread per connection).
    const use_evented = if (init.environ_map.get("ZAX_IO")) |v| std.mem.eql(u8, v, "evented") else false;

    // Self-shutdown timer: ZAX_RUN_SECS=N → stop after N seconds (dumps trace).
    // 0 or unset → run forever (unchanged behavior).
    const run_secs: u64 = if (init.environ_map.get("ZAX_RUN_SECS")) |v|
        std.fmt.parseUnsigned(u64, v, 10) catch 0
    else
        0;

    var db = Db{};
    var app = try Api.init(init.gpa, &db, .{
        .tcp_nodelay = nodelay,
        .max_in_flight = max_in_flight,
        .keep_alive = keep_alive,
    });
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
    } else if (threads_n > 0) {
        // E4: override the thread/async_limit count with a dedicated Threaded backend.
        var threaded = std.Io.Threaded.init(init.gpa, .{
            .async_limit = std.Io.Limit.limited(threads_n),
        });
        defer threaded.deinit();
        const io = threaded.io();
        if (run_secs > 0) {
            std.debug.print(
                "zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, max_in_flight={d}, keep_alive={}, threads={d}, trace={}, run_secs={d})\n",
                .{ port, nodelay, max_in_flight, keep_alive, threads_n, zax.trace_latency, run_secs },
            );
            try serveWithTimer(&app, io, port, run_secs);
        } else {
            std.debug.print(
                "zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, max_in_flight={d}, keep_alive={}, threads={d}, trace={}, run_secs=∞)\n",
                .{ port, nodelay, max_in_flight, keep_alive, threads_n, zax.trace_latency },
            );
            try app.serve(io, .{ .ip4 = .loopback(port) });
        }
    } else {
        const io = init.io;
        if (run_secs > 0) {
            std.debug.print(
                "zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, max_in_flight={d}, keep_alive={}, threads=init.io, trace={}, run_secs={d})\n",
                .{ port, nodelay, max_in_flight, keep_alive, zax.trace_latency, run_secs },
            );
            try serveWithTimer(&app, io, port, run_secs);
        } else {
            std.debug.print(
                "zax bench server on http://127.0.0.1:{d} (tcp_nodelay={}, max_in_flight={d}, keep_alive={}, threads=init.io, trace={}, run_secs=∞)\n",
                .{ port, nodelay, max_in_flight, keep_alive, zax.trace_latency },
            );
            try app.serve(io, .{ .ip4 = .loopback(port) });
        }
    }
}

/// Bind, spawn a concurrent shutdown timer, run acceptLoop, then await the timer.
/// The timer calls app.requestShutdown(io) after run_secs seconds, which closes
/// the listening socket so acceptLoop exits and (if trace_latency) dumps the
/// phase summary before we return.
fn serveWithTimer(app: *Api, io: std.Io, port: u16, run_secs: u64) !void {
    try app.bind(io, .{ .ip4 = .loopback(port) });

    // Timer task: lives entirely within this function's frame.
    var ctx = ShutdownCtx{ .app = app, .io = io, .run_secs = run_secs };
    var timer_fut = io.async(ShutdownCtx.run, .{&ctx});

    // acceptLoop blocks until requestShutdown closes the socket.
    app.acceptLoop(io);

    // Reap the timer task (it has either already fired or will momentarily).
    timer_fut.await(io);
}
