//! Response model + the `IntoResponse` contract. A `Response` borrows its body
//! slice (caller/request-scoped memory); it owns nothing. Serialization targets
//! any `std.Io.Writer`, so the same code path serves a socket writer in the
//! server and a fixed buffer in tests.

const std = @import("std");
const Writer = std.Io.Writer;
const Header = @import("request.zig").Header;

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    moved_permanently = 301,
    found = 302,
    not_modified = 304,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    length_required = 411,
    request_timeout = 408,
    payload_too_large = 413,
    request_header_fields_too_large = 431,
    too_many_requests = 429,
    unprocessable_entity = 422,
    internal_server_error = 500,
    not_implemented = 501,
    service_unavailable = 503,

    pub fn code(s: Status) u16 {
        return @intFromEnum(s);
    }

    pub fn reason(s: Status) []const u8 {
        return switch (s) {
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .not_modified => "Not Modified",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .conflict => "Conflict",
            .length_required => "Length Required",
            .request_timeout => "Request Timeout",
            .payload_too_large => "Payload Too Large",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .too_many_requests => "Too Many Requests",
            .unprocessable_entity => "Unprocessable Entity",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .service_unavailable => "Service Unavailable",
        };
    }
};

pub const Response = struct {
    status: Status = .ok,
    content_type: []const u8 = "text/plain; charset=utf-8",
    /// Borrowed body bytes. Valid for the request lifetime.
    body: []const u8 = "",
    /// Extra response headers (beyond content-length/type/connection). Borrowed;
    /// typically arena-allocated via `withHeader`. Empty by default (zero-alloc).
    headers: []const Header = &.{},
    /// Whether to advertise a persistent connection. The server sets this from
    /// the request; default `false` keeps `connection: close` behavior.
    keep_alive: bool = false,

    pub fn text(body: []const u8) Response {
        return .{ .body = body };
    }

    pub fn jsonRaw(body: []const u8) Response {
        return .{ .content_type = "application/json", .body = body };
    }

    pub fn fromStatus(s: Status) Response {
        return .{ .status = s, .body = "" };
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

    /// Serialize a complete HTTP/1.1 response (head + body) to `w`.
    pub fn write(self: Response, w: *Writer) Writer.Error!void {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        try w.print("content-length: {d}\r\n", .{self.body.len});
        try w.print("content-type: {s}\r\n", .{self.content_type});
        for (self.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll(if (self.keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
        try w.writeAll("\r\n");
        try w.writeAll(self.body);
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
