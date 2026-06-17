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
                try w.print("{s} {s} {d} {d:.3}ms {d}b\n", .{ @tagName(rec.method), rec.path, rec.status, ms, rec.bytes });
            },
            .json => {
                try w.writeAll("{\"method\":\"");
                try w.writeAll(@tagName(rec.method));
                try w.writeAll("\",\"path\":");
                try std.json.Stringify.encodeJsonString(rec.path, .{}, w);
                try w.print(",\"status\":{d},\"dur_us\":{d},\"bytes\":{d}}}\n", .{ rec.status, rec.duration_ns / 1000, rec.bytes });
            },
        }
        try w.flush(); // best-effort; on a fixed writer this errors but `log` swallows it (bytes already written)
    }
};

const testing = std.testing;

test "access logger: text format" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .text };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/users/42", .status = 200, .duration_ns = 412_000, .bytes = 18 });
    try testing.expectEqualStrings("GET /users/42 200 0.412ms 18b\n", w.buffered());
}

test "access logger: json format escapes path" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .json };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .POST, .path = "/a\"b", .status = 404, .duration_ns = 1_500_000, .bytes = 0 });
    try testing.expectEqualStrings("{\"method\":\"POST\",\"path\":\"/a\\\"b\",\"status\":404,\"dur_us\":1500,\"bytes\":0}\n", w.buffered());
}
