# Design — Rate-Limit Middleware (built-in middleware)

**Status:** Proposed 2026-06-23. Branch `feat/rate-limit-middleware` (off main `e8a1c81`). Target release **v0.17.0**.

## Context

zax ships built-in middleware as comptime factories: `src/cors.zig` (`cors(Ctx, config)`) and `src/compress.zig` (`compress(Ctx, config)`). Both follow the house style — comptime config, zero heap allocation, response headers appended into the request arena, in-file `test {}` blocks, no socket in tests.

A rate limiter is the next built-in on the roadmap (the other remaining gap is ETag/conditional requests). It throttles request floods and returns `429 Too Many Requests` with the standard `Retry-After` and `X-RateLimit-*` headers.

The one structural difference vs cors/compress: a rate limiter holds **runtime-mutable state** (a token bucket per client). We preserve the zero-heap house style by keeping that state in a **static `var` table** baked into each comptime instantiation of the factory, guarded by the atomic spinlock pattern from `src/observe.zig` (this Zig 0.16 has no `std.Thread.Mutex`).

## Goal

A built-in `rateLimit(Ctx, config)` middleware, mounted like any other:

```zig
try app.use(zax.rateLimit(Api.Context, .{ .capacity = 60, .refill_per_sec = 1.0 }));
```

Token-bucket throttling, keyed per client (forwarded headers, honored only when the app trusts proxies), emitting `X-RateLimit-Limit/Remaining/Reset` on every response and `Retry-After` on a 429.

### Decisions (confirmed with Chris)

- **Algorithm: token bucket.** `capacity` = burst ceiling and the value reported as `X-RateLimit-Limit`; `refill_per_sec` = sustained rate. Bursts up to capacity allowed, smooth steady-state.
- **Key: by request header.** `x-forwarded-for` (first hop, before first comma) with `x-real-ip` fallback, honored **only when `ctx.trust_forwarded`**. When no key is derivable, `on_missing` selects a shared bucket (default) or pass-through.
- **Headers: full `X-RateLimit-*` set** on every response, plus `Retry-After` on a 429.
- **Zero heap.** Static comptime-sized slot table inside the factory instantiation; no allocator beyond the request arena (used only for formatting header value strings).

## Background (verified against current code)

- **Factory shape** — `src/cors.zig:25-43`: `pub fn cors(comptime Ctx, comptime config: Cors) middleware.Chain(Ctx).Middleware`, inner `Impl` struct with `fn mw(ctx: *const Ctx, next: *Next) anyerror!Response`, returns `Impl.mw`.
- **Chain** — `src/middleware.zig:15-47`: `Middleware = *const fn(ctx, next) anyerror!Response`; `Next.run()` advances the chain; not calling `next` short-circuits.
- **Spinlock** — `src/observe.zig:43,53-57`: `locked: std.atomic.Value(bool) = .init(false)`; lock = `while (cmpxchgWeak(false,true,.acquire,.monotonic) != null) spinLoopHint();`; unlock = `store(false,.release)` in `defer`.
- **Response** — `src/http/response.zig:358-365` `withHeader(arena, name, value)`; `:219-221` `fromStatus`; `:57` `too_many_requests = 429`.
- **Context** — `src/extract/extract.zig:24` `trust_forwarded: bool`, `arena`, `req`. `src/http/request.zig:49-54` `req.header(name)` case-insensitive. `src/extract/forwarded.zig:46-50` first-hop XFF parse (split on first comma, trim " \t").
- **Monotonic clock** — `src/reactor/conn.zig:119-130` `monotonicNow() i96` via `clock_gettime(.MONOTONIC)` (Linux vDSO / `std.c` on macOS). No `std.time.Instant`/`nanoTimestamp` use in `src/`.
- **Integer→string** — `std.fmt.allocPrint(arena, "{d}", .{n})`, the existing pattern (`src/cors.zig:69`).
- **Export site** — `src/root.zig:75-78` (cors/compress block); `refAllDecls` test `:110-114` auto-runs in-file tests.

## Components

### New: `src/ratelimit.zig`

**Config (comptime):**
```zig
pub const RateLimit = struct {
    capacity: u32 = 60,
    refill_per_sec: f64 = 1.0,
    max_keys: usize = 1024,
    key_max_len: usize = 64,
    header: []const u8 = "x-forwarded-for",
    fallback_header: []const u8 = "x-real-ip",
    on_missing: enum { shared, bypass } = .shared,
};
```

**Static store (inside `Impl`, one per comptime instantiation):**
```zig
const Slot = struct {
    key: [config.key_max_len]u8 = undefined,
    key_len: u16 = 0,          // 0 == empty
    tokens: f64 = 0,
    last_refill_ns: i128 = 0,
};
const Store = struct {
    slots: [config.max_keys]Slot = .{.{}} ** config.max_keys,
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(self) / unlock(self)          // observe.zig spinlock, verbatim
    fn check(self, key, now) Decision      // refill+consume under lock; linear scan
    fn find(self, key) ?*Slot              // linear scan
    fn claim(self, key, now) *Slot         // free slot, else evict min-tokens slot
};
const Decision = struct { allow: bool, remaining: u32, reset_s: u64, retry_after_s: u64 };
```

**Token-bucket math** (`check`, holding the lock, `now` passed in — deterministic for tests):
```
elapsed_s   = max(0, now - slot.last_refill_ns) / 1e9   // clamp → clock-backwards safe
slot.tokens = min(capacity, slot.tokens + elapsed_s * refill_per_sec)
slot.last_refill_ns = now
allow = slot.tokens >= 1.0;  if allow: slot.tokens -= 1.0
remaining     = floor(slot.tokens)                            // post-consume
reset_s       = ceil((capacity - slot.tokens) / refill_per_sec)   // 0 if full
retry_after_s = max(1, ceil((1.0 - slot.tokens) / refill_per_sec))  // deny only
```
`@compileError` if `refill_per_sec <= 0`.

**Factory + middleware:**
```zig
pub fn rateLimit(comptime Ctx: type, comptime config: RateLimit) middleware.Chain(Ctx).Middleware {
    // inner Impl { var store; fn mw(ctx, next) {...} }  → returns Impl.mw
}
```
`mw` flow:
- `extractKey(ctx)`: `!ctx.trust_forwarded` → null; else first-hop of `config.header`; else trimmed `config.fallback_header`; else null.
- key null & `.bypass` → `next.run()` (no headers). Else key = `""` (shared bucket under `.shared`).
- `store.lock(); d = store.check(key, nowNs()); store.unlock();`
- **deny:** `Response.fromStatus(.too_many_requests)` + `x-ratelimit-limit/remaining/reset` + `retry-after`; return WITHOUT `next`.
- **allow:** `var r = try next.run();` then append the three `x-ratelimit-*` headers (mirrors `cors.zig:60-75` decorate).

**Local clock:** `fn nowNs() i128` replicates `clock_gettime(.MONOTONIC)` (per `conn.zig:119-130`) — local replication, not a reactor import, matching the `observe.zig` "replicate not couple" precedent.

### Modified: `src/root.zig`
Add after the compress exports (`:75-78`):
```zig
pub const RateLimit = @import("ratelimit.zig").RateLimit;
pub const rateLimit = @import("ratelimit.zig").rateLimit;
```

### Unchanged
No change to `middleware.zig`, `cors.zig`, `compress.zig`, the server, or any extractor. Purely additive.

## Data flow

request → `mw` → derive key → lock store → refill+consume bucket → unlock →
allow: run handler, append `X-RateLimit-*` → response.
deny: build 429 + `Retry-After` + `X-RateLimit-*`, skip handler → response.

## Error handling / edge cases

- **No key / untrusted:** `on_missing` — `.shared` (one coarse bucket, default) or `.bypass` (pass-through, no headers).
- **Table full:** evict the min-`tokens` slot (computed in the same scan); new key starts at `capacity`. Best-effort under high key cardinality; documented.
- **Same-key concurrency:** entire refill+consume is one critical section under the spinlock; no read-modify-write race.
- **`capacity == 0`:** deny-all (tokens never reach 1.0). Acceptable; not an error.
- **Clock backwards:** `max(0, …)` clamp — no spurious refill, no negative tokens; `i128` signed delta.
- **Key longer than `key_max_len`:** truncate on store AND compare. Default 64 covers IPv6 (~45 bytes). Documented; no hashing (keeps it alloc-free and simple).
- **Hostile header:** the key is only stored/compared, never echoed into a response header → no CRLF/header injection via the key.

## Behavior change & test impact

Purely additive — no existing behavior changes, no breaking change. New in-file tests only; all zero-socket / arena-based (no port binding). Library suite must stay green at 367/370 + new tests.

## Testing

Unit (Task 1, pure, inject `now`): consume to 0 then deny; refill after injected elapsed re-allows; `remaining`/`reset`/`retry_after` formula values; eviction picks min-tokens slot when full; burst up to capacity.
Middleware (Task 2, cors harness `TestCtx{req, arena, trust_forwarded, ran}` + `Chain.run`): allow appends 3 headers + runs handler; deny → 429 + retry-after + `ran == false`; untrusted → bypass/shared per config; XFF first-hop; fallback header.
Integration (Task 3): `rateLimit` composed with another middleware in one chain — ordering + decoration survive.

## Docs

`docs/CHANGELOG.md` Added entry (target v0.17.0); usage snippet in docs examples. Document: keyed only when `trust_forwarded`; static-table sizing; eviction = drop min-tokens key; >`key_max_len` truncation; comptime-memoization caveat (identical `(Ctx, config)` may share one static store — vary config for independent buckets per mount point).

## Out of scope (future)

Distributed/shared-store limiting; per-route differing limits beyond separate factory instantiations; sliding-window or leaky-bucket variants; configurable response body; limiting by API key / arbitrary key fn (only the comptime-memoization-safe header keying is in this slice).
