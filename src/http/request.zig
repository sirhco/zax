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
};
