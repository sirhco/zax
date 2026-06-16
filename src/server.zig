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
const Io = std.Io;
const net = std.Io.net;

const request = @import("http/request.zig");
const Header = request.Header;
const response = @import("http/response.zig");
const Response = response.Response;
const parser = @import("http/parser.zig");
const router = @import("router/router.zig");
const radix = @import("router/radix.zig");
const Param = radix.Param;
const extract = @import("extract/extract.zig");
const middleware = @import("middleware.zig");
const err_mod = @import("error.zig");

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
        fallback_handler: ?ErasedHandler = null,
        on_error: ?ErrorHandler = null,
        server: ?net.Server = null,
        shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(gpa: std.mem.Allocator, state: AppState, opts: Options) std.mem.Allocator.Error!Self {
            return .{ .gpa = gpa, .state = state, .router = try R.init(gpa), .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            self.mws.deinit(self.gpa);
            self.router.deinit();
        }

        /// Append a middleware to the global chain. Middleware run in
        /// registration order, wrapping the matched route handler (after
        /// routing, so 404/405 short-circuit before the chain).
        pub fn use(self: *Self, mw: Chn.Middleware) std.mem.Allocator.Error!void {
            try self.mws.append(self.gpa, mw);
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
            var group: Io.Group = .init;
            while (!self.shutting_down.load(.acquire)) {
                const srv = if (self.server) |*s| s else break;
                const stream = srv.accept(io) catch break;
                group.async(io, handleConn, .{ self, io, stream });
            }
            group.await(io) catch {};
        }

        /// Convenience: bind then run the accept loop on the current task.
        pub fn serve(self: *Self, io: Io, addr: net.IpAddress) !void {
            try self.bind(io, addr);
            self.acceptLoop(io);
        }

        /// Request a graceful shutdown: stop accepting (by closing the listening
        /// socket, which unblocks `accept`) so `acceptLoop` exits and drains.
        /// Safe to call from another task. A SIGINT/SIGTERM handler would simply
        /// call this.
        pub fn requestShutdown(self: *Self, io: Io) void {
            self.shutting_down.store(true, .release);
            if (self.server) |*s| s.socket.close(io);
        }

        /// Serve a connection: a keep-alive loop of request/response cycles over
        /// one stream. Read/write buffers and the request arena persist for the
        /// whole connection; the arena is reset (capacity retained) each request.
        fn handleConn(self: *Self, io: Io, stream_in: net.Stream) void {
            var stream = stream_in;
            defer stream.close(io);

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

                var hs: [request.max_headers]Header = undefined;
                var parsed = readHead(&cr, &hs, read_to, idle_to) catch |e| {
                    terminalResponse(w, e);
                    break;
                };

                // Chunked request bodies are unsupported: reject and close.
                if (parsed.request.isChunked()) {
                    _ = writeResponse(w, Response.fromStatus(.length_required));
                    break;
                }

                readBody(&cr, &parsed, self.opts.max_body_size, read_to) catch |e| {
                    terminalResponse(w, e);
                    break;
                };
                const consumed = parsed.head_len + parsed.request.body.len;

                const persistent = self.opts.keep_alive and
                    parsed.request.isPersistent() and
                    (served + 1) < self.opts.max_keep_alive_requests;

                var resp = self.dispatch(io, &parsed.request, &arena);
                const streamed = resp.streamer != null;
                resp.keep_alive = persistent and !streamed;
                if (!writeResponse(w, resp)) break;
                if (streamed) break; // connection-close framing: close after a stream

                cr.consume(consumed);
                served += 1;
                if (!persistent) break;
            }
        }

        /// Route one already-read request and run its handler. Every failure
        /// path maps to an HTTP status rather than propagating.
        fn makeCtx(self: *Self, io: Io, req: *const request.Request, params: []const Param, arena: *std.heap.ArenaAllocator) Ctx {
            return .{
                .req = req,
                .params = params,
                .state = self.state,
                .arena = arena.allocator(),
                .io = io,
                .trust_forwarded = self.opts.trust_forwarded,
            };
        }

        /// Classify an error and render it, using the app's on_error hook if set.
        fn renderError(self: *Self, e: anyerror, ctx: *const Ctx) Response {
            const info = err_mod.classify(e);
            if (self.on_error) |h| return h(e, info, ctx);
            return .{ .status = info.status, .body = info.reason };
        }

        fn dispatch(self: *Self, io: Io, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch {
                const ctx = self.makeCtx(io, req, &.{}, arena);
                return self.renderError(err_mod.Error.BadRequest, &ctx);
            };

            switch (outcome) {
                .not_found => {
                    const ctx = self.makeCtx(io, req, &.{}, arena);
                    if (self.fallback_handler) |fb|
                        return Chn.run(self.mws.items, fb, &ctx) catch |e| self.renderError(e, &ctx);
                    return self.renderError(err_mod.Error.NotFound, &ctx);
                },
                .method_not_allowed => |allowed| {
                    const ctx = self.makeCtx(io, req, &.{}, arena);
                    var resp = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
                    resp = resp.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch resp;
                    return resp;
                },
                .found => |f| {
                    const ctx = self.makeCtx(io, req, f.params, arena);
                    return Chn.run(self.mws.items, f.handler, &ctx) catch |e| self.renderError(e, &ctx);
                },
            }
        }
    };
}

/// Write and flush a response; returns false on a write error (caller closes).
fn writeResponse(w: *Io.Writer, resp: Response) bool {
    if (resp.streamer) |s| {
        resp.writeHead(w) catch return false;
        s.func(s.context, w) catch return false;
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
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

/// Validate Content-Length against the effective limit, then fill until the body
/// is buffered and attach it as a zero-copy slice.
fn readBody(cr: *ConnReader, parsed: *parser.Parsed, max_body: usize, read_to: Io.Timeout) RequestError!void {
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
}

/// Send the terminal response for a RequestError (or nothing for Closed).
fn terminalResponse(w: *Io.Writer, e: RequestError) void {
    switch (e) {
        error.HeaderFieldsTooLarge => _ = writeResponse(w, Response.fromStatus(.request_header_fields_too_large)),
        error.BodyTooLarge => _ = writeResponse(w, Response.fromStatus(.payload_too_large)),
        error.Timeout => _ = writeResponse(w, Response.fromStatus(.request_timeout)),
        error.Malformed => _ = writeResponse(w, Response.fromStatus(.bad_request)),
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

test "keep-alive: chunked request body is rejected with 411" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/ping", pingHandler);

    const port: u16 = 18093;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const resp = doRequest(io, port, "POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, resp, "411 Length Required") != null);

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

    const resp = app.dispatch(undefined, &parsed.request, &arena);
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

    const resp = app.dispatch(undefined, &parsed.request, &arena);
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
    cw.interface.writeAll("GET /stream HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
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
    cw.interface.writeAll("GET /events HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
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
