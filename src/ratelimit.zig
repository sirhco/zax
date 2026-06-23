//! Token-bucket rate limiter — data layer (Task 1).
//!
//! Zero heap allocation; state lives in a static array baked into each
//! comptime instantiation of `StoreT`. Spinlock mirrors `src/observe.zig`.
//! Monotonic clock mirrors `src/reactor/conn.zig` (local copy, not an import).
//! Task 2 will add the `rateLimit` middleware factory on top of this layer.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Comptime configuration for the rate limiter.
pub const RateLimit = struct {
    capacity: u32 = 60,
    refill_per_sec: f64 = 1.0,
    max_keys: usize = 1024,
    key_max_len: usize = 64,
    header: []const u8 = "x-forwarded-for",
    fallback_header: []const u8 = "x-real-ip",
    on_missing: enum { shared, bypass } = .shared,
};

// ---------------------------------------------------------------------------
// Decision
// ---------------------------------------------------------------------------

pub const Decision = struct {
    allow: bool,
    remaining: u32,
    reset_s: u64,
    retry_after_s: u64,
};

// ---------------------------------------------------------------------------
// Monotonic clock (local replication of src/reactor/conn.zig:119-130)
// ---------------------------------------------------------------------------

/// Current monotonic time in nanoseconds.
/// Uses the Linux vDSO clock_gettime on Linux, std.c on other platforms.
pub fn nowNs() i128 {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    }
}

// ---------------------------------------------------------------------------
// StoreT — comptime-parameterised token-bucket store
// ---------------------------------------------------------------------------

/// Returns a Store type whose slot array is sized by `config`.
/// Each distinct comptime `config` value produces a unique type with its own
/// static storage, so multiple `rateLimit(Ctx, config)` instantiations are
/// independent.
pub fn StoreT(comptime config: RateLimit) type {
    if (config.refill_per_sec <= 0) {
        @compileError("rateLimit: refill_per_sec must be > 0");
    }

    return struct {
        const Self = @This();

        const Slot = struct {
            key: [config.key_max_len]u8 = undefined,
            key_len: u16 = 0, // 0 == empty
            tokens: f64 = 0,
            last_refill_ns: i128 = 0,
        };

        slots: [config.max_keys]Slot = .{Slot{}} ** config.max_keys,
        locked: std.atomic.Value(bool) = .init(false),

        // --- spinlock (verbatim from src/observe.zig:53-57) ---

        pub fn lock(self: *Self) void {
            while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }

        pub fn unlock(self: *Self) void {
            self.locked.store(false, .release);
        }

        // --- key helpers ---

        /// Truncate `key` to `key_max_len` for storage and comparison.
        fn truncated(key: []const u8) []const u8 {
            return key[0..@min(key.len, config.key_max_len)];
        }

        /// Linear scan; returns pointer to matching slot or null.
        /// Caller must hold the lock.
        pub fn find(self: *Self, key: []const u8) ?*Slot {
            const k = truncated(key);
            for (&self.slots) |*slot| {
                if (slot.key_len != 0 and
                    std.mem.eql(u8, slot.key[0..slot.key_len], k))
                {
                    return slot;
                }
            }
            return null;
        }

        /// Return first empty slot; if full, evict the slot with the smallest
        /// `tokens` value.  Initialises the claimed slot.
        /// Caller must hold the lock.
        pub fn claim(self: *Self, key: []const u8, now: i128) *Slot {
            const k = truncated(key);

            // First pass: find an empty slot.
            for (&self.slots) |*slot| {
                if (slot.key_len == 0) {
                    initSlot(slot, k, now);
                    return slot;
                }
            }

            // No empty slot — evict the one with fewest tokens.
            var victim: *Slot = &self.slots[0];
            for (self.slots[1..]) |*slot| {
                if (slot.tokens < victim.tokens) {
                    victim = slot;
                }
            }
            initSlot(victim, k, now);
            return victim;
        }

        fn initSlot(slot: *Slot, key: []const u8, now: i128) void {
            @memcpy(slot.key[0..key.len], key);
            slot.key_len = @intCast(key.len);
            slot.tokens = @floatFromInt(config.capacity);
            slot.last_refill_ns = now;
        }

        // --- token-bucket math ---

        /// Refill, consume, and return a decision.
        /// Takes the spinlock internally; `now` is passed in for determinism.
        /// Never calls `nowNs()` — that is the caller's responsibility.
        pub fn check(self: *Self, key: []const u8, now: i128) Decision {
            self.lock();
            defer self.unlock();

            const cap_f: f64 = @floatFromInt(config.capacity);
            const refill: f64 = config.refill_per_sec;

            const slot = self.find(key) orelse self.claim(key, now);

            // Refill — clamp elapsed to >= 0 so clock-backwards is safe.
            const elapsed_raw: f64 = @as(f64, @floatFromInt(now - slot.last_refill_ns));
            const elapsed_s: f64 = @max(0.0, elapsed_raw) / 1e9;
            slot.tokens = @min(cap_f, slot.tokens + elapsed_s * refill);
            slot.last_refill_ns = now;

            // Consume.
            const allow = slot.tokens >= 1.0;
            if (allow) slot.tokens -= 1.0;

            // Decision fields (all post-consume).
            const remaining: u32 = @intFromFloat(@floor(slot.tokens));

            // reset_s: time until bucket is full; 0 when already full.
            const deficit = cap_f - slot.tokens;
            const reset_s: u64 = if (deficit <= 0.0)
                0
            else
                @intFromFloat(@ceil(deficit / refill));

            // retry_after_s: how long until one token is available; 0 on allow.
            const retry_after_s: u64 = if (allow)
                0
            else
                @max(1, @as(u64, @intFromFloat(@ceil((1.0 - slot.tokens) / refill))));

            return .{
                .allow = allow,
                .remaining = remaining,
                .reset_s = reset_s,
                .retry_after_s = retry_after_s,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "burst: 3 allows from full, 4th denies" {
    const S = StoreT(.{ .capacity = 3, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const now: i128 = 1_000_000_000_000;

    const d1 = store.check("client1", now);
    try std.testing.expect(d1.allow);
    try std.testing.expectEqual(@as(u32, 2), d1.remaining);

    const d2 = store.check("client1", now);
    try std.testing.expect(d2.allow);
    try std.testing.expectEqual(@as(u32, 1), d2.remaining);

    const d3 = store.check("client1", now);
    try std.testing.expect(d3.allow);
    try std.testing.expectEqual(@as(u32, 0), d3.remaining);

    const d4 = store.check("client1", now);
    try std.testing.expect(!d4.allow);
    try std.testing.expectEqual(@as(u32, 0), d4.remaining);
}

test "reset_s == 0 when bucket deficit is zero (capacity == 0)" {
    // reset_s == 0 requires deficit <= 0.  With capacity=0 the bucket starts
    // empty and can never refill to 1 token, so every call is a deny with
    // tokens==0 and deficit==0-0==0 → reset_s==0.
    const S = StoreT(.{ .capacity = 0, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const now: i128 = 1_000_000_000_000;
    const d = store.check("k", now);
    try std.testing.expect(!d.allow);
    try std.testing.expectEqual(@as(u32, 0), d.remaining);
    try std.testing.expectEqual(@as(u64, 0), d.reset_s);
}

test "refill: after deny, advance 1s gives one allow; remaining and reset correct" {
    const S = StoreT(.{ .capacity = 3, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const t0: i128 = 1_000_000_000_000;

    // Drain the bucket fully.
    _ = store.check("ip", t0);
    _ = store.check("ip", t0);
    _ = store.check("ip", t0);
    const deny = store.check("ip", t0);
    try std.testing.expect(!deny.allow);
    try std.testing.expect(deny.retry_after_s >= 1);

    // Advance 1 second → one token refilled, consume it.
    const t1 = t0 + 1_000_000_000;
    const d = store.check("ip", t1);
    try std.testing.expect(d.allow);
    try std.testing.expectEqual(@as(u32, 0), d.remaining); // consumed the 1 refilled token
    // tokens == 0; reset_s = ceil((3-0)/1) = 3
    try std.testing.expectEqual(@as(u64, 3), d.reset_s);
}

test "retry_after_s >= 1 on deny" {
    const S = StoreT(.{ .capacity = 1, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const now: i128 = 500_000_000_000;
    _ = store.check("x", now); // allow, drains to 0 tokens
    const d = store.check("x", now); // deny
    try std.testing.expect(!d.allow);
    try std.testing.expect(d.retry_after_s >= 1);
}

test "eviction: 3rd key evicts the lower-tokens slot" {
    const S = StoreT(.{ .capacity = 3, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const t0: i128 = 1_000_000_000_000;

    // Slot 0: "aaa" — drain all 3 tokens → tokens == 0.
    _ = store.check("aaa", t0);
    _ = store.check("aaa", t0);
    _ = store.check("aaa", t0);

    // Slot 1: "bbb" — drain 1 token → tokens == 2.
    _ = store.check("bbb", t0);

    // 3rd distinct key "ccc" must evict "aaa" (tokens=0 < bbb tokens=2).
    const d = store.check("ccc", t0);
    try std.testing.expect(d.allow); // fresh slot starts at cap=3, consume 1 → remaining=2

    // "bbb" must still be present.
    const find_bbb = store.find("bbb");
    try std.testing.expect(find_bbb != null);

    // "aaa" was evicted by "ccc".
    const find_aaa = store.find("aaa");
    try std.testing.expect(find_aaa == null);
}

test "clock-backwards: now < last_refill_ns gives no extra tokens and no panic" {
    const S = StoreT(.{ .capacity = 3, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });
    var store = S{};
    const t0: i128 = 1_000_000_000_000;

    // Drain all tokens at t0.
    _ = store.check("k", t0);
    _ = store.check("k", t0);
    _ = store.check("k", t0);
    const deny_at_t0 = store.check("k", t0);
    try std.testing.expect(!deny_at_t0.allow);

    // Call with a timestamp before t0 (clock skew / backwards).
    // elapsed_s = max(0, negative) = 0 → no extra tokens → still deny.
    const t_past = t0 - 5_000_000_000;
    const d = store.check("k", t_past);
    try std.testing.expect(!d.allow);
    try std.testing.expectEqual(@as(u32, 0), d.remaining);
}
