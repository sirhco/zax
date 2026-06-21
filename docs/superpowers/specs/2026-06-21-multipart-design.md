# Design — `Multipart` extractor (multipart/form-data file uploads)

**Status:** approved 2026-06-21. Branch `feat/multipart` (off main `53ea7ac`).

## Problem

zax has no `multipart/form-data` support — the only body extractors are `Form` (urlencoded),
`Json`, and `Bytes`. File uploads (the dominant multipart use) are unhandled; a handler
receiving a multipart POST has no way to read the parts. This is the top feature-rich gap.

## Goal

A `Multipart` body extractor that parses a buffered `multipart/form-data` request body into a
zero-copy list of parts (name, optional filename, optional content-type, data slice), with
lookup helpers, following the existing extractor contract.

Non-goals: a typed `Multipart(T)` struct-binding sugar (later); streaming uploads (the body is
fully buffered, bounded by `max_body_size` — large uploads need the separate inbound-streaming
gap); per-part size limits; nested multipart/mixed.

### Decisions (confirmed with Chris)
- **Untyped parts collection** (not typed `Multipart(T)`) — flexible for dynamic/multiple
  files + unknown field names; simple comptime; zero-copy.
- **Const part-count cap** `MAX_PARTS = 1024` → `error.TooManyParts` (413) — DoS guard on top
  of `max_body_size`.

## Extractor contract (from existing extractors)

A body extractor is `struct { …, pub const zax_is_extractor = true; pub const zax_is_body =
true; pub fn fromContext(ctx: anytype) ErrorSet!@This() }`. `ctx` exposes `.req: *const
Request` and `.arena: std.mem.Allocator`. Errors flow through `error.zig classify`. Extractors
are re-exported from `src/root.zig` (`pub const Bytes = @import("extract/bytes.zig").Bytes;`).
`Request.body: []const u8` is the fully-buffered body; `Request.header("content-type")` reads
the header. No content-type parameter parser exists yet — `Multipart` owns boundary extraction.

## Components

### Added: `src/extract/multipart.zig`

```zig
/// One multipart/form-data part. All slices borrow `req.body` (zero-copy, valid
/// for the request lifetime).
pub const Part = struct {
    name: []const u8,            // Content-Disposition `name`
    filename: ?[]const u8 = null, // Content-Disposition `filename` (file parts)
    content_type: ?[]const u8 = null, // part `Content-Type` header, if present
    data: []const u8,            // the part body bytes
};

/// `Multipart` — parses a buffered `multipart/form-data` body into `parts`.
/// Body extractor: must be a handler's last parameter (like Json/Form/Bytes).
pub const Multipart = struct {
    parts: []const Part,

    pub const zax_is_extractor = true;
    pub const zax_is_body = true;
    pub const max_parts = 1024;

    pub fn fromContext(ctx: anytype) Error!Multipart { ... }

    /// First text part (no filename) named `name` → its data; null if absent.
    pub fn field(self: Multipart, name: []const u8) ?[]const u8 { ... }
    /// First part named `name` that has a filename → the Part; null if absent.
    pub fn file(self: Multipart, name: []const u8) ?Part { ... }
    /// First part named `name` (text or file); null if absent.
    pub fn part(self: Multipart, name: []const u8) ?Part { ... }

    pub const Error = error{ InvalidMultipart, TooManyParts, OutOfMemory };
};
```

**`fromContext` algorithm:**
1. `ct = ctx.req.header("content-type") orelse return error.InvalidMultipart`.
2. Extract the boundary: find `boundary=` (case-insensitive on the parameter name) in `ct`,
   take the value to the next `;`/end, strip surrounding `"` quotes. Require `ct` to start
   (case-insensitively) with `multipart/form-data`. Empty/missing boundary → `error.InvalidMultipart`.
3. Parse `ctx.req.body` with the boundary into parts (see parser below), into an arena-backed
   `std.ArrayList(Part)` (the only allocation). Append cap: at `max_parts` → `error.TooManyParts`.
4. Return `.{ .parts = list.items }`.

**Parser (zero-copy over `body`):**
- The delimiter is `--<boundary>`. Locate the first `--<boundary>` (a preamble before it is
  skipped). For each subsequent segment:
  - After the delimiter, expect `\r\n` (the closing delimiter is `--<boundary>--` → end of
    parsing). Bytes between this delimiter's trailing `\r\n` and the next `\r\n--<boundary>`
    are one part.
  - Within a part: header block = bytes up to `\r\n\r\n`; data = the rest (the trailing
    `\r\n` immediately before the next delimiter is NOT part of the data — strip it).
  - Parse the header block lines: `Content-Disposition: form-data; name="x"[; filename="y"]`
    → `name` (required; missing → `error.InvalidMultipart`), `filename` (optional). A
    `Content-Type:` line → `content_type`. Header values are slices into `body` (zero-copy);
    strip the surrounding quotes on `name`/`filename`.
- Any structural malformation (no leading delimiter, missing `\r\n\r\n`, missing terminator,
  missing `name`) → `error.InvalidMultipart`.

A small internal helper parses the `Content-Disposition` parameters (`name=`, `filename=`),
quote-aware. Keep parsing defensive (bounds-checked slicing) — this is untrusted input (a fuzz
target follow-up is reasonable).

### Modified: `src/error.zig`

Add to the canonical `Error` set + `classify`:
```zig
    error.InvalidMultipart => .{ .status = .bad_request, .reason = "invalid multipart body" },
    error.TooManyParts => .{ .status = .payload_too_large, .reason = "too many multipart parts" },
```
(Add `InvalidMultipart`, `TooManyParts` to the `Error` set too if handlers should be able to
`return` them; at minimum the classify arms so the extractor errors map correctly.)

### Modified: `src/root.zig`

```zig
pub const Multipart = @import("extract/multipart.zig").Multipart;
pub const MultipartPart = @import("extract/multipart.zig").Part;
```

## Data flow

```
POST multipart/form-data → req.body buffered (≤ max_body_size)
  → Multipart.fromContext: boundary from content-type → parse body → []Part (arena array;
    name/filename/content_type/data all zero-copy slices into req.body)
  → handler: mp.field("desc"), mp.file("upload") → Part{ filename, content_type, data }
```

## Error handling

- Not multipart / no boundary / malformed structure / missing part name → `error.InvalidMultipart` → **400**.
- > `max_parts` parts → `error.TooManyParts` → **413**.
- Oversize body is already rejected upstream (`max_body_size` → 413) before the extractor runs.
- Arena `OutOfMemory` → propagates (→ 500 via classify default).

## Behavior change & test impact

- Purely additive: a new extractor + two error variants + two root re-exports. No existing
  behavior changes; existing extractors/tests unaffected.

## Testing

Unit (`src/extract/multipart.zig`, ctx-literal pattern like `bytes.zig`/`form.zig`):
1. Two-part body (text field `desc` + file `upload` with filename + Content-Type) parses →
   2 parts; `field("desc")` returns the text; `file("upload")` returns the Part with the
   right filename/content_type/data (exact bytes, zero-copy correct).
2. Quoted boundary in content-type (`boundary="----X"`) handled.
3. Missing/`!multipart` content-type → `error.InvalidMultipart`.
4. Malformed (no terminator / missing `\r\n\r\n` / missing `name`) → `error.InvalidMultipart`.
5. > `max_parts` → `error.TooManyParts`.
6. `field()` returns null for a file part; `file()` returns null for a text part; `part()`
   finds either.
7. Binary data with embedded `\r\n`/NUL preserved exactly (data slice correct).

e2e (`src/server.zig`, loopback; mirror the "Form + Cookies over a real connection" test):
a real `multipart/form-data` POST to a handler that echoes `file("f").filename` + a field →
200 with expected content.

## Verification

- `zig build test --summary all` — current baseline green; after this feature, baseline + new
  multipart unit + e2e tests, 0 failures (mac kqueue + Linux epoll).
- Manual: `curl -F "desc=hi" -F "[email protected]" URL` → handler reads the field + file.

## Docs

- `README.md` (extractors section) + `docs/getting-started.md`: document `Multipart`
  (`mp.field`/`mp.file`/`mp.parts`, zero-copy, bounded by `max_body_size` + `max_parts`).
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added`.
