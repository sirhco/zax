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

const metrics = @import("bench/metrics.zig");
const counting = @import("bench/counting.zig");
const Config = metrics.Config;

const clock: Io.Clock = .awake; // monotonic

const usage_line = "usage: bench [--iters N] [--conns N] [--reqs N] [--samples N] [--warmup N]\n";

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, clock).toNanoseconds();
}

// --- App used by the e2e section ---
const Db = struct {};
const Api = zax.App(*const Db);

fn benchHandler() zax.Response {
    return zax.Response.text("ok");
}

// --- Fixtures used by the micro-benchmark chain section ---
const FakeCtx = struct {};
const FChn = zax.Chain(FakeCtx);
fn passThru(_: *const FakeCtx, next: *FChn.Next) anyerror!zax.Response {
    return next.run();
}
fn chainHandler(_: *const FakeCtx) anyerror!zax.Response {
    return zax.Response.text("ok");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // Collect process args (skipping argv[0]) into a plain []const []const u8.
    var arg_list: std.ArrayList([]const u8) = .empty;
    var it = init.minimal.args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| try arg_list.append(arena, a);

    const cfg = metrics.parse(arg_list.items) catch {
        var stderr_buf: [256]u8 = undefined;
        var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
        stderr_fw.interface.writeAll(usage_line) catch {};
        stderr_fw.interface.flush() catch {};
        std.process.exit(2);
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    try out.writeAll("=== Zax benchmark (ReleaseFast recommended) ===\n\n");
    try microBenchmarks(io, gpa, out, cfg);
    try endToEnd(io, gpa, out, cfg);
    try out.writeAll("\n");
    try memoryMetrics(io, gpa, out, cfg);
    try out.flush();
}

// ---------------------------------------------------------------------------
// Section A: micro-benchmarks
// ---------------------------------------------------------------------------
fn microBenchmarks(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, cfg: Config) !void {
    try out.print("-- micro-benchmarks (in-process, {d} iters x {d} samples) --\n", .{ cfg.iters, cfg.samples });

    const iters = cfg.iters;

    // Reused per-micro sample buffer holding ns/op for each sample.
    const buf = try gpa.alloc(f64, cfg.samples);
    defer gpa.free(buf);

    const nsPerOp = struct {
        fn f(total_ns: i96, n: usize) f64 {
            return @as(f64, @floatFromInt(@as(i64, @intCast(total_ns)))) / @as(f64, @floatFromInt(n));
        }
    }.f;

    // 1. HTTP/1.1 head parse.
    {
        const raw = "GET /users/42?active=true HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n";
        var hs: [zax.request.max_headers]zax.Header = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const p = zax.parser.parseHead(raw, &hs) catch unreachable;
                sink +%= p.request.path.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const p = zax.parser.parseHead(raw, &hs) catch unreachable;
                sink +%= p.request.path.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "parseHead", metrics.median(buf), metrics.stddev(buf));
    }

    // 2. Radix route match (static + param).
    {
        var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
        defer tree.deinit();
        (try tree.getOrPutSlot("/users/:id")).* = 1;
        var pb: [8]zax.radix.Param = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/users/42", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/users/42", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "radix match", metrics.median(buf), metrics.stddev(buf));
    }

    // 3. Response serialize to a fixed buffer.
    {
        const resp = zax.Response.text("hello world");
        var rbuf: [256]u8 = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fw = Io.Writer.fixed(&rbuf);
                resp.write(&fw) catch unreachable;
                sink +%= fw.buffered().len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fw = Io.Writer.fixed(&rbuf);
                resp.write(&fw) catch unreachable;
                sink +%= fw.buffered().len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "response write", metrics.median(buf), metrics.stddev(buf));
    }

    // 4. Middleware chain (3 pass-through middlewares wrapping a handler).
    {
        // `var` + escaped address forces the optimizer to treat the
        // comptime-known middleware slice as opaque, defeating devirtualization
        // and constant-folding of the whole chain under ReleaseFast.
        var mws = [_]FChn.Middleware{ &passThru, &passThru, &passThru };
        std.mem.doNotOptimizeAway(&mws);
        var fctx = FakeCtx{};
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const r = FChn.run(&mws, &chainHandler, &fctx) catch unreachable;
                std.mem.doNotOptimizeAway(r);
                sink +%= r.body.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const r = FChn.run(&mws, &chainHandler, &fctx) catch unreachable;
                std.mem.doNotOptimizeAway(r);
                sink +%= r.body.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "middleware x3", metrics.median(buf), metrics.stddev(buf));
    }

    // 5. Radix wildcard match.
    {
        var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
        defer tree.deinit();
        (try tree.getOrPutSlot("/assets/*path")).* = 1;
        var pb: [8]zax.radix.Param = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/assets/a/b/c", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/assets/a/b/c", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "radix wildcard", metrics.median(buf), metrics.stddev(buf));
    }

    // 6. Radix nested-static + param match.
    {
        var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
        defer tree.deinit();
        (try tree.getOrPutSlot("/api/v1/users/:id")).* = 1;
        var pb: [8]zax.radix.Param = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/api/v1/users/42", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const m = (tree.match("/api/v1/users/42", &pb) catch unreachable).?;
                sink +%= m.value + m.params.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "radix nested", metrics.median(buf), metrics.stddev(buf));
    }

    // 7. Path extractor (struct field from a captured param).
    {
        // Rotate the param value per iteration so the parse cannot be hoisted
        // out of the loop as a constant under ReleaseFast.
        const ids = [_][]const u8{ "42", "7", "1234", "99" };
        var fbuf: [512]u8 = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const params = [_]zax.Param{.{ .name = "id", .value = ids[i % ids.len] }};
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const p = zax.Path(struct { id: u64 }).fromContext(.{ .params = &params, .arena = fba.allocator() }) catch unreachable;
                std.mem.doNotOptimizeAway(p);
                sink +%= p.value.id;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const params = [_]zax.Param{.{ .name = "id", .value = ids[i % ids.len] }};
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const p = zax.Path(struct { id: u64 }).fromContext(.{ .params = &params, .arena = fba.allocator() }) catch unreachable;
                std.mem.doNotOptimizeAway(p);
                sink +%= p.value.id;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "Path extract", metrics.median(buf), metrics.stddev(buf));
    }

    // 8. Query extractor (bool + int from a query string).
    {
        const qreq = zax.Request{ .method = .GET, .target = "", .path = "", .query = "active=true&page=2", .version_minor = 1, .headers = &.{}, .body = "" };
        var fbuf: [512]u8 = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const q = zax.Query(struct { active: bool, page: u32 }).fromContext(.{ .req = &qreq, .arena = fba.allocator() }) catch unreachable;
                sink +%= @as(usize, @intFromBool(q.value.active)) + q.value.page;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const q = zax.Query(struct { active: bool, page: u32 }).fromContext(.{ .req = &qreq, .arena = fba.allocator() }) catch unreachable;
                sink +%= @as(usize, @intFromBool(q.value.active)) + q.value.page;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "Query extract", metrics.median(buf), metrics.stddev(buf));
    }

    // 9. Json extractor (small object from the request body).
    {
        const jreq = zax.Request{ .method = .POST, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "{\"id\":42,\"msg\":\"hello\"}" };
        var fbuf: [4096]u8 = undefined;
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            var sink: usize = 0;
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const j = zax.Json(struct { id: u64, msg: []const u8 }).fromContext(.{ .arena = fba.allocator(), .req = &jreq }) catch unreachable;
                sink +%= j.value.id + j.value.msg.len;
            }
            std.mem.doNotOptimizeAway(sink);
        }
        for (buf) |*slot| {
            var sink: usize = 0;
            const t0 = nowNs(io);
            var i: usize = 0;
            while (i < iters) : (i += 1) {
                var fba = std.heap.FixedBufferAllocator.init(&fbuf);
                const j = zax.Json(struct { id: u64, msg: []const u8 }).fromContext(.{ .arena = fba.allocator(), .req = &jreq }) catch unreachable;
                sink +%= j.value.id + j.value.msg.len;
            }
            const ns = nowNs(io) - t0;
            std.mem.doNotOptimizeAway(sink);
            slot.* = nsPerOp(ns, iters);
        }
        try report(out, "Json extract", metrics.median(buf), metrics.stddev(buf));
    }
    try out.writeAll("\n");
}

fn report(out: *Io.Writer, name: []const u8, median_ns: f64, sd_ns: f64) !void {
    const per_sec: f64 = if (median_ns > 0) 1_000_000_000.0 / median_ns else 0;
    try out.print("  {s:<16} {d:>8.1} ns/op  +/- {d:>6.1}  {d:>12.0} ops/sec\n", .{ name, median_ns, sd_ns, per_sec });
}

// ---------------------------------------------------------------------------
// Section B: end-to-end loopback load
// ---------------------------------------------------------------------------
/// Run one measured load: `conns` workers each issuing `reqs` requests over a
/// keep-alive connection. Fills `all` (length conns*reqs) with per-request
/// latencies (ns) and returns the load's throughput (req/sec).
fn runLoad(io: Io, gpa: std.mem.Allocator, port: u16, conns: usize, reqs: usize, all: []i96) !f64 {
    // Per-connection latency buffers (slices into `all`).
    const lat = try gpa.alloc([]i96, conns);
    defer gpa.free(lat);
    for (lat, 0..) |*slot, c| slot.* = all[c * reqs .. (c + 1) * reqs];

    const futs = try gpa.alloc(Io.Future(void), conns);
    defer gpa.free(futs);

    const t0 = nowNs(io);
    for (0..conns) |c| {
        futs[c] = io.async(worker, .{ io, port, lat[c] });
    }
    for (futs) |*f| f.await(io);
    const wall_ns = nowNs(io) - t0;

    const total = conns * reqs;
    const wall_s: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(wall_ns)))) / 1_000_000_000.0;
    return if (wall_s > 0) @as(f64, @floatFromInt(total)) / wall_s else 0;
}

fn endToEnd(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, cfg: Config) !void {
    const conns = cfg.conns;
    const reqs = cfg.reqs;
    try out.print("-- end-to-end load (loopback, {d} keep-alive conns x {d} reqs, {d} samples) --\n", .{ conns, reqs, cfg.samples });

    var db = Db{};
    var app = try Api.init(gpa, &db, .{});
    defer app.deinit();
    try app.get("/bench", benchHandler);

    const port: u16 = 18099;
    try app.bind(io, .{ .ip4 = .loopback(port) });
    var loop_fut = io.async(Api.acceptLoop, .{ &app, io });
    defer {
        app.requestShutdown(io);
        loop_fut.await(io);
    }

    const total = conns * reqs;

    // Warmup loads (discarded).
    {
        const scratch = try gpa.alloc(i96, total);
        defer gpa.free(scratch);
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            _ = try runLoad(io, gpa, port, conns, reqs, scratch);
        }
    }

    // Measured samples: throughput per sample, plus per-sample latency buffers
    // so we can report percentiles from the median-throughput sample.
    // Memory scales as ~samples × conns × reqs × 16 B (all samples retained
    // because the median-throughput sample is not known until all finish).
    const thr = try gpa.alloc(f64, cfg.samples);
    defer gpa.free(thr);
    const lat_per_sample = try gpa.alloc([]i96, cfg.samples);
    defer gpa.free(lat_per_sample);
    for (lat_per_sample) |*s| s.* = try gpa.alloc(i96, total);
    defer for (lat_per_sample) |s| gpa.free(s);

    for (0..cfg.samples) |s| {
        thr[s] = try runLoad(io, gpa, port, conns, reqs, lat_per_sample[s]);
    }

    // Median throughput; locate the sample whose throughput == median (or
    // nearest) and report latency percentiles from its latencies.
    const thr_copy = try gpa.alloc(f64, cfg.samples);
    defer gpa.free(thr_copy);
    @memcpy(thr_copy, thr);
    const med_thr = metrics.median(thr_copy); // sorts thr_copy
    const sd_thr = metrics.stddev(thr);

    var best: usize = 0;
    var best_diff: f64 = std.math.floatMax(f64);
    for (thr, 0..) |t, i| {
        const d = @abs(t - med_thr);
        if (d < best_diff) {
            best_diff = d;
            best = i;
        }
    }

    const all = lat_per_sample[best];
    std.mem.sort(i96, all, {}, std.sort.asc(i96));

    try out.print("  requests        {d} x {d} samples\n", .{ total, cfg.samples });
    try out.print("  throughput      {d:.0} req/sec  +/- {d:.0}\n", .{ med_thr, sd_thr });
    try out.print("  latency p50     {d:.1} us\n", .{us(metrics.percentile(all, 50))});
    try out.print("  latency p90     {d:.1} us\n", .{us(metrics.percentile(all, 90))});
    try out.print("  latency p99     {d:.1} us\n", .{us(metrics.percentile(all, 99))});
    try out.print("  latency max     {d:.1} us\n", .{us(all[all.len - 1])});
}

// ---------------------------------------------------------------------------
// Section C: memory metrics (bytes/req + peak RSS)
// ---------------------------------------------------------------------------
// Kept separate from `endToEnd` so the throughput numbers there stay free of
// the CountingAllocator's atomic-counter overhead. Only the SERVER's allocator
// is wrapped; the client side (runLoad) uses the raw gpa, so client
// allocations are not counted.
fn memoryMetrics(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, cfg: Config) !void {
    try out.print("-- memory (loopback, {d} conns x {d} reqs) --\n", .{ cfg.conns, cfg.reqs });

    var ca = counting.CountingAllocator{ .child = gpa };
    const cgpa = ca.allocator(); // server allocations counted

    var db = Db{};
    var app = try Api.init(cgpa, &db, .{});
    defer app.deinit();
    try app.get("/bench", benchHandler);

    const port: u16 = 18098;
    try app.bind(io, .{ .ip4 = .loopback(port) });
    var loop_fut = io.async(Api.acceptLoop, .{ &app, io });
    defer {
        app.requestShutdown(io);
        loop_fut.await(io);
    }

    const total = cfg.conns * cfg.reqs;

    // Warmup load(s): client uses the raw gpa (not counted).
    {
        const scratch = try gpa.alloc(i96, total);
        defer gpa.free(scratch);
        var w: usize = 0;
        while (w < cfg.warmup) : (w += 1) {
            _ = try runLoad(io, gpa, port, cfg.conns, cfg.reqs, scratch);
        }
    }

    const lat = try gpa.alloc(i96, total);
    defer gpa.free(lat);
    const before = ca.bytesAllocated();
    _ = try runLoad(io, gpa, port, cfg.conns, cfg.reqs, lat);
    const after = ca.bytesAllocated();

    // bytes/req includes amortized per-connection accept/buffers (each load opens
    // fresh connections), so this is steady-state allocator pressure including
    // amortized connection setup, not pure per-request cost.
    const per_req: f64 = @as(f64, @floatFromInt(after - before)) / @as(f64, @floatFromInt(total));
    try out.print("  bytes/req       {d:.1}\n", .{per_req});
    const rss = peakRssMb();
    if (rss < 0) {
        try out.writeAll("  peak RSS        n/a\n");
    } else {
        try out.print("  peak RSS        {d:.1} MB (process lifetime, all sections)\n", .{rss});
    }
}

// peakRssMb returns the process-lifetime RSS high-water mark via getrusage(SELF).
// This spans all bench sections (micro + e2e + memory), not memory alone.
fn peakRssMb() f64 {
    const builtin = @import("builtin");
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: f64 = @floatFromInt(ru.maxrss);
    // darwin/ios report bytes; linux reports KiB.
    const bytes = if (builtin.os.tag == .macos or builtin.os.tag == .ios) maxrss else maxrss * 1024.0;
    return bytes / (1024.0 * 1024.0);
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

fn us(ns: i96) f64 {
    return @as(f64, @floatFromInt(@as(i64, @intCast(ns)))) / 1000.0;
}

test {
    // Ensure the metrics module's unit tests run under `zig build test`
    // (the bench test target builds this module; runtime use alone does not
    // pull in an imported file's test blocks).
    _ = @import("bench/metrics.zig");
    _ = @import("bench/counting.zig");
}
