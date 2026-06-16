# Zax — response helpers (C-b) design

Date: 2026-06-15
Status: approved, ready for implementation planning
Scope: sub-project C-b of theme C (extractor/response parity). Output-side
helpers on the existing `Response`. Streaming/SSE/file responses (C-c) are a
separate sub-project, out of scope here.

## Context

`Response` (`src/http/response.zig`) is minimal: `status`, `content_type`,
`body`, `headers` (via `withHeader`), `keep_alive`; constructors `text`,
`jsonRaw`, `fromStatus`. Parity gaps vs Axum on the output side:

- No `redirect` (status + `Location`).
- No `html` content-type helper.
- Only `jsonRaw` (pre-serialized string) — no typed `json` that serializes a
  value.

This sub-project adds those, building entirely on the existing `Response` (no new
infrastructure, no dispatcher change — `IntoResponse` already passes a `Response`
through unchanged).

## Decision (from brainstorming)

- **Redirect carries the Location via a dedicated `location: ?[]const u8` field**
  on `Response` (not via `withHeader`), so `redirect` is non-allocating and
  ergonomic: `return Response.redirect(.found, "/login");`.

## Components (all in `src/http/response.zig`)

### 1. `Response.location` field

```zig
/// When set, emitted as a `Location:` response header (used by redirects).
location: ?[]const u8 = null,
```

`write()` emits it among the headers (before the connection line), only when
non-null:

```zig
        if (self.location) |loc| try w.print("location: {s}\r\n", .{loc});
```

Existing responses (which never set `location`) are byte-for-byte unchanged.

### 2. New `Status` members

Add (with reasons): `see_other = 303` ("See Other"),
`temporary_redirect = 307` ("Temporary Redirect"),
`permanent_redirect = 308` ("Permanent Redirect"). (`moved_permanently = 301`,
`found = 302` already exist.)

### 3. New constructors

```zig
/// HTML body with a text/html content type.
pub fn html(body: []const u8) Response {
    return .{ .content_type = "text/html; charset=utf-8", .body = body };
}

/// Serialize `value` to a JSON body in `arena`. The typed counterpart to
/// `jsonRaw` (which takes a pre-serialized string).
pub fn json(arena: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!Response {
    const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
    return .{ .content_type = "application/json", .body = body };
}

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

Note: the exact `json` serialization call (`std.json.fmt(value, .{})` formatted
with `{f}`, vs `std.json.Stringify`) must be confirmed against the installed std
during implementation; the contract is "serialize `value` to a JSON string in
`arena`."

## Data flow

A handler returns one of these directly; `IntoResponse` (which already accepts a
`Response`) passes it through, and the server's existing `write()` serializes it:

```zig
fn login() zax.Response { return zax.Response.redirect(.found, "/dashboard"); }
fn page() zax.Response { return zax.Response.html("<h1>Hi</h1>"); }
fn data(a: zax.Alloc) !zax.Response { return zax.Response.json(a.value, .{ .ok = true }); }
```

## Testing

**Unit (`response.zig`, via the existing fixed-buffer `serialize` test helper):**
- `redirect(.found, "/x")` → status line `302 Found`, a `location: /x` header,
  empty body.
- `seeOther`/`temporaryRedirect`/`permanentRedirect` → 303/307/308 + Location.
- `html("<p>")` → `content-type: text/html; charset=utf-8`, body present.
- `json(arena, .{ .a = 1, .b = "x" })` → `content-type: application/json` and a
  body that parses back / matches the expected JSON.
- `write()` omits `location:` when the field is null (assert the existing `text`
  response golden bytes are unchanged — no `location` line).
- 303/307/308 `code()`/`reason()`.

**Socket integration (`server.zig`):** a route returning
`Response.redirect(.found, "/next")`; assert the response contains `302 Found`
and `location: /next` over a real connection.

## Files

- Modify: `src/http/response.zig` (`location` field, `write` line, 3 statuses,
  `html`/`json`/`redirect`/`seeOther`/`temporaryRedirect`/`permanentRedirect`,
  tests).
- Modify: `src/server.zig` (redirect integration test).
- Docs: README + `docs/getting-started.md` — a short "responses" note listing the
  helpers.

## Risks & edge cases

- **Golden-bytes regression.** The `location` line must be emitted only when set,
  so existing response serialization tests stay green. Mitigated by the
  null-omission test.
- **`json` serialization API.** `std.json` serialization shape may differ; the
  plan confirms the exact call. Errors are `Allocator.Error` only (serialization
  of a well-formed value into an arena doesn't otherwise fail).
- **Redirect status not validated** — `redirect` trusts the caller to pass a 3xx;
  passing a non-3xx still sets `location` (harmless). The convenience wrappers
  pin the common ones. No validation needed (YAGNI).

## Out of scope

Streaming/SSE/file responses (C-c), `Set-Cookie` helpers, content negotiation,
and per-status convenience constructors beyond redirects (`fromStatus` covers
them).
