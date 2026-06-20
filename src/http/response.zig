//! Response model + the `IntoResponse` contract. A `Response` borrows its body
//! slice (caller/request-scoped memory); it owns nothing. Serialization targets
//! any `std.Io.Writer`, so the same code path serves a socket writer in the
//! server and a fixed buffer in tests.

const std = @import("std");
const Writer = std.Io.Writer;
const Header = @import("request.zig").Header;
const sse_mod = @import("sse.zig");

pub const Status = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,
    _,

    pub fn code(s: Status) u16 {
        return @intFromEnum(s);
    }

    pub fn reason(s: Status) []const u8 {
        return switch (s) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_entity => "Unprocessable Entity",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",
            else => "",
        };
    }
};

/// A type-erased streamed-body producer: `func` writes the body bytes directly
/// to the connection writer, using `context` (which must outlive the request —
/// allocate it in the request arena).
pub const Streamer = struct {
    context: *const anyopaque,
    func: *const fn (context: *const anyopaque, w: *Writer) anyerror!void,
};

/// Result of a single `PullStreamer.next` call.
pub const PullResult = union(enum) {
    /// `n` bytes were written into the caller-supplied buffer; `n` may be 0
    /// (the caller should call `next` again immediately).
    chunk: usize,
    /// The stream is finished; no more bytes will be produced.
    done,
    /// An unrecoverable error occurred; the connection should be closed.
    err,
};

/// A type-erased PULL streamer: the caller supplies a buffer; `nextFn` fills it
/// and returns how many bytes were written, or signals done/error.
/// `context` must outlive the request (allocate in the request arena).
pub const PullStreamer = struct {
    context: *anyopaque,
    nextFn: *const fn (context: *anyopaque, buf: []u8) PullResult,

    pub fn next(self: PullStreamer, buf: []u8) PullResult {
        return self.nextFn(self.context, buf);
    }
};

/// One step of a pull-model SSE producer (see `Response.ssePull`).
pub const SsePull = union(enum) {
    /// A full SSE event (event/data/id/retry) — framed via `sse.formatEvent`.
    event: sse_mod.Event,
    /// An SSE comment line (`: text`) — keepalive heartbeat, via `sse.formatComment`.
    comment: []const u8,
    /// No event ready yet — emits a 0-byte chunk (parks on the evented backend).
    not_ready,
    /// End of stream.
    done,
};

pub const Response = struct {
    status: Status = .ok,
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// Borrowed body bytes. Valid for the request lifetime.
    body: []const u8 = "",
    /// Extra response headers (beyond content-length/type/connection). Borrowed;
    /// typically arena-allocated via `withHeader`. Empty by default (zero-alloc).
    headers: []const Header = &.{},
    /// When set, emitted as a `Location:` response header (used by redirects).
    location: ?[]const u8 = null,
    /// Whether to advertise a persistent connection. The server sets this from
    /// the request; default `false` keeps `connection: close` behavior.
    keep_alive: bool = false,
    /// When set, the body is produced by `streamer.func` (connection-close
    /// framing); `body`/`content-length` are not used.
    streamer: ?Streamer = null,
    /// When set, the body is produced by calling `pull_streamer.next(buf)` repeatedly
    /// (connection-close framing). The evented reactor uses this for true non-blocking
    /// streaming; the threaded backend loops next()+write(). `body`/`content-length`
    /// are not used. Mutually exclusive with `streamer` (set one or the other).
    pull_streamer: ?PullStreamer = null,

    pub fn text(body: []const u8) Response {
        return .{ .body = body };
    }

    pub fn jsonRaw(body: []const u8) Response {
        return .{ .content_type = "application/json", .body = body };
    }

    pub fn fromStatus(s: Status) Response {
        return .{ .status = s, .body = "" };
    }

    /// Build a bare response with an arbitrary numeric status (for codes outside the
    /// named set — proxies, custom). Named codes should prefer `fromStatus`.
    pub fn fromCode(code: u16) Response {
        return .{ .status = @enumFromInt(code) };
    }

    /// A redirect to `location` with the given 3xx status.
    pub fn redirect(status: Status, location: []const u8) Response {
        return .{ .status = status, .location = location };
    }
    pub fn seeOther(location: []const u8) Response {
        return redirect(.see_other, location);
    }
    pub fn temporaryRedirect(location: []const u8) Response {
        return redirect(.temporary_redirect, location);
    }
    pub fn permanentRedirect(location: []const u8) Response {
        return redirect(.permanent_redirect, location);
    }

    /// HTML body with a text/html content type.
    pub fn html(body: []const u8) Response {
        return .{ .content_type = "text/html; charset=utf-8", .body = body };
    }

    /// Serialize `value` to a JSON body in `arena` (typed counterpart to jsonRaw).
    pub fn json(arena: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!Response {
        const body = try std.json.Stringify.valueAlloc(arena, value, .{});
        return .{ .content_type = "application/json", .body = body };
    }

    /// Build a streamed (connection-close) response. `func` receives the
    /// arena-allocated `context` and the connection writer, and writes the body
    /// bytes directly. `context` must outlive the request (use the request arena).
    pub fn stream(
        comptime Ctx: type,
        context: *const Ctx,
        comptime func: fn (*const Ctx, *Writer) anyerror!void,
        content_type: []const u8,
    ) Response {
        const Erased = struct {
            fn call(c: *const anyopaque, w: *Writer) anyerror!void {
                return func(@ptrCast(@alignCast(c)), w);
            }
        };
        return .{
            .content_type = content_type,
            .streamer = .{ .context = context, .func = &Erased.call },
            .keep_alive = false,
        };
    }

    /// Build a pull-streamed (connection-close) response. `nextFn` is called
    /// repeatedly with a caller-owned buffer; it fills the buffer and returns
    /// `.chunk(n)` (n bytes written), `.done` when finished, or `.err` on failure.
    /// `context` must outlive the request (use the request arena).
    ///
    /// True non-blocking streaming on the evented backend; blocking loop on threaded.
    pub fn streamPull(
        comptime Ctx: type,
        context: *Ctx,
        comptime nextFn: fn (*Ctx, []u8) PullResult,
        content_type: []const u8,
    ) Response {
        const Erased = struct {
            fn call(c: *anyopaque, buf: []u8) PullResult {
                return nextFn(@ptrCast(@alignCast(c)), buf);
            }
        };
        return .{
            .content_type = content_type,
            .pull_streamer = .{ .context = context, .nextFn = &Erased.call },
            .keep_alive = false,
        };
    }

    /// Build a pull-model SSE (`text/event-stream`) response. `nextFn` is called
    /// repeatedly; zax frames each returned event/comment into the driver's write
    /// buffer via the SSE wire formatter. Connection-close framing. Works on both
    /// backends — on the evented backend `not_ready` parks the connection on the
    /// timer wheel (no busy-spin); on threaded it loops, so for sparse streams on
    /// the threaded backend prefer the push `sse()` helper. A single event larger
    /// than the driver buffer yields `.err` (the connection closes).
    /// `context` must outlive the request (use the request arena).
    pub fn ssePull(
        comptime Ctx: type,
        context: *Ctx,
        comptime nextFn: fn (*Ctx) SsePull,
    ) Response {
        const Erased = struct {
            fn call(c: *anyopaque, buf: []u8) PullResult {
                const ctx: *Ctx = @ptrCast(@alignCast(c));
                switch (nextFn(ctx)) {
                    .event => |e| {
                        var w = Writer.fixed(buf);
                        sse_mod.formatEvent(&w, e) catch return .err;
                        return .{ .chunk = w.buffered().len };
                    },
                    .comment => |txt| {
                        var w = Writer.fixed(buf);
                        sse_mod.formatComment(&w, txt) catch return .err;
                        return .{ .chunk = w.buffered().len };
                    },
                    .not_ready => return .{ .chunk = 0 },
                    .done => return .done,
                }
            }
        };
        return .{
            .content_type = "text/event-stream",
            .pull_streamer = .{ .context = context, .nextFn = &Erased.call },
            .keep_alive = false,
        };
    }

    /// Build an SSE (`text/event-stream`) streamed response. `func` receives the
    /// arena-allocated `context` and an `Sse` event writer. Connection-close
    /// framing (like `stream`); each event is flushed as it is sent.
    pub fn sse(
        comptime Ctx: type,
        context: *const Ctx,
        comptime func: fn (*const Ctx, *sse_mod.Sse) anyerror!void,
    ) Response {
        const Wrap = struct {
            fn run(c: *const Ctx, w: *Writer) anyerror!void {
                var s = sse_mod.Sse{ .w = w };
                return func(c, &s);
            }
        };
        return Response.stream(Ctx, context, Wrap.run, "text/event-stream");
    }

    /// Return a copy of `self` with `(name, value)` appended to its headers,
    /// using `arena` for the (re)allocated header slice. Borrowed name/value
    /// must outlive the response (request-scoped).
    pub fn withHeader(self: Response, arena: std.mem.Allocator, name: []const u8, value: []const u8) std.mem.Allocator.Error!Response {
        const list = try arena.alloc(Header, self.headers.len + 1);
        @memcpy(list[0..self.headers.len], self.headers);
        list[self.headers.len] = .{ .name = name, .value = value };
        var r = self;
        r.headers = list;
        return r;
    }

    /// Shared head serializer. `content_length` is emitted only when given.
    /// When `chunked` is true (streamed + keep-alive), emits
    /// `transfer-encoding: chunked` and `connection: keep-alive`;
    /// otherwise honors `self.keep_alive`.
    fn writeHeadersFramed(self: Response, w: *Writer, content_length: ?usize, chunked: bool) Writer.Error!void {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        if (content_length) |n| try w.print("content-length: {d}\r\n", .{n});
        if (chunked) try w.writeAll("transfer-encoding: chunked\r\n");
        try w.print("content-type: {s}\r\n", .{self.content_type});
        for (self.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
        const ka = chunked or self.keep_alive;
        try w.writeAll(if (ka) "connection: keep-alive\r\n" else "connection: close\r\n");
        try w.writeAll("\r\n");
    }

    /// Emit the response head. `content_length` is emitted only when given
    /// (a streamed response omits it). Buffered path: chunked=false.
    pub fn writeHeaders(self: Response, w: *Writer, content_length: ?usize) Writer.Error!void {
        try self.writeHeadersFramed(w, content_length, false);
    }

    /// Serialize a complete HTTP/1.1 response (head + buffered body) to `w`.
    pub fn write(self: Response, w: *Writer) Writer.Error!void {
        try self.writeHeaders(w, self.body.len);
        try w.writeAll(self.body);
    }

    /// Write the head for a streamed response. When `chunked` is true, emits
    /// `transfer-encoding: chunked` and `connection: keep-alive`; when false,
    /// uses connection-close framing (existing behavior).
    pub fn writeHead(self: Response, w: *Writer, chunked: bool) Writer.Error!void {
        try self.writeHeadersFramed(w, null, chunked);
    }
};

/// Whether `T` is a byte-string-like type we can treat as a text body.
fn isStringLike(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    const info = @typeInfo(T);
    // String literals: *const [N:0]u8
    if (info == .pointer and info.pointer.size == .one) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8) return true;
    }
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) return true;
    return false;
}

/// The `IntoResponse` contract: convert a handler return value into a Response.
/// Built-in conversions: `Response` (identity), `Status`, byte-strings (text).
/// Any other type may opt in by defining `pub fn intoResponse(self) Response`.
pub fn intoResponse(value: anytype) Response {
    const T = @TypeOf(value);
    if (T == Response) return value;
    if (T == Status) return Response.fromStatus(value);
    if (comptime isStringLike(T)) return Response.text(value);
    if (comptime std.meta.hasMethod(T, "intoResponse")) return value.intoResponse();
    @compileError("type '" ++ @typeName(T) ++ "' does not satisfy IntoResponse");
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn serialize(buf: []u8, r: Response) []const u8 {
    var w = Writer.fixed(buf);
    r.write(&w) catch unreachable;
    return w.buffered();
}

test "serializes a 200 text response" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.text("hello"));
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "content-length: 5\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "connection: close\r\n\r\n" ++
        "hello";
    try testing.expectEqualStrings(expected, out);
}

test "status-only response has empty body and right reason" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.fromStatus(.not_found));
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "content-length: 0\r\n") != null);
}

test "too_many_requests status code and reason" {
    try testing.expectEqual(@as(u16, 429), Status.too_many_requests.code());
    try testing.expectEqualStrings("Too Many Requests", Status.too_many_requests.reason());
}

test "keep_alive toggles the Connection header" {
    var buf: [256]u8 = undefined;
    var r = Response.text("x");
    r.keep_alive = true;
    const out = serialize(&buf, r);
    try testing.expect(std.mem.indexOf(u8, out, "connection: keep-alive\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: close") == null);
}

test "withHeader appends extra headers in order before connection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;

    const r = try (try Response.text("hi").withHeader(a, "x-request-id", "abc"))
        .withHeader(a, "x-cache", "MISS");
    const out = serialize(&buf, r);

    const id_at = std.mem.indexOf(u8, out, "x-request-id: abc\r\n").?;
    const cache_at = std.mem.indexOf(u8, out, "x-cache: MISS\r\n").?;
    const conn_at = std.mem.indexOf(u8, out, "connection: close\r\n").?;
    const ct_at = std.mem.indexOf(u8, out, "content-type:").?;
    // Order: content-type < x-request-id < x-cache < connection.
    try testing.expect(ct_at < id_at);
    try testing.expect(id_at < cache_at);
    try testing.expect(cache_at < conn_at);
    try testing.expect(std.mem.endsWith(u8, out, "hi"));
}

test "json response sets content-type" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.jsonRaw("{\"x\":1}"));
    try testing.expect(std.mem.indexOf(u8, out, "content-type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "{\"x\":1}"));
}

test "IntoResponse: string literal, slice, Status, and identity" {
    const r1 = intoResponse("hi"); // *const [2:0]u8
    try testing.expectEqualStrings("hi", r1.body);

    const s: []const u8 = "world";
    const r2 = intoResponse(s);
    try testing.expectEqualStrings("world", r2.body);

    const r3 = intoResponse(Status.created);
    try testing.expectEqual(Status.created, r3.status);
    try testing.expectEqualStrings("", r3.body);

    const r4 = intoResponse(Response.jsonRaw("{}"));
    try testing.expectEqualStrings("application/json", r4.content_type);
}

test "IntoResponse: custom type via intoResponse method" {
    const Custom = struct {
        n: u8,
        pub fn intoResponse(self: @This()) Response {
            return if (self.n == 0) Response.fromStatus(.no_content) else Response.text("nonzero");
        }
    };
    try testing.expectEqual(Status.no_content, intoResponse(Custom{ .n = 0 }).status);
    try testing.expectEqualStrings("nonzero", intoResponse(Custom{ .n = 1 }).body);
}

test "hardening statuses: 408/413/431 codes and reasons" {
    try testing.expectEqual(@as(u16, 408), Status.request_timeout.code());
    try testing.expectEqualStrings("Request Timeout", Status.request_timeout.reason());
    try testing.expectEqual(@as(u16, 413), Status.payload_too_large.code());
    try testing.expectEqualStrings("Payload Too Large", Status.payload_too_large.reason());
    try testing.expectEqual(@as(u16, 431), Status.request_header_fields_too_large.code());
    try testing.expectEqualStrings("Request Header Fields Too Large", Status.request_header_fields_too_large.reason());
}

test "redirect statuses: 303/307/308 codes and reasons" {
    try testing.expectEqual(@as(u16, 303), Status.see_other.code());
    try testing.expectEqualStrings("See Other", Status.see_other.reason());
    try testing.expectEqual(@as(u16, 307), Status.temporary_redirect.code());
    try testing.expectEqualStrings("Temporary Redirect", Status.temporary_redirect.reason());
    try testing.expectEqual(@as(u16, 308), Status.permanent_redirect.code());
    try testing.expectEqualStrings("Permanent Redirect", Status.permanent_redirect.reason());
}

test "redirect sets status and Location, omits Location when unset" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.redirect(.found, "/dashboard"));
    try testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 302 Found\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "location: /dashboard\r\n") != null);

    var buf2: [256]u8 = undefined;
    const plain = serialize(&buf2, Response.text("hi"));
    try testing.expect(std.mem.indexOf(u8, plain, "location:") == null);
}

test "redirect convenience wrappers use the right status" {
    try testing.expectEqual(Status.see_other, Response.seeOther("/a").status);
    try testing.expectEqual(Status.temporary_redirect, Response.temporaryRedirect("/b").status);
    try testing.expectEqual(Status.permanent_redirect, Response.permanentRedirect("/c").status);
    try testing.expectEqualStrings("/a", Response.seeOther("/a").location.?);
}

test "html sets text/html content type" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.html("<h1>Hi</h1>"));
    try testing.expect(std.mem.indexOf(u8, out, "content-type: text/html; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "<h1>Hi</h1>"));
}

test "json serializes a value into the arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try Response.json(arena.allocator(), .{ .a = @as(u32, 1), .b = "x" });
    try testing.expectEqualStrings("application/json", r.content_type);
    try testing.expectEqualStrings("{\"a\":1,\"b\":\"x\"}", r.body);
}

test "writeHead omits content-length and sets connection close" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain; charset=utf-8" };
    r.writeHead(&w, false) catch unreachable;
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "content-length:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-type: text/plain; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n")); // head ends at the blank line; no body
}

test "stream builder round-trips the typed context" {
    const Ctx = struct { msg: []const u8 };
    const Impl = struct {
        fn run(c: *const Ctx, w: *Writer) anyerror!void {
            try w.writeAll(c.msg);
        }
    };
    var ctx = Ctx{ .msg = "hello" };
    const r = Response.stream(Ctx, &ctx, Impl.run, "text/plain");
    try testing.expect(r.streamer != null);
    try testing.expectEqualStrings("text/plain", r.content_type);
    try testing.expect(r.keep_alive == false);

    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try r.streamer.?.func(r.streamer.?.context, &w);
    try testing.expectEqualStrings("hello", w.buffered());
}

test "PullStreamer: next() calls nextFn with the buffer" {
    const Ctx = struct { calls: usize = 0 };
    const Impl = struct {
        fn next(c: *Ctx, buf: []u8) PullResult {
            if (c.calls == 0) {
                c.calls += 1;
                buf[0] = 'h';
                buf[1] = 'i';
                return .{ .chunk = 2 };
            }
            return .done;
        }
    };
    var ctx = Ctx{};
    const ps = PullStreamer{
        .context = &ctx,
        .nextFn = @ptrCast(&Impl.next),
    };
    var buf: [8]u8 = undefined;
    const r1 = ps.next(&buf);
    try testing.expectEqual(PullResult{ .chunk = 2 }, r1);
    try testing.expectEqualStrings("hi", buf[0..2]);
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "streamPull: builds a Response with pull_streamer set, keep_alive false, no body" {
    const Ctx = struct { done: bool = false };
    const Impl = struct {
        fn next(c: *Ctx, buf: []u8) PullResult {
            _ = buf;
            if (!c.done) { c.done = true; return .{ .chunk = 0 }; }
            return .done;
        }
    };
    var ctx = Ctx{};
    const r = Response.streamPull(Ctx, &ctx, Impl.next, "text/plain");
    try testing.expect(r.pull_streamer != null);
    try testing.expectEqualStrings("text/plain", r.content_type);
    try testing.expect(r.keep_alive == false);
    try testing.expectEqualStrings("", r.body);
    try testing.expect(r.streamer == null); // does NOT set push streamer
}

test "ssePull: builds text/event-stream Response, connection-close, pull_streamer set, no body" {
    const Ctx = struct {
        fn next(_: *@This()) SsePull {
            return .done;
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    try testing.expectEqualStrings("text/event-stream", r.content_type);
    try testing.expect(r.pull_streamer != null);
    try testing.expect(!r.keep_alive);
    try testing.expectEqual(@as(usize, 0), r.body.len);
}

test "ssePull: event is framed via formatEvent into the buffer, then done" {
    const Ctx = struct {
        sent: bool = false,
        fn next(c: *@This()) SsePull {
            if (c.sent) return .done;
            c.sent = true;
            return .{ .event = .{ .event = "tick", .data = "hi" } };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;

    var buf: [256]u8 = undefined;
    const res = ps.next(&buf);

    // Reference: what formatEvent would write for the same event.
    var rbuf: [256]u8 = undefined;
    var rw = Writer.fixed(&rbuf);
    try sse_mod.formatEvent(&rw, .{ .event = "tick", .data = "hi" });
    const expected = rw.buffered();

    switch (res) {
        .chunk => |n| try testing.expectEqualStrings(expected, buf[0..n]),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "status: expanded named codes" {
    try testing.expectEqual(@as(u16, 410), Status.gone.code());
    try testing.expectEqualStrings("Gone", Status.gone.reason());
    try testing.expectEqual(@as(u16, 502), Status.bad_gateway.code());
    try testing.expectEqualStrings("Bad Gateway", Status.bad_gateway.reason());
    try testing.expectEqual(@as(u16, 418), Status.im_a_teapot.code());
    try testing.expectEqualStrings("I'm a teapot", Status.im_a_teapot.reason());
    try testing.expectEqual(@as(u16, 206), Status.partial_content.code());
    try testing.expectEqual(@as(u16, 100), Status.@"continue".code());
}

test "status: arbitrary code via non-exhaustive enum" {
    const s: Status = @enumFromInt(@as(u16, 499));
    try testing.expectEqual(@as(u16, 499), s.code());
    try testing.expectEqualStrings("", s.reason());
}

test "response: fromCode arbitrary status serializes with empty reason" {
    var buf: [128]u8 = undefined;
    const out = serialize(&buf, Response.fromCode(599));
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 599 \r\n"));
}

test "ssePull: comment framed; not_ready → chunk 0; done" {
    const Ctx = struct {
        step: usize = 0,
        fn next(c: *@This()) SsePull {
            defer c.step += 1;
            return switch (c.step) {
                0 => .{ .comment = "ping" },
                1 => .not_ready,
                else => .done,
            };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;
    var buf: [64]u8 = undefined;

    switch (ps.next(&buf)) {
        .chunk => |n| try testing.expectEqualStrings(": ping\n", buf[0..n]),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(PullResult{ .chunk = 0 }, ps.next(&buf));
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "ssePull: event larger than the buffer → err" {
    const Ctx = struct {
        fn next(_: *@This()) SsePull {
            return .{ .event = .{ .data = "x" ** 200 } };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;
    var buf: [16]u8 = undefined; // far smaller than the 200-byte payload
    try testing.expectEqual(PullResult.err, ps.next(&buf));
}

test "writeHead chunked=true emits transfer-encoding chunked + keep-alive, no content-length" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain" };
    try r.writeHead(&w, true);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: keep-alive\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-length") == null);
}

test "writeHead chunked=false emits connection close" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Response{ .content_type = "text/plain" };
    try r.writeHead(&w, false);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding") == null);
}
