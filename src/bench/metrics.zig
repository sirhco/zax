//! Pure, testable helpers for the benchmark harness: a CLI `Config` parser and
//! summary statistics (`median`/`stddev`/`percentile`). No `zax`/`Io` imports —
//! pure std only, so the `test` blocks below run under `zig build test`.

const std = @import("std");

pub const Config = struct {
    iters: usize = 2_000_000,
    conns: usize = 8,
    reqs: usize = 5_000,
    samples: usize = 5,
    warmup: usize = 1,
};

pub const ParseError = error{ UnknownFlag, MissingValue, BadValue };

pub fn parse(args: []const []const u8) ParseError!Config {
    var cfg: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const field: *usize = if (std.mem.eql(u8, arg, "--iters"))
            &cfg.iters
        else if (std.mem.eql(u8, arg, "--conns"))
            &cfg.conns
        else if (std.mem.eql(u8, arg, "--reqs"))
            &cfg.reqs
        else if (std.mem.eql(u8, arg, "--samples"))
            &cfg.samples
        else if (std.mem.eql(u8, arg, "--warmup"))
            &cfg.warmup
        else
            return error.UnknownFlag;

        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        field.* = std.fmt.parseInt(usize, args[i], 10) catch return error.BadValue;
    }
    // Only `warmup` may be 0 (means "skip warmup").
    // `iters`, `conns`, `reqs`, and `samples` must be >= 1: zero iters gives
    // a 0/0 ns/op NaN in micro-benchmarks, and zero conns/reqs/samples cause
    // an out-of-bounds index into the latency slice in the e2e section.
    if (cfg.iters == 0 or cfg.conns == 0 or cfg.reqs == 0 or cfg.samples == 0)
        return error.BadValue;
    return cfg;
}

/// Sorts `samples` in place and returns the median (mean of the two middle values for even length; 0 for empty).
pub fn median(samples: []f64) f64 {
    if (samples.len == 0) return 0;
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const mid = samples.len / 2;
    if (samples.len % 2 == 1) return samples[mid];
    return (samples[mid - 1] + samples[mid]) / 2.0;
}

pub fn stddev(samples: []f64) f64 {
    const n = samples.len;
    if (n < 2) return 0;
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(n));
    var acc: f64 = 0;
    for (samples) |s| {
        const d = s - mean;
        acc += d * d;
    }
    return @sqrt(acc / @as(f64, @floatFromInt(n - 1)));
}

pub fn percentile(sorted: []const i96, p: usize) i96 {
    if (sorted.len == 0) return 0;
    const idx = @min((sorted.len * p) / 100, sorted.len - 1);
    return sorted[idx];
}

const testing = std.testing;

test "parse: defaults when no args" {
    const c = try parse(&.{});
    try testing.expectEqual(@as(usize, 2_000_000), c.iters);
    try testing.expectEqual(@as(usize, 8), c.conns);
    try testing.expectEqual(@as(usize, 5_000), c.reqs);
    try testing.expectEqual(@as(usize, 5), c.samples);
    try testing.expectEqual(@as(usize, 1), c.warmup);
}

test "parse: flags override" {
    const c = try parse(&.{ "--conns", "64", "--reqs", "2000", "--samples", "3", "--warmup", "0", "--iters", "10" });
    try testing.expectEqual(@as(usize, 10), c.iters);
    try testing.expectEqual(@as(usize, 64), c.conns);
    try testing.expectEqual(@as(usize, 2000), c.reqs);
    try testing.expectEqual(@as(usize, 3), c.samples);
    try testing.expectEqual(@as(usize, 0), c.warmup);
}

test "parse: errors" {
    try testing.expectError(error.UnknownFlag, parse(&.{"--nope"}));
    try testing.expectError(error.MissingValue, parse(&.{"--conns"}));
    try testing.expectError(error.BadValue, parse(&.{ "--conns", "x" }));
    try testing.expectError(error.BadValue, parse(&.{ "--samples", "0" }));
    // iters/conns/reqs must be >= 1; zero panics or produces NaN at runtime.
    try testing.expectError(error.BadValue, parse(&.{ "--iters", "0" }));
    try testing.expectError(error.BadValue, parse(&.{ "--conns", "0" }));
    try testing.expectError(error.BadValue, parse(&.{ "--reqs", "0" }));
}

test "median: odd and even, unsorted" {
    var a = [_]f64{ 3, 1, 2 };
    try testing.expectApproxEqAbs(@as(f64, 2), median(&a), 1e-9);
    var b = [_]f64{ 4, 1, 3, 2 };
    try testing.expectApproxEqAbs(@as(f64, 2.5), median(&b), 1e-9);
}

test "stddev: known values and n<2" {
    var a = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    try testing.expectApproxEqAbs(@as(f64, 2.13809), stddev(&a), 1e-4);
    var one = [_]f64{42};
    try testing.expectApproxEqAbs(@as(f64, 0), stddev(&one), 1e-9);
}

test "percentile: p50/p99/edges" {
    const s = [_]i96{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try testing.expectEqual(@as(i96, 60), percentile(&s, 50));
    try testing.expectEqual(@as(i96, 100), percentile(&s, 99));
    try testing.expectEqual(@as(i96, 100), percentile(&s, 100));
    try testing.expectEqual(@as(i96, 10), percentile(&s, 0));
}

test "parse: rejects negative and overflowing integers" {
    try testing.expectError(error.BadValue, parse(&.{ "--conns", "-1" }));
    try testing.expectError(error.BadValue, parse(&.{ "--iters", "99999999999999999999999" }));
}

test "median/stddev/percentile: empty inputs return 0" {
    var empty: [0]f64 = .{};
    try testing.expectApproxEqAbs(@as(f64, 0), median(&empty), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), stddev(&empty), 1e-9);
    const es: [0]i96 = .{};
    try testing.expectEqual(@as(i96, 0), percentile(&es, 50));
}
