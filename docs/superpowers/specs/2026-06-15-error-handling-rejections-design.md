# Zax — error handling & rejections (design)

Date: 2026-06-15
Status: approved, ready for implementation planning
Scope: one sub-project of the post-v0.1.0 roadmap (theme A). Themes B–F
(robustness/security, extractor/response parity, routing parity, benchmarking,
observability) are tracked separately and out of scope here.

## Context

Zax v0.1.0 has no real error model. Two concrete defects motivate this work:

1. **Every extractor failure returns 500.** In `extract.callHandler`, a failing
   extractor (`Path`, `Query`, `Json`) propagates a Zig error that
   `server.dispatch` catches and maps blanket to `internal_server_error`. So a
   non-numeric `:id` for `Path(struct{ id: u64 })`, or a malformed JSON body,
   yields **500** when it should be **400/422**.
2. **Handlers can only fail as 500.** A handler returning any error becomes 500;
   there is no way to say "this is a 404" or "this is a 409" ergonomically.

Goal: correct status codes for extractor and handler failures, an ergonomic way
for handlers to raise typed statuses, and a single customization point so apps
can render errors how they like (e.g. JSON bodies). Axum achieves this with
per-extractor `Rejection` types and `Result<T, E: IntoResponse>`; we adapt that
to Zig's payload-less error values.

## Decisions (from brainstorming)

- **Rejection richness:** status code + short text reason. Errors stay payload-less
  Zig errors; mapping is centralized. (Not field-level structured detail.)
- **Handler errors:** a canonical `zax.Error` set whose members auto-map to
  statuses, usable with `try`. Returning a `Response` directly still works
  (`Response` is already `IntoResponse`).
- **Customization:** a single optional `on_error` hook that both classifies and
  renders, receiving the raw error, a computed default `ErrorInfo`, and the
  request context.
- **Wiring (Approach A):** a central `classify(anyerror) ErrorInfo` table applied
  at the dispatch boundary. No changes to extractor, `callHandler`, or middleware
  signatures — Zig error values are global identities, so a central table is
  unambiguous.

## Architecture

```
request → match → middleware chain → handler
                         │ (anyerror!Response, unchanged)
                         ▼
                  dispatch catch |err|
                         │
                  classify(err) → ErrorInfo{status, reason}
                         │
            on_error set? ──yes──▶ on_error(err, info, ctx) → Response
                  │no
                  ▼
            default render: Response{ status, body = reason }
```

404 and 405 are routed through the **same** renderer (with synthetic canonical
errors) so apps customize all error bodies via one hook.

### Component 1 — `src/error.zig` (new)

```zig
pub const ErrorInfo = struct {
    status: Status,
    reason: []const u8,
};

/// Canonical handler-facing error set. Members auto-map to statuses via classify.
pub const Error = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    Conflict,
    UnprocessableEntity,
    TooManyRequests,
    Internal,
    NotImplemented,
    ServiceUnavailable,
};

/// Map any error to a status + reason. Covers the canonical set, the extractor
/// error tags, and a 500 fallback for everything else.
pub fn classify(err: anyerror) ErrorInfo;
```

`classify` switch arms (else → `{ .internal_server_error, "internal server error" }`):

| Error tag | Status | reason |
|---|---|---|
| `Error.BadRequest` | 400 | "bad request" |
| `Error.Unauthorized` | 401 | "unauthorized" |
| `Error.Forbidden` | 403 | "forbidden" |
| `Error.NotFound` | 404 | "not found" |
| `Error.MethodNotAllowed` | 405 | "method not allowed" |
| `Error.Conflict` | 409 | "conflict" |
| `Error.UnprocessableEntity` | 422 | "unprocessable entity" |
| `Error.TooManyRequests` | 429 | "too many requests" |
| `Error.Internal` | 500 | "internal server error" |
| `Error.NotImplemented` | 501 | "not implemented" |
| `Error.ServiceUnavailable` | 503 | "service unavailable" |
| `MissingPathParam` | 400 | "missing path parameter" |
| `MissingQueryParam` | 400 | "missing query parameter" |
| `InvalidScalar` | 400 | "invalid parameter" |
| `InvalidEnum` | 400 | "invalid parameter" |
| `InvalidJson` | 422 | "invalid JSON body" |
| _(else)_ | 500 | "internal server error" |

Reasons may reuse `Status.reason()` where it matches; the table above is the
source of truth for wording.

### Component 2 — App error hook (`src/server.zig`)

Inside `App(AppState)`:

```zig
pub const ErrorHandler = *const fn (err: anyerror, info: ErrorInfo, ctx: *const Ctx) Response;

on_error: ?ErrorHandler = null,   // field, default null

pub fn onError(self: *Self, h: ErrorHandler) void {
    self.on_error = h;
}
```

The hook returns a `Response` (infallible — no recursive error handling). It lives
on `App` rather than the non-generic `Options` because it is parameterized by
`Ctx`. Apps that need allocation in the hook use `ctx.arena` and fall back to
`Response.fromStatus(info.status)` on allocation failure.

### Component 3 — dispatch rendering (`src/server.zig`)

```zig
fn renderError(self: *Self, err: anyerror, ctx: *const Ctx) Response {
    const info = err_mod.classify(err);
    if (self.on_error) |h| return h(err, info, ctx);
    return .{ .status = info.status, .body = info.reason };
}
```

`dispatch` changes:
- `found` branch: `return Chn.run(self.mws.items, f.handler, &ctx) catch |err| self.renderError(err, &ctx);`
- `not_found`: `return self.renderError(error.NotFound, &ctx);` (synthetic canonical error).
- `method_not_allowed`: render via `error.MethodNotAllowed`, then attach an
  `Allow` header built from the computed `MethodSet` (allowed methods, comma-
  separated, into `ctx.arena`). This fixes the dangling 405 `Allow` gap.

Note: `not_found`/`method_not_allowed` paths must construct `ctx` (today only the
`found` branch builds it). The synthetic-error render needs `req`, `state`, and
`arena`; build a `Ctx` with empty `params` for these branches.

### Component 4 — status additions (`src/http/response.zig`)

Add `too_many_requests = 429` to `Status` (+ "Too Many Requests" reason) to back
`Error.TooManyRequests`. All other canonical statuses already exist.

### Component 5 — exports (`src/root.zig`)

```zig
pub const err = @import("error.zig");   // module name `err` (error is reserved-ish)
pub const ErrorInfo = err.ErrorInfo;
pub const Error = err.Error;
pub const classify = err.classify;
```

(`App.onError`/`ErrorHandler` reached via `zax.App(S).ErrorHandler`.)

## Data flow examples

- `GET /users/abc` on `Path(struct{ id: u64 })` → extractor returns
  `error.InvalidScalar` → chain propagates → `classify` → `{400, "invalid
  parameter"}` → default render → **400** text body "invalid parameter".
- `POST /u` with malformed body on `Json(T)` → `error.InvalidJson` → **422**.
- Handler `const u = store.get(id) orelse return error.NotFound;` → **404**.
- Handler `return error.SomethingApp;` (not canonical) → **500**.
- App sets `on_error` returning `Response.jsonRaw(...)` → all of the above render
  as JSON with `application/json`.

## Testing

**Unit (`src/error.zig`):**
- `classify` returns the table's status for every canonical `Error` member and
  every extractor tag.
- An unrecognized error (`error.Nope`) → `{500, "internal server error"}`.

**Socket integration (`src/server.zig`, existing harness):**
- `GET /users/abc` (non-numeric) → 400 (regression test for the original bug).
- Malformed JSON body → 422.
- Missing required query field → 400.
- Handler returning `error.NotFound` → 404; `error.Conflict` → 409.
- Handler returning a non-canonical error → 500.
- Custom `on_error` hook → asserts JSON body + `content-type: application/json`.
- 404 routed through the hook → custom body.
- 405 response carries an `Allow` header listing the registered methods.

## Files

- New: `src/error.zig` (+ its tests).
- Edit: `src/server.zig` (App `on_error` field + `onError` + `renderError`,
  dispatch branches, 405 `Allow`, integration tests), `src/http/response.zig`
  (429 status), `src/root.zig` (exports).
- Docs: README "Error handling" section; `docs/getting-started.md` error example.

## Risks & edge cases

- **Tag collision:** a handler `try`ing a helper that returns an extractor-owned
  tag (e.g. `error.InvalidJson`) is classified as that tag (422). Mitigation:
  handlers use the canonical `Error` set; truly app-specific errors fall to 500;
  `on_error` can re-classify by inspecting `err`. Documented in README.
- **Hook safety:** `on_error` returns `Response` (not an error union) to prevent
  error-handling recursion; allocation failures inside it are the app's
  responsibility (fall back to `fromStatus`).
- **Ctx for 404/405:** these branches now build a `Ctx` (empty params). Keep the
  construction in one helper to avoid drift from the `found` branch.

## Out of scope

Field-level structured rejections, per-extractor `rejection()` overrides
(Approach B), error-handling middleware, and broader routing work (nested
routers, fallback handlers) — the latter is theme D.
