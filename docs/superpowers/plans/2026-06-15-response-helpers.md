# Response Helpers (C-b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `redirect`, `html`, and a typed `json` constructor to `Response`, plus 303/307/308 statuses.

**Architecture:** Extend the existing `Response` struct with a `location: ?[]const u8` field (emitted by `write()` only when set) and new constructors. No dispatcher change — `IntoResponse` already passes a `Response` through.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-15-response-helpers-design.md`. Branch: `feat/response-helpers`. Confirmed serialize call: `std.json.Stringify.valueAlloc(arena, value, .{}) error{OutOfMemory}![]u8`.

**Conventions:** Tests via `zig build test --summary all`. TDD per task. Do NOT touch main.

---

## File Structure

- **Modify** `src/http/response.zig` — `Status` (3 redirect codes), `location` field + `write()` line, `html`/`json`/`redirect`/wrappers, tests.
- **Modify** `src/server.zig` — redirect integration test.
- **Modify** `README.md`, `docs/getting-started.md` — responses note.

---

## Task 1: Redirect statuses (303/307/308)

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing test** — add to the test section:

```zig
test "redirect statuses: 303/307/308 codes and reasons" {
    try testing.expectEqual(@as(u16, 303), Status.see_other.code());
    try testing.expectEqualStrings("See Other", Status.see_other.reason());
    try testing.expectEqual(@as(u16, 307), Status.temporary_redirect.code());
    try testing.expectEqualStrings("Temporary Redirect", Status.temporary_redirect.reason());
    try testing.expectEqual(@as(u16, 308), Status.permanent_redirect.code());
    try testing.expectEqualStrings("Permanent Redirect", Status.permanent_redirect.reason());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error|see_other"`
Expected: compile error — no member `see_other`.

- [ ] **Step 3: Implement** — in the `Status` enum, add after `found = 302,` and `not_modified = 304,`:

```zig
    see_other = 303,
    temporary_redirect = 307,
    permanent_redirect = 308,
```

And in the `reason` switch, add (near the other 3xx arms):

```zig
            .see_other => "See Other",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): add 303/307/308 redirect statuses"
```

---

## Task 2: `location` field + `write()` emission + `redirect` family

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing tests** — add to the test section (the file has a `serialize(buf, response) []const u8` test helper that serializes via a fixed buffer):

```zig
test "redirect sets status and Location, omits Location when unset" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.redirect(.found, "/dashboard"));
    try testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 302 Found\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "location: /dashboard\r\n") != null);

    // A plain text response must NOT emit a location header.
    var buf2: [256]u8 = undefined;
    const plain = serialize(&buf2, Response.text("hi"));
    try testing.expect(std.mem.indexOf(u8, plain, "location:") == null);
}

test "redirect convenience wrappers use the right status" {
    try testing.expectEqual(Status.see_other, Response.seeOther("/a").status);
    try testing.expectEqual(Status.temporary_redirect, Response.temporaryRedirect("/b").status);
    try testing.expectEqual(Status.permanent_redirect, Response.permanentRedirect("/c").status);
    try testing.expectEqualStrings("/a", Response.seeOther("/a").location.?);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|location|redirect"`
Expected: compile error — `Response` has no `location` field / no `redirect`.

- [ ] **Step 3: Add the `location` field** — in the `Response` struct, add after the `headers` field (before `keep_alive`):

```zig
    /// When set, emitted as a `Location:` response header (used by redirects).
    location: ?[]const u8 = null,
```

- [ ] **Step 4: Emit it in `write()`** — in `Response.write`, add this line immediately after the `for (self.headers) |h| { ... }` loop and before the `connection` line:

```zig
        if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
```

- [ ] **Step 5: Add the redirect constructors** — add these methods to the `Response` struct (after `fromStatus`):

```zig
    /// A redirect to `location` with the given 3xx status.
    pub fn redirect(status: Status, location: []const u8) Response {
        return .{ .status = status, .location = location };
    }
    pub fn seeOther(location: []const u8) Response {
        return redirect(.see_other, location);
    }
    pub fn temporaryRedirect(location: []const u8) Response {
        return redirect(.temporary_redirect, location);
    }
    pub fn permanentRedirect(location: []const u8) Response {
        return redirect(.permanent_redirect, location);
    }
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the new redirect tests AND the existing `serialize`/golden-bytes tests (the `text` response is unchanged because `location` is null).

- [ ] **Step 7: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): Response.location + redirect constructors"
```

---

## Task 3: `html` and typed `json` constructors

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing tests** — add to the test section:

```zig
test "html sets text/html content type" {
    var buf: [256]u8 = undefined;
    const out = serialize(&buf, Response.html("<h1>Hi</h1>"));
    try testing.expect(std.mem.indexOf(u8, out, "content-type: text/html; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, out, "<h1>Hi</h1>"));
}

test "json serializes a value into the arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try Response.json(arena.allocator(), .{ .a = @as(u32, 1), .b = "x" });
    try testing.expectEqualStrings("application/json", r.content_type);
    try testing.expectEqualStrings("{\"a\":1,\"b\":\"x\"}", r.body);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|html|json"`
Expected: compile error — `Response` has no `html`/`json`.

- [ ] **Step 3: Implement** — add these methods to the `Response` struct (after the redirect constructors):

```zig
    /// HTML body with a text/html content type.
    pub fn html(body: []const u8) Response {
        return .{ .content_type = "text/html; charset=utf-8", .body = body };
    }

    /// Serialize `value` to a JSON body in `arena` (typed counterpart to jsonRaw).
    pub fn json(arena: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!Response {
        const body = try std.json.Stringify.valueAlloc(arena, value, .{});
        return .{ .content_type = "application/json", .body = body };
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass. If the JSON body bytes differ (e.g. field order or spacing), adjust the expected string in the test to match `std.json.Stringify.valueAlloc`'s output for `.{ .a = 1, .b = "x" }` — it should be compact `{"a":1,"b":"x"}` with struct field order preserved.

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): Response.html and typed Response.json constructors"
```

---

## Task 4: Integration test + docs

**Files:** Modify `src/server.zig`, `README.md`, `docs/getting-started.md`

- [ ] **Step 1: Write the integration test** — add to the test section of `src/server.zig` (uses existing helpers `TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`):

```zig
fn redirectHandler() Response {
    return Response.redirect(.found, "/next");
}

test "responses: redirect over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.get("/old", redirectHandler);

    const port: u16 = 18130;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const r = doRequest(io, port, "GET /old HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "302 Found") != null);
    try testing.expect(std.mem.indexOf(u8, r, "location: /next\r\n") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass.

- [ ] **Step 3: README "Responses" note** — in `README.md`, insert this section immediately AFTER the `## Error handling` section and before `## Limits & timeouts`:

```markdown
## Responses

Build responses with the `Response` constructors:

| Constructor | Result |
|---|---|
| `Response.text(s)` | `text/plain` body |
| `Response.html(s)` | `text/html` body |
| `Response.json(arena, value)` | JSON-serialized body (`application/json`) |
| `Response.jsonRaw(s)` | pre-serialized JSON string |
| `Response.redirect(status, loc)` | redirect with a `Location` header |
| `Response.seeOther/temporaryRedirect/permanentRedirect(loc)` | 303 / 307 / 308 redirects |
| `Response.fromStatus(s)` | bare status |
| `r.withHeader(arena, name, value)` | add a response header |
```

- [ ] **Step 4: getting-started note** — in `docs/getting-started.md`, in the "## 4. Write the service" section near the `### Errors` / `### Limits & timeouts` subsections, add:

```markdown
### Responses

`Response.text` / `.html` / `.json(arena, value)` / `.redirect(.found, "/path")` /
`.fromStatus(.created)` cover the common cases; `r.withHeader(arena, n, v)` adds
headers.
```

- [ ] **Step 5: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/server.zig README.md docs/getting-started.md
git commit -m "test+docs: redirect integration and response-helpers documentation"
```

---

## Final verification

- [ ] Full suite:

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|Build Summary"`
Expected: all pass (Task 1 +1, Task 2 +2, Task 3 +2, Task 4 +1 = +6 over the 81 baseline → 87).

- [ ] Live smoke (optional): `zig build run`; the demo has no redirect route, but the integration test covers redirect end-to-end.

---

## Self-review notes (already applied)

- **Spec coverage:** statuses (Task 1); location field + write + redirect family (Task 2); html + json (Task 3); integration + docs (Task 4). All spec components covered.
- **Type consistency:** `location: ?[]const u8`; `redirect(status, location)`, `seeOther/temporaryRedirect/permanentRedirect(location)`; `html(body)`; `json(arena, value) Allocator.Error!Response` using `std.json.Stringify.valueAlloc`. Statuses `see_other`/`temporary_redirect`/`permanent_redirect` consistent across tasks.
- **No placeholders:** complete code in every step; the one output-format caveat (JSON byte string) has an explicit fallback instruction in Task 3 Step 4.
- **Golden-bytes safety:** Task 2 includes the null-location omission assertion; existing `text` serialization tests stay green.
```
