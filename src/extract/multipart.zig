//! `Multipart` — parse a buffered `multipart/form-data` request body into a
//! zero-copy list of parts. A body extractor: must be a handler's last parameter.

const std = @import("std");

/// One multipart/form-data part. All slices borrow `req.body` (zero-copy).
pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

pub const Multipart = struct {
    parts: []const Part,

    pub const zax_is_extractor = true;
    pub const zax_is_body = true;
    pub const max_parts = 1024;
    pub const Error = error{ InvalidMultipart, TooManyParts, OutOfMemory };

    pub fn fromContext(ctx: anytype) Error!Multipart {
        const ct = ctx.req.header("content-type") orelse return error.InvalidMultipart;
        const boundary = parseBoundary(ct) orelse return error.InvalidMultipart;
        return parse(ctx.req.body, boundary, ctx.arena);
    }

    pub fn field(self: Multipart, name: []const u8) ?[]const u8 {
        for (self.parts) |p| {
            if (p.filename == null and std.mem.eql(u8, p.name, name)) return p.data;
        }
        return null;
    }
    pub fn file(self: Multipart, name: []const u8) ?Part {
        for (self.parts) |p| {
            if (p.filename != null and std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
    pub fn part(self: Multipart, name: []const u8) ?Part {
        for (self.parts) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// Extract the (unquoted) boundary from a `multipart/form-data; boundary=...`
/// content-type value. Returns null if not multipart/form-data or no boundary.
fn parseBoundary(ct: []const u8) ?[]const u8 {
    // Require the media type (case-insensitive), ignore leading OWS.
    const trimmed = std.mem.trim(u8, ct, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "multipart/form-data")) return null;
    // Find `boundary=` parameter (case-insensitive on the name).
    var rest = trimmed;
    while (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
        var param = std.mem.trim(u8, rest[semi + 1 ..], " \t");
        // param is "name=value..."; we may continue scanning, so compute next first.
        const next_semi = std.mem.indexOfScalar(u8, param, ';');
        const one = if (next_semi) |n| param[0..n] else param;
        if (std.ascii.startsWithIgnoreCase(one, "boundary=")) {
            var v = std.mem.trim(u8, one["boundary=".len..], " \t");
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            return if (v.len == 0) null else v;
        }
        rest = if (next_semi) |n| param[n..] else "";
    }
    return null;
}

/// Parse `body` delimited by `--boundary` into parts (arena-allocated array).
fn parse(body: []const u8, boundary: []const u8, arena: std.mem.Allocator) Multipart.Error!Multipart {
    var list: std.ArrayList(Part) = .empty;
    var dash_boundary_buf: [74]u8 = undefined; // "--" + boundary (<=70) + slack
    if (boundary.len + 2 > dash_boundary_buf.len) return error.InvalidMultipart;
    const delim = blk: {
        @memcpy(dash_boundary_buf[0..2], "--");
        @memcpy(dash_boundary_buf[2 .. 2 + boundary.len], boundary);
        break :blk dash_boundary_buf[0 .. 2 + boundary.len];
    };

    // Find the first delimiter (skip any preamble).
    var i = std.mem.indexOf(u8, body, delim) orelse return error.InvalidMultipart;
    i += delim.len;
    while (true) {
        // After a delimiter: "--" => terminator (done); "\r\n" => another part.
        if (i + 2 > body.len) return error.InvalidMultipart;
        if (body[i] == '-' and body[i + 1] == '-') break; // closing delimiter
        if (!(body[i] == '\r' and body[i + 1] == '\n')) return error.InvalidMultipart;
        i += 2;

        // Header block ends at the first "\r\n\r\n".
        const hdr_rel = std.mem.indexOf(u8, body[i..], "\r\n\r\n") orelse return error.InvalidMultipart;
        const headers = body[i .. i + hdr_rel];
        const data_start = i + hdr_rel + 4;

        // Next delimiter is "\r\n" + delim; data is everything before that "\r\n".
        var needle_buf: [76]u8 = undefined;
        @memcpy(needle_buf[0..2], "\r\n");
        @memcpy(needle_buf[2 .. 2 + delim.len], delim);
        const needle = needle_buf[0 .. 2 + delim.len];
        const next_rel = std.mem.indexOf(u8, body[data_start..], needle) orelse return error.InvalidMultipart;
        const data = body[data_start .. data_start + next_rel];

        var p = Part{ .name = "", .data = data };
        if (!parsePartHeaders(headers, &p)) return error.InvalidMultipart;
        if (list.items.len >= Multipart.max_parts) return error.TooManyParts;
        try list.append(arena, p);

        i = data_start + next_rel + needle.len; // position right after the delimiter
    }
    return .{ .parts = list.items };
}

/// Parse a part's header block; fill name/filename/content_type. Requires `name`.
fn parsePartHeaders(headers: []const u8, p: *Part) bool {
    var found_name = false;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        const hname = std.mem.trim(u8, line[0..colon], " \t");
        const hval = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(hname, "content-disposition")) {
            p.name = dispParam(hval, "name") orelse return false;
            p.filename = dispParam(hval, "filename");
            found_name = true;
        } else if (std.ascii.eqlIgnoreCase(hname, "content-type")) {
            p.content_type = hval;
        }
    }
    return found_name;
}

/// Extract a (de-quoted) `key="value"` (or `key=value`) param from a header value.
fn dispParam(hval: []const u8, key: []const u8) ?[]const u8 {
    var rest = hval;
    while (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
        const seg = std.mem.trim(u8, rest[semi + 1 ..], " \t");
        const nxt = std.mem.indexOfScalar(u8, seg, ';');
        const one = if (nxt) |n| seg[0..n] else seg;
        if (std.mem.indexOfScalar(u8, one, '=')) |eq| {
            const k = std.mem.trim(u8, one[0..eq], " \t");
            if (std.ascii.eqlIgnoreCase(k, key)) {
                var v = std.mem.trim(u8, one[eq + 1 ..], " \t");
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
                return v;
            }
        }
        rest = if (nxt) |n| seg[n..] else "";
    }
    return null;
}

const testing = std.testing;
const Request = @import("../http/request.zig").Request;
const Header = @import("../http/request.zig").Header;

fn makeCtx(arena: std.mem.Allocator, ct: []const u8, body: []const u8) struct {
    req: *const Request,
    arena: std.mem.Allocator,
    // Request stored in a static so &req is valid; tests are single-threaded.
} {
    const S = struct {
        var req: Request = undefined;
        var hdrs: [1]Header = undefined;
    };
    S.hdrs[0] = .{ .name = "content-type", .value = ct };
    S.req = .{ .method = .POST, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = &S.hdrs, .body = body };
    return .{ .req = &S.req, .arena = arena };
}

test "multipart: text field + file part" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"desc\"\r\n\r\n" ++
        "hello\r\n" ++
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "FILEDATA\r\n" ++
        "--X--\r\n";
    const mp = try Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data; boundary=X", body));
    try testing.expectEqual(@as(usize, 2), mp.parts.len);
    try testing.expectEqualStrings("hello", mp.field("desc").?);
    const f = mp.file("upload").?;
    try testing.expectEqualStrings("a.txt", f.filename.?);
    try testing.expectEqualStrings("text/plain", f.content_type.?);
    try testing.expectEqualStrings("FILEDATA", f.data);
    try testing.expect(mp.field("upload") == null); // it's a file, not a text field
    try testing.expect(mp.file("desc") == null);
}

test "multipart: quoted boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "--abc\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ny\r\n--abc--\r\n";
    const mp = try Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data; boundary=\"abc\"", body));
    try testing.expectEqualStrings("y", mp.field("x").?);
}

test "multipart: non-multipart or missing boundary -> InvalidMultipart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidMultipart, Multipart.fromContext(makeCtx(arena.allocator(), "application/json", "{}")));
    try testing.expectError(error.InvalidMultipart, Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data", "--X--\r\n")));
}

test "multipart: malformed (no terminator / missing name) -> InvalidMultipart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const no_term = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n"; // missing --X--
    try testing.expectError(error.InvalidMultipart, Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data; boundary=X", no_term)));
    const no_name = "--X\r\nContent-Type: text/plain\r\n\r\nv\r\n--X--\r\n";
    try testing.expectError(error.InvalidMultipart, Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data; boundary=X", no_name)));
}

test "multipart: binary data with embedded CRLF/NUL preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "--X\r\nContent-Disposition: form-data; name=\"b\"; filename=\"f\"\r\n\r\na\r\nb\x00c\r\n--X--\r\n";
    const mp = try Multipart.fromContext(makeCtx(arena.allocator(), "multipart/form-data; boundary=X", body));
    try testing.expectEqualStrings("a\r\nb\x00c", mp.file("b").?.data);
}
