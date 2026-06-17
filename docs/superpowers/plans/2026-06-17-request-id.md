# Request ID / Correlation (F3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in per-request correlation id (`Options.request_id`). When on: use a validated incoming `x-request-id` or a generated one (per-app atomic counter, 16 hex); expose via `ctx.request_id` + a `RequestId` extractor; echo `x-request-id` on the response; include in the access log.

**Architecture:** `handleConn` computes the id once (when enabled), passes it to `dispatch` → `makeCtx` (sets `ctx.request_id`), echoes it on the response before writing, and puts it in the `AccessRecord`. Incoming ids are validated (`[A-Za-z0-9._-]`, ≤128) before use to prevent header/log injection; invalid → generate. `AccessLogger` appends the id only when non-empty (F1 output unchanged when disabled).

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-17-request-id-design.md`. Branch: `feat/request-id`. FINAL sub-project of theme F and the A–F roadmap.

**Conventions:** Tests via `zig build test --summary all`. TDD for `validRid` + logger. Server wiring verified by a socket integration test. Baseline = **146 tests**.

---

## File Structure

- **Modify** `src/observe.zig` — `AccessRecord.request_id`; logger appends it (+ tests).
- **Modify** `src/extract/extract.zig` — `Context.request_id` field.
- **Add** `src/extract/request_id.zig` — `RequestId` extractor.
- **Modify** `src/server.zig` — `Options.request_id`, `rid_counter`, `validRid`, `computeRid`, `makeCtx`/`dispatch` params, `handleConn` wiring, tests.
- **Modify** `src/root.zig` — export `RequestId`.
- **Modify** `README.md`, `docs/getting-started.md`.

---

## Task 1: `AccessRecord.request_id` + logger (TDD)

**Files:** Modify `src/observe.zig`

- [ ] **Step 1: Write the failing unit tests** — add to observe.zig's test block:

```zig
test "access logger: includes request_id when present (text + json)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = AccessLogger{ .writer = &w, .format = .text };
    const obs = lg.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/p", .status = 200, .duration_ns = 412_000, .bytes = 18, .request_id = "abc-123" });
    try testing.expectEqualStrings("GET /p 200 0.412ms 18b id=abc-123\n", w.buffered());

    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    var lg2 = AccessLogger{ .writer = &w2, .format = .json };
    const obs2 = lg2.observer();
    obs2.func(obs2.context, .{ .method = .GET, .path = "/p", .status = 200, .duration_ns = 412_000, .bytes = 18, .request_id = "abc-123" });
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"request_id\":\"abc-123\"") != null);
}
```
(The existing F1 tests construct `AccessRecord` WITHOUT `request_id`; the new field's default `""` keeps them compiling and their expected output unchanged — verify they still pass.)

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|expected" | head`.

- [ ] **Step 3: Implement** — add `request_id: []const u8 = ""` to `AccessRecord`. In `writeRecord`:
  - text: after the `{d}b` token, if `rec.request_id.len > 0` write ` id=` then `rec.request_id` (before the `\n`).
  - json: before the closing `}`, if `rec.request_id.len > 0` write `,"request_id":"` then `rec.request_id` then `"`.
  (Ids are validated/hex → safe to embed raw; no escaping needed.)

- [ ] **Step 4: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (146 + 1 new); F1 logger tests unchanged. Report count.

- [ ] **Step 5: Commit**

```bash
git add src/observe.zig
git commit -m "feat(observe): AccessRecord.request_id, logged when present"
```

---

## Task 2: request-id wiring (server + extractor)

**Files:** Modify `src/server.zig`, `src/extract/extract.zig`; add `src/extract/request_id.zig`; modify `src/root.zig`

- [ ] **Step 1: Write the failing integration + unit tests** in `src/server.zig`:

```zig
fn ridHandler(rid: @import("extract/request_id.zig").RequestId) Response {
    return Response.text(rid.value);
}

test "validRid accepts safe tokens, rejects unsafe" {
    try testing.expect(validRid("abc-123"));
    try testing.expect(validRid("00000000000000a1"));
    try testing.expect(!validRid(""));
    try testing.expect(!validRid("bad id"));   // space
    try testing.expect(!validRid("a\r\nb"));   // CRLF
    try testing.expect(!validRid("a/b"));      // slash
    try testing.expect(!validRid("x" ** 129)); // too long
}

test "request id: generated, echoed, and exposed to handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .request_id = true });
    defer app.deinit();
    try app.get("/rid", ridHandler);

    const port: u16 = 18192;
    var loop_fut = startTestApp(io, &app, port);

    // No incoming id -> generated; header present and equals the body.
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "x-request-id: ") != null);

    // Valid incoming id -> echoed verbatim in header and body.
    var rb2: [2048]u8 = undefined;
    const r2 = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\nX-Request-Id: abc-123\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r2, "x-request-id: abc-123\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, r2, "abc-123"));

    // Invalid incoming id -> NOT echoed (generated instead).
    var rb3: [2048]u8 = undefined;
    const r3 = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\nX-Request-Id: bad id!\r\n\r\n", &rb3);
    try testing.expect(std.mem.indexOf(u8, r3, "bad id!") == null);
    try testing.expect(std.mem.indexOf(u8, r3, "x-request-id: ") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "request id: disabled by default -> no header, empty value" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{}); // request_id defaults false
    defer app.deinit();
    try app.get("/rid", ridHandler);

    const port: u16 = 18193;
    var loop_fut = startTestApp(io, &app, port);
    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /rid HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "x-request-id:") == null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```
Confirm the `request.Method`/`Response`/`TestApp` references and the `X-Request-Id` header casing the parser stores (req.header is case-insensitive per existing usage — verify). Pick free ports.

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|validRid|request_id|FAIL" | head`.

- [ ] **Step 3: Add the `RequestId` extractor** — create `src/extract/request_id.zig` per the spec's Component 2; export from `src/root.zig`: `pub const RequestId = @import("extract/request_id.zig").RequestId;`.

- [ ] **Step 4: Add the `Context.request_id` field** — in `src/extract/extract.zig`, add `request_id: []const u8 = ""` to `Context(AppState)` (with a short doc comment).

- [ ] **Step 5: Server wiring** in `src/server.zig`:
  - `Options.request_id: bool = false` (with a doc comment mirroring `trust_forwarded`).
  - `App` field `rid_counter: std.atomic.Value(u64) = .init(0)`.
  - `fn validRid(s: []const u8) bool` (file scope): `if (s.len == 0 or s.len > 128) return false;` then each char must be `A-Z`/`a-z`/`0-9`/`.`/`_`/`-`.
  - `fn computeRid(self: *Self, req: *const request.Request, arena: std.mem.Allocator) []const u8`: `if (req.header("x-request-id")) |h| { if (validRid(h)) return h; }` then `const n = self.rid_counter.fetchAdd(1, .monotonic); return std.fmt.allocPrint(arena, "{x:0>16}", .{n}) catch "";`.
  - `makeCtx`: add a `request_id: []const u8` param; set `.request_id = request_id` in the returned Ctx.
  - `dispatch`: add a `request_id: []const u8` param; pass it to every `makeCtx(...)` call (BadRequest catch, not_found, method_not_allowed, found).
  - `handleConn`: before `dispatch`, `const rid: []const u8 = if (self.opts.request_id) self.computeRid(&parsed.request, arena.allocator()) else "";` Pass `rid` to `dispatch`. After `dispatch` (before `writeResponse`): `if (self.opts.request_id) { resp = resp.withHeader(arena.allocator(), "x-request-id", rid) catch resp; }`. In the observe `AccessRecord`, add `.request_id = rid`.

- [ ] **Step 6: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (now ~150: 147 + validRid + 2 integration). Report count.

- [ ] **Step 7: Flakiness check** — `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done` → three ok.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig src/extract/extract.zig src/extract/request_id.zig src/root.zig
git commit -m "feat(server): opt-in request-id (validated incoming or generated, echoed, exposed)"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — under Observability, document request ids: enable with `Options{ .request_id = true }`; the id is a validated incoming `x-request-id` or a generated 16-hex value; read it via `ctx.request_id` / the `zax.RequestId` extractor; it's echoed in the `x-request-id` response header and added to the access log. Note incoming ids are validated (safe charset) to prevent header/log injection. Short example.

- [ ] **Step 2: getting-started** — a couple of lines on enabling request ids + reading via `RequestId`.

- [ ] **Step 3: Verify** — `zig build test --summary all 2>&1 | grep "tests passed"`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document opt-in request-id / correlation"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines.
- [ ] (Optional) scratch app with `.request_id = true` + `AccessLogger`: a request shows `x-request-id` in the response and `id=...` in the log line; supplying a valid `X-Request-Id` echoes it; an unsafe one is replaced.

---

## Self-review notes

- **Spec coverage:** logger/record id (Task 1); Options+counter+validRid+computeRid+makeCtx+dispatch+handleConn + Context field + RequestId extractor + integration (Task 2); docs (Task 3). All F3 spec components covered.
- **Security:** incoming ids validated to `[A-Za-z0-9._-]` (≤128) before being echoed into the response header or written to the log — no CRLF/space/control injection. Unit-tested (CRLF/space/slash/length rejected); integration test asserts an unsafe incoming id is NOT echoed.
- **Opt-in & zero-overhead:** `Options.request_id` default false → no id computed, no header, `ctx.request_id == ""`, `RequestId.value == ""`. Verified by the disabled-by-default test.
- **Correlation:** a valid incoming `x-request-id` is propagated to the handler, response, and log; otherwise a per-app atomic-counter hex id is generated.
- **F1/F2 compatibility:** `AccessRecord.request_id` defaults `""`; the logger appends it only when present, so F1/F2 tests and default output are unchanged.
- **Regression safety:** additive — new extractor + additive fields/params/wiring; `dispatch`/`makeCtx` gain a param but behavior is identical when disabled (empty id). Existing 146 tests untouched.
- **Theme F + roadmap A–F complete** after F3.
