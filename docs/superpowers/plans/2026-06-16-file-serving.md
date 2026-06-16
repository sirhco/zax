# Static File Serving (C-c3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Files` extractor lets a handler serve a file from disk — `files.file(path)` (explicit) and `files.dir(root, requested)` (traversal-safe) — with content-type by extension and Content-Length.

**Architecture:** `Files` (an extractor carrying `io` + `arena`) reads the whole file into the request arena via `Io.Dir.readFileAlloc` and returns a buffered `Response`. Read/traversal failures map to canonical errors the existing classifier turns into 404/403/413. Enabling change: add `io` to `Context` and thread it through `dispatch`/`makeCtx`.

**Tech Stack:** Zig 0.16.0, `std.Io`. Spec: `docs/superpowers/specs/2026-06-16-file-serving-design.md`. Branch: `feat/file-serving`.

**Conventions:** Tests via `zig build test --summary all`. TDD per task. Do NOT touch main. Tests serve the repo's own `build.zig` (present at cwd during `zig build test`) to avoid temp-file machinery.

---

## File Structure

- **Create** `src/extract/files.zig` — `contentType`, `safeJoin`, and the `Files` extractor.
- **Modify** `src/extract/extract.zig` — add `io` to `Context`.
- **Modify** `src/server.zig` — thread `io` through `dispatch`/`makeCtx`; fix the alloc-test `dispatch` calls; integration test.
- **Modify** `src/error.zig` — `classify(error.PayloadTooLarge)` → 413.
- **Modify** `src/root.zig` — export `Files`.
- **Modify** `README.md`, `docs/getting-started.md`.

---

## Task 1: `contentType` + `safeJoin` helpers

**Files:** Create `src/extract/files.zig`

- [ ] **Step 1: Write `src/extract/files.zig` with the two pure helpers + tests**

```zig
//! Static file serving. `Files` is an extractor (carrying io + arena) that reads
//! a file into the request arena and returns a buffered Response. `contentType`
//! and `safeJoin` are pure helpers.

const std = @import("std");
const Response = @import("../http/response.zig").Response;

pub const default_max_file_size: usize = 16 * 1024 * 1024;

/// Content type by file extension; defaults to application/octet-stream.
pub fn contentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const map = .{
        .{ "html", "text/html; charset=utf-8" }, .{ "css", "text/css" },
        .{ "js", "text/javascript" },            .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },             .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },                .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },                 .{ "txt", "text/plain; charset=utf-8" },
        .{ "ico", "image/x-icon" },              .{ "wasm", "application/wasm" },
    };
    inline for (map) |kv| if (std.mem.eql(u8, ext, kv[0])) return kv[1];
    return "application/octet-stream";
}

/// Join `requested` under `root`, rejecting traversal. Returns null if
/// `requested` is empty or has a `.`, `..`, empty, or backslash-containing
/// segment (blocking absolute paths, `..`, `./`, `//`). Arena-allocated result.
pub fn safeJoin(arena: std.mem.Allocator, root: []const u8, requested: []const u8) ?[]const u8 {
    if (requested.len == 0) return null;
    var it = std.mem.splitScalar(u8, requested, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null) return null;
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, requested }) catch null;
}

const testing = std.testing;

test "contentType maps known extensions, defaults otherwise" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentType("index.html"));
    try testing.expectEqualStrings("text/css", contentType("a/b/style.css"));
    try testing.expectEqualStrings("text/javascript", contentType("app.js"));
    try testing.expectEqualStrings("application/json", contentType("data.json"));
    try testing.expectEqualStrings("image/png", contentType("logo.png"));
    try testing.expectEqualStrings("application/octet-stream", contentType("noext"));
    try testing.expectEqualStrings("application/octet-stream", contentType("archive.tar.gz"));
}

test "safeJoin joins safe paths and rejects traversal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("static/a/b.txt", safeJoin(a, "static", "a/b.txt").?);
    try testing.expect(safeJoin(a, "static", "") == null);
    try testing.expect(safeJoin(a, "static", "..") == null);
    try testing.expect(safeJoin(a, "static", "a/../x") == null);
    try testing.expect(safeJoin(a, "static", "/etc/passwd") == null); // leading slash -> empty seg
    try testing.expect(safeJoin(a, "static", "./x") == null);
    try testing.expect(safeJoin(a, "static", "a//b") == null);
}
```

- [ ] **Step 2: Make its tests run** — `files.zig` is imported transitively in Task 2. To run its tests now, temporarily add to `src/root.zig` (after the other `extract/*` exports):

```zig
pub const files = @import("extract/files.zig");
```

- [ ] **Step 3: Run to verify** — Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (2 new tests).

- [ ] **Step 4: Commit**

```bash
git add src/extract/files.zig src/root.zig
git commit -m "feat(files): contentType + safeJoin helpers"
```

---

## Task 2: `Files` extractor + `PayloadTooLarge` classification

**Files:** Modify `src/extract/files.zig`, `src/error.zig`, `src/root.zig`

- [ ] **Step 1: Write the failing tests** — add to the test section of `src/extract/files.zig`:

```zig
const Io = std.Io;

test "Files.file reads an existing file and sets content type" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const f = Files{ .io = io, .arena = arena.allocator() };
    const r = try f.file("build.zig"); // present at the repo root (test cwd)
    try testing.expect(std.mem.indexOf(u8, r.body, "pub fn build") != null);
    try testing.expectEqualStrings("application/octet-stream", r.content_type); // .zig unmapped
}

test "Files.file missing path -> NotFound" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = Files{ .io = io, .arena = arena.allocator() };
    try testing.expectError(error.NotFound, f.file("this-does-not-exist.txt"));
}

test "Files.dir rejects traversal -> NotFound" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = Files{ .io = io, .arena = arena.allocator() };
    try testing.expectError(error.NotFound, f.dir(".", "../secret"));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|Files|FAIL"`
Expected: compile error — no `Files`.

- [ ] **Step 3: Add the `Files` extractor** — in `src/extract/files.zig`, add (before the `const testing` line):

```zig
pub const Files = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!Files {
        return .{ .io = ctx.io, .arena = ctx.arena };
    }

    /// Serve an explicit (handler-controlled) file path, relative to the cwd.
    pub fn file(self: Files, path: []const u8) !Response {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io, path, self.arena, std.Io.Limit.limited(default_max_file_size),
        ) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.Forbidden,
            error.StreamTooLong => return error.PayloadTooLarge,
            else => return error.Internal,
        };
        return .{ .content_type = contentType(path), .body = bytes };
    }

    /// Safely serve `requested` under `root`. Traversal (`..`/absolute) → 404.
    pub fn dir(self: Files, root: []const u8, requested: []const u8) !Response {
        const joined = safeJoin(self.arena, root, requested) orelse return error.NotFound;
        return self.file(joined);
    }
};
```

- [ ] **Step 4: Export `Files` from `src/root.zig`** — replace the temporary `pub const files = @import("extract/files.zig");` line (added in Task 1) with:

```zig
pub const files = @import("extract/files.zig");
pub const Files = files.Files;
```

- [ ] **Step 5: Add the classify arm + test** — in `src/error.zig`, in the `classify` switch, add (next to the other status arms):

```zig
        error.PayloadTooLarge => .{ .status = .payload_too_large, .reason = "payload too large" },
```

And add a test to `src/error.zig`'s test section:

```zig
test "classify maps PayloadTooLarge to 413" {
    try testing.expectEqual(Status.payload_too_large, classify(error.PayloadTooLarge).status);
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass (3 Files tests + 1 classify test).

- [ ] **Step 7: Commit**

```bash
git add src/extract/files.zig src/error.zig src/root.zig
git commit -m "feat(files): Files extractor (file/dir) + PayloadTooLarge classification"
```

---

## Task 3: Thread `io` through `Context`/`dispatch` + server integration

**Files:** Modify `src/extract/extract.zig`, `src/server.zig`

- [ ] **Step 1: Write the failing integration test** — add to the test section of `src/server.zig` (uses existing helpers `TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`):

```zig
const Files = @import("extract/files.zig").Files;
fn serveBuild(files: Files) !Response {
    return files.file("build.zig");
}
const PathRest = struct { rest: []const u8 };
fn serveAsset(p: @import("extract/path.zig").Path(PathRest), files: Files) !Response {
    return files.dir(".", p.value.rest);
}

test "files: serve a file and reject traversal over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/build", serveBuild);
    try app.get("/assets/:rest", serveAsset);

    const port: u16 = 18160;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [64 * 1024]u8 = undefined;
    // Serve build.zig: 200 with content-length and the file body.
    const r1 = doRequest(io, port, "GET /build HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r1, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "content-length:") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "pub fn build") != null);

    // Traversal attempt -> 404 (safeJoin rejects "..").
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /assets/.. HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "404 Not Found") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|no member named 'io'|FAIL"`
Expected: compile error — `Context` has no `io` field (the `Files.fromContext` reads `ctx.io`).

- [ ] **Step 3: Add `io` to `Context`** — in `src/extract/extract.zig`, in the `Context` struct, add `io` after the `arena` field:

```zig
        arena: std.mem.Allocator,
        io: std.Io,
```

- [ ] **Step 4: Fix the `extract.zig` test `makeCtx`** — in `src/extract/extract.zig`'s test section, the `makeCtx` helper currently ends with `return .{ .req = &S.req, .params = params, .state = db, .arena = arena };`. Change it to include `.io`:

```zig
    return .{ .req = &S.req, .params = params, .state = db, .arena = arena, .io = undefined };
}
```

(That test path never reads `io`, so `undefined` is safe.)

- [ ] **Step 5: Thread `io` through `server.zig` `makeCtx` + `dispatch`** — in `src/server.zig`:

(a) Replace `makeCtx`:

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
```

with (adds an `io` parameter, sets `.io`):

```zig
        fn makeCtx(self: *Self, io: Io, req: *const request.Request, params: []const Param, arena: *std.heap.ArenaAllocator) Ctx {
            return .{
                .req = req,
                .params = params,
                .state = self.state,
                .arena = arena.allocator(),
                .io = io,
                .trust_forwarded = self.opts.trust_forwarded,
            };
        }
```

(b) Replace `dispatch`'s signature line and its four `makeCtx` calls. The current function is:

```zig
        fn dispatch(self: *Self, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch {
                const ctx = self.makeCtx(req, &.{}, arena);
                return self.renderError(err_mod.Error.BadRequest, &ctx);
            };

            switch (outcome) {
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
                .found => |f| {
                    const ctx = self.makeCtx(req, f.params, arena);
                    return Chn.run(self.mws.items, f.handler, &ctx) catch |e| self.renderError(e, &ctx);
                },
            }
        }
```

Replace with (every signature/call gains `io`):

```zig
        fn dispatch(self: *Self, io: Io, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            var params_buf: [max_params]Param = undefined;
            const outcome = self.router.match(req.method, req.path, &params_buf) catch {
                const ctx = self.makeCtx(io, req, &.{}, arena);
                return self.renderError(err_mod.Error.BadRequest, &ctx);
            };

            switch (outcome) {
                .not_found => {
                    const ctx = self.makeCtx(io, req, &.{}, arena);
                    return self.renderError(err_mod.Error.NotFound, &ctx);
                },
                .method_not_allowed => |allowed| {
                    const ctx = self.makeCtx(io, req, &.{}, arena);
                    var resp = self.renderError(err_mod.Error.MethodNotAllowed, &ctx);
                    resp = resp.withHeader(ctx.arena, "allow", allowHeader(ctx.arena, allowed)) catch resp;
                    return resp;
                },
                .found => |f| {
                    const ctx = self.makeCtx(io, req, f.params, arena);
                    return Chn.run(self.mws.items, f.handler, &ctx) catch |e| self.renderError(e, &ctx);
                },
            }
        }
```

(c) Update the `handleConn` dispatch call — find `var resp = self.dispatch(&parsed.request, &arena);` and change it to:

```zig
                var resp = self.dispatch(io, &parsed.request, &arena);
```

(d) Update the two alloc-accounting test `dispatch` calls — both `const resp = app.dispatch(&parsed.request, &arena);` lines become:

```zig
    const resp = app.dispatch(undefined, &parsed.request, &arena);
```

(Those tests don't read `io`, so `undefined` is safe.)

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the file integration test plus every existing test (the `io` threading is behavior-neutral for non-file handlers).

- [ ] **Step 7: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 8: Commit**

```bash
git add src/extract/extract.zig src/server.zig
git commit -m "feat(server): thread io through Context for file serving + integration test"
```

---

## Task 4: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README extractor row + note** — in `README.md`, in the `## Extractors` table, add a row (after the `Bytes` row):

```markdown
| `Files` | serve files: `files.file(path)` / `files.dir(root, requested)` (traversal-safe) |
```

Then, in the `## Responses` section, after the SSE paragraph, add:

```markdown
Serve static files with the `Files` extractor — `files.file("static/index.html")`
for an explicit path, or `files.dir("static", requested)` to safely serve a
request-derived path under a root (rejects `..`/absolute → 404). Files are
buffered (Content-Length set), content-type inferred by extension.
```

- [ ] **Step 2: getting-started note** — in `docs/getting-started.md`, in the `### Responses` subsection, append:

```markdown

Serve files with the `Files` extractor: `files.file("static/app.css")` or the
traversal-safe `files.dir("static", requested)`.
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document the Files extractor (static file serving)"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines (Task 1 +2, Task 2 +4, Task 3 +1 = +7 over the 94 baseline → 101).

- [ ] Live smoke (optional): `zig build run`; the demo has no file route — the integration test covers serving + traversal end-to-end.

---

## Self-review notes (already applied)

- **Spec coverage:** contentType/safeJoin (Task 1); Files extractor + PayloadTooLarge classify (Task 2); Context.io threading + integration (Task 3); docs (Task 4). All spec components covered.
- **Type consistency:** `Files{ io: std.Io, arena: std.mem.Allocator }` with `file(path) !Response` / `dir(root, requested) !Response`; `contentType(path) []const u8`; `safeJoin(arena, root, requested) ?[]const u8`; `Context.io: std.Io`; `makeCtx(io, req, params, arena)`; `dispatch(io, req, arena)`. Consistent across tasks.
- **No placeholders:** complete code in every step; the `.found` makeCtx call's params arg is called out explicitly (`f.params`).
- **io-threading completeness:** Context field (no default) + both `Context` literal builders (server `makeCtx`, extract test `makeCtx`) + the two alloc-test `dispatch` calls + the `handleConn` call — all updated in Task 3.
- **Test files:** serving the repo's own `build.zig` avoids temp-file creation; `safeJoin`/`contentType` unit-tested directly.
```
