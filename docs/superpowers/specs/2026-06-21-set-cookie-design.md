# Design — `SetCookie` response helper (writing cookies)

**Status:** approved 2026-06-21. Branch `v0.10.0` (off main `8baa3b3`).

## Problem

zax can *read* request cookies (`Cookies` extractor, `src/extract/cookie.zig`)
but cannot *set* them — there is no `Set-Cookie` response helper. Handlers that
need to establish a session, set a preference, or log a user out have no
first-class way to emit a `Set-Cookie` header. Half the cookie story is missing.

## Goal

A `SetCookie` builder that serializes to a `Set-Cookie` header value, plus two
`Response` methods (`withCookie`, `expireCookie`) that append it — building on the
existing arena-backed extra-headers mechanism (`Response.withHeader`,
`src/http/response.zig:351`). Round-trips with the `Cookies` read extractor.

Non-goals (YAGNI): an `Expires` (HTTP-date) attribute (Max-Age is the modern
equivalent); automatic value percent-encoding (the read side returns raw, so
encoding would break symmetry); cookie signing/encryption; auto-enforcing the
`SameSite=None ⇒ Secure` rule (documented, not enforced — keeps the serializer
pure).

### Decisions (confirmed with Chris)
- **Common attribute set:** `Max-Age`, `Domain`, `Path`, `Secure`, `HttpOnly`,
  `SameSite` (Strict/Lax/None). No `Expires`.
- **Delete helper:** `Response.expireCookie(arena, name, path)` (Max-Age=0).
- **Raw, validated value:** emit the value as-is (symmetric with the `Cookies`
  read extractor) but reject invalid cookie octets / names at build time.
- **Document, don't enforce** `SameSite=None ⇒ Secure`.
- Version bump to **0.10.0**.

## Components

### Added: `src/http/set_cookie.zig`

```zig
//! `SetCookie` — build a `Set-Cookie` response header value (RFC 6265). The
//! cookie value is emitted raw (symmetric with the `Cookies` read extractor,
//! which does not percent-decode); `serialize` validates the name and value and
//! rejects invalid octets. Note: browsers require `Secure` when `SameSite=None`
//! — set `.secure = true` in that case (not auto-enforced here).

const std = @import("std");

pub const SameSite = enum { strict, lax, none }; // → "Strict" / "Lax" / "None"

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
    /// `arena`. Validates name (RFC 6265 token) and value (cookie-octet).
    pub fn serialize(self: SetCookie, arena: std.mem.Allocator) Error![]const u8 { ... }
};
```

**Validation:**
- `name`: non-empty RFC 6265 *token* — no controls (< 0x20 or 0x7f), no
  separators or whitespace (`()<>@,;:\"/[]?={} \t`). Else `InvalidCookieName`.
- `value`: RFC 6265 *cookie-octet* — no controls, space, `"`, `,`, `;`, `\`.
  (Surrounding DQUOTE is allowed by the grammar but we keep it simple and reject
  embedded quotes.) Empty value is allowed (used by `expireCookie`). Else
  `InvalidCookieValue`.
- `domain`/`path`: emitted as-is (caller-controlled; not user input). No
  validation in v1 (documented).

**Serialization (deterministic attribute order):**
```
name=value
[; Max-Age=<n>]
[; Domain=<d>]
[; Path=<p>]
[; Secure]
[; HttpOnly]
[; SameSite=Strict|Lax|None]
```
Build via an arena-backed writer (e.g. `std.Io.Writer.Allocating` /
`ArrayListUnmanaged(u8)` — match the idiom already used in the codebase, e.g.
`src/extract/multipart.zig` / check `docs/zig016-api-notes.md`). The only
allocation is the result string.

### Modified: `src/http/response.zig`

```zig
/// Append a `Set-Cookie` header for `cookie` (serialized into `arena`).
/// Multiple calls emit multiple `set-cookie` lines (order preserved).
pub fn withCookie(self: Response, arena: std.mem.Allocator, cookie: SetCookie) SetCookie.Error!Response {
    const v = try cookie.serialize(arena);
    return self.withHeader(arena, "set-cookie", v); // withHeader → OutOfMemory only
}

/// Append a `Set-Cookie` that clears `name` (empty value, Max-Age=0). `path`
/// should match the path the cookie was set with (null omits Path).
pub fn expireCookie(self: Response, arena: std.mem.Allocator, name: []const u8, path: ?[]const u8) SetCookie.Error!Response {
    return self.withCookie(arena, .{ .name = name, .value = "", .max_age = 0, .path = path });
}
```
- Header name emitted lowercase `set-cookie`, matching the framework's lowercase
  header output (`content-type`, `connection`, etc.). Browsers treat header
  names case-insensitively.
- `withHeader` already serializes the headers list in order in
  `writeHeadersFramed` (`response.zig:369`) and allows duplicate names, so N
  cookies → N `set-cookie:` lines with no further change.
- `SetCookie` is imported into `response.zig` (e.g. `const SetCookie =
  @import("set_cookie.zig").SetCookie;`).

### Modified: `src/root.zig`

```zig
pub const SetCookie = @import("http/set_cookie.zig").SetCookie;
pub const SameSite = @import("http/set_cookie.zig").SameSite;
```

### No `src/error.zig` change

`InvalidCookieName`/`InvalidCookieValue` are programmer errors (bad handler
input), not request-classified. If a handler `return`s one it maps to the
classify default (→ 500), same as other un-mapped errors. (Not added to the
request-facing error set — these are not client-driven.)

## Data flow

```
handler builds SetCookie{ name, value, attrs }
  → Response.withCookie(arena, c): c.serialize(arena) → "set-cookie" header appended (arena)
  → writeHeadersFramed emits each set-cookie line in order
  → browser stores; later requests carry Cookie: → Cookies extractor reads it back (raw)
```

## Error handling

- Invalid name/value → `error.InvalidCookieName` / `error.InvalidCookieValue`
  (handler decides; → 500 if propagated).
- Arena `OutOfMemory` → propagates.
- No runtime failure for valid input.

## Behavior change & test impact

Purely additive: one new file, two new `Response` methods, two root re-exports.
No existing behavior changes; existing response/extractor tests unaffected.

## Testing

Unit (`src/http/set_cookie.zig`):
1. Full-attribute cookie serializes to the exact expected string (all attrs,
   correct order/spacing).
2. Minimal cookie (`name=value` only) — no trailing `;`.
3. Each `SameSite` variant renders `Strict`/`Lax`/`None`.
4. `Max-Age=0` renders (the delete case).
5. Invalid name (space / `;` / control) → `InvalidCookieName`.
6. Invalid value (`;` / control / space) → `InvalidCookieValue`.
7. Empty value allowed (serializes `name=`).

Response-level (`src/http/response.zig`, reuse the `serialize`/golden-bytes test
helper):
8. `withCookie` appends a `set-cookie:` line with the serialized value, ordered
   before `connection:`.
9. Two `withCookie` calls → two `set-cookie:` lines in order.
10. `expireCookie` emits `name=; Max-Age=0` (+ Path when given).

e2e (`src/server.zig`, loopback; mirror the Forwarded/Headers e2e + `doRequest`):
11. A handler returning `withCookie(...)` → response contains the expected
    `set-cookie:` header.

## Verification

- `zig build test --summary all` — baseline green + new unit/response/e2e tests,
  0 failures (mac kqueue + Linux epoll). No timing-sensitive paths → single run.
- Manual: `zig build run`, JS-fetch smoke (curl hooked) — hit a `withCookie`
  route, confirm the `Set-Cookie` header in the response.

## Docs

- `README.md`: document `SetCookie` + `Response.withCookie`/`expireCookie`
  (attributes, raw-validated value, the `SameSite=None ⇒ Secure` note) near the
  `Cookies` read docs.
- `docs/getting-started.md`: add if it covers responses/cookies.
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added`.
