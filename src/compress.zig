//! gzip response-compression middleware (built-in). `compress(Ctx, config)`
//! returns a Chain(Ctx) middleware that gzips eligible buffered responses when
//! the client sends `Accept-Encoding: gzip`. Streamed responses, small bodies,
//! non-text content types, and already-encoded responses pass through untouched.
//! Config is comptime.

const std = @import("std");
const flate = std.compress.flate;
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;
const Header = @import("http/request.zig").Header;

pub const Compress = struct {
    pub const Level = enum { fastest, default, best };
    level: Level = .default,
    /// Skip bodies smaller than this many bytes (compression overhead).
    min_length: usize = 1024,

    fn options(self: Compress) flate.Compress.Options {
        return switch (self.level) {
            .fastest => flate.Compress.Options.level_1,
            .default => flate.Compress.Options.level_6,
            .best => flate.Compress.Options.level_9,
        };
    }
};

pub fn compress(comptime Ctx: type, comptime config: Compress) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            var r = try next.run();
            if (r.streamer != null or r.pull_streamer != null) return r;
            if (r.body.len < config.min_length) return r;
            if (!acceptsGzip(ctx.req.header("accept-encoding"))) return r;
            if (hasHeader(r, "content-encoding")) return r;
            if (!isCompressible(r.content_type)) return r;

            const gz = gzip(ctx.arena, r.body, comptime config.options()) catch return r;
            if (gz.len >= r.body.len) return r; // no gain
            r.body = gz;
            r = try r.withHeader(ctx.arena, "content-encoding", "gzip");
            r = try r.withHeader(ctx.arena, "vary", "accept-encoding");
            return r;
        }
    };
    return Impl.mw;
}

/// gzip `body` into `arena`. Returns the compressed bytes.
fn gzip(arena: std.mem.Allocator, body: []const u8, opts: flate.Compress.Options) ![]const u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(arena, 4096); // >8: Compress.init asserts
    const window = try arena.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(&aw.writer, window, .gzip, opts);
    try c.writer.writeAll(body);
    try c.finish();
    // flush is a no-op on Allocating; kept for symmetry with the std flate test pattern
    try aw.writer.flush();
    return aw.written();
}

/// True iff `accept-encoding` advertises gzip and does not disable it (`gzip;q=0`).
/// Note: the `q=0` substring check is conservative — it also rejects `gzip;q=0.5`.
/// Clients sending `gzip;q=0.5` are rare; they receive an uncompressed response.
fn acceptsGzip(header: ?[]const u8) bool {
    const h = header orelse return false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        // token is "gzip" optionally followed by ";q=..."
        const name_end = std.mem.indexOfScalar(u8, t, ';') orelse t.len;
        const name = std.mem.trim(u8, t[0..name_end], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "gzip")) continue;
        // check for an explicit q=0 (conservative: also matches q=0.5 — acceptable)
        if (std.mem.indexOf(u8, t[name_end..], "q=0")) |_| {
            return false;
        }
        return true;
    }
    return false;
}

/// True for text-like media types worth compressing.
fn isCompressible(content_type: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const mt = std.mem.trim(u8, content_type[0..semi], " \t");
    if (std.ascii.startsWithIgnoreCase(mt, "text/")) return true;
    if (std.mem.endsWith(u8, mt, "+xml")) return true;
    const exact = [_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "image/svg+xml",
    };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(mt, e)) return true;
    return false;
}

fn hasHeader(r: Response, name: []const u8) bool {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const Request = @import("http/request.zig").Request;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
};

fn fakeReq(headers: []const Header) Request {
    return .{ .method = .GET, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Run `config`'s compress middleware over a request, with a handler that returns `resp`.
fn runCompress(arena: std.mem.Allocator, comptime config: Compress, req: *const Request, resp: Response) !Response {
    const C = middleware.Chain(TestCtx);
    const H = struct {
        var out: Response = undefined;
        fn handler(_: *const TestCtx) anyerror!Response {
            return out;
        }
    };
    H.out = resp;
    var ctx = TestCtx{ .req = req, .arena = arena };
    const mws = [_]C.Middleware{compress(TestCtx, config)};
    return C.run(&mws, &H.handler, &ctx);
}

/// gunzip helper for round-trip assertions.
fn gunzip(arena: std.mem.Allocator, gz: []const u8) ![]const u8 {
    var in = std.Io.Reader.fixed(gz);
    const dbuf = try arena.alloc(u8, flate.max_window_len);
    var dec = flate.Decompress.init(&in, .gzip, dbuf);
    return dec.reader.allocRemaining(arena, .unlimited);
}

test "compress: gzip a large text body and round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const r = try runCompress(a, .{}, &req, Response.text(body));
    try testing.expectEqualStrings("gzip", hdr(r, "content-encoding").?);
    try testing.expectEqualStrings("accept-encoding", hdr(r, "vary").?);
    try testing.expect(r.body.len >= 2 and r.body[0] == 0x1f and r.body[1] == 0x8b); // gzip magic
    try testing.expectEqualStrings(body, try gunzip(a, r.body));
}

test "compress: body below min_length untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text("small"));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: no gzip in accept-encoding untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "br, deflate" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text(body));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: gzip;q=0 disables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip;q=0" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text(body));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: non-text content-type untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    var resp = Response.text(body);
    resp.content_type = "image/png";
    const r = try runCompress(arena.allocator(), .{}, &req, resp);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: already content-encoded untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const pre = try Response.text(body).withHeader(a, "content-encoding", "br");
    const r = try runCompress(a, .{}, &req, pre);
    // still only the original br encoding; no second gzip applied
    try testing.expectEqualStrings("br", hdr(r, "content-encoding").?);
    try testing.expect(r.body.len == body.len); // body not replaced
}

test "compress: streamed response untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const Streamed = struct {
        fn run(_: *const u8, w: *std.Io.Writer) anyerror!void {
            try w.writeAll("x" ** 2000);
        }
    };
    const dummy: u8 = 0;
    const resp = Response.stream(u8, &dummy, Streamed.run, "text/plain");
    const r = try runCompress(arena.allocator(), .{}, &req, resp);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: level best and fastest both round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "hello world " ** 200;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    inline for (.{ Compress.Level.fastest, Compress.Level.best }) |lvl| {
        const r = try runCompress(a, .{ .level = lvl }, &req, Response.text(body));
        try testing.expectEqualStrings("gzip", hdr(r, "content-encoding").?);
        try testing.expectEqualStrings(body, try gunzip(a, r.body));
    }
}
