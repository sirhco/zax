# Design — ETag / Conditional-Request Middleware (built-in middleware)

**Status:** Proposed 2026-06-24. Branch `feat/etag-middleware` (off main `3b73519`). Target release **v0.18.0**.

## Context

zax's last non-WebSocket roadmap gap. Built-in middleware ship as comptime factories — `src/cors.zig`, `src/compress.zig`, `src/ratelimit.zig`. This adds `zax.etag(Ctx, config)`: hashes buffered `200` responses to safe-method (GET/HEAD) requests, emits an `ETag`, and short-circuits to `304 Not Modified` when the client's `If-None-Match` matches — standard HTTP conditional-GET caching, saving re-transfer of unchanged representations.

Mirrors `src/compress.zig` structure exactly (comptime factory wrapping `next.run()`, post-processing the buffered Response, arena-only allocation). Clean slate: no existing ETag/`If-None-Match`/`304` handling anywhere in `src/` (`Status.not_modified = 304` already exists). No HTTP-date formatter exists → Last-Modified/If-Modified-Since is out of scope this slice.

## Goal

```zig
try app.use(zax.etag(App.Context, .{}));
```
Auto-ETag buffered 200 GET/HEAD responses; honor `If-None-Match` → `304`.

### Decisions (confirmed with Chris)
- **Scope: ETag + If-None-Match → 304 only.** No Last-Modified/If-Modified-Since.
- **Hash: `std.hash.Wyhash`** → `u64` as 16 lowercase hex chars. Fast, non-crypto — a cache validator needs uniqueness, not collision-resistance.
- **Validator: strong default** (`"<16hex>"`); config `weak: bool = false` → `W/"<16hex>"`.

## Background (verified against current code)

- **Factory shape** — `src/compress.zig:28-48`: `pub fn compress(comptime Ctx, comptime config) middleware.Chain(Ctx).Middleware`, inner `Impl { fn mw(ctx: *const Ctx, next: *Next) anyerror!Response }`, `return Impl.mw`. `const Next = middleware.Chain(Ctx).Next;`.
- **Post-process pattern** — `src/compress.zig:32`: `var r = try next.run();` then guard-and-return-early; re-bind via `r = try r.withHeader(...)`.
- **Middleware** — `src/middleware.zig:20,31`: `Middleware = *const fn(ctx, next) anyerror!Response`; `Next.run()` advances chain; not calling it short-circuits.
- **Response** — `src/http/response.zig`: fields `:184-209` (status, content_type, body, headers, keep_alive, streamer, pull_streamer, upgrade); `Status.not_modified = 304` `:27`; `text` `:211`, `fromStatus` `:219` (`{.status, .body=""}`), `withHeader(arena,name,value)` `:358`, `stream` `:257`. Header names emitted verbatim → pass lowercase.
- **Request** — `src/http/request.zig`: `header(name)` case-insensitive `:49`; `Method` enum GET/HEAD `:8-22`; `req.method` `:34`.
- **Context** — `src/extract/extract.zig:14-28`: middleware sees `ctx.req`, `ctx.arena`.
- **Wyhash** — `std.hash.Wyhash.hash(seed: u64, input: []const u8) u64`.
- **Export site** — `src/root.zig:75-80` (cors/compress/ratelimit). `refAllDecls(@This())` test `:112-116` — in-file `test {}` blocks run ONLY when the module is reachable from root.zig.
- **Test harness** — `src/compress.zig:111-138`: `TestCtx{ req, arena }`, `fakeReq`, `hdr`, `runCompress` via `middleware.Chain(TestCtx)`. (compress's `fakeReq` hardcodes `.method=.GET` → ETag's must take a method param.)
- **No HEAD body-stripping** in `src/server.zig`/reactor (`Response.write` always emits body) → ETag treats HEAD exactly like GET.

## Components

### New: `src/etag.zig`

**Config (comptime):**
```zig
pub const Etag = struct {
    weak: bool = false,   // emit W/"<hash>" instead of strong "<hash>"
};
```

**Factory + middleware:** `pub fn etag(comptime Ctx, comptime config: Etag) middleware.Chain(Ctx).Middleware` → inner `Impl { fn mw }` → `return Impl.mw`.

**`mw` flow** (`var r = try next.run();` then post-process):

*Gating — pass `r` through unchanged unless ALL hold (cheapest first):*
1. `r.streamer == null and r.pull_streamer == null` (can't hash an unbuffered body).
2. `r.upgrade == null` (skip WS takeover).
3. `ctx.req.method == .GET or .HEAD` (safe methods only; unsafe → pass through, ignore If-None-Match entirely — unsafe-method conditionals are 412 territory, out of scope).
4. `r.status == .ok` (200 only).

*Validator resolution:*
- Handler already set an `etag` header (case-insensitive `hdr`) → use that, don't hash or double-set.
- Else `h = std.hash.Wyhash.hash(0, r.body)`; `tag = allocPrint(arena, "\"{x:0>16}\"", .{h})` (or `"W/\"{x:0>16}\""` when `config.weak`); `r = try r.withHeader(arena, "etag", tag)`.

*Conditional:* `if (ctx.req.header("if-none-match")) |inm| if (matches(inm, tag))` → **304**: `Response.fromStatus(.not_modified)`; copy `keep_alive` from `r`; carry `etag` (MUST); copy `cache-control` + `vary` if present (RFC 7232 §4.1). Empty body, no content-type. Else return `r`.

**Pure helpers (no alloc):**
- `opaque_tag(raw) []const u8` — trim " \t"; strip leading `W/`; trim again.
- `matches(if_none_match, our_tag) bool` — RFC 7232 weak comparison: trim; `*` → true; split on `,`; each non-empty trimmed entry → `eql(opaque_tag(entry), opaque_tag(our_tag))`.
- `hdr(r, name) ?[]const u8` — case-insensitive response-header lookup.

### Modified: `src/root.zig`
After the ratelimit exports:
```zig
pub const Etag = @import("etag.zig").Etag;   // Task 1 (so tests run)
pub const etag = @import("etag.zig").etag;    // Task 2
```

### Unchanged
No change to middleware.zig/compress.zig/cors.zig/ratelimit.zig/server/extractors. Purely additive.

## Data flow

request → `mw` → `next.run()` → gate → resolve validator (handler etag | Wyhash(body)) → set `etag` →
If-None-Match present & matches → 304 (etag + cache-control/vary, empty body); else 200 + etag.

## Error handling / edge cases

- If-None-Match `*` → 304. Multiple/weak tags, whitespace, trailing/empty commas → handled in `matches`.
- Handler-set ETag → respected, used for comparison, not double-set.
- Empty body → tagged (deterministic Wyhash of "").
- Non-200 / streaming / pull_streamer / upgrade → pass through untouched.
- HEAD → identical to GET (no HEAD body-stripping in the framework).
- If-None-Match on POST/PUT/etc. → ignored (pass through, no etag, no 304).
- Hostile If-None-Match → only parsed/compared, never echoed; the emitted `etag` is server-generated (handler-set path echoes the handler's own value, not client input).

## Behavior change & test impact

Purely additive — no existing behavior changes; opt-in via `app.use`. New in-file tests only, zero-socket/arena-based. Suite must stay green at 381/383 + new tests.

## Testing

Unit (Task 1): `matches` exact/`*`/weak/comma-list-with-whitespace/mismatch; `formatTag` strong (18 chars) vs weak (`W/"..."`), same 16-hex opaque-tag.
Middleware (Task 2, compress harness w/ method-param `fakeReq`): 200 GET sets etag; INM match → 304 + etag + empty body; mismatch → 200; weak config emits W/ + still 304s; HEAD like GET; POST passes through (no etag/304); non-200 not tagged; handler-set etag respected; streamed untouched; 304 preserves cache-control + vary; empty body tagged.
Integration (Task 3): compose `{etag, compress}`, large gzip-eligible body → response has both `content-encoding: gzip` + `etag`; follow-up echo → 304.

## Docs

`CHANGELOG.md` `[Unreleased]/Added` bullet; README `### Built-in: ETag / conditional requests` subsection (after rate limiting), mirroring cors/compress/ratelimit format. Note recommended ordering: register `etag` before `compress` so the ETag varies by content-encoding (compress already sets `Vary: Accept-Encoding`).

## Out of scope (future)

Last-Modified / If-Modified-Since (needs an RFC 7231 IMF-fixdate formatter+parser); If-Match / 412 optimistic concurrency on unsafe methods; per-route ETag config beyond separate factory instantiations; range requests.
