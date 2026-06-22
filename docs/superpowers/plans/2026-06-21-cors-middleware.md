# CORS middleware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in `cors` middleware factory that answers `OPTIONS` preflight (204) and decorates responses with the correct `Access-Control-*` headers.

**Architecture:** A new `src/cors.zig` defines a comptime `Cors` config and `cors(comptime Ctx, comptime config)` returning a `middleware.Chain(Ctx).Middleware`. The generated middleware resolves the allow-origin (wildcard or allowlist-reflect), short-circuits preflight, and post-processes actual responses via the existing `Response.withHeader`. Wired via two `root.zig` re-exports.

**Tech Stack:** Zig 0.16.

## Global Constraints

- Zig 0.16. Additive: new file `src/cors.zig` + 2 root re-exports. No `error.zig` change, no change to existing middleware/routing/response behavior.
- Comptime config: `cors(comptime Ctx: type, comptime config: Cors) middleware.Chain(Ctx).Middleware`. The chain's `Middleware` is a bare fn pointer — config MUST be comptime (no runtime/AppState config).
- Origin policy: `.any` → `*` (or reflect when credentials); `.list` → reflect request `Origin` iff exact-match a list entry, else emit ZERO CORS headers. Never emit `*` when `credentials = true` — reflect the concrete origin.
- Reflected origin (allow != "*") → also emit `vary: origin`.
- Preflight = `method == .OPTIONS` AND `Access-Control-Request-Method` header present → short-circuit `204` (handler NOT called).
- No `Origin` header → pass through, no CORS headers.
- Header names lowercase (framework convention); append via `Response.withHeader(arena, name, value)`.
- Test baseline: current `v0.11.0` branch green (`zig build test --summary all`, 0 failures). `timeout` not on this mac — run zig directly. No timing-sensitive paths → single run.

---

### Task 1: cors config + factory + unit tests

**Files:**
- Create: `src/cors.zig`
- Modify: `src/root.zig` (two re-exports)

**Interfaces:**
- Produces: `pub const Cors = struct { pub const Origins = union(enum){ any, list: []const []const u8 }; origins: Origins = .any, methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS", allow_headers: []const u8 = "Content-Type", expose_headers: ?[]const u8 = null, credentials: bool = false, max_age: ?u32 = null }`; `pub fn cors(comptime Ctx: type, comptime config: Cors) middleware.Chain(Ctx).Middleware`.

- [ ] **Step 1: Write the module + failing tests (TDD).**

Create `src/cors.zig`:

```zig
//! CORS middleware (built-in). `cors(Ctx, config)` returns a `Chain(Ctx)`
//! middleware that answers `OPTIONS` preflight with 204 and decorates actual
//! responses with `Access-Control-*` headers. Config is comptime. Header names
//! are lowercase (framework convention). The cookie value / origins are emitted
//! as configured (caller-controlled, not request input) except the reflected
//! request Origin, which is matched exactly against the allowlist.

const std = @import("std");
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

pub const Cors = struct {
    pub const Origins = union(enum) {
        any,
        list: []const []const u8,
    };
    origins: Origins = .any,
    methods: []const u8 = "GET, POST, PUT, DELETE, OPTIONS",
    allow_headers: []const u8 = "Content-Type",
    expose_headers: ?[]const u8 = null,
    credentials: bool = false,
    max_age: ?u32 = null,
};

pub fn cors(comptime Ctx: type, comptime config: Cors) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            const origin = ctx.req.header("origin");
            const allow = resolveAllowOrigin(config, origin);

            const is_preflight = ctx.req.method == .OPTIONS and
                ctx.req.header("access-control-request-method") != null;

            if (is_preflight) {
                return decorate(ctx.arena, Response.fromStatus(.no_content), config, allow, true);
            }
            const r = try next.run();
            return decorate(ctx.arena, r, config, allow, false);
        }
    };
    return Impl.mw;
}

/// The value for `Access-Control-Allow-Origin`, or null when no CORS headers
/// should be emitted (no Origin, or allowlist miss).
fn resolveAllowOrigin(comptime config: Cors, origin: ?[]const u8) ?[]const u8 {
    const o = origin orelse return null;
    switch (config.origins) {
        .any => return if (config.credentials) o else "*",
        .list => |allowed| {
            for (allowed) |entry| if (std.mem.eql(u8, entry, o)) return o;
            return null;
        },
    }
}

/// Append the CORS headers to `r`. Returns `r` unchanged when `allow` is null.
fn decorate(arena: std.mem.Allocator, r0: Response, comptime config: Cors, allow: ?[]const u8, preflight: bool) !Response {
    const a = allow orelse return r0;
    var r = try r0.withHeader(arena, "access-control-allow-origin", a);
    if (!std.mem.eql(u8, a, "*")) r = try r.withHeader(arena, "vary", "origin");
    if (config.credentials) r = try r.withHeader(arena, "access-control-allow-credentials", "true");
    if (preflight) {
        r = try r.withHeader(arena, "access-control-allow-methods", config.methods);
        r = try r.withHeader(arena, "access-control-allow-headers", config.allow_headers);
        if (config.max_age) |ma| {
            var nbuf: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{ma}) catch unreachable;
            r = try r.withHeader(arena, "access-control-max-age", ns);
        }
    } else if (config.expose_headers) |eh| {
        r = try r.withHeader(arena, "access-control-expose-headers", eh);
    }
    return r;
}
```

Verify against the installed Zig 0.16: `Response.withHeader` signature (`src/http/response.zig`), `Request.method`/`Request.header` and `Method.OPTIONS` (`src/http/request.zig`), and `middleware.Chain(Ctx).Middleware`/`.Next` (`src/middleware.zig`). If a signature differs, match the real one.

- [ ] **Step 2: Unit tests** (append to `cors.zig`):

```zig
const testing = std.testing;
const Request = @import("http/request.zig").Request;
const Header = @import("http/request.zig").Header;
const Method = @import("http/request.zig").Method;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
    ran: *bool,
};

fn fakeReq(method: Method, headers: []const Header) Request {
    return .{ .method = method, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

fn okHandler(ctx: *const TestCtx) anyerror!Response {
    ctx.ran.* = true;
    return Response.text("ok");
}

/// First value of header `name` on `r`, or null.
fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Run `config`'s cors middleware over a request and return the response.
fn runCors(arena: std.mem.Allocator, comptime config: Cors, req: *const Request, ran: *bool) !Response {
    const C = middleware.Chain(TestCtx);
    var ctx = TestCtx{ .req = req, .arena = arena, .ran = ran };
    const mws = [_]C.Middleware{cors(TestCtx, config)};
    return C.run(&mws, &okHandler, &ctx);
}

test "cors any: GET with Origin gets wildcard, no vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any }, &req, &ran);
    try testing.expect(ran);
    try testing.expectEqualStrings("*", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "vary"));
}

test "cors list match: reflects origin + vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .{ .list = &.{"https://a.com"} } }, &req, &ran);
    try testing.expectEqualStrings("https://a.com", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqualStrings("origin", hdr(r, "vary").?);
}

test "cors list miss: no CORS headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://evil.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .{ .list = &.{"https://a.com"} } }, &req, &ran);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-origin"));
}

test "cors credentials + any: reflects concrete origin, not star" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any, .credentials = true }, &req, &ran);
    try testing.expectEqualStrings("https://a.com", hdr(r, "access-control-allow-origin").?);
    try testing.expectEqualStrings("true", hdr(r, "access-control-allow-credentials").?);
    try testing.expectEqualStrings("origin", hdr(r, "vary").?);
}

test "cors preflight: 204 + allow-methods/headers, handler not called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.OPTIONS, &.{
        .{ .name = "Origin", .value = "https://a.com" },
        .{ .name = "Access-Control-Request-Method", .value = "GET" },
    });
    const r = try runCors(arena.allocator(), .{ .origins = .any, .max_age = 600 }, &req, &ran);
    try testing.expect(!ran);
    try testing.expectEqual(@import("http/response.zig").Status.no_content, r.status);
    try testing.expectEqualStrings("*", hdr(r, "access-control-allow-origin").?);
    try testing.expect(hdr(r, "access-control-allow-methods") != null);
    try testing.expect(hdr(r, "access-control-allow-headers") != null);
    try testing.expectEqualStrings("600", hdr(r, "access-control-max-age").?);
}

test "cors: no Origin passes through with no CORS headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{});
    const r = try runCors(arena.allocator(), .{ .origins = .any }, &req, &ran);
    try testing.expect(ran);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "access-control-allow-origin"));
}

test "cors expose_headers on actual response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ran = false;
    const req = fakeReq(.GET, &.{.{ .name = "Origin", .value = "https://a.com" }});
    const r = try runCors(arena.allocator(), .{ .origins = .any, .expose_headers = "X-Total" }, &req, &ran);
    try testing.expectEqualStrings("X-Total", hdr(r, "access-control-expose-headers").?);
}
```

- [ ] **Step 3: Export** in `src/root.zig` (near the middleware export):

```zig
pub const Cors = @import("cors.zig").Cors;
pub const cors = @import("cors.zig").cors;
```
Confirm `Cors`/`cors` are not already public symbols.

- [ ] **Step 4: Gate** — `zig build test --summary all` green (RED first to confirm tests fail without the impl, then GREEN).

- [ ] **Step 5: Commit** — `feat(cors): built-in CORS middleware (preflight + origin policies)`.

---

### Task 2: e2e test in server.zig

**Files:**
- Modify: `src/server.zig` (add a test-only route + e2e test)

**Interfaces:**
- Consumes: `zax.cors` / `App(S).Context` (Task 1). Register with `try app.use(zax.cors(@TypeOf(app.*).Context, .{ .origins = .any }))` — adapt to how the surrounding e2e tests spell the app/Context type and call `app.use` (study the existing middleware-using e2e tests, if any, and the Headers e2e test-app setup).

- [ ] **Step 1:** Mirror the Headers/forwarded e2e (`doRequest` loopback + test-app setup). Register a `cors(.any)` middleware via `app.use`, a `GET /x` route, on a fresh port. Two requests:

```zig
test "e2e: cors preflight 204 and actual request gets allow-origin" {
    // ... standard test-app setup on a fresh port; app.use(cors(...)); app.get("/x", handler) ...
    var rb1: [1024]u8 = undefined;
    const pre = doRequest(io, port,
        "OPTIONS /x HTTP/1.1\r\nHost: x\r\nOrigin: https://a.com\r\nAccess-Control-Request-Method: GET\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, pre, "HTTP/1.1 204") != null);
    try testing.expect(std.mem.indexOf(u8, pre, "access-control-allow-methods:") != null);

    var rb2: [1024]u8 = undefined;
    const act = doRequest(io, port, "GET /x HTTP/1.1\r\nHost: x\r\nOrigin: https://a.com\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, act, "access-control-allow-origin: *\r\n") != null);
}
```
(Adapt the handler signature, `app.use`/`app.get` calls, and teardown to the EXACT conventions already in `src/server.zig` — do not invent new ones. If `app.use` needs the Context type spelled, use the form the file already uses for `App(S).Context`.)

- [ ] **Step 2: Gate** — `zig build test --summary all` green.

- [ ] **Step 3: Commit** — `test(cors): e2e preflight + actual request over loopback`.

---

### Task 2b: auto-preflight in dispatch

**Discovered during Task 2:** global `app.use` middleware runs only after a route
matches; the `.method_not_allowed` branch returns `405` before the chain
(`src/server.zig:766`). So an `OPTIONS` preflight to a path with no `OPTIONS`
route `405`s before CORS can answer. This task makes preflight work without a
registered `OPTIONS` route.

**Files:**
- Modify: `src/server.zig` (`dispatch`, the `.method_not_allowed` branch ~line 766; add a unit/e2e test; revise the Task 2 e2e to NOT register an `OPTIONS` route)

**Interfaces:**
- Consumes: `zax.cors` (Task 1), `Chn.run`, `makeCtx`, `allowHeader`, `Response.fromStatus`.

- [ ] **Step 1: Change the `.method_not_allowed` branch** in `dispatch` so OPTIONS runs the chain:

```zig
.method_not_allowed => |allowed| {
    const ctx = self.makeCtx(io, req, &.{}, arena, request_id);
    if (req.method == .OPTIONS) {
        // Auto-preflight: run the global chain so a CORS middleware can
        // answer the preflight (it short-circuits to 204 before the
        // terminal). If nothing handles it, fall through to the normal 405.
        const term = struct {
            fn call(_: *const Ctx) anyerror!Response {
                return Response.fromStatus(.method_not_allowed);
            }
        }.call;
        const resp = Chn.run(self.mws.items, &term, &ctx) catch |e| return self.renderError(e, &ctx);
        if (resp.status == .method_not_allowed) {
            var r = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
            r = r.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch r;
            return r;
        }
        return resp;
    }
    var resp = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
    resp = resp.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch resp;
    return resp;
},
```
Confirm `Response`, `Ctx`, `Chn`, `allowHeader`, `err_mod` are all in scope in `dispatch` (they are — see the existing branch). Keep the non-OPTIONS path byte-for-byte unchanged.

- [ ] **Step 2: e2e — auto-preflight without an OPTIONS route.** Revise the Task 2 e2e (`"e2e: cors preflight..."`) so it registers ONLY a `GET /x` route (NO `app.options`/`OPTIONS` route). Assert the preflight still returns `204` + `access-control-allow-methods:` purely via the middleware:

```zig
// app.use(zax.cors(<Ctx>, .{ .origins = .any }));  app.get("/x", handler);  (no OPTIONS route)
const pre = doRequest(io, port,
    "OPTIONS /x HTTP/1.1\r\nHost: x\r\nOrigin: https://a.com\r\nAccess-Control-Request-Method: GET\r\n\r\n", &rb1);
try testing.expect(std.mem.indexOf(u8, pre, "HTTP/1.1 204") != null);
try testing.expect(std.mem.indexOf(u8, pre, "access-control-allow-methods:") != null);
```

- [ ] **Step 3: e2e/unit — OPTIONS 405 preserved without CORS.** Add a test: a GET-only route, NO cors middleware, `OPTIONS /x` → still `405` with an `allow:` header (existing behavior unbroken).

- [ ] **Step 4: Gate** — `zig build test --summary all` green.

- [ ] **Step 5: Commit** — `feat(server): auto-preflight — run global chain on OPTIONS 405 so CORS answers`.

---

### Task 3: docs

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `CHANGELOG.md`

- [ ] **Step 1:** `README.md` — in the middleware section, document the built-in `cors` + `Cors` config: the comptime-factory usage (`try app.use(zax.cors(App(S).Context, .{ ... }))`), origin policies (`.any` / `.list`), credentials/preflight behavior, and a snippet. Match neighboring doc format.
- [ ] **Step 2:** `docs/getting-started.md` — add `cors` if it covers middleware; else leave and note it.
- [ ] **Step 3:** `CHANGELOG.md` — entry under `[Unreleased]` → `### Added` (match existing style).
- [ ] **Step 4: Gate** — docs match shipped API; `zig build test` still green.
- [ ] **Step 5: Commit** — `docs(cors): document the built-in CORS middleware`.

---

## Verification (end-to-end, after all tasks)

1. `zig build test --summary all` — all green (unit + e2e).
2. `zig build run` with a `cors` middleware; JS-fetch smoke (curl hooked): `OPTIONS` preflight → 204 + Allow-* ; `GET` with `Origin` → `access-control-allow-origin` on the response.
3. `grep -n "cors\|Cors" README.md` — appears in the middleware docs.
4. Version is `0.11.0` in `build.zig.zon`.
