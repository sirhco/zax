# Fallback Handler (D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `App.fallback(handler)` runs a normal handler for unmatched requests (custom 404 / SPA index), through the global middleware chain.

**Architecture:** Store a type-erased fallback handler on `App` (wrapped like a route). The `dispatch` `not_found` branch runs it through the middleware chain when set, else the existing default 404.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-fallback-handler-design.md`. Branch: `feat/fallback-handler`.

**Conventions:** Tests via `zig build test --summary all`. TDD. Do NOT touch main. The field is `fallback_handler` (the method is `fallback` — field/method can't share a name in Zig).

---

## File Structure

- **Modify** `src/server.zig` — `fallback_handler` field, `fallback` method, `not_found` dispatch branch, integration tests.
- **Modify** `README.md`, `docs/getting-started.md` — fallback note.

---

## Task 1: `App.fallback` + `not_found` dispatch through it

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing integration tests** — add to the test section of `src/server.zig`. They use existing helpers `TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`. (There are existing test handlers like `pingHandler`; `Middleware`/`Next` are `TestApp.Middleware`/`TestApp.Next`.)

```zig
fn customNotFound() Response {
    return .{ .status = .not_found, .body = "custom-404" };
}
fn spaIndex() Response {
    return Response.text("spa-index");
}
fn fallbackTagMw(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-fallback", "1");
}

test "fallback: custom 404 handler for unmatched routes" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);
    try app.fallback(customNotFound);

    const port: u16 = 18170;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "404 Not Found") != null);
    try testing.expect(std.mem.endsWith(u8, r, "custom-404"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "fallback: SPA-style 200 + middleware applies; 405 unaffected" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&fallbackTagMw);
    try app.get("/ping", pingHandler);
    try app.fallback(spaIndex);

    const port: u16 = 18171;
    var loop_fut = startTestApp(io, &app, port);

    // Unmatched -> fallback returns 200, and the global middleware tagged it.
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /anything HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "x-fallback: 1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r, "spa-index"));

    // Wrong method on a registered path -> 405 (fallback NOT applied).
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "DELETE /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "405 Method Not Allowed") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|no member named 'fallback'|FAIL"`
Expected: compile error — `App` has no `fallback` method.

- [ ] **Step 3: Add the `fallback_handler` field** — in `src/server.zig`, inside `App(AppState)`'s struct, add the field next to the existing `mws` field (e.g. immediately after `mws: std.ArrayListUnmanaged(Chn.Middleware) = .empty,`):

```zig
        fallback_handler: ?ErasedHandler = null,
```

- [ ] **Step 4: Add the `fallback` method** — add it after the existing `use` method (it mirrors `route`'s comptime wrapping but stores instead of registering):

```zig
        /// Set the handler run for requests that match no route (a custom 404 or
        /// an SPA index fallback). Runs through the global middleware chain;
        /// applies to not-found only (not method-not-allowed). The handler must
        /// not use `Path` (an unmatched route has no captured params).
        pub fn fallback(self: *Self, comptime handler: anytype) std.mem.Allocator.Error!void {
            const Wrap = struct {
                fn call(ctx: *const Ctx) anyerror!Response {
                    return extract.callHandler(handler, ctx.*);
                }
            };
            self.fallback_handler = &Wrap.call;
        }
```

- [ ] **Step 5: Update the `not_found` dispatch branch** — in `src/server.zig`'s `dispatch`, replace:

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

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the two new fallback tests plus every existing test (a not_found with no fallback set still hits the default 404; the existing `/nope` 404 test is unchanged).

- [ ] **Step 7: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): App.fallback handler for unmatched routes"
```

---

## Task 2: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README note** — in `README.md`, in the routing-related area (after the `## Middleware` section, before `## Error handling`), add:

```markdown
## Fallback

Register a handler for requests that match no route — a custom 404 or an SPA
index fallback. It runs through the global middleware chain (not-found only;
method-not-allowed still returns 405):

​```zig
fn notFound() zax.Response { return zax.Response.fromStatus(.not_found); }
try app.fallback(notFound);

// SPA: serve index.html for any unknown path
fn spa(files: zax.Files) !zax.Response { return files.file("static/index.html"); }
try app.fallback(spa);
​```
```

(Replace the `​` zero-width markers with plain triple backticks in the file.)

- [ ] **Step 2: getting-started note** — in `docs/getting-started.md`, after the middleware/responses area, add:

```markdown
### Fallback

`app.fallback(handler)` handles unmatched requests (custom 404 or SPA index); it
runs through the global middleware chain.
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document App.fallback"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines (Task 1 +2 = 105 over the 103 baseline).

---

## Self-review notes (already applied)

- **Spec coverage:** `fallback_handler` field + `fallback` method + `not_found` branch (Task 1); docs (Task 2). All spec components covered.
- **Type consistency:** field `fallback_handler: ?ErasedHandler`; method `fallback(comptime handler) std.mem.Allocator.Error!void` wrapping via `extract.callHandler` (same as `route`); dispatch uses `self.fallback_handler` + `Chn.run(self.mws.items, fb, &ctx)`. `ErasedHandler`/`Ctx`/`Chn`/`extract`/`err_mod` are existing `App` decls.
- **No placeholders:** complete code in every step; the README nested fences use the zero-width-marker note.
- **Name-collision avoided:** field `fallback_handler` ≠ method `fallback`.
- **Regression safety:** no-fallback path is byte-identical (the `if` falls through to the existing `renderError(NotFound)`); 405 branch untouched (tested).
```
