# Large buffered responses on evented Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the evented backend send buffered responses larger than `write_buf` (currently → 500) by sending the head from the write buffer, then pumping the body in place.

**Architecture:** Add a `pending_body`/`body_phase` indirection so `pumpWrite` can drain either `write_buf` (head, fast path) or the handler's `resp.body` slice (oversized path). When `serializeResponse` overflows, serialize the head only (`serializeHeadWithLen`) and pump `resp.body` directly — no copy, reusing the `.writing` state + partial-write logic. Falls back to 500 only if the head itself overflows.

**Tech Stack:** Zig 0.16, zax evented reactor (epoll/kqueue), fake-transport unit tests.

## Global Constraints

- Zig 0.16. Evented backend only (`src/reactor/conn.zig` + a `pub` on `src/http/response.zig:writeHeaders`). Do NOT touch the threaded backend.
- Split head/body ONLY when oversized; responses that fit `write_buf` keep the one-shot fast path (byte-for-byte unchanged).
- No body copy: pump `resp.body` (arena slice, valid through `.writing`) directly. No response-size cap.
- Reuse `.writing` state + `pumpWrite` partial-write/backpressure; no new state.
- Head-overflow (pathological huge headers) still → 500 + close (existing rare path).
- Reset `pending_body`/`body_phase` in the keep-alive block before `arena.reset` (pipelined reuse); close path discards the Conn (fresh `Conn.init` per accept).
- Test baseline: **257/260 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Pump large buffered bodies in place

**Files:**
- Modify: `src/http/response.zig` (`writeHeaders` → `pub` if not already)
- Modify: `src/reactor/conn.zig` (Conn fields; `pumpWrite` ~:418; new `serializeHeadWithLen`; buffered overflow branch ~:583-588; `.writing` `wrote_all` ~:740; keep-alive reset ~:748-751)
- Test: `src/reactor/conn.zig` (test block — mirror the pull-streamer partial-write tests ~:1611)

**Interfaces:**
- Consumes: `response.Response.writeHeaders(w, content_length)`, `Conn.pumpWrite`, `Conn.serializeResponse`.
- Produces: `Conn.pending_body: []const u8`, `Conn.body_phase: bool`, `Conn.serializeHeadWithLen(resp) error{ResponseTooLarge}!usize`.

- [ ] **Step 1: Make `writeHeaders` pub (if needed)**

In `src/http/response.zig`, find `fn writeHeaders(` (called by `pub fn write`). If it is not already `pub`, change it to `pub fn writeHeaders(`. Confirm its signature is `(self: Response, w: *Writer, content_length: usize) Writer.Error!void` (it emits `content-length`). No behavior change.

- [ ] **Step 2: Write failing unit tests**

In the `src/reactor/conn.zig` test block, mirror the existing fake-transport pull-streamer partial-write test (search for `mid-chunk backpressure` / a test that drives `step` with a transport returning small partial writes). Add tests that drive a Conn with a SMALL `write_buf` and a large buffered response. Use the existing fake transport (one that can return `.ok` with a capped `n` to force partial writes). Sketch (adapt to the real harness/fixture names):

```zig
test "evented large buffered response: full body sent across partial writes (no 500)" {
    // Conn with a small write_buf (e.g. 64 bytes) and a fake transport that
    // accepts at most 16 bytes per write. Dispatch a buffered response whose
    // body is, say, 300 bytes ("A" * 300) with status .ok.
    // Drive step() until done, collecting everything the transport received.
    // Assert: collected output starts with "HTTP/1.1 200 OK", contains
    // "content-length: 300", ends with the 300-byte body; NO "500".
}

test "evented large buffered response then keep-alive: second request served" {
    // Persistent request → large response fully sent → a SECOND request on the
    // same conn parses and is served (proves pending_body/body_phase reset).
}

test "evented small buffered response uses the one-shot fast path" {
    // A small response that fits write_buf → pending_body stays empty (&.{}),
    // body_phase false, output correct.
}

test "evented response with oversized HEAD still returns 500" {
    // A response whose HEADERS alone exceed a tiny write_buf → 500 + close.
}
```

Write real assertions using the actual fake-transport accessor for "bytes written" that the existing tests use (find it — e.g. a `written` ArrayList on the fake transport). Do NOT invent a new transport.

- [ ] **Step 3: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — large response currently yields 500 (and `pending_body`/`serializeHeadWithLen` undefined).

- [ ] **Step 4: Add Conn fields**

In `src/reactor/conn.zig`, in the `Conn` struct (near `pull_streamer`/`stream_chunked` fields), add:

```zig
        /// Large buffered response: the body to pump in place after the head
        /// (the handler's arena slice — never copied). Empty when not in use.
        pending_body: []const u8 = &.{},
        /// True once the head has been written and we are pumping `pending_body`.
        body_phase: bool = false,
```

- [ ] **Step 5: Source-select in `pumpWrite`**

In `pumpWrite` (`conn.zig:418`), replace:

```zig
        const remaining = self.write_buf[self.w_off..self.w_len];
```

with:

```zig
        const remaining = if (self.body_phase)
            self.pending_body[self.w_off..self.w_len]
        else
            self.write_buf[self.w_off..self.w_len];
```

- [ ] **Step 6: Add `serializeHeadWithLen`**

In `src/reactor/conn.zig`, next to `serializeHead` (~:398), add:

```zig
    /// Serialize the response HEAD with `content-length: resp.body.len` into
    /// `write_buf` (no body). Used to send the head of a large buffered response
    /// before pumping the body in place. `error.ResponseTooLarge` if the head
    /// alone does not fit.
    fn serializeHeadWithLen(self: *Conn, resp: Response) error{ResponseTooLarge}!usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        resp.writeHeaders(&w, resp.body.len) catch {
            self.w_len = w.end;
            self.w_off = 0;
            return error.ResponseTooLarge;
        };
        self.w_len = w.end;
        self.w_off = 0;
        return self.w_len;
    }
```

- [ ] **Step 7: Split path in the buffered overflow branch**

In the dispatch buffered branch, replace the overflow `else |_| { ...synthesize 500... }`
(`conn.zig:583-588`) with:

```zig
            } else |_| {
                // Too large for write_buf: send the head from write_buf, then pump
                // the body in place from resp.body (no copy). Only a head that
                // itself overflows falls back to 500.
                if (self.serializeHeadWithLen(resp)) |_| {
                    self.pending_body = resp.body;
                    self.body_phase = false; // head first
                    if (!persistent) self.close_after_write = true;
                } else |_| {
                    var e500 = Response.fromStatus(.internal_server_error);
                    e500.keep_alive = false;
                    _ = self.serializeResponse(e500) catch {};
                    self.close_after_write = true;
                }
            }
```

(Leave the success branch — `if (self.serializeResponse(resp)) |_| { ... }` — unchanged.)

- [ ] **Step 8: Body-phase transition in `.writing` `wrote_all`**

In the `.writing` `wrote_all` arm, AFTER the `if (self.pull_streamer) |ps| { ... }` block and
BEFORE the `// Normal (non-streaming) path.` comment (`conn.zig:740`), insert:

```zig
                            // Large buffered response: head fully written → now
                            // pump the body in place from resp.body.
                            if (self.pending_body.len > 0 and !self.body_phase) {
                                self.body_phase = true;
                                self.w_off = 0;
                                self.w_len = self.pending_body.len;
                                continue;
                            }
```

- [ ] **Step 9: Reset body-phase state on keep-alive**

In the keep-alive reset block (`conn.zig:748-751`, alongside
`self.stream_chunked = false;` before `arena.reset`), add:

```zig
                            self.pending_body = &.{};
                            self.body_phase = false;
```

- [ ] **Step 10: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS — all four new tests green; existing reactor tests unaffected; baseline 257 + new tests, 0 failures.

- [ ] **Step 11: Commit**

```bash
git add src/http/response.zig src/reactor/conn.zig
git commit -m "fix(reactor): send large buffered responses on evented (no 500)"
```

---

### Task 2: Docs + CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: evented-backend.md note**

In `docs/evented-backend.md`, in the responses/limitations section, add (and correct any
statement implying a response-size limit on evented):

> **Buffered responses of any size.** A buffered (non-streamed) response larger than the
> write buffer is sent by writing the head from the write buffer and then streaming the body
> in place across writable events — no fixed cap and no copy. (Previously such responses
> returned 500 on the evented backend.)

- [ ] **Step 2: CHANGELOG entry**

Under `## [Unreleased]` → `### Fixed` in `CHANGELOG.md` (create the `### Fixed` subsection if
absent; v0.7.0 is the latest released — entry goes under `[Unreleased]` only):

```markdown
- Evented reactor: buffered (non-streamed) responses larger than the write buffer (default 8 KB) are now sent correctly — the head is written from the buffer and the body is streamed in place — instead of returning 500. The threaded backend was unaffected.
```

- [ ] **Step 3: Run + commit**

Run: `zig build test --summary all` (expect green, no count change from docs)

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(reactor): document large buffered responses on evented"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 257 + the four new conn tests.
- Spec coverage: T1 = writeHeaders pub + Conn fields + pumpWrite source-select + serializeHeadWithLen + split overflow branch + body-phase transition + keep-alive reset + 4 tests; T2 = docs + CHANGELOG. All spec sections covered.
- Regression: small responses unchanged (fast path); streamed responses unchanged; threaded untouched; keep-alive after a large response works (state reset).
- Manual: `curl` a ~50 KB JSON endpoint under `serveEvented` → full body + 200 (was 500).
