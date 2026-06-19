//! Zero-copy HTTP/1.1 request-head parser. Operates on a single contiguous byte
//! buffer and returns a `Request` whose every field is a slice into that buffer.
//! No allocation, no copies. The parser handles the request line and headers;
//! the caller is responsible for ensuring the body bytes are present in the
//! buffer (using Content-Length) before reading `request.body`.

const std = @import("std");
const request = @import("request.zig");
const Request = request.Request;
const Header = request.Header;

pub const ParseError = error{
    /// Buffer does not yet contain a full header block (no CRLF CRLF). The
    /// caller should read more bytes and retry.
    Incomplete,
    /// Request line is malformed (method/target/version).
    InvalidRequestLine,
    /// Unknown or unsupported HTTP method token.
    UnknownMethod,
    /// A header line is malformed (missing colon).
    InvalidHeader,
    /// More than `request.max_headers` header fields.
    TooManyHeaders,
    /// Version was not HTTP/1.0 or HTTP/1.1.
    UnsupportedVersion,
};

pub const Parsed = struct {
    request: Request,
    /// Number of bytes consumed by the head (request line + headers + final
    /// CRLF). Body bytes, if any, begin at `buffer[head_len..]`.
    head_len: usize,
    /// Encoded body bytes after the head: the Content-Length value, or the full
    /// encoded length of a chunked body. The stream advances by
    /// `head_len + body_consumed`. parseHead leaves 0; readBody sets it.
    body_consumed: usize = 0,
};

/// Parse the request head from `buffer`. Header storage is written into
/// `headers_storage` (caller-owned, request-scoped) and referenced by the
/// returned Request; nothing is heap-allocated here.
pub fn parseHead(
    buffer: []const u8,
    headers_storage: *[request.max_headers]Header,
) ParseError!Parsed {
    // Locate end of header block: CRLF CRLF.
    const head_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse
        return error.Incomplete;
    const head_len = head_end + 4;
    const head = buffer[0..head_end];

    var lines = std.mem.splitSequence(u8, head, "\r\n");

    // --- Request line: METHOD SP target SP HTTP/1.x ---
    const req_line = lines.next() orelse return error.InvalidRequestLine;
    var rl = std.mem.splitScalar(u8, req_line, ' ');
    const method_tok = rl.next() orelse return error.InvalidRequestLine;
    const target = rl.next() orelse return error.InvalidRequestLine;
    const version_tok = rl.next() orelse return error.InvalidRequestLine;
    if (rl.next() != null) return error.InvalidRequestLine;

    const method = request.Method.parse(method_tok) orelse return error.UnknownMethod;
    const version_minor = try parseVersion(version_tok);

    // Split target into path and query (zero-copy slices).
    var path = target;
    var query: []const u8 = target[target.len..target.len];
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path = target[0..q];
        query = target[q + 1 ..];
    }

    // --- Header lines ---
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue; // tolerate stray blank line
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidHeader;
        if (n == request.max_headers) return error.TooManyHeaders;
        headers_storage[n] = .{
            .name = line[0..colon],
            // Trim optional leading/trailing OWS from the value only.
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
        n += 1;
    }

    return .{
        .request = .{
            .method = method,
            .target = target,
            .path = path,
            .query = query,
            .version_minor = version_minor,
            .headers = headers_storage[0..n],
            .body = buffer[head_len..head_len], // empty until caller attaches
        },
        .head_len = head_len,
    };
}

fn parseVersion(tok: []const u8) ParseError!u8 {
    if (std.mem.eql(u8, tok, "HTTP/1.1")) return 1;
    if (std.mem.eql(u8, tok, "HTTP/1.0")) return 0;
    return error.UnsupportedVersion;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn parseFixture(buf: []const u8, hs: *[request.max_headers]Header) ParseError!Parsed {
    return parseHead(buf, hs);
}

test "parses a simple GET request line" {
    var hs: [request.max_headers]Header = undefined;
    const raw = "GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const p = try parseFixture(raw, &hs);
    try testing.expectEqual(request.Method.GET, p.request.method);
    try testing.expectEqualStrings("/hello", p.request.path);
    try testing.expectEqualStrings("", p.request.query);
    try testing.expectEqual(@as(u8, 1), p.request.version_minor);
    try testing.expectEqual(@as(usize, raw.len), p.head_len);
}

test "splits path and query zero-copy" {
    var hs: [request.max_headers]Header = undefined;
    const raw = "GET /users/42?active=true&x=1 HTTP/1.1\r\nHost: h\r\n\r\n";
    const p = try parseFixture(raw, &hs);
    try testing.expectEqualStrings("/users/42", p.request.path);
    try testing.expectEqualStrings("active=true&x=1", p.request.query);
    // Zero-copy: path/query point inside the original buffer.
    const base = @intFromPtr(raw.ptr);
    const end = base + raw.len;
    const pp = @intFromPtr(p.request.path.ptr);
    const qp = @intFromPtr(p.request.query.ptr);
    try testing.expect(pp >= base and pp < end);
    try testing.expect(qp >= base and qp < end);
}

test "parses headers and case-insensitive lookup with OWS trimming" {
    var hs: [request.max_headers]Header = undefined;
    const raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Type:  application/json \r\n" ++
        "Content-Length: 7\r\n\r\n";
    const p = try parseFixture(raw, &hs);
    try testing.expectEqual(request.Method.POST, p.request.method);
    try testing.expectEqual(@as(usize, 3), p.request.headers.len);
    try testing.expectEqualStrings("application/json", p.request.header("content-type").?);
    try testing.expectEqualStrings("example.com", p.request.header("HOST").?);
    try testing.expectEqual(@as(?usize, 7), p.request.contentLength());
}

test "body slice is attachable from the same buffer" {
    var hs: [request.max_headers]Header = undefined;
    const raw = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var p = try parseFixture(raw, &hs);
    const len = p.request.contentLength().?;
    p.request.body = raw[p.head_len .. p.head_len + len];
    try testing.expectEqualStrings("hello", p.request.body);
}

test "incomplete head reports Incomplete" {
    var hs: [request.max_headers]Header = undefined;
    try testing.expectError(error.Incomplete, parseFixture("GET / HTTP/1.1\r\nHost: x", &hs));
}

test "malformed request line and unknown method" {
    var hs: [request.max_headers]Header = undefined;
    try testing.expectError(error.UnknownMethod, parseFixture("FROBNICATE / HTTP/1.1\r\n\r\n", &hs));
    try testing.expectError(error.InvalidRequestLine, parseFixture("GET /only-two HTTP/1.1 extra\r\n\r\n", &hs));
    try testing.expectError(error.UnsupportedVersion, parseFixture("GET / HTTP/2.0\r\n\r\n", &hs));
    try testing.expectError(error.InvalidHeader, parseFixture("GET / HTTP/1.1\r\nBadHeaderNoColon\r\n\r\n", &hs));
}
