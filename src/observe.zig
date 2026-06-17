//! Observability primitives: a per-request observation record, a type-erased
//! observer interface (so the server can fan out to any sink without knowing its
//! type), and a thread-safe access logger that renders records as text or JSON.
//!
//! Depends only on `std` and the HTTP `Method` enum — no server/Io-backend
//! coupling beyond `std.Io.Writer`. Logging is best-effort: a failing writer
//! must never propagate into request serving.

const std = @import("std");
const request = @import("http/request.zig");

/// A single observed request outcome. All slices alias caller-owned memory and
/// are only valid for the duration of the observer call.
pub const AccessRecord = struct {
    method: request.Method,
    path: []const u8,
    status: u16,
    duration_ns: u64,
    bytes: usize,
    request_id: []const u8 = "",
};

/// Type-erased observer. `func` is invoked with the original `context` pointer
/// plus the record; implementations recover their concrete type via `@ptrCast`.
pub const Observer = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque, record: AccessRecord) void,
};

/// Thread-safe access logger. Serializes each record to `writer` while holding
/// an atomic spinlock, in either a compact human-readable text form or one JSON
/// object per line.
///
/// Why a spinlock and not `std.Thread.Mutex`: Zig 0.16 removed
/// `std.Thread.Mutex`; the replacement `std.Io.Mutex.lock` requires an `Io`
/// instance, which would couple this module to the Io backend and force an `io`
/// parameter into `Observer.func`. A tiny atomic spinlock keeps the dependency
/// surface to `std` alone. Critical sections are short (one formatted line), so
/// contention is brief.
pub const AccessLogger = struct {
    writer: *std.Io.Writer,
    format: Format = .text,
    locked: std.atomic.Value(bool) = .init(false),

    pub const Format = enum { text, json };

    pub fn observer(self: *AccessLogger) Observer {
        return .{ .context = self, .func = log };
    }

    fn log(ctx: *anyopaque, rec: AccessRecord) void {
        const self: *AccessLogger = @ptrCast(@alignCast(ctx));
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer self.locked.store(false, .release);
        self.writeRecord(rec) catch {}; // best-effort: logging must never break serving
    }

    fn writeRecord(self: *AccessLogger, rec: AccessRecord) !void {
        const w = self.writer;
        switch (self.format) {
            .text => {
                const ms = @as(f64, @floatFromInt(rec.duration_ns)) / 1_000_000.0;
                try w.print("{s} {s} {d} {d:.3}ms {d}b", .{ @tagName(rec.method), rec.path, rec.status, ms, rec.bytes });
                if (rec.request_id.len > 0) {
                    try w.writeAll(" id=");
                    try w.writeAll(rec.request_id);
                }
                try w.writeAll("\n");
            },
            .json => {
                try w.writeAll("{\"method\":\"");
                try w.writeAll(@tagName(rec.method));
                try w.writeAll("\",\"path\":");
                try std.json.Stringify.encodeJsonString(rec.path, .{}, w);
                try w.print(",\"status\":{d},\"dur_us\":{d},\"bytes\":{d}", .{ rec.status, rec.duration_ns / 1000, rec.bytes });
                if (rec.request_id.len > 0) {
                    // Embedded raw (not encodeJsonString'd): request ids are
                    // validated to a safe charset [A-Za-z0-9._-] before reaching
                    // here (see server computeRid/validRid), so they contain no
                    // JSON-special chars. If that contract changes, escape this.
                    try w.writeAll(",\"request_id\":\"");
                    try w.writeAll(rec.request_id);
                    try w.writeAll("\"");
                }
                try w.writeAll("}\n");
            },
        }
        try w.flush(); // best-effort; on a fixed writer this errors but `log` swallows it (bytes already written)
    }
};

/// Thread-safe metrics collector implementing `Observer`. Aggregates request
/// outcomes into lock-free atomic counters and a latency histogram, then exposes
/// either a value-snapshot or Prometheus text exposition.
///
/// No lock needed: every field is an independent monotonic atomic counter; a
/// snapshot reads them without a consistent point-in-time guarantee (acceptable
/// for metrics). Histogram bucket bounds are in nanoseconds (matching
/// `AccessRecord.duration_ns`) but exposed in seconds per Prometheus convention.
pub const Metrics = struct {
    pub const bucket_bounds_ns = [_]u64{ 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000, 10_000_000_000 };

    /// `le` label strings, parallel to `bucket_bounds_ns`. Hardcoded so the
    /// exposition renders exact literals (e.g. "0.005", "2.5", "10") without
    /// float-formatting ambiguity.
    pub const bucket_labels = [_][]const u8{ "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10" };

    total: std.atomic.Value(u64) = .init(0),
    class: [6]std.atomic.Value(u64) = @splat(.init(0)),
    bytes_total: std.atomic.Value(u64) = .init(0),
    duration_sum_ns: std.atomic.Value(u64) = .init(0),
    buckets: [bucket_bounds_ns.len]std.atomic.Value(u64) = @splat(.init(0)),

    pub fn observer(self: *Metrics) Observer {
        return .{ .context = self, .func = record };
    }

    fn record(ctx: *anyopaque, rec: AccessRecord) void {
        const self: *Metrics = @ptrCast(@alignCast(ctx));
        _ = self.total.fetchAdd(1, .monotonic);
        const cls = rec.status / 100;
        if (cls >= 1 and cls <= 5) _ = self.class[cls].fetchAdd(1, .monotonic);
        _ = self.bytes_total.fetchAdd(rec.bytes, .monotonic);
        _ = self.duration_sum_ns.fetchAdd(rec.duration_ns, .monotonic);
        for (bucket_bounds_ns, 0..) |bound, i| {
            if (rec.duration_ns <= bound) {
                _ = self.buckets[i].fetchAdd(1, .monotonic);
                break;
            }
        }
    }

    pub fn snapshot(self: *const Metrics) MetricsSnapshot {
        var s: MetricsSnapshot = undefined;
        s.total = self.total.load(.monotonic);
        for (&self.class, 0..) |*c, i| s.class[i] = c.load(.monotonic);
        s.bytes_total = self.bytes_total.load(.monotonic);
        s.duration_sum_ns = self.duration_sum_ns.load(.monotonic);
        for (&self.buckets, 0..) |*b, i| s.buckets[i] = b.load(.monotonic);
        return s;
    }

    pub fn writePrometheus(self: *const Metrics, w: *std.Io.Writer) !void {
        const s = self.snapshot();
        try w.writeAll(
            \\# HELP zax_requests_total Total HTTP requests by status class.
            \\# TYPE zax_requests_total counter
            \\
        );
        try w.print("zax_requests_total{{class=\"1xx\"}} {d}\n", .{s.class[1]});
        try w.print("zax_requests_total{{class=\"2xx\"}} {d}\n", .{s.class[2]});
        try w.print("zax_requests_total{{class=\"3xx\"}} {d}\n", .{s.class[3]});
        try w.print("zax_requests_total{{class=\"4xx\"}} {d}\n", .{s.class[4]});
        try w.print("zax_requests_total{{class=\"5xx\"}} {d}\n", .{s.class[5]});
        try w.writeAll(
            \\# HELP zax_response_bytes_total Total response body bytes.
            \\# TYPE zax_response_bytes_total counter
            \\
        );
        try w.print("zax_response_bytes_total {d}\n", .{s.bytes_total});
        try w.writeAll(
            \\# HELP zax_request_duration_seconds Request duration in seconds.
            \\# TYPE zax_request_duration_seconds histogram
            \\
        );
        var cum: u64 = 0;
        for (bucket_labels, 0..) |label, i| {
            cum += s.buckets[i];
            try w.print("zax_request_duration_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ label, cum });
        }
        try w.print("zax_request_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{s.total});
        const sum_s = @as(f64, @floatFromInt(s.duration_sum_ns)) / 1e9;
        try w.print("zax_request_duration_seconds_sum {d:.6}\n", .{sum_s});
        try w.print("zax_request_duration_seconds_count {d}\n", .{s.total});
    }
};

/// Point-in-time copy of `Metrics` counters (plain `u64`s, no atomics).
pub const MetricsSnapshot = struct {
    total: u64,
    class: [6]u64,
    bytes_total: u64,
    duration_sum_ns: u64,
    buckets: [Metrics.bucket_bounds_ns.len]u64,
};

const testing = std.testing;

test "metrics: counts, classes, bytes, sum, buckets" {
    var m = Metrics{};
    const obs = m.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/a", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });
    obs.func(obs.context, .{ .method = .GET, .path = "/b", .status = 200, .duration_ns = 30_000_000, .bytes = 20 });
    obs.func(obs.context, .{ .method = .GET, .path = "/c", .status = 404, .duration_ns = 2_000_000_000, .bytes = 0 });
    obs.func(obs.context, .{ .method = .GET, .path = "/d", .status = 500, .duration_ns = 30_000_000_000, .bytes = 5 });

    const s = m.snapshot();
    try testing.expectEqual(@as(u64, 4), s.total);
    try testing.expectEqual(@as(u64, 2), s.class[2]);
    try testing.expectEqual(@as(u64, 1), s.class[4]);
    try testing.expectEqual(@as(u64, 1), s.class[5]);
    try testing.expectEqual(@as(u64, 35), s.bytes_total);
    try testing.expectEqual(@as(u64, 3_000_000 + 30_000_000 + 2_000_000_000 + 30_000_000_000), s.duration_sum_ns);
    try testing.expectEqual(@as(u64, 1), s.buckets[0]); // 3ms -> le 0.005
    try testing.expectEqual(@as(u64, 1), s.buckets[3]); // 30ms -> le 0.05
    try testing.expectEqual(@as(u64, 1), s.buckets[8]); // 2s -> le 2.5
    // 30s -> no bucket (>10s), only in total/+Inf
}

test "metrics: prometheus exposition" {
    var m = Metrics{};
    const obs = m.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/a", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });
    obs.func(obs.context, .{ .method = .GET, .path = "/b", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.writePrometheus(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "zax_requests_total{class=\"2xx\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_bucket{le=\"0.005\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_bucket{le=\"+Inf\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_count 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_response_bytes_total 20") != null);
}

test "access logger: text format" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .text };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/users/42", .status = 200, .duration_ns = 412_000, .bytes = 18 });
    try testing.expectEqualStrings("GET /users/42 200 0.412ms 18b\n", w.buffered());
}

test "access logger: includes request_id when present (text + json)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .text };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/p", .status = 200, .duration_ns = 412_000, .bytes = 18, .request_id = "abc-123" });
    try testing.expectEqualStrings("GET /p 200 0.412ms 18b id=abc-123\n", w.buffered());

    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    var lg2 = AccessLogger{ .writer = &w2, .format = .json };
    const obs2 = lg2.observer();
    obs2.func(obs2.context, .{ .method = .GET, .path = "/p", .status = 200, .duration_ns = 412_000, .bytes = 18, .request_id = "abc-123" });
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"request_id\":\"abc-123\"") != null);
}

test "access logger: json format escapes path" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .json };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .POST, .path = "/a\"b", .status = 404, .duration_ns = 1_500_000, .bytes = 0 });
    try testing.expectEqualStrings("{\"method\":\"POST\",\"path\":\"/a\\\"b\",\"status\":404,\"dur_us\":1500,\"bytes\":0}\n", w.buffered());
}
