# Zax — request id / correlation (F3) design

Date: 2026-06-17. Status: accepted. Scope: sub-project F3 of theme F
(observability) — the FINAL sub-project of theme F and of the post-v0.1.0
roadmap (A–F). F1 (hook + access logger) and F2 (metrics) are done.

## Context

zax has no request correlation id. F3 adds an opt-in per-request id: read a
validated incoming `x-request-id` (correlate across a proxy/client) or generate
one, expose it to handlers (`ctx.request_id` + a `RequestId` extractor), echo it
in the response (`x-request-id`), and include it in the access log
(`AccessRecord.request_id`).

## Decision (from brainstorming)

1. **Opt-in via `Options.request_id` (default false).** Mirrors
   `trust_forwarded`. When off: zero overhead, `ctx.request_id == ""`, no header.
2. **Incoming-or-generated, with validation.** When enabled, the id is the
   incoming `x-request-id` **iff it passes validation**, else a generated id.
3. **Validation (security).** An incoming id is client-controlled; echoing it raw
   into a response header risks CRLF response-splitting, and into the text access
   log risks newline log-injection. Accept an incoming id only if it is
   1–128 chars and every char is in `[A-Za-z0-9._-]`; otherwise generate. (The
   generated id is always safe.)
4. **Generation: per-app atomic counter, 16 hex digits.** `rid_counter:
   std.atomic.Value(u64)` on `App`; `fetchAdd(.monotonic)` then
   `allocPrint(arena, "{x:0>16}", .{n})`. Unique within a process run; no RNG
   dependency. (Not globally unique across restarts — fine for correlation.)
5. **Threaded through the request path.** `handleConn` computes the id (when
   enabled) before `dispatch`, passes it to `dispatch` → `makeCtx` (sets
   `ctx.request_id`), echoes it on the response (`withHeader`) before writing, and
   includes it in the `AccessRecord`. One orchestration point.
6. **Handler access:** `ctx.request_id` field + a `RequestId` extractor
   (`rid.value` == `ctx.request_id`, `""` when disabled) for ergonomic use.
7. **Log integration:** `AccessRecord` gains `request_id` (default `""`); the
   `AccessLogger` appends it **only when non-empty** (text: ` id=<id>`; JSON:
   `,"request_id":"<id>"`), so F1's default output is unchanged.

## Architecture

```
handleConn (per request):
  rid = opts.request_id ? computeRid(req, arena) : ""
        computeRid: validRid(req.header("x-request-id")) ? that : genHex(counter, arena)
  resp = dispatch(io, req, arena, rid)      // makeCtx sets ctx.request_id = rid
  if opts.request_id: resp = resp.withHeader(arena, "x-request-id", rid)
  writeResponse(resp)
  observe: AccessRecord{ ..., request_id = rid }
```

## Components

### 1. `src/extract/extract.zig` — Context field
Add `request_id: []const u8 = ""` to `Context(AppState)`.

### 2. `src/extract/request_id.zig` (new) — extractor
```zig
pub const RequestId = struct {
    value: []const u8,
    pub const zax_is_extractor = true;
    pub const zax_is_body = false;
    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .value = ctx.request_id };
    }
};
```
Root export: `pub const RequestId = @import("extract/request_id.zig").RequestId;`.

### 3. `src/server.zig`
- `Options.request_id: bool = false`.
- `App` field `rid_counter: std.atomic.Value(u64) = .init(0)`.
- `fn validRid(s: []const u8) bool` — `1..=128` chars, each in `[A-Za-z0-9._-]`.
- `fn computeRid(self, req, arena) []const u8` — incoming `x-request-id` if
  `validRid`, else `allocPrint(arena, "{x:0>16}", .{rid_counter.fetchAdd(1, .monotonic)}) catch ""`.
- `makeCtx` gains a `request_id: []const u8` param → sets `ctx.request_id`.
- `dispatch` gains a `request_id: []const u8` param, threaded to all `makeCtx`
  call sites (BadRequest, not_found, method_not_allowed, found).
- `handleConn`: compute `rid` (when `opts.request_id`) before `dispatch`; pass to
  `dispatch`; after `dispatch`, if enabled `resp = resp.withHeader(arena.allocator(),
  "x-request-id", rid) catch resp`; set `AccessRecord.request_id = rid`.

### 4. `src/observe.zig`
- `AccessRecord` gains `request_id: []const u8 = ""`.
- `AccessLogger.writeRecord`: when `rec.request_id.len > 0`, append ` id=<id>`
  (text) / `,"request_id":"<id>"` (json). (Ids are validated/hex → safe to embed
  raw.)

## Testing

- **Unit:** `validRid` — accepts `"abc-123"`, `"00000000000000a1"`; rejects `""`,
  a 129-char string, `"bad id"` (space), `"a\r\nb"` (CRLF), `"a/b"`. `AccessLogger`
  with a non-empty `request_id` appends ` id=...` (text) / `"request_id":"..."`
  (json); with empty `request_id` the F1 output is unchanged.
- **Integration (`src/server.zig` socket test):** app with `.request_id = true`
  and a handler returning `RequestId.value` as the body:
  - no incoming header → response has an `x-request-id` header (16 hex) equal to
    the body (handler saw the same id).
  - incoming `X-Request-Id: abc-123` → body and header both `abc-123`.
  - incoming invalid `X-Request-Id: bad id!` → body/header are a generated id, NOT
    `bad id!` (no injection).
  - app WITHOUT `.request_id` → no `x-request-id` header; `RequestId.value == ""`.
- **Regression:** full `zig build test` green (146 + new tests).

## Files

- Add: `src/extract/request_id.zig`.
- Modify: `src/extract/extract.zig` (Context field), `src/server.zig` (Options,
  counter, validRid, computeRid, makeCtx, dispatch, handleConn, tests),
  `src/observe.zig` (AccessRecord + logger), `src/root.zig` (export `RequestId`).
- Modify: `README.md`, `docs/getting-started.md`.

## Risks & edge cases

- **Injection (handled):** incoming ids validated to a safe charset before being
  echoed/logged — no CRLF/space/control chars reach the response header or log.
- **Lifetime:** an accepted incoming id borrows the request read buffer; a
  generated id is arena-allocated. Both live for the whole request (used in
  dispatch, echo, log within `handleConn`). Safe.
- **dispatch signature change:** `dispatch`/`makeCtx` gain a `request_id` param;
  all call sites updated. When disabled the value is `""` (no behavior change vs
  today — empty header not added, `ctx.request_id` empty).
- **Counter wraparound:** u64 — not a practical concern.
- **F1 log compatibility:** the logger appends the id only when non-empty, so F1's
  format tests and default output are unchanged.

## Out of scope

W3C `traceparent`/distributed tracing span propagation, trust-gating the incoming
id behind `trust_forwarded` (validation already makes it injection-safe; accepting
a syntactically-valid client id is the intended correlation behavior), UUID/random
ids (chose the atomic counter). Theme F and the A–F roadmap are complete after F3.
