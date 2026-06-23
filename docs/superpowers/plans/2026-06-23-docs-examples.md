# Documentation & Examples Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a README logo, four complete runnable example apps (`todo-api`, `auth-sessions`, `file-upload`, `websocket-live`), a `docs/examples.md` cookbook, and a CI compile-check so the examples can't rot.

**Architecture:** Each example is a standalone consumer of `zax` (its own `build.zig` + `build.zig.zon` path-dependency on the repo root, `src/main.zig`, `README.md`), mirroring `examples/hello-service/`. Examples are separate build graphs — they don't affect the library's `zig build test`. The cookbook indexes them; the README links them; CI compiles each.

**Tech Stack:** Zig 0.16.0; the public `zax` API (extractors, middleware, responses, observability, WebSocket); GitHub README `<picture>` for the dark/light logo.

## Global Constraints

- Zig `0.16.0`. **No library source changes, no version bump** — docs/examples only. The library `zig build test` suite must stay untouched and green.
- Each example mirrors `examples/hello-service/`: `build.zig.zon` (path-dep `.zax = .{ .path = "../.." }`), `build.zig` (consumer wiring with `run` + `test` steps), `src/main.zig`, `README.md`.
- **`build.zig.zon` fingerprint:** each new package needs a unique `.fingerprint`. Create the `.zon` WITHOUT a `.fingerprint` line, run `zig build` once — Zig errors with `recommended: .fingerprint = 0x...` — paste that exact value in. (Do NOT copy hello-service's fingerprint; it must be unique.)
- **Entry point:** `pub fn main(init: std.process.Init) !void` (zax's "Juicy Main"); use `init.gpa` + `init.io`. Serve with `try app.serve(init.io, .{ .ip4 = .loopback(PORT) })` (or `app.serveEvented`).
- **Mutable shared state:** `todo-api` and `auth-sessions` use `App(*Store)` with a `std.Thread.Mutex` inside the store; store methods copy data OUT into the request arena under the lock so the handler serializes lock-free, immune to concurrent mutation.
- **Verification per example:** `cd examples/<name> && zig build` (compile gate) and `zig build test` (handler unit tests). These are separate build graphs — they do NOT run the library suite and have no shared-port concerns.
- Each example's `.zig-cache/` and `zig-out/` are git-ignored (root `.gitignore`).
- **Assets:** `assets/zax-icon-velocity-dark.svg`, `assets/zax-icon-velocity-light.svg`, `assets/zax-wordmark.svg` exist.
- WebSocket example is per-connection (no broadcast — not shipped).

## Verified API surface (use these exactly)

- App: `zax.App(StateType)`; `Api.init(gpa, &state, .{})`; `app.deinit()`; `app.use(&mw)`; `app.get/post/put/delete(pattern, handler)`; `app.getWith/postWith/putWith(pattern, mws_tuple, handler)`; `app.observe(observer)`; `app.serve(io, addr)`; `app.serveEvented(io, addr, .{ .workers = N })`.
- Middleware fn: `fn (ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response`. `next.run()` continues the chain. `ctx.arena`, `ctx.req`.
- Extractors: `zax.State(T)` (`.value`), `zax.Path(struct{...})` (`.value`), `zax.Query(struct{...})`, `zax.Json(struct{...})` (body — last param), `zax.Alloc` (`.value` = arena), `zax.Cookies` (`.get(name) ?[]const u8`), `zax.Multipart` (`.field(name) ?[]const u8`, `.file(name) ?Part`, `.parts`), `zax.Files` (`.dir(root, requested) !Response`, `.file(path) !Response`). Each extractor value is `.{ .value = ... }` for unit tests; `Cookies`/`Files` are `.{ .list = ... }`-style — for tests, construct via their real fields (Cookies wraps the header list; prefer testing pure helpers instead).
- Response: `zax.Response.text(body)`, `.jsonRaw(body)`, `.json(arena, value)` (serializes any Zig value to JSON), `.fromStatus(status)`, `.withHeader(arena, k, v)`, `.withCookie(arena, zax.SetCookie{...})`, `.expireCookie(arena, name, ?path)`. `Response` has a public `.body` and `.status` field for tests.
- `zax.SetCookie{ .name, .value, .max_age: ?i64, .domain: ?[]const u8, .path: ?[]const u8, .secure: bool, .http_only: bool, .same_site: ?zax.SameSite }`.
- `zax.Status` enum (`.ok`, `.created`, `.no_content`, `.not_found`, `.bad_request`, `.unauthorized`, …); `Response.fromStatus(.created)`.
- Observability: `zax.Metrics` (`.observer() zax.Observer`, `.snapshot() MetricsSnapshot`, `.writePrometheus(w)`); `zax.AccessLogger` (`.observer()`); register with `app.observe(m.observer())`. `MetricsSnapshot{ total, class:[6]u64, bytes_total, duration_sum_ns, buckets }`.
- WebSocket: `fn h(ws: zax.WebSocket) zax.Response { return ws.onUpgrade(.{ .on_message = onMsg }); }`; `fn onMsg(conn: *zax.WsConn, frame: zax.WsFrame) void`; `conn.send(opcode, payload) catch {}`; `conn.state(T)`.

---

## File Structure

```
README.md                       (modify: logo header + ## Examples)
.gitignore                      (modify: examples caches)
CHANGELOG.md                    (modify: Added note)
docs/examples.md                (create: cookbook)
.github/workflows/ci.yml        (modify: per-example compile-check)
examples/todo-api/              (create: build.zig.zon, build.zig, src/main.zig, README.md)
examples/auth-sessions/         (create: same shape)
examples/file-upload/           (create: same shape)
examples/websocket-live/        (create: same shape)
```

Tasks: T1 README logo + Examples + gitignore → T2 todo-api → T3 auth-sessions → T4 file-upload → T5 websocket-live → T6 cookbook → T7 CI + CHANGELOG.

---

### Task 1: README logo header + Examples section + .gitignore

Add the logo + examples index; ignore example caches. Deliverable: README renders the logo (icon dark/light + wordmark) and links the examples (which arrive in later tasks); caches are ignored.

**Files:**
- Modify: `README.md` (top header; add `## Examples`)
- Modify: `.gitignore`

- [ ] **Step 1: Replace the README H1 with the logo header**

In `README.md`, replace the first line `# Zax` with:

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/zax-icon-velocity-dark.svg">
    <img src="assets/zax-icon-velocity-light.svg" height="96" alt="zax">
  </picture>
</p>
<p align="center">
  <img src="assets/zax-wordmark.svg" height="40" alt="zax">
</p>
```

Leave the existing CI badge line, the tagline paragraph, and the "New here?" paragraph immediately below, unchanged.

- [ ] **Step 2: Add an `## Examples` section**

Immediately after the "New here?" paragraph (before `## Why 0.16.0`), insert:

```markdown
## Examples

Runnable, self-contained apps under [`examples/`](examples) — each is its own package
that depends on this repo, so `cd examples/<name> && zig build run` just works. See the
[examples cookbook](docs/examples.md) for walkthroughs.

| Example | Demonstrates |
| --- | --- |
| [`hello-service`](examples/hello-service) | Minimal app: `State`, `Path`, `Query`, `Json`, middleware |
| [`todo-api`](examples/todo-api) | REST/CRUD JSON API, mutable `State` + `Mutex`, metrics + access log |
| [`auth-sessions`](examples/auth-sessions) | Cookie sessions + a guard middleware (401 on missing/invalid) |
| [`file-upload`](examples/file-upload) | `multipart/form-data` uploads + static file serving |
| [`websocket-live`](examples/websocket-live) | WebSocket echo on both `serve` and `serveEvented` |
```

- [ ] **Step 3: Ignore example build artifacts** (`.gitignore`)

Append (if not already covered):

```gitignore
# Example app build artifacts
examples/*/.zig-cache/
examples/*/zig-out/
```

- [ ] **Step 4: Verify the library suite is untouched + commit**

Run: `git diff --stat` (expect only `README.md` + `.gitignore`). No build needed (no code changed).

```bash
git add README.md .gitignore
git commit -m "docs: README logo header + examples index + ignore example caches"
```

---

### Task 2: `examples/todo-api/`

A REST/CRUD JSON API with mutable shared state + observability. Deliverable: `cd examples/todo-api && zig build` compiles and `zig build test` passes.

**Files:**
- Create: `examples/todo-api/build.zig.zon`, `examples/todo-api/build.zig`, `examples/todo-api/src/main.zig`, `examples/todo-api/README.md`

- [ ] **Step 1: `build.zig.zon`** (omit fingerprint first; see Step 2)

```zig
.{
    .name = .todo_api,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zax = .{ .path = "../.." },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

- [ ] **Step 2: `build.zig`** (mirror hello-service)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zax = b.dependency("zax", .{ .target = target, .optimize = optimize }).module("zax");
    const exe = b.addExecutable(.{
        .name = "todo-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zax", .module = zax }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the todo-api").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run todo-api tests").dependOn(&b.addRunArtifact(tests).step);
}
```

- [ ] **Step 3: `src/main.zig`**

```zig
//! todo-api — a REST/CRUD JSON API on zax. Demonstrates mutable shared state
//! (App(*Store) + a Mutex), the Json/Path/State extractors, JSON responses with
//! real status codes, and observability (metrics + access log).
//!
//!   zig build run    # serve on http://127.0.0.1:8082
//!   zig build test   # unit-test the store + handlers

const std = @import("std");
const zax = @import("zax");

const Todo = struct { id: u32, title: []const u8, done: bool };
const NewTodo = struct { title: []const u8 };
const Patch = struct { title: ?[]const u8 = null, done: ?bool = null };

/// In-memory store. Mutated by handlers on multiple threads → guarded by a Mutex.
/// Methods copy results OUT into the caller's request arena under the lock, so the
/// handler serializes JSON lock-free and immune to concurrent mutation.
const Store = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Todo) = .empty,
    next_id: u32 = 1,

    fn deinit(self: *Store) void {
        for (self.items.items) |t| self.gpa.free(t.title);
        self.items.deinit(self.gpa);
    }

    fn list(self: *Store, arena: std.mem.Allocator) ![]Todo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try arena.alloc(Todo, self.items.items.len);
        for (self.items.items, out) |src, *dst| dst.* = .{ .id = src.id, .title = try arena.dupe(u8, src.title), .done = src.done };
        return out;
    }

    fn add(self: *Store, arena: std.mem.Allocator, title: []const u8) !Todo {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = try self.gpa.dupe(u8, title); // store-owned copy (request body is request-scoped)
        const t = Todo{ .id = self.next_id, .title = owned, .done = false };
        try self.items.append(self.gpa, t);
        self.next_id += 1;
        return .{ .id = t.id, .title = try arena.dupe(u8, owned), .done = false };
    }

    fn get(self: *Store, arena: std.mem.Allocator, id: u32) !?Todo {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |t| if (t.id == id)
            return Todo{ .id = t.id, .title = try arena.dupe(u8, t.title), .done = t.done };
        return null;
    }

    fn update(self: *Store, arena: std.mem.Allocator, id: u32, patch: Patch) !?Todo {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*t| if (t.id == id) {
            if (patch.title) |nt| {
                const owned = try self.gpa.dupe(u8, nt);
                self.gpa.free(t.title);
                t.title = owned;
            }
            if (patch.done) |d| t.done = d;
            return Todo{ .id = t.id, .title = try arena.dupe(u8, t.title), .done = t.done };
        };
        return null;
    }

    fn remove(self: *Store, id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items, 0..) |t, i| if (t.id == id) {
            self.gpa.free(t.title);
            _ = self.items.orderedRemove(i);
            return true;
        };
        return false;
    }
};

const Api = zax.App(*Store);

// --- Handlers ---
fn listTodos(s: zax.State(*Store), a: zax.Alloc) !zax.Response {
    const todos = try s.value.list(a.value);
    return zax.Response.json(a.value, todos);
}

fn createTodo(s: zax.State(*Store), a: zax.Alloc, body: zax.Json(NewTodo)) !zax.Response {
    if (body.value.title.len == 0) return zax.Response.fromStatus(.bad_request);
    const t = try s.value.add(a.value, body.value.title);
    var r = try zax.Response.json(a.value, t);
    r.status = .created; // 201
    return r;
}

fn getTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 }), a: zax.Alloc) !zax.Response {
    const t = (try s.value.get(a.value, p.value.id)) orelse return zax.Response.fromStatus(.not_found);
    return zax.Response.json(a.value, t);
}

fn updateTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 }), a: zax.Alloc, body: zax.Json(Patch)) !zax.Response {
    const t = (try s.value.update(a.value, p.value.id, body.value)) orelse return zax.Response.fromStatus(.not_found);
    return zax.Response.json(a.value, t);
}

fn deleteTodo(s: zax.State(*Store), p: zax.Path(struct { id: u32 })) zax.Response {
    return if (s.value.remove(p.value.id)) zax.Response.fromStatus(.no_content) else zax.Response.fromStatus(.not_found);
}

fn metrics(s: zax.State(*Store), a: zax.Alloc) !zax.Response {
    _ = s;
    var buf = std.Io.Writer.Allocating.init(a.value);
    try global_metrics.writePrometheus(&buf.writer);
    return zax.Response.text(buf.written());
}

var global_metrics: zax.Metrics = .{};

pub fn main(init: std.process.Init) !void {
    var store = Store{ .gpa = init.gpa };
    defer store.deinit();
    var app = try Api.init(init.gpa, &store, .{});
    defer app.deinit();

    var access = zax.AccessLogger{};
    try app.observe(access.observer());
    try app.observe(global_metrics.observer());

    try app.get("/todos", listTodos);
    try app.post("/todos", createTodo);
    try app.get("/todos/:id", getTodo);
    try app.put("/todos/:id", updateTodo);
    try app.delete("/todos/:id", deleteTodo);
    try app.get("/metrics", metrics);

    std.debug.print("todo-api listening on http://127.0.0.1:8082\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8082) });
}

// --- Tests (store logic; no sockets) ---
const testing = std.testing;

test "store add/get/update/remove" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var s = Store{ .gpa = testing.allocator };
    defer s.deinit();

    const a = try s.add(ar, "buy milk");
    try testing.expectEqual(@as(u32, 1), a.id);
    try testing.expectEqualStrings("buy milk", a.title);

    const g = (try s.get(ar, 1)).?;
    try testing.expectEqualStrings("buy milk", g.title);
    try testing.expect(!g.done);

    const u = (try s.update(ar, 1, .{ .done = true })).?;
    try testing.expect(u.done);

    try testing.expect(s.remove(1));
    try testing.expect((try s.get(ar, 1)) == null);
}
```

NOTE on `Response.json` + `MetricsSnapshot`/`writePrometheus`: if `Response.json` does not accept a slice directly, wrap as needed per its signature (it serializes any Zig value via `std.json`); if `Metrics.writePrometheus` expects a different writer type than `std.Io.Writer.Allocating`, match its actual `*std.Io.Writer` parameter (read `src/observe.zig`). Keep the behavior: `/metrics` returns the Prometheus text exposition.

- [ ] **Step 4: `README.md`**

````markdown
# todo-api

A REST/CRUD JSON API on [zax](../..). Demonstrates mutable shared state
(`App(*Store)` guarded by a `std.Thread.Mutex`), the `Json` / `Path` / `State`
extractors, JSON responses with real status codes (201/204/404), and
observability (an access log + Prometheus `/metrics`).

## Run

```sh
zig build run        # http://127.0.0.1:8082
zig build test       # store + handler unit tests
```

## Try it

```sh
curl -s localhost:8082/todos
curl -s -XPOST localhost:8082/todos -d '{"title":"buy milk"}'   # 201
curl -s localhost:8082/todos/1
curl -s -XPUT localhost:8082/todos/1 -d '{"done":true}'
curl -s -XDELETE localhost:8082/todos/1 -i | head -1            # 204
curl -s localhost:8082/metrics
```

## How it works

The `Store` holds the data behind a mutex; each method copies its result into the
request arena under the lock, so handlers serialize JSON without holding the lock and
are immune to concurrent mutation. State reaches handlers via `zax.State(*Store)`.
````

- [ ] **Step 5: Generate the fingerprint, compile, test**

```sh
cd examples/todo-api
zig build            # first run errors: "missing fingerprint ... recommended: .fingerprint = 0x..."
# paste the recommended .fingerprint into build.zig.zon, then:
zig build            # compiles
zig build test       # store/handler tests pass
```
Expected: compiles clean; tests pass.

- [ ] **Step 6: Commit**

```bash
git add examples/todo-api
git commit -m "examples: todo-api — REST/CRUD JSON API with mutable State + metrics"
```

---

### Task 3: `examples/auth-sessions/`

Cookie sessions + a guard middleware. Deliverable: `cd examples/auth-sessions && zig build` compiles and `zig build test` passes.

**Files:**
- Create: `examples/auth-sessions/build.zig.zon`, `build.zig`, `src/main.zig`, `README.md`

- [ ] **Step 1: `build.zig.zon`** — same as Task 2 Step 1 but `.name = .auth_sessions` (omit fingerprint; generate in Step 5).

- [ ] **Step 2: `build.zig`** — identical to Task 2 Step 2 but exe name `"auth-sessions"` and step descriptions "Run/Run the auth-sessions".

- [ ] **Step 3: `src/main.zig`**

```zig
//! auth-sessions — cookie sessions + a guard middleware on zax. POST /login sets a
//! session cookie; a middleware reads the Cookies extractor and rejects requests to
//! protected routes with 401 when the session is missing/invalid.
//!
//!   zig build run    # serve on http://127.0.0.1:8083
//!   zig build test   # unit-test the session store

const std = @import("std");
const zax = @import("zax");

const Sessions = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    map: std.StringHashMapUnmanaged([]const u8) = .empty, // token -> user

    fn deinit(self: *Sessions) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.map.deinit(self.gpa);
    }

    fn create(self: *Sessions, user: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Demo token: not cryptographically strong — a real app would use a CSPRNG.
        var buf: [16]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = "0123456789abcdef"[(self.map.count() + i) % 16];
        const token = try self.gpa.dupe(u8, &buf);
        try self.map.put(self.gpa, token, try self.gpa.dupe(u8, user));
        return token;
    }

    /// Returns the user for a token (arena-duped), or null. Lock-safe copy-out.
    fn userFor(self: *Sessions, arena: std.mem.Allocator, token: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.get(token)) |u| return try arena.dupe(u8, u);
        return null;
    }

    fn destroy(self: *Sessions, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(token)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
    }
};

const Api = zax.App(*Sessions);
const Creds = struct { user: []const u8, pass: []const u8 };

/// Guard middleware: requires a valid `session` cookie, else 401.
fn requireAuth(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const cookies = try zax.Cookies.fromContext(ctx);
    const token = cookies.get("session") orelse return zax.Response.fromStatus(.unauthorized);
    const user = (try ctx.state.userFor(ctx.arena, token)) orelse return zax.Response.fromStatus(.unauthorized);
    _ = user; // a real app would stash this for downstream handlers
    return next.run();
}

fn index() zax.Response {
    return zax.Response.text("public homepage — POST /login to get a session\n");
}

fn login(s: zax.State(*Sessions), a: zax.Alloc, body: zax.Json(Creds)) !zax.Response {
    // Demo auth: accept any non-empty user with pass == "secret".
    if (body.value.user.len == 0 or !std.mem.eql(u8, body.value.pass, "secret"))
        return zax.Response.fromStatus(.unauthorized);
    const token = try s.value.create(body.value.user);
    const r = zax.Response.text("logged in\n");
    return r.withCookie(a.value, .{ .name = "session", .value = token, .path = "/", .http_only = true, .same_site = .lax });
}

fn me(cookies: zax.Cookies, s: zax.State(*Sessions), a: zax.Alloc) !zax.Response {
    const token = cookies.get("session").?; // guard guarantees presence
    const user = (try s.value.userFor(a.value, token)).?;
    const body = try std.fmt.allocPrint(a.value, "you are: {s}\n", .{user});
    return zax.Response.text(body);
}

fn logout(cookies: zax.Cookies, s: zax.State(*Sessions), a: zax.Alloc) !zax.Response {
    if (cookies.get("session")) |token| s.value.destroy(token);
    const r = zax.Response.text("logged out\n");
    return r.expireCookie(a.value, "session", "/");
}

pub fn main(init: std.process.Init) !void {
    var sessions = Sessions{ .gpa = init.gpa };
    defer sessions.deinit();
    var app = try Api.init(init.gpa, &sessions, .{});
    defer app.deinit();

    try app.get("/", index);
    try app.post("/login", login);
    try app.post("/logout", logout);
    // Protected: requireAuth runs before the handler.
    try app.getWith("/me", .{&requireAuth}, me);

    std.debug.print("auth-sessions listening on http://127.0.0.1:8083\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8083) });
}

const testing = std.testing;

test "sessions create / userFor / destroy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = Sessions{ .gpa = testing.allocator };
    defer s.deinit();
    const token = try s.create("ada");
    try testing.expectEqualStrings("ada", (try s.userFor(arena.allocator(), token)).?);
    s.destroy(token);
    try testing.expect((try s.userFor(arena.allocator(), token)) == null);
}
```

NOTE: verify the `getWith` middleware-tuple form against `src/server.zig` (`getWith(pattern, mws, handler)`) — the tuple is `.{&requireAuth}`. If the per-route mw API differs, match it (the behavior: `requireAuth` runs before `me`). If `Cookies.fromContext(ctx)` needs a specific ctx shape in the middleware, pass `ctx` as-is (middleware receives `*const Api.Context`, which is a valid extractor context).

- [ ] **Step 4: `README.md`** — describe login/me/logout with a `curl` cookie-jar walkthrough:

````markdown
# auth-sessions

Cookie sessions + a guard middleware on [zax](../..). `POST /login` sets a `session`
cookie; a middleware reads the `Cookies` extractor and returns `401` for protected
routes without a valid session.

## Run
```sh
zig build run     # http://127.0.0.1:8083
zig build test
```

## Try it
```sh
curl -s localhost:8083/                              # public
curl -s localhost:8083/me -i | head -1               # 401 (no cookie)
curl -s -c jar -XPOST localhost:8083/login -d '{"user":"ada","pass":"secret"}'
curl -s -b jar localhost:8083/me                     # "you are: ada"
curl -s -b jar -XPOST localhost:8083/logout
```

## How it works
`requireAuth` is a `Chain` middleware applied to `/me` via `getWith`. It reads the
`session` cookie, looks it up in the mutex-guarded `Sessions` store, and short-circuits
`401` on miss. Login issues a token and sets it with `Response.withCookie` (HttpOnly,
SameSite=Lax). (Demo auth only — `pass == "secret"`, non-CSPRNG tokens.)
````

- [ ] **Step 5: Generate fingerprint, compile, test** (same procedure as Task 2 Step 5, in `examples/auth-sessions`).

- [ ] **Step 6: Commit**

```bash
git add examples/auth-sessions
git commit -m "examples: auth-sessions — cookie sessions + guard middleware"
```

---

### Task 4: `examples/file-upload/`

Multipart upload + static serving. Deliverable: `cd examples/file-upload && zig build` compiles and `zig build test` passes.

**Files:**
- Create: `examples/file-upload/build.zig.zon`, `build.zig`, `src/main.zig`, `README.md`

- [ ] **Step 1–2: build files** — same shape as Task 2; `.name = .file_upload`, exe `"file-upload"` (omit fingerprint; generate in Step 5).

- [ ] **Step 3: `src/main.zig`**

```zig
//! file-upload — multipart/form-data uploads + static serving on zax. POST /upload
//! saves the uploaded file under ./uploads; GET /files/<name> serves it back.
//!
//!   zig build run    # serve on http://127.0.0.1:8084
//!   zig build test

const std = @import("std");
const zax = @import("zax");

const upload_dir = "uploads";

const Api = zax.App(*const struct {}); // no shared state needed

fn home() zax.Response {
    return zax.Response.text("POST a file to /upload (field name: file); GET /files/<name>\n");
}

// Multipart is a body extractor → must be the LAST parameter.
fn upload(a: zax.Alloc, mp: zax.Multipart) !zax.Response {
    const f = mp.file("file") orelse return zax.Response.fromStatus(.bad_request);
    const name = sanitize(f.filename orelse "upload.bin");
    const path = try std.fmt.allocPrint(a.value, upload_dir ++ "/{s}", .{name});
    var dir = try std.fs.cwd().makeOpenPath(upload_dir, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = name, .data = f.data });
    const body = try std.fmt.allocPrint(a.value, "saved {s} ({d} bytes)\n", .{ path, f.data.len });
    var r = zax.Response.text(body);
    r.status = .created;
    return r;
}

fn serveFile(p: zax.Path(struct { name: []const u8 }), files: zax.Files) !zax.Response {
    return files.dir(upload_dir, p.value.name);
}

/// Strip path separators so an uploaded filename can't escape the upload dir.
fn sanitize(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

pub fn main(init: std.process.Init) !void {
    var state = .{};
    var app = try Api.init(init.gpa, &state, .{});
    defer app.deinit();
    try app.get("/", home);
    try app.post("/upload", upload);
    try app.get("/files/:name", serveFile);
    std.debug.print("file-upload listening on http://127.0.0.1:8084\n", .{});
    try app.serve(init.io, .{ .ip4 = .loopback(8084) });
}

const testing = std.testing;

test "sanitize strips directory components" {
    try testing.expectEqualStrings("evil.sh", sanitize("../../etc/evil.sh"));
    try testing.expectEqualStrings("ok.txt", sanitize("ok.txt"));
}
```

NOTE: confirm `zax.Files.dir(root, requested)` signature + that a no-shared-state app uses `App(*const struct{})` (or whatever the codebase's "no state" convention is — `hello-service` used a real `Store`; if an empty state type is awkward, use a tiny `const State = struct {}` value). Confirm `std.fs.Dir.writeFile(.{ .sub_path, .data })` is the correct 0.16 API; if not, use `dir.createFile` + `writeAll`. The behavior is: save the part bytes to `uploads/<name>` and serve them via `Files`.

- [ ] **Step 4: `README.md`**

````markdown
# file-upload

`multipart/form-data` uploads + static serving on [zax](../..). `POST /upload` saves
the file part under `./uploads/`; `GET /files/<name>` serves it via the `Files` helper.

## Run
```sh
zig build run     # http://127.0.0.1:8084
zig build test
```

## Try it
```sh
echo "hello" > /tmp/hi.txt
curl -s -F file=@/tmp/hi.txt localhost:8084/upload    # "saved uploads/hi.txt (6 bytes)"
curl -s localhost:8084/files/hi.txt                   # "hello"
```

## How it works
`zax.Multipart` (a body extractor, last param) exposes `.file("file")`; the bytes are
written under `./uploads/` (filename sanitized to block path traversal). `zax.Files.dir`
serves saved files, bounded by the request body limits.
````

- [ ] **Step 5: Generate fingerprint, compile, test** (in `examples/file-upload`).

- [ ] **Step 6: Commit**

```bash
git add examples/file-upload
git commit -m "examples: file-upload — multipart uploads + static serving"
```

---

### Task 5: `examples/websocket-live/`

WebSocket echo on both backends. Deliverable: `cd examples/websocket-live && zig build` compiles and `zig build test` passes.

**Files:**
- Create: `examples/websocket-live/build.zig.zon`, `build.zig`, `src/main.zig`, `README.md`

- [ ] **Step 1–2: build files** — same shape; `.name = .websocket_live`, exe `"websocket-live"` (omit fingerprint; generate in Step 5).

- [ ] **Step 3: `src/main.zig`**

```zig
//! websocket-live — a WebSocket echo endpoint on zax, running on BOTH the threaded
//! (app.serve) and evented (app.serveEvented) backends with the same handler.
//! on_message receives whole reassembled messages; ping/pong + close are automatic.
//!
//!   zig build run            # threaded backend, ws://127.0.0.1:8085/ws
//!   zig build run -- evented # evented (reactor) backend

const std = @import("std");
const zax = @import("zax");

const Counter = struct { mutex: std.Thread.Mutex = .{}, n: usize = 0 };
const Api = zax.App(*Counter);

fn onMessage(conn: *zax.WsConn, frame: zax.WsFrame) void {
    const counter = conn.state(*Counter);
    counter.mutex.lock();
    counter.n += 1;
    counter.mutex.unlock();
    conn.send(frame.opcode, frame.payload) catch {}; // echo the whole message back
}

fn ws(sock: zax.WebSocket) zax.Response {
    return sock.onUpgrade(.{ .on_message = onMessage });
}

fn home() zax.Response {
    return zax.Response.text("connect a WebSocket to /ws (it echoes messages)\n");
}

pub fn main(init: std.process.Init) !void {
    var counter = Counter{};
    var app = try Api.init(init.gpa, &counter, .{});
    defer app.deinit();
    try app.get("/", home);
    try app.get("/ws", ws);

    const evented = if (init.args.len > 1) std.mem.eql(u8, init.args[1], "evented") else false;
    const addr = .{ .ip4 = .loopback(8085) };
    if (evented) {
        std.debug.print("websocket-live (evented) on ws://127.0.0.1:8085/ws\n", .{});
        try app.serveEvented(init.io, addr, .{});
    } else {
        std.debug.print("websocket-live (threaded) on ws://127.0.0.1:8085/ws\n", .{});
        try app.serve(init.io, addr);
    }
}

const testing = std.testing;

test "home handler" {
    try testing.expect(std.mem.indexOf(u8, home().body, "WebSocket") != null);
}
```

NOTE: confirm the args access (`init.args` shape in zax's Juicy Main — `init.args` may be `[][:0]u8` or similar; match the real type, falling back to threaded if arg parsing differs) and `app.serveEvented(io, addr, .{})`'s exact options struct (read `src/server.zig`). The behavior: default threaded, `-- evented` selects the reactor backend; both serve the same `/ws` echo.

- [ ] **Step 4: `README.md`**

````markdown
# websocket-live

A WebSocket echo endpoint on [zax](../..) that runs on **both** server backends with
the same handler. `on_message` receives whole reassembled messages; the framework
auto-replies to pings and does the close handshake.

## Run
```sh
zig build run              # threaded backend
zig build run -- evented   # evented (reactor) backend
# ws://127.0.0.1:8085/ws
```

## Try it
```sh
# with websocat (or wscat):
websocat ws://127.0.0.1:8085/ws
> hello        # server echoes: hello
```

Or in a browser console:
```js
const ws = new WebSocket("ws://127.0.0.1:8085/ws");
ws.onmessage = (e) => console.log("echo:", e.data);
ws.onopen = () => ws.send("hello from the browser");
```

## How it works
The `WebSocket` extractor's `onUpgrade(.{ .on_message = onMessage })` performs the RFC
6455 handshake and hands each whole message to `onMessage`, which bumps a mutex-guarded
counter (reached via `conn.state(*Counter)`) and echoes the message back. The same
handler runs under `app.serve` and `app.serveEvented`.
````

- [ ] **Step 5: Generate fingerprint, compile, test** (in `examples/websocket-live`).

- [ ] **Step 6: Commit**

```bash
git add examples/websocket-live
git commit -m "examples: websocket-live — WS echo on threaded + evented backends"
```

---

### Task 6: `docs/examples.md` cookbook

Index + walkthroughs of all five examples. Deliverable: a cookbook that links each example and explains what it teaches.

**Files:**
- Create: `docs/examples.md`

- [ ] **Step 1: Write the cookbook**

```markdown
# Examples cookbook

Each example under [`examples/`](../examples) is a standalone package that depends on
this repo by relative path, so it always tracks the local source:

```zig
// build.zig.zon
.dependencies = .{ .zax = .{ .path = "../.." } },
```

Run any example with `cd examples/<name> && zig build run`, and unit-test its handlers
with `zig build test`. Copy a directory out of the repo and swap the path dependency for
a `zig fetch --save git+https://…/zax` URL to use it as a starting point.

## [hello-service](../examples/hello-service)
The minimal app. `State`, `Path`, `Query`, `Json`, and `Alloc` extractors, a
response-stamping middleware, and handler unit tests that call handlers directly with
constructed extractor values. Start here.

## [todo-api](../examples/todo-api)
A REST/CRUD JSON API. Shows **mutable shared state** done safely: `App(*Store)` with a
`std.Thread.Mutex`; store methods copy results into the request arena under the lock so
handlers serialize JSON lock-free. Returns real status codes (201/204/404) and exposes
Prometheus `/metrics` plus an access log via `app.observe`.
Key file: [`src/main.zig`](../examples/todo-api/src/main.zig).

## [auth-sessions](../examples/auth-sessions)
Cookie sessions + a **guard middleware**. `POST /login` issues a token and sets it with
`Response.withCookie` (HttpOnly, SameSite=Lax); a `Chain` middleware reads the `Cookies`
extractor and short-circuits `401` for protected routes (`getWith`). Demonstrates
middleware composition, cookies, and error responses.
Key file: [`src/main.zig`](../examples/auth-sessions/src/main.zig).

## [file-upload](../examples/file-upload)
`multipart/form-data` uploads + static serving. The `Multipart` body extractor saves an
uploaded file (filename sanitized against path traversal); `Files.dir` serves it back.
Key file: [`src/main.zig`](../examples/file-upload/src/main.zig).

## [websocket-live](../examples/websocket-live)
A WebSocket echo endpoint that runs on **both** `app.serve` and `app.serveEvented` with
one handler. `onUpgrade(.{ .on_message = … })` delivers whole reassembled messages;
ping/pong and the close handshake are automatic; the handler reaches app state via
`conn.state(T)`.
Key file: [`src/main.zig`](../examples/websocket-live/src/main.zig).

## See also
- [Getting started](getting-started.md) — set up a project from scratch.
- [README](../README.md) — the full feature reference.
- [Evented backend](evented-backend.md) — when to use `serveEvented`.
```

- [ ] **Step 2: Verify links + commit**

Run: `ls examples/hello-service examples/todo-api examples/auth-sessions examples/file-upload examples/websocket-live docs/getting-started.md docs/evented-backend.md` (all exist).

```bash
git add docs/examples.md
git commit -m "docs: examples cookbook indexing all five example apps"
```

---

### Task 7: CI compile-check + CHANGELOG

Compile every example in CI; note the addition. Deliverable: CI builds each example; CHANGELOG records the docs/examples work.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an examples compile-check job** (`.github/workflows/ci.yml`)

Read the existing workflow first (the `bench-build` step shows the runner/Zig setup pattern). Add a step (in the existing build job, after the bench-build step, reusing the same checkout + Zig install) that compiles each example:

```yaml
      - name: Build examples
        run: |
          for d in examples/*/; do
            echo "== building $d =="
            (cd "$d" && zig build)
          done
```

Match the existing job's indentation, runner, and Zig-setup steps exactly (the examples need the same Zig 0.16.0 the rest of CI uses). If CI runs a matrix (Linux + macOS), the examples build on each — that's fine (they're platform-independent consumers).

- [ ] **Step 2: CHANGELOG note** (`CHANGELOG.md`, under `## [Unreleased]` → `### Added`)

```markdown
- **Example apps + cookbook + README logo** — four runnable example apps (`todo-api` REST/CRUD with mutable state + metrics, `auth-sessions` cookie sessions + guard middleware, `file-upload` multipart + static serving, `websocket-live` WS echo on both backends), a `docs/examples.md` cookbook, a README logo header, and a CI compile-check that builds every example. No library code change.
```

- [ ] **Step 3: Verify the library suite + commit**

Run: `zig build test --summary all` (single instance) — the library suite is unchanged; confirm it still passes.
Run: `for d in examples/*/; do (cd "$d" && zig build) || echo "FAILED: $d"; done` — every example compiles.

```bash
git add .github/workflows/ci.yml CHANGELOG.md
git commit -m "ci+docs: compile-check examples in CI; CHANGELOG note"
```

---

## Self-Review

**Spec coverage:**
- README logo (icon dark/light `<picture>` + wordmark) + Examples section → Task 1. ✓
- `.gitignore` example caches → Task 1. ✓
- `todo-api` (CRUD + `State(*Store)`+Mutex + Json + status codes + observability/metrics) → Task 2. ✓
- `auth-sessions` (cookies + guard middleware + 401) → Task 3. ✓
- `file-upload` (Multipart + Files) → Task 4. ✓
- `websocket-live` (WS both backends, per-connection) → Task 5. ✓
- `docs/examples.md` cookbook (all five) → Task 6. ✓
- CI compile-check per example → Task 7. ✓
- CHANGELOG note; no version bump → Task 7 + Global Constraints. ✓
- Each example mirrors hello-service build shape; fingerprint generated → every example task. ✓

**Placeholder scan:** No TBD/vague steps. Each example has complete build files, `src/main.zig`, and README. The `NOTE` blocks flag specific API signatures the implementer must confirm against the real source (`Response.json` slice handling, `Metrics.writePrometheus` writer type, `getWith` tuple form, `Files.dir` signature, `std.fs` write API, Juicy Main `init.args` shape, `serveEvented` options) — each names the exact thing to verify and the behavior to preserve, not an open "figure it out." These are real (the plan author can't run the example compiler here); the implementer compiles each example, which surfaces any signature mismatch immediately.

**Type consistency:** Each example is self-contained (its own `Store`/`Sessions`/`Counter` + handlers); no cross-task type sharing. API names (`zax.App`, `State`, `Path`, `Json`, `Cookies`, `Multipart`, `Files`, `Response.json/text/fromStatus/withCookie/expireCookie`, `Metrics`, `AccessLogger`, `WebSocket`, `WsConn`, `WsFrame`, `serve`/`serveEvented`, `getWith`) are used consistently and match the verified API surface section. Ports are distinct (8082–8085; hello uses 8081).

**Note on the example tasks' "tests":** these are demo apps; the gate is `zig build` (compile) per example in CI, plus light handler/store unit tests via `zig build test` (mirroring hello-service). The library `zig build test` suite is not affected (separate build graphs) — example tasks must NOT modify library source.
