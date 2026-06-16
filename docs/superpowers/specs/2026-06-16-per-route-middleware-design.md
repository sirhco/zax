# Zax — per-route middleware (D3) design

Date: 2026-06-16. Status: accepted. Scope: sub-project D3 of theme D (routing
parity). Middleware that runs only for a specific route, in addition to the
global chain. Fallback handler (D1) and wildcard/catch-all (D2) are done; nested
routers (D4) remain a separate sub-project, out of scope.

## Context

zax has a global middleware chain: `app.use(mw)` appends to `App.mws`, and
`dispatch` runs `Chn.run(self.mws.items, handler, &ctx)` for a matched route
(and for the D1 fallback). Middleware are `*const fn (*const Ctx, *Next)
anyerror!Response`; `Next.run()` advances the chain and finally calls the
handler (`src/middleware.zig`).

There is no way to attach middleware to a single route — e.g. auth on `/admin`
only, or a body-size guard on one upload endpoint. Today you either gate inside
the handler (loses the composable short-circuit/post-process shape) or make a
mw global and branch on `ctx.req.path` (fragile). D3 adds first-class per-route
middleware.

## Decision (from brainstorming)

1. **API: `*With` verb variants.** New methods `routeWith`,
   `getWith`/`postWith`/`putWith`/`deleteWith`. The middleware are a **comptime
   tuple before the handler**: `app.getWith("/admin", .{ &auth, &log },
   handler)`. Existing `get`/`post`/… stay byte-identical and zero-cost.

2. **Composition: the stored handler runs the route chain.** No router, storage,
   `Found`, or `dispatch` changes. `routeWith` wraps the real handler in a
   comptime `Wrap.call` that runs `Chn.run(route_mws, realHandler, ctx)`. The
   global chain reaches `Wrap.call` as its terminal "handler"; `Wrap.call` then
   runs the per-route chain and finally the real handler.

3. **Ordering: global → per-route → handler.** Falls out of decision 2: the
   global `Chn.run` wraps `Wrap.call`, which wraps the route chain, which wraps
   the handler. Route middleware run in tuple order.

4. **Lifetime: comptime-static, zero per-request allocation.** The tuple is
   materialized into a `const` array on the comptime `Wrap` struct (static
   storage), and `Chn.run` borrows it. No `gpa`/arena allocation at registration
   or per request.

5. **Routing semantics unchanged.** Per-route middleware run only after a route
   matches (`.found`), exactly like the global chain. 404/405 still short-circuit
   before any middleware; the D1 fallback keeps running the global chain only.

## Architecture

```
request -> dispatch (.found) -> Chn.run(global_mws, Wrap.call, ctx)
                                         |
        global m1 -> global m2 -> ... -> Wrap.call
                                         |
                                 Chn.run(route_mws, realHandler, ctx)
                                         |
              route r1 -> route r2 -> ... -> realHandler (extractors + user fn)
```

`Wrap.call` has the same `ErasedHandler` shape (`*const fn (*const Ctx)
anyerror!Response`) as today's `route` wrapper, so the router stores it
unchanged. The only new code is the `routeWith`/`*With` methods.

## Components (all in `src/server.zig`, inside `App(AppState)`)

### 1. `routeWith` — register a route with its own middleware

```zig
/// Like `route`, but `mws` (a comptime tuple of `Middleware`) run only for
/// this route, after the global chain and before the handler, in tuple order.
pub fn routeWith(
    self: *Self,
    method: request.Method,
    pattern: []const u8,
    comptime mws: anytype,
    comptime handler: anytype,
) std.mem.Allocator.Error!void {
    const Wrap = struct {
        const list: [mws.len]Chn.Middleware = mws; // comptime tuple -> static array
        fn real(ctx: *const Ctx) anyerror!Response {
            return extract.callHandler(handler, ctx.*);
        }
        fn call(ctx: *const Ctx) anyerror!Response {
            return Chn.run(&list, &real, ctx);
        }
    };
    try self.router.register(method, pattern, &Wrap.call);
}
```

### 2. Convenience verbs

```zig
pub fn getWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
    return self.routeWith(.GET, pattern, mws, h);
}
// postWith / putWith / deleteWith identical with .POST / .PUT / .DELETE
```

## Data flow / error handling

- **Match → run:** `dispatch`'s `.found` branch is unchanged; it runs
  `Chn.run(self.mws.items, f.handler, &ctx)`. For a `routeWith` route,
  `f.handler` is `Wrap.call`, which runs the route chain then the real handler.
- **Short-circuit:** a route middleware that returns without calling
  `next.run()` (e.g. auth → 401) skips the remaining route chain and the handler,
  exactly like a global middleware short-circuit.
- **Errors:** an error from a route middleware or the handler propagates out
  through both `Chn.run` calls to `dispatch`'s `catch |e| self.renderError(e,
  &ctx)` — identical to the global path.
- **Empty tuple:** `.{}` yields a zero-length static array; `Chn.run` with no
  middleware just calls the handler (use plain `get` instead — supported but
  pointless).

## Testing (integration in `src/server.zig`)

- **Scoping + short-circuit:** register `get("/open", ping)` and
  `getWith("/admin", .{ &requireAuth }, ping)` (reusing the existing
  `requireAuth` test middleware). `GET /open` with no auth → 200 (route mw does
  not apply); `GET /admin` with no auth → 401; `GET /admin` with an
  `authorization` header → 200.
- **Ordering global → route → handler:** body-wrapping middleware `wrapG`
  (global) and `wrapR` (route) that wrap the inner body as `G(...)` / `R(...)`;
  handler returns `H`. `getWith("/x", .{ &wrapR }, h)` with `use(&wrapG)` yields
  body `G(R(H))`.
- **Multiple route middleware order:** `.{ &wrapR1, &wrapR2 }` yields
  `R1(R2(H))`.
- **Flakiness:** real-socket tests run 3× (per repo convention).

## Files

- Modify: `src/server.zig` (`routeWith` + four `*With` verbs; integration tests).
- Modify: `README.md`, `docs/getting-started.md` (per-route middleware note).
- No changes to `src/middleware.zig`, `src/router/*`, or the extract layer.

## Risks & edge cases

- **Comptime tuple coercion:** `const list: [mws.len]Chn.Middleware = mws;`
  requires each tuple element to coerce to `Chn.Middleware`. A wrong-signature
  middleware fails at comptime with a clear type error (desirable).
- **No dedup with global chain:** a middleware listed both globally and per-route
  runs twice. Documented; route authors control their tuple.
- **Static storage per call site:** each distinct `routeWith` instantiation emits
  its own `Wrap` (same as `route` today). Negligible; comptime-bounded by the
  number of registration sites.

## Out of scope

Nested routers / route groups (D4) — including group-level shared middleware and
path-prefix mounting. Runtime (non-comptime) middleware lists. Per-route middleware
on the D1 fallback (the fallback runs the global chain only).
