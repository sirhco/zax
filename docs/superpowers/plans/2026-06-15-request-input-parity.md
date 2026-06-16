# Request Input Parity (C-a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the percent-decoding bug in `Path`/`Query` and add `Form(T)`, `Cookies`, and `Bytes` request extractors.

**Architecture:** A `url.decode` util (zero-copy fast-path, else arena-decode) and a shared `urlencoded.bind` (`k=v&k=v` → struct, with decoding) power `Query` (refactored) and the new `Form`. `Path` decodes path params; `Cookies`/`Bytes` are thin accessors. All follow the existing `fromContext`/extractor-marker pattern.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-15-request-input-parity-design.md`. Branch: `feat/request-input-parity`.

**Conventions:** Tests via `zig build test --summary all` (cross-dir imports need the build; standalone `zig test` won't resolve them). TDD per task. Do NOT touch main.

---

## File Structure

- **Create** `src/url.zig` — percent-decode util. One job: decode a single component.
- **Create** `src/extract/urlencoded.zig` — `bind(T, source, arena)`: `k=v` → struct with decoding. Shared by Query + Form.
- **Create** `src/extract/form.zig`, `src/extract/cookie.zig`, `src/extract/bytes.zig` — the new extractors.
- **Modify** `src/extract/query.zig` (refactor onto `urlencoded.bind`), `src/extract/path.zig` (decode params), `src/error.zig` (`MissingField`→400), `src/root.zig` (exports), `src/server.zig` (integration test), README + getting-started.

---

## Task 1: `url.decode` util

**Files:** Create `src/url.zig`; Modify `src/root.zig`

- [ ] **Step 1: Write `src/url.zig` with the decoder and its tests**

```zig
//! URL percent-decoding for a single component (path segment, query/form value).
//! Zero-copy fast path: a component with no '%' (and no '+' in plus mode) is
//! returned unchanged. Otherwise it is decoded into the arena (decoded length is
//! always <= input length). Malformed '%' sequences are copied literally.

const std = @import("std");

pub fn decode(arena: std.mem.Allocator, raw: []const u8, plus_as_space: bool) std.mem.Allocator.Error![]const u8 {
    const has_pct = std.mem.indexOfScalar(u8, raw, '%') != null;
    const has_plus = plus_as_space and std.mem.indexOfScalar(u8, raw, '+') != null;
    if (!has_pct and !has_plus) return raw; // fast path: zero-copy

    const out = try arena.alloc(u8, raw.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                out[j] = c;
                i += 1;
                j += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                out[j] = c;
                i += 1;
                j += 1;
                continue;
            };
            out[j] = hi * 16 + lo;
            i += 3;
            j += 1;
        } else if (plus_as_space and c == '+') {
            out[j] = ' ';
            i += 1;
            j += 1;
        } else {
            out[j] = c;
            i += 1;
            j += 1;
        }
    }
    return out[0..j];
}

const testing = std.testing;

test "decode: clean input is returned zero-copy (same pointer)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "plain-value";
    const out = try decode(arena.allocator(), raw, true);
    try testing.expectEqual(raw.ptr, out.ptr); // no allocation
}

test "decode: percent sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("John Doe", try decode(arena.allocator(), "John%20Doe", false));
    try testing.expectEqualStrings("a&b", try decode(arena.allocator(), "a%26b", false));
    try testing.expectEqualStrings("a+b", try decode(arena.allocator(), "a%2Bb", true)); // %2B is literal '+'
}

test "decode: plus means space only in plus mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b", try decode(arena.allocator(), "a+b", true));
    try testing.expectEqualStrings("a+b", try decode(arena.allocator(), "a+b", false));
}

test "decode: malformed percent copied literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("100% x", try decode(arena.allocator(), "100%25 x", true) ); // valid -> '%'
    try testing.expectEqualStrings("a%2", try decode(arena.allocator(), "a%2", false)); // truncated
    try testing.expectEqualStrings("a%zz", try decode(arena.allocator(), "a%zz", false)); // non-hex
}
```

- [ ] **Step 2: Export from `src/root.zig`** — add after the `Forwarded` export line (`pub const Forwarded = @import("extract/forwarded.zig").Forwarded;`):

```zig
pub const url = @import("url.zig");
```

- [ ] **Step 3: Run to verify** — Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (4 new decode tests).

- [ ] **Step 4: Commit**

```bash
git add src/url.zig src/root.zig
git commit -m "feat(url): percent-decode util with zero-copy fast path"
```

---

## Task 2: `urlencoded.bind` shared binder

**Files:** Create `src/extract/urlencoded.zig`

- [ ] **Step 1: Write `src/extract/urlencoded.zig` with `bind` and tests**

```zig
//! Bind an `x-www-form-urlencoded` source (`k=v&k=v`) to a struct. Used by both
//! the Query extractor (source = query string) and the Form extractor (source =
//! request body). Each field value is percent-decoded (plus_as_space = true)
//! then scalar-parsed. Optional (`?T`) fields default to null when absent.

const std = @import("std");
const scalar = @import("scalar.zig");
const url = @import("../url.zig");

/// Bind `source` to `T`. Returns `error.MissingField` if a required (non-optional)
/// field is absent. Decoding allocates into `arena` only when a value needs it.
pub fn bind(comptime T: type, source: []const u8, arena: std.mem.Allocator) !T {
    if (@typeInfo(T) != .@"struct") @compileError("urlencoded.bind: T must be a struct");
    var v: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const raw = find(source, f.name);
        switch (@typeInfo(f.type)) {
            .optional => |o| {
                @field(v, f.name) = if (raw) |r|
                    try scalar.parse(o.child, try url.decode(arena, r, true))
                else
                    null;
            },
            else => {
                const r = raw orelse return error.MissingField;
                @field(v, f.name) = try scalar.parse(f.type, try url.decode(arena, r, true));
            },
        }
    }
    return v;
}

/// Find the first `key=value` whose key equals `name` in an `&`-separated source.
fn find(source: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, source, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

const testing = std.testing;

test "bind: required + optional fields with decoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { name: []const u8, page: ?u32, note: ?[]const u8 };
    const v = try bind(T, "name=ada+lovelace&page=3&note=x%26y", arena.allocator());
    try testing.expectEqualStrings("ada lovelace", v.name);
    try testing.expectEqual(@as(?u32, 3), v.page);
    try testing.expectEqualStrings("x&y", v.note.?);
}

test "bind: missing required field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { name: []const u8 };
    try testing.expectError(error.MissingField, bind(T, "page=1", arena.allocator()));
}

test "bind: absent optional is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const T = struct { q: ?[]const u8 };
    const v = try bind(T, "", arena.allocator());
    try testing.expectEqual(@as(?[]const u8, null), v.q);
}
```

- [ ] **Step 2: Make its tests run** — `urlencoded.zig` is imported transitively in a later task. To run its tests now, temporarily it must be reachable from `src/root.zig`. Add this line after the `url` export in `src/root.zig`:

```zig
pub const urlencoded = @import("extract/urlencoded.zig");
```

- [ ] **Step 3: Run to verify** — Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (3 new bind tests).

- [ ] **Step 4: Commit**

```bash
git add src/extract/urlencoded.zig src/root.zig
git commit -m "feat(extract): shared urlencoded.bind binder with decoding"
```

---

## Task 3: Refactor `Query` onto `urlencoded.bind` + `MissingField` classification

**Files:** Modify `src/extract/query.zig`, `src/error.zig`

- [ ] **Step 1: Update the Query missing-field test + add a decoding test**

In `src/extract/query.zig`, find the existing test `"Query missing required field errors"` and change its expected error from `error.MissingQueryParam` to `error.MissingField`:

```zig
test "Query missing required field errors" {
    const Q = Query(struct { active: bool });
    try testing.expectError(error.MissingField, Q.fromContext(ctxWithQuery("page=1")));
}
```

Add a new test (after the existing Query tests):

```zig
test "Query decodes percent and plus" {
    const Q = Query(struct { q: []const u8 });
    const r = try Q.fromContext(ctxWithQuery("q=a+b%26c"));
    try testing.expectEqualStrings("a b&c", r.value.q);
}
```

NOTE: the existing `ctxWithQuery` test helper in this file builds a context with a `req` but no `arena`. `urlencoded.bind` needs `ctx.arena`. Update `ctxWithQuery` to also provide an arena. Replace the existing `ctxWithQuery` helper with:

```zig
fn ctxWithQuery(q: []const u8) struct { req: *const Request, arena: std.mem.Allocator } {
    const S = struct {
        var req: Request = undefined;
        var arena: std.heap.ArenaAllocator = undefined;
    };
    S.req = .{
        .method = .GET,
        .target = "",
        .path = "",
        .query = q,
        .version_minor = 1,
        .headers = &.{},
        .body = "",
    };
    S.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    return .{ .req = &S.req, .arena = S.arena.allocator() };
}
```

(This leaks the arena across tests, which is acceptable in a test-only helper that runs briefly; the process exits after tests. The existing helper already used a static `req`.)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|MissingField|FAIL"`
Expected: FAIL — `Query` still uses `error.MissingQueryParam` and doesn't decode; also `ctx.arena` unused mismatch.

- [ ] **Step 3: Refactor `Query`** — replace the entire `pub fn Query(...)` function and the file-local `find` in `src/extract/query.zig`. The current definitions are:

```zig
pub fn Query(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Query(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) Error!@This() {
            var v: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const raw = find(ctx.req.query, f.name);
                switch (@typeInfo(f.type)) {
                    .optional => |o| {
                        @field(v, f.name) = if (raw) |r| try scalar.parse(o.child, r) else null;
                    },
                    else => {
                        const r = raw orelse return error.MissingQueryParam;
                        @field(v, f.name) = try scalar.parse(f.type, r);
                    },
                }
            }
            return .{ .value = v };
        }
    };
}

/// Find the first `key=value` whose key equals `name` in a `&`-separated query.
fn find(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}
```

Replace BOTH with:

```zig
pub fn Query(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Query(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = false;

        pub fn fromContext(ctx: anytype) !@This() {
            return .{ .value = try urlencoded.bind(T, ctx.req.query, ctx.arena) };
        }
    };
}
```

Then update the imports at the top of `src/extract/query.zig`: it currently has `const scalar = @import("scalar.zig");` and `pub const Error = error{ MissingQueryParam, InvalidScalar, InvalidEnum };`. The `scalar` import and the `Error` decl are now unused — DELETE the `pub const Error = ...` line, DELETE `const scalar = @import("scalar.zig");`, and ADD `const urlencoded = @import("urlencoded.zig");`. Keep `const std = @import("std");` and `const Request = @import("../http/request.zig").Request;` (used by the test helper).

- [ ] **Step 4: Add `MissingField` to `classify`** — in `src/error.zig`, in the `classify` switch, add this arm next to the other extractor tags (e.g. after the `MissingQueryParam` arm):

```zig
        error.MissingField => .{ .status = .bad_request, .reason = "missing form field" },
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass (Query now decodes; missing-field test green; existing Query binding test still green).

- [ ] **Step 6: Commit**

```bash
git add src/extract/query.zig src/error.zig
git commit -m "refactor(extract): Query uses urlencoded.bind; add MissingField classification"
```

---

## Task 4: `Path` percent-decoding

**Files:** Modify `src/extract/path.zig`

- [ ] **Step 1: Write the failing test** — add to the test section of `src/extract/path.zig`. NOTE: the existing `FakeCtx` test helper there has only `params`; `url.decode` needs `arena`. Replace the existing `FakeCtx` with one that includes an arena, and add a decode test:

```zig
const FakeCtx = struct { params: []const Param, arena: std.mem.Allocator };

fn fakeCtx(params: []const Param, arena: std.mem.Allocator) FakeCtx {
    return .{ .params = params, .arena = arena };
}

test "Path decodes percent-encoded params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const params = [_]Param{.{ .name = "name", .value = "John%20Doe" }};
    const P = Path(struct { name: []const u8 });
    const p = try P.fromContext(fakeCtx(&params, arena.allocator()));
    try testing.expectEqualStrings("John Doe", p.value.name);
}
```

Also update the THREE existing Path tests in this file that build `FakeCtx{ .params = ... }` to use the new helper with an arena. For each, add `var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();` and change `FakeCtx{ .params = &params }` to `fakeCtx(&params, arena.allocator())`. (The three tests are: "Path binds struct fields from named params", "Path scalar binds single param", "Path missing param errors".)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|John Doe|FAIL"`
Expected: FAIL — `Path` returns the raw `"John%20Doe"`, and `arena` field is now required.

- [ ] **Step 3: Implement decoding** — in `src/extract/path.zig`, add the url import at the top (next to `const scalar = @import("scalar.zig");`):

```zig
const url = @import("../url.zig");
```

Then replace the `fromContext` body. The current one is:

```zig
        pub fn fromContext(ctx: anytype) Error!@This() {
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    var v: T = undefined;
                    inline for (s.fields) |f| {
                        const raw = find(ctx.params, f.name) orelse return error.MissingPathParam;
                        @field(v, f.name) = try scalar.parse(f.type, raw);
                    }
                    return .{ .value = v };
                },
                else => {
                    if (ctx.params.len == 0) return error.MissingPathParam;
                    return .{ .value = try scalar.parse(T, ctx.params[0].value) };
                },
            }
        }
```

Replace with (note return type changes from `Error!@This()` to `!@This()` because `url.decode` adds `error.OutOfMemory`):

```zig
        pub fn fromContext(ctx: anytype) !@This() {
            switch (@typeInfo(T)) {
                .@"struct" => |s| {
                    var v: T = undefined;
                    inline for (s.fields) |f| {
                        const raw = find(ctx.params, f.name) orelse return error.MissingPathParam;
                        const decoded = try url.decode(ctx.arena, raw, false);
                        @field(v, f.name) = try scalar.parse(f.type, decoded);
                    }
                    return .{ .value = v };
                },
                else => {
                    if (ctx.params.len == 0) return error.MissingPathParam;
                    const decoded = try url.decode(ctx.arena, ctx.params[0].value, false);
                    return .{ .value = try scalar.parse(T, decoded) };
                },
            }
        }
```

The `pub const Error = error{ MissingPathParam, InvalidScalar, InvalidEnum };` declaration is now unused by `fromContext` (which infers its error set) but `error.MissingPathParam` is still returned. You may keep the `Error` decl (harmless, documents the domain errors) — do NOT delete it, since `classify` and external readers reference these tags by value.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/extract/path.zig
git commit -m "fix(extract): percent-decode Path params"
```

---

## Task 5: `Form`, `Cookies`, `Bytes` extractors

**Files:** Create `src/extract/form.zig`, `src/extract/cookie.zig`, `src/extract/bytes.zig`; Modify `src/root.zig`

- [ ] **Step 1: Create `src/extract/form.zig`**

```zig
//! `Form(T)` — parse an `x-www-form-urlencoded` request body into struct `T`,
//! via the shared urlencoded binder (same semantics as Query, but from the body).
//! Consumes the body, so it must be a handler's last parameter (like Json).

const std = @import("std");
const urlencoded = @import("urlencoded.zig");

pub fn Form(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("Form(T): T must be a struct");
    return struct {
        value: T,

        pub const zax_is_extractor = true;
        pub const zax_is_body = true;

        pub fn fromContext(ctx: anytype) !@This() {
            return .{ .value = try urlencoded.bind(T, ctx.req.body, ctx.arena) };
        }
    };
}

const testing = std.testing;
const Request = @import("../http/request.zig").Request;

fn ctxWithBody(arena: std.mem.Allocator, body: []const u8) struct { req: *const Request, arena: std.mem.Allocator } {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{
        .method = .POST,
        .target = "",
        .path = "",
        .query = "",
        .version_minor = 1,
        .headers = &.{},
        .body = body,
    };
    return .{ .req = &S.req, .arena = arena };
}

test "Form binds a urlencoded body with decoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const F = Form(struct { name: []const u8, tags: []const u8 });
    const r = try F.fromContext(ctxWithBody(arena.allocator(), "name=ada&tags=x%2Cy"));
    try testing.expectEqualStrings("ada", r.value.name);
    try testing.expectEqualStrings("x,y", r.value.tags);
}

test "Form missing field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const F = Form(struct { name: []const u8 });
    try testing.expectError(error.MissingField, F.fromContext(ctxWithBody(arena.allocator(), "x=1")));
}
```

- [ ] **Step 2: Create `src/extract/cookie.zig`**

```zig
//! `Cookies` — access request cookies by name. Parses the `Cookie` header lazily
//! via `get`. Cookie values are returned raw (opaque; not percent-decoded).

const std = @import("std");

pub const Cookies = struct {
    /// Raw `Cookie` header value (or "" when absent).
    header: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .header = ctx.req.header("cookie") orelse "" };
    }

    /// Return the first cookie value matching `name`, or null.
    pub fn get(self: Cookies, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.header, ';');
        while (it.next()) |pair| {
            const p = std.mem.trim(u8, pair, " \t");
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
        }
        return null;
    }
};

const testing = std.testing;
const Request = @import("../http/request.zig").Request;
const Header = @import("../http/request.zig").Header;

fn ctxWithCookie(value: []const u8) struct { req: *const Request } {
    const S = struct {
        var req: Request = undefined;
        var headers: [1]Header = undefined;
    };
    S.headers = .{.{ .name = "Cookie", .value = value }};
    S.req = .{
        .method = .GET,
        .target = "",
        .path = "",
        .query = "",
        .version_minor = 1,
        .headers = &S.headers,
        .body = "",
    };
    return .{ .req = &S.req };
}

test "Cookies.get finds values and trims OWS" {
    const c = try Cookies.fromContext(ctxWithCookie("sid=abc; theme=dark"));
    try testing.expectEqualStrings("abc", c.get("sid").?);
    try testing.expectEqualStrings("dark", c.get("theme").?);
    try testing.expectEqual(@as(?[]const u8, null), c.get("missing"));
}

test "Cookies with no header yields no cookies" {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{ .method = .GET, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "" };
    const c = try Cookies.fromContext(.{ .req = &S.req });
    try testing.expectEqual(@as(?[]const u8, null), c.get("sid"));
}
```

- [ ] **Step 3: Create `src/extract/bytes.zig`**

```zig
//! `Bytes` — the raw request body as a borrowed `[]const u8`. A body extractor,
//! so it must be a handler's last parameter (and cannot coexist with Json/Form).

const std = @import("std");

pub const Bytes = struct {
    value: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = true;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .value = ctx.req.body };
    }
};

const testing = std.testing;
const Request = @import("../http/request.zig").Request;

test "Bytes returns the raw body" {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{ .method = .POST, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "raw\x00bytes" };
    const b = try Bytes.fromContext(.{ .req = &S.req });
    try testing.expectEqualStrings("raw\x00bytes", b.value);
}
```

- [ ] **Step 4: Export from `src/root.zig`** — add after the `Alloc`/`Forwarded` extractor exports:

```zig
pub const Form = @import("extract/form.zig").Form;
pub const Cookies = @import("extract/cookie.zig").Cookies;
pub const Bytes = @import("extract/bytes.zig").Bytes;
```

- [ ] **Step 5: Run to verify**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass (Form 2, Cookies 2, Bytes 1 new tests).

- [ ] **Step 6: Commit**

```bash
git add src/extract/form.zig src/extract/cookie.zig src/extract/bytes.zig src/root.zig
git commit -m "feat(extract): add Form, Cookies, and Bytes extractors"
```

---

## Task 6: Server integration test

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the integration test** — add to the test section of `src/server.zig` (uses existing helpers `TestApp`, `Db`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`). Import the extractors at the top of the test section if not present:

Add near the other test-only imports (e.g. after `const Forwarded = @import("extract/forwarded.zig").Forwarded;`):

```zig
const Form = @import("extract/form.zig").Form;
const Cookies = @import("extract/cookie.zig").Cookies;
```

Add the handler and test:

```zig
fn formCookieHandler(c: Cookies, a: @import("extract/alloc.zig").Alloc, body: Form(struct { name: []const u8 })) !Response {
    const sid = c.get("sid") orelse "none";
    const out = try std.fmt.allocPrint(a.value, "{s}|{s}", .{ body.value.name, sid });
    return Response.text(out);
}

test "input parity: Form + Cookies over a real connection" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    try app.post("/submit", formCookieHandler);

    const port: u16 = 18120;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // urlencoded body "name=ada+lovelace"; cookie sid=xyz.
    const raw = "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: sid=xyz\r\nContent-Length: 17\r\n\r\nname=ada+lovelace";
    const r = doRequest(io, port, raw, &rb);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.endsWith(u8, r, "ada lovelace|xyz"));

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

(`Content-Length: 17` is the byte length of `name=ada+lovelace`.)

- [ ] **Step 2: Run to verify**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass. Run 3×: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done` → three ok lines.

- [ ] **Step 3: Commit**

```bash
git add src/server.zig
git commit -m "test(server): Form + Cookies integration over a real connection"
```

---

## Task 7: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: Update the README extractor table** — in `README.md`, in the `## Extractors` table, add three rows (after the `Forwarded` row):

```markdown
| `Form(T)` | urlencoded request body → struct fields (must be last) |
| `Cookies` | request cookies via `.get(name)` |
| `Bytes` | the raw request body (`[]const u8`, must be last) |
```

Also adjust the existing `Path`/`Query` descriptions to mention decoding — change the `Path(T)` row to `path params (`/users/:id`) → struct fields or a scalar (percent-decoded)` and the `Query(T)` row to `query string → struct fields (`?T` = optional, percent-decoded)`.

- [ ] **Step 2: Update getting-started** — in `docs/getting-started.md`, in the extractor table under "### Extractors", add:

```markdown
| `Form(T)` | urlencoded body → struct (must be last) |
| `Cookies` | request cookies via `.get(name)` |
| `Bytes` | raw request body |
```

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document Form/Cookies/Bytes extractors and percent-decoding"
```

---

## Final verification

- [ ] Full suite 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines.

- [ ] Live smoke (optional): `zig build run`; `curl localhost:8080/users/John%20Doe`-equivalent should show the decoded value (demo `getUser` uses `Path(struct{id:u64})` so use a numeric id; the decoding is covered by the automated Path test).

---

## Self-review notes (already applied)

- **Spec coverage:** url.decode (Task 1); urlencoded.bind (Task 2); Query refactor + MissingField classify (Task 3); Path decoding (Task 4); Form/Cookies/Bytes (Task 5); integration (Task 6); docs (Task 7). All spec components covered.
- **Type consistency:** `url.decode(arena, raw, plus_as_space) ![]const u8`; `urlencoded.bind(T, source, arena) !T` returning `error.MissingField`; extractors expose `value`/`fromContext` with markers; `Cookies` uses a `header` field + `get`. `error.MissingField`→400 in classify matches `bind`. `fromContext` signatures change to inferred `!@This()` where decode adds `OutOfMemory`.
- **No placeholders:** complete code in every step; exact current code shown for each replacement.
- **Test-helper arena:** Query/Path/Form test contexts updated to provide `arena` (required by decode); Cookies/Bytes need no arena.
- **Body-extractor rule:** `Form`/`Bytes` are `zax_is_body = true`; the existing comptime body-last check governs them. The integration handler places `Form` last with `Cookies` (non-body) + `Alloc` before it.
```
