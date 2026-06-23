# Rate-Limit Middleware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Spec: `docs/superpowers/specs/2026-06-23-rate-limit-middleware-design.md`.

**Goal:** A built-in `rateLimit(Ctx, config)` token-bucket middleware in a new `src/ratelimit.zig`, mirroring `src/cors.zig`. Keyed per client via forwarded headers (honored only when `ctx.trust_forwarded`), zero heap (static comptime-sized slot table guarded by an atomic spinlock), emitting full `X-RateLimit-*` headers + `Retry-After` on 429.

## Global Constraints

- **Zig 0.16.** NO `std.Thread.Mutex` — use the atomic spinlock from `src/observe.zig:43,53-57` VERBATIM (`std.atomic.Value(bool)` + `cmpxchgWeak(false,true,.acquire,.monotonic)` + `spinLoopHint()`; unlock `store(false,.release)` in `defer`).
- **House style:** comptime factory → inner `Impl` struct → return `Impl.mw` (exactly like `cors.zig:25-43`). Config is comptime. Runtime bucket state is a static `var store: Store` inside `Impl` — NO heap allocation. Only the request `arena` is used, and only to format header value strings.
- **Monotonic clock:** replicate `clock_gettime(.MONOTONIC)` LOCALLY in `ratelimit.zig` (copy the body of `src/reactor/conn.zig:119-130`, returning `i128`). Do NOT import from `reactor/` — avoids lib→reactor coupling (the `observe.zig:34-39` precedent: replicate, don't couple).
- **Testable time:** the bucket math (`Store.check`) takes `now: i128` as a parameter. ONLY `mw` calls `nowNs()`. This keeps Task 1 tests deterministic.
- **Header names lowercase** (framework convention, see `cors.zig`).
- **Additive only:** do not modify `middleware.zig`, `cors.zig`, `compress.zig`, the server, or extractors. The only edit outside the new file is the `root.zig` export (Task 3).
- **Build/test:** `zig build test --summary all`, SINGLE-INSTANCE only (never run two concurrent `zig build test` — WS e2e binds fixed ports and concurrent runs deadlock). Baseline 367/370 (3 pre-existing macOS skips). Final suite must be ≥ baseline + new tests, no regressions.

## File Structure

- Create: `src/ratelimit.zig` (Tasks 1 + 2 — Task 1 lands config/store/math + unit tests; Task 2 adds the factory/mw + mw tests in the same file).
- Modify: `src/root.zig` (Task 3 — two export lines).
- Modify: `docs/CHANGELOG.md` + docs example snippet (Task 4).

---

### Task 1: Config + Store + token-bucket math (pure, no HTTP)

Delivers the data layer of `src/ratelimit.zig`: the `RateLimit` config struct, the static `Store`/`Slot` types with the spinlock, the token-bucket math, the local monotonic clock, and pure unit tests. No middleware wiring yet — everything here is testable without HTTP.

**Files:** Create `src/ratelimit.zig`; modify `src/root.zig` (export, so tests run — see Step 0).

**Produces:** `RateLimit`, `Slot`, `Store` (+ `lock`/`unlock`/`find`/`claim`/`check`), `Decision`, `nowNs()`.

> **ORDERING (resolved):** `zig build test` runs a module's `test {}` blocks only when that module is reachable from `src/root.zig` (via `refAllDecls(@This())`, `root.zig:113-117`). So `ratelimit.zig` MUST be exported from `root.zig` for Task 1's tests to execute. Do the export in this task (Step 0). Task 3 then only adds the integration test.

- [ ] **Step 0: Export early (so tests run).**
  In `src/root.zig`, immediately after the compress exports (`:77-78`), add:
  ```zig
  pub const RateLimit = @import("ratelimit.zig").RateLimit;
  pub const rateLimit = @import("ratelimit.zig").rateLimit;
  ```
  `rateLimit` does not exist until Task 2 — so for THIS task export only `RateLimit` (the config type) and add `pub const rateLimit` in Task 2 Step 1. Exporting `RateLimit` makes `refAllDecls` pull `ratelimit.zig` into analysis so its `test {}` blocks run. Confirm the test count rises after Step 5.

- [ ] **Step 1: File header + imports + config.**
  Doc comment (purpose: token-bucket rate limiter, zero-heap static store, mirrors cors.zig/observe.zig). Imports: `std`, `middleware = @import("middleware.zig")`, `Response = @import("http/response.zig").Response`. Define `pub const RateLimit` exactly as the spec:
  `capacity: u32 = 60`, `refill_per_sec: f64 = 1.0`, `max_keys: usize = 1024`, `key_max_len: usize = 64`, `header: []const u8 = "x-forwarded-for"`, `fallback_header: []const u8 = "x-real-ip"`, `on_missing: enum { shared, bypass } = .shared`.

- [ ] **Step 2: `nowNs()`.**
  `fn nowNs() i128` replicating `src/reactor/conn.zig:119-130` (`builtin.os.tag == .linux` → `std.os.linux.clock_gettime(.MONOTONIC, &ts)`, else `std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)`), returning `i128` seconds*1e9 + nsec.

- [ ] **Step 3: `Slot`, `Decision`, and a generic `Store(comptime config)` builder.**
  Because the static store lives inside the comptime factory, define the store as a comptime function `fn StoreT(comptime config: RateLimit) type` (or build `Slot`/`Store` inside the factory's `Impl`). For Task 1 testability, expose a comptime helper, e.g. `fn StoreT(comptime config: RateLimit) type` returning a struct with:
  - `slots: [config.max_keys]Slot = .{.{}} ** config.max_keys` where `Slot = struct { key: [config.key_max_len]u8 = undefined, key_len: u16 = 0, tokens: f64 = 0, last_refill_ns: i128 = 0 }`.
  - `locked: std.atomic.Value(bool) = .init(false)`.
  - `fn lock`/`fn unlock` — spinlock verbatim from observe.zig.
  - `fn find(self, key) ?*Slot` — linear scan, match `key_len != 0 and eql(slot.key[0..key_len], key)`.
  - `fn claim(self, key, now) *Slot` — return first empty slot (`key_len == 0`); if none, evict the slot with the smallest `tokens`. Initialize claimed slot: copy `key` truncated to `key_max_len` into `slot.key`, set `key_len`, `tokens = capacity`, `last_refill_ns = now`.
  - `fn check(self, key, now) Decision` — does NOT lock itself (caller locks in `mw`; tests lock too, OR make `check` lock internally and have `mw` call a non-locking inner — pick ONE: simplest is `check` locks internally via `lock()`/`defer unlock()`, and `mw` just calls `store.check(key, nowNs())`. Tests then call `check` directly). Implement refill+consume+Decision per the spec math.

  NOTE for implementer: decide lock placement and state it in your report. Recommended: `check` takes the lock internally (`self.lock(); defer self.unlock();`) so both `mw` and tests call `check` uniformly. `nowNs()` stays OUT of `check`.

- [ ] **Step 4: token-bucket math in `check`.** Per spec:
  ```
  slot = find(key) orelse claim(key, now);
  elapsed_s = @max(0, now - slot.last_refill_ns) / 1e9   // f64 division
  slot.tokens = @min(cap_f, slot.tokens + elapsed_s * config.refill_per_sec)
  slot.last_refill_ns = now
  allow = slot.tokens >= 1.0; if allow: slot.tokens -= 1.0
  remaining = @intFromFloat(@floor(slot.tokens))
  reset_s = ceilDiv((cap_f - slot.tokens), refill)  → 0 if full
  retry_after_s = if allow 0 else @max(1, ceil((1.0 - slot.tokens)/refill))
  ```
  Use `@compileError("rateLimit: refill_per_sec must be > 0")` guard at factory entry — but for Task 1 you can guard inside `StoreT`/a comptime check reachable from tests. Use `f64` throughout; cast to integer only for header/Decision fields.

- [ ] **Step 5: unit tests (`test {}` blocks).**
  Use a concrete instantiation, e.g. `const S = StoreT(.{ .capacity = 3, .refill_per_sec = 1.0, .max_keys = 2, .key_max_len = 8 });`. Tests (inject `now` as integer nanoseconds):
  - burst: 3 allows from full, 4th denies (`now` fixed).
  - refill: after deny, advance `now` by 1s → one allow again; `remaining`/`reset` correct.
  - `retry_after_s >= 1` on deny; `reset_s == 0` when full.
  - eviction: fill both slots (2 keys), 3rd distinct key evicts the lower-tokens slot.
  - clock-backwards: `now` smaller than `last_refill_ns` → no extra tokens, no panic.

- [ ] **Step 6: Commit.**
  ```bash
  git add src/ratelimit.zig src/root.zig
  git commit -m "feat(ratelimit): config + static token-bucket store + math (task 1)"
  ```
  Verify `zig build test --summary all` green (single-instance) AND that your new tests actually ran (count rose vs baseline 367).

---

### Task 2: Factory + middleware + key extraction + header decoration

Wires the data layer into a `Chain(Ctx)` middleware. Adds the `rateLimit()` factory, `Impl.mw`, key extraction, and allow/deny header decoration. Tests mirror the cors harness.

**Files:** Modify `src/ratelimit.zig`.

**Consumes:** Task 1's `RateLimit`, `StoreT`/`Store`, `Decision`, `nowNs()`.
**Produces:** `pub fn rateLimit(comptime Ctx, comptime config) middleware.Chain(Ctx).Middleware`.

- [ ] **Step 1: Factory + static store + finish the export.**
  `pub fn rateLimit(comptime Ctx: type, comptime config: RateLimit) middleware.Chain(Ctx).Middleware`. Guard `if (config.refill_per_sec <= 0) @compileError(...)`. Inner `const Impl = struct { var store: StoreT(config) = .{}; ... fn mw(...) ... }; return Impl.mw;`. `const Next = middleware.Chain(Ctx).Next;`. Then add the second export line in `src/root.zig` (after the `RateLimit` line added in Task 1): `pub const rateLimit = @import("ratelimit.zig").rateLimit;`.

- [ ] **Step 2: `extractKey`.**
  Nested helper `fn extractKey(ctx: *const Ctx) ?[]const u8` (or file-level taking `comptime config`): if `!ctx.trust_forwarded` return null; `if (ctx.req.header(config.header)) |v| return firstHop(v);` (firstHop = up to first ',', trimmed of " \t" — replicate `src/extract/forwarded.zig:46-50`); else `if (ctx.req.header(config.fallback_header)) |v| return std.mem.trim(u8, v, " \t");` else null.

- [ ] **Step 3: `mw` flow.**
  ```
  const key = extractKey(ctx);
  if (key == null and config.on_missing == .bypass) return next.run();
  const k = key orelse "";              // .shared bucket
  const d = Impl.store.check(k, nowNs());
  if (!d.allow) return try deny(ctx.arena, d);
  var r = try next.run();
  return try decorate(ctx.arena, r, d);
  ```

- [ ] **Step 4: `deny` + `decorate`.**
  `decorate(arena, r, d)`: chain `r = try r.withHeader(arena, "x-ratelimit-limit", fmt(capacity)); ...remaining...reset...; return r;` where `fmt(n) = try std.fmt.allocPrint(arena, "{d}", .{n})`. `deny(arena, d)`: `var r = Response.fromStatus(.too_many_requests);` append the same 3 `x-ratelimit-*` headers + `retry-after` = `fmt(d.retry_after_s)`; `return r;`. Limit value = `config.capacity`.

- [ ] **Step 5: middleware tests (cors harness style).**
  `const TestCtx = struct { req: *const Request, arena: std.mem.Allocator, trust_forwarded: bool, ran: *bool };` plus `fakeReq`, `hdr`, `runRl` helpers mirroring `cors.zig:86-131`. Use small config (`capacity = 1`, `refill_per_sec = 0.001` so refill is negligible within a test). Tests:
  - allow path: first request runs handler (`ran == true`), response carries `x-ratelimit-limit/remaining/reset`.
  - deny path: second request (same key, trusted, XFF set) → status 429, `retry-after` present, `ran == false`.
  - untrusted (`trust_forwarded = false`): `.shared` → still limited on shared key; with `.bypass` → passes through, no `x-ratelimit-*` headers.
  - XFF first-hop: `x-forwarded-for: "1.2.3.4, 5.6.7.8"` keys on `1.2.3.4`.
  - fallback: no XFF but `x-real-ip` present (trusted) → keys on it.
  Requires `Request` import: `const Request = @import("http/request.zig").Request;` (test-only; mirror cors.zig's test imports).

- [ ] **Step 6: Commit.**
  ```bash
  git add src/ratelimit.zig
  git commit -m "feat(ratelimit): rateLimit factory, mw, key extraction, header decoration (task 2)"
  ```
  Verify `zig build test --summary all` green.

---

### Task 3: Root export + integration test

Exposes the middleware from the package root and proves it composes in a chain.

**Files:** Modify `src/ratelimit.zig` (integration test). The `root.zig` exports were added in Tasks 1–2; this task only verifies them and adds the composition test.

- [ ] **Step 1: Verify exports.** Confirm both `pub const RateLimit` and `pub const rateLimit` exist in `src/root.zig` (added in Tasks 1–2) and that `zax.rateLimit` resolves. No new export edit expected; if the `rateLimit` line is missing, add it.

- [ ] **Step 2: Integration test.** In `src/ratelimit.zig`, a `test {}` composing `rateLimit(TestCtx, cfg)` with a second trivial middleware (e.g. a header-adder) in one `Chain(TestCtx).run(&.{rl, other}, handler, &ctx)`. Assert: handler ran, BOTH the other middleware's header and the `x-ratelimit-*` headers are present on the allow path; on the deny path the 429 is returned and the downstream middleware/handler did not run.

- [ ] **Step 3: Commit.**
  ```bash
  git add src/ratelimit.zig
  git commit -m "test(ratelimit): middleware composition integration test (task 3)"
  ```
  Verify `zig build test --summary all` green; note new test count.

---

### Task 4: Docs / CHANGELOG

**Files:** Modify `docs/CHANGELOG.md`; add a usage snippet to the docs examples (e.g. `docs/examples.md` if a middleware/cookbook section fits, else a short section in the README middleware list — implementer confirms where cors/compress are documented and mirrors that).

- [ ] **Step 1: CHANGELOG.** Add an `Added` bullet under `[Unreleased]` (or a new `[0.17.0]` block — match existing CHANGELOG convention): built-in `rateLimit(Ctx, config)` token-bucket middleware; keyed by forwarded header (trusted-proxy only); full `X-RateLimit-*` + `Retry-After`; zero-heap static store.

- [ ] **Step 2: Usage snippet + caveats.** Document, mirroring how cors/compress are documented:
  - `try app.use(zax.rateLimit(Ctx, .{ .capacity = 60, .refill_per_sec = 1.0 }));`
  - Keying works only when `trust_forwarded` is enabled (else `on_missing` governs).
  - Static-table sizing (`max_keys`), eviction = drop the least-budget key under cardinality pressure.
  - Keys longer than `key_max_len` are truncated (default 64 covers IPv6).
  - Comptime-memoization caveat: identical `(Ctx, config)` instantiations may share one static store; vary config for independent buckets per mount point.

- [ ] **Step 3: Commit.**
  ```bash
  git add docs/
  git commit -m "docs(ratelimit): CHANGELOG + usage snippet (task 4)"
  ```

---

## Self-Review

**Spec coverage:** config struct (T1) ✓; static store + spinlock + math (T1) ✓; factory + mw + key extraction + decoration (T2) ✓; full `X-RateLimit-*` + `Retry-After` (T2) ✓; root export (T3) ✓; docs + caveats (T4) ✓. Edge cases (no-key/untrusted, table-full eviction, concurrency, capacity 0, clock-backwards, key truncation, hostile header) covered by spec + T1/T2 tests.

**Placeholder scan:** all field names, defaults, header names, and formulas are concrete in the spec. No TBD.

**Type consistency:** `mw: *const fn(*const Ctx, *Next) anyerror!Response`; `check(key: []const u8, now: i128) Decision`; `nowNs() i128`; header values `[]const u8` via `allocPrint`. `Decision { allow: bool, remaining: u32, reset_s: u64, retry_after_s: u64 }`.

**Cross-file compile note (for the controller):** RESOLVED — `zig build test` runs a module's `test {}` blocks only when reachable from `root.zig` via `refAllDecls` (verified `root.zig:113-117`). The `RateLimit` export is added in Task 1 Step 0 (and `rateLimit` in Task 2 Step 1) precisely so each task's tests actually run. Every task's `zig build test` should be GREEN (no RED-between-tasks window), and each implementer must confirm the suite count rose vs the 367 baseline.

**Note on test determinism:** `check` takes `now` as a parameter; tests pass fixed/advanced integer nanoseconds. `nowNs()` is only ever called by `mw`, never inside `check`, so unit tests never touch the real clock.
