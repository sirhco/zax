# Design — Documentation & examples expansion (logo + runnable example apps + cookbook)

**Status:** approved 2026-06-23. Branch `docs-examples` (off main `e5eb7ba` = `v0.16.0`).
**No library version bump** — docs/examples only; the published `zax` API is unchanged.

## Context

zax is feature-complete across HTTP core, routing, comptime extractors, middleware
(incl built-in CORS + gzip), observability, and WebSocket (all 4 sub-features shipped:
`v0.13.0`–`v0.16.0`). The README (763 lines) documents features with prose + code
snippets, but the only runnable example is `examples/hello-service/` — a minimal
"hello" consumer. New users lack realistic, end-to-end, copy-runnable apps, and the
README has no logo.

This slice adds **four runnable example apps**, a **cookbook** that indexes/walks
through them, a **README logo header**, and a **CI compile-check** so the examples
can't rot. No library source changes — the examples consume the published API,
doubling as living validation of real usage.

## Goal

A new contributor can open `examples/`, pick a realistic app close to their use case,
`zig build run` it, and read a cookbook that explains how it works — and the README
opens with the zax logo and a curated Examples index.

### Decisions (confirmed with Chris)

- **Form: runnable example apps + a cookbook.** Each example is a standalone consumer
  of `zax` (its own `build.zig` + `build.zig.zon` path-dependency on the repo, `src/main.zig`,
  and a `README.md`), mirroring `examples/hello-service/`. A `docs/examples.md` cookbook
  indexes and walks through them.
- **Example set:** `todo-api`, `auth-sessions`, `file-upload`, `websocket-live`
  (plus the existing `hello-service`). **Observability** folds into `todo-api`
  (metrics + access log on a real app), not a separate stub.
- **Mutable shared state via `State(*T)` + `std.Thread.Mutex`.** `todo-api` and
  `auth-sessions` mutate in-memory state; since the threaded backend is
  thread-per-connection (and the evented backend has multiple worker threads),
  handlers lock a mutex inside the shared store. This honestly teaches zax's
  shared-state model (`State(T)` hands the app-state value through unchanged; the
  "read-only" guidance is a convention, not enforced — a mutable `*Store` with
  internal synchronization is valid and is the realistic pattern).
- **WebSocket example is per-connection, not chat.** Cross-connection broadcast is a
  future *code* feature; `websocket-live` demonstrates the shipped API (upgrade,
  whole-message `on_message`, `conn.send`, auto ping/pong + close handshake) on both
  `app.serve` and `app.serveEvented`.
- **Logo:** centered `<picture>` (velocity icon, dark/light theme swap) + `zax-wordmark.svg`,
  replacing the plain `# Zax` H1; badges + tagline below.
- **No version bump.** Docs/examples don't change the library; `CHANGELOG.md` gets an
  `[Unreleased]` → `### Added` note.

## Background (verified against the codebase)

- **Example structure to mirror:** `examples/hello-service/` = `build.zig` + `build.zig.zon`
  (relative path-dependency on the repo root) + `src/main.zig`. New examples copy this shape.
  Each example's `.zig-cache/` must be git-ignored (it currently leaks into the working
  tree for `hello-service`; the root `.gitignore` should cover `examples/*/.zig-cache/`).
- **State model:** `State(T).fromContext` returns `ctx.state` (type = the router's
  `AppState`), with a comptime check that `@TypeOf(ctx.state) == T`. `App(AppState)` is
  generic, so `AppState = *Store` (a mutable pointer) is allowed; handlers reach the store
  via `State(*Store)`. No const enforcement.
- **Assets:** `assets/zax-icon-velocity-dark.svg`, `assets/zax-icon-velocity-light.svg`,
  `assets/zax-wordmark.svg` (+ mono mark + favicons). The dark/light icon pair drives the
  README `<picture>` theme swap.
- **APIs the examples use** (all shipped): `Path`, `Query`, `Json`, `State`, `Cookies`,
  `Multipart`, `Files`, `Headers`; `Response` + `withCookie`/`expireCookie`/`fromStatus`/
  JSON helpers; `Router`/route groups/per-route middleware; the `Chain` middleware factory
  pattern; `observe` (metrics + access logger + `Observer` registration); `WebSocket`
  extractor + `WsConn` + `WsHandler`; `App.serve` / `App.serveEvented`.
- **CI:** `.github/workflows/ci.yml` already has a `bench-build` compile-check step; the
  example compile-checks mirror it.

## Components

### Modified: `README.md` — logo header + Examples section

Replace the top `# Zax` H1 with:

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/zax-icon-velocity-dark.svg">
    <img src="assets/zax-icon-velocity-light.svg" height="96" alt="zax">
  </picture>
</p>
<p align="center"><img src="assets/zax-wordmark.svg" height="40" alt="zax"></p>
```

Keep the CI badge + tagline (the "New here?" line) below. Add a `## Examples` section
(near the top, after the intro) — a table linking each example dir + its one-line
purpose, and pointing at `docs/examples.md`.

### Added: `examples/todo-api/`

REST/CRUD JSON API + observability. `src/main.zig`:
- `Store = struct { mutex: std.Thread.Mutex, items: ...next_id... }` with `add/get/list/
  update/remove` methods that lock the mutex. App is `App(*Store)`.
- Routes: `GET /todos` (list → JSON array), `POST /todos` (`Json(NewTodo)` → 201 + created),
  `GET /todos/:id` (`Path` → 200 or 404), `PUT /todos/:id` (update → 200/404),
  `DELETE /todos/:id` (→ 204/404).
- Observability: register the metrics + access-log `Observer`; `GET /metrics` returns the
  metrics snapshot.
- Proper status codes + an error path (invalid id, missing body → 4xx via the error model).
- `README.md`: what it teaches, `zig build run`, `curl` commands for each route.

### Added: `examples/auth-sessions/`

Cookie sessions + guard middleware. `src/main.zig`:
- `Sessions = struct { mutex, set }` (token → user), `App(*Sessions)`.
- `POST /login` (`Json` or form creds) → validate → create a session token → `Response`
  with `withCookie("session", token, ...)`.
- A **guard middleware** (`Chain(Ctx).Middleware`) that reads the `Cookies` extractor,
  looks up the token, and short-circuits `401` when missing/invalid; applied to a protected
  route group.
- `GET /me` (protected → user info), `GET /` (public), `POST /logout` (`expireCookie`).
- `README.md`: login/me/logout `curl -c/-b cookiejar` walkthrough.

### Added: `examples/file-upload/`

Multipart upload + static serving. `src/main.zig`:
- `POST /upload` consumes `Multipart` (the file part) and writes it to an example output
  dir (created at startup); returns the saved path/size.
- `GET /files/*` serves the saved files via `Files` (static serving), bounded by the
  configured body/size limits.
- `README.md`: `curl -F file=@... /upload` + a browse `curl /files/...` walkthrough; notes
  the output directory + `max_body_size`.

### Added: `examples/websocket-live/`

WebSocket per-connection demo on both backends. `src/main.zig`:
- A `WebSocket` handler: `on_message` echoes (or transforms) whole messages; a per-app
  counter (`State(*Counter)` + Mutex) shows app-state access from a WS handler; relies on
  the framework's auto ping/pong + close handshake.
- A `const use_evented = ...` (or CLI flag) switching `app.serve` ↔ `app.serveEvented`,
  demonstrating the same handler runs on both.
- `README.md`: run instructions + a minimal browser `<script>` WebSocket client snippet for
  manual testing (and a `wscat`/`websocat` command).

### Added: `docs/examples.md` — cookbook

Index of all five examples (`hello-service` + the four new). For each: a one-paragraph
"what it teaches", the `zig build run` command, a short key-code walkthrough (the
interesting handler/middleware/store snippet), and cross-links to the relevant
README/getting-started sections. A short intro explains the `examples/` convention
(path-dependency on the repo) and how to adapt one as a starting point.

### Modified: `.github/workflows/ci.yml` — example compile-checks

Add a step (or matrix entry) that runs `zig build` (compile only, like `bench-build`) in
each `examples/*/` dir, so a public-API change that breaks an example fails CI.

### Modified: `.gitignore` — ignore example caches

Ensure `examples/*/.zig-cache/` (and `examples/*/zig-out/`) are git-ignored.

### Modified: `CHANGELOG.md`

`[Unreleased]` → `### Added`: a note that example apps (`todo-api`, `auth-sessions`,
`file-upload`, `websocket-live`), a `docs/examples.md` cookbook, and a README logo were added.

## Data flow / structure

```
README.md            -> logo header + ## Examples table -> examples/* + docs/examples.md
docs/examples.md     -> per-example walkthrough -> examples/<name>/
examples/<name>/     -> build.zig(.zon path-dep) + src/main.zig + README.md
.github/workflows/ci.yml -> compile-check each examples/<name>/
```

## Error handling / correctness

- Every example **must compile**; CI compiles all four (the gate). `todo-api`/`auth-sessions`
  mutate state → `std.Thread.Mutex` guards every read/write (the plan confirms `State(*T)`
  with a non-const pointer compiles and that concurrent handler access is safe).
- `file-upload` creates its output dir at startup; uploads bounded by `max_body_size`;
  the README documents the output path.
- Examples pin `zax` by relative path (like `hello-service`) so they track local source and
  break loudly in CI on an API change.
- The logo `<picture>` uses `alt="zax"` so the README degrades gracefully where SVG/`<picture>`
  isn't rendered.

## Testing

- **CI compile-check per example** is the automated gate (these are demo apps, not
  unit-tested). The main `zig build test` suite is unaffected (examples are separate build
  graphs).
- Each example README has a **manual "run it"** section (curl/wscat) for human verification.

## Scope / version

Docs + examples only — **no library code change, no version bump**. One cohesive spec; the
plan decomposes into ~6–7 tasks: README logo + Examples section + `.gitignore`; one task per
example app (`todo-api`, `auth-sessions`, `file-upload`, `websocket-live`); `docs/examples.md`
cookbook; CI compile-check; CHANGELOG note. A true multi-user **chat** example is out of scope
(needs the future cross-connection broadcast code feature).

## Out of scope (future)

Cross-connection broadcast / chat example; a hosted docs site; permessage-deflate; converting
the README's inline snippets into the cookbook (the README stays as the reference; the cookbook
is example-centric).
