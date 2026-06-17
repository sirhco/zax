# Observation Hook + Access Logger (F1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-request observation hook (`app.observe(observer)`, an appendable list) fired in `handleConn` for every dispatched response (matched/404/405/error) with timing + size, plus a thread-safe `AccessLogger` (text default, JSON option).

**Architecture:** New `src/observe.zig` defines `AccessRecord`, the type-erased `Observer{context, func}` (same shape as `Response.Streamer`), and `AccessLogger` (writes one formatted line per record to a `*std.Io.Writer` under a mutex; `format` enum text|json; best-effort). `server.zig` gains an `observers` list, an `observe` setter (appends, like `use`), a `nowNs` helper, and a hook in `handleConn`: capture `t0` before `dispatch` (only when observers exist), then after `writeResponse` build an `AccessRecord` and call each observer. Covers all dispatched responses including streamed; pre-dispatch terminal (parse-error) responses are not observed.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-17-observe-access-log-design.md`. Branch: `feat/observe-access-log`. This is the first sub-project of theme F (final theme of the A–F roadmap).

**Conventions:** Tests via `zig build test --summary all`. TDD for the logger formatting. The `handleConn` hook is verified by a server integration test. Baseline = **140 tests**.

---

## File Structure

- **Add** `src/observe.zig` — `AccessRecord`, `Observer`, `AccessLogger` (+ unit tests).
- **Modify** `src/root.zig` — export `observe`, `Observer`, `AccessRecord`, `AccessLogger`.
- **Modify** `src/server.zig` — `observers` field, `observe` setter, `deinit` free, `nowNs`, `handleConn` hook, integration test.
- **Modify** `README.md`, `docs/getting-started.md` — observability/access-log note.

---

## Task 1: `src/observe.zig` — record, observer, access logger (TDD)

**Files:** Add `src/observe.zig`; modify `src/root.zig`

- [ ] **Step 1: Write the failing unit tests** — create `src/observe.zig` with the API surface (see spec Component 1) and a test block:

```zig
const testing = std.testing;

test "access logger: text format" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .text };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/users/42", .status = 200, .duration_ns = 412_000, .bytes = 18 });
    try testing.expectEqualStrings("GET /users/42 200 0.412ms 18b\n", w.buffered());
}

test "access logger: json format escapes path" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .json };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .POST, .path = "/a\"b", .status = 404, .duration_ns = 1_500_000, .bytes = 0 });
    try testing.expectEqualStrings("{\"method\":\"POST\",\"path\":\"/a\\\"b\",\"status\":404,\"dur_us\":1500,\"bytes\":0}\n", w.buffered());
}
```

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|expected" | head`. Expected: `AccessLogger`/`Observer`/`AccessRecord` not defined.

- [ ] **Step 3: Implement** `src/observe.zig` exactly as in the spec's Component 1 (`AccessRecord`, `Observer`, `AccessLogger` with `observer()`, `log`, `writeRecord`; text + json formats; mutex; best-effort `catch {}`). Import `std` and `@import("http/request.zig")` for `Method`. Pure (no server/Io-backend coupling beyond `std.Io.Writer`).

  Note on the fixed-writer test: `writeRecord` ends with `try w.flush()`, which errors on a `Writer.fixed` (nothing to drain) — but `log` wraps the call in `catch {}` and the formatted bytes are already in the buffer, so `w.buffered()` returns the full line. If `std.json.Stringify.encodeJsonString`'s exact name/signature differs in this Zig version, adapt to the available JSON string-escaping API (confirm against std; bench.zig already uses `std.json.Stringify.encodeJsonString` for keys).

- [ ] **Step 4: Export from `src/root.zig`** — add:

```zig
pub const observe = @import("observe.zig");
pub const Observer = observe.Observer;
pub const AccessRecord = observe.AccessRecord;
pub const AccessLogger = observe.AccessLogger;
```

- [ ] **Step 5: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (140 + 2 new observe tests). Report the count.

- [ ] **Step 6: Commit**

```bash
git add src/observe.zig src/root.zig
git commit -m "feat(observe): AccessRecord, Observer, and text/JSON AccessLogger"
```

---

## Task 2: `handleConn` observation hook + integration test

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing integration test** — add to the test section of `src/server.zig`, using existing helpers (`TestApp`, `Db`, `startTestApp`, `doRequest`, `Io`, `testing`, `pingHandler`). A capturing observer that copies the record (path into a fixed buffer so it stays valid after the request):

```zig
const Captured = struct {
    method: TestApp_request_Method_placeholder = undefined, // use the actual request.Method type
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    status: u16 = 0,
    count: usize = 0,
};
fn captureObserver(ctx: *anyopaque, rec: zax.AccessRecord) void {
    const c: *Captured = @ptrCast(@alignCast(ctx));
    c.method = rec.method;
    const n = @min(rec.path.len, c.path_buf.len);
    @memcpy(c.path_buf[0..n], rec.path[0..n]);
    c.path_len = n;
    c.status = rec.status;
    c.count += 1;
}

test "observe: hook fires for matched and 404 with method/path/status" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/ping", pingHandler);

    var cap = Captured{};
    try app.observe(.{ .context = &cap, .func = captureObserver });

    const port: u16 = 18190;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expectEqual(@as(u16, 200), cap.status);
    try testing.expectEqualStrings("/ping", cap.path_buf[0..cap.path_len]);
    try testing.expect(cap.method == .GET);

    var rb2: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expectEqual(@as(u16, 404), cap.status); // observer covers non-matched
    try testing.expect(cap.count >= 2);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```
Replace `TestApp_request_Method_placeholder` with the real method type (`request.Method` / `zax.Method` — match how the file refers to it). Confirm `zax`/`request` are in scope in the test section; adapt the import path for `AccessRecord`/`Method` to the file's conventions.

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|no member named 'observe'|FAIL"`. Expected: `App` has no `observe` method.

- [ ] **Step 3: Add imports/field/setter/deinit** in `src/server.zig`:
  - Near the other `@import`s: `const observe = @import("observe.zig");` (confirm the module path style used in this file).
  - In the `App(AppState)` struct, next to `mws`: `observers: std.ArrayListUnmanaged(observe.Observer) = .empty,`.
  - Setter (near `use`): `pub fn observe(self: *Self, obs: observe.Observer) std.mem.Allocator.Error!void { try self.observers.append(self.gpa, obs); }`.
  - In `deinit`: `self.observers.deinit(self.gpa);`.

- [ ] **Step 4: Add the `nowNs` helper** (file scope, near other helpers):

```zig
fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).toNanoseconds();
}
```
(Confirm `Io.Timestamp.now(io, .awake)`/`.toNanoseconds()` against the pattern in `src/bench.zig`.)

- [ ] **Step 5: Wire the hook into `handleConn`** — around the dispatch/write at src/server.zig:330–334:

```zig
                const t0: i96 = if (self.observers.items.len > 0) nowNs(io) else 0;
                var resp = self.dispatch(io, &parsed.request, &arena);
                const streamed = resp.streamer != null;
                resp.keep_alive = persistent and !streamed;
                if (!writeResponse(w, resp)) break;
                if (self.observers.items.len > 0) {
                    const dur: u64 = @intCast(@max(@as(i96, 0), nowNs(io) - t0));
                    const rec = observe.AccessRecord{
                        .method = parsed.request.method,
                        .path = parsed.request.path,
                        .status = resp.status.code(),
                        .duration_ns = dur,
                        .bytes = resp.body.len,
                    };
                    for (self.observers.items) |obs| obs.func(obs.context, rec);
                }
                if (streamed) break;
```
(Keep the rest of the loop — `cr.consume`, `served`, `persistent` break — unchanged.)

- [ ] **Step 6: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (now 143: 140 + 2 observe + 1 server integration). Report the count.

- [ ] **Step 7: Flakiness check** — `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done` → three ok lines.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): per-request observation hook (App.observe) in handleConn"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — add an "Observability" / access-log note: `app.observe(observer)` registers an observer fired for every request (matched/404/405/error) with method/path/status/duration/bytes; the built-in `AccessLogger` writes text (default) or JSON lines. Example:

```markdown
## Observability

`app.observe(obs)` registers an observer run after every request — matched, 404,
405, or handler error — with method, path, status, duration, and response bytes.
Register as many as you like. A built-in thread-safe `AccessLogger` writes one
line per request (text or JSON):

​```zig
var log = zax.AccessLogger{ .writer = stdout_writer, .format = .text };
try app.observe(log.observer());
// GET /users/42 200 0.412ms 18b
​```
```
(Replace the `​` markers with plain triple backticks; verify the `AccessLogger` init/field spelling and the writer setup against the shipped code.)

- [ ] **Step 2: getting-started** — a short subsection mirroring the above in one or two lines.

- [ ] **Step 3: Verify** — `zig build test --summary all 2>&1 | grep "tests passed"` (143).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document the observation hook and access logger"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines (143).
- [ ] (Optional) a scratch app registering `AccessLogger` over a stdout writer prints one line per request.

---

## Self-review notes

- **Spec coverage:** observe module + logger + tests (Task 1); `handleConn` hook + setter + integration test (Task 2); docs (Task 3). All F1 spec components covered.
- **Foundation for F2/F3:** the appendable `observers` list lets the F2 metrics collector and any F3 logging be additional observers without a combiner.
- **Coverage:** the hook fires for matched, 404, 405, and handler-error responses (all via `dispatch`→`writeResponse`), proven by the matched+404 integration test; streamed responses observed too (bytes = buffered length).
- **Thread safety:** `AccessLogger` serializes with a mutex; the `observers` list is built before serving and only read per request.
- **Zero overhead when unused:** timing + record build guarded by `observers.items.len > 0`.
- **Best-effort logging:** all logger write/flush errors are swallowed so logging never breaks request serving.
- **Regression safety:** additive — new module + additive server fields/hook; existing 140 tests untouched; library behavior unchanged when no observer is registered.
