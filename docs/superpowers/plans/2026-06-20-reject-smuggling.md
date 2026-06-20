# Reject request-smuggling framing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject ambiguous request framing (Content-Length + Transfer-Encoding, duplicate CL, multiple TE) with 400 on both backends to prevent HTTP request smuggling.

**Architecture:** A single `Request.hasFramingConflict()` scans all headers; each backend's `readBody` calls it first and returns the existing `error.Malformed` (→ 400) on conflict. No parser change, no new status/error.

**Tech Stack:** Zig 0.16; both backends (`src/server.zig` threaded, `src/reactor/conn.zig` evented).

## Global Constraints

- Zig 0.16. Detect + reject (400) — do NOT implement TE-precedence/strip-CL.
- Conflicts (any → reject): both `Content-Length` and `Transfer-Encoding` present; >1 `Content-Length`; >1 `Transfer-Encoding`.
- Single shared method `Request.hasFramingConflict()` (case-insensitive, full-headers scan — `header()` only sees the first duplicate). Both backends call it identically.
- Reuse existing `error.Malformed` → 400 path on BOTH backends (threaded `terminalResponse`, evented `step` mapping). No new error variant, no parser change.
- Legit single-framing requests (CL-only, TE-chunked-only, no-body) must NOT be affected.
- Test baseline: **265/268 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Detect + reject conflicting framing

**Files:**
- Modify: `src/http/request.zig` (add `hasFramingConflict`; test block)
- Modify: `src/server.zig` (`readBody` top ~:963)
- Modify: `src/reactor/conn.zig` (`readBody` top ~:303)
- Test: `src/http/request.zig` (unit), `src/server.zig` (threaded e2e), `src/reactor/conn.zig` (evented integration)

**Interfaces:**
- Produces: `Request.hasFramingConflict(self: *const Request) bool`.

- [ ] **Step 1: Write the failing unit test**

In the `src/http/request.zig` test block, add (build `Request` values with literal `headers` slices):

```zig
test "hasFramingConflict detects smuggling framing" {
    const mk = struct {
        fn req(hs: []const Header) Request {
            return .{ .method = .POST, .target = "/", .path = "/", .query = "",
                      .version_minor = 1, .headers = hs, .body = "" };
        }
    };
    // CL + TE → conflict
    try std.testing.expect(mk.req(&.{
        .{ .name = "Content-Length", .value = "5" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    }).hasFramingConflict());
    // duplicate Content-Length → conflict
    try std.testing.expect(mk.req(&.{
        .{ .name = "content-length", .value = "5" },
        .{ .name = "Content-Length", .value = "5" },
    }).hasFramingConflict());
    // multiple Transfer-Encoding → conflict
    try std.testing.expect(mk.req(&.{
        .{ .name = "transfer-encoding", .value = "gzip" },
        .{ .name = "transfer-encoding", .value = "chunked" },
    }).hasFramingConflict());
    // CL only → ok
    try std.testing.expect(!mk.req(&.{ .{ .name = "Content-Length", .value = "5" } }).hasFramingConflict());
    // TE chunked only → ok
    try std.testing.expect(!mk.req(&.{ .{ .name = "Transfer-Encoding", .value = "chunked" } }).hasFramingConflict());
    // single TE with coding list, no CL → ok
    try std.testing.expect(!mk.req(&.{ .{ .name = "Transfer-Encoding", .value = "gzip, chunked" } }).hasFramingConflict());
    // no framing headers → ok
    try std.testing.expect(!mk.req(&.{ .{ .name = "Host", .value = "x" } }).hasFramingConflict());
}
```

(If `Request` has more required fields than shown, set them in the `req` helper to compile — read the struct first.)

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — `hasFramingConflict` undefined.

- [ ] **Step 3: Implement `hasFramingConflict`**

In `src/http/request.zig`, add a method to `Request` (near `header`/`isChunked`):

```zig
    /// True when the request's framing headers are ambiguous (RFC 7230 §3.3.3) —
    /// an HTTP request-smuggling vector — and the request must be rejected (400):
    ///   - both Transfer-Encoding and Content-Length present, or
    ///   - more than one Content-Length header, or
    ///   - more than one Transfer-Encoding header.
    /// Scans all headers because `header()` only returns the first of a duplicate.
    pub fn hasFramingConflict(self: *const Request) bool {
        var n_cl: usize = 0;
        var n_te: usize = 0;
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
                n_cl += 1;
            } else if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) {
                n_te += 1;
            }
        }
        if (n_cl > 1) return true;
        if (n_te > 1) return true;
        return n_cl >= 1 and n_te >= 1;
    }
```

- [ ] **Step 4: Run unit test — verify pass**

Run: `zig build test --summary all`
Expected: the unit test passes.

- [ ] **Step 5: Threaded reject + e2e tests**

In `src/server.zig` `readBody` (`:963`), as the FIRST statement (before the `isChunked()` branch):

```zig
    if (parsed.request.hasFramingConflict()) return error.Malformed;
```

Add a threaded loopback e2e test (mirror the existing chunked-request tests, e.g. "chunked request body is decoded"): send a request with both `Content-Length: 5` and `Transfer-Encoding: chunked` → assert response contains `"400"`; send a request with two `Content-Length` headers → `"400"`; confirm a normal `Content-Length` POST and a normal chunked POST still return `200` (no false positive).

- [ ] **Step 6: Evented reject + integration tests**

In `src/reactor/conn.zig` `readBody` (`:303`), as the FIRST statement (before the `isChunked()` branch):

```zig
        if (p.request.hasFramingConflict()) return .{ .failed = error.Malformed };
```

Add an evented fake-transport test (mirror the chunked-decode tests): drive a CL+TE request → assert `step` produces a `400` response (`.bad_request`) and closes; confirm a normal chunked request and a normal CL request still parse + dispatch.

- [ ] **Step 7: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS — all new unit/e2e/integration tests green; existing tests unaffected; baseline 265 + new tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add src/http/request.zig src/server.zig src/reactor/conn.zig
git commit -m "fix(security): reject ambiguous request framing (CL+TE smuggling) with 400"
```

---

### Task 2: Docs + CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md` (or README security note)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Docs note**

In `docs/evented-backend.md` (or a short security note in `README.md`), state: zax rejects
ambiguous request framing — a request with both `Content-Length` and `Transfer-Encoding`, or
with duplicate `Content-Length` / multiple `Transfer-Encoding` headers — with `400 Bad Request`
(and closes the connection) to prevent HTTP request smuggling. Applies to both backends.

- [ ] **Step 2: CHANGELOG entry**

In `CHANGELOG.md` under `## [Unreleased]`, add a `### Security` subsection (create it; place
above `### Added`/`### Changed`/`### Fixed` if present, matching the changelog style):

```markdown
### Security

- Reject ambiguous request framing with `400 Bad Request` — a request carrying both `Content-Length` and `Transfer-Encoding`, or duplicate `Content-Length` / multiple `Transfer-Encoding` headers (RFC 7230 §3.3.3) — to prevent HTTP request smuggling. Both backends.
```

- [ ] **Step 3: Run + commit**

Run: `zig build test --summary all` (expect green, no count change from docs)

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(security): document request-smuggling framing rejection"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 265 + new unit/e2e/integration tests.
- Spec coverage: T1 = `hasFramingConflict` + both backend reject sites + unit/e2e/integration tests; T2 = docs + CHANGELOG. All spec sections covered.
- Regression: CL-only, TE-chunked-only, no-body requests unaffected (no false positive).
- Manual: a CL+TE request via `nc` → `HTTP/1.1 400`.
