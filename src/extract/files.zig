//! Static file serving. `Files` is an extractor (carrying io + arena) that reads
//! a file into the request arena and returns a buffered Response. `contentType`
//! and `safeJoin` are pure helpers.

const std = @import("std");
const Response = @import("../http/response.zig").Response;

pub const default_max_file_size: usize = 16 * 1024 * 1024;

/// Content type by file extension; defaults to application/octet-stream.
pub fn contentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const map = .{
        .{ "html", "text/html; charset=utf-8" }, .{ "css", "text/css" },
        .{ "js", "text/javascript" },            .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },             .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },                .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },                 .{ "txt", "text/plain; charset=utf-8" },
        .{ "ico", "image/x-icon" },              .{ "wasm", "application/wasm" },
    };
    inline for (map) |kv| if (std.mem.eql(u8, ext, kv[0])) return kv[1];
    return "application/octet-stream";
}

/// Join `requested` under `root`, rejecting traversal. Returns null if
/// `requested` is empty or has a `.`, `..`, empty, or backslash-containing
/// segment (blocking absolute paths, `..`, `./`, `//`). Arena-allocated result.
pub fn safeJoin(arena: std.mem.Allocator, root: []const u8, requested: []const u8) ?[]const u8 {
    if (requested.len == 0) return null;
    var it = std.mem.splitScalar(u8, requested, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null) return null;
        for (seg) |c| if (c < 0x20) return null; // reject NUL and other control bytes
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, requested }) catch null;
}

pub const Files = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!Files {
        return .{ .io = ctx.io, .arena = ctx.arena };
    }

    /// Serve an explicit (handler-controlled) file path, relative to the cwd.
    pub fn file(self: Files, path: []const u8) !Response {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io, path, self.arena, std.Io.Limit.limited(default_max_file_size),
        ) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.Forbidden,
            error.StreamTooLong => return error.PayloadTooLarge,
            else => return error.Internal,
        };
        return .{ .content_type = contentType(path), .body = bytes };
    }

    /// Safely serve `requested` under `root`, guarding TEXTUAL traversal
    /// (`..`/absolute/control bytes → 404). Note: symlinks inside `root` are
    /// followed (not resolved against `root`).
    pub fn dir(self: Files, root: []const u8, requested: []const u8) !Response {
        const joined = safeJoin(self.arena, root, requested) orelse return error.NotFound;
        return self.file(joined);
    }
};

const testing = std.testing;
const Io = std.Io;

test "Files.file reads an existing file and sets content type" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const f = Files{ .io = io, .arena = arena.allocator() };
    const r = try f.file("build.zig"); // present at the repo root (test cwd)
    try testing.expect(std.mem.indexOf(u8, r.body, "pub fn build") != null);
    try testing.expectEqualStrings("application/octet-stream", r.content_type); // .zig unmapped
}

test "Files.file missing path -> NotFound" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = Files{ .io = io, .arena = arena.allocator() };
    try testing.expectError(error.NotFound, f.file("this-does-not-exist.txt"));
}

test "Files.dir rejects traversal -> NotFound" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = Files{ .io = io, .arena = arena.allocator() };
    try testing.expectError(error.NotFound, f.dir(".", "../secret"));
}

test "Files.dir serves a safe path under root" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = Files{ .io = io, .arena = arena.allocator() };
    const r = try f.dir(".", "build.zig");
    try testing.expect(std.mem.indexOf(u8, r.body, "pub fn build") != null);
}

test "contentType maps known extensions, defaults otherwise" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentType("index.html"));
    try testing.expectEqualStrings("text/css", contentType("a/b/style.css"));
    try testing.expectEqualStrings("text/javascript", contentType("app.js"));
    try testing.expectEqualStrings("application/json", contentType("data.json"));
    try testing.expectEqualStrings("image/png", contentType("logo.png"));
    try testing.expectEqualStrings("application/octet-stream", contentType("noext"));
    try testing.expectEqualStrings("application/octet-stream", contentType("archive.tar.gz"));
}

test "safeJoin joins safe paths and rejects traversal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("static/a/b.txt", safeJoin(a, "static", "a/b.txt").?);
    try testing.expect(safeJoin(a, "static", "") == null);
    try testing.expect(safeJoin(a, "static", "..") == null);
    try testing.expect(safeJoin(a, "static", "a/../x") == null);
    try testing.expect(safeJoin(a, "static", "/etc/passwd") == null);
    try testing.expect(safeJoin(a, "static", "./x") == null);
    try testing.expect(safeJoin(a, "static", "a//b") == null);
}

test "safeJoin rejects control bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(safeJoin(arena.allocator(), "static", "a\x00b") == null);
}
