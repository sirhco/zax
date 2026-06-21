# SetCookie response helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `SetCookie` builder + `Response.withCookie`/`expireCookie` so handlers can emit `Set-Cookie` headers (round-trips with the `Cookies` read extractor).

**Architecture:** A new `src/http/set_cookie.zig` defines `SetCookie` (+ `SameSite`) with a `serialize(arena)` that validates name/value and renders the header value. `src/http/response.zig` gains `withCookie`/`expireCookie` that append a `set-cookie` header via the existing arena-backed `withHeader` mechanism. Wired via two `root.zig` re-exports.

**Tech Stack:** Zig 0.16.

## Global Constraints

- Zig 0.16. Additive: new file + 2 `Response` methods + 2 root re-exports; no existing behavior change. No `error.zig` change (cookie errors are programmer errors → classify default 500).
- Common attribute set only: `Max-Age`, `Domain`, `Path`, `Secure`, `HttpOnly`, `SameSite` (Strict/Lax/None). NO `Expires`. NO percent-encoding. NO signing.
- Raw, validated value: emit value as-is (symmetric with `Cookies` read extractor); reject invalid name/value at build time. Empty value allowed (delete case).
- `SameSite=None ⇒ Secure` is DOCUMENTED, not auto-enforced (serializer stays pure).
- Deterministic attribute order: `name=value; Max-Age=<n>; Domain=<d>; Path=<p>; Secure; HttpOnly; SameSite=<V>` — each attr only when set.
- Header name emitted lowercase `set-cookie` (matches framework's lowercase header output). Duplicate header names already supported → N cookies → N lines.
- Test baseline: current `v0.10.0` branch green (`zig build test --summary all`, 0 failures). `timeout` not on this mac — run zig directly. No timing-sensitive paths → single run.

---

### Task 1: SetCookie builder + serializer + unit tests

**Files:**
- Create: `src/http/set_cookie.zig`
- Modify: `src/root.zig` (two re-exports)

**Interfaces:**
- Produces: `pub const SameSite = enum { strict, lax, none };` and `pub const SetCookie = struct { name, value, max_age: ?i64, domain: ?[]const u8, path: ?[]const u8, secure: bool, http_only: bool, same_site: ?SameSite, pub const Error = error{ InvalidCookieName, InvalidCookieValue, OutOfMemory }; pub fn serialize(self, arena) Error![]const u8 }`.

- [ ] **Step 1: Write the module + failing tests (TDD).**

Create `src/http/set_cookie.zig`:

```zig
//! `SetCookie` — build a `Set-Cookie` response header value (RFC 6265). The
//! cookie value is emitted raw (symmetric with the `Cookies` read extractor,
//! which does not percent-decode); `serialize` validates the name and value.
//! Note: browsers require `Secure` when `SameSite=None` — set `.secure = true`
//! in that case (not auto-enforced here).

const std = @import("std");

pub const SameSite = enum { strict, lax, none };

pub const SetCookie = struct {
    name: []const u8,
    value: []const u8,
    /// Max-Age in seconds. 0 expires the cookie immediately. null omits it.
    max_age: ?i64 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    pub const Error = error{ InvalidCookieName, InvalidCookieValue, OutOfMemory };

    /// Serialize to a `Set-Cookie` header VALUE (no "set-cookie:" prefix), into
    /// `arena`. Validates the name (RFC 6265 token) and value (cookie-octet).
    pub fn serialize(self: SetCookie, arena: std.mem.Allocator) Error![]const u8 {
        if (!isValidName(self.name)) return error.InvalidCookieName;
        if (!isValidValue(self.value)) return error.InvalidCookieValue;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(arena, self.name);
        try out.append(arena, '=');
        try out.appendSlice(arena, self.value);

        if (self.max_age) |ma| {
            var nbuf: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{ma}) catch unreachable;
            try out.appendSlice(arena, "; Max-Age=");
            try out.appendSlice(arena, ns);
        }
        if (self.domain) |d| {
            try out.appendSlice(arena, "; Domain=");
            try out.appendSlice(arena, d);
        }
        if (self.path) |p| {
            try out.appendSlice(arena, "; Path=");
            try out.appendSlice(arena, p);
        }
        if (self.secure) try out.appendSlice(arena, "; Secure");
        if (self.http_only) try out.appendSlice(arena, "; HttpOnly");
        if (self.same_site) |ss| {
            try out.appendSlice(arena, "; SameSite=");
            try out.appendSlice(arena, switch (ss) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            });
        }
        return out.toOwnedSlice(arena);
    }
};

/// RFC 6265 cookie-name = token (RFC 7230): VCHAR minus separators/whitespace.
fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return false,
            else => {},
        }
    }
    return true;
}

/// RFC 6265 cookie-octet: %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E —
/// i.e. no CTL, no space, no `"` `,` `;` `\`. Empty value is allowed.
fn isValidValue(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x21 or c > 0x7e) return false;
        switch (c) {
            '"', ',', ';', '\\' => return false,
            else => {},
        }
    }
    return true;
}
```

Verify the `std.ArrayListUnmanaged(u8)` `.empty` / `appendSlice(arena,…)` / `append(arena,…)` / `toOwnedSlice(arena)` idiom against the installed Zig 0.16 — cross-check `src/extract/headers.zig` (`getAll` uses the same list idiom) and `src/extract/multipart.zig`. If they differ, match the codebase idiom; the behavior (arena-allocated result string) is what matters. `std.fmt.bufPrint` for the i64 avoids any writer-API question.

- [ ] **Step 2: Unit tests** (append to `set_cookie.zig`):

```zig
const testing = std.testing;

fn ser(arena: std.mem.Allocator, c: SetCookie) ![]const u8 {
    return c.serialize(arena);
}

test "SetCookie: full attribute set serializes in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try ser(arena.allocator(), .{
        .name = "sid",
        .value = "abc",
        .max_age = 3600,
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
    try testing.expectEqualStrings(
        "sid=abc; Max-Age=3600; Domain=example.com; Path=/; Secure; HttpOnly; SameSite=Lax",
        s,
    );
}

test "SetCookie: minimal is just name=value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a=b", try ser(arena.allocator(), .{ .name = "a", .value = "b" }));
}

test "SetCookie: SameSite variants render Strict/Lax/None" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("k=v; SameSite=Strict", try ser(a, .{ .name = "k", .value = "v", .same_site = .strict }));
    try testing.expectEqualStrings("k=v; SameSite=Lax", try ser(a, .{ .name = "k", .value = "v", .same_site = .lax }));
    try testing.expectEqualStrings("k=v; SameSite=None", try ser(a, .{ .name = "k", .value = "v", .same_site = .none }));
}

test "SetCookie: Max-Age=0 (delete) and empty value allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("x=; Max-Age=0", try ser(arena.allocator(), .{ .name = "x", .value = "", .max_age = 0 }));
}

test "SetCookie: invalid name rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "", .value = "v" }));
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "a b", .value = "v" }));
    try testing.expectError(error.InvalidCookieName, ser(a, .{ .name = "a;b", .value = "v" }));
}

test "SetCookie: invalid value rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a b" }));
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a;b" }));
    try testing.expectError(error.InvalidCookieValue, ser(a, .{ .name = "k", .value = "a\"b" }));
}
```

- [ ] **Step 3: Export** in `src/root.zig` (near the other `http/` re-exports, e.g. by `Response`/`Status`):

```zig
pub const SetCookie = @import("http/set_cookie.zig").SetCookie;
pub const SameSite = @import("http/set_cookie.zig").SameSite;
```
Confirm `SetCookie`/`SameSite` are not already public symbols.

- [ ] **Step 4: Gate** — `zig build test --summary all` green (RED first to confirm tests fail without the impl, then GREEN).

- [ ] **Step 5: Commit** — `feat(http): SetCookie — build Set-Cookie header values (RFC 6265)`.

---

### Task 2: Response.withCookie / expireCookie + response-level tests

**Files:**
- Modify: `src/http/response.zig` (import `SetCookie`; add two methods + tests)

**Interfaces:**
- Consumes: `SetCookie` from Task 1.
- Produces: `pub fn withCookie(self: Response, arena, cookie: SetCookie) SetCookie.Error!Response`; `pub fn expireCookie(self: Response, arena, name: []const u8, path: ?[]const u8) SetCookie.Error!Response`.

- [ ] **Step 1: Add the import** near the top of `src/http/response.zig` (alongside `const Header = @import("request.zig").Header;`):

```zig
const SetCookie = @import("set_cookie.zig").SetCookie;
```

- [ ] **Step 2: Add the methods** to the `Response` struct, right after `withHeader` (`response.zig:351`):

```zig
    /// Append a `Set-Cookie` header for `cookie` (serialized into `arena`).
    /// Multiple calls emit multiple `set-cookie` lines (order preserved).
    pub fn withCookie(self: Response, arena: std.mem.Allocator, cookie: SetCookie) SetCookie.Error!Response {
        const v = try cookie.serialize(arena);
        return self.withHeader(arena, "set-cookie", v);
    }

    /// Append a `Set-Cookie` that clears `name` (empty value, Max-Age=0). `path`
    /// should match the path the cookie was set with (null omits Path).
    pub fn expireCookie(self: Response, arena: std.mem.Allocator, name: []const u8, path: ?[]const u8) SetCookie.Error!Response {
        return self.withCookie(arena, .{ .name = name, .value = "", .max_age = 0, .path = path });
    }
```

Note: `withHeader` returns `std.mem.Allocator.Error` (`OutOfMemory`), which is a subset of `SetCookie.Error`, so the `return` type-checks.

- [ ] **Step 3: Response-level tests** (append to the tests in `response.zig`, reuse the existing `serialize(buf, r)` golden-bytes helper at `response.zig:428`):

```zig
test "withCookie appends a set-cookie header before connection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    const r = try Response.text("hi").withCookie(arena.allocator(), .{
        .name = "sid", .value = "abc", .path = "/", .http_only = true,
    });
    const out = serialize(&buf, r);
    const sc_at = std.mem.indexOf(u8, out, "set-cookie: sid=abc; Path=/; HttpOnly\r\n").?;
    const conn_at = std.mem.indexOf(u8, out, "connection: close\r\n").?;
    try testing.expect(sc_at < conn_at);
    try testing.expect(std.mem.endsWith(u8, out, "hi"));
}

test "two withCookie calls emit two set-cookie lines in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    const r = try (try Response.text("x").withCookie(a, .{ .name = "a", .value = "1" }))
        .withCookie(a, .{ .name = "b", .value = "2" });
    const out = serialize(&buf, r);
    const a_at = std.mem.indexOf(u8, out, "set-cookie: a=1\r\n").?;
    const b_at = std.mem.indexOf(u8, out, "set-cookie: b=2\r\n").?;
    try testing.expect(a_at < b_at);
}

test "expireCookie emits empty value with Max-Age=0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    const r = try Response.text("bye").expireCookie(arena.allocator(), "sid", "/");
    const out = serialize(&buf, r);
    try testing.expect(std.mem.indexOf(u8, out, "set-cookie: sid=; Max-Age=0; Path=/\r\n") != null);
}
```

- [ ] **Step 4: Gate** — `zig build test --summary all` green.

- [ ] **Step 5: Commit** — `feat(http): Response.withCookie/expireCookie set-cookie helpers`.

---

### Task 3: e2e test in server.zig

**Files:**
- Modify: `src/server.zig` (add a test-only handler + an e2e test)

**Interfaces:**
- Consumes: `Response.withCookie` (Task 2). The handler obtains the arena the same way other test handlers do (e.g. the `Alloc` extractor, as the Headers `getAll` e2e handler does).

- [ ] **Step 1:** Mirror the Headers/Forwarded e2e (`doRequest` loopback + test-app setup). Add a handler that returns `withCookie(...)`, register it on a fresh port, send a request, assert the response contains the expected `set-cookie:` line. Match the exact test-handler + teardown conventions already in `src/server.zig` (study the Headers e2e tests added on the previous branch).

```zig
fn setCookieHandler(_: *const TestCtx, a: Alloc) anyerror!Response {
    return Response.text("ok").withCookie(a.value, .{ .name = "sid", .value = "xyz", .http_only = true });
}
```
(Adapt `TestCtx`/handler signature and `Alloc` import to whatever the surrounding e2e handlers use — do not invent a new convention.)

```zig
test "e2e: handler sets a cookie via withCookie" {
    // ... standard test-app setup on a fresh port, route -> setCookieHandler ...
    var rb: [1024]u8 = undefined;
    const r = doRequest(io, port, "GET /cookie HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "set-cookie: sid=xyz; HttpOnly\r\n") != null);
}
```

- [ ] **Step 2: Gate** — `zig build test --summary all` green.

- [ ] **Step 3: Commit** — `test(http): e2e set-cookie via withCookie over loopback`.

---

### Task 4: docs

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `CHANGELOG.md`

- [ ] **Step 1:** `README.md` — near the `Cookies` (read) docs, document `SetCookie` + `Response.withCookie`/`expireCookie`: the attribute set, raw-validated value, the `SameSite=None ⇒ Secure` note, and a tiny usage snippet. Match neighboring doc format.
- [ ] **Step 2:** `docs/getting-started.md` — add `SetCookie`/`withCookie` if it covers responses or cookies; else leave and note it.
- [ ] **Step 3:** `CHANGELOG.md` — entry under `[Unreleased]` → `### Added` (match existing entry style).
- [ ] **Step 4: Gate** — docs match the shipped API; `zig build test` still green.
- [ ] **Step 5: Commit** — `docs(set-cookie): document SetCookie + withCookie/expireCookie`.

---

## Verification (end-to-end, after all tasks)

1. `zig build test --summary all` — all green (unit + response + e2e).
2. `zig build run`, JS-fetch smoke (curl hooked): hit a `withCookie` route, confirm the `Set-Cookie` header in the response.
3. `grep -n "SetCookie\|withCookie" README.md` — appears in the response/cookie docs.
4. Version is `0.10.0` in `build.zig.zon`.
