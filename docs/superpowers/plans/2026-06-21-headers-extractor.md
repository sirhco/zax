# Headers extractor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Headers` accessor extractor giving handlers case-insensitive access to arbitrary request headers (`get`/`has`/`getAll`/`all`/`count`).

**Architecture:** A new `src/extract/headers.zig` with a `Headers` struct (extractor contract: `zax_is_extractor=true`/`zax_is_body=false`/`fromContext`). It borrows `ctx.req.headers` (zero-copy); only `getAll` allocates into `ctx.arena`. Wired via a single `root.zig` re-export. No `error.zig` change.

**Tech Stack:** Zig 0.16.

## Global Constraints

- Zig 0.16. Additive: new extractor + 1 root re-export; no existing behavior change.
- Accessor shape (NOT typed `Headers(T)`). Zero-copy: `Headers.list` borrows `req.headers`; the ONLY allocation is the `getAll` result slice (arena).
- Case-insensitive name matching via `std.ascii.eqlIgnoreCase` (RFC 9110), same as `Request.header` (`src/http/request.zig:51`).
- Extractor contract: `struct { …, pub const zax_is_extractor=true; pub const zax_is_body=false; pub fn fromContext(ctx: anytype) error{}!@This() }`; `ctx.req: *const Request`, `ctx.arena: std.mem.Allocator`.
- `fromContext` infallible (`error{}`); `getAll` only error is `OutOfMemory` (→ 500 via existing classify default). No new error variants.
- Test baseline: current `v0.9.0` branch green (`zig build test --summary all`, 0 failures). `timeout` not on this mac — run zig directly. No timing-sensitive paths → single run.

---

### Task 1: Headers extractor + unit tests

**Files:**
- Create: `src/extract/headers.zig`
- Modify: `src/root.zig` (one re-export)

**Interfaces:**
- Produces: `pub const Headers = struct { list: []const Header, … fromContext, get, has, getAll, all, count }`. Markers `zax_is_extractor=true`, `zax_is_body=false`.

- [ ] **Step 1: Write the module + failing tests (TDD).**

Create `src/extract/headers.zig`. Mirror `src/extract/forwarded.zig` (empty error set, in-memory ctx test harness `ctxWith`) and `src/extract/cookie.zig` (borrowed-slice accessor).

```zig
//! `Headers` — read arbitrary request headers from a handler. Names are matched
//! case-insensitively (RFC 9110). Values are borrowed slices into the request
//! buffer (zero-copy); only `getAll` allocates (into the arena).

const std = @import("std");
const Header = @import("../http/request.zig").Header;

pub const Headers = struct {
    /// Borrowed view of the parsed request header list (zero-copy).
    list: []const Header,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .list = ctx.req.headers };
    }

    /// First value matching `name` (case-insensitive), or null.
    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        for (self.list) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Whether any header matches `name` (case-insensitive).
    pub fn has(self: @This(), name: []const u8) bool {
        return self.get(name) != null;
    }

    /// All values matching `name` (case-insensitive), in request order.
    /// Arena-allocated; empty slice when none match.
    pub fn getAll(self: @This(), arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.list) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(arena, h.value);
        }
        return out.toOwnedSlice(arena);
    }

    /// Raw header list for iteration.
    pub fn all(self: @This()) []const Header {
        return self.list;
    }

    /// Number of headers on the request.
    pub fn count(self: @This()) usize {
        return self.list.len;
    }
};
```

Verify the `std.ArrayListUnmanaged` `.empty` / `append(arena, …)` / `toOwnedSlice(arena)` idiom against the installed Zig 0.16 — cross-check `src/extract/multipart.zig` (which already builds an arena-backed list) and `docs/zig016-api-notes.md`; match whatever idiom multipart uses.

- [ ] **Step 2: Unit tests** (in `headers.zig`, in-memory `ctxWith(headers)` harness copied from `forwarded.zig:57`):
  - `get` finds first match, case-insensitive (insert `X-Test`, query `x-test`); missing → null.
  - `has` → true present, false absent.
  - `getAll` returns all values for a repeated header in request order; single match → len 1; no match → empty slice.
  - `count` / `all` reflect the raw list.
  - Empty header slice → `count == 0`, `get` → null, `has` → false, `getAll` → empty.

- [ ] **Step 3: Export** in `src/root.zig` next to `Multipart`:
```zig
pub const Headers = @import("extract/headers.zig").Headers;
```
Confirm `Headers` is not already a public symbol.

- [ ] **Step 4: Gate** — `zig build test --summary all` green.

---

### Task 2: e2e tests in server.zig

**Files:**
- Modify: `src/server.zig` (add e2e tests; add test-only handler(s) if the harness needs them)

**Interfaces:**
- Consumes: `zax.Headers` extractor from Task 1.

- [ ] **Step 1:** Mirror the Forwarded e2e (~`server.zig:1534`) using the `doRequest` loopback helper:
  - A handler taking `Headers`, echoing `get("x-test")` in the body → send `GET … X-Test: hi` → assert body contains `hi`.
  - A handler echoing the `getAll` count for a header → send the same header twice → assert it sees `2`.

- [ ] **Step 2: Gate** — `zig build test --summary all` green.

---

### Task 3: docs

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `CHANGELOG.md` (if present)

- [ ] **Step 1:** `README.md` — add `Headers` to the extractors section (`get`/`has`/`getAll`/`all`/`count`, zero-copy, case-insensitive) with a tiny usage snippet; remove "Headers extractor" from the **Not yet built** line (`README.md:575`).
- [ ] **Step 2:** `docs/getting-started.md` — add `Headers` if it enumerates extractors.
- [ ] **Step 3:** `CHANGELOG.md` — entry under `[Unreleased]` → `### Added` (if a changelog exists).
- [ ] **Step 4: Gate** — docs match the shipped API; `zig build test` still green.

---

## Verification (end-to-end, after all tasks)

1. `zig build test --summary all` — all green (unit + e2e).
2. `zig build run`, then JS-fetch smoke (curl hooked): hit a `Headers` route, send `X-Test: hi` and a duplicated header; confirm the echoed value + `getAll` count of 2.
3. `grep -n "Headers" README.md` — appears in the extractor list, gone from "Not yet built".
4. Version is `0.9.0` in `build.zig.zon`.
