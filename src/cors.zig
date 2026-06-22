//! CORS middleware (built-in). `cors(Ctx, config)` returns a `Chain(Ctx)`
//! middleware that answers `OPTIONS` preflight with 204 and decorates actual
//! responses with `Access-Control-*` headers. Config is comptime. Header names
//! are lowercase (framework convention). The cookie value / origins are emitted
//! as configured (caller-controlled, not request input) except the reflected
//! request Origin, which is matched exactly against the allowlist.

const std = @import("std");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

pub const Cors = struct {
    pub const Origins = union(enum) {
        any,
        list: []const []const u8,
    };
    origins: Origins = .any,
    methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS",
    allow_headers: []const u8 = "Content-Type",
    expose_headers: ?[]const u8 = null,
    credentials: bool = false,
    max_age: ?u32 = null,
};

pub fn cors(comptime Ctx: type, comptime config: Cors) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            const origin = ctx.req.header("origin");
            const allow = resolveAllowOrigin(config, origin);

            const is_preflight = ctx.req.method == .OPTIONS and
                ctx.req.header("access-control-request-method") != null;

            if (is_preflight) {
                return decorate(ctx.arena, Response.fromStatus(.no_content), config, allow, true);
            }
            const r = try next.run();
            return decorate(ctx.arena, r, config, allow, false);
        }
    };
    return Impl.mw;
}

/// The value for `Access-Control-Allow-Origin`, or null when no CORS headers
/// should be emitted (no Origin, or allowlist miss).
fn resolveAllowOrigin(comptime config: Cors, origin: ?[]const u8) ?[]const u8 {
    const o = origin orelse return null;
    switch (config.origins) {
        .any => return if (config.credentials) o else "*",
        .list => |allowed| {
            for (allowed) |entry| if (std.mem.eql(u8, entry, o)) return o;
            return null;
        },
    }
}

/// Append the CORS headers to `r`. Returns `r` unchanged when `allow` is null.
fn decorate(arena: std.mem.Allocator, r0: Response, comptime config: Cors, allow: ?[]const u8, preflight: bool) !Response {
    const a = allow orelse return r0;
    var r = try r0.withHeader(arena, "access-control-allow-origin", a);
    if (!std.mem.eql(u8, a, "*")) r = try r.withHeader(arena, "vary", "origin");
    if (config.credentials) r = try r.withHeader(arena, "access-control-allow-credentials", "true");
    if (preflight) {
        r = try r.withHeader(arena, "access-control-allow-methods", config.methods);
        r = try r.withHeader(arena, "access-control-allow-headers", config.allow_headers);
        if (config.max_age) |ma| {
            const ns = try std.fmt.allocPrint(arena, "{d}", .{ma});
            r = try r.withHeader(arena, "access-control-max-age", ns);
        }
    } else if (config.expose_headers) |eh| {
        r = try r.withHeader(arena, "access-control-expose-headers", eh);
    }
    return r;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("http/request.zig").Request;
const Header = @import("http/request.zig").Header;
const Method = @import("http/request.zig").Method;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
    ran: *bool,
};

fn fakeReq(method: Method, headers: []const Header) Request {
    return .{ .method = method, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

fn okHandler(ctx: *const TestCtx) anyerror!Response {
    ctx.ran.* = true;
    return Response.text("ok");
}

/// First value of header `name` on `r`, or null.
fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Run `config`'s cors middleware over a request and return the response.
fn runCors(arena: std.mem.Allocator, comptime config: Cors, req: *const Request, ran: *bool) !Response {
    const C = middleware.Chain(TestCtx);
    var ctx = TestCtx{ .req = req, .arena = arena, .ran = ran };
    const mws = [_]C.Middleware{cors(TestCtx, config)};
    return C.run(&mws, &okHandler, &ctx);
}

test "cors any: GET with Origin gets wildcard, no vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any }, &req, &ran);
    try testing.expect(ran);
    try testing.expectEqualStrings("*", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "vary"));
}

test "cors list match: reflects origin + vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .{ .list = &.{"https://a.com"} } }, &req, &ran);
    try testing.expectEqualStrings("https://a.com", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqualStrings("origin", hdr(r, "vary").?);
}

test "cors list miss: no CORS headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://evil.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .{ .list = &.{"https://a.com"} } }, &req, &ran);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-origin"));
}

test "cors credentials + any: reflects concrete origin, not star" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any, .credentials = true }, &req, &ran);
    try testing.expectEqualStrings("https://a.com", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqualStrings("true", hdr(r, "access-control-allow-credentials").?);
    try testing.expectEqualStrings("origin", hdr(r, "vary").?);
}

test "cors preflight: 204 + allow-methods/headers, handler not called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.OPTIONS, &.{
        .{ .name = "Origin", .value = "https://a.com" },
        .{ .name = "Access-Control-Request-Method", .value = "GET" },
    });
    const r = try runCors(arena.allocator(), .{ .origins = .any, .max_age = 600 }, &req, &ran);
    try testing.expect(!ran);
    try testing.expectEqual(@import("http/response.zig").Status.no_content, r.status);
    try testing.expectEqualStrings("*", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqualStrings("GET, POST, PUT, DELETE, OPTIONS", hdr(r, "access-control-allow-methods").?);
    try testing.expectEqualStrings("Content-Type", hdr(r, "access-control-allow-headers").?);
    try testing.expectEqualStrings("600", hdr(r, "access-control-max-age").?);
}

test "cors preflight: list miss origin → 204, no access-control-* headers, handler not called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.OPTIONS, &.{
        .{ .name = "Origin", .value = "https://evil.com" },
        .{ .name = "Access-Control-Request-Method", .value = "GET" },
    });
    const r = try runCors(arena.allocator(), .{ .origins = .{ .list = &.{"https://a.com"} } }, &req, &ran);
    try testing.expect(!ran);
    try testing.expectEqual(@import("http/response.zig").Status.no_content, r.status);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-origin"));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-methods"));
}

test "cors: no Origin passes through with no CORS headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{});
    const r = try runCors(arena.allocator(), .{ .origins = .any }, &req, &ran);
    try testing.expect(ran);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-origin"));
}

test "cors expose_headers on actual response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any, .expose_headers = "X-Total" }, &req, &ran);
    try testing.expectEqualStrings("X-Total", hdr(r, "access-control-expose-headers").?);
}
