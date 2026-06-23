//! file-upload — multipart/form-data uploads + static serving on zax. POST /upload
//! saves the uploaded file under ./uploads; GET /files/<name> serves it back.
//!
//!   zig build run    # serve on http://127.0.0.1:8084
//!   zig build test

const std = @import("std");
const zax = @import("zax");

const upload_dir = "uploads";

/// Minimal no-shared-state type. An empty anonymous struct literal works at
/// the call site but naming it avoids Zig 0.16 comptime complaints with
/// `App(*const struct{})` when the type is inferred differently each use.
const AppState = struct {};
const Api = zax.App(*const AppState);

fn home() zax.Response {
    return zax.Response.text("POST a file to /upload (field name: file); GET /files/<name>\n");
}

// Files is a non-body extractor — place it before Multipart.
// Multipart is a body extractor — must be the LAST parameter.
fn upload(f: zax.Files, a: zax.Alloc, mp: zax.Multipart) !zax.Response {
    const part = mp.file("file") orelse return zax.Response.fromStatus(.bad_request);
    const name = sanitize(part.filename orelse "upload.bin");

    // Ensure the uploads directory exists.
    try std.Io.Dir.cwd().createDirPath(f.io, upload_dir);

    // Build the full relative path for writing.
    const path = try std.fmt.allocPrint(a.value, upload_dir ++ "/{s}", .{name});

    // Write the uploaded bytes.
    try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = path, .data = part.data });
    const body = try std.fmt.allocPrint(a.value, "saved {s} ({d} bytes)\n", .{ path, part.data.len });
    var r = zax.Response.text(body);
    r.status = .created;
    return r;
}

fn serveFile(p: zax.Path(struct { name: []const u8 }), files: zax.Files) !zax.Response {
    return files.dir(upload_dir, p.value.name);
}

/// Strip path separators so an uploaded filename can't escape the upload dir.
fn sanitize(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

pub fn main(init: std.process.Init) !void {
    var state = AppState{};
    var app = try Api.init(init.gpa, &state, .{});
    defer app.deinit();
    try app.get("/", home);
    try app.post("/upload", upload);
    try app.get("/files/:name", serveFile);
    std.debug.print("file-upload listening on http://127.0.0.1:8084\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8084) });
}

const testing = std.testing;

test "sanitize strips directory components" {
    try testing.expectEqualStrings("evil.sh", sanitize("../../etc/evil.sh"));
    try testing.expectEqualStrings("ok.txt", sanitize("ok.txt"));
}
