# Per-Route Middleware (D3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `app.getWith(pattern, .{ &mwA, &mwB }, handler)` (and `postWith`/`putWith`/`deleteWith`/`routeWith`) attach middleware that run only for that route — after the global chain, before the handler, in tuple order.

**Architecture:** Purely additive. The stored handler is already a comptime `Wrap.call` of shape `ErasedHandler` (`*const fn (*const Ctx) anyerror!Response`). `routeWith` makes that wrapper run the route's own chain: `Chn.run(&route_mws, &realHandler, ctx)`. The global chain reaches `Wrap.call` as its terminal handler, so global → route → handler ordering falls out for free. The middleware tuple is materialized into a `const` array on the comptime `Wrap` struct (static storage, zero per-request allocation). **No changes to `router.zig`, `middleware.zig`, `dispatch`, `Found`, or the extract layer.**

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-per-route-middleware-design.md`. Branch: `feat/per-route-middleware`.

**Conventions:** Tests via `zig build test --summary all`. TDD. Do NOT touch main. Baseline = **113 tests** (after D2). Reuse existing test middleware where possible (`requireAuth`, `requestId` in the `src/server.zig` test section).

---

## File Structure

- **Modify** `src/server.zig` — `routeWith` method + `getWith`/`postWith`/`putWith`/`deleteWith` convenience verbs (next to the existing `route`/`get`/… block, after `delete`), and integration tests.
- **Modify** `README.md`, `docs/getting-started.md` — per-route middleware note.

---

## Task 1: `routeWith` + `*With` verbs, with integration tests

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing integration tests** — add to the test section of `src/server.zig`, using existing helpers (`TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`, `pingHandler`) and the existing `requireAuth` test middleware. Add two small body-wrapping middleware for the ordering test. Verify the exact names/signatures of `requireAuth`/`pingHandler` in the file first and adapt if needed (e.g. `Response.text`).

```zig
fn wrapG(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "G({s})", .{r.body}));
}
fn wrapR(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "R({s})", .{r.body}));
}
fn wrapR2(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "R2({s})", .{r.body}));
}
fn bodyH() Response {
    return Response.text("H");
}

test "per-route middleware: scoped to its route + short-circuits" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/open", pingHandler);
    try app.getWith("/admin", .{&requireAuth}, pingHandler);

    const port: u16 = 18173;
    var loop_fut = startTestApp(io, &app, port);

    // Open route: per-route mw does NOT apply -> 200 without auth.
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /open HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);

    // Admin route, no auth -> per-route mw short-circuits to 401.
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "401 Unauthorized") != null);

    // Admin route, with auth -> handler runs.
    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: t\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "per-route middleware: order is global -> route -> handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    try app.getWith("/x", .{ &wrapR, &wrapR2 }, bodyH);

    const port: u16 = 18174;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /x HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    // global wraps route-chain (in tuple order) wraps handler.
    try testing.expect(std.mem.endsWith(u8, r, "G(R(R2(H)))"));

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|no member named 'getWith'|FAIL"`
Expected: compile error — `App` has no `getWith`/`routeWith` method.

- [ ] **Step 3: Add `routeWith`** — in `src/server.zig`, after the existing `route` method (and before/around the `get`/`post`/… verbs), add:

```zig
        /// Like `route`, but `mws` (a comptime tuple of `Middleware`) run only
        /// for this route — after the global chain, before the handler, in tuple
        /// order. The tuple is materialized into static storage (no allocation).
        pub fn routeWith(
            self: *Self,
            method: request.Method,
            pattern: []const u8,
            comptime mws: anytype,
            comptime handler: anytype,
        ) std.mem.Allocator.Error!void {
            const Wrap = struct {
                const list: [mws.len]Chn.Middleware = mws;
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

- [ ] **Step 4: Add the `*With` convenience verbs** — after the existing `delete` verb:

```zig
        pub fn getWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.GET, pattern, mws, h);
        }
        pub fn postWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.POST, pattern, mws, h);
        }
        pub fn putWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.PUT, pattern, mws, h);
        }
        pub fn deleteWith(self: *Self, pattern: []const u8, comptime mws: anytype, comptime h: anytype) !void {
            return self.routeWith(.DELETE, pattern, mws, h);
        }
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the two new tests plus every existing test (existing `route`/`get`/… and the global chain are untouched).

Note for the implementer: if `const list: [mws.len]Chn.Middleware = mws;` does not coerce the tuple cleanly in this Zig version, build the array with an `inline for` instead (still a comptime struct-level `const` for static storage) — do NOT fall back to runtime/`gpa` allocation. Report it as a concern if the idiom needs adjusting.

- [ ] **Step 6: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 7: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): per-route middleware via getWith/routeWith"
```

---

## Task 2: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README note** — in `README.md`, just after the `## Middleware` section, add (match the existing Middleware code-block style; verify `zax.App`/`Context`/`Next`/`Response` spelling against the existing example):

```markdown
### Per-route middleware

`getWith` / `postWith` / `putWith` / `deleteWith` (and the generic `routeWith`)
attach middleware to a single route. They run after the global chain and before
the handler, in tuple order:

​```zig
fn requireAuth(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    if (ctx.req.header("authorization") == null) return zax.Response.fromStatus(.unauthorized);
    return next.run();
}

try app.getWith("/admin", .{&requireAuth}, adminHandler);
try app.get("/", homeHandler); // unchanged, no per-route middleware
​```
```

(Replace the `​` zero-width markers with plain triple backticks in the file.)

- [ ] **Step 2: getting-started note** — in `docs/getting-started.md`, after the `### Middleware` subsection, add:

```markdown
### Per-route middleware

`app.getWith(pattern, .{ &mwA, &mwB }, handler)` (also `postWith`/`putWith`/
`deleteWith`/`routeWith`) runs middleware for that route only — after the global
chain, before the handler, in tuple order.
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document per-route middleware"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines. New tests: 2 integration tests = **115 over the 113 baseline**.

---

## Self-review notes

- **Spec coverage:** `routeWith` + four `*With` verbs (Task 1); docs (Task 2). All spec components covered.
- **Minimal blast radius:** change confined to new methods in `src/server.zig`; `router.zig`, `middleware.zig`, `dispatch`, `Found`, and extract are untouched — verified by the existing suite staying green.
- **Ordering:** global `Chn.run(mws, Wrap.call, ctx)` → `Wrap.call` runs `Chn.run(route_mws, real, ctx)` → handler. The `G(R(R2(H)))` test locks in global → route(tuple order) → handler.
- **Zero allocation:** the middleware tuple becomes a static `const` array on the comptime `Wrap`; `Chn.run` borrows it. No registration-time or per-request allocation.
- **Regression safety:** `route`/`get`/`post`/`put`/`delete` and the global chain are unchanged; per-route middleware run only on `.found`, so 404/405 and the D1 fallback behave exactly as before.
- **Type safety:** a wrong-signature middleware fails at comptime in the tuple→array coercion (clear error), not at runtime.
