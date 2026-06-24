# ETag / Conditional-Request Middleware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Spec: `docs/superpowers/specs/2026-06-24-etag-middleware-design.md`.

**Goal:** A built-in `zax.etag(Ctx, config)` middleware in a new `src/etag.zig`, mirroring `src/compress.zig`. Hashes buffered `200` GET/HEAD response bodies with Wyhash → strong (or weak) `ETag`; honors `If-None-Match` (RFC 7232 weak comparison) → `304 Not Modified`. Zero heap beyond the request arena.

## Global Constraints

- **Zig 0.16.** Mirror `src/compress.zig` house style EXACTLY: comptime `config`, inner `const Impl = struct { fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {...} }`, `const Next = middleware.Chain(Ctx).Next;`, `return Impl.mw;`.
- **Arena-only allocation:** the formatted tag (`std.fmt.allocPrint`) + `withHeader` copies. No heap. No new module deps beyond `std`, `middleware.zig`, `http/response.zig`, `http/request.zig`.
- **Header names lowercase** (emitted verbatim by the writer).
- **Wyhash:** `std.hash.Wyhash.hash(0, r.body)` → `u64`; format `"\"{x:0>16}\""` (strong) or `"W/\"{x:0>16}\""` (weak via `config.weak`, a comptime branch).
- **If-None-Match = RFC 7232 WEAK comparison:** strip a leading `W/` on either side, compare the quoted opaque-tag; `*` matches any current representation; value is a comma-separated list.
- **Gating, in order, all must hold** else pass `r` through: (1) `r.streamer == null and r.pull_streamer == null`; (2) `r.upgrade == null`; (3) `ctx.req.method == .GET or .HEAD`; (4) `r.status == .ok`. Unsafe methods → pass through AND ignore If-None-Match.
- **Additive only:** the only edits outside `src/etag.zig` are two `root.zig` export lines (Task 1 + Task 2) and docs (Task 4).
- **Test discovery:** `zig build test` runs a module's `test {}` only if reachable from `src/root.zig` via `refAllDecls` (root.zig:112-116) → export `Etag` in Task 1 so Task 1's tests run; add `etag` export in Task 2. No throwaway stub.
- **Build/test:** `zig build test --summary all`, SINGLE-INSTANCE only (WS e2e binds fixed ports; never two concurrent runs). Baseline 381/383 (3 pre-existing macOS skips). Final ≥ baseline + new tests, no regressions.

## File Structure

- Create: `src/etag.zig` (Tasks 1–3).
- Modify: `src/root.zig` (Task 1 export `Etag`; Task 2 export `etag`).
- Modify: `CHANGELOG.md` + `README.md` (Task 4).

---

### Task 1: Config + pure helpers (`opaque_tag`, `matches`, `formatTag`) + root export

Delivers the testable, HTTP-free core of `src/etag.zig`.

**Files:** Create `src/etag.zig`; modify `src/root.zig`.

**Produces:** `pub const Etag`; file-private `opaque_tag`, `matches`, `formatTag` (exercised by in-file tests).

- [ ] **Step 1: File skeleton.** Doc comment (token-bucket... no — ETag middleware: Wyhash ETag + If-None-Match→304, mirrors compress.zig). Imports: `std`, `middleware = @import("middleware.zig")`, `Response = @import("http/response.zig").Response`. Define:
  ```zig
  pub const Etag = struct { weak: bool = false };
  ```

- [ ] **Step 2: `formatTag`.**
  ```zig
  fn formatTag(arena: std.mem.Allocator, weak: bool, body: []const u8) ![]const u8 {
      const h: u64 = std.hash.Wyhash.hash(0, body);
      return if (weak)
          std.fmt.allocPrint(arena, "W/\"{x:0>16}\"", .{h})
      else
          std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{h});
  }
  ```

- [ ] **Step 3: `opaque_tag` + `matches`.**
  ```zig
  fn opaque_tag(raw: []const u8) []const u8 {
      var t = std.mem.trim(u8, raw, " \t");
      if (std.mem.startsWith(u8, t, "W/")) t = std.mem.trim(u8, t[2..], " \t");
      return t;
  }
  fn matches(if_none_match: []const u8, our_tag: []const u8) bool {
      const h = std.mem.trim(u8, if_none_match, " \t");
      if (std.mem.eql(u8, h, "*")) return true;
      const want = opaque_tag(our_tag);
      var it = std.mem.splitScalar(u8, h, ',');
      while (it.next()) |tok| {
          const cand = std.mem.trim(u8, tok, " \t");
          if (cand.len == 0) continue;
          if (std.mem.eql(u8, opaque_tag(cand), want)) return true;
      }
      return false;
  }
  ```

- [ ] **Step 4: Root export (so tests run).** In `src/root.zig`, after the `pub const rateLimit = ...` line, add ONLY:
  ```zig
  pub const Etag = @import("etag.zig").Etag;
  ```
  (Do NOT add `etag` — the function lands in Task 2.)

- [ ] **Step 5: Unit tests** (`test {}` in `src/etag.zig`; `const testing = std.testing;`):
  - `matches("\"abc\"", "\"abc\"")` true; `matches("\"abc\"", "\"abd\"")` false.
  - `matches("*", anytag)` true.
  - weak: `matches("W/\"abc\"", "\"abc\"")` and `matches("\"abc\"", "W/\"abc\"")` both true.
  - comma list + whitespace + trailing comma: `matches(" \"x\" , W/\"abc\" , ", "\"abc\"")` true; `matches("\"x\", \"y\"", "\"abc\"")` false.
  - `formatTag`: strong len == 18, starts/ends `"`; weak starts `W/"`; both share the same 16-hex opaque-tag (`opaque_tag(strong) == opaque_tag(weak)`).

- [ ] **Step 6: Commit.**
  ```bash
  git add src/etag.zig src/root.zig
  git commit -m "feat(etag): Etag config + If-None-Match matcher + tag formatting (task 1)"
  ```
  Verify `zig build test --summary all` green (single-instance) AND count rose vs 381 (proves tests are reached).

---

### Task 2: `etag` factory + `mw` + gating + 304 shaping + middleware tests

**Files:** Modify `src/etag.zig`; modify `src/root.zig` (add `etag` export).

**Consumes:** Task 1's `Etag`, `matches`, `formatTag`.
**Produces:** `pub fn etag(comptime Ctx: type, comptime config: Etag) middleware.Chain(Ctx).Middleware`.

- [ ] **Step 1: `hdr` helper + factory.** Add `fn hdr(r: Response, name: []const u8) ?[]const u8` (case-insensitive scan of `r.headers`, copy compress's). Then the factory: inner `const Impl = struct { fn mw(ctx, next) {...} }; return Impl.mw;`, `const Next = middleware.Chain(Ctx).Next;`. Add the second root export: `pub const etag = @import("etag.zig").etag;`.

- [ ] **Step 2: `mw` flow** (per spec):
  ```zig
  fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
      var r = try next.run();
      if (r.streamer != null or r.pull_streamer != null) return r;
      if (r.upgrade != null) return r;
      if (ctx.req.method != .GET and ctx.req.method != .HEAD) return r;
      if (r.status != .ok) return r;
      const tag = hdr(r, "etag") orelse blk: {
          const t = try formatTag(ctx.arena, config.weak, r.body);
          r = try r.withHeader(ctx.arena, "etag", t);
          break :blk t;
      };
      if (ctx.req.header("if-none-match")) |inm| {
          if (matches(inm, tag)) {
              var nm = Response.fromStatus(.not_modified);
              nm.keep_alive = r.keep_alive;
              nm = try nm.withHeader(ctx.arena, "etag", tag);
              if (hdr(r, "cache-control")) |v| nm = try nm.withHeader(ctx.arena, "cache-control", v);
              if (hdr(r, "vary")) |v| nm = try nm.withHeader(ctx.arena, "vary", v);
              return nm;
          }
      }
      return r;
  }
  ```

- [ ] **Step 3: Test harness** mirroring `src/compress.zig:111-138`: `const Request = @import("http/request.zig").Request;`, `TestCtx{ req: *const Request, arena: std.mem.Allocator }`, `fakeReq(method: Request.Method, headers: []const Header)` (takes a method param — compress's hardcodes GET), `runEtag(arena, comptime config, req, resp)` via `middleware.Chain(TestCtx)` with a static-`var` handler returning `resp`. (Import `Header` as compress does.)

- [ ] **Step 4: Middleware tests:** 200 GET sets strong etag (18 chars); INM match → `.not_modified` + same etag + empty body; INM mismatch → `.ok`; `weak=true` emits `W/` and still 304s under weak compare; HEAD like GET (etag set); POST with `If-None-Match: *` → `.ok`, NO etag header (unsafe method ignored); non-200 (`fromStatus(.not_found)`) → no etag; handler-set etag (`Response.text(...).withHeader(a,"etag","\"custom\"")`) respected + used for comparison (INM `"custom"` → 304 carrying `"custom"`); streamed response (`Response.stream(...)`) untouched (no etag); 304 preserves cache-control + vary (set them on the 200, echo etag → assert both present on 304); empty body (`Response.text("")`) tagged.

- [ ] **Step 5: Commit.**
  ```bash
  git add src/etag.zig src/root.zig
  git commit -m "feat(etag): etag middleware factory, gating, 304 shaping (task 2)"
  ```
  Verify `zig build test --summary all` green; note count.

---

### Task 3: Compose-with-compress ordering integration test

**Files:** Modify `src/etag.zig` (one `test {}`).

- [ ] **Step 1: Integration test.** Build `const C = middleware.Chain(TestCtx);` and `mws = [_]C.Middleware{ etag(TestCtx, .{}), @import("compress.zig").compress(TestCtx, .{}) }` (etag FIRST → outer → post-processes the already-compressed body). Drive a GET with `Accept-Encoding: gzip` over a large compressible body (≥ compress `min_length`, repetitive so it shrinks). Assert the response carries BOTH `content-encoding: gzip` AND an `etag`. Then a follow-up GET echoing that etag in `If-None-Match` (same body/headers) → `.not_modified`. This documents that the ETag is over the compressed representation (compress sets `Vary: Accept-Encoding`).

- [ ] **Step 2: Commit.**
  ```bash
  git add src/etag.zig
  git commit -m "test(etag): compose with compress, verify ordering + 304 (task 3)"
  ```
  Verify `zig build test --summary all` green.

---

### Task 4: Docs / CHANGELOG

**Files:** Modify `CHANGELOG.md`; modify `README.md`.

- [ ] **Step 1: CHANGELOG.** Add an `Added` bullet as the FIRST item under `## [Unreleased]` → `### Added`, mirroring the compress/ratelimit bullet voice: `zax.etag(Ctx, config)` — comptime-configured ETag; Wyhash-hashes buffered 200 GET/HEAD responses → strong `"<16hex>"` (or weak `W/"..."` via `weak: bool`); honors `If-None-Match` (RFC 7232 weak comparison, `*` wildcard, comma lists) → `304 Not Modified` carrying `etag` and preserving `cache-control`/`vary`; respects a handler-set `etag`; skips streaming/upgrade/non-200/unsafe-method responses; zero heap beyond the arena. Note recommended registration order (etag before compress so the ETag varies by content-encoding).

- [ ] **Step 2: README.** Add `### Built-in: ETag / conditional requests` to the `## Middleware` section AFTER `### Built-in: rate limiting`, in the same format as the cors/compress/ratelimit subsections: intro with `zax.etag(comptime Ctx: type, comptime config: zax.Etag)`, an `app.use` code example, a `zax.Etag` config table (the single `weak` field), and a behavior list (token... no: ETag behavior — what gets tagged, If-None-Match→304, handler-etag respected, skip rules, ordering note). Read README's existing middleware subsections (~lines 244-330) to match format.

- [ ] **Step 3: Commit.**
  ```bash
  git add CHANGELOG.md README.md
  git commit -m "docs(etag): CHANGELOG entry + README built-in ETag section (task 4)"
  ```

---

## Self-Review

**Spec coverage:** config (T1); pure matchers/formatter (T1); factory+mw+gating+304 (T2); compose ordering (T3); docs (T4). Root export split T1(`Etag`)/T2(`etag`) so each task's tests run. Edge cases (`*`, weak, comma/whitespace, handler-etag, empty body, non-200, streaming, HEAD, unsafe-method) covered by T1/T2 tests.

**Placeholder scan:** all helper bodies, the mw flow, format strings, and gating order are concrete. No TBD.

**Type consistency:** `etag` returns `middleware.Chain(Ctx).Middleware`; `mw: *const fn(*const Ctx, *Next) anyerror!Response`; `formatTag(arena, bool, []const u8) ![]const u8`; `matches([]const u8, []const u8) bool`; `hdr(Response, []const u8) ?[]const u8`. `fakeReq` takes `Request.Method`.

**Cross-file compile note (controller):** RESOLVED — `Etag` exported in Task 1 Step 4 and `etag` in Task 2 Step 1, so each task's `zig build test` is GREEN (no RED-between-tasks window) and the new tests actually run. Each implementer confirms the count rose vs 381.

**Note on test determinism:** all tests are pure/arena-based, no clock, no socket. Wyhash is deterministic (seed 0), so ETag values are stable across runs.
