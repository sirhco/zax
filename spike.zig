//! Phase 0 ground-truth spike. Proves the load-bearing Zig 0.16.0 assumptions
//! Zax depends on, against the installed compiler:
//!   1. "Juicy Main": `main(init: std.process.Init)` hands us gpa + io.
//!   2. The std.Io interface: io.async / Future.await for concurrency.
//!   3. std.Io.net: listen / accept / Stream reader+writer round-trip.
//!   4. Zero-copy reads: Io.Reader.takeDelimiterInclusive returns a slice into
//!      the caller-owned read buffer (no heap copy).
//!   5. Comptime handler-signature reflection (the extractor machinery).
//! Run: `zig run spike.zig`  — prints "spike ok" and exits 0 on success.

const std = @import("std");
const Io = std.Io;

// (5) Comptime reflection sanity — the exact machinery the extractor dispatcher
// will use to map handler params -> extractors and build the call tuple.
fn sampleHandler(a: u32, b: []const u8) u64 {
    _ = b;
    return a;
}
comptime {
    const info = @typeInfo(@TypeOf(sampleHandler)).@"fn";
    if (info.params.len != 2) @compileError("params introspection broken");
    if (info.return_type.? != u64) @compileError("return_type introspection broken");
    const Args = std.meta.ArgsTuple(@TypeOf(sampleHandler));
    if (@typeInfo(Args).@"struct".fields.len != 2) @compileError("ArgsTuple broken");
}

const port: u16 = 18080;

fn serveOne(io: Io, server: *Io.net.Server) void {
    serveOneFallible(io, server) catch |err| {
        std.debug.print("server task error: {s}\n", .{@errorName(err)});
    };
}

fn serveOneFallible(io: Io, server: *Io.net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

    var wbuf: [4096]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const w = &sw.interface;

    // (4) zero-copy: `line` is a slice into rbuf, not a fresh allocation.
    const line = try r.takeDelimiterInclusive('\n');
    const inside = @intFromPtr(line.ptr) >= @intFromPtr(&rbuf) and
        @intFromPtr(line.ptr) < @intFromPtr(&rbuf) + rbuf.len;
    if (!inside) return error.NotZeroCopy;

    try w.writeAll(line);
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    // (1) Juicy Main gives us both an allocator and an Io for free.
    const io = init.io;

    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // (2) run the accept+echo concurrently; (3) it's Io-agnostic.
    var fut = io.async(serveOne, .{ io, &server });
    defer fut.await(io);

    // Client side: connect, send a line, read the echo back.
    var caddr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var cstream = try caddr.connect(io, .{ .mode = .stream });
    defer cstream.close(io);

    var cwbuf: [64]u8 = undefined;
    var csw = cstream.writer(io, &cwbuf);
    try csw.interface.writeAll("ping\n");
    try csw.interface.flush();

    var crbuf: [64]u8 = undefined;
    var csr = cstream.reader(io, &crbuf);
    const echoed = try csr.interface.takeDelimiterInclusive('\n');

    if (!std.mem.eql(u8, echoed, "ping\n")) return error.EchoMismatch;
    std.debug.print("spike ok: round-trip + zero-copy + reflection verified\n", .{});
}
