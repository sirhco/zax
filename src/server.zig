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

/// Maximum path parameters captured per request (compile-time, sizes the
/// stack capture buffer).
pub const max_params = 16;

pub const Options = struct {
    read_buffer_size: usize = 16 * 1024,
    write_buffer_size: usize = 8 * 1024,
};

/// `App(AppState)` — a server bound to one concrete, read-only app-state type.
pub fn App(comptime AppState: type) type {
    return struct {
        const Self = @This();
        const Ctx = extract.Context(AppState);
        /// Type-erased handler: every typed handler is wrapped into this single
        /// shape so the router can store them uniformly.
        const ErasedHandler = *const fn (ctx: *const Ctx) anyerror!Response;
        const R = router.Router(ErasedHandler);

        gpa: std.mem.Allocator,
        state: AppState,
        router: R,
        opts: Options,
        server: ?net.Server = null,
        shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(gpa: std.mem.Allocator, state: AppState, opts: Options) std.mem.Allocator.Error!Self {
            return .{ .gpa = gpa, .state = state, .router = try R.init(gpa), .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
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

        fn handleConn(self: *Self, io: Io, stream_in: net.Stream) void {
            var stream = stream_in;
            defer stream.close(io);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            const read_buf = arena.allocator().alloc(u8, self.opts.read_buffer_size) catch return;
            const write_buf = arena.allocator().alloc(u8, self.opts.write_buffer_size) catch return;

            var sr = stream.reader(io, read_buf);
            var sw = stream.writer(io, write_buf);

            const resp = self.handleOne(io, &sr.interface, &arena);
            resp.write(&sw.interface) catch return;
            sw.interface.flush() catch return;
        }

        /// Read one request, route it, run the handler, and return a Response.
        /// Every failure path maps to an HTTP status rather than propagating.
        fn handleOne(self: *Self, io: Io, r: *Io.Reader, arena: *std.heap.ArenaAllocator) Response {
            _ = io;
            var hs: [request.max_headers]Header = undefined;
            const parsed = readRequest(r, &hs) catch return Response.fromStatus(.bad_request);

            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(parsed.request.method, parsed.request.path, &params_buf) catch
                return Response.fromStatus(.bad_request);

            switch (outcome) {
                .not_found => return Response.fromStatus(.not_found),
                .method_not_allowed => return Response.fromStatus(.method_not_allowed),
                .found => |f| {
                    const ctx = Ctx{
                        .req = &parsed.request,
                        .params = f.params,
                        .state = self.state,
                        .arena = arena.allocator(),
                    };
                    return f.handler(&ctx) catch Response.fromStatus(.internal_server_error);
                },
            }
        }
    };
}

const ReadError = error{ HeadTooLarge, IncompleteRequest };

/// Fill the reader until the full request head (and body, per Content-Length) is
/// buffered, then return a `Parsed` whose slices point into the reader buffer.
fn readRequest(r: *Io.Reader, hs: *[request.max_headers]Header) ReadError!parser.Parsed {
    var parsed: parser.Parsed = while (true) {
        if (parser.parseHead(r.buffered(), hs)) |p| {
            break p;
        } else |err| switch (err) {
            error.Incomplete => {},
            else => return error.IncompleteRequest,
        }
        // Need more bytes for the head.
        r.fillMore() catch return error.IncompleteRequest;
        if (r.buffered().len == r.buffer.len) return error.HeadTooLarge;
    };

    if (parsed.request.contentLength()) |clen| {
        while (r.buffered().len < parsed.head_len + clen) {
            r.fillMore() catch return error.IncompleteRequest;
        }
        parsed.request.body = r.buffered()[parsed.head_len .. parsed.head_len + clen];
    }
    return parsed;
}

// ----------------------------------------------------------------------------
// Tests  (real Io.Threaded, loopback sockets)
// ----------------------------------------------------------------------------
const testing = std.testing;
const Path = @import("extract/path.zig").Path;
const State = @import("extract/state.zig").State;

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

fn readAll(io: Io, stream: *net.Stream, buf: []u8) []const u8 {
    var cr = stream.reader(io, buf);
    const r = &cr.interface;
    var total: usize = 0;
    while (true) {
        const n = r.readSliceShort(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn doRequest(io: Io, port: u16, raw: []const u8, resp_buf: []u8) []const u8 {
    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll(raw) catch unreachable;
    cw.interface.flush() catch unreachable;
    return readAll(io, &cs, resp_buf);
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
