# Error Handling & Rejections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Map extractor failures and handler errors to correct HTTP statuses (instead of a blanket 500), give handlers a canonical `zax.Error` set usable with `try`, and add one `on_error` hook for custom rendering.

**Architecture:** A central `classify(anyerror) → ErrorInfo{status, reason}` table is applied at the dispatcher's existing `catch` boundary. Errors keep flowing as plain Zig errors through the middleware chain (no extractor/`callHandler`/middleware signature changes). 404/405 route through the same renderer; 405 emits an `Allow` header.

**Tech Stack:** Zig 0.16.0, `std.Io`. Spec: `docs/superpowers/specs/2026-06-15-error-handling-rejections-design.md`. Branch: `feat/error-handling`.

**Conventions:** Tests run via `zig build test` (whole suite; the single-file `zig test` can't resolve cross-dir imports). Each task is TDD: failing test → verify fail → implement → verify pass → commit.

---

## File Structure

- **Create** `src/error.zig` — `ErrorInfo`, canonical `Error` set, `classify()`. One responsibility: error→status mapping.
- **Modify** `src/http/response.zig` — add `Status.too_many_requests` (429).
- **Modify** `src/root.zig` — export the error module/types.
- **Modify** `src/server.zig` — `App.on_error` field + `onError` setter, `makeCtx`/`renderError` helpers, dispatch error mapping, 404/405 through renderer, 405 `Allow`. Integration tests.
- **Modify** `README.md`, `docs/getting-started.md` — error-handling docs.

---

## Task 1: Add the 429 status

**Files:**
- Modify: `src/http/response.zig` (the `Status` enum + `reason`)

- [ ] **Step 1: Write the failing test**

Add to the test section of `src/http/response.zig` (after the existing `status-only` test):

```zig
test "too_many_requests status code and reason" {
    try testing.expectEqual(@as(u16, 429), Status.too_many_requests.code());
    try testing.expectEqualStrings("Too Many Requests", Status.too_many_requests.reason());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -E "error|too_many"`
Expected: compile error — `Status` has no member `too_many_requests`.

- [ ] **Step 3: Implement**

In `src/http/response.zig`, add the enum member (after `conflict = 409,` / `length_required = 411,`):

```zig
    too_many_requests = 429,
```

And add its `reason` arm (in the `reason` switch, after the `length_required` arm):

```zig
            .too_many_requests => "Too Many Requests",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: PASS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): add 429 Too Many Requests status"
```

---

## Task 2: The error module (`ErrorInfo`, `Error`, `classify`) + exports

**Files:**
- Create: `src/error.zig`
- Modify: `src/root.zig` (export so its tests run under `zig build test`)

- [ ] **Step 1: Write `src/error.zig` with `classify` and its unit tests**

Create `src/error.zig`:

```zig
//! Error model: a canonical handler-facing error set and a central mapping from
//! any error value to an HTTP status + short reason. Zig errors are payload-less
//! global identities, so one table classifies both the canonical set and the
//! extractor error tags unambiguously.

const std = @import("std");
const Status = @import("http/response.zig").Status;

pub const ErrorInfo = struct {
    status: Status,
    reason: []const u8,
};

/// Canonical errors a handler can `return` to produce a specific status, e.g.
/// `const u = store.get(id) orelse return error.NotFound;`
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

/// Map any error to a status + reason. Covers the canonical `Error` set and the
/// extractor error tags; everything else is a 500.
pub fn classify(e: anyerror) ErrorInfo {
    return switch (e) {
        error.BadRequest => .{ .status = .bad_request, .reason = "bad request" },
        error.Unauthorized => .{ .status = .unauthorized, .reason = "unauthorized" },
        error.Forbidden => .{ .status = .forbidden, .reason = "forbidden" },
        error.NotFound => .{ .status = .not_found, .reason = "not found" },
        error.MethodNotAllowed => .{ .status = .method_not_allowed, .reason = "method not allowed" },
        error.Conflict => .{ .status = .conflict, .reason = "conflict" },
        error.UnprocessableEntity => .{ .status = .unprocessable_entity, .reason = "unprocessable entity" },
        error.TooManyRequests => .{ .status = .too_many_requests, .reason = "too many requests" },
        error.Internal => .{ .status = .internal_server_error, .reason = "internal server error" },
        error.NotImplemented => .{ .status = .not_implemented, .reason = "not implemented" },
        error.ServiceUnavailable => .{ .status = .service_unavailable, .reason = "service unavailable" },

        // Extractor tags (from path.zig/query.zig/json.zig/scalar.zig).
        error.MissingPathParam => .{ .status = .bad_request, .reason = "missing path parameter" },
        error.MissingQueryParam => .{ .status = .bad_request, .reason = "missing query parameter" },
        error.InvalidScalar => .{ .status = .bad_request, .reason = "invalid parameter" },
        error.InvalidEnum => .{ .status = .bad_request, .reason = "invalid parameter" },
        error.InvalidJson => .{ .status = .unprocessable_entity, .reason = "invalid JSON body" },

        else => .{ .status = .internal_server_error, .reason = "internal server error" },
    };
}

const testing = std.testing;

test "classify maps the canonical Error set" {
    try testing.expectEqual(Status.bad_request, classify(Error.BadRequest).status);
    try testing.expectEqual(Status.not_found, classify(Error.NotFound).status);
    try testing.expectEqual(Status.conflict, classify(Error.Conflict).status);
    try testing.expectEqual(Status.too_many_requests, classify(Error.TooManyRequests).status);
    try testing.expectEqual(Status.service_unavailable, classify(Error.ServiceUnavailable).status);
    try testing.expectEqualStrings("not found", classify(Error.NotFound).reason);
}

test "classify maps extractor tags to 4xx" {
    try testing.expectEqual(Status.bad_request, classify(error.MissingPathParam).status);
    try testing.expectEqual(Status.bad_request, classify(error.InvalidScalar).status);
    try testing.expectEqual(Status.bad_request, classify(error.MissingQueryParam).status);
    try testing.expectEqual(Status.unprocessable_entity, classify(error.InvalidJson).status);
    try testing.expectEqualStrings("invalid JSON body", classify(error.InvalidJson).reason);
}

test "classify maps unknown errors to 500" {
    const info = classify(error.SomethingNobodyDefined);
    try testing.expectEqual(Status.internal_server_error, info.status);
    try testing.expectEqualStrings("internal server error", info.reason);
}
```

- [ ] **Step 2: Export from `src/root.zig`**

In `src/root.zig`, add after the `Forwarded` export line (`pub const Forwarded = @import("extract/forwarded.zig").Forwarded;`):

```zig

// --- Error model ---
pub const err = @import("error.zig");
pub const ErrorInfo = err.ErrorInfo;
pub const Error = err.Error;
pub const classify = err.classify;
```

- [ ] **Step 3: Run tests to verify the new ones pass**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: PASS; test count increases by 3 (the three `classify` tests).

- [ ] **Step 4: Commit**

```bash
git add src/error.zig src/root.zig
git commit -m "feat(error): add ErrorInfo, canonical Error set, and classify()"
```

---

## Task 3: Dispatch error mapping + `on_error` hook

This rewrites the `found` branch of `dispatch` to map errors via `classify` and the optional hook, and adds the App plumbing.

**Files:**
- Modify: `src/server.zig` (imports, `App` decls/fields, `dispatch`, tests)

- [ ] **Step 1: Write the failing integration tests**

Add to the test section of `src/server.zig` (after the `forwarded:` test, before `middleware:` test). These use the existing `TestApp`, `Db`, `pingHandler`, `echoId`, `jsonHandler`, `startTestApp`, `doRequest` helpers already in the file.

```zig
fn failNotFound() !Response {
    return err_mod.Error.NotFound;
}
fn failConflict() !Response {
    return err_mod.Error.Conflict;
}
fn failUnknown() !Response {
    return error.SomeAppSpecificThing;
}

fn jsonErrorRenderer(e: anyerror, info: err_mod.ErrorInfo, ctx: *const TestApp.Context) Response {
    _ = e;
    const body = std.fmt.allocPrint(ctx.arena, "{{\"error\":\"{s}\"}}", .{info.reason}) catch
        return Response.fromStatus(info.status);
    var r = Response.jsonRaw(body);
    r.status = info.status;
    return r;
}

test "errors: extractor failures map to 4xx, handler errors to mapped status" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/users/:id", echoId); // Path(struct{ id: u64 })
    try app.post("/u", jsonHandler); // Json(struct{ name })
    try app.get("/nf", failNotFound);
    try app.get("/conflict", failConflict);
    try app.get("/boom", failUnknown);

    const port: u16 = 18100;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // Non-numeric path param -> 400 (was 500 before this change).
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /users/abc HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "400 Bad Request") != null);
    // Malformed JSON body -> 422.
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "POST /u HTTP/1.1\r\nContent-Length: 9\r\n\r\n{not json", &rb), "422 Unprocessable Entity") != null);
    // Handler canonical errors.
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /nf HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /conflict HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "409 Conflict") != null);
    // Unknown handler error -> 500.
    try testing.expect(std.mem.indexOf(u8, doRequest(io, port, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n", &rb), "500 Internal Server Error") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "errors: on_error hook renders custom JSON bodies" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    app.onError(&jsonErrorRenderer);
    try app.get("/nf", failNotFound);

    const port: u16 = 18101;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /nf HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "404 Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, r, "content-type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, r, "{\"error\":\"not found\"}"));

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "error:|not found|no member"`
Expected: compile error — `err_mod` undefined and `TestApp` has no `onError`/`Context`-typed error handler yet.

- [ ] **Step 3: Add the `err_mod` import**

In `src/server.zig`, add to the imports block (after `const middleware = @import("middleware.zig");`):

```zig
const err_mod = @import("error.zig");
```

- [ ] **Step 4: Add `ErrorHandler`, the `on_error` field, and `onError`**

In `src/server.zig`, inside `App(AppState)`'s `return struct { ... }`:

Add this public decl right after the existing `pub const Next = Chn.Next;` line:

```zig
        /// Renders an error into a Response. Receives the raw error, a computed
        /// default classification, and the request context. Infallible.
        pub const ErrorHandler = *const fn (err: anyerror, info: err_mod.ErrorInfo, ctx: *const Ctx) Response;
```

Add this field right after the existing `mws: std.ArrayListUnmanaged(Chn.Middleware) = .empty,` line:

```zig
        on_error: ?ErrorHandler = null,
```

Add this method right after the existing `use` method:

```zig
        /// Set a custom error renderer (e.g. to emit JSON error bodies).
        pub fn onError(self: *Self, h: ErrorHandler) void {
            self.on_error = h;
        }
```

- [ ] **Step 5: Add `makeCtx` and `renderError` helpers and rewrite the `found` branch**

In `src/server.zig`, replace the entire `dispatch` function body. The current function is:

```zig
        fn dispatch(self: *Self, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch
                return Response.fromStatus(.bad_request);

            switch (outcome) {
                .not_found => return Response.fromStatus(.not_found),
                .method_not_allowed => return Response.fromStatus(.method_not_allowed),
                .found => |f| {
                    const ctx = Ctx{
                        .req = req,
                        .params = f.params,
                        .state = self.state,
                        .arena = arena.allocator(),
                        .trust_forwarded = self.opts.trust_forwarded,
                    };
                    return Chn.run(self.mws.items, f.handler, &ctx) catch Response.fromStatus(.internal_server_error);
                },
            }
        }
```

Replace it with (note: 404/405 still return raw statuses here — Task 4 routes them through the renderer; this task only changes the `found` and `match`-catch paths and adds the helpers):

```zig
        fn makeCtx(self: *Self, req: *const request.Request, params: []const Param, arena: *std.heap.ArenaAllocator) Ctx {
            return .{
                .req = req,
                .params = params,
                .state = self.state,
                .arena = arena.allocator(),
                .trust_forwarded = self.opts.trust_forwarded,
            };
        }

        /// Classify an error and render it, using the app's on_error hook if set.
        fn renderError(self: *Self, e: anyerror, ctx: *const Ctx) Response {
            const info = err_mod.classify(e);
            if (self.on_error) |h| return h(e, info, ctx);
            return .{ .status = info.status, .body = info.reason };
        }

        fn dispatch(self: *Self, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch {
                const ctx = self.makeCtx(req, &.{}, arena);
                return self.renderError(err_mod.Error.BadRequest, &ctx);
            };

            switch (outcome) {
                .not_found => return Response.fromStatus(.not_found),
                .method_not_allowed => return Response.fromStatus(.method_not_allowed),
                .found => |f| {
                    const ctx = self.makeCtx(req, f.params, arena);
                    return Chn.run(self.mws.items, f.handler, &ctx) catch |e| self.renderError(e, &ctx);
                },
            }
        }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: PASS, all tests pass (the two new error tests included). The existing end-to-end test still passes (its 404/405 assertions check the status line only).

- [ ] **Step 7: Verify no timing flakiness**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: `run 1 ok` / `run 2 ok` / `run 3 ok`.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): map extractor + handler errors to statuses via classify + on_error hook"
```

---

## Task 4: Route 404/405 through the renderer + emit the 405 `Allow` header

**Files:**
- Modify: `src/server.zig` (`dispatch` 404/405 branches, `allowHeader` helper, tests)

- [ ] **Step 1: Write the failing tests**

Add to the test section of `src/server.zig` (after the two error tests from Task 3):

```zig
test "errors: 404/405 go through the renderer and 405 carries Allow" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    app.onError(&jsonErrorRenderer);
    try app.get("/ping", pingHandler);
    try app.post("/ping", pingHandler);

    const port: u16 = 18102;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // 404 rendered by the hook -> JSON body.
    const r404 = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r404, "404 Not Found") != null);
    try testing.expect(std.mem.endsWith(u8, r404, "{\"error\":\"not found\"}"));

    // 405 carries an Allow header listing the registered methods.
    var rb2: [2048]u8 = undefined;
    const r405 = doRequest(io, port, "DELETE /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r405, "405 Method Not Allowed") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "allow: ") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "GET") != null);
    try testing.expect(std.mem.indexOf(u8, r405, "POST") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "404 Not Found|allow|FAIL|error"`
Expected: FAIL — the 404 body is empty (not JSON) and no `allow:` header is present, because the 404/405 branches still return raw `fromStatus`.

- [ ] **Step 3: Add the `allowHeader` helper**

In `src/server.zig`, add this free function near the other free helpers at the bottom of the file (e.g. just before `const ReadError = error{ ... };`):

```zig
/// Build a comma-separated `Allow` header value from a method set, into `arena`.
fn allowHeader(arena: std.mem.Allocator, allowed: router.MethodSet) []const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var it = allowed.iterator();
    var first = true;
    while (it.next()) |m| {
        if (!first) list.appendSlice(arena, ", ") catch return list.items;
        list.appendSlice(arena, @tagName(m)) catch return list.items;
        first = false;
    }
    return list.items;
}
```

- [ ] **Step 4: Rewrite the 404/405 branches**

In `src/server.zig`, in `dispatch`, replace these two lines:

```zig
                .not_found => return Response.fromStatus(.not_found),
                .method_not_allowed => return Response.fromStatus(.method_not_allowed),
```

with:

```zig
                .not_found => {
                    const ctx = self.makeCtx(req, &.{}, arena);
                    return self.renderError(err_mod.Error.NotFound, &ctx);
                },
                .method_not_allowed => |allowed| {
                    const ctx = self.makeCtx(req, &.{}, arena);
                    var resp = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
                    resp = resp.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch resp;
                    return resp;
                },
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: PASS, all tests pass.

- [ ] **Step 6: Verify no timing flakiness**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three `ok` lines.

- [ ] **Step 7: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): render 404/405 through error hook and emit 405 Allow header"
```

---

## Task 5: Documentation

**Files:**
- Modify: `README.md` (add an "Error handling" section; update limitations)
- Modify: `docs/getting-started.md` (add an error-handling example)

- [ ] **Step 1: Add the README "Error handling" section**

In `README.md`, insert this section immediately before the `## Performance` heading:

```markdown
## Error handling

Extractor failures and handler errors map to real HTTP statuses (not a blanket
500). Handlers raise typed statuses with the canonical `zax.Error` set:

​```zig
fn getUser(s: zax.State(*const Db), p: zax.Path(struct { id: u64 })) !zax.Response {
    const user = s.value.lookup(p.value.id) orelse return error.NotFound; // -> 404
    return zax.Response.text(user.name);
}
​```

A non-numeric `:id` becomes `400`, a malformed `Json` body `422`, `error.Conflict`
`409`, and any unrecognized error `500`. Customize rendering (e.g. JSON bodies)
with one hook:

​```zig
fn renderError(e: anyerror, info: zax.ErrorInfo, ctx: *const Api.Context) zax.Response {
    _ = e;
    const body = std.fmt.allocPrint(ctx.arena, "{{\"error\":\"{s}\"}}", .{info.reason}) catch
        return zax.Response.fromStatus(info.status);
    var r = zax.Response.jsonRaw(body);
    r.status = info.status;
    return r;
}

app.onError(&renderError); // applies to extractor, handler, 404, and 405 responses
​```

Note: classification keys off the error value, so handlers should use the
canonical `zax.Error` set; an unrecognized error is treated as `500`, and
`on_error` can re-classify by inspecting the raw error.
```

(Replace the `​` zero-width characters — they are only here to escape the nested code fences in this plan. Use plain triple-backtick fences in the actual file.)

- [ ] **Step 2: Update the README limitations**

In `README.md`, in the "Not yet built" paragraph under `## Status & limitations`, remove "a full rejection-type taxonomy," (error handling now exists; field-level structured rejections remain out of scope but are not worth calling out as a headline gap).

- [ ] **Step 3: Add a getting-started error example**

In `docs/getting-started.md`, add this subsection at the end of the "## 4. Write the service" section, right before "## 5. Validate":

```markdown
### Errors

Return a canonical error to produce a status, or let an extractor failure map
itself:

​```zig
fn getUser(s: zax.State(*const Store), p: zax.Path(struct { id: u64 })) !zax.Response {
    if (p.value.id == 0) return error.NotFound; // -> 404
    return zax.Response.text("found\n");
}
​```

A bad `:id` (non-numeric) is a `400`, a malformed `Json` body a `422`. Customize
error bodies with `app.onError(&renderFn)`.
```

(Again, replace `​`-escaped fences with plain triple backticks.)

- [ ] **Step 4: Verify docs build nothing but read correctly**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: PASS (docs don't affect the build; this confirms nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document error handling and the on_error hook"
```

---

## Final verification

- [ ] Run the full suite with summary:

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|Build Summary"`
Expected: all tests pass (Task 1 +1, Task 2 +3, Task 3 +2, Task 4 +1 = +7 over the 52 baseline → ~59).

- [ ] Live smoke (optional): `zig build run`, then with the demo confirm a bad path param returns 400:

The demo (`src/main.zig`) has `GET /users/:id` with `Path(struct{ id: u64 })`; a request to `/users/abc` should now return `400`, and `/missing` a `404`.

---

## Self-review notes (already applied)

- **Spec coverage:** ErrorInfo/Error/classify (Task 2), 429 status (Task 1), on_error hook + dispatch mapping (Task 3), 404/405 through renderer + 405 Allow (Task 4), docs (Task 5), tests in every task. All spec sections covered.
- **Type consistency:** `ErrorInfo{status, reason}`, `classify(anyerror) ErrorInfo`, `ErrorHandler = *const fn(anyerror, ErrorInfo, *const Ctx) Response`, `app.onError(&fn)`, `renderError`/`makeCtx`, `allowHeader(Allocator, router.MethodSet)` — names consistent across tasks and match the existing code (`Response.jsonRaw`, `Response.withHeader`, `router.MethodSet`, `Ctx.arena` is an `Allocator`).
- **No placeholders:** every code step shows complete code; commands have expected output.
- **Edge cases:** match-catch path routed through `renderError(BadRequest)`; `on_error` is infallible (returns `Response`); 404/405 `Ctx` built via shared `makeCtx`.
