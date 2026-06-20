# Full HTTP status code support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support the full standard HTTP status set as named variants plus any arbitrary `u16` code, and add common handler `error.X` mappings.

**Architecture:** Expand the `Status` `enum(u16)` to the full IANA named set and make it non-exhaustive (`_`) so any code is valid; `reason()` returns "" for unnamed; add `Response.fromCode(u16)`. Expand `error.zig`'s canonical `Error` set + `classify` for common codes.

**Tech Stack:** Zig 0.16.

## Global Constraints

- Zig 0.16. Purely additive: all existing named variants keep their exact names + values, so every current `fromStatus(.x)`/`code()`/`reason()` call compiles unchanged.
- `Status` becomes `enum(u16) { …, _ }` (non-exhaustive) → any `u16` representable. `reason()` gets `else => ""` (RFC-legal empty reason). `code()` (`@intFromEnum`) unchanged.
- Arbitrary codes via `Response.fromCode(u16)` (`@enumFromInt`) and `.status = @enumFromInt(x)`.
- The ONLY exhaustive switch over a `Status` value is `reason()` — the build will flag any other; fix with an `else` arm if one appears. (`conn.zig:540` switches over an error, not a Status — leave it.)
- Error additions target statuses that now exist in the expanded enum.
- Test baseline: **261/264 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Expand the Status enum + arbitrary codes

**Files:**
- Modify: `src/http/response.zig` — `Status` enum + `reason()` (~:11-71); `Response.fromCode` (near `fromStatus` ~:146)
- Test: `src/http/response.zig` (test block)

**Interfaces:**
- Produces: expanded non-exhaustive `Status` (full IANA named set + `_`); `Status.reason()` with `else => ""`; `Response.fromCode(code: u16) Response`.

- [ ] **Step 1: Write failing tests**

In the `src/http/response.zig` test block, add:

```zig
test "status: expanded named codes" {
    try testing.expectEqual(@as(u16, 410), Status.gone.code());
    try testing.expectEqualStrings("Gone", Status.gone.reason());
    try testing.expectEqual(@as(u16, 502), Status.bad_gateway.code());
    try testing.expectEqualStrings("Bad Gateway", Status.bad_gateway.reason());
    try testing.expectEqual(@as(u16, 418), Status.im_a_teapot.code());
    try testing.expectEqual(@as(u16, 206), Status.partial_content.code());
    try testing.expectEqual(@as(u16, 100), Status.@"continue".code());
}

test "status: arbitrary code via non-exhaustive enum" {
    const s: Status = @enumFromInt(@as(u16, 499));
    try testing.expectEqual(@as(u16, 499), s.code());
    try testing.expectEqualStrings("", s.reason());
}

test "response: fromCode arbitrary status serializes with empty reason" {
    var buf: [128]u8 = undefined;
    const out = serialize(&buf, Response.fromCode(599));
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 599 \r\n"));
}
```

(`serialize` is the existing test helper used by the current serialize test ~:376 — reuse it; if its signature differs, match the existing call.)

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — `Status.gone`/`im_a_teapot`/`@"continue"`/`fromCode` undefined.

- [ ] **Step 3: Replace the `Status` enum + `reason()`**

In `src/http/response.zig`, replace the `Status` enum (`:11-71`) with the full set (keep `ok`/etc. names/values identical; add the rest; non-exhaustive `_`). Note `continue` is a Zig keyword → use `@"continue"`:

```zig
pub const Status = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,
    _,

    pub fn code(s: Status) u16 {
        return @intFromEnum(s);
    }

    pub fn reason(s: Status) []const u8 {
        return switch (s) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_entity => "Unprocessable Entity",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",
            else => "",
        };
    }
};
```

- [ ] **Step 4: Add `Response.fromCode`**

In `src/http/response.zig`, next to `fromStatus` (~:146), add:

```zig
/// Build a bare response with an arbitrary numeric status (for codes outside the
/// named set — proxies, custom). Named codes should prefer `fromStatus`.
pub fn fromCode(code: u16) Response {
    return .{ .status = @enumFromInt(code) };
}
```

- [ ] **Step 5: Build + run**

Run: `zig build test --summary all`
Expected: PASS — the 3 new tests green; existing serialize/`fromStatus`/reason tests still pass. If the build flags an exhaustive switch over `Status` anywhere else, add an `else` arm there (none expected beyond `reason()`).

- [ ] **Step 6: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): full standard status set + arbitrary codes (non-exhaustive Status)"
```

---

### Task 2: Expand the Error set + docs

**Files:**
- Modify: `src/error.zig` (`Error` set ~:16-28; `classify` ~:32-58)
- Modify: `README.md`, `CHANGELOG.md`
- Test: `src/error.zig` (test block)

**Interfaces:**
- Consumes: the expanded `Status` (`.gone`/`.unsupported_media_type`/`.not_acceptable`/`.precondition_failed`/`.bad_gateway`/`.gateway_timeout`) from Task 1.

- [ ] **Step 1: Write failing classify tests**

In the `src/error.zig` test block, add:

```zig
test "classify maps the expanded error set" {
    try testing.expectEqual(Status.gone, classify(Error.Gone).status);
    try testing.expectEqual(Status.unsupported_media_type, classify(Error.UnsupportedMediaType).status);
    try testing.expectEqual(Status.not_acceptable, classify(Error.NotAcceptable).status);
    try testing.expectEqual(Status.precondition_failed, classify(Error.PreconditionFailed).status);
    try testing.expectEqual(Status.bad_gateway, classify(Error.BadGateway).status);
    try testing.expectEqual(Status.gateway_timeout, classify(Error.GatewayTimeout).status);
    try testing.expectEqualStrings("gone", classify(Error.Gone).reason);
}
```

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — `Error.Gone` etc. undefined.

- [ ] **Step 3: Add Error variants**

In `src/error.zig`, add to the `Error` set (after `ServiceUnavailable`):

```zig
    Gone,
    UnsupportedMediaType,
    NotAcceptable,
    PreconditionFailed,
    BadGateway,
    GatewayTimeout,
```

- [ ] **Step 4: Add classify arms**

In `classify` (before the extractor-tag section), add:

```zig
        error.Gone => .{ .status = .gone, .reason = "gone" },
        error.UnsupportedMediaType => .{ .status = .unsupported_media_type, .reason = "unsupported media type" },
        error.NotAcceptable => .{ .status = .not_acceptable, .reason = "not acceptable" },
        error.PreconditionFailed => .{ .status = .precondition_failed, .reason = "precondition failed" },
        error.BadGateway => .{ .status = .bad_gateway, .reason = "bad gateway" },
        error.GatewayTimeout => .{ .status = .gateway_timeout, .reason = "gateway timeout" },
```

- [ ] **Step 5: Build + run**

Run: `zig build test --summary all`
Expected: PASS — new classify tests green; existing error tests pass.

- [ ] **Step 6: README + CHANGELOG**

In `README.md`, in the Responses section, add a note: the full standard HTTP status set is
supported as `Status` variants; arbitrary/non-standard codes via `Response.fromCode(u16)`;
handlers can `return` canonical errors (`error.NotFound`, `error.Gone`,
`error.UnsupportedMediaType`, …) which map to statuses. Update the "Status & limitations"
section if it implies limited status support.

In `CHANGELOG.md` under `## [Unreleased]` → `### Added` (create the subsection if absent):

```markdown
- Full standard HTTP status set as `Status` variants, plus `Response.fromCode(u16)` for arbitrary/non-standard codes (the `Status` enum is now non-exhaustive). Expanded the canonical `Error` set (`Gone`, `UnsupportedMediaType`, `NotAcceptable`, `PreconditionFailed`, `BadGateway`, `GatewayTimeout`) with `classify` mappings.
```

- [ ] **Step 7: Commit**

```bash
git add src/error.zig README.md CHANGELOG.md
git commit -m "feat(error): expanded canonical Error set + classify; docs"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 261 + new status/error tests.
- Spec coverage: T1 = full named set + non-exhaustive + reason else + fromCode + tests; T2 = Error set + classify + README + CHANGELOG + tests. All spec sections covered.
- Regression: existing named variants unchanged (names/values), so all current call sites compile + behave identically; only `reason()` gained an `else`.
- Manual: `Response.fromStatus(.im_a_teapot)` → `HTTP/1.1 418 I'm a teapot`; `Response.fromCode(599)` → `HTTP/1.1 599 ` (empty reason).
