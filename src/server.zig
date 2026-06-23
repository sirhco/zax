//! The Zax server: an Io-agnostic accept loop that binds the router, app state,
//! and the comptime extractor dispatcher to real `std.Io.net` sockets.
//!
//! It names no concrete Io backend — `bind`/`acceptLoop` take a `std.Io`, so the
//! same code runs on `Io.Threaded` today and a future `Io.Evented` unchanged.
//! Each accepted connection is handled in an `Io.Group` task; under `Io.Threaded`
//! that means the thread pool, under an evented Io it would be single-thread
//! concurrency — identical framework code either way.
//!
//! Memory: one `ArenaAllocator` per connection, freed wholesale at end of
//! request. The read buffer is stack-local; parsed request slices point into it
//! (zero-copy) and stay valid for the request's lifetime.
//!
//! Shutdown: `requestShutdown` closes the listening socket — the documented way
//! to make a blocking `accept` return — so the loop exits, then `group.await`
//! drains in-flight connections before returning.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;

const build_options = @import("build_options");

// Reactor imports — used only by serveEvented (Linux only).
const worker_mod = @import("reactor/worker.zig");
const conn_mod = @import("reactor/conn.zig");

const request = @import("http/request.zig");
const Header = request.Header;
const response = @import("http/response.zig");
const Response = response.Response;
const chunked_mod = @import("http/chunked.zig");
const parser = @import("http/parser.zig");
const router = @import("router/router.zig");
const radix = @import("router/radix.zig");
const Param = radix.Param;
const extract = @import("extract/extract.zig");
const middleware = @import("middleware.zig");
const err_mod = @import("error.zig");
const observe_mod = @import("observe.zig");
const ws_mod = @import("ws.zig");

// ---------------------------------------------------------------------------
// Compile-time-gated latency tracer.
// When build_options.trace_latency is false this entire block is a no-op
// set of zero-size types; the optimizer (and comptime branches in handleConn)
// ensure zero code is emitted for the production path.
// ---------------------------------------------------------------------------

/// Per-segment stats: atomic running-max (ns) + count of requests that
/// exceeded a 5 ms threshold.  All fields are i64 so we can CAS without
/// the awkward i96 precision (truncation is fine for max-tracking).
const TraceSegment = struct {
    max_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    over_threshold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Which segment "dominated" a slow request (had the largest delta).
const TraceSeg = enum(u8) { head, body, dispatch, write };

/// Process-global lock-free tracer.  Only allocated/used when trace_latency
/// is true; at comptime-false, handleConn never references it so the struct
/// definition still compiles but is unreachable.
const Trace = struct {
    head: TraceSegment = .{},
    body: TraceSegment = .{},
    dispatch: TraceSegment = .{},
    write: TraceSegment = .{},
    /// Count of requests where each segment was the largest.
    dominant: [4]std.atomic.Value(u64) = .{
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    },

    const threshold_ns: i64 = 5_000_000; // 5 ms

    fn record(_: *Trace, seg: *TraceSegment, delta: i64) void {
        // CAS-max loop — lock-free, no allocation.
        var cur = seg.max_ns.load(.monotonic);
        while (delta > cur) {
            cur = seg.max_ns.cmpxchgWeak(cur, delta, .monotonic, .monotonic) orelse break;
        }
        if (delta > threshold_ns) {
            _ = seg.over_threshold.fetchAdd(1, .monotonic);
        }
    }

    fn recordRequest(self: *Trace, h: i64, b2: i64, d: i64, w: i64) void {
        self.record(&self.head, h);
        self.record(&self.body, b2);
        self.record(&self.dispatch, d);
        self.record(&self.write, w);
        // Tally dominant segment for this request.
        var max_val = h;
        var dom: TraceSeg = .head;
        if (b2 > max_val) { max_val = b2; dom = .body; }
        if (d > max_val) { max_val = d; dom = .dispatch; }
        if (w > max_val) { dom = .write; }
        _ = self.dominant[@intFromEnum(dom)].fetchAdd(1, .monotonic);
    }

    fn dump(self: *const Trace) void {
        const names = [_][]const u8{ "head ", "body ", "disp ", "write" };
        const segs = [_]*const TraceSegment{ &self.head, &self.body, &self.dispatch, &self.write };
        std.debug.print("[latency-trace] segment  max_ms  over5ms  dominant\n", .{});
        for (names, segs, 0..) |name, seg, i| {
            const max_ms = @as(f64, @floatFromInt(seg.max_ns.load(.monotonic))) / 1_000_000.0;
            const over = seg.over_threshold.load(.monotonic);
            const dom = self.dominant[i].load(.monotonic);
            std.debug.print("[latency-trace]   {s}  {d:.2}ms  {d}  {d}\n", .{ name, max_ms, over, dom });
        }
    }
};

/// The singleton tracer — only meaningful when trace_latency is true.
/// We use a global so no allocation is needed and handleConn can reach it
/// without threading it through every call site.
var global_trace: Trace = .{};

/// Maximum path parameters captured per request (compile-time, sizes the
/// stack capture buffer).
pub const max_params = 16;

pub const Options = struct {
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 8 * 1024,
    /// Allow persistent (keep-alive) connections.
    keep_alive: bool = true,
    /// Cap on requests served per connection before closing (bounds resource
    /// use on long-lived connections).
    max_keep_alive_requests: usize = 100,
    /// Reject a body whose Content-Length exceeds this (413). 0 = bounded only
    /// by the read buffer. Effective limit = min(max_body_size, read_buffer_size
    /// − head length).
    max_body_size: usize = 0,
    /// Deadline (ms) to receive a request's full head+body once its first byte
    /// arrives. Defeats slow-trickle. 0 = no timeout.
    read_timeout_ms: u32 = 30_000,
    /// Max wait (ms) for the next request on a keep-alive connection. 0 = none.
    idle_timeout_ms: u32 = 60_000,
    /// Trust `X-Forwarded-Proto/Host/For` headers. Enable ONLY when Zax sits
    /// behind a reverse proxy you control (it terminates TLS and sets these);
    /// otherwise clients could spoof them. See docs/deploy-https.md.
    trust_forwarded: bool = false,
    /// Enable per-request ids: validate an incoming `X-Request-Id` (safe charset,
    /// ≤128 chars) or generate one, echo it on the response as `x-request-id`,
    /// expose it via the `RequestId` extractor, and include it in access records.
    /// Off by default (zero overhead and identical behavior when disabled).
    request_id: bool = false,
    /// Disable Nagle's algorithm (set `TCP_NODELAY`) on each accepted
    /// connection so small responses go out immediately instead of waiting to
    /// coalesce. On by default (matches axum/hyper and Go net/http). Set false
    /// only to deliberately measure the Nagle/delayed-ACK effect.
    tcp_nodelay: bool = true,
    /// Cap concurrent in-flight connections (backpressure). When this many
    /// connections are being served, the accept loop stops accepting until one
    /// finishes — new connections wait in the kernel accept backlog. Bounds the
    /// live-thread count under `Io.Threaded` to tame CPU oversubscription and the
    /// latency tail. 0 = unbounded (default; unchanged behavior). A good starting
    /// value is roughly the core count.
    max_in_flight: usize = 0,
    /// Sleep (ms) between re-polls of a not-ready (`chunk(0)`) pull-stream
    /// producer on the threaded backend; 0 = legacy busy-loop.
    stream_repoll_ms: u32 = 5,
    /// Whole-stream idle cap (ms): close a threaded pull stream that has
    /// produced no data for this long; 0 = disabled. Hard-close (truncate,
    /// no chunked terminator).
    stream_idle_timeout_ms: u32 = 0,
    /// Maximum reassembled WebSocket message size (bytes). A message exceeding this
    /// is rejected with a 1009 close. A single frame is separately bounded by
    /// `read_buffer_size`.
    ws_max_message_size: usize = 1 << 20,
};

/// Options for the evented backend (`serveEvented`).
/// Supported on Linux (epoll) and macOS/BSD (kqueue).
/// Returns `error.EventedUnsupported` only on truly unsupported platforms (Windows, wasm).
pub const EventedOptions = struct {
    /// Number of worker threads. 0 → auto-detect via `std.Thread.getCpuCount()`.
    /// On Linux, `getCpuCount` calls `sched_getaffinity(0)` and counts set bits,
    /// so it already respects `taskset`/cgroup CPU masks (no oversubscription).
    workers: usize = 0,
    /// Per-worker connection pool size.
    max_connections: usize = 1024,
    /// Backoff (ms) before re-polling a not-ready streaming producer;
    /// 0 disables (legacy want_write busy behavior).
    stream_repoll_ms: u32 = 5,
    /// Whole-stream idle cap (ms) for pull streams: close a stream that has
    /// produced no data for this long. 0 disables (default — no cap).
    stream_idle_timeout_ms: u32 = 0,
};

/// `App(AppState)` — a server bound to one concrete, read-only app-state type.
pub fn App(comptime AppState: type) type {
    return struct {
        const Self = @This();
        /// Per-request context the extractors and middleware receive. Exposed so
        /// users can spell middleware signatures: `fn (*const App(S).Context, *App(S).Next)`.
        pub const Context = extract.Context(AppState);
        const Ctx = Context;
        const Chn = middleware.Chain(Ctx);
        /// Type-erased handler: every typed handler is wrapped into this single
        /// shape so the router can store them uniformly.
        const ErasedHandler = Chn.Handler;
        const R = router.Router(ErasedHandler);

        /// Middleware function type for this app. See `use`.
        pub const Middleware = Chn.Middleware;
        /// Cursor passed to middleware; call `.run()` to continue the chain.
        pub const Next = Chn.Next;

        /// Renders an error into a Response. Receives the raw error, a computed
        /// default classification, and the request context. Infallible.
        pub const ErrorHandler = *const fn (err: anyerror, info: err_mod.ErrorInfo, ctx: *const Ctx) Response;

        gpa: std.mem.Allocator,
        state: AppState,
        router: R,
        opts: Options,
        mws: std.ArrayListUnmanaged(Chn.Middleware) = .empty,
        observers: std.ArrayListUnmanaged(observe_mod.Observer) = .empty,
        fallback_handler: ?ErasedHandler = null,
        on_error: ?ErrorHandler = null,
        server: ?net.Server = null,
        shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        rid_counter: std.atomic.Value(u64) = .init(0),
        /// Pointers to live evented workers — set by `serveEvented` before threads
        /// start, cleared before the frame returns. `requestShutdown` wakes them.
        evented_workers: ?[]*worker_mod.Worker = null,

        pub fn init(gpa: std.mem.Allocator, state: AppState, opts: Options) std.mem.Allocator.Error!Self {
            return .{ .gpa = gpa, .state = state, .router = try R.init(gpa), .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            self.mws.deinit(self.gpa);
            self.observers.deinit(self.gpa);
            self.router.deinit();
        }

        /// Append a middleware to the global chain. Middleware run in
        /// registration order, wrapping the matched route handler (after
        /// routing, so 404/405 short-circuit before the chain).
        pub fn use(self: *Self, mw: Chn.Middleware) std.mem.Allocator.Error!void {
            try self.mws.append(self.gpa, mw);
        }

        /// Register an observer run after every request (matched, 404, 405, or
        /// handler error) with method/path/status/duration/bytes. Multiple
        /// observers may be registered; they run in registration order.
        pub fn observe(self: *Self, obs: observe_mod.Observer) std.mem.Allocator.Error!void {
            try self.observers.append(self.gpa, obs);
        }

        /// Set the handler run for requests that match no route (a custom 404 or
        /// an SPA index fallback). Runs through the global middleware chain;
        /// applies to not-found only (not method-not-allowed). The handler must
        /// not use `Path` (an unmatched route has no captured params).
        pub fn fallback(self: *Self, comptime handler: anytype) std.mem.Allocator.Error!void {
            const Wrap = struct {
                fn call(ctx: *const Ctx) anyerror!Response {
                    return extract.callHandler(handler, ctx.*);
                }
            };
            self.fallback_handler = &Wrap.call;
        }

        /// Set a custom error renderer (e.g. to emit JSON error bodies).
        pub fn onError(self: *Self, h: ErrorHandler) void {
            self.on_error = h;
        }

        /// Register `handler` for `method` at `pattern`. The handler's signature
        /// is validated and its extractors wired at comptime here.
        pub fn route(self: *Self, method: request.Method, pattern: []const u8, comptime handler: anytype) std.mem.Allocator.Error!void {
            const Wrap = struct {
                fn call(ctx: *const Ctx) anyerror!Response {
                    return extract.callHandler(handler, ctx.*);
                }
            };
            try self.router.register(method, pattern, &Wrap.call);
        }

        /// Like `route`, but `mws` (a comptime tuple of `Middleware`) run only
        /// for this route — after the global chain, before the handler, in tuple
        /// order. The tuple is materialized into static storage (no allocation).
        pub fn routeWith(
            self: *Self,
            method: request.Method,
            pattern: []const u8,
            comptime mws: anytype,
            comptime handler: anytype,
        ) std.mem.Allocator.Error!void {
            const Wrap = struct {
                const list: [mws.len]Chn.Middleware = mws;
                fn real(ctx: *const Ctx) anyerror!Response {
                    return extract.callHandler(handler, ctx.*);
                }
                fn call(ctx: *const Ctx) anyerror!Response {
                    return Chn.run(&list, &real, ctx);
                }
            };
            try self.router.register(method, pattern, &Wrap.call);
        }

        pub fn get(self: *Self, pattern: []const u8, comptime h: anytype) !void {
            return self.route(.GET, pattern, h);
        }
        pub fn post(self: *Self, pattern: []const u8, comptime h: anytype) !void {
            return self.route(.POST, pattern, h);
        }
        pub fn put(self: *Self, pattern: []const u8, comptime h: anytype) !void {
            return self.route(.PUT, pattern, h);
        }
        pub fn delete(self: *Self, pattern: []const u8, comptime h: anytype) !void {
            return self.route(.DELETE, pattern, h);
        }

        pub fn getWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.GET, pattern, mws, h);
        }
        pub fn postWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.POST, pattern, mws, h);
        }
        pub fn putWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.PUT, pattern, mws, h);
        }
        pub fn deleteWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.DELETE, pattern, mws, h);
        }

        /// A route group: a shared comptime `prefix` and shared `group_mws` (a
        /// comptime middleware tuple) applied to every route registered through
        /// it. Created by `App.group`; nestable via `Group.group`.
        pub fn Group(comptime prefix: []const u8, comptime group_mws: anytype) type {
            return struct {
                const G = @This();
                app: *Self,

                /// Mirror of `App.route`, with this group's prefix and middleware applied.
                pub fn route(self: G, method: request.Method, comptime pattern: []const u8, comptime handler: anytype) !void {
                    return self.app.routeWith(method, prefix ++ pattern, group_mws, handler);
                }
                /// Mirror of `App.routeWith`; this group's middleware run before `mws`.
                pub fn routeWith(self: G, method: request.Method, comptime pattern: []const u8, comptime mws: anytype, comptime handler: anytype) !void {
                    return self.app.routeWith(method, prefix ++ pattern, group_mws ++ mws, handler);
                }

                pub fn get(self: G, comptime p: []const u8, comptime h: anytype) !void {
                    return self.route(.GET, p, h);
                }
                pub fn post(self: G, comptime p: []const u8, comptime h: anytype) !void {
                    return self.route(.POST, p, h);
                }
                pub fn put(self: G, comptime p: []const u8, comptime h: anytype) !void {
                    return self.route(.PUT, p, h);
                }
                pub fn delete(self: G, comptime p: []const u8, comptime h: anytype) !void {
                    return self.route(.DELETE, p, h);
                }

                pub fn getWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void {
                    return self.routeWith(.GET, p, mws, h);
                }
                pub fn postWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void {
                    return self.routeWith(.POST, p, mws, h);
                }
                pub fn putWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void {
                    return self.routeWith(.PUT, p, mws, h);
                }
                pub fn deleteWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void {
                    return self.routeWith(.DELETE, p, mws, h);
                }

                /// Nest a sub-group: prefixes concatenate, middleware tuples
                /// concatenate (outer group middleware run before inner).
                pub fn group(self: G, comptime sub: []const u8, comptime more_mws: anytype) Group(prefix ++ sub, group_mws ++ more_mws) {
                    return .{ .app = self.app };
                }
            };
        }

        /// Open a route group with a shared comptime `prefix` and shared
        /// middleware `mws` (a comptime tuple). Routes registered through the
        /// returned `Group` are registered at `prefix ++ pattern` with `mws`
        /// prepended to their chain. Pass `.{}` for a prefix-only group.
        pub fn group(self: *Self, comptime prefix: []const u8, comptime mws: anytype) Group(prefix, mws) {
            return .{ .app = self };
        }

        /// Bind and start listening. Separated from `acceptLoop` so callers can
        /// guarantee the socket is listening before driving traffic (e.g. tests
        /// that spawn the loop and then connect).
        pub fn bind(self: *Self, io: Io, addr: net.IpAddress) net.IpAddress.ListenError!void {
            var a = addr;
            self.server = try a.listen(io, .{ .reuse_address = true });
        }

        /// Accept connections until shutdown, handling each in a Group task, then
        /// drain in-flight connections. Returns when fully drained.
        pub fn acceptLoop(self: *Self, io: Io) void {
            var conn_group: Io.Group = .init;
            var sem: Io.Semaphore = .{ .permits = self.opts.max_in_flight };
            const cap = self.opts.max_in_flight != 0;
            while (!self.shutting_down.load(.acquire)) {
                const srv = if (self.server) |*s| s else break;
                if (cap) sem.waitUncancelable(io); // backpressure: block at cap
                // Re-check after unblocking: shutdown may have fired while we waited.
                if (cap and self.shutting_down.load(.acquire)) {
                    sem.post(io);
                    break;
                }
                const stream = srv.accept(io) catch {
                    if (cap) sem.post(io); // release on accept error
                    break;
                };
                conn_group.async(io, handleConn, .{ self, io, stream, if (cap) &sem else null });
            }
            conn_group.await(io) catch {};
        }

        /// Convenience: bind then run the accept loop on the current task.
        pub fn serve(self: *Self, io: Io, addr: net.IpAddress) !void {
            try self.bind(io, addr);
            self.acceptLoop(io);
        }

        /// Start the epoll-based evented backend. Linux only.
        ///
        /// Spawns `opts.workers` (0 → affinity-mask CPU count) worker threads each owning a
        /// `SO_REUSEPORT` listen socket on `addr`. Blocks until all workers
        /// exit (triggered by `requestShutdown`).
        ///
        /// The `io` parameter is passed to each handler's context (it is stored
        /// in `Ctx.io`). Handlers that call blocking-IO extractors (e.g. `Files`)
        /// will stall their worker's entire event loop — use only non-blocking
        /// extractors (Path, Query, Json, State, …).
        pub fn serveEvented(self: *Self, io: Io, addr: net.IpAddress, opts: EventedOptions) error{
            EventedUnsupported,
            SystemResources,
            OutOfMemory,
            Unexpected,
        }!void {
            // Supported on Linux (epoll) and macOS/BSD (kqueue).
            // Unsupported on Windows and wasm — no epoll/kqueue there.
            const reactor_supported = comptime switch (builtin.os.tag) {
                .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
                .freebsd, .dragonfly, .netbsd, .openbsd => true,
                else => false,
            };
            if (comptime !reactor_supported) return error.EventedUnsupported;

            // getCpuCount() on Linux calls sched_getaffinity(0) — already respects
            // taskset / cgroup cpuset masks, so this is never oversubscribed.
            const n_workers = if (opts.workers != 0) opts.workers else std.Thread.getCpuCount() catch 1;

            const WorkerOpts = worker_mod.WorkerOpts;
            const Worker = worker_mod.Worker;
            const Dispatcher = conn_mod.Dispatcher;

            // Bundle: lives on this frame (outlives all workers).
            // Each worker thread gets its own bundle so they can each hold
            // a copy of `io` without contention.  All bundles point to the
            // same `*App`.
            const AppIoBundle = struct {
                app: *Self,
                io: Io,
            };

            const DispatchFn = struct {
                fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
                    const b: *AppIoBundle = @ptrCast(@alignCast(ctx));
                    // Compute request-id (zero overhead when disabled).
                    const rid: []const u8 = if (b.app.opts.request_id)
                        b.app.computeRid(req, arena.allocator())
                    else
                        "";
                    // Time the dispatch for observers; skip the clock read when no
                    // observers are registered (zero-overhead-when-none guard).
                    const t0: i96 = if (b.app.observers.items.len > 0)
                        conn_mod.monotonicNow()
                    else
                        0;
                    var resp = b.app.dispatch(b.io, req, arena, rid);
                    // Echo request-id on the response header (mirrors threaded backend).
                    if (b.app.opts.request_id) {
                        resp = resp.withHeader(arena.allocator(), "x-request-id", rid) catch resp;
                    }
                    if (b.app.observers.items.len > 0) {
                        const dur: u64 = @intCast(@max(@as(i96, 0), conn_mod.monotonicNow() - t0));
                        const rec = observe_mod.AccessRecord{
                            .method = req.method,
                            .path = req.path,
                            .status = resp.status.code(),
                            .duration_ns = dur,
                            .bytes = resp.body.len,
                            .request_id = rid,
                        };
                        for (b.app.observers.items) |obs| obs.func(obs.context, rec);
                    }
                    return resp;
                }
            };

            // Allocate worker storage on this frame.
            // We use a single heap allocation for the slice of Workers (they are
            // too large for the stack) — freed before we return.
            const workers_slice = try self.gpa.alloc(Worker, n_workers);
            defer self.gpa.free(workers_slice);

            const bundles = try self.gpa.alloc(AppIoBundle, n_workers);
            defer self.gpa.free(bundles);

            const worker_ptrs = try self.gpa.alloc(*Worker, n_workers);
            defer self.gpa.free(worker_ptrs);

            const threads = try self.gpa.alloc(std.Thread, n_workers);
            defer self.gpa.free(threads);

            const worker_opts = WorkerOpts{
                .max_connections = opts.max_connections,
                .read_buffer_size = self.opts.read_buffer_size,
                .write_buffer_size = self.opts.write_buffer_size,
                .keep_alive = self.opts.keep_alive,
                .max_keep_alive_requests = self.opts.max_keep_alive_requests,
                .max_body_size = self.opts.max_body_size,
                .read_timeout_ms = self.opts.read_timeout_ms,
                .idle_timeout_ms = self.opts.idle_timeout_ms,
                .tcp_nodelay = self.opts.tcp_nodelay,
                .stream_repoll_ms = opts.stream_repoll_ms,
                .stream_idle_timeout_ms = opts.stream_idle_timeout_ms,
                .ws_max_message_size = self.opts.ws_max_message_size,
            };

            // Init workers.  Track counts separately so the single cleanup path
            // below can handle both init and spawn failures without double-deinit.
            var inited: usize = 0;
            var spawned: usize = 0;
            var spawn_err: ?anyerror = null;

            for (0..n_workers) |i| {
                bundles[i] = AppIoBundle{ .app = self, .io = io };
                const disp = Dispatcher{
                    .ctx = @ptrCast(&bundles[i]),
                    .dispatchFn = DispatchFn.dispatch,
                };
                workers_slice[i] = Worker.init(
                    self.gpa,
                    disp,
                    worker_opts,
                    addr,
                    &self.shutting_down,
                ) catch |e| {
                    spawn_err = e;
                    break;
                };
                worker_ptrs[i] = &workers_slice[i];
                inited += 1;
            }

            if (spawn_err == null) {
                // Register worker pointers BEFORE spawning threads so
                // requestShutdown can safely wake them.
                self.evented_workers = worker_ptrs;

                // Spawn threads.
                for (0..n_workers) |i| {
                    threads[i] = std.Thread.spawn(.{}, Worker.run, .{&workers_slice[i]}) catch |e| {
                        spawn_err = e;
                        break;
                    };
                    spawned += 1;
                }
            }

            if (spawn_err) |e| {
                // Single cleanup path for both init-failure and spawn-failure.
                // Order: signal shutdown → wake+join live threads → deinit each
                // initialised worker exactly once → clear evented_workers.
                self.shutting_down.store(true, .release);
                for (0..spawned) |j| {
                    workers_slice[j].wake();
                    threads[j].join();
                }
                for (0..inited) |j| workers_slice[j].deinit();
                self.evented_workers = null;
                return switch (@as(anyerror, e)) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SystemResources,
                };
            }

            // Join all threads.
            for (0..n_workers) |i| threads[i].join();

            // Clear evented_workers before frame returns (pointers become dangling).
            self.evented_workers = null;

            // Deinit workers exactly once on the normal path.
            for (0..n_workers) |i| workers_slice[i].deinit();

            if (comptime build_options.trace_latency) global_trace.dump();
        }

        /// Request a graceful shutdown: stop accepting (by closing the listening
        /// socket, which unblocks `accept`) so `acceptLoop` exits and drains.
        /// Safe to call from another task. A SIGINT/SIGTERM handler would simply
        /// call this.
        pub fn requestShutdown(self: *Self, io: Io) void {
            self.shutting_down.store(true, .release);
            if (self.server) |*s| {
                // shutdown(SHUT_RDWR) before close so that any thread blocked
                // in accept() returns EINVAL / SocketNotListening immediately
                // on all platforms (on Linux, close() alone is not guaranteed
                // to unblock a concurrent accept() in another thread).
                io.vtable.netShutdown(io.userdata, s.socket.handle, .both) catch {};
                s.socket.close(io);
            }
            // Wake all evented workers so they break out of epoll_wait.
            if (self.evented_workers) |ws| {
                for (ws) |w| w.wake();
            }
            if (comptime build_options.trace_latency) global_trace.dump();
        }

        /// Serve a connection: a keep-alive loop of request/response cycles over
        /// one stream. Read/write buffers and the request arena persist for the
        /// whole connection; the arena is reset (capacity retained) each request.
        fn handleConn(self: *Self, io: Io, stream_in: net.Stream, sem: ?*Io.Semaphore) void {
            defer if (sem) |s| s.post(io);
            var stream = stream_in;
            defer stream.close(io);
            // disable Nagle (opt-out): small responses go out immediately
            if (self.opts.tcp_nodelay) setNoDelay(stream.socket.handle);

            const read_buf = self.gpa.alloc(u8, self.opts.read_buffer_size) catch return;
            defer self.gpa.free(read_buf);
            const write_buf = self.gpa.alloc(u8, self.opts.write_buffer_size) catch return;
            defer self.gpa.free(write_buf);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            var cr = ConnReader{ .socket = stream.socket, .io = io, .buf = read_buf };
            var sw = stream.writer(io, write_buf);
            const w = &sw.interface;

            const read_to = msTimeout(self.opts.read_timeout_ms);
            const idle_to = msTimeout(self.opts.idle_timeout_ms);

            var served: usize = 0;
            while (true) {
                _ = arena.reset(.retain_capacity);
                cr.compact(); // request boundary: move pipelined leftover to front (start=0)

                // Phase-timer stamps — comptime-elided when trace_latency is off.
                const t_loop: i96 = if (comptime build_options.trace_latency) nowNs(io) else 0;

                var hs: [request.max_headers]Header = undefined;
                var parsed = readHead(&cr, &hs, read_to, idle_to) catch |e| {
                    terminalResponse(io, w, e);
                    break;
                };

                const t_head: i96 = if (comptime build_options.trace_latency) nowNs(io) else 0;

                readBody(&cr, &parsed, self.opts.max_body_size, read_to) catch |e| {
                    terminalResponse(io, w, e);
                    break;
                };
                const consumed = parsed.head_len + parsed.body_consumed;

                const t_body: i96 = if (comptime build_options.trace_latency) nowNs(io) else 0;

                const persistent = self.opts.keep_alive and
                    parsed.request.isPersistent() and
                    (served + 1) < self.opts.max_keep_alive_requests;

                const rid: []const u8 = if (self.opts.request_id) self.computeRid(&parsed.request, arena.allocator()) else "";

                const t0: i96 = if (self.observers.items.len > 0) nowNs(io) else 0;
                var resp = self.dispatch(io, &parsed.request, &arena, rid);

                const t_disp: i96 = if (comptime build_options.trace_latency) nowNs(io) else 0;

                if (resp.upgrade) |up| {
                    // Write the 101 handshake by hand (the generic Response writer
                    // would emit content-length: 0 and connection: close).
                    w.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch break;
                    w.writeAll("Upgrade: websocket\r\n") catch break;
                    w.writeAll("Connection: Upgrade\r\n") catch break;
                    w.writeAll("Sec-WebSocket-Accept: ") catch break;
                    w.writeAll(&up.accept) catch break;
                    w.writeAll("\r\n\r\n") catch break;
                    w.flush() catch break;

                    // Threaded WsConn: send = blocking writeFrame+flush; close = flag.
                    const ThreadedSink = struct {
                        writer: *std.Io.Writer,
                        closed: bool = false,
                        const vt = ws_mod.WsConn.VTable{ .send = sendFn, .close = closeFn };
                        fn sendFn(ctx: *anyopaque, opcode: ws_mod.Opcode, payload: []const u8) ws_mod.SendError!void {
                            const s: *@This() = @ptrCast(@alignCast(ctx));
                            ws_mod.writeFrame(s.writer, opcode, payload) catch return error.WriteFailed;
                            s.writer.flush() catch return error.WriteFailed;
                        }
                        fn closeFn(ctx: *anyopaque) void {
                            const s: *@This() = @ptrCast(@alignCast(ctx));
                            s.closed = true;
                        }
                    };
                    var sink = ThreadedSink{ .writer = w };
                    var conn = ws_mod.WsConn{ .ctx = &sink, .vtable = &ThreadedSink.vt,
                        .state_ptr = up.state_ptr, .arena = arena.allocator() };

                    // Seed the frame buffer with any pipelined post-handshake bytes.
                    cr.consume(consumed);
                    cr.compact();
                    var start: usize = 0;
                    var end: usize = cr.buffered().len;

                    // Record the upgrade request (status 101) now: the request completes
                    // at the handshake, so duration_ns covers handshake-to-takeover only,
                    // not the long-lived WebSocket session that follows.
                    if (self.observers.items.len > 0) {
                        const dur: u64 = @intCast(@max(@as(i96, 0), nowNs(io) - t0));
                        const rec = observe_mod.AccessRecord{
                            .method = parsed.request.method,
                            .path = parsed.request.path,
                            .status = resp.status.code(),
                            .duration_ns = dur,
                            .bytes = 0,
                            .request_id = rid,
                        };
                        for (self.observers.items) |obs| obs.func(obs.context, rec);
                    }

                    var reasm = ws_mod.Reassembler{ .arena = arena.allocator(), .max_message_size = self.opts.ws_max_message_size };
                    if (up.handler.on_open) |f| f(&conn);

                    // Framework-driven read loop: read -> pump -> on_message.
                    while (!sink.closed) {
                        const pr = ws_mod.pump(read_buf, &start, &end, &conn, up.handler, &reasm);
                        if (pr == .closed) break;
                        if (sink.closed) break;
                        // ws.pump compacts leftover to the front (start := 0), so a full
                        // buffer here means a single incomplete frame exceeds read_buf -> stop.
                        if (end == read_buf.len) break; // frame larger than buffer -> stop
                        // Blocking read more bytes into read_buf[end..].
                        const msg = stream.socket.receiveTimeout(io, read_buf[end..], idle_to) catch break;
                        if (msg.data.len == 0) break; // EOF
                        end += msg.data.len;
                    }
                    if (up.handler.on_close) |f| f(&conn);
                    break; // -> defer stream.close
                }

                if (self.opts.request_id) {
                    resp = resp.withHeader(arena.allocator(), "x-request-id", rid) catch resp;
                }
                const streamed = resp.streamer != null or resp.pull_streamer != null;
                const chunked = streamed and persistent;
                resp.keep_alive = persistent and !streamed; // unchanged for buffered; streamed head driven by writeHead(chunked)
                if (!writeResponse(w, resp, chunked, io, self.opts.stream_repoll_ms, self.opts.stream_idle_timeout_ms)) break;

                if (comptime build_options.trace_latency) {
                    const t_write = nowNs(io);
                    const seg_head: i64 = @intCast(@max(@as(i96, 0), t_head - t_loop));
                    const seg_body: i64 = @intCast(@max(@as(i96, 0), t_body - t_head));
                    const seg_disp: i64 = @intCast(@max(@as(i96, 0), t_disp - t_body));
                    const seg_write: i64 = @intCast(@max(@as(i96, 0), t_write - t_disp));
                    global_trace.recordRequest(seg_head, seg_body, seg_disp, seg_write);
                }

                if (self.observers.items.len > 0) {
                    const dur: u64 = @intCast(@max(@as(i96, 0), nowNs(io) - t0));
                    const rec = observe_mod.AccessRecord{
                        .method = parsed.request.method,
                        .path = parsed.request.path,
                        .status = resp.status.code(),
                        .duration_ns = dur,
                        .bytes = resp.body.len,
                        .request_id = rid,
                    };
                    for (self.observers.items) |obs| obs.func(obs.context, rec);
                }
                if (streamed and !chunked) break; // close only after a connection-close stream

                cr.consume(consumed);
                served += 1;
                if (!persistent) break;
            }
        }

        /// Route one already-read request and run its handler. Every failure
        /// path maps to an HTTP status rather than propagating.
        fn makeCtx(self: *Self, io: Io, req: *const request.Request, params: []const Param, arena: *std.heap.ArenaAllocator, request_id: []const u8) Ctx {
            return .{
                .req = req,
                .params = params,
                .state = self.state,
                .arena = arena.allocator(),
                .io = io,
                .trust_forwarded = self.opts.trust_forwarded,
                .request_id = request_id,
            };
        }

        /// Resolve the request id: reuse a valid incoming `X-Request-Id`, else
        /// generate a monotonic 16-hex-digit id into `arena`. Falls back to "" if
        /// allocation fails (the header echo simply omits a value).
        pub fn computeRid(self: *Self, req: *const request.Request, arena: std.mem.Allocator) []const u8 {
            if (req.header("x-request-id")) |h| {
                if (validRid(h)) return h;
            }
            const n = self.rid_counter.fetchAdd(1, .monotonic);
            return std.fmt.allocPrint(arena, "{x:0>16}", .{n}) catch "";
        }

        /// Classify an error and render it, using the app's on_error hook if set.
        fn renderError(self: *Self, e: anyerror, ctx: *const Ctx) Response {
            const info = err_mod.classify(e);
            if (self.on_error) |h| return h(e, info, ctx);
            return .{ .status = info.status, .body = info.reason };
        }

        fn dispatch(self: *Self, io: Io, req: *const request.Request, arena: *std.heap.ArenaAllocator, request_id: []const u8) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch {
                const ctx = self.makeCtx(io, req, &.{}, arena, request_id);
                return self.renderError(err_mod.Error.BadRequest, &ctx);
            };

            switch (outcome) {
                .not_found => {
                    const ctx = self.makeCtx(io, req, &.{}, arena, request_id);
                    if (self.fallback_handler) |fb|
                        return Chn.run(self.mws.items, fb, &ctx) catch |e| self.renderError(e, &ctx);
                    return self.renderError(err_mod.Error.NotFound, &ctx);
                },
                .method_not_allowed => |allowed| {
                    const ctx = self.makeCtx(io, req, &.{}, arena, request_id);
                    if (req.method == .OPTIONS) {
                        // Auto-preflight: run the global chain so a CORS middleware can
                        // answer the preflight (it short-circuits to 204 before the
                        // terminal). If nothing handles it, fall through to the normal 405.
                        const term = struct {
                            fn call(_: *const Ctx) anyerror!Response {
                                return Response.fromStatus(.method_not_allowed);
                            }
                        }.call;
                        const resp = Chn.run(self.mws.items, &term, &ctx) catch |e| return self.renderError(e, &ctx);
                        if (resp.status == .method_not_allowed) {
                            var r = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
                            r = r.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch r;
                            return r;
                        }
                        return resp;
                    }
                    var resp = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
                    resp = resp.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch resp;
                    return resp;
                },
                .found => |f| {
                    const ctx = self.makeCtx(io, req, f.params, arena, request_id);
                    return Chn.run(self.mws.items, f.handler, &ctx) catch |e| self.renderError(e, &ctx);
                },
            }
        }
    };
}

/// Write and flush a response; returns false on a write error (caller closes).
fn writeResponse(w: *Io.Writer, resp: Response, chunked: bool, io: Io, repoll_ms: u32, idle_ms: u32) bool {
    // Pull-streamed response: loop next(buf) writing chunks to the blocking writer.
    if (resp.pull_streamer) |ps| {
        resp.writeHead(w, chunked) catch return false;
        var chunk_buf: [4096]u8 = undefined;
        var last_produce: i96 = nowNs(io); // idle window starts at stream start
        while (true) {
            switch (ps.next(&chunk_buf)) {
                .chunk => |n| {
                    if (n == 0) {
                        // Whole-stream idle cap: no data for too long → hard close (truncate).
                        if (idle_ms != 0 and nowNs(io) - last_produce > @as(i96, idle_ms) * 1_000_000) {
                            w.flush() catch {}; // push head bytes to client before truncating
                            return false; // caller closes; NO terminator
                        }
                        if (repoll_ms != 0)
                            Io.sleep(io, Io.Duration.fromMilliseconds(repoll_ms), .awake) catch {};
                        continue;
                    }
                    last_produce = nowNs(io); // real data resets the idle window
                    if (chunked) {
                        chunked_mod.writeChunk(w, chunk_buf[0..n]) catch return false;
                    } else {
                        w.writeAll(chunk_buf[0..n]) catch return false;
                    }
                },
                .done => break,
                .err => return false,
            }
        }
        if (chunked) chunked_mod.writeTerminator(w) catch return false;
        w.flush() catch return false;
        return true;
    }
    // Push-streamed response: func writes directly to the connection writer.
    if (resp.streamer) |s| {
        resp.writeHead(w, chunked) catch return false;
        if (chunked) {
            var cw_buf: [4096]u8 = undefined;
            var cw = chunked_mod.ChunkedWriter.init(w, &cw_buf);
            s.func(s.context, cw.writer()) catch return false;
            cw.finish() catch return false;
        } else {
            s.func(s.context, w) catch return false;
        }
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}

/// Whether `s` is a safe request-id to echo verbatim: non-empty, ≤128 chars, and
/// limited to `[A-Za-z0-9._-]` (no whitespace, CR/LF, or header-injection bytes).
fn validRid(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Build a comma-separated `Allow` header value from a method set, into `arena`.
fn allowHeader(arena: std.mem.Allocator, allowed: router.MethodSet) []const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var it = allowed.iterator();
    var first = true;
    while (it.next()) |m| {
        if (!first) list.appendSlice(arena, ", ") catch return list.items;
        list.appendSlice(arena, @tagName(m)) catch return list.items;
        first = false;
    }
    return list.items;
}

/// Build an Io.Timeout from milliseconds; 0 means no timeout (blocking).
fn msTimeout(ms_val: u32) Io.Timeout {
    if (ms_val == 0) return .none;
    return .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(@intCast(ms_val)), .clock = .awake } };
}

/// Disable Nagle's algorithm on a connection socket so a small response is sent
/// immediately rather than held waiting for an ACK the peer may delay (~40 ms).
/// Standard for HTTP servers. Best-effort: a socket-option failure must never
/// break the connection.
fn setNoDelay(handle: net.Socket.Handle) void {
    std.posix.setsockopt(
        handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch {};
}

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).toNanoseconds();
}

/// A manual, timeout-capable connection reader. Owns a fixed buffer and a
/// [start, end) window of received-but-unconsumed bytes. Compaction runs only at
/// request boundaries, so slices the parser hands out never move mid-request.
const ConnReader = struct {
    socket: net.Socket,
    io: Io,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    const FillError = error{ Timeout, BufferFull, Closed };

    fn buffered(self: *const ConnReader) []const u8 {
        return self.buf[self.start..self.end];
    }

    fn consume(self: *ConnReader, n: usize) void {
        self.start += n;
    }

    fn compact(self: *ConnReader) void {
        if (self.start == 0) return;
        const len = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..len], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = len;
    }

    /// Receive more bytes (up to the buffer's free tail) with `timeout`. Never
    /// compacts (callers keep start==0 during a request), so returns BufferFull
    /// when the buffer is full rather than moving in-use slices.
    fn fill(self: *ConnReader, timeout: Io.Timeout) FillError!void {
        if (self.end == self.buf.len) return error.BufferFull;
        const msg = self.socket.receiveTimeout(self.io, self.buf[self.end..], timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            // Every other receive failure ends this connection: peer reset/close,
            // cancellation during graceful shutdown (error.Canceled), and resource
            // exhaustion all mean "stop reading and close" — handleConn closes the
            // socket on error.Closed regardless, so distinct handling would be unused.
            else => return error.Closed,
        };
        if (msg.data.len == 0) return error.Closed;
        self.end += msg.data.len;
    }
};

const RequestError = error{
    HeaderFieldsTooLarge, // -> 431
    BodyTooLarge, // -> 413
    Timeout, // -> 408
    Malformed, // -> 400
    MalformedBody, // -> 400
    Closed, // -> close, no response
};

/// Fill until a full head is parsed. The first receive (no bytes yet for this
/// request) uses the idle deadline; subsequent receives use the read deadline.
fn readHead(cr: *ConnReader, hs: *[request.max_headers]Header, read_to: Io.Timeout, idle_to: Io.Timeout) RequestError!parser.Parsed {
    while (true) {
        if (parser.parseHead(cr.buffered(), hs)) |p| {
            return p;
        } else |err| switch (err) {
            error.Incomplete => {},
            error.TooManyHeaders => return error.HeaderFieldsTooLarge,
            else => return error.Malformed,
        }
        const waiting_for_first_byte = cr.buffered().len == 0;
        cr.fill(if (waiting_for_first_byte) idle_to else read_to) catch |e| switch (e) {
            error.Timeout => return if (waiting_for_first_byte) error.Closed else error.Timeout,
            error.BufferFull => return error.HeaderFieldsTooLarge,
            error.Closed => return error.Closed,
        };
    }
}

/// Read and attach the request body. Branches on chunked vs Content-Length.
/// Sets `parsed.body_consumed` on both paths so the stream can advance past
/// the encoded bytes (head_len + body_consumed).
fn readBody(cr: *ConnReader, parsed: *parser.Parsed, max_body: usize, read_to: Io.Timeout) RequestError!void {
    if (parsed.request.hasFramingConflict()) return error.Malformed;
    if (parsed.request.isChunked()) {
        const max = max_body; // bounds decoded length (0 = unbounded)
        while (true) {
            const enc = cr.buffered()[parsed.head_len..];
            switch (chunked_mod.decodeInPlace(@constCast(enc), max)) {
                .done => |d| {
                    parsed.request.body = cr.buffered()[parsed.head_len .. parsed.head_len + d.body_len];
                    parsed.body_consumed = d.consumed;
                    return;
                },
                .incomplete => cr.fill(read_to) catch |e| switch (e) {
                    error.Timeout => return error.Timeout,
                    error.BufferFull => return error.BodyTooLarge,
                    error.Closed => return error.Closed,
                },
                .malformed => return error.MalformedBody,
                .too_large => return error.BodyTooLarge,
            }
        }
    }
    const clen = parsed.request.contentLength() orelse return;
    const buf_bound = cr.buf.len - parsed.head_len;
    const limit = if (max_body == 0) buf_bound else @min(max_body, buf_bound);
    if (clen > limit) return error.BodyTooLarge;
    while (cr.buffered().len < parsed.head_len + clen) {
        cr.fill(read_to) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.BufferFull => return error.BodyTooLarge,
            error.Closed => return error.Closed,
        };
    }
    parsed.request.body = cr.buffered()[parsed.head_len .. parsed.head_len + clen];
    parsed.body_consumed = clen;
}

/// Send the terminal response for a RequestError (or nothing for Closed).
fn terminalResponse(io: Io, w: *Io.Writer, e: RequestError) void {
    switch (e) {
        error.HeaderFieldsTooLarge => _ = writeResponse(w, Response.fromStatus(.request_header_fields_too_large), false, io, 0, 0),
        error.BodyTooLarge => _ = writeResponse(w, Response.fromStatus(.payload_too_large), false, io, 0, 0),
        error.Timeout => _ = writeResponse(w, Response.fromStatus(.request_timeout), false, io, 0, 0),
        error.Malformed => _ = writeResponse(w, Response.fromStatus(.bad_request), false, io, 0, 0),
        error.MalformedBody => _ = writeResponse(w, Response.fromStatus(.bad_request), false, io, 0, 0),
        error.Closed => {},
    }
}

// ----------------------------------------------------------------------------
// Tests  (real Io.Threaded, loopback sockets)
// ----------------------------------------------------------------------------
const testing = std.testing;
const Path = @import("extract/path.zig").Path;
const State = @import("extract/state.zig").State;
const Forwarded = @import("extract/forwarded.zig").Forwarded;
const Form = @import("extract/form.zig").Form;
const Cookies = @import("extract/cookie.zig").Cookies;
const Alloc = @import("extract/alloc.zig").Alloc;
const Bytes = @import("extract/bytes.zig").Bytes;
const Headers = @import("extract/headers.zig").Headers;
const cors_mod = @import("cors.zig");
const compress_mod = @import("compress.zig");

const Db = struct { msg: []const u8 };
const TestApp = App(*const Db);

fn pingHandler(s: State(*const Db)) Response {
    return Response.text(s.value.msg);
}
fn echoId(p: Path(struct { id: u64 })) Response {
    // Body borrows: format into a static-ish buffer is unsafe; return fixed text
    // proving the param parsed. (id is validated by reaching here.)
    return if (p.value.id == 42) Response.text("forty-two") else Response.fromStatus(.not_found);
}
fn echoBody(b: Bytes) Response {
    return Response.text(b.value);
}

fn parseClen(head: []const u8) usize {
    const key = "content-length: ";
    const start = std.mem.indexOf(u8, head, key) orelse return 0;
    const i = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, head, i, '\r') orelse return 0;
    return std.fmt.parseInt(usize, head[i..end], 10) catch 0;
}

/// Read exactly one HTTP response (head + Content-Length body) from `r`, copy it
/// into `out`, and consume it from the reader buffer. Works on both keep-alive
/// and close connections (does not rely on EOF to frame the response).
fn readResp(r: *Io.Reader, out: []u8) []const u8 {
    while (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n") == null) {
        r.fillMore() catch break;
    }
    const he = (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n") orelse return out[0..0]) + 4;
    const clen = parseClen(r.buffered()[0..he]);
    while (r.buffered().len < he + clen) {
        r.fillMore() catch break;
    }
    const total = @min(he + clen, r.buffered().len);
    @memcpy(out[0..total], r.buffered()[0..total]);
    r.toss(total);
    return out[0..total];
}

fn doRequest(io: Io, port: u16, raw: []const u8, resp_buf: []u8) []const u8 {
    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [64 * 1024]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll(raw) catch unreachable;
    cw.interface.flush() catch unreachable;
    return readResp(&cr.interface, resp_buf);
}

test "end-to-end: routes, extractors, and graceful drain" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);
    try app.get("/users/:id", echoId);

    const port: u16 = 18090;
    try app.bind(io, .{ .ip4 = .loopback(port) });
    var loop_fut = io.async(TestApp.acceptLoop, .{ &app, io });

    // State extractor round-trip.
    var rb1: [2048]u8 = undefined;
    const r1 = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r1, "pong"));

    // Path extractor round-trip.
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.endsWith(u8, r2, "forty-two"));

    // 404 for unknown route.
    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "404 Not Found") != null);

    // 405 for known path, wrong method.
    var rb4: [2048]u8 = undefined;
    const r4 = doRequest(io, port, "DELETE /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb4);
    try testing.expect(std.mem.indexOf(u8, r4, "405 Method Not Allowed") != null);

    // Graceful shutdown: loop exits and drains.
    app.requestShutdown(io);
    loop_fut.await(io);
}

fn startTestApp(io: Io, app: *TestApp, port: u16) Io.Future(void) {
    app.bind(io, .{ .ip4 = .loopback(port) }) catch unreachable;
    return io.async(TestApp.acceptLoop, .{ app, io });
}

test "keep-alive: multiple requests reuse one connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18091;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // Two sequential requests on the SAME connection.
    inline for (0..2) |_| {
        cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
        cw.interface.flush() catch unreachable;
        var out: [1024]u8 = undefined;
        const resp = readResp(&cr.interface, &out);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "connection: keep-alive") != null);
        try testing.expect(std.mem.endsWith(u8, resp, "pong"));
    }

    // Pipelined: two requests written back-to-back, two framed responses read.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\nGET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var pout1: [1024]u8 = undefined;
    var pout2: [1024]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, readResp(&cr.interface, &pout1), "pong"));
    try testing.expect(std.mem.endsWith(u8, readResp(&cr.interface, &pout2), "pong"));

    cs.close(io);
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "keep-alive: Connection: close ends the connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18092;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out: [1024]u8 = undefined;
    const resp = readResp(&cr.interface, &out);
    try testing.expect(std.mem.indexOf(u8, resp, "connection: close") != null);
    // Server closed: the next fill hits EOF (no more bytes).
    try testing.expectError(error.EndOfStream, cr.interface.fillMore());

    cs.close(io);
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "keep-alive: chunked request body is decoded and connection reused" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/ping", pingHandler);

    const port: u16 = 18093;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // Chunked POST: "hello" + " world" = "hello world".
    cw.interface.writeAll("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out1: [1024]u8 = undefined;
    const resp1 = readResp(&cr.interface, &out1);
    try testing.expect(std.mem.indexOf(u8, resp1, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, resp1, "hello world"));
    try testing.expect(std.mem.indexOf(u8, resp1, "connection: keep-alive") != null);

    // Second request on the SAME connection proves keep-alive survived.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out2: [1024]u8 = undefined;
    const resp2 = readResp(&cr.interface, &out2);
    try testing.expect(std.mem.indexOf(u8, resp2, "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "keep-alive: malformed chunked body is rejected with 400" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/echo", echoBody);

    const port: u16 = 18096;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // "zz" is not a valid hex chunk-size → malformed.
    const resp = doRequest(io, port, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nbad\r\n0\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, resp, "400") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "security: CL+TE request smuggling attempt rejected with 400" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/ping", pingHandler);

    const port: u16 = 18097;
    var loop_fut = startTestApp(io, &app, port);

    // CL + TE → 400 (framing conflict)
    var rb1: [2048]u8 = undefined;
    const resp1 = doRequest(io, port,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello",
        &rb1);
    try testing.expect(std.mem.startsWith(u8, resp1, "HTTP/1.1 400"));

    // Duplicate Content-Length → 400
    var rb2: [2048]u8 = undefined;
    const resp2 = doRequest(io, port,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\ncontent-length: 5\r\n\r\nhello",
        &rb2);
    try testing.expect(std.mem.startsWith(u8, resp2, "HTTP/1.1 400"));

    // Normal CL POST → 200 (no false positive)
    var rb3: [2048]u8 = undefined;
    const resp3 = doRequest(io, port,
        "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello",
        &rb3);
    try testing.expect(std.mem.indexOf(u8, resp3, "200") != null);

    // Normal chunked POST → 200 (no false positive)
    var rb4: [2048]u8 = undefined;
    const resp4 = doRequest(io, port,
        "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        &rb4);
    try testing.expect(std.mem.indexOf(u8, resp4, "200") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "security: duplicate Transfer-Encoding rejected with 400" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/ping", pingHandler);

    const port: u16 = 18221;
    var loop_fut = startTestApp(io, &app, port);

    // Two Transfer-Encoding headers → 400 (multi-TE smuggling vector)
    var rb: [2048]u8 = undefined;
    const resp = doRequest(io, port,
        "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n",
        &rb);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 400"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn requireAuth(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    if (ctx.req.header("authorization") == null) return Response.fromStatus(.unauthorized);
    return next.run();
}
fn requestId(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-request-id", "abc123");
}

fn wrapG(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "G({s})", .{r.body}));
}
fn wrapR(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "R({s})", .{r.body}));
}
fn wrapR2(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "R2({s})", .{r.body}));
}
fn bodyH() Response {
    return Response.text("H");
}
fn wrapGrp(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "Grp({s})", .{r.body}));
}
fn wrapV1(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "V1({s})", .{r.body}));
}

test "per-route middleware: scoped to its route + short-circuits" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/open", pingHandler);
    try app.getWith("/admin", .{&requireAuth}, pingHandler);

    const port: u16 = 18173;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /open HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);

    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "401 Unauthorized") != null);

    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: t\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "per-route middleware: order is global -> route -> handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    try app.getWith("/x", .{ &wrapR, &wrapR2 }, bodyH);

    const port: u16 = 18174;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.endsWith(u8, r, "G(R(R2(H)))"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "per-route middleware: postWith/putWith/deleteWith register the intended method" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.postWith("/p", .{}, pingHandler);
    try app.putWith("/u", .{}, pingHandler);
    try app.deleteWith("/d", .{}, pingHandler);

    const port: u16 = 18175;
    var loop_fut = startTestApp(io, &app, port);

    // POST /p -> 200 (correct method)
    var b1: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "POST /p HTTP/1.1\r\nHost: x\r\n\r\n", &b1), "200 OK") != null);
    // GET /p -> 405 (wrong method, proving it was registered as POST not GET)
    var b2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /p HTTP/1.1\r\nHost: x\r\n\r\n", &b2), "405 Method Not Allowed") != null);
    // PUT /u -> 200
    var b3: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "PUT /u HTTP/1.1\r\nHost: x\r\n\r\n", &b3), "200 OK") != null);
    // GET /u -> 405 (wrong method)
    var b4: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /u HTTP/1.1\r\nHost: x\r\n\r\n", &b4), "405 Method Not Allowed") != null);
    // DELETE /d -> 200
    var b5: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "DELETE /d HTTP/1.1\r\nHost: x\r\n\r\n", &b5), "200 OK") != null);
    // GET /d -> 405 (wrong method)
    var b6: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /d HTTP/1.1\r\nHost: x\r\n\r\n", &b6), "405 Method Not Allowed") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "per-route middleware: empty tuple behaves like a plain route" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.getWith("/e", .{}, pingHandler);

    const port: u16 = 18176;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /e HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn schemeHandler(f: Forwarded) Response {
    return Response.text(f.scheme);
}

const Json = @import("extract/json.zig").Json;
fn jsonHandler(body: Json(struct { name: []const u8 })) Response {
    return Response.text(body.value.name);
}

test "hot path: static-handler dispatch + serialize make zero heap allocations" {
    // The per-request arena is backed by a FailingAllocator that merely counts.
    // A handler that uses no allocating extractor must never touch the backing.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{}); // router uses testing.allocator
    defer app.deinit();
    try app.get("/ping", pingHandler);

    var hs: [request.max_headers]Header = undefined;
    const parsed = parser.parseHead("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &hs) catch unreachable;

    const resp = app.dispatch(undefined, &parsed.request, &arena, "");
    try testing.expectEqualStrings("pong", resp.body);

    var ob: [256]u8 = undefined;
    var w = Io.Writer.fixed(&ob);
    resp.write(&w) catch unreachable;

    // Parse + route + extract + handler + serialize: nothing hit the backing.
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "contrast: Json handler does allocate (discriminates the alloc check)" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/u", jsonHandler);

    var hs: [request.max_headers]Header = undefined;
    const raw = "POST /u HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"name\":\"grace\"}";
    var parsed = parser.parseHead(raw, &hs) catch unreachable;
    parsed.request.body = raw[parsed.head_len .. parsed.head_len + parsed.request.contentLength().?];

    const resp = app.dispatch(undefined, &parsed.request, &arena, "");
    try testing.expectEqualStrings("grace", resp.body);
    try testing.expect(failing.allocations > 0); // JSON parse used the arena
}

test "forwarded: trusted reads X-Forwarded-Proto, untrusted ignores it" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };

    // trust_forwarded = true: handler sees the proxied scheme.
    {
        var app = try TestApp.init(testing.allocator, &db, .{ .trust_forwarded = true });
        defer app.deinit();
        try app.get("/scheme", schemeHandler);
        const port: u16 = 18095;
        var loop_fut = startTestApp(io, &app, port);
        var rb: [1024]u8 = undefined;
        const r = doRequest(io, port, "GET /scheme HTTP/1.1\r\nHost: x\r\nX-Forwarded-Proto: https\r\n\r\n", &rb);
        try testing.expect(std.mem.endsWith(u8, r, "https"));
        app.requestShutdown(io);
        loop_fut.await(io);
    }
    // trust_forwarded = false (default): the header is ignored, scheme = http.
    {
        var app = try TestApp.init(testing.allocator, &db, .{});
        defer app.deinit();
        try app.get("/scheme", schemeHandler);
        const port: u16 = 18096;
        var loop_fut = startTestApp(io, &app, port);
        var rb: [1024]u8 = undefined;
        const r = doRequest(io, port, "GET /scheme HTTP/1.1\r\nHost: x\r\nX-Forwarded-Proto: https\r\n\r\n", &rb);
        try testing.expect(std.mem.endsWith(u8, r, "http"));
        app.requestShutdown(io);
        loop_fut.await(io);
    }
}

fn failNotFound() !Response {
    return err_mod.Error.NotFound;
}
fn failConflict() !Response {
    return err_mod.Error.Conflict;
}
fn failUnknown() !Response {
    return error.SomeAppSpecificThing;
}

fn jsonErrorRenderer(_: anyerror, info: err_mod.ErrorInfo, ctx: *const TestApp.Context) Response {
    const body = std.fmt.allocPrint(ctx.arena, "{{\"error\":\"{s}\"}}", .{info.reason}) catch
        return Response.fromStatus(info.status);
    var r = Response.jsonRaw(body);
    r.status = info.status;
    return r;
}

test "errors: extractor failures map to 4xx, handler errors to mapped status" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/users/:id", echoId);
    try app.post("/u", jsonHandler);
    try app.get("/nf", failNotFound);
    try app.get("/conflict", failConflict);
    try app.get("/boom", failUnknown);

    const port: u16 = 18100;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /users/abc HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "400 Bad Request") != null);
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "POST /u HTTP/1.1\r\nContent-Length: 9\r\n\r\n{not json", &rb), "422 Unprocessable Entity") != null);
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /nf HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /conflict HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "409 Conflict") != null);
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "500 Internal Server Error") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "errors: on_error hook renders custom JSON bodies" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    app.onError(&jsonErrorRenderer);
    try app.get("/nf", failNotFound);

    const port: u16 = 18101;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /nf HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, r, "content-type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, r, "{\"error\":\"not found\"}"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "errors: 404/405 go through the renderer and 405 carries Allow" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    app.onError(&jsonErrorRenderer);
    try app.get("/ping", pingHandler);
    try app.post("/ping", pingHandler);

    const port: u16 = 18102;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r404 = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r404, "404 Not Found") != null);
    try testing.expect(std.mem.endsWith(u8, r404, "{\"error\":\"not found\"}"));

    var rb2: [2048]u8 = undefined;
    const r405 = doRequest(io, port, "DELETE /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r405, "405 Method Not Allowed") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "allow: ") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "GET") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "POST") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "middleware: auth short-circuit and post-process header injection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&requireAuth);
    try app.use(&requestId);
    try app.get("/ping", pingHandler);

    const port: u16 = 18094;
    var loop_fut = startTestApp(io, &app, port);

    // No Authorization -> auth middleware short-circuits with 401; requestId
    // never runs, so no x-request-id header.
    var rb1: [2048]u8 = undefined;
    const r1 = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, r1, "401 Unauthorized") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "x-request-id") == null);

    // With Authorization -> chain runs through; handler responds and requestId
    // post-processes the response, adding the header.
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "x-request-id: abc123") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "pong"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "ConnReader buffer mechanics: buffered/consume/compact" {
    var backing: [16]u8 = "ABCDEFGH________".*;
    var cr = ConnReader{ .socket = undefined, .io = undefined, .buf = &backing, .start = 0, .end = 8 };
    try testing.expectEqualStrings("ABCDEFGH", cr.buffered());
    cr.consume(3); // drop "ABC"
    try testing.expectEqualStrings("DEFGH", cr.buffered());
    cr.compact(); // move "DEFGH" to front
    try testing.expectEqual(@as(usize, 0), cr.start);
    try testing.expectEqual(@as(usize, 5), cr.end);
    try testing.expectEqualStrings("DEFGH", cr.buffered());
    try testing.expectEqualStrings("DEFGH", backing[0..5]);
}

test "msTimeout: 0 disables, n builds a duration" {
    try testing.expect(msTimeout(0) == .none);
    const t = msTimeout(100);
    try testing.expect(t == .duration);
}

test "limits: oversized body returns 413" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .max_body_size = 10 });
    defer app.deinit();
    try app.post("/u", pingHandler);

    const port: u16 = 18110;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "POST /u HTTP/1.1\r\nContent-Length: 20\r\n\r\n01234567890123456789", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "413 Payload Too Large") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "limits: oversized header block returns 431" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .read_buffer_size = 64 });
    defer app.deinit();
    try app.get("/", pingHandler);

    const port: u16 = 18111;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const long = "GET / HTTP/1.1\r\nX-Long: " ++ ("a" ** 120) ++ "\r\n\r\n";
    const r = doRequest(io, port, long, &rb);
    try testing.expect(std.mem.indexOf(u8, r, "431 Request Header Fields Too Large") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "timeout: slow header (slowloris) returns 408 then closes" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{ .read_timeout_ms = 100 });
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18112;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);

    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll("GET /ping HTTP/1.1\r\n") catch unreachable; // partial, no terminator
    cw.interface.flush() catch unreachable;

    Io.sleep(io, Io.Duration.fromMilliseconds(300), .awake) catch {};

    var rb: [1024]u8 = undefined;
    var rdr = cs.reader(io, &rb);
    var out: [1024]u8 = undefined;
    const resp = readResp(&rdr.interface, &out); // reads the 408 head (content-length 0)
    try testing.expect(std.mem.indexOf(u8, resp, "408 Request Timeout") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "timeout: idle keep-alive connection is closed after idle_timeout" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{ .idle_timeout_ms = 100 });
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18113;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);

    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    var rb: [1024]u8 = undefined;
    var rdr = cs.reader(io, &rb);

    // One full request + response, keeping the connection open.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out: [1024]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, readResp(&rdr.interface, &out), "pong"));

    // Now stall past idle_timeout; the server should close the connection.
    Io.sleep(io, Io.Duration.fromMilliseconds(300), .awake) catch {};
    try testing.expectError(error.EndOfStream, rdr.interface.fillMore());

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn formCookieHandler(c: Cookies, a: @import("extract/alloc.zig").Alloc, body: Form(struct { name: []const u8 })) !Response {
    const sid = c.get("sid") orelse "none";
    const out = try std.fmt.allocPrint(a.value, "{s}|{s}", .{ body.value.name, sid });
    return Response.text(out);
}

test "input parity: Form + Cookies over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/submit", formCookieHandler);

    const port: u16 = 18120;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // urlencoded body "name=ada+lovelace" (17 bytes); cookie sid=xyz.
    const raw = "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: sid=xyz\r\nContent-Length: 17\r\n\r\nname=ada+lovelace";
    const r = doRequest(io, port, raw, &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r, "ada lovelace|xyz"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

const Multipart = @import("extract/multipart.zig").Multipart;

fn multipartHandler(a: @import("extract/alloc.zig").Alloc, mp: Multipart) Response {
    const filename = mp.file("f").?.filename.?;
    const desc = mp.field("desc").?;
    const out = std.fmt.allocPrint(a.value, "{s}|{s}", .{ filename, desc }) catch "error";
    return Response.text(out);
}

test "input parity: Multipart over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/upload", multipartHandler);

    const port: u16 = 18125;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const body =
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"desc\"\r\n\r\n" ++
        "hi\r\n" ++
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "data\r\n" ++
        "--X--\r\n";
    const clen = std.fmt.comptimePrint("{d}", .{body.len});
    const raw =
        "POST /upload HTTP/1.1\r\n" ++
        "Host: x\r\n" ++
        "Content-Type: multipart/form-data; boundary=X\r\n" ++
        "Content-Length: " ++ clen ++ "\r\n\r\n" ++
        body;
    const r = doRequest(io, port, raw, &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, r, "hi") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn redirectHandler() Response {
    return Response.redirect(.found, "/next");
}

const Lines = struct { n: usize };
fn writeLines(c: *const Lines, w: *Io.Writer) anyerror!void {
    var i: usize = 0;
    while (i < c.n) : (i += 1) try w.print("line{d}\n", .{i});
}
fn streamHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(Lines);
    c.* = .{ .n = 3 };
    return Response.stream(Lines, c, writeLines, "text/plain");
}

test "streaming: connection-close streamed body over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/stream", streamHandler);

    const port: u16 = 18140;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll("GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    // Read to EOF (the server closes after a streamed, connection-close response).
    var rb: [4096]u8 = undefined;
    var rdr = cs.reader(io, &rb);
    while (true) rdr.interface.fillMore() catch break;
    const resp = rdr.interface.buffered();

    try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "content-length:") == null);
    try testing.expect(std.mem.endsWith(u8, resp, "line0\nline1\nline2\n"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

const Sse = @import("http/sse.zig").Sse;
const Feed = struct { n: usize };
fn feed(f: *const Feed, s: *Sse) anyerror!void {
    var i: usize = 0;
    while (i < f.n) : (i += 1) try s.send(.{ .event = "tick", .data = "hi", .id = "1" });
    try s.comment("bye");
}
fn sseHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const f = try a.value.create(Feed);
    f.* = .{ .n = 2 };
    return Response.sse(Feed, f, feed);
}

test "sse: event stream over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/events", sseHandler);

    const port: u16 = 18150;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll("GET /events HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    var rb: [4096]u8 = undefined;
    var rdr = cs.reader(io, &rb);
    while (true) rdr.interface.fillMore() catch break;
    const resp = rdr.interface.buffered();

    try testing.expect(std.mem.indexOf(u8, resp, "content-type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "event: tick\nid: 1\ndata: hi\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, resp, ": bye\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

const Files = @import("extract/files.zig").Files;
fn serveBuild(files: Files) !Response {
    return files.file("build.zig");
}
const PathRest = struct { rest: []const u8 };
fn serveAsset(p: @import("extract/path.zig").Path(PathRest), files: Files) !Response {
    return files.dir(".", p.value.rest);
}

test "files: serve a file and reject traversal over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/build", serveBuild);
    try app.get("/assets/:rest", serveAsset);

    const port: u16 = 18160;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [64 * 1024]u8 = undefined;
    const r1 = doRequest(io, port, "GET /build HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "content-length:") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "pub fn build") != null);

    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /assets/.. HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "404 Not Found") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "responses: redirect over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/old", redirectHandler);

    const port: u16 = 18130;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /old HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "302 Found") != null);
    try testing.expect(std.mem.indexOf(u8, r, "location: /next\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn customNotFound() Response {
    return .{ .status = .not_found, .body = "custom-404" };
}
fn spaIndex() Response {
    return Response.text("spa-index");
}
fn fallbackTagMw(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-fallback", "1");
}

test "fallback: custom 404 handler for unmatched routes" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);
    try app.fallback(customNotFound);

    const port: u16 = 18170;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "404 Not Found") != null);
    try testing.expect(std.mem.endsWith(u8, r, "custom-404"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "fallback: SPA-style 200 + middleware applies; 405 unaffected" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&fallbackTagMw);
    try app.get("/ping", pingHandler);
    try app.fallback(spaIndex);

    const port: u16 = 18171;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /anything HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "x-fallback: 1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r, "spa-index"));

    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "DELETE /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "405 Method Not Allowed") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

const ObsCapture = struct {
    method: request.Method = .GET,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    status: u16 = 0,
    count: usize = 0,
};
fn obsCapture(ctx: *anyopaque, rec: observe_mod.AccessRecord) void {
    const c: *ObsCapture = @ptrCast(@alignCast(ctx));
    c.method = rec.method;
    const n = @min(rec.path.len, c.path_buf.len);
    @memcpy(c.path_buf[0..n], rec.path[0..n]);
    c.path_len = n;
    c.status = rec.status;
    c.count += 1;
}

test "observe: hook fires for matched and 404 with method/path/status" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);

    var cap = ObsCapture{};
    try app.observe(.{ .context = &cap, .func = obsCapture });

    const port: u16 = 18190;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expectEqual(@as(u16, 200), cap.status);
    try testing.expectEqualStrings("/ping", cap.path_buf[0..cap.path_len]);
    try testing.expect(cap.method == .GET);

    var rb2: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expectEqual(@as(u16, 404), cap.status); // observer covers non-matched
    try testing.expect(cap.count >= 2);

    app.requestShutdown(io);
    loop_fut.await(io);
}

var test_metrics: observe_mod.Metrics = .{};
fn metricsTestHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    var w = std.Io.Writer.Allocating.init(a.value);
    try test_metrics.writePrometheus(&w.writer);
    return .{ .status = .ok, .content_type = "text/plain; version=0.0.4", .body = w.written() };
}

test "metrics: end-to-end via observer + /metrics handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    test_metrics = .{}; // reset (process may be shared across tests)
    try app.get("/ping", pingHandler);
    try app.get("/metrics", metricsTestHandler);
    try app.observe(test_metrics.observer());

    const port: u16 = 18191;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);

    var rb2: [4096]u8 = undefined;
    const r = doRequest(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "zax_requests_total{class=\"2xx\"} 2") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn echoTail(p: Path(struct { path: []const u8 })) Response {
    return Response.text(p.value.path);
}

test "wildcard: catch-all captures the path tail end-to-end" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);
    try app.get("/assets/*path", echoTail);

    const port: u16 = 18172;
    var loop_fut = startTestApp(io, &app, port);

    // Multi-segment tail captured (slashes preserved).
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /assets/css/app.css HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r, "css/app.css"));

    // Bare prefix does NOT match the catch-all -> 404.
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /assets HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "404 Not Found") != null);

    // An unrelated static route still works (wildcard didn't shadow it).
    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: prefixes routes; non-prefixed path 404s" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{});
    try api.get("/users", pingHandler);
    const port: u16 = 18177;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/users HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "200 OK") != null);
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n", &rb2), "404 Not Found") != null);
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: group middleware applies in order global -> group -> route -> handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    const api = app.group("/api", .{&wrapGrp});
    try api.getWith("/x", .{&wrapR}, bodyH);
    try app.get("/plain", bodyH);
    const port: u16 = 18178;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, doRequest(io, port, "GET /api/x HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "G(Grp(R(H)))"));
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, doRequest(io, port, "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n", &rb2), "G(H)"));
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: nested groups compose prefix and middleware" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    const api = app.group("/api", .{&wrapGrp});
    const v1 = api.group("/v1", .{&wrapV1});
    try v1.get("/items", bodyH);
    const port: u16 = 18179;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /api/v1/items HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r, "G(Grp(V1(H)))"));
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: shared middleware short-circuits group routes only" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{&requireAuth});
    try api.get("/secret", pingHandler);
    try app.get("/open", pingHandler);
    const port: u16 = 18180;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/secret HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "401 Unauthorized") != null);
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/secret HTTP/1.1\r\nHost: x\r\nAuthorization: t\r\n\r\n", &rb2), "200 OK") != null);
    var rb3: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /open HTTP/1.1\r\nHost: x\r\n\r\n", &rb3), "200 OK") != null);
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: non-GET verb registers under the group prefix" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{});
    try api.post("/things", pingHandler);
    const port: u16 = 18181;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "POST /api/things HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "200 OK") != null);
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/things HTTP/1.1\r\nHost: x\r\n\r\n", &rb2), "405 Method Not Allowed") != null);
    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: empty pattern registers the group root" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{});
    try api.get("", pingHandler);
    const port: u16 = 18182;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "200 OK") != null);
    app.requestShutdown(io);
    loop_fut.await(io);
}

fn ridHandler(rid: @import("extract/request_id.zig").RequestId) Response {
    return Response.text(rid.value);
}

test "validRid accepts safe tokens, rejects unsafe" {
    try testing.expect(validRid("abc-123"));
    try testing.expect(validRid("00000000000000a1"));
    try testing.expect(!validRid(""));
    try testing.expect(!validRid("bad id"));   // space
    try testing.expect(!validRid("a\r\nb"));   // CRLF
    try testing.expect(!validRid("a/b"));      // slash
    try testing.expect(!validRid("x" ** 129)); // too long
}

test "setNoDelay enables TCP_NODELAY on a socket" {
    if (builtin.os.tag == .linux) {
        // Linux: use syscalls directly — no libc needed in the test binary.
        const linux = std.os.linux;
        const sfd = linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        const se = linux.errno(sfd);
        if (se != .SUCCESS) return std.posix.unexpectedErrno(se);
        const fd: i32 = @intCast(sfd);
        defer _ = linux.close(@intCast(fd));
        setNoDelay(fd);
        var val: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        const grc = linux.getsockopt(fd, std.posix.IPPROTO.TCP, @intCast(std.posix.TCP.NODELAY), @ptrCast(&val), &len);
        const ge = linux.errno(grc);
        try testing.expect(ge == .SUCCESS);
        try testing.expect(val != 0);
    } else {
        // macOS: use libc.
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        try testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        setNoDelay(fd);
        var val: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        const rc = std.c.getsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &val, &len);
        try testing.expect(rc == 0);
        try testing.expect(val != 0);
    }
}

test "Options: tcp_nodelay defaults on (opt-out)" {
    try testing.expect((Options{}).tcp_nodelay);
    try testing.expect(!(Options{ .tcp_nodelay = false }).tcp_nodelay);
}

test "request id: generated, echoed, and exposed to handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .request_id = true });
    defer app.deinit();
    try app.get("/rid", ridHandler);
    const port: u16 = 18192;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "x-request-id: ") != null);

    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\nX-Request-Id: abc-123\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "x-request-id: abc-123\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "abc-123"));

    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\nX-Request-Id: bad id!\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "bad id!") == null);
    try testing.expect(std.mem.indexOf(u8, r3, "x-request-id: ") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "request id: disabled by default -> no header, empty value" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/rid", ridHandler);
    const port: u16 = 18193;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "x-request-id:") == null);
    app.requestShutdown(io);
    loop_fut.await(io);
}

// ---------------------------------------------------------------------------
// Counters shared between the capped / uncapped in-flight tests.
// ---------------------------------------------------------------------------
const InFlightState = struct {
    in_flight: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    max_seen: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Io handle so the handler can sleep without requiring OS-level sleep API.
    io: Io,
};

fn inFlightHandler(s: State(*InFlightState)) !Response {
    const c = s.value;
    const prev = c.in_flight.fetchAdd(1, .acq_rel);
    const cur = prev + 1;
    // CAS-max: update max_seen if cur is larger.
    var old = c.max_seen.load(.acquire);
    while (old < cur) {
        old = c.max_seen.cmpxchgWeak(old, cur, .acq_rel, .acquire) orelse break;
    }
    // Park briefly so multiple requests overlap in the server.
    Io.sleep(c.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
    _ = c.in_flight.fetchSub(1, .acq_rel);
    return Response.text("ok");
}

test "max_in_flight: cap holds under concurrent load" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = InFlightState{ .io = io };
    const InFlightApp = App(*InFlightState);
    var app = try InFlightApp.init(testing.allocator, &state, .{ .max_in_flight = 2 });
    defer app.deinit();
    try app.get("/work", inFlightHandler);

    const port: u16 = 18194;
    app.bind(io, .{ .ip4 = .loopback(port) }) catch unreachable;
    var loop_fut = io.async(InFlightApp.acceptLoop, .{ &app, io });

    // Spawn 8 concurrent client tasks, all fire simultaneously.
    var group: Io.Group = .init;
    const N = 8;
    var bufs: [N][2048]u8 = undefined;
    var results: [N][]const u8 = undefined;
    const Ctx = struct {
        io: Io,
        port: u16,
        buf: *[2048]u8,
        result: *[]const u8,
        fn run(self: *@This()) void {
            self.result.* = doRequest(self.io, self.port, "GET /work HTTP/1.1\r\nHost: x\r\n\r\n", self.buf);
        }
    };
    var ctxs: [N]Ctx = undefined;
    for (0..N) |i| {
        ctxs[i] = .{ .io = io, .port = port, .buf = &bufs[i], .result = &results[i] };
        group.async(io, Ctx.run, .{&ctxs[i]});
    }
    group.await(io) catch unreachable;

    // All 8 must have succeeded.
    for (0..N) |i| {
        try testing.expect(std.mem.indexOf(u8, results[i], "200 OK") != null);
        try testing.expect(std.mem.endsWith(u8, results[i], "ok"));
    }
    // The cap must have held: never more than 2 simultaneous in-flight.
    const observed_max = state.max_seen.load(.acquire);
    try testing.expect(observed_max <= 2);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "max_in_flight: default (0) is unbounded — all requests succeed" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = InFlightState{ .io = io };
    const InFlightApp = App(*InFlightState);
    var app = try InFlightApp.init(testing.allocator, &state, .{}); // max_in_flight = 0
    defer app.deinit();
    try app.get("/work", inFlightHandler);

    const port: u16 = 18195;
    app.bind(io, .{ .ip4 = .loopback(port) }) catch unreachable;
    var loop_fut = io.async(InFlightApp.acceptLoop, .{ &app, io });

    var group: Io.Group = .init;
    const N = 8;
    var bufs: [N][2048]u8 = undefined;
    var results: [N][]const u8 = undefined;
    const Ctx = struct {
        io: Io,
        port: u16,
        buf: *[2048]u8,
        result: *[]const u8,
        fn run(self: *@This()) void {
            self.result.* = doRequest(self.io, self.port, "GET /work HTTP/1.1\r\nHost: x\r\n\r\n", self.buf);
        }
    };
    var ctxs: [N]Ctx = undefined;
    for (0..N) |i| {
        ctxs[i] = .{ .io = io, .port = port, .buf = &bufs[i], .result = &results[i] };
        group.async(io, Ctx.run, .{&ctxs[i]});
    }
    group.await(io) catch unreachable;

    // All 8 must succeed (unbounded — no drops, no hangs).
    for (0..N) |i| {
        try testing.expect(std.mem.indexOf(u8, results[i], "200 OK") != null);
        try testing.expect(std.mem.endsWith(u8, results[i], "ok"));
    }
    // Prove the harness genuinely produces concurrency: with no cap and 8
    // concurrent clients each sleeping 5 ms, at least 2 must overlap.  This
    // makes the capped test's `<= 2` assertion meaningful by contrast.
    try testing.expect(state.max_seen.load(.acquire) >= 2);

    app.requestShutdown(io);
    loop_fut.await(io);
}

// ---------------------------------------------------------------------------
// Chunked-streaming + keep-alive tests (threaded backend)
// ---------------------------------------------------------------------------

/// Read exactly one chunked HTTP response from `r`: headers + body up to and
/// including the `0\r\n\r\n` terminator. Copies into `out` and consumes from
/// the reader buffer. Returns the slice of `out` that was filled.
fn readChunkedResp(r: *Io.Reader, out: []u8) []const u8 {
    // Fill until we have the full header block.
    while (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n") == null) {
        r.fillMore() catch break;
    }
    // Fill until we have the chunked terminator "0\r\n\r\n".
    while (std.mem.indexOf(u8, r.buffered(), "0\r\n\r\n") == null) {
        r.fillMore() catch break;
    }
    const term = (std.mem.indexOf(u8, r.buffered(), "0\r\n\r\n") orelse return out[0..0]) + 5;
    const total = @min(term, out.len);
    @memcpy(out[0..total], r.buffered()[0..total]);
    r.toss(total);
    return out[0..total];
}

const TwoChunks = struct { n: usize };
fn twoChunksNext(c: *TwoChunks, buf: []u8) response.PullResult {
    if (c.n == 0) return .done;
    const payload = if (c.n == 2) "one" else "two";
    c.n -= 1;
    @memcpy(buf[0..payload.len], payload);
    return .{ .chunk = payload.len };
}
fn twoChunksPullHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(TwoChunks);
    c.* = .{ .n = 2 };
    return Response.streamPull(TwoChunks, c, twoChunksNext, "text/plain");
}

test "streaming: persistent pull-stream uses chunked framing and keeps connection alive" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/chunks", twoChunksPullHandler);
    try app.get("/ping", pingHandler);

    const port: u16 = 18200;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // First request: persistent HTTP/1.1 to the pull-stream route.
    cw.interface.writeAll("GET /chunks HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    var out1: [2048]u8 = undefined;
    const r1 = readChunkedResp(&cr.interface, &out1);

    // Response head must advertise chunked + keep-alive.
    try testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "transfer-encoding: chunked") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "connection: keep-alive") != null);

    // Body must contain the two framed chunks and the terminator.
    try testing.expect(std.mem.indexOf(u8, r1, "3\r\none\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "3\r\ntwo\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "0\r\n\r\n") != null);

    // Second request on the SAME connection — proves keep-alive worked.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out2: [1024]u8 = undefined;
    const r2 = readResp(&cr.interface, &out2);
    try testing.expect(std.mem.indexOf(u8, r2, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "pong"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "streaming: persistent push-stream uses chunked framing and keeps connection alive" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/push", streamHandler);
    try app.get("/ping", pingHandler);

    const port: u16 = 18220;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // First request: persistent HTTP/1.1 to the PUSH-stream route (Response.stream).
    cw.interface.writeAll("GET /push HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    var out1: [2048]u8 = undefined;
    const r1 = readChunkedResp(&cr.interface, &out1);

    // Head must advertise chunked + keep-alive (push streamer on a persistent client).
    try testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "transfer-encoding: chunked") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "connection: keep-alive") != null);

    // Body must contain the streamed lines (chunk-framed) and the terminator.
    try testing.expect(std.mem.indexOf(u8, r1, "line0") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "line2") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "0\r\n\r\n") != null);

    // Second request on the SAME connection — proves keep-alive after a push stream.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out2: [1024]u8 = undefined;
    const r2 = readResp(&cr.interface, &out2);
    try testing.expect(std.mem.indexOf(u8, r2, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "pong"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

// ---------------------------------------------------------------------------
// Cross-platform socket helpers for serveEvented tests
// (std.posix lacks socket/connect/close in Zig 0.16; use linux.* or std.c.*)
// ---------------------------------------------------------------------------

/// True when the evented reactor is available on this platform.
const evented_supported = switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
    .freebsd, .dragonfly, .netbsd, .openbsd => true,
    else => false,
};

/// Create a blocking TCP socket.  Returns fd; caller must sev_closeFd.
fn sevSocket() !i32 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        return @intCast(rc);
    } else {
        const rc = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (rc < 0) return error.SocketFailed;
        return rc;
    }
}

/// Close a socket fd.
fn sevCloseFd(fd: i32) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(@intCast(fd));
    } else {
        _ = std.c.close(fd);
    }
}

/// Connect fd to localhost:port (blocking).  Returns false on failure.
fn sevConnect(fd: i32, port: u16) bool {
    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.connect(@intCast(fd), @ptrCast(&sa_in), @sizeOf(std.posix.sockaddr.in));
        return std.os.linux.errno(rc) == .SUCCESS;
    } else {
        const rc = std.c.connect(fd, @ptrCast(&sa_in), @sizeOf(std.posix.sockaddr.in));
        return rc == 0;
    }
}

/// Sleep for `ms` milliseconds (cross-platform).
fn sevSleep(ms: u64) void {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const ts = linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = linux.nanosleep(&ts, null);
    } else {
        const ts = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Write all bytes of `data` to `fd`.
fn sevWrite(fd: i32, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.write(@intCast(fd), data[sent..].ptr, data.len - sent))
        else
            std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.SendFailed;
        sent += @intCast(n);
    }
}

/// Read bytes from a blocking `fd` into `buf` until a complete HTTP response.
fn sevRecvFull(fd: i32, buf: []u8) []u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(fd), buf[total..].ptr, buf.len - total))
        else
            std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |sep| {
            if (std.mem.indexOf(u8, buf[0 .. sep + 4], "content-length: ")) |cl_start| {
                const after = buf[cl_start + "content-length: ".len .. sep + 4];
                const end = std.mem.indexOfAny(u8, after, "\r\n") orelse after.len;
                const clen = std.fmt.parseInt(usize, after[0..end], 10) catch 0;
                if (total - (sep + 4) >= clen) break;
            } else break;
        }
    }
    return buf[0..total];
}

/// Poll until localhost:port accepts a connection (up to max_attempts * 10ms).
fn sevWaitListening(port: u16, max_attempts: usize) void {
    var i: usize = 0;
    while (i < max_attempts) : (i += 1) {
        sevSleep(10);
        const tfd = sevSocket() catch continue;
        if (sevConnect(tfd, port)) {
            sevCloseFd(tfd);
            break;
        }
        sevCloseFd(tfd);
    }
}

// ---------------------------------------------------------------------------
// serveEvented tests
// ---------------------------------------------------------------------------

test "serveEvented: returns EventedUnsupported on non-Linux" {
    // This test only runs on platforms where the reactor is unsupported
    // (Windows, wasm). On Linux and macOS/BSD the reactor is supported and
    // serveEvented would actually start — so we skip there.
    const reactor_supported = switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
        .freebsd, .dragonfly, .netbsd, .openbsd => true,
        else => false,
    };
    if (reactor_supported) return error.SkipZigTest;

    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();

    const addr = net.IpAddress{ .ip4 = .loopback(19000) };
    try testing.expectError(error.EventedUnsupported, app.serveEvented(io, addr, .{}));
}

test "serveEvented: 2-worker integration — keep-alive requests across 3 routes" {
    // Runs on Linux (epoll) and macOS/BSD (kqueue). Skip on unsupported platforms.
    if (!evented_supported) return error.SkipZigTest;

    var db = Db{ .msg = "hello" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/", pingHandler);
    try app.get("/users/:id", echoId);
    try app.post("/echo", pingHandler);

    const port: u16 = 18200;
    const addr = net.IpAddress{ .ip4 = .loopback(port) };

    const ServeCtx = struct {
        app: *TestApp,
        io: Io,
        addr: net.IpAddress,
        err: ?anyerror = null,
    };
    var serve_ctx = ServeCtx{ .app = &app, .io = undefined, .addr = addr };
    var srv_threaded = Io.Threaded.init(testing.allocator, .{});
    defer srv_threaded.deinit();
    serve_ctx.io = srv_threaded.io();

    const ServeThread = struct {
        fn run(ctx: *ServeCtx) void {
            ctx.app.serveEvented(ctx.io, ctx.addr, .{ .workers = 2 }) catch |e| {
                ctx.err = e;
            };
        }
    };
    const srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{&serve_ctx});

    sevWaitListening(port, 50);

    const N_THREADS = 5;
    const N_REQS_PER_THREAD = 10;
    const Total = N_THREADS * N_REQS_PER_THREAD;

    var correct = std.atomic.Value(usize).init(0);

    const ClientCtx = struct {
        port: u16,
        correct: *std.atomic.Value(usize),
    };

    const ClientThread = struct {
        fn run(ctx: *ClientCtx) void {
            const cfd = sevSocket() catch return;
            defer sevCloseFd(cfd);
            if (!sevConnect(cfd, ctx.port)) return;

            var buf: [8192]u8 = undefined;
            var i: usize = 0;
            while (i < N_REQS_PER_THREAD) : (i += 1) {
                sevWrite(cfd, "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n") catch return;
                const resp = sevRecvFull(cfd, &buf);
                if (std.mem.indexOf(u8, resp, "200") != null and
                    std.mem.indexOf(u8, resp, "hello") != null)
                {
                    _ = ctx.correct.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var client_threads: [N_THREADS]std.Thread = undefined;
    var client_ctxs: [N_THREADS]ClientCtx = undefined;
    for (0..N_THREADS) |i| {
        client_ctxs[i] = .{ .port = port, .correct = &correct };
        client_threads[i] = try std.Thread.spawn(.{}, ClientThread.run, .{&client_ctxs[i]});
    }
    for (0..N_THREADS) |i| client_threads[i].join();

    try testing.expectEqual(Total, correct.load(.acquire));

    var shutdown_threaded = Io.Threaded.init(testing.allocator, .{});
    defer shutdown_threaded.deinit();
    app.requestShutdown(shutdown_threaded.io());

    srv_thread.join();
    try testing.expect(serve_ctx.err == null);
}

test "serveEvented: observer fires for each request" {
    if (!evented_supported) return error.SkipZigTest;

    var db = Db{ .msg = "hello" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);

    var cap = ObsCapture{};
    try app.observe(.{ .context = &cap, .func = obsCapture });

    const port: u16 = 18201;
    const addr = net.IpAddress{ .ip4 = .loopback(port) };

    const ServeCtx = struct {
        app: *TestApp,
        io: Io,
        addr: net.IpAddress,
        err: ?anyerror = null,
    };
    var serve_ctx = ServeCtx{ .app = &app, .io = undefined, .addr = addr };
    var srv_threaded = Io.Threaded.init(testing.allocator, .{});
    defer srv_threaded.deinit();
    serve_ctx.io = srv_threaded.io();

    const ServeThread = struct {
        fn run(ctx: *ServeCtx) void {
            ctx.app.serveEvented(ctx.io, ctx.addr, .{ .workers = 1 }) catch |e| {
                ctx.err = e;
            };
        }
    };
    const srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{&serve_ctx});

    sevWaitListening(port, 50);

    const cfd = try sevSocket();
    try testing.expect(sevConnect(cfd, port));
    defer sevCloseFd(cfd);

    var buf1: [2048]u8 = undefined;
    try sevWrite(cfd, "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    _ = sevRecvFull(cfd, &buf1);

    var buf2: [2048]u8 = undefined;
    try sevWrite(cfd, "GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    _ = sevRecvFull(cfd, &buf2);

    sevSleep(20);

    try testing.expect(cap.count >= 2);
    try testing.expectEqual(@as(u16, 404), cap.status);

    var shutdown_threaded = Io.Threaded.init(testing.allocator, .{});
    defer shutdown_threaded.deinit();
    app.requestShutdown(shutdown_threaded.io());
    srv_thread.join();
    try testing.expect(serve_ctx.err == null);
}

test "serveEvented: request_id generated and echoed" {
    if (!evented_supported) return error.SkipZigTest;

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .request_id = true });
    defer app.deinit();
    try app.get("/rid", ridHandler);

    const port: u16 = 18202;
    const addr = net.IpAddress{ .ip4 = .loopback(port) };

    const ServeCtx = struct {
        app: *TestApp,
        io: Io,
        addr: net.IpAddress,
        err: ?anyerror = null,
    };
    var serve_ctx = ServeCtx{ .app = &app, .io = undefined, .addr = addr };
    var srv_threaded = Io.Threaded.init(testing.allocator, .{});
    defer srv_threaded.deinit();
    serve_ctx.io = srv_threaded.io();

    const ServeThread = struct {
        fn run(ctx: *ServeCtx) void {
            ctx.app.serveEvented(ctx.io, ctx.addr, .{ .workers = 1 }) catch |e| {
                ctx.err = e;
            };
        }
    };
    const srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{&serve_ctx});

    sevWaitListening(port, 50);

    const cfd = try sevSocket();
    try testing.expect(sevConnect(cfd, port));
    defer sevCloseFd(cfd);

    // 1. No incoming x-request-id → server generates one and echoes it.
    var buf1: [2048]u8 = undefined;
    try sevWrite(cfd, "GET /rid HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    const r1 = sevRecvFull(cfd, &buf1);
    try testing.expect(std.mem.indexOf(u8, r1, "x-request-id: ") != null);

    // 2. Valid incoming x-request-id → server echoes it unchanged.
    var buf2: [2048]u8 = undefined;
    try sevWrite(cfd, "GET /rid HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\nX-Request-Id: abc-123\r\n\r\n");
    const r2 = sevRecvFull(cfd, &buf2);
    try testing.expect(std.mem.indexOf(u8, r2, "x-request-id: abc-123\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "abc-123"));

    // 3. Invalid incoming x-request-id → server replaces with generated id.
    var buf3: [2048]u8 = undefined;
    try sevWrite(cfd, "GET /rid HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-Request-Id: bad id!\r\n\r\n");
    const r3 = sevRecvFull(cfd, &buf3);
    try testing.expect(std.mem.indexOf(u8, r3, "bad id!") == null);
    try testing.expect(std.mem.indexOf(u8, r3, "x-request-id: ") != null);

    var shutdown_threaded = Io.Threaded.init(testing.allocator, .{});
    defer shutdown_threaded.deinit();
    app.requestShutdown(shutdown_threaded.io());
    srv_thread.join();
    try testing.expect(serve_ctx.err == null);
}

// ---------------------------------------------------------------------------
// Threaded pull-stream backoff + idle-cap tests
// ---------------------------------------------------------------------------

/// A counter-driven pull producer for the backoff tests.
/// Behaviour is controlled by two counters:
///   - `zeros_left`: how many chunk(0) calls before we return real data
///   - chunks are returned from `payloads[payload_idx]` in order, then .done
const BackoffProducer = struct {
    zeros_left: usize,
    payload_idx: usize,
    payloads: []const []const u8,

    fn next(self: *BackoffProducer, buf: []u8) response.PullResult {
        if (self.zeros_left > 0) {
            self.zeros_left -= 1;
            return .{ .chunk = 0 };
        }
        if (self.payload_idx >= self.payloads.len) return .done;
        const p = self.payloads[self.payload_idx];
        self.payload_idx += 1;
        @memcpy(buf[0..p.len], p);
        return .{ .chunk = p.len };
    }
};

fn backoffHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(BackoffProducer);
    c.* = .{ .zeros_left = 2, .payload_idx = 0, .payloads = &[_][]const u8{ "hello", "world" } };
    return Response.streamPull(BackoffProducer, c, BackoffProducer.next, "text/plain");
}

/// A producer that returns chunk(0) forever (idle-cap test).
const InfiniteZeroProducer = struct {
    fn next(_: *InfiniteZeroProducer, _: []u8) response.PullResult {
        return .{ .chunk = 0 };
    }
};

fn idleCapHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(InfiniteZeroProducer);
    c.* = .{};
    return Response.streamPull(InfiniteZeroProducer, c, InfiniteZeroProducer.next, "text/plain");
}

/// A producer that returns chunk(0) once then "ok" then .done.
const ZeroOnceThenOkProducer = struct {
    called: bool = false,
    done: bool = false,

    fn next(self: *ZeroOnceThenOkProducer, buf: []u8) response.PullResult {
        if (!self.called) {
            self.called = true;
            return .{ .chunk = 0 };
        }
        if (!self.done) {
            self.done = true;
            const p = "ok";
            @memcpy(buf[0..p.len], p);
            return .{ .chunk = p.len };
        }
        return .done;
    }
};

fn zeroOnceThenOkHandler(a: @import("extract/alloc.zig").Alloc) !Response {
    const c = try a.value.create(ZeroOnceThenOkProducer);
    c.* = .{};
    return Response.streamPull(ZeroOnceThenOkProducer, c, ZeroOnceThenOkProducer.next, "text/plain");
}

test "threaded pull-stream backoff: chunk(0) x2 then data completes correctly" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{ .stream_repoll_ms = 1, .idle_timeout_ms = 50 });
    defer app.deinit();
    try app.get("/backoff", backoffHandler);

    const port: u16 = 18210;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    cw.interface.writeAll("GET /backoff HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    var out: [4096]u8 = undefined;
    const r = readChunkedResp(&cr.interface, &out);

    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "transfer-encoding: chunked") != null);
    try testing.expect(std.mem.indexOf(u8, r, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, r, "world") != null);
    // The stream must end with the chunked terminator.
    try testing.expect(std.mem.indexOf(u8, r, "0\r\n\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "threaded pull-stream idle cap: truncates without chunked terminator" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    // idle cap of 5 ms; repoll every 1 ms so the cap fires quickly.
    var app = try TestApp.init(testing.allocator, &db, .{ .stream_repoll_ms = 1, .stream_idle_timeout_ms = 5, .idle_timeout_ms = 50 });
    defer app.deinit();
    try app.get("/idle", idleCapHandler);

    const port: u16 = 18211;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    cw.interface.writeAll("GET /idle HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    // Read until the connection closes (idle cap triggers hard close).
    while (true) {
        cr.interface.fillMore() catch break;
    }
    const received = cr.interface.buffered();

    // Must contain 200 OK header.
    try testing.expect(std.mem.indexOf(u8, received, "200 OK") != null);
    // Must NOT contain the chunked terminator (truncated).
    try testing.expect(std.mem.indexOf(u8, received, "0\r\n\r\n") == null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "threaded pull-stream repoll_ms=0: no-sleep path still completes" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    // repoll_ms=0 → legacy busy-loop; stream still completes.
    var app = try TestApp.init(testing.allocator, &db, .{ .stream_repoll_ms = 0, .idle_timeout_ms = 50 });
    defer app.deinit();
    try app.get("/legacy", zeroOnceThenOkHandler);

    const port: u16 = 18212;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    cw.interface.writeAll("GET /legacy HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;

    var out: [4096]u8 = undefined;
    const r = readChunkedResp(&cr.interface, &out);

    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "ok") != null);
    try testing.expect(std.mem.indexOf(u8, r, "0\r\n\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn headersGetHandler(h: Headers) Response {
    return Response.text(h.get("x-test") orelse "");
}

fn headersGetAllHandler(a: Alloc, h: Headers) !Response {
    const vals = try h.getAll(a.value, "x-dup");
    const out = try std.fmt.allocPrint(a.value, "{d}", .{vals.len});
    return Response.text(out);
}

test "Headers extractor: get() echoes first matching header value" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/hdr", headersGetHandler);

    const port: u16 = 18213;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [1024]u8 = undefined;
    const r = doRequest(io, port, "GET /hdr HTTP/1.1\r\nHost: x\r\nX-Test: hi\r\n\r\n", &rb);
    try testing.expect(std.mem.endsWith(u8, r, "hi"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "Headers extractor: getAll() counts duplicate headers" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/hdrall", headersGetAllHandler);

    const port: u16 = 18214;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [1024]u8 = undefined;
    const r = doRequest(io, port, "GET /hdrall HTTP/1.1\r\nHost: x\r\nX-Dup: a\r\nX-Dup: b\r\n\r\n", &rb);
    try testing.expect(std.mem.endsWith(u8, r, "2"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn setCookieHandler(a: Alloc) anyerror!Response {
    return Response.text("ok").withCookie(a.value, .{ .name = "sid", .value = "xyz", .http_only = true });
}

test "e2e: handler sets a cookie via withCookie" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/cookie", setCookieHandler);

    const port: u16 = 18215;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [1024]u8 = undefined;
    const r = doRequest(io, port, "GET /cookie HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "set-cookie: sid=xyz; HttpOnly\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "e2e: cors preflight 204 and actual request gets allow-origin" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(cors_mod.cors(TestApp.Context, .{ .origins = .any }));
    try app.get("/x", pingHandler);

    const port: u16 = 18222;
    var loop_fut = startTestApp(io, &app, port);

    // Preflight: OPTIONS with Origin + Access-Control-Request-Method → 204 + allow-methods.
    var rb1: [1024]u8 = undefined;
    const pre = doRequest(io, port,
        "OPTIONS /x HTTP/1.1\r\nHost: x\r\nOrigin: https://a.com\r\nAccess-Control-Request-Method: GET\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, pre, "HTTP/1.1 204") != null);
    try testing.expect(std.mem.indexOf(u8, pre, "access-control-allow-methods:") != null);

    // Actual: GET with Origin → access-control-allow-origin: *.
    var rb2: [1024]u8 = undefined;
    const act = doRequest(io, port, "GET /x HTTP/1.1\r\nHost: x\r\nOrigin: https://a.com\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, act, "access-control-allow-origin: *\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "e2e: OPTIONS on GET-only route without CORS still returns 405 with allow header" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    // No CORS middleware — OPTIONS method-mismatch must still yield 405 + allow.
    try app.get("/x", pingHandler);

    const port: u16 = 18223;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [1024]u8 = undefined;
    const r = doRequest(io, port, "OPTIONS /x HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "HTTP/1.1 405") != null);
    try testing.expect(std.mem.indexOf(u8, r, "allow: ") != null);
    try testing.expect(std.mem.indexOf(u8, r, "GET") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn bigHandler() Response {
    return Response.text("x" ** 2000);
}
fn smallHandler() Response {
    return Response.text("hi");
}

test "e2e: gzip compresses a large text response when accepted" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(compress_mod.compress(TestApp.Context, .{}));
    try app.get("/big", bigHandler);
    try app.get("/small", smallHandler);

    const port: u16 = 18224;
    var loop_fut = startTestApp(io, &app, port);

    // Large body + Accept-Encoding: gzip → content-encoding: gzip in response.
    var rb1: [4096]u8 = undefined;
    const big = doRequest(io, port, "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, big, "content-encoding: gzip\r\n") != null);

    // Small body (below min_length) → no content-encoding header.
    var rb2: [4096]u8 = undefined;
    const small = doRequest(io, port, "GET /small HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, small, "content-encoding: gzip") == null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

fn wsEchoOnMessage(conn: *ws_mod.WsConn, frame: ws_mod.Frame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}
fn wsEchoHandler(sock: @import("extract/websocket.zig").WebSocket) Response {
    return sock.onUpgrade(.{ .on_message = wsEchoOnMessage });
}

test "end-to-end: websocket upgrade, handshake, and echo" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18097;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // 1. Send the handshake and assert 101 + accept value.
    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    cw.interface.writeAll(upgrade_req) catch unreachable;
    cw.interface.flush() catch unreachable;
    var tries1: usize = 0;
    while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) : (tries1 += 1) {
        if (tries1 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    const head_end = std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n").? + 4;
    const head = cr.interface.buffered()[0..head_end];
    try testing.expect(std.mem.indexOf(u8, head, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    cr.interface.toss(head_end);

    // 2. Send a masked text frame "hi" (zero mask key -> payload bytes unchanged).
    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    cw.interface.writeAll(&text_frame) catch unreachable;
    cw.interface.flush() catch unreachable;

    // 3. Read the echoed unmasked server frame: 0x81, 0x02, 'h', 'i'.
    var tries2: usize = 0;
    while (cr.interface.buffered().len < 4) : (tries2 += 1) {
        if (tries2 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, cr.interface.buffered()[0..4]);
    cr.interface.toss(4);

    // 4. Send a masked close frame; the server ends the loop and closes the socket.
    const close_frame = [_]u8{ 0x88, 0x80, 0x00, 0x00, 0x00, 0x00 };
    cw.interface.writeAll(&close_frame) catch unreachable;
    cw.interface.flush() catch unreachable;
    // The server replies with an (empty) close frame before closing.
    var triesC: usize = 0;
    while (cr.interface.buffered().len < 2) : (triesC += 1) {
        if (triesC > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch break;
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x00 }, cr.interface.buffered()[0..2]);
    cr.interface.toss(2);
    // Then the server closes -> EOF.
    const eof = blk: {
        cr.interface.fillMore() catch break :blk true;
        break :blk cr.interface.buffered().len == 0;
    };
    try testing.expect(eof);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "end-to-end: websocket fragmentation, ping, and close (threaded)" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18100;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    // 1. Send the handshake and assert 101 + accept value.
    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    cw.interface.writeAll(upgrade_req) catch unreachable;
    cw.interface.flush() catch unreachable;
    var tries1: usize = 0;
    while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) : (tries1 += 1) {
        if (tries1 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    const head_end = std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n").? + 4;
    const head = cr.interface.buffered()[0..head_end];
    try testing.expect(std.mem.indexOf(u8, head, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    cr.interface.toss(head_end);

    // 2. Fragmented message: text fin=0 "Hel" + continuation fin=1 "lo" -> echoed whole "Hello".
    const frag1 = [_]u8{ 0x01, 0x83, 0x00, 0x00, 0x00, 0x00, 'H', 'e', 'l' }; // opcode text(0x1), fin=0
    const frag2 = [_]u8{ 0x80, 0x82, 0x00, 0x00, 0x00, 0x00, 'l', 'o' };       // opcode continuation(0x0), fin=1
    cw.interface.writeAll(&frag1) catch unreachable;
    cw.interface.writeAll(&frag2) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t1: usize = 0;
    while (cr.interface.buffered().len < 7) : (t1 += 1) {
        if (t1 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    // server echoes the whole message as one text frame: 0x81, 0x05, "Hello"
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' }, cr.interface.buffered()[0..7]);
    cr.interface.toss(7);

    // 3. Ping -> pong. masked ping (0x89) "pq" -> server sends pong (0x8A) "pq".
    const ping = [_]u8{ 0x89, 0x82, 0x00, 0x00, 0x00, 0x00, 'p', 'q' };
    cw.interface.writeAll(&ping) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t2: usize = 0;
    while (cr.interface.buffered().len < 4) : (t2 += 1) {
        if (t2 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 0x02, 'p', 'q' }, cr.interface.buffered()[0..4]);
    cr.interface.toss(4);

    // 4. Close -> close-reply then EOF. masked close (0x88) with code 1000.
    const close = [_]u8{ 0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8 };
    cw.interface.writeAll(&close) catch unreachable;
    cw.interface.flush() catch unreachable;
    var t3: usize = 0;
    while (cr.interface.buffered().len < 4) : (t3 += 1) {
        if (t3 > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }
    // server echoes a close frame (0x88) with the same code, then closes.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xE8 }, cr.interface.buffered()[0..4]);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "observe: upgrade request is recorded with status 101" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    var cap = ObsCapture{};
    try app.observe(.{ .context = &cap, .func = obsCapture });

    const port: u16 = 18098;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);

    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    cw.interface.writeAll(upgrade_req) catch unreachable;
    cw.interface.flush() catch unreachable;

    // Wait for 101 response head.
    var tries: usize = 0;
    while (std.mem.indexOf(u8, cr.interface.buffered(), "\r\n\r\n") == null) : (tries += 1) {
        if (tries > 1000) return error.TestTimeout;
        cr.interface.fillMore() catch unreachable;
    }

    // Send a close frame to end the WS session cleanly.
    const close_frame = [_]u8{ 0x88, 0x80, 0x00, 0x00, 0x00, 0x00 };
    cw.interface.writeAll(&close_frame) catch unreachable;
    cw.interface.flush() catch unreachable;
    // Drain until EOF so the server has finished the handler before we check.
    while (true) cr.interface.fillMore() catch break;

    app.requestShutdown(io);
    loop_fut.await(io);

    // Observer must have recorded the upgrade as status 101.
    try testing.expectEqual(@as(u16, 101), cap.status);
    try testing.expect(cap.count >= 1);
}

test "end-to-end (evented): websocket upgrade, handshake, and echo" {
    if (!evented_supported) return error.SkipZigTest;

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18099;
    const addr = net.IpAddress{ .ip4 = .loopback(port) };

    const ServeCtx = struct {
        app: *TestApp,
        io: Io,
        addr: net.IpAddress,
        err: ?anyerror = null,
    };
    var serve_ctx = ServeCtx{ .app = &app, .io = undefined, .addr = addr };
    var srv_threaded = Io.Threaded.init(testing.allocator, .{});
    defer srv_threaded.deinit();
    serve_ctx.io = srv_threaded.io();

    const ServeThread = struct {
        fn run(ctx: *ServeCtx) void {
            ctx.app.serveEvented(ctx.io, ctx.addr, .{ .workers = 1 }) catch |e| {
                ctx.err = e;
            };
        }
    };
    const srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{&serve_ctx});

    sevWaitListening(port, 50);

    const cfd = try sevSocket();
    defer sevCloseFd(cfd);
    try testing.expect(sevConnect(cfd, port));

    // 1. Send the WebSocket upgrade request.
    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try sevWrite(cfd, upgrade_req);

    // 2. Read the 101 response head.
    var head_buf: [1024]u8 = undefined;
    var head_total: usize = 0;
    var head_tries: usize = 0;
    while (std.mem.indexOf(u8, head_buf[0..head_total], "\r\n\r\n") == null) : (head_tries += 1) {
        if (head_tries > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), head_buf[head_total..].ptr, head_buf.len - head_total))
        else
            std.c.read(cfd, head_buf[head_total..].ptr, head_buf.len - head_total);
        if (n <= 0) return error.UnexpectedEof;
        head_total += @intCast(n);
    }
    const head_end = std.mem.indexOf(u8, head_buf[0..head_total], "\r\n\r\n").? + 4;
    try testing.expect(std.mem.indexOf(u8, head_buf[0..head_end], "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, head_buf[0..head_end], "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // 3. Send a masked text frame "hi" (zero mask key → payload bytes unchanged).
    const text_frame = [_]u8{ 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i' };
    try sevWrite(cfd, &text_frame);

    // 4. Read the echoed unmasked server frame: 0x81, 0x02, 'h', 'i'.
    var echo_buf: [64]u8 = undefined;
    var echo_total: usize = 0;
    var echo_tries: usize = 0;
    while (echo_total < 4) : (echo_tries += 1) {
        if (echo_tries > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), echo_buf[echo_total..].ptr, echo_buf.len - echo_total))
        else
            std.c.read(cfd, echo_buf[echo_total..].ptr, echo_buf.len - echo_total);
        if (n <= 0) return error.UnexpectedEof;
        echo_total += @intCast(n);
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, echo_buf[0..4]);

    // 5. Shutdown.
    var shutdown_threaded = Io.Threaded.init(testing.allocator, .{});
    defer shutdown_threaded.deinit();
    app.requestShutdown(shutdown_threaded.io());
    srv_thread.join();
    try testing.expect(serve_ctx.err == null);
}

test "end-to-end (evented): websocket fragmentation, ping, and close" {
    if (!evented_supported) return error.SkipZigTest;

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ws", wsEchoHandler);

    const port: u16 = 18101;
    const addr = net.IpAddress{ .ip4 = .loopback(port) };

    const ServeCtx = struct {
        app: *TestApp,
        io: Io,
        addr: net.IpAddress,
        err: ?anyerror = null,
    };
    var serve_ctx = ServeCtx{ .app = &app, .io = undefined, .addr = addr };
    var srv_threaded = Io.Threaded.init(testing.allocator, .{});
    defer srv_threaded.deinit();
    serve_ctx.io = srv_threaded.io();

    const ServeThread = struct {
        fn run(ctx: *ServeCtx) void {
            ctx.app.serveEvented(ctx.io, ctx.addr, .{ .workers = 1 }) catch |e| {
                ctx.err = e;
            };
        }
    };
    const srv_thread = try std.Thread.spawn(.{}, ServeThread.run, .{&serve_ctx});

    sevWaitListening(port, 50);

    const cfd = try sevSocket();
    defer sevCloseFd(cfd);
    try testing.expect(sevConnect(cfd, port));

    // 1. Send the WebSocket upgrade request.
    const upgrade_req =
        "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try sevWrite(cfd, upgrade_req);

    // 2. Read the 101 response head.
    var head_buf: [1024]u8 = undefined;
    var head_total: usize = 0;
    var head_tries: usize = 0;
    while (std.mem.indexOf(u8, head_buf[0..head_total], "\r\n\r\n") == null) : (head_tries += 1) {
        if (head_tries > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), head_buf[head_total..].ptr, head_buf.len - head_total))
        else
            std.c.read(cfd, head_buf[head_total..].ptr, head_buf.len - head_total);
        if (n <= 0) return error.UnexpectedEof;
        head_total += @intCast(n);
    }
    const head_end = std.mem.indexOf(u8, head_buf[0..head_total], "\r\n\r\n").? + 4;
    try testing.expect(std.mem.indexOf(u8, head_buf[0..head_end], "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, head_buf[0..head_end], "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // 3. Fragmented message: text fin=0 "Hel" + continuation fin=1 "lo" -> echoed whole "Hello".
    const frag1 = [_]u8{ 0x01, 0x83, 0x00, 0x00, 0x00, 0x00, 'H', 'e', 'l' }; // opcode text(0x1), fin=0
    const frag2 = [_]u8{ 0x80, 0x82, 0x00, 0x00, 0x00, 0x00, 'l', 'o' };       // opcode continuation(0x0), fin=1
    try sevWrite(cfd, &frag1);
    try sevWrite(cfd, &frag2);
    var frag_buf: [64]u8 = undefined;
    var frag_total: usize = 0;
    var t1: usize = 0;
    while (frag_total < 7) : (t1 += 1) {
        if (t1 > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), frag_buf[frag_total..].ptr, frag_buf.len - frag_total))
        else
            std.c.read(cfd, frag_buf[frag_total..].ptr, frag_buf.len - frag_total);
        if (n <= 0) return error.UnexpectedEof;
        frag_total += @intCast(n);
    }
    // server echoes the whole message as one text frame: 0x81, 0x05, "Hello"
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' }, frag_buf[0..7]);

    // 4. Ping -> pong. masked ping (0x89) "pq" -> server sends pong (0x8A) "pq".
    const ping = [_]u8{ 0x89, 0x82, 0x00, 0x00, 0x00, 0x00, 'p', 'q' };
    try sevWrite(cfd, &ping);
    var pong_buf: [64]u8 = undefined;
    var pong_total: usize = 0;
    var t2: usize = 0;
    while (pong_total < 4) : (t2 += 1) {
        if (t2 > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), pong_buf[pong_total..].ptr, pong_buf.len - pong_total))
        else
            std.c.read(cfd, pong_buf[pong_total..].ptr, pong_buf.len - pong_total);
        if (n <= 0) return error.UnexpectedEof;
        pong_total += @intCast(n);
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 0x02, 'p', 'q' }, pong_buf[0..4]);

    // 5. Close -> close-reply then EOF. masked close (0x88) with code 1000.
    const close = [_]u8{ 0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8 };
    try sevWrite(cfd, &close);
    var close_buf: [64]u8 = undefined;
    var close_total: usize = 0;
    var t3: usize = 0;
    while (close_total < 4) : (t3 += 1) {
        if (t3 > 1000) return error.TestTimeout;
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(std.os.linux.read(@intCast(cfd), close_buf[close_total..].ptr, close_buf.len - close_total))
        else
            std.c.read(cfd, close_buf[close_total..].ptr, close_buf.len - close_total);
        if (n <= 0) return error.UnexpectedEof;
        close_total += @intCast(n);
    }
    // server echoes a close frame (0x88) with the same code, then closes.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x02, 0x03, 0xE8 }, close_buf[0..4]);

    // 6. Shutdown.
    var shutdown_threaded = Io.Threaded.init(testing.allocator, .{});
    defer shutdown_threaded.deinit();
    app.requestShutdown(shutdown_threaded.io());
    srv_thread.join();
    try testing.expect(serve_ctx.err == null);
}
