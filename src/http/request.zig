//! Request: a parsed HTTP/1.1 request head plus body, expressed entirely as
//! `[]const u8` views into a caller-owned read buffer. Nothing here owns memory;
//! every slice aliases the buffer the bytes were read into (zero-copy). Slices
//! are valid only for the lifetime of that buffer (i.e. the request).

const std = @import("std");

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,

    pub fn parse(token: []const u8) ?Method {
        return std.meta.stringToEnum(Method, token);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Maximum header fields captured per request. Excess headers are a parse error
/// rather than a silent truncation.
pub const max_headers = 64;

pub const Request = struct {
    method: Method,
    /// Raw request target as received, e.g. "/users/42?active=true".
    target: []const u8,
    /// Path portion of `target` (before '?'). Slice into the buffer.
    path: []const u8,
    /// Query portion of `target` (after '?'), empty if none. Slice into buffer.
    query: []const u8,
    /// HTTP minor version (1 for HTTP/1.1, 0 for HTTP/1.0).
    version_minor: u8,
    headers: []const Header,
    /// Request body. May be empty. Slice into the buffer; only valid once the
    /// full body has been read into it.
    body: []const u8,

    /// Case-insensitive header lookup. Returns the first matching value.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn contentLength(self: *const Request) ?usize {
        const v = self.header("content-length") orelse return null;
        return std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null;
    }

    /// Whether the connection should be kept alive after this request.
    /// HTTP/1.1 defaults to keep-alive (unless `Connection: close`); HTTP/1.0
    /// defaults to close (unless `Connection: keep-alive`).
    pub fn isPersistent(self: *const Request) bool {
        if (self.header("connection")) |c| {
            if (hasToken(c, "close")) return false;
            if (hasToken(c, "keep-alive")) return true;
        }
        return self.version_minor >= 1;
    }

    /// Whether the request body uses chunked transfer-encoding (unsupported in
    /// v1.1 — the server rejects these with 411).
    pub fn isChunked(self: *const Request) bool {
        const te = self.header("transfer-encoding") orelse return false;
        return hasToken(te, "chunked");
    }
};

/// Case-insensitive membership test over a comma-separated header value.
fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), token)) return true;
    }
    return false;
}

const testing = std.testing;

fn reqWith(version_minor: u8, headers: []const Header) Request {
    return .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version_minor = version_minor,
        .headers = headers,
        .body = "",
    };
}

test "isPersistent honors version defaults and Connection header" {
    // HTTP/1.1 default keep-alive; HTTP/1.0 default close.
    try testing.expect(reqWith(1, &.{}).isPersistent());
    try testing.expect(!reqWith(0, &.{}).isPersistent());
    // Explicit override either way, case-insensitive, token in a list.
    try testing.expect(!reqWith(1, &.{.{ .name = "Connection", .value = "close" }}).isPersistent());
    try testing.expect(reqWith(0, &.{.{ .name = "connection", .value = "keep-alive" }}).isPersistent());
    try testing.expect(!reqWith(1, &.{.{ .name = "Connection", .value = "Keep-Alive, Close" }}).isPersistent());
}

test "isChunked detects chunked transfer-encoding" {
    try testing.expect(reqWith(1, &.{.{ .name = "Transfer-Encoding", .value = "chunked" }}).isChunked());
    try testing.expect(reqWith(1, &.{.{ .name = "transfer-encoding", .value = "gzip, chunked" }}).isChunked());
    try testing.expect(!reqWith(1, &.{.{ .name = "Transfer-Encoding", .value = "gzip" }}).isChunked());
    try testing.expect(!reqWith(1, &.{}).isChunked());
}
