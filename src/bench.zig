//! Zax benchmark harness. Run with `zig build bench` (ReleaseFast).
//!
//! Two sections:
//!   A. Micro-benchmarks — in-process cost of the hot-path components
//!      (HTTP parse, radix match, response serialize). No sockets, no client
//!      overhead: these are the cleanest numbers.
//!   B. End-to-end load — a loopback server driven by N concurrent keep-alive
//!      connections, reporting throughput and latency percentiles.
//!
//! Caveats (read before quoting any number): loopback only (no real network),
//! single machine, the client shares the same process/Io as the server, and
//! these are NOT comparative benchmarks against other frameworks. Treat them as
//! reproducible indicators of Zax's own overhead, not marketing figures.

const std = @import("std");
const zax = @import("zax");
const Io = std.Io;
const net = std.Io.net;

const clock: Io.Clock = .awake; // monotonic

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, clock).toNanoseconds();
}

// --- App used by the e2e section ---
const Db = struct {};
const Api = zax.App(*const Db);

fn benchHandler() zax.Response {
    return zax.Response.text("ok");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    try out.writeAll("=== Zax benchmark (ReleaseFast recommended) ===\n\n");
    try microBenchmarks(io, out);
    try endToEnd(io, gpa, out);
    try out.flush();
}

// ---------------------------------------------------------------------------
// Section A: micro-benchmarks
// ---------------------------------------------------------------------------
fn microBenchmarks(io: Io, out: *Io.Writer) !void {
    try out.writeAll("-- micro-benchmarks (in-process) --\n");

    const iters: usize = 2_000_000;

    // 1. HTTP/1.1 head parse.
    {
        const raw = "GET /users/42?active=true HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
        var hs: [zax.request.max_headers]zax.Header = undefined;
        var sink: usize = 0;
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const p = zax.parser.parseHead(raw, &hs) catch unreachable;
            sink +%= p.request.path.len;
        }
        const ns = nowNs(io) - t0;
        std.mem.doNotOptimizeAway(sink);
        try report(out, "parseHead", iters, ns);
    }

    // 2. Radix route match (static + param).
    {
        var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
        defer tree.deinit();
        (try tree.getOrPutSlot("/users/:id")).* = 1;
        var pb: [8]zax.radix.Param = undefined;
        var sink: usize = 0;
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const m = (tree.match("/users/42", &pb) catch unreachable).?;
            sink +%= m.value + m.params.len;
        }
        const ns = nowNs(io) - t0;
        std.mem.doNotOptimizeAway(sink);
        try report(out, "radix match", iters, ns);
    }

    // 3. Response serialize to a fixed buffer.
    {
        const resp = zax.Response.text("hello world");
        var buf: [256]u8 = undefined;
        var sink: usize = 0;
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var w = Io.Writer.fixed(&buf);
            resp.write(&w) catch unreachable;
            sink +%= w.buffered().len;
        }
        const ns = nowNs(io) - t0;
        std.mem.doNotOptimizeAway(sink);
        try report(out, "response write", iters, ns);
    }
    try out.writeAll("\n");
}

fn report(out: *Io.Writer, name: []const u8, iters: usize, total_ns: i96) !void {
    const ns_per: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(total_ns)))) / @as(f64, @floatFromInt(iters));
    const per_sec: f64 = if (ns_per > 0) 1_000_000_000.0 / ns_per else 0;
    try out.print("  {s:<16} {d:>8.1} ns/op   {d:>12.0} ops/sec\n", .{ name, ns_per, per_sec });
}

// ---------------------------------------------------------------------------
// Section B: end-to-end loopback load
// ---------------------------------------------------------------------------
const conns = 8;
const reqs_per_conn = 5_000;

fn endToEnd(io: Io, gpa: std.mem.Allocator, out: *Io.Writer) !void {
    try out.print("-- end-to-end load (loopback, {d} keep-alive conns x {d} reqs) --\n", .{ conns, reqs_per_conn });

    var db = Db{};
    var app = try Api.init(gpa, &db, .{});
    defer app.deinit();
    try app.get("/bench", benchHandler);

    const port: u16 = 18099;
    try app.bind(io, .{ .ip4 = .loopback(port) });
    var loop_fut = io.async(Api.acceptLoop, .{ &app, io });

    // Per-connection latency buffers.
    const lat = try gpa.alloc([]i96, conns);
    defer gpa.free(lat);
    for (lat) |*slot| slot.* = try gpa.alloc(i96, reqs_per_conn);
    defer for (lat) |slot| gpa.free(slot);

    const t0 = nowNs(io);
    var futs: [conns]Io.Future(void) = undefined;
    for (0..conns) |c| {
        futs[c] = io.async(worker, .{ io, port, lat[c] });
    }
    for (&futs) |*f| f.await(io);
    const wall_ns = nowNs(io) - t0;

    app.requestShutdown(io);
    loop_fut.await(io);

    // Aggregate latencies.
    const total = conns * reqs_per_conn;
    var all = try gpa.alloc(i96, total);
    defer gpa.free(all);
    var n: usize = 0;
    for (lat) |slot| {
        @memcpy(all[n .. n + slot.len], slot);
        n += slot.len;
    }
    std.mem.sort(i96, all, {}, std.sort.asc(i96));

    const wall_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(wall_ns)))) / 1_000_000_000.0;
    const rps: f64 = @as(f64, @floatFromInt(total)) / wall_s;
    try out.print("  requests        {d}\n", .{total});
    try out.print("  wall            {d:.3} s\n", .{wall_s});
    try out.print("  throughput      {d:.0} req/sec\n", .{rps});
    try out.print("  latency p50     {d:.1} us\n", .{us(pct(all, 50))});
    try out.print("  latency p90     {d:.1} us\n", .{us(pct(all, 90))});
    try out.print("  latency p99     {d:.1} us\n", .{us(pct(all, 99))});
    try out.print("  latency max     {d:.1} us\n", .{us(all[all.len - 1])});
}

fn worker(io: Io, port: u16, out_lat: []i96) void {
    workerFallible(io, port, out_lat) catch {};
}

fn workerFallible(io: Io, port: u16, out_lat: []i96) !void {
    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = try caddr.connect(io, .{ .mode = .stream });
    defer cs.close(io);
    var rb: [4096]u8 = undefined;
    var cr = cs.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var cw = cs.writer(io, &wb);
    const r = &cr.interface;

    for (out_lat) |*slot| {
        const t0 = nowNs(io);
        try cw.interface.writeAll("GET /bench HTTP/1.1\r\nHost: x\r\n\r\n");
        try cw.interface.flush();
        skipResponse(r);
        slot.* = nowNs(io) - t0;
    }
}

/// Consume one Content-Length-framed response from the reader.
fn skipResponse(r: *Io.Reader) void {
    while (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n") == null) {
        r.fillMore() catch return;
    }
    const he = (std.mem.indexOf(u8, r.buffered(), "\r\n\r\n") orelse return) + 4;
    const clen = parseClen(r.buffered()[0..he]);
    while (r.buffered().len < he + clen) {
        r.fillMore() catch return;
    }
    r.toss(@min(he + clen, r.buffered().len));
}

fn parseClen(head: []const u8) usize {
    const key = "content-length: ";
    const start = std.mem.indexOf(u8, head, key) orelse return 0;
    const i = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, head, i, '\r') orelse return 0;
    return std.fmt.parseInt(usize, head[i..end], 10) catch 0;
}

fn pct(sorted: []const i96, p: usize) i96 {
    if (sorted.len == 0) return 0;
    const idx = @min((sorted.len * p) / 100, sorted.len - 1);
    return sorted[idx];
}

fn us(ns: i96) f64 {
    return @as(f64, @floatFromInt(@as(i64, @intCast(ns)))) / 1000.0;
}
