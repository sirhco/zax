# Design — `Headers` extractor (arbitrary request-header access)

**Status:** approved 2026-06-21. Branch `v0.9.0` (off main `08ba7ed`).

## Problem

Handlers receive their inputs only through comptime extractors — they never get
the raw `*const Request`. `Request.header()` exists (`src/http/request.zig:51`,
case-insensitive) but is unreachable from a handler. The special-purpose header
extractors (`Forwarded`, `Cookies`) cover their niches, but there is no general
way for a handler to read an arbitrary request header (`Authorization`,
`X-Request-Id`, `Accept`, a custom `X-Whatever`). README lists "Headers
extractor" under **Not yet built**.

## Goal

A `Headers` accessor extractor that exposes the parsed request header list to
handlers with case-insensitive lookup, multi-value lookup, presence test, and
raw iteration. Zero-copy: it borrows the request's header slice; only the
multi-value `getAll` allocates (into the request arena).

Non-goals (YAGNI): typed `Headers(T)` struct-binding sugar; typed scalar parse
helpers (`getInt` etc.); response-header mutation (already `Response.withHeader`).

### Decisions (confirmed with Chris)
- **Accessor shape** (Cookies/Forwarded-style dynamic struct), not typed
  `Headers(T)` binding — header names rarely map cleanly to field identifiers.
- **Include `getAll`** for repeated headers (arena-backed slice).

## Extractor contract (from existing extractors)

A non-body extractor is `struct { …, pub const zax_is_extractor = true; pub const
zax_is_body = false; pub fn fromContext(ctx: anytype) ErrorSet!@This() }`. `ctx`
exposes `.req: *const Request` and `.arena: std.mem.Allocator`. Extractors are
re-exported from `src/root.zig`. `Request.headers: []const Header` is the parsed
header list (`Header{ name, value }`, both zero-copy slices into the read
buffer); `Request.header(name)` is the existing case-insensitive single lookup.

The closest references are `src/extract/forwarded.zig` (reads multiple headers,
empty error set, in-memory test harness) and `src/extract/cookie.zig` (holds a
borrowed slice + accessor methods).

## Components

### Added: `src/extract/headers.zig`

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
    pub fn get(self: @This(), name: []const u8) ?[]const u8 { ... }

    /// Whether any header matches `name` (case-insensitive).
    pub fn has(self: @This(), name: []const u8) bool {
        return self.get(name) != null;
    }

    /// All values matching `name` (case-insensitive), in request order.
    /// Arena-allocated; empty slice when none match.
    pub fn getAll(self: @This(), arena: std.mem.Allocator, name: []const u8) ![]const []const u8 { ... }

    /// Raw header list for iteration.
    pub fn all(self: @This()) []const Header { return self.list; }

    /// Number of headers on the request.
    pub fn count(self: @This()) usize { return self.list.len; }
};
```

- `get`/`has` replicate the `std.ascii.eqlIgnoreCase` scan (the struct holds a
  slice, not a `*Request`, so it cannot reuse `Request.header`) — the same
  one-liner as `request.zig:51`.
- `getAll` is the only fallible method (`error{OutOfMemory}`, inferred via `!`);
  allocator-first per Zig std idiom. Build into an arena-backed list, then
  `toOwnedSlice(arena)` — mirror the list idiom already used in
  `src/extract/multipart.zig` (cross-check against `docs/zig016-api-notes.md`).

### Modified: `src/root.zig`

```zig
pub const Headers = @import("extract/headers.zig").Headers;
```
(Add next to the `Multipart` export. Confirm `Headers` is not already public.)

### No `src/error.zig` change

`fromContext` cannot fail (`error{}`); `getAll`'s only error is `OutOfMemory`,
which propagates to the existing classify default (→ 500). No new error variants.

## Data flow

```
request parsed → req.headers: []Header (zero-copy into read buffer)
  → Headers.fromContext: { .list = req.headers }  (borrow, no alloc)
  → handler: h.get("authorization") / h.has("x-test") / h.getAll(arena, "accept")
             / h.all() / h.count()
```

## Error handling

- Lookups never fail; missing header → `null` (`get`) / `false` (`has`) / empty
  slice (`getAll`).
- `getAll` arena `OutOfMemory` → propagates (→ 500 via classify default).

## Behavior change & test impact

Purely additive: one new extractor + one root re-export. No existing behavior
changes; existing extractors/tests unaffected.

## Testing

Unit (`src/extract/headers.zig`, in-memory ctx harness like `forwarded.zig:57`):
1. `get` finds first match, case-insensitive (`X-Test` queried as `x-test`);
   missing → null.
2. `has` → true for present, false for absent.
3. `getAll` returns all values for a repeated header in request order; single
   match → len 1; no match → empty slice.
4. `count` / `all` reflect the raw list.
5. Empty header slice → `count == 0`, `get` → null, `has` → false, `getAll` →
   empty.

e2e (`src/server.zig`, loopback; mirror the Forwarded e2e ~`server.zig:1534`
using `doRequest`):
- Handler uses `Headers`, echoes `get("x-test")` → send `X-Test: hi`, assert body.
- Handler echoes `getAll` count for a header sent twice → assert it sees 2.

## Verification

- `zig build test --summary all` — baseline green + new Headers unit + e2e tests,
  0 failures (mac kqueue + Linux epoll). No timing-sensitive paths → single run.
- Manual: `zig build run`, JS-fetch smoke (curl hooked) — hit a `Headers` route
  with `X-Test: hi` and a duplicated header; confirm the echoed value + count 2.

## Docs

- `README.md` (extractors section): document `Headers`
  (`get`/`has`/`getAll`/`all`/`count`, zero-copy); remove "Headers extractor"
  from the **Not yet built** line.
- `docs/getting-started.md`: add `Headers` if it enumerates extractors.
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added` (if a changelog exists).
