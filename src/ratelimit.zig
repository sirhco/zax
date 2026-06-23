//! Token-bucket rate limiter — data layer (Task 1) + middleware factory (Task 2).
//!
//! Zero heap allocation; state lives in a static array baked into each
//! comptime instantiation of `StoreT`. Spinlock mirrors `src/observe.zig`.
//! Monotonic clock mirrors `src/reactor/conn.zig` (local copy, not an import).
//! `rateLimit(Ctx, config)` wraps the data layer into a `Chain(Ctx)` middleware.

const std = @import("std");
const builtin = @import("builtin");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

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
// Middleware factory
// ---------------------------------------------------------------------------

/// Returns a `Chain(Ctx)` middleware that enforces `config`'s token-bucket
/// rate limit.  Key extraction requires `ctx.req` (a `*const Request` with a
/// `.header(name)` method) and `ctx.trust_forwarded: bool`.
/// Each distinct comptime `config` value has its own independent static store.
pub fn rateLimit(comptime Ctx: type, comptime config: RateLimit) middleware.Chain(Ctx).Middleware {
    if (config.refill_per_sec <= 0) @compileError("rateLimit: refill_per_sec must be > 0");
    if (config.max_keys == 0) @compileError("rateLimit: max_keys must be > 0");
    if (config.key_max_len > std.math.maxInt(u16)) @compileError("rateLimit: key_max_len must be <= 65535");

    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        var store: StoreT(config) = .{};

        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            const Self = @This();
            const key = extractKey(Ctx, config, ctx);
            if (key == null and config.on_missing == .bypass) return next.run();
            const k = key orelse "\x00"; // .shared bucket — non-empty sentinel so key_len != 0
            const d = Self.store.check(k, nowNs());
            if (!d.allow) return try rlDeny(config, ctx.arena, d);
            const r = try next.run();
            return try rlDecorate(config, ctx.arena, r, d);
        }
    };
    return Impl.mw;
}

// ---------------------------------------------------------------------------
// Key extraction
// ---------------------------------------------------------------------------

/// Extract the rate-limit key from `ctx`.
/// Returns null when forwarded headers are not trusted, or when no usable
/// header is present (caller decides: bypass or shared bucket).
fn extractKey(comptime Ctx: type, comptime config: RateLimit, ctx: *const Ctx) ?[]const u8 {
    if (!ctx.trust_forwarded) return null;
    if (ctx.req.header(config.header)) |v| {
        // First hop of a comma-separated XFF list, trimmed of whitespace.
        const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
        const hop = std.mem.trim(u8, v[0..comma], " \t");
        if (hop.len > 0) return hop;
    }
    if (ctx.req.header(config.fallback_header)) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Header decoration helpers
// ---------------------------------------------------------------------------

/// Append the three `x-ratelimit-*` headers to `r` and return it.
fn rlDecorate(comptime config: RateLimit, arena: std.mem.Allocator, r0: Response, d: Decision) !Response {
    var r = try r0.withHeader(arena, "x-ratelimit-limit", try std.fmt.allocPrint(arena, "{d}", .{config.capacity}));
    r = try r.withHeader(arena, "x-ratelimit-remaining", try std.fmt.allocPrint(arena, "{d}", .{d.remaining}));
    r = try r.withHeader(arena, "x-ratelimit-reset", try std.fmt.allocPrint(arena, "{d}", .{d.reset_s}));
    return r;
}

/// Build a 429 response with `x-ratelimit-*` and `retry-after` headers.
fn rlDeny(comptime config: RateLimit, arena: std.mem.Allocator, d: Decision) !Response {
    var r = Response.fromStatus(.too_many_requests);
    r = try r.withHeader(arena, "x-ratelimit-limit", try std.fmt.allocPrint(arena, "{d}", .{config.capacity}));
    r = try r.withHeader(arena, "x-ratelimit-remaining", try std.fmt.allocPrint(arena, "{d}", .{d.remaining}));
    r = try r.withHeader(arena, "x-ratelimit-reset", try std.fmt.allocPrint(arena, "{d}", .{d.reset_s}));
    r = try r.withHeader(arena, "retry-after", try std.fmt.allocPrint(arena, "{d}", .{d.retry_after_s}));
    return r;
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

// ---------------------------------------------------------------------------
// Middleware tests (cors harness style)
// ---------------------------------------------------------------------------
// NOTE on shared static store: each distinct comptime config value produces a
// unique StoreT instantiation with its own static `var store`. Tests in THIS
// file share the static store across test runs when they use the same config.
// To prevent earlier tests from draining a later test's bucket:
//   - Each test uses a DISTINCT IP key (e.g. "10.0.0.1", "10.0.0.2", …), or
//   - Tests use distinct configs (different capacity / refill / max_keys).
// The configs below are crafted to keep keys isolated.

const testing = std.testing;
const Request = @import("http/request.zig").Request;
const Header = @import("http/request.zig").Header;
const Method = @import("http/request.zig").Method;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
    trust_forwarded: bool,
    ran: *bool,
};

fn fakeReq(method: Method, headers: []const Header) Request {
    return .{ .method = method, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

fn okHandler(ctx: *const TestCtx) anyerror!Response {
    ctx.ran.* = true;
    return Response.text("ok");
}

fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn runRl(arena: std.mem.Allocator, comptime config: RateLimit, req: *const Request, trust: bool, ran: *bool) !Response {
    const C = middleware.Chain(TestCtx);
    var ctx = TestCtx{ .req = req, .arena = arena, .trust_forwarded = trust, .ran = ran };
    const mws = [_]C.Middleware{rateLimit(TestCtx, config)};
    return C.run(&mws, &okHandler, &ctx);
}

// Config A: capacity=1, tiny refill — used for allow/deny tests.
// Each test uses a unique XFF IP so the shared static store doesn't interfere.
const cfgA: RateLimit = .{ .capacity = 1, .refill_per_sec = 0.001, .max_keys = 16, .key_max_len = 32 };

test "rl allow: first request runs handler; response carries x-ratelimit-* headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    // Use unique key "10.1.0.1" for this test.
    const req = fakeReq(.GET, &.{.{ .name = "x-forwarded-for", .value = "10.1.0.1" }});
    const r = try runRl(arena.allocator(), cfgA, &req, true, &ran);
    try testing.expect(ran);
    try testing.expect(hdr(r, "x-ratelimit-limit") != null);
    try testing.expect(hdr(r, "x-ratelimit-remaining") != null);
    try testing.expect(hdr(r, "x-ratelimit-reset") != null);
    try testing.expectEqualStrings("1", hdr(r, "x-ratelimit-limit").?);
}

test "rl deny: second request (same key) → 429, retry-after present, handler not called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Use unique key "10.1.0.2" for this test (drain + deny in sequence).
    const req = fakeReq(.GET, &.{.{ .name = "x-forwarded-for", .value = "10.1.0.2" }});

    // First request: allow (drains the 1-token bucket).
    var ran1 = false;
    _ = try runRl(arena.allocator(), cfgA, &req, true, &ran1);
    try testing.expect(ran1);

    // Second request: deny.
    var ran2 = false;
    const r2 = try runRl(arena.allocator(), cfgA, &req, true, &ran2);
    try testing.expect(!ran2);
    try testing.expectEqual(@import("http/response.zig").Status.too_many_requests, r2.status);
    try testing.expect(hdr(r2, "retry-after") != null);
    try testing.expect(hdr(r2, "x-ratelimit-limit") != null);
}

// Config B: untrusted → shared or bypass.
const cfgB_shared: RateLimit = .{ .capacity = 1, .refill_per_sec = 0.001, .max_keys = 4, .key_max_len = 32, .on_missing = .shared };
const cfgB_bypass: RateLimit = .{ .capacity = 1, .refill_per_sec = 0.001, .max_keys = 4, .key_max_len = 32, .on_missing = .bypass };

test "rl untrusted + shared: still rate-limited on shared (empty) key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // trust_forwarded=false → key=null → shared bucket "".
    const req = fakeReq(.GET, &.{});

    // First: allow (shared bucket gets claimed).
    var ran1 = false;
    _ = try runRl(arena.allocator(), cfgB_shared, &req, false, &ran1);
    try testing.expect(ran1);

    // Second: deny (shared bucket drained).
    var ran2 = false;
    const r2 = try runRl(arena.allocator(), cfgB_shared, &req, false, &ran2);
    try testing.expect(!ran2);
    try testing.expectEqual(@import("http/response.zig").Status.too_many_requests, r2.status);
}

test "rl untrusted + bypass: passes through, NO x-ratelimit-* headers, handler ran" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(.GET, &.{});
    var ran = false;
    const r = try runRl(arena.allocator(), cfgB_bypass, &req, false, &ran);
    try testing.expect(ran);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "x-ratelimit-limit"));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "x-ratelimit-remaining"));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "x-ratelimit-reset"));
}

// Config C: XFF first-hop isolation test.
const cfgC: RateLimit = .{ .capacity = 2, .refill_per_sec = 0.001, .max_keys = 16, .key_max_len = 32 };

test "rl XFF first-hop: different second hops but same first hop share a bucket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Both requests have first hop "1.2.3.4" (different second hops).
    const req1 = fakeReq(.GET, &.{.{ .name = "x-forwarded-for", .value = "1.2.3.4, 5.6.7.8" }});
    const req2 = fakeReq(.GET, &.{.{ .name = "x-forwarded-for", .value = "1.2.3.4, 9.9.9.9" }});

    var ran1 = false;
    _ = try runRl(arena.allocator(), cfgC, &req1, true, &ran1);
    try testing.expect(ran1);

    var ran2 = false;
    _ = try runRl(arena.allocator(), cfgC, &req2, true, &ran2);
    try testing.expect(ran2); // capacity=2, still has a token

    // Third request with same first hop → deny.
    var ran3 = false;
    const r3 = try runRl(arena.allocator(), cfgC, &req1, true, &ran3);
    try testing.expect(!ran3);
    try testing.expectEqual(@import("http/response.zig").Status.too_many_requests, r3.status);
}

// Config D: fallback header test.
const cfgD: RateLimit = .{ .capacity = 1, .refill_per_sec = 0.001, .max_keys = 8, .key_max_len = 32 };

test "rl fallback: no XFF, x-real-ip present (trusted) → keys on it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // No XFF, but x-real-ip is set.
    const req = fakeReq(.GET, &.{.{ .name = "x-real-ip", .value = "192.0.2.5" }});

    var ran1 = false;
    const r1 = try runRl(arena.allocator(), cfgD, &req, true, &ran1);
    try testing.expect(ran1);
    try testing.expectEqualStrings("1", hdr(r1, "x-ratelimit-limit").?);

    // Second request (same x-real-ip) → deny.
    var ran2 = false;
    const r2 = try runRl(arena.allocator(), cfgD, &req, true, &ran2);
    try testing.expect(!ran2);
    try testing.expectEqual(@import("http/response.zig").Status.too_many_requests, r2.status);
    try testing.expect(hdr(r2, "retry-after") != null);
}
