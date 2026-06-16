# Nested Routers / Route Groups (D4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `app.group(prefix, mwTuple)` returns a `Group` facade whose `get`/`post`/`put`/`delete`/`*With`/`route`/`routeWith` register routes at `prefix ++ pattern` with the group's middleware prepended. Groups nest via `Group.group`. Ordering is global → group(s) → route → handler.

**Architecture:** Purely additive. `Group(comptime prefix, comptime group_mws)` is a comptime-parameterized struct holding only `*App`; every method forwards to `App.routeWith(method, prefix ++ pattern, group_mws ++ route_mws, handler)`. Prefix concat (string `++`) and middleware concat (tuple `++`) are comptime → static, so registered patterns stay static-lifetime (required: the radix tree borrows pattern slices). All composition/ordering/zero-alloc behavior is inherited from D3's `routeWith`. **No changes to `router.zig`, `radix.zig`, `middleware.zig`, `dispatch`, or extract.**

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-nested-routers-design.md`. Branch: `feat/nested-routers`.

**Conventions:** Tests via `zig build test --summary all`. TDD. Do NOT touch main. Baseline = **117 tests** (after D3). Reuse the existing body-wrapping test middleware (`wrapG`/`wrapR`/`bodyH`) and `requireAuth`/`pingHandler` from the `src/server.zig` test section where possible.

---

## File Structure

- **Modify** `src/server.zig` — `Group(prefix, mws)` type + `group` method (near `routeWith`/the verb block), and integration tests.
- **Modify** `README.md`, `docs/getting-started.md` — route groups note.

---

## Task 1: `Group` facade + `App.group`, with integration tests

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing integration tests** — add to the test section of `src/server.zig`, reusing existing helpers (`TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`, `pingHandler`, `requireAuth`, and the body-wrapping `wrapG`/`wrapR`/`bodyH` added in D3 — verify their names/signatures and reuse; add `wrapGrp`/`wrapV1` like the existing `wrapR`). Use unused ports 18177–18180 (verify free).

```zig
fn wrapGrp(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "Grp({s})", .{r.body}));
}
fn wrapV1(ctx: *const TestApp.Context, next: *TestApp.Next) anyerror!Response {
    const r = try next.run();
    return Response.text(try std.fmt.allocPrint(ctx.arena, "V1({s})", .{r.body}));
}

test "group: prefixes routes; non-prefixed path 404s" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{});
    try api.get("/users", pingHandler);

    const port: u16 = 18177;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/users HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "200 OK") != null);
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n", &rb2), "404 Not Found") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: group middleware applies in order global -> group -> route -> handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    const api = app.group("/api", .{&wrapGrp});
    try api.getWith("/x", .{&wrapR}, bodyH);
    try app.get("/plain", bodyH); // no group mw

    const port: u16 = 18178;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, doRequest(io, port, "GET /api/x HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "G(Grp(R(H)))"));
    // Non-group route: only the global wrapper applies.
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, doRequest(io, port, "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n", &rb2), "G(H)"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: nested groups compose prefix and middleware" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.use(&wrapG);
    const api = app.group("/api", .{&wrapGrp});
    const v1 = api.group("/v1", .{&wrapV1});
    try v1.get("/items", bodyH);

    const port: u16 = 18179;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /api/v1/items HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r, "G(Grp(V1(H)))"));

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "group: shared middleware short-circuits group routes only" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    const api = app.group("/api", .{&requireAuth});
    try api.get("/secret", pingHandler);
    try app.get("/open", pingHandler);

    const port: u16 = 18180;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/secret HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "401 Unauthorized") != null);
    var rb2: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /api/secret HTTP/1.1\r\nHost: x\r\nAuthorization: t\r\n\r\n", &rb2), "200 OK") != null);
    var rb3: [2048]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /open HTTP/1.1\r\nHost: x\r\n\r\n", &rb3), "200 OK") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|no member named 'group'|FAIL"`
Expected: compile error — `App` has no `group` method.

- [ ] **Step 3: Add the `Group` type** — in `src/server.zig`, inside `App(AppState)` (near `routeWith`), add the `Group(prefix, group_mws)` generic struct exactly as in the spec's Component 1 (forwards `route`/`routeWith`/verbs/`*With`/nested `group` to `self.app`, using `prefix ++ pattern` and `group_mws ++ mws`).

- [ ] **Step 4: Add the `App.group` method** — as in the spec's Component 2:

```zig
        pub fn group(self: *Self, comptime prefix: []const u8, comptime mws: anytype) Group(prefix, mws) {
            return .{ .app = self };
        }
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — 4 new tests + 117 existing = 121. Report actual count.

Note for the implementer: if `group_mws ++ mws` (comptime tuple concatenation) is rejected by this Zig version, build the combined tuple via a comptime `inline for` into a static value inside `routeWith`/`Group` — do NOT introduce runtime/`gpa`/arena allocation. Report DONE_WITH_CONCERNS if the idiom needs adjusting.

- [ ] **Step 6: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 7: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): route groups via App.group / Group facade"
```

---

## Task 2: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README note** — in `README.md`, after the per-route middleware subsection (in the Middleware/routing area), add (match the existing code-block style; verify `zax.App`/`Api.Context`/`Api.Next` spelling):

```markdown
### Route groups

`app.group(prefix, .{ ...middleware })` returns a group that shares a path prefix
and middleware across its routes. Groups nest, and reuse the same verbs
(`get`/`post`/… and `getWith`/…). Order is global → group → route → handler:

​```zig
const api = app.group("/api", .{&requireAuth});
try api.get("/users", listUsers);          // GET /api/users (global -> requireAuth -> handler)

const v1 = api.group("/v1", .{&logRequests});
try v1.post("/items", createItem);         // POST /api/v1/items
​```
```

(Replace the `​` zero-width markers with plain triple backticks in the file.)

- [ ] **Step 2: getting-started note** — in `docs/getting-started.md`, after the per-route middleware subsection, add:

```markdown
### Route groups

`app.group(prefix, .{ &mw })` groups routes under a shared prefix and middleware;
groups nest. `const api = app.group("/api", .{&auth}); try api.get("/users", h);`
registers `GET /api/users`, running global → group → handler.
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document route groups"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines. New tests: 4 integration tests = **121 over the 117 baseline**.

---

## Self-review notes

- **Spec coverage:** `Group` type + `App.group` (Task 1); docs (Task 2). All spec components covered.
- **Minimal blast radius:** change confined to a new type + method in `src/server.zig`; `router.zig`, `radix.zig`, `middleware.zig`, `dispatch`, and extract untouched — verified by the existing suite staying green.
- **Reuses D3:** group registration is a thin forward to `App.routeWith` with concatenated prefix + middleware; ordering, static storage, and zero-allocation are inherited.
- **Ordering:** global → group(s) → route → handler, locked in by `G(Grp(R(H)))` and `G(Grp(V1(H)))` tests.
- **Static lifetime:** `prefix ++ pattern` and `group_mws ++ route_mws` are comptime, so registered patterns and middleware lists are static — satisfying the radix tree's borrowed-slice requirement with zero allocation.
- **Regression safety:** flat `route`/`get`/… and the global chain unchanged; group routes are ordinary registrations, so 404/405 and the D1 fallback behave as before.
- **Theme D complete** after D4 (D1 fallback, D2 wildcard, D3 per-route middleware, D4 route groups).
