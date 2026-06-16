# Zax — fallback handler (D1) design

Date: 2026-06-16
Status: approved, ready for implementation planning
Scope: sub-project D1 of theme D (routing parity). A custom handler for unmatched
requests. Wildcard/catch-all (D2), per-route middleware (D3), and nested routers
(D4) are separate sub-projects, out of scope.

## Context

When no route matches, `App.dispatch`'s `not_found` branch returns a hardcoded
`renderError(error.NotFound)` (a default 404, customizable only via the global
`on_error` renderer). Axum lets an app register a **fallback handler** — a normal
handler that runs for unmatched requests, enabling a custom 404 page or an SPA
index fallback (serve `index.html` for any unknown path). Zax has no equivalent.

## Decision (from brainstorming)

- The fallback is a normal handler (extractors, `IntoResponse`, errors) that
  **runs through the global middleware chain**, like Axum. It applies to
  **not-found only**; `method_not_allowed` (405 + `Allow`) is unchanged.

## Architecture

```
unmatched request → router.match → .not_found
   fallback set? ── yes → Chn.run(mws, fallback, ctx)  (middleware applies)
                            └ handler error → renderError(e, ctx)
                 ── no  → renderError(error.NotFound, ctx)   (default 404, unchanged)
```

The fallback is stored as the same type-erased handler the router uses, wrapped
identically to a registered route, so it gets the full extractor/dispatch
pipeline.

## Components (all in `src/server.zig`, inside `App(AppState)`)

### 1. The `fallback_handler` field

(Named `fallback_handler`, not `fallback`, because Zig forbids a field and a
method sharing a name — the method is `fallback`.)

```zig
fallback_handler: ?ErasedHandler = null,
```

(`ErasedHandler = Chn.Handler = *const fn (*const Ctx) anyerror!Response`,
already defined.)

### 2. The `fallback` registrar

Mirrors `route()`'s comptime wrapping (validate signature, build the arg tuple,
`@call`, IntoResponse) but stores the result instead of registering it:

```zig
/// Set the handler run for requests that match no route (a custom 404, or an
/// SPA index fallback). Runs through the global middleware chain. Does not apply
/// to method-not-allowed (405).
pub fn fallback(self: *Self, comptime handler: anytype) std.mem.Allocator.Error!void {
    const Wrap = struct {
        fn call(ctx: *const Ctx) anyerror!Response {
            return extract.callHandler(handler, ctx.*);
        }
    };
    self.fallback_handler = &Wrap.call;
}
```

Note: the return type is `Allocator.Error!void` for signature parity with
`route()`/`use()` even though this implementation cannot fail; keeping it
fallible lets the body grow later without an API break, and lets callers write
`try app.fallback(h)` consistently. (If the reviewer prefers, it may be `void` —
the implementation has no allocation.)

### 3. The `not_found` dispatch branch

Replace the current branch:

```zig
.not_found => {
    const ctx = self.makeCtx(io, req, &.{}, arena);
    return self.renderError(err_mod.Error.NotFound, &ctx);
},
```

with:

```zig
.not_found => {
    const ctx = self.makeCtx(io, req, &.{}, arena);
    if (self.fallback_handler) |fb|
        return Chn.run(self.mws.items, fb, &ctx) catch |e| self.renderError(e, &ctx);
    return self.renderError(err_mod.Error.NotFound, &ctx);
},
```

`makeCtx` passes empty params (`&.{}`) — an unmatched route has no captures, so a
fallback handler must not use `Path` (it would get `MissingPathParam`).

## Data flow / error handling

- Fallback set → run through middleware; its `Response` is returned (a custom
  404, or a 200 for SPA). A handler error propagates to `renderError` (→ classify
  → status), exactly like a normal route.
- Fallback unset → default 404 via `renderError(error.NotFound)` — byte-identical
  to today.
- `method_not_allowed` is untouched (405 + `Allow`).

## Testing (socket integration in `src/server.zig`)

- **Custom 404 body:** app with a fallback returning `Response{ .status =
  .not_found, .body = "custom" }`; an unmatched route → `404` with body
  `custom`.
- **SPA-style 200:** a fallback returning `Response.text("index")`; an unmatched
  route → `200` body `index`.
- **No fallback (regression):** an unmatched route → default `404 Not Found`
  (existing behavior).
- **Middleware applies:** a global middleware that adds a header (e.g.
  `x-fallback`) is present on the fallback response.
- **405 unaffected:** a registered path hit with the wrong method → `405 Method
  Not Allowed` + `Allow` (the fallback is NOT invoked).

## Files

- Modify: `src/server.zig` (`fallback` field, `fallback` method, `not_found`
  branch, tests).
- Docs: README + `docs/getting-started.md` — a short fallback note.

## Risks & edge cases

- **`Path` in a fallback:** an unmatched route has no params, so a fallback using
  `Path(T)` yields `MissingPathParam` → 400. Documented (fallbacks use
  `State`/`Bytes`/`Files`/no-arg, not `Path`).
- **Field/method name collision:** the field `fallback` and the method
  `fallback` share a name — Zig forbids that. Resolve by naming the field
  differently (e.g. `fallback_handler`) and keeping the method `fallback`; the
  plan will use `fallback_handler` for the field.

## Out of scope

Per-route/group fallbacks, a dedicated method-not-allowed handler, and
wildcard/catch-all routing (D2).
