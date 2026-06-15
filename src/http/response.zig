//! Response model + the `IntoResponse` contract. A `Response` borrows its body
//! slice (caller/request-scoped memory); it owns nothing. Serialization targets
//! any `std.Io.Writer`, so the same code path serves a socket writer in the
//! server and a fixed buffer in tests.

const std = @import("std");
const Writer = std.Io.Writer;

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

    pub fn text(body: []const u8) Response {
        return .{ .body = body };
    }

    pub fn jsonRaw(body: []const u8) Response {
        return .{ .content_type = "application/json", .body = body };
    }

    pub fn fromStatus(s: Status) Response {
        return .{ .status = s, .body = "" };
    }

    /// Serialize a complete HTTP/1.1 response (head + body) to `w`.
    pub fn write(self: Response, w: *Writer) Writer.Error!void {
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        try w.print("content-length: {d}\r\n", .{self.body.len});
        try w.print("content-type: {s}\r\n", .{self.content_type});
        try w.writeAll("connection: close\r\n");
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
