# Zax — request input parity (C-a) design

Date: 2026-06-15
Status: approved, ready for implementation planning
Scope: sub-project C-a of theme C (extractor/response parity). Covers
percent-decoding (fixing a shipped bug) and the request-input extractors
`Form`, `Cookies`, `Bytes`. Response helpers (C-b) and streaming (C-c) are
separate sub-projects, out of scope here.

## Context

Two parity gaps on the request-input side:

1. **Percent-decoding bug (shipped).** `Query.find` returns the raw
   `pair[eq+1..]` and `Path` uses the raw `param.value`; neither decodes `%XX`
   or `+`. So `/greet/John%20Doe` yields `"John%20Doe"`, and `?q=a%26b` /
   `?q=a+b` are wrong. This affects the already-released `Path`/`Query`
   extractors.
2. **Missing request extractors.** Axum has `Form`, cookie access, and raw-body
   extraction; Zax has none. Handlers can reach `ctx.req.body`/`req.header`
   internally, but there is no ergonomic extractor.

Goal: a correct percent-decoder applied to `Path`/`Query`, plus `Form(T)`,
`Cookies`, and `Bytes` extractors, all following the existing
`fromContext`/`value` extractor pattern.

## Decisions (from brainstorming)

- **Decode strategy:** zero-copy fast-path — return the raw slice unchanged when
  it contains no `%` (and no `+` in plus-mode); otherwise decode into the
  per-request arena (decoded length ≤ input). Malformed `%` is treated literally
  (lenient, no error). `+`→space applies to query/form only, never to paths.
- **Cookie shape:** a `Cookies` accessor with `.get(name) ?[]const u8` (not a
  typed `Cookie(T)`). Cookie values are returned raw (opaque, not decoded).
- **DRY:** a shared `urlencoded.bind` powers both `Query` (from the query string)
  and `Form` (from the body); `Query` is refactored onto it.

## Architecture

```
url.decode(arena, raw, plus_as_space) ──┐
                                         ├─ Path  (plus_as_space = false)
        urlencoded.bind(T, src, arena) ──┼─ Query (src = query string, plus = true)
                                         └─ Form  (src = body, plus = true)

Cookies.get(name)  ← parse Cookie header (raw values)
Bytes.value        ← ctx.req.body
```

### Component 1 — `src/url.zig` (new)

```zig
/// Percent-decode `raw`. Fast path: if `raw` has no '%' (and no '+' when
/// plus_as_space), return it unchanged (zero-copy). Otherwise decode '%XX' and,
/// when plus_as_space, '+'→' ', into an arena buffer. Malformed '%' sequences
/// are copied literally.
pub fn decode(arena: std.mem.Allocator, raw: []const u8, plus_as_space: bool) std.mem.Allocator.Error![]const u8;
```

Decoder: allocate `out` of `raw.len` (upper bound); walk input — `%` + two hex
digits → byte; `+` → space (plus mode); otherwise copy byte; a `%` not followed
by two hex digits is copied literally. Return `out[0..j]`. Hex parse via
`std.fmt.charToDigit(c, 16)`.

### Component 2 — `src/extract/urlencoded.zig` (new)

```zig
pub const Error = error{ MissingField, InvalidScalar, InvalidEnum };

/// Bind a `k=v&k=v` source string to struct `T`. Each field is found by name,
/// its value percent-decoded (plus_as_space = true), then scalar-parsed.
/// Optional fields (`?T`) default to null when absent; required fields error.
pub fn bind(comptime T: type, source: []const u8, arena: std.mem.Allocator) Error!T;
```

Reuses `scalar.parse` (existing). `find(source, name)` splits on `&`, matches the
key before `=`. The decode call uses the arena. `MissingField` is the shared
"required field absent" error for both Query and Form (see error mapping).

### Component 3 — extractors

- **`src/extract/query.zig` (refactor):** `Query(T).fromContext` becomes
  `return .{ .value = try urlencoded.bind(T, ctx.req.query, ctx.arena) }`. The
  existing struct-only compile check stays. Behavior change: values are now
  percent-decoded. Existing Query tests stay green (clean values fast-path to
  identical output).
- **`src/extract/form.zig` (new):** `Form(T)` mirrors `Query` but binds the body:
  `urlencoded.bind(T, ctx.req.body, ctx.arena)`. Markers: `zax_is_extractor =
  true`, `zax_is_body = true` (consumes the body → must be the handler's last
  parameter, like `Json`).
- **`src/extract/cookie.zig` (new):** `Cookies` — `value` holds the raw `Cookie`
  header (or `""`); `value.get(name) ?[]const u8` scans `name=value` pairs split
  on `;` (OWS-trimmed), returning the first match's raw value. Markers:
  `zax_is_extractor = true`, `zax_is_body = false`.
- **`src/extract/bytes.zig` (new):** `Bytes` — `value: []const u8 = ctx.req.body`.
  Markers: extractor, `zax_is_body = true` (it represents the body; only one body
  extractor per handler).

### Component 4 — `Path` decoding (`src/extract/path.zig`)

In `fromContext`, decode each captured value before `scalar.parse`, with
`plus_as_space = false`:
`const decoded = try url.decode(ctx.arena, raw, false); @field(v, f.name) = try
scalar.parse(f.type, decoded);` (and the same for the scalar shortcut). `Path`
already receives `ctx.arena`.

### Component 5 — error mapping (`src/error.zig`)

Add to `classify`: `error.MissingField` → 400 ("missing form field"). (The
existing `MissingQueryParam` stays for back-compat but `Query` now routes through
`urlencoded.bind`, which uses `MissingField`; update the Query missing-field test
accordingly.)

### Component 6 — exports + docs

`src/root.zig`: `pub const Form = @import("extract/form.zig").Form;`,
`pub const Cookies = @import("extract/cookie.zig").Cookies;`,
`pub const Bytes = @import("extract/bytes.zig").Bytes;`. README extractor table +
`docs/getting-started.md` note.

## Data flow

- `GET /greet/John%20Doe` → `Path(struct{ name })`: raw `"John%20Doe"` →
  `url.decode(arena, .., false)` → `"John Doe"` → `scalar.parse([]const u8)` →
  field. (Has `%` → arena copy.)
- `?q=a+b&n=%32` → `Query`: `urlencoded.bind` finds `q`→decode(plus)→`"a b"`,
  `n`→`"2"`.
- `POST` body `name=ada&tags=x%2Cy` with `Form(struct{ name, tags })` →
  `name="ada"`, `tags="x,y"`.
- `Cookie: sid=abc; theme=dark` → `Cookies.get("sid")` = `"abc"`.
- `Bytes.value` = the raw request body bytes.

## Testing

**Unit:**
- `url.decode`: `%20`→space; `+`→space (plus mode) and literal `+` (path mode);
  mixed `a%2Bb`→`a+b`; clean input fast-path returns the SAME pointer (`.ptr` ==
  input `.ptr`); malformed `%2`/`%zz` copied literally.
- `urlencoded.bind`: required + optional fields, decoding applied, missing
  required → `MissingField`.
- `Path`: a `%20` param decodes to a space (struct and scalar forms).
- `Query`: `q=a+b`→"a b", `%26`→"&"; existing required/optional behavior intact.
- `Form`: body→struct, decoding applied, missing field → error.
- `Cookies`: `get` hit/miss, OWS trimming, multiple cookies.
- `Bytes`: returns `ctx.req.body` verbatim.
- `classify(error.MissingField)` → 400.

**Socket integration (`server.zig`):** a `POST` route with
`fn(Cookies, Bytes-or-Form)` returning a value derived from the form/cookie,
asserting the decoded result over a real connection. (Form is last; pair it with
`Cookies` which is non-body.)

## Files

- New: `src/url.zig`, `src/extract/urlencoded.zig`, `src/extract/form.zig`,
  `src/extract/cookie.zig`, `src/extract/bytes.zig` (+ their tests).
- Modify: `src/extract/path.zig` (decode), `src/extract/query.zig` (refactor onto
  `urlencoded.bind`), `src/error.zig` (`MissingField`→400), `src/root.zig`
  (exports), `src/server.zig` (integration test), README + getting-started.

## Risks & edge cases

- **Query refactor regression.** Routing `Query` through `urlencoded.bind` must
  preserve existing behavior (required/optional/scalar parsing). Mitigated by the
  existing Query tests staying green and the new decoding tests.
- **Decode buffer bound.** Decoded length ≤ input length always (each `%XX`
  collapses 3→1, `+`→1), so `arena.alloc(raw.len)` never overflows.
- **`Bytes` + `Json`/`Form` conflict.** All are body extractors (`zax_is_body =
  true`); the existing comptime body-last check already forbids two in one
  handler — `Bytes` simply participates in that rule.
- **Cookie values not decoded** — intentional (opaque); documented.

## Out of scope

Typed `Cookie(T)`, multipart/form-data, a `Headers` extractor (`req.header()`
exists), response helpers (C-b), and streaming/SSE/file responses (C-c).
