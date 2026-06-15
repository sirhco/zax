# Zax v1.1 plan — middleware, keep-alive, HTTPS

Subagent-driven-development plan for the three features deferred from v1. Each
task is implemented by a subagent using TDD (failing `test` first, then code,
`zig build test` green), grounded in [`docs/zig016-api-notes.md`](zig016-api-notes.md)
and the existing real-socket test harness in `src/server.zig`. A review checkpoint
(`requesting-code-review`) closes each phase before the next begins.

## Context

v1 shipped a core vertical slice (34 tests, `feat/zax-v1-core`). v1.1 adds the
three pieces the README flags as designed-for-but-not-built. Research against the
installed Zig 0.16.0 std settled the unknowns:

- **TLS:** std ships `crypto.tls.Client` only — **no server handshake**. Decision:
  **terminate TLS at a reverse proxy** (nginx/Caddy/Cloudflare); Zax stays
  plaintext HTTP/1.1 and trusts `X-Forwarded-*` from the proxy. No C deps, no
  from-scratch crypto. (In-process TLS is revisited if std ships a server.)
- **Keep-alive:** feasible on std — `Io.Reader.toss`/`tossBuffered`/`rebase`
  (buffer reuse) and `Io.Timeout`/`Clock.Duration.sleep` (idle timeout) all exist.
  Decision: **Content-Length framing only**; reject `Transfer-Encoding: chunked`
  request bodies with 411 and close.
- **Middleware:** pure design on existing types; no std unknowns.

## Decisions (from the user)
1. HTTPS via reverse-proxy termination + forwarded-header trust.
2. Keep-alive: Content-Length only, chunked request bodies rejected.

## Dependencies between phases

```
Phase 1 (Response headers + connection control)
   ├── Phase 2 (Keep-alive loop)      ─┐  both touch server.zig but different fns;
   └── Phase 3 (Middleware chain)      ─┘  run sequentially (2 then 3) to avoid conflicts
Phase 4 (Reverse-proxy HTTPS)  — independent, may run in parallel with 2/3
```

Phase 1 is a prerequisite for 2 (needs `Connection` header control) and 3 (needs
response-header injection for post-processing middleware).

---

## Phase 1 — Response header support + connection control

**Why first:** today `Response` has a fixed shape and hardcodes
`connection: close`. Middleware post-processing wants to add headers; keep-alive
needs to set `Connection` dynamically.

**Files:** `src/http/response.zig`.

**Work:**
- Add an arena-backed extra-headers list to `Response`:
  `headers: []const Header = &.{}` plus a builder
  `withHeader(self, arena, name, value) !Response` (or a small `ResponseBuilder`).
  Keep zero-alloc default (empty slice).
- Replace the hardcoded `connection: close` with a field
  `keep_alive: bool = false`; `write` emits `connection: keep-alive` or `close`
  accordingly. Default stays `close` so v1 behavior is unchanged until Phase 2
  flips it.
- Serialize extra headers between content-type and the blank line.

**Tests (extend `response.zig`):** extra headers serialize in order; `keep_alive`
toggles the `Connection` line; empty-headers path unchanged from v1 golden bytes.

**Subagent:** one `cavecrew-builder` (single file, bounded) or general agent.
Reference the existing `Response.write` golden-bytes tests so formatting stays
exact.

---

## Phase 2 — Keep-alive (persistent connections)

**Files:** `src/server.zig` (`handleConn`), `src/http/request.zig` (helper).

**Work:**
- Add `Request.isPersistent()`: HTTP/1.1 default keep-alive unless
  `Connection: close`; HTTP/1.0 default close unless `Connection: keep-alive`.
- Reject framing we don't support: if request has `Transfer-Encoding: chunked`,
  respond `411 Length Required` (or `400`) and close.
- Convert `handleConn` from one-shot to a **request loop** on the same stream:
  1. `readRequest` (existing) → route → run handler → write response with
     `keep_alive = request.isPersistent()`.
  2. After responding, `r.toss(head_len + body_len)` to consume the request; if
     more bytes are already buffered (pipelined), loop without reading; else
     `rebase` to reclaim buffer and `fillMore` for the next.
  3. Reset the per-connection arena between requests
     (`_ = arena.reset(.retain_capacity)`) instead of one arena per request —
     reuses capacity, still frees per-request data.
  4. Exit the loop when: not persistent, client closes (EOF), idle timeout, a
     read/parse error, or a configured max-requests-per-connection cap.
- **Idle timeout:** best-effort using `Io.Timeout`/`Clock.Duration.sleep` raced
  against the next read via `io.select` (see api-notes). If the select wiring
  proves heavy, ship a simpler variant first (close on EOF + a request cap) and
  add the timer as a follow-up task — `log`/document whichever is shipped.
- New `Options` fields: `keep_alive: bool = true`, `max_keep_alive_requests:
  usize = 100`, `idle_timeout_ms: u32 = 5000`.

**Tests (extend `server.zig`, real sockets):**
- Two sequential requests on one connection both succeed (proves reuse + arena
  reset + `toss`/`rebase`).
- Pipelined: two requests written back-to-back, two responses read in order.
- `Connection: close` → server closes after one response (next read EOFs).
- HTTP/1.0 request → closes by default.
- `Transfer-Encoding: chunked` request → 411 and close.

**Subagent:** general agent (multi-step, touches the live test harness). Must run
`zig build test` 3× to check for timing flakiness (as in v1 Phase 4).

---

## Phase 3 — Middleware (tower-style layer chain)

**Files:** new `src/middleware.zig`; `src/server.zig` (`App`, `handleOne`); export
in `src/root.zig`.

**Design (runtime chain over the existing type-erased handler):**
- `Middleware = *const fn (ctx: *const Ctx, next: *Next) anyerror!Response`.
- `Next` is a tiny cursor: `{ mws: []const Middleware, idx, handler: ErasedHandler }`
  with `run(ctx)` that calls `mws[idx]` (advancing) or, when exhausted, the
  matched handler. This gives ordered execution, **short-circuit** (return
  without calling `next` — e.g. auth → 401), and **post-processing** (call
  `next`, then mutate the response — e.g. add `x-request-id`).
- `App` holds `mws: std.ArrayListUnmanaged(Middleware)`; `app.use(mw)` appends.
  `handleOne` builds a `Next` over `app.mws` + the matched handler and runs it,
  instead of calling the handler directly. Middleware runs **before** routing is
  resolved? No — after match (so 404/405 still short-circuit cheaply); document
  that ordering choice. (A pre-routing variant can come later.)
- Middleware see the same `Ctx` (req, state, arena), so they read headers, touch
  state, and allocate via the arena.

**Tests (`middleware.zig` + an integration test in `server.zig`):**
- Ordering: two middlewares run outer→inner, response unwinds inner→outer.
- Short-circuit: an auth middleware returns 401 without invoking the handler.
- Post-processing: a middleware adds a header to the handler's response (uses
  Phase 1 header support).
- State access: middleware reads `ctx.state`.

**Subagent:** general agent. Depends on Phase 1 (header injection) being merged.

---

## Phase 4 — HTTPS via reverse proxy (forwarded-header trust + docs)

**Files:** new `src/extract/forwarded.zig`; `src/server.zig` (`Options`); new
`docs/deploy-https.md`; `README.md` update; export in `root.zig`.

**Work:**
- `Options.trust_forwarded: bool = false` (opt-in; only trust when actually
  behind a proxy you control).
- A `Forwarded` extractor exposing derived connection info:
  `scheme` (`X-Forwarded-Proto`, default "http"), `host` (`X-Forwarded-Host`),
  `client_ip` (first hop of `X-Forwarded-For`). When `trust_forwarded` is false,
  the extractor returns direct-connection defaults and ignores the headers.
- Threading `trust_forwarded` into the `Ctx` (extend `Context` with a small
  `conn` substruct, or pass via app state) so the extractor can honor it.
- `docs/deploy-https.md`: worked nginx and Caddy configs terminating TLS and
  proxying to Zax on `127.0.0.1:8080`, setting `X-Forwarded-Proto/Host/For`.
  README: add an "HTTPS in production" section pointing to it.

**Tests (`forwarded.zig`):** parse proto/host/first-XFF-hop; `trust_forwarded =
false` ignores all forwarded headers and yields defaults; malformed XFF handled.

**Subagent:** general agent (code + docs). Independent — safe to run in parallel
with Phases 2–3 since it touches different files (only a small `Context`/`Options`
addition coordinates with them; do that addition in Phase 1 to avoid a merge
seam, or rebase Phase 4 after 1).

---

## Cross-cutting

- **Keep `zig build test` the gate.** Every task adds tests; `src/root.zig`
  already aggregates all modules. Target: no net-new untested public function.
- **Update the README** at the end (remove shipped items from the "limitations"
  list; document keep-alive, middleware, and HTTPS-via-proxy).
- **No new dependencies.** All three features land on std + existing code; the
  reverse-proxy choice specifically avoids a TLS/C dependency.

## Verification (end-to-end, after all phases)

- `zig build test` green; run 3× for keep-alive timing stability.
- `zig build run`, then (via the JS-fetch smoke used in v1, since curl is hooked):
  - keep-alive: issue 2 requests on one reused connection, confirm both 200 and
    the socket stays open between them.
  - middleware: register a request-id middleware, confirm the header appears on
    responses and an auth middleware 401s without reaching the handler.
  - forwarded: with `trust_forwarded = true`, send `X-Forwarded-Proto: https`
    and confirm a handler using the `Forwarded` extractor sees `scheme = https`;
    with it false, sees `http`.
- HTTPS path is validated manually behind a local Caddy/nginx per
  `docs/deploy-https.md` (out of the automated suite — no in-process TLS).

## Risks / open items

- **Idle-timeout via `io.select`** is the least-certain piece; ship the simple
  EOF+cap variant first if the select wiring is heavy, and note it.
- **Middleware position relative to routing** (post-match chosen) — revisit if a
  pre-routing hook (e.g. global rate-limit) is needed.
- **Pipelining + response buffering**: ensure the write buffer is flushed per
  response inside the keep-alive loop so pipelined clients get framed replies.
