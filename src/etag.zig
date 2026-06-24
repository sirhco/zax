//! ETag middleware: Wyhash ETag + If-None-Match → 304.
//! Mirrors compress.zig structure.

const std = @import("std");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;
const Header = @import("http/request.zig").Header;

/// ETag middleware configuration.
pub const Etag = struct {
    /// When true, emit `W/"<hash>"` (weak validator) instead of `"<hash>"`.
    weak: bool = false,
};

/// Compute a quoted ETag string for `body` using Wyhash.
/// Strong: `"<16hex>"` (18 chars). Weak: `W/"<16hex>"` (21 chars).
fn formatTag(arena: std.mem.Allocator, weak: bool, body: []const u8) ![]const u8 {
    const h: u64 = std.hash.Wyhash.hash(0, body);
    return if (weak)
        std.fmt.allocPrint(arena, "W/\"{x:0>16}\"", .{h})
    else
        std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{h});
}

/// Return the opaque tag portion of a raw ETag value:
/// trim whitespace, strip a leading `W/` prefix and trim again.
fn opaque_tag(raw: []const u8) []const u8 {
    var t = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, t, "W/")) t = std.mem.trim(u8, t[2..], " \t");
    return t;
}

/// RFC 7232 weak ETag comparison against an If-None-Match header value.
/// Returns true if `our_tag` matches any entry in the comma-separated list,
/// or if the list is `*`.
fn matches(if_none_match: []const u8, our_tag: []const u8) bool {
    const h = std.mem.trim(u8, if_none_match, " \t");
    if (std.mem.eql(u8, h, "*")) return true;
    const want = opaque_tag(our_tag);
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok| {
        const cand = std.mem.trim(u8, tok, " \t");
        if (cand.len == 0) continue;
        if (std.mem.eql(u8, opaque_tag(cand), want)) return true;
    }
    return false;
}

/// Case-insensitive scan of response headers; returns the first matching value.
fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// ETag middleware factory. Returns a `Chain(Ctx).Middleware` that:
///   - skips streamed / upgrade / non-GET-HEAD / non-200 responses
///   - computes (or reuses handler-set) ETag and adds it to the response
///   - returns 304 Not Modified when If-None-Match matches, preserving
///     cache-control and vary headers from the original response.
pub fn etag(comptime Ctx: type, comptime config: Etag) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            var r = try next.run();
            if (r.streamer != null or r.pull_streamer != null) return r;
            if (r.upgrade != null) return r;
            if (ctx.req.method != .GET and ctx.req.method != .HEAD) return r;
            if (r.status != .ok) return r;
            const tag = hdr(r, "etag") orelse blk: {
                const t = try formatTag(ctx.arena, config.weak, r.body);
                r = try r.withHeader(ctx.arena, "etag", t);
                break :blk t;
            };
            if (ctx.req.header("if-none-match")) |inm| {
                if (matches(inm, tag)) {
                    var nm = Response.fromStatus(.not_modified);
                    nm.keep_alive = r.keep_alive;
                    nm = try nm.withHeader(ctx.arena, "etag", tag);
                    if (hdr(r, "cache-control")) |v| nm = try nm.withHeader(ctx.arena, "cache-control", v);
                    if (hdr(r, "vary")) |v| nm = try nm.withHeader(ctx.arena, "vary", v);
                    return nm;
                }
            }
            return r;
        }
    };
    return Impl.mw;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "matches: exact strong match" {
    try testing.expect(matches("\"abc\"", "\"abc\""));
    try testing.expect(!matches("\"abc\"", "\"abd\""));
}

test "matches: wildcard * matches anything" {
    try testing.expect(matches("*", "\"abc\""));
    try testing.expect(matches("*", "W/\"xyz\""));
}

test "matches: weak comparison cross-type" {
    // weak header vs strong tag
    try testing.expect(matches("W/\"abc\"", "\"abc\""));
    // strong header vs weak tag
    try testing.expect(matches("\"abc\"", "W/\"abc\""));
}

test "matches: comma list with whitespace and trailing comma" {
    // hit via weak entry in list
    try testing.expect(matches(" \"x\" , W/\"abc\" , ", "\"abc\""));
    // miss
    try testing.expect(!matches("\"x\", \"y\"", "\"abc\""));
}

test "formatTag: strong and weak properties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = "hello world";
    const strong = try formatTag(alloc, false, body);
    const weak = try formatTag(alloc, true, body);

    // strong: exactly 18 chars, starts and ends with "
    try testing.expectEqual(@as(usize, 18), strong.len);
    try testing.expectEqual('"', strong[0]);
    try testing.expectEqual('"', strong[strong.len - 1]);

    // weak: starts with W/"
    try testing.expect(std.mem.startsWith(u8, weak, "W/\""));

    // same opaque tag (same 16-hex body)
    try testing.expectEqualStrings(opaque_tag(strong), opaque_tag(weak));
}

// ---------------------------------------------------------------------------
// Middleware tests
// ---------------------------------------------------------------------------

const Request = @import("http/request.zig").Request;
const Method = @import("http/request.zig").Method;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
};

fn fakeReq(method: Method, headers: []const Header) Request {
    return .{ .method = method, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

/// Run `config`'s etag middleware over a request, with a handler that returns `resp`.
fn runEtag(arena: std.mem.Allocator, comptime config: Etag, req: *const Request, resp: Response) !Response {
    const C = middleware.Chain(TestCtx);
    const H = struct {
        var out: Response = undefined;
        fn handler(_: *const TestCtx) anyerror!Response {
            return out;
        }
    };
    H.out = resp;
    var ctx = TestCtx{ .req = req, .arena = arena };
    const mws = [_]C.Middleware{etag(TestCtx, config)};
    return C.run(&mws, &H.handler, &ctx);
}

test "etag: 200 GET sets strong etag (18 chars)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.text("hello"));
    const tag = hdr(r, "etag") orelse return error.MissingEtag;
    try testing.expectEqual(@as(u16, 200), @intFromEnum(r.status));
    try testing.expectEqual(@as(usize, 18), tag.len);
    try testing.expectEqual('"', tag[0]);
    try testing.expectEqual('"', tag[tag.len - 1]);
}

test "etag: INM match → 304 + same etag + empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // First: learn the tag from a plain GET
    const req1 = fakeReq(.GET, &.{});
    const r1 = try runEtag(a, .{}, &req1, Response.text("hello"));
    const tag = hdr(r1, "etag") orelse return error.MissingEtag;

    // Second: send If-None-Match with matching tag
    const req2 = fakeReq(.GET, &.{.{ .name = "if-none-match", .value = tag }});
    const r2 = try runEtag(a, .{}, &req2, Response.text("hello"));
    try testing.expectEqual(@as(u16, 304), @intFromEnum(r2.status));
    try testing.expectEqualStrings("", r2.body);
    try testing.expectEqualStrings(tag, hdr(r2, "etag").?);
}

test "etag: INM mismatch → 200" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{.{ .name = "if-none-match", .value = "\"0000000000000000\"" }});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.text("hello"));
    try testing.expectEqual(@as(u16, 200), @intFromEnum(r.status));
}

test "etag: weak config emits W/\" and 304s on match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req1 = fakeReq(.GET, &.{});
    const r1 = try runEtag(a, .{ .weak = true }, &req1, Response.text("hello"));
    const tag = hdr(r1, "etag") orelse return error.MissingEtag;
    try testing.expect(std.mem.startsWith(u8, tag, "W/\""));

    const req2 = fakeReq(.GET, &.{.{ .name = "if-none-match", .value = tag }});
    const r2 = try runEtag(a, .{ .weak = true }, &req2, Response.text("hello"));
    try testing.expectEqual(@as(u16, 304), @intFromEnum(r2.status));
}

test "etag: HEAD sets etag like GET" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.HEAD, &.{});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.text("hello"));
    try testing.expect(hdr(r, "etag") != null);
    try testing.expectEqual(@as(u16, 200), @intFromEnum(r.status));
}

test "etag: POST with If-None-Match:* → 200, no etag header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.POST, &.{.{ .name = "if-none-match", .value = "*" }});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.text("hello"));
    try testing.expectEqual(@as(u16, 200), @intFromEnum(r.status));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "etag"));
}

test "etag: non-200 response → no etag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.fromStatus(.not_found));
    try testing.expectEqual(@as(u16, 404), @intFromEnum(r.status));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "etag"));
}

test "etag: handler-set etag respected, used for comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Handler pre-set etag "custom"
    const resp = try Response.text("x").withHeader(a, "etag", "\"custom\"");
    // INM matching the custom tag
    const req = fakeReq(.GET, &.{.{ .name = "if-none-match", .value = "\"custom\"" }});
    const r = try runEtag(a, .{}, &req, resp);
    try testing.expectEqual(@as(u16, 304), @intFromEnum(r.status));
    try testing.expectEqualStrings("\"custom\"", hdr(r, "etag").?);
}

test "etag: streamed response untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{});
    const Streamed = struct {
        fn run(_: *const u8, w: *std.Io.Writer) anyerror!void {
            try w.writeAll("hello");
        }
    };
    const dummy: u8 = 0;
    const resp = Response.stream(u8, &dummy, Streamed.run, "text/plain");
    const r = try runEtag(arena.allocator(), .{}, &req, resp);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "etag"));
    try testing.expect(r.streamer != null);
}

test "etag: 304 preserves cache-control and vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Build a 200 with cache-control + vary
    const resp200 = try (try Response.text("hello")
        .withHeader(a, "cache-control", "max-age=3600"))
        .withHeader(a, "vary", "accept-encoding");
    // Learn the tag
    const req1 = fakeReq(.GET, &.{});
    const r1 = try runEtag(a, .{}, &req1, resp200);
    const tag = hdr(r1, "etag") orelse return error.MissingEtag;

    // Now echo it → 304
    const resp200b = try (try Response.text("hello")
        .withHeader(a, "cache-control", "max-age=3600"))
        .withHeader(a, "vary", "accept-encoding");
    const req2 = fakeReq(.GET, &.{.{ .name = "if-none-match", .value = tag }});
    const r2 = try runEtag(a, .{}, &req2, resp200b);
    try testing.expectEqual(@as(u16, 304), @intFromEnum(r2.status));
    try testing.expectEqualStrings("max-age=3600", hdr(r2, "cache-control").?);
    try testing.expectEqualStrings("accept-encoding", hdr(r2, "vary").?);
}

test "etag: empty body gets etag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{});
    const r = try runEtag(arena.allocator(), .{}, &req, Response.text(""));
    try testing.expect(hdr(r, "etag") != null);
    try testing.expectEqual(@as(u16, 200), @intFromEnum(r.status));
}
