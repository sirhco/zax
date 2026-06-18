//! Coarse per-worker timer wheel for tracking connection deadlines.
//!
//! Design:
//!   - `wheel_size` buckets, each a list of slot ids (connection indices).
//!   - A separate map `slot -> (bucket_index, deadline_ns)` enables O(1) remove.
//!   - Bucket assignment: `bucket = @intCast((deadline_ns / tick_ns) % wheel_size)`.
//!   - `advance` scans every bucket whose tick has elapsed since the last advance
//!     and expires any slot with `deadline_ns <= now_ns`. On small connection counts
//!     per worker this simple-scan approach is correct and fast enough; a precise
//!     hashed-wheel optimisation is deferred.
//!   - No real clock is used here. `now_ns` is always injected by the caller so
//!     tests can run deterministically.
//!   - Re-insert policy: `insert` is idempotent — if a slot is already tracked
//!     it is silently removed from its old bucket before being placed in the new
//!     one. Callers may also call `remove` then `insert` explicitly; both paths
//!     are safe.

const std = @import("std");
const testing = std.testing;

/// Entry stored in the per-slot map.
const Entry = struct {
    bucket: usize,
    deadline_ns: i96,
};

pub const TimerWheel = struct {
    gpa: std.mem.Allocator,
    tick_ns: i96, // tick_ms converted to nanoseconds
    wheel_size: usize,

    /// `buckets[i]` holds the slot ids whose deadline hashes to bucket i.
    buckets: []std.ArrayListUnmanaged(usize),

    /// slot id → Entry (bucket index + deadline).
    /// Using a HashMap keyed by usize.
    map: std.AutoHashMapUnmanaged(usize, Entry),

    /// The tick index up to which we have already advanced (exclusive).
    /// Initialised to 0; updated in `advance`.
    last_tick: i96,

    pub fn init(gpa: std.mem.Allocator, tick_ms: u32, wheel_size: usize) !TimerWheel {
        const buckets = try gpa.alloc(std.ArrayListUnmanaged(usize), wheel_size);
        for (buckets) |*b| b.* = .empty;
        return .{
            .gpa = gpa,
            .tick_ns = @as(i96, tick_ms) * std.time.ns_per_ms,
            .wheel_size = wheel_size,
            .buckets = buckets,
            .map = .{},
            .last_tick = 0,
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        for (self.buckets) |*b| b.deinit(self.gpa);
        self.gpa.free(self.buckets);
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// Insert (or re-insert) `slot` with the given `deadline_ns`.
    /// If the slot is already tracked it is moved to the correct bucket for the
    /// new deadline, so callers may call `insert` directly to update a deadline
    /// without a preceding `remove`.
    pub fn insert(self: *TimerWheel, slot: usize, deadline_ns: i96) void {
        // Remove from old bucket if already present.
        if (self.map.get(slot)) |old| {
            removeSingleFromBucket(&self.buckets[old.bucket], slot);
        }

        const bucket = self.bucketFor(deadline_ns);
        self.buckets[bucket].append(self.gpa, slot) catch @panic("OOM in TimerWheel.insert");
        self.map.put(self.gpa, slot, .{ .bucket = bucket, .deadline_ns = deadline_ns }) catch
            @panic("OOM in TimerWheel.insert");
    }

    /// Remove `slot` from the wheel. No-op if the slot is not tracked.
    pub fn remove(self: *TimerWheel, slot: usize) void {
        const entry = self.map.fetchRemove(slot) orelse return;
        removeSingleFromBucket(&self.buckets[entry.value.bucket], slot);
    }

    /// Advance the wheel to `now_ns`, calling `expired(slot)` for every tracked
    /// slot whose `deadline_ns <= now_ns`. Expired slots are removed from the
    /// wheel before the callback is invoked.
    ///
    /// Handles large jumps: all elapsed ticks (from the previous `last_tick`
    /// through the current tick) are scanned.
    pub fn advance(self: *TimerWheel, now_ns: i96, expired: *const fn (slot: usize) void) void {
        const now_tick = @divFloor(now_ns, self.tick_ns);

        // Collect expired slots first (avoid mutating the wheel under iteration).
        var to_expire = std.ArrayListUnmanaged(usize).empty;
        defer to_expire.deinit(self.gpa);

        // Number of ticks to scan — cap at wheel_size to avoid redundant full laps
        // when the jump is very large (all buckets get scanned at most once).
        const ticks_elapsed = now_tick - self.last_tick;
        const ticks_to_scan = @min(ticks_elapsed + 1, @as(i96, @intCast(self.wheel_size)));

        var t: i96 = 0;
        while (t < ticks_to_scan) : (t += 1) {
            const tick_idx = @mod(self.last_tick + t, @as(i96, @intCast(self.wheel_size)));
            const bucket_idx: usize = @intCast(tick_idx);
            const bucket = &self.buckets[bucket_idx];

            // Scan this bucket for slots due by now_ns.
            var i: usize = 0;
            while (i < bucket.items.len) {
                const s = bucket.items[i];
                const entry = self.map.get(s) orelse unreachable;
                if (entry.deadline_ns <= now_ns) {
                    to_expire.append(self.gpa, s) catch @panic("OOM in TimerWheel.advance");
                    // Remove from bucket (swap-remove for O(1)).
                    _ = bucket.swapRemove(i);
                    _ = self.map.remove(s);
                    // Don't increment i — the swapped element is now at position i.
                } else {
                    i += 1;
                }
            }
        }

        self.last_tick = now_tick;

        // Fire callbacks after all mutations are done.
        for (to_expire.items) |s| expired(s);
    }

    /// Returns milliseconds until the soonest deadline, or -1 if no timers are
    /// registered. Intended for use as the `epoll_wait` timeout.
    pub fn nextDeadlineMs(self: *TimerWheel, now_ns: i96) i32 {
        var it = self.map.valueIterator();
        var soonest: ?i96 = null;
        while (it.next()) |e| {
            if (soonest == null or e.deadline_ns < soonest.?) {
                soonest = e.deadline_ns;
            }
        }
        const d = soonest orelse return -1;
        const remaining_ns = d - now_ns;
        if (remaining_ns <= 0) return 0;
        // Convert ns → ms, rounding up so we don't return 0 when slightly > 0 ns remain.
        const ms = @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        // Clamp to i32 max.
        const clamped = @min(ms, @as(i96, std.math.maxInt(i32)));
        return @intCast(clamped);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    fn bucketFor(self: *const TimerWheel, deadline_ns: i96) usize {
        const tick = @divFloor(deadline_ns, self.tick_ns);
        const idx = @mod(tick, @as(i96, @intCast(self.wheel_size)));
        return @intCast(idx);
    }
};

/// Swap-remove `slot` from `bucket`. Panics if not found (caller must ensure
/// the slot is present).
fn removeSingleFromBucket(bucket: *std.ArrayListUnmanaged(usize), slot: usize) void {
    for (bucket.items, 0..) |s, i| {
        if (s == slot) {
            _ = bucket.swapRemove(i);
            return;
        }
    }
    @panic("TimerWheel: slot not found in expected bucket");
}

// =============================================================================
// Tests
// =============================================================================

/// File-scope capture list for test callbacks.
var g_captured: std.ArrayListUnmanaged(usize) = .empty;

fn captureExpired(slot: usize) void {
    g_captured.append(testing.allocator, slot) catch @panic("OOM in captureExpired");
}

test "advance: only slot at deadline fires" {
    var tw = try TimerWheel.init(testing.allocator, 10, 64);
    defer tw.deinit();
    g_captured = .empty;
    defer g_captured.deinit(testing.allocator);

    tw.insert(0, 100);
    tw.insert(1, 200);
    tw.insert(2, 300);

    tw.advance(150, captureExpired);

    try testing.expectEqual(@as(usize, 1), g_captured.items.len);
    try testing.expectEqual(@as(usize, 0), g_captured.items[0]);
}

test "remove: slot not fired after removal" {
    var tw = try TimerWheel.init(testing.allocator, 10, 64);
    defer tw.deinit();
    g_captured = .empty;
    defer g_captured.deinit(testing.allocator);

    tw.insert(5, 100);
    tw.insert(6, 200);
    tw.remove(5);

    tw.advance(150, captureExpired);

    try testing.expectEqual(@as(usize, 0), g_captured.items.len);
}

test "advance past multiple deadlines at once" {
    var tw = try TimerWheel.init(testing.allocator, 10, 64);
    defer tw.deinit();
    g_captured = .empty;
    defer g_captured.deinit(testing.allocator);

    tw.insert(0, 100);
    tw.insert(1, 200);
    tw.insert(2, 300);

    // First advance only fires slot 0.
    tw.advance(150, captureExpired);
    try testing.expectEqual(@as(usize, 1), g_captured.items.len);

    // Large jump: now both slot 1 (200) and slot 2 (300) should fire.
    tw.advance(350, captureExpired);
    try testing.expectEqual(@as(usize, 3), g_captured.items.len);

    // Verify slots 1 and 2 appear in the captured list (order may vary).
    const has1 = std.mem.indexOfScalar(usize, g_captured.items, 1) != null;
    const has2 = std.mem.indexOfScalar(usize, g_captured.items, 2) != null;
    try testing.expect(has1);
    try testing.expect(has2);
}

test "nextDeadlineMs: returns soonest ms; -1 when empty" {
    var tw = try TimerWheel.init(testing.allocator, 10, 64);
    defer tw.deinit();

    try testing.expectEqual(@as(i32, -1), tw.nextDeadlineMs(0));

    tw.insert(0, 1_000_000); // 1 ms in ns
    tw.insert(1, 2_000_000); // 2 ms in ns

    // now = 0 → soonest is 1_000_000 ns = 1 ms
    try testing.expectEqual(@as(i32, 1), tw.nextDeadlineMs(0));

    // now = 500_000 ns → still 0.5 ms away, rounds up to 1
    try testing.expectEqual(@as(i32, 1), tw.nextDeadlineMs(500_000));

    // now = 1_500_000 ns → soonest deadline is 1_000_000 (already past) → 0
    try testing.expectEqual(@as(i32, 0), tw.nextDeadlineMs(1_500_000));

    // now past all deadlines → 0
    try testing.expectEqual(@as(i32, 0), tw.nextDeadlineMs(3_000_000));
}

test "re-insert updates deadline (old time not fired, new time fires)" {
    var tw = try TimerWheel.init(testing.allocator, 10, 64);
    defer tw.deinit();
    g_captured = .empty;
    defer g_captured.deinit(testing.allocator);

    tw.insert(7, 100); // original deadline: 100
    tw.insert(7, 400); // re-insert with later deadline

    // Advancing past the old deadline should NOT fire slot 7.
    tw.advance(200, captureExpired);
    try testing.expectEqual(@as(usize, 0), g_captured.items.len);

    // Advancing past the new deadline SHOULD fire it.
    tw.advance(450, captureExpired);
    try testing.expectEqual(@as(usize, 1), g_captured.items.len);
    try testing.expectEqual(@as(usize, 7), g_captured.items[0]);
}
