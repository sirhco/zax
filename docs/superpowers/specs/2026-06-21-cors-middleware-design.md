# Design — CORS middleware (first built-in middleware)

**Status:** approved 2026-06-21. Branch `v0.11.0` (off main `438ac93`).

## Problem

zax shipped a tower-style middleware chain (`src/middleware.zig`, `Chain(Ctx)`)
in v1.1, but ships **no built-in middleware** — every user must hand-roll even
common cross-cutting concerns. CORS (Cross-Origin Resource Sharing) is the most
common: any browser frontend calling a zax API on a different origin needs it,
and getting the preflight/credentials/origin-reflection rules right by hand is
error-prone. A built-in `cors` middleware both fills that need and demonstrates
the chain (the first batteries-included middleware).

## Goal

A configurable `cors` middleware factory that handles `OPTIONS` preflight
(short-circuit `204`) and decorates actual responses with the correct
`Access-Control-*` headers, built on the existing `Chain(Ctx).Middleware`
contract and `Response.withHeader`.

Non-goals (YAGNI): per-route origin policies beyond the allowlist; regex/pattern
origin matching; runtime/env-driven origin lists (config is comptime — see
Decisions); automatic `OPTIONS` routing changes (the middleware answers
preflight itself).

### Decisions (confirmed with Chris)
- **Comptime factory:** `cors(comptime Ctx, comptime config: Cors)` returns a
  generated middleware fn with config baked in. The chain's `Middleware` is a
  bare fn pointer with no runtime payload, so comptime config is the natural fit
  (no AppState coupling). Origins are fixed at build time.
- **Origin policy:** wildcard `*` AND explicit allowlist (reflect a matching
  request `Origin`). With `credentials = true`, never emit `*` — reflect the
  specific origin (per the Fetch spec).
- **Allowlist no-match → emit ZERO CORS headers** (strict; the browser blocks).
- **Preflight:** short-circuit `204` (handler not called).

## Background: the middleware contract

From `src/middleware.zig`: `Chain(Ctx).Middleware = *const fn (ctx: *const Ctx,
next: *Next) anyerror!Response`. `next.run()` continues the chain; returning
without calling it short-circuits; calling it then mutating the result
post-processes. The server exposes `App(S).Context` (= `extract.Context(S)`,
fields incl. `req: *const Request`, `arena: std.mem.Allocator`) and
`App(S).Middleware`; middlewares are registered with `app.use(mw)` (global) or
`getWith`/`routeWith` (per-route). `Request.method` is the HTTP method enum;
`Request.header(name)` is the case-insensitive lookup. `Response.withHeader(arena,
name, value)` appends an arena-backed header (lowercase convention).

## Components

### Added: `src/cors.zig`

```zig
//! CORS middleware (built-in). `cors(Ctx, config)` returns a `Chain(Ctx)`
//! middleware that answers `OPTIONS` preflight with 204 and decorates actual
//! responses with `Access-Control-*` headers. Config is comptime.

const std = @import("std");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

pub const Cors = struct {
    pub const Origins = union(enum) {
        any,                        // emit "*" (or reflect when credentials)
        list: []const []const u8,   // reflect request Origin iff it matches
    };
    origins: Origins = .any,
    /// Access-Control-Allow-Methods (preflight).
    methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS",
    /// Access-Control-Allow-Headers (preflight).
    allow_headers: []const u8 = "Content-Type",
    /// Access-Control-Expose-Headers (actual response); null omits.
    expose_headers: ?[]const u8 = null,
    /// Access-Control-Allow-Credentials: true when set.
    credentials: bool = false,
    /// Access-Control-Max-Age seconds (preflight); null omits.
    max_age: ?u32 = null,
};

/// Build a CORS middleware for context type `Ctx` with comptime `config`.
pub fn cors(comptime Ctx: type, comptime config: Cors) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            const origin = ctx.req.header("origin");
            const allow = resolveAllowOrigin(config, origin); // ?[]const u8

            const is_preflight = ctx.req.method == .OPTIONS and
                ctx.req.header("access-control-request-method") != null;

            if (is_preflight) {
                const r = Response.fromStatus(.no_content);
                return decorate(ctx.arena, r, config, allow, true);
            }
            const r = try next.run();
            return decorate(ctx.arena, r, config, allow, false);
        }
    };
    return Impl.mw;
}
```

**`resolveAllowOrigin(config, origin) ?[]const u8`** — the value for
`Access-Control-Allow-Origin`, or null when no CORS headers should be emitted:
- `origin == null` → null (non-CORS request).
- `.any` + `!credentials` → `"*"`.
- `.any` + `credentials` → reflect `origin` (can't use `*` with credentials).
- `.list` → reflect `origin` iff it equals (exact match) a list entry; else null.

**`decorate(arena, r, config, allow, preflight) !Response`** — returns `r`
unchanged when `allow == null`; otherwise appends (via `r.withHeader`):
- `access-control-allow-origin: <allow>`.
- When the origin was reflected (i.e. not the literal `"*"`): `vary: origin`
  (cache-correctness).
- `access-control-allow-credentials: true` when `config.credentials`.
- **Preflight only:** `access-control-allow-methods: <methods>`,
  `access-control-allow-headers: <allow_headers>`, and
  `access-control-max-age: <n>` when `max_age` set.
- **Actual only:** `access-control-expose-headers: <expose_headers>` when set.

(Header names lowercase; `max_age` formatted with a stack `bufPrint` like
`SetCookie`. The `vary: origin` decision keys off `allow.ptr != "*".ptr` /
`!std.mem.eql(u8, allow, "*")`.)

### Modified: `src/root.zig`

```zig
pub const Cors = @import("cors.zig").Cors;
pub const cors = @import("cors.zig").cors;
```

### No `error.zig` change

The middleware never originates a domain error; it propagates whatever
`next.run()` returns and only appends headers (arena `OutOfMemory` propagates).

## Data flow

```
browser preflight: OPTIONS + Origin + Access-Control-Request-Method
  → cors mw: resolveAllowOrigin → 204 + Allow-Origin/Methods/Headers[/Max-Age]  (short-circuit)
browser actual: GET + Origin
  → cors mw: r = next.run(); + Allow-Origin [+ Credentials][+ Expose][+ Vary: Origin]
no Origin (same-origin / curl)
  → cors mw: pass through, no CORS headers
```

## Error handling

- Disallowed origin (`.list` no match) or absent `Origin` → emit no CORS headers
  (and for preflight still return a bare `204`). The browser enforces the block.
- `credentials = true` with `.any` → reflect the concrete origin, never `*`.
- Arena `OutOfMemory` from `withHeader` → propagates.

## Behavior change & test impact

Additive: one new file + two root re-exports. No change to existing middleware,
routing, or response behavior; existing tests unaffected.

## Testing

Unit (`src/cors.zig`) — drive the generated middleware through
`Chain(TestCtx).run` with a fake `TestCtx` (`.req` built in-memory like the
extractor tests, `.arena`) and a trivial handler:
1. `.any`, GET + Origin → response has `access-control-allow-origin: *`, no
   `vary`.
2. `.list` match → `access-control-allow-origin: <origin>` + `vary: origin`.
3. `.list` no match → NO `access-control-*` header at all.
4. `credentials = true` + `.any` → reflects the concrete origin (not `*`) +
   `access-control-allow-credentials: true` + `vary: origin`.
5. Preflight (`OPTIONS` + `Access-Control-Request-Method`) → `204`, has
   Allow-Methods/Allow-Headers (+ Max-Age when configured), handler NOT invoked
   (assert via a flag the handler would flip).
6. No `Origin` header → handler runs, response has no CORS headers.
7. `expose_headers` set → actual response carries
   `access-control-expose-headers: <v>`.

e2e (`src/server.zig`, loopback; mirror the Headers/forwarded e2e + `doRequest`):
8. `app.use(zax.cors(App(S).Context, .{ .origins = .any }))`; a GET route.
   - Preflight `OPTIONS /x` with `Origin` + `Access-Control-Request-Method: GET`
     → `204` with `access-control-allow-methods:` present.
   - `GET /x` with `Origin` → `200` body + `access-control-allow-origin: *`.

## Verification

- `zig build test --summary all` — baseline green + new unit + e2e tests, 0
  failures (mac kqueue + Linux epoll). No timing-sensitive paths → single run.
- Manual: `zig build run` with a `cors` middleware; JS-fetch smoke (curl hooked)
  — send `OPTIONS` with the preflight headers → 204 + Allow-* ; send `GET` with
  `Origin` → Allow-Origin on the response.

## Preflight dispatch (auto-preflight)

**Discovered during implementation:** global middleware (`app.use`) runs only
*after* a route matches — `server.zig` dispatch returns `405` for a
method-mismatch (and `404` for no path) **before** invoking the chain
(`server.zig:766`, comment at `:241`). So an `OPTIONS` preflight to a path
registered only for `GET` would `405` before the CORS middleware could answer —
defeating automatic preflight.

**Decision (confirmed with Chris): auto-preflight in dispatch.** In the
`.method_not_allowed` branch, when `req.method == .OPTIONS`, run the global
middleware chain with a terminal handler that returns `405`. The CORS middleware
short-circuits the preflight (returns `204`) before reaching the terminal, so
preflight works with no `OPTIONS` route registered. If the chain falls through
(no CORS, or non-preflight `OPTIONS`), the response is still the normal `405`
(re-render `MethodNotAllowed` + `Allow` header) — existing behavior preserved.
This is scoped to `OPTIONS` only; non-`OPTIONS` 405s keep the cheap
short-circuit. (A general pre-routing middleware hook remains future work.)

## Docs

- `README.md` (middleware section): document `cors` + `Cors` config, the
  comptime-factory usage (`app.use(zax.cors(App(S).Context, .{...}))`), origin
  policies, credentials/preflight behavior, and a snippet.
- `docs/getting-started.md`: add if it covers middleware.
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added`.
