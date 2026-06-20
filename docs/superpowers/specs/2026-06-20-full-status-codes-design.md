# Design — full HTTP status code support

**Status:** approved 2026-06-20. Branch `feat/full-status-codes` (off main `06db621`).

## Problem

zax's `Status` is a **closed** `enum(u16)` with only 25 named variants
(`src/http/response.zig:11-71`); `Response.status` is that enum, `reason()` is an
exhaustive switch, and `error.zig classify` maps only to the subset. There is **no way to
send an arbitrary numeric status**, and ~50 standard IANA codes are missing (notably 402,
406, 410, 412, 414, 415, 416, 417, 421, 426, 428, 451, 502, 504, 505, 511, 1xx, 206). Users
hitting proxy/edge/uncommon codes cannot express them.

## Goal

Support the full standard HTTP status set as named variants **and** any arbitrary `u16` code,
and let handlers `return error.X` for the common additions.

Non-goals: per-response custom reason strings (we use standard phrases for named codes, empty
for unnamed — RFC-legal); 1xx interim-response protocol semantics (we only make the codes
expressible, not implement 100-continue handshakes).

### Decisions (confirmed with Chris)
- **Full named set + arbitrary codes.** Expand the named variants to the full standard IANA
  set, AND make the enum **non-exhaustive** (`enum(u16){ …, _ }`) so any `u16` is a valid
  `Status`. `reason()` returns the phrase for named codes, **empty string** for unnamed
  (RFC 7230 allows an empty reason-phrase). Add `Response.fromCode(u16)`.
- **Expand the Error set.** Add common canonical errors + `classify` mappings so handlers can
  `return error.Gone` etc.

## Key facts

- `Status` (`response.zig:11-71`): `enum(u16)` with explicit values; `code()` =
  `@intFromEnum`; `reason()` = exhaustive switch.
- `Response.status: Status` (`response.zig:117`); `Response.fromStatus(Status)`
  (`response.zig:146`); wire line `response.zig:293`:
  `w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() })`.
- **Only exhaustive switch over a `Status` value is `reason()`** — confirmed by grep. The
  switch at `conn.zig:540` switches over an *error* and produces `Status` literals (e.g.
  `.bad_request`); it is unaffected by making `Status` non-exhaustive. `response.zig:345`
  `if (T == Status)` is a comptime type check, unaffected.
- `error.zig`: canonical `Error` set (`error.zig:16-28`) + `classify` (`:32-58`) mapping to
  `Status` + reason; `else => 500`.

## Components

### Modified: `src/http/response.zig` — `Status`

Expand to the full standard IANA set and make it non-exhaustive. The complete variant list
(name = code, reason phrase):

- **1xx:** continue=100 "Continue", switching_protocols=101 "Switching Protocols".
- **2xx:** ok=200, created=201, accepted=202, non_authoritative_information=203
  "Non-Authoritative Information", no_content=204, reset_content=205 "Reset Content",
  partial_content=206 "Partial Content".
- **3xx:** multiple_choices=300 "Multiple Choices", moved_permanently=301, found=302,
  see_other=303, not_modified=304, use_proxy=305 "Use Proxy", temporary_redirect=307,
  permanent_redirect=308.
- **4xx:** bad_request=400, unauthorized=401, payment_required=402 "Payment Required",
  forbidden=403, not_found=404, method_not_allowed=405, not_acceptable=406 "Not Acceptable",
  proxy_authentication_required=407 "Proxy Authentication Required", request_timeout=408,
  conflict=409, gone=410 "Gone", length_required=411, precondition_failed=412
  "Precondition Failed", payload_too_large=413, uri_too_long=414 "URI Too Long",
  unsupported_media_type=415 "Unsupported Media Type", range_not_satisfiable=416
  "Range Not Satisfiable", expectation_failed=417 "Expectation Failed", im_a_teapot=418
  "I'm a teapot", misdirected_request=421 "Misdirected Request", unprocessable_entity=422,
  locked=423 "Locked", failed_dependency=424 "Failed Dependency", too_early=425 "Too Early",
  upgrade_required=426 "Upgrade Required", precondition_required=428 "Precondition Required",
  too_many_requests=429, request_header_fields_too_large=431,
  unavailable_for_legal_reasons=451 "Unavailable For Legal Reasons".
- **5xx:** internal_server_error=500, not_implemented=501, bad_gateway=502 "Bad Gateway",
  service_unavailable=503, gateway_timeout=504 "Gateway Timeout",
  http_version_not_supported=505 "HTTP Version Not Supported", variant_also_negotiates=506
  "Variant Also Negotiates", insufficient_storage=507 "Insufficient Storage",
  loop_detected=508 "Loop Detected", not_extended=510 "Not Extended",
  network_authentication_required=511 "Network Authentication Required".
- Trailing `_` (non-exhaustive marker).

`reason()` gains `else => ""` for unnamed/custom codes. `code()` unchanged. (Existing named
variants keep the same names so all current call sites compile unchanged.)

### Modified: `src/http/response.zig` — `Response`

Add an arbitrary-code constructor:
```zig
/// Build a bare response with an arbitrary numeric status (for codes outside the
/// named set — proxies, custom). Named codes should prefer `fromStatus`.
pub fn fromCode(code: u16) Response {
    return .{ .status = @enumFromInt(code) };
}
```
`@enumFromInt` on a non-exhaustive enum is always valid (no UB). Users may also set
`.status = @enumFromInt(x)` directly. Wire: a custom code serializes as
`HTTP/1.1 <code> \r\n` (empty reason — RFC-legal status-line with empty reason-phrase).

### Modified: `src/error.zig`

Add to the canonical `Error` set:
```zig
    Gone,
    UnsupportedMediaType,
    NotAcceptable,
    PreconditionFailed,
    BadGateway,
    GatewayTimeout,
```
Add `classify` arms:
```zig
    error.Gone => .{ .status = .gone, .reason = "gone" },
    error.UnsupportedMediaType => .{ .status = .unsupported_media_type, .reason = "unsupported media type" },
    error.NotAcceptable => .{ .status = .not_acceptable, .reason = "not acceptable" },
    error.PreconditionFailed => .{ .status = .precondition_failed, .reason = "precondition failed" },
    error.BadGateway => .{ .status = .bad_gateway, .reason = "bad gateway" },
    error.GatewayTimeout => .{ .status = .gateway_timeout, .reason = "gateway timeout" },
```
(All target statuses now exist in the expanded enum.)

## Error handling

- Custom/unnamed code → empty reason phrase on the wire (valid). `code()` returns the value.
- `@enumFromInt` on non-exhaustive `Status` cannot trip illegal-value UB (that is the reason
  for `_`).

## Behavior change & test impact

- Purely additive: all existing named variants keep their names + values, so every current
  `Response.fromStatus(.x)` / `status.code()` / `status.reason()` call compiles and behaves
  identically. Only NEW capability is added (more named codes, arbitrary codes, more errors).
- `reason()` becoming non-exhaustive requires its own `else` arm (added); no other switch over
  `Status` exists, so no other call site needs changes.

## Testing

Unit (`src/http/response.zig` test block):
1. A sample of newly-added named codes: `Status.gone.code() == 410` + `reason() == "Gone"`;
   `Status.bad_gateway.code() == 502`; `Status.im_a_teapot.code() == 418`.
2. Arbitrary code: `Response.fromCode(599).status.code() == 599` and
   `.reason() == ""`; serializing it yields a status line starting `HTTP/1.1 599 ` (empty
   reason).
3. `@enumFromInt(@as(u16, 499))` → `code() == 499`, `reason() == ""` (non-exhaustive works).
4. Existing serialize/`fromStatus` tests still pass (e.g. 429/408 reason strings).

Unit (`src/error.zig` test block):
5. `classify(error.Gone).status == .gone` (+ reason "gone"); same for
   `UnsupportedMediaType`→415, `NotAcceptable`→406, `PreconditionFailed`→412,
   `BadGateway`→502, `GatewayTimeout`→504. Existing classify tests still pass.

## Verification

- `zig build test --summary all` — baseline 261/264 mac (3 Linux-epoll skips); after this
  feature, baseline + new tests, 0 failures. (Build also catches any missed non-exhaustive
  `else` arm.)
- Manual: `Response.fromStatus(.im_a_teapot)` → `HTTP/1.1 418 I'm a teapot`;
  `Response.fromCode(599)` → `HTTP/1.1 599 ` (custom code, empty reason).

## Docs

- `README.md`: in the Responses section, note the full standard status set is supported, plus
  `Response.fromCode(u16)` for arbitrary/non-standard codes, and the expanded `error.X` set.
  Update the "Status & limitations" section if it implies limited status support.
- `CHANGELOG.md`: entry under `[Unreleased]` (`### Added`).
