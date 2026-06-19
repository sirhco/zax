# Inbound chunked request bodies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode `Transfer-Encoding: chunked` request bodies on both backends and hand handlers a contiguous zero-copy `[]const u8`, replacing the current 411 rejection.

**Architecture:** A pure in-place decoder in `src/http/chunked.zig` (`decodeInPlace`) concatenates chunk data over the removed chunk headers (write-pos ≤ read-pos → forward overlapping copy). `parser.Parsed` gains `body_consumed` (encoded body length) so both backends advance past the request by the encoded length, not the decoded length. Each backend's `readBody` gets a chunked branch that loops read→decode until done.

**Tech Stack:** Zig 0.16, zax dual backend (threaded `std.Io.Threaded` + evented reactor epoll/kqueue), fake-transport + loopback tests.

## Global Constraints

- Zig 0.16. Purely additive where possible; no new dependencies.
- Always-on: remove the 411; no opt-in knob. Standard RFC 7230 §4.1 behavior.
- Both backends (threaded `src/server.zig` + evented `src/reactor/conn.zig`) must decode chunked identically.
- Body MUST remain a contiguous zero-copy `[]const u8` slice into the read buffer (extractors `src/extract/{bytes,json,form}.zig` read `ctx.req.body`).
- Decode IN PLACE via `std.mem.copyForwards` (dest ≤ src invariant). No allocation, no IO in the decoder.
- Tolerate chunk extensions (`<hex>;ext` → skip to CRLF) and trailers (after `0`-chunk → skip header lines to final blank line); do NOT surface them.
- `max_body_size` bounds the DECODED length (0 = unbounded). Encoded body bounded by read-buffer space → overflow before terminator = 413.
- Error mapping: malformed framing → 400; over-limit / buffer overflow → 413.
- Test baseline: **235/238 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: `decodeInPlace` chunked decoder

Pure in-place decoder + exhaustive unit tests. No backend wiring yet.

**Files:**
- Modify: `src/http/chunked.zig` (add `DecodeResult` + `decodeInPlace`)
- Test: `src/http/chunked.zig` (test block at end of file)

**Interfaces:**
- Produces:
  ```zig
  pub const DecodeResult = union(enum) {
      done: struct { body_len: usize, consumed: usize },
      incomplete,
      malformed,
      too_large,
  };
  pub fn decodeInPlace(buf: []u8, max: usize) DecodeResult;
  ```

- [ ] **Step 1: Write failing tests**

Add to the test block in `src/http/chunked.zig`. Use a mutable buffer (copy the literal into a `var` array since decode mutates in place):

```zig
test "decodeInPlace: single chunk" {
    var buf = "5\r\nhello\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expect(r == .done);
    try std.testing.expectEqual(@as(usize, 5), r.done.body_len);
    try std.testing.expectEqual(buf.len, r.done.consumed);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
}

test "decodeInPlace: multi-chunk concatenates" {
    var buf = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello world", buf[0..r.done.body_len]);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: chunk extension skipped" {
    var buf = "5;foo=bar\r\nhello\r\n0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
}

test "decodeInPlace: trailers skipped, counted in consumed" {
    var buf = "5\r\nhello\r\n0\r\nX-Trace: 1\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqualStrings("hello", buf[0..r.done.body_len]);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: empty body" {
    var buf = "0\r\n\r\n".*;
    const r = decodeInPlace(&buf, 0);
    try std.testing.expectEqual(@as(usize, 0), r.done.body_len);
    try std.testing.expectEqual(buf.len, r.done.consumed);
}

test "decodeInPlace: incomplete (no terminator)" {
    var buf = "5\r\nhel".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .incomplete);
}

test "decodeInPlace: incomplete (data shorter than size)" {
    var buf = "5\r\nhi\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .incomplete);
}

test "decodeInPlace: malformed hex size" {
    var buf = "zz\r\nhello\r\n0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .malformed);
}

test "decodeInPlace: malformed missing data CRLF" {
    var buf = "5\r\nhelloXX0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 0) == .malformed);
}

test "decodeInPlace: too_large" {
    var buf = "5\r\nhello\r\n0\r\n\r\n".*;
    try std.testing.expect(decodeInPlace(&buf, 4) == .too_large);
}
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `zig build test --summary all`
Expected: FAIL — `decodeInPlace` / `DecodeResult` not defined.

- [ ] **Step 3: Implement `DecodeResult` + `decodeInPlace`**

Add to `src/http/chunked.zig` (above the test block; keep the existing encode API untouched):

```zig
pub const DecodeResult = union(enum) {
    /// Fully decoded. body_len = decoded bytes at buf[0..body_len];
    /// consumed = encoded bytes eaten (chunk sizes + data + CRLFs + terminator + trailers).
    done: struct { body_len: usize, consumed: usize },
    /// Buffer lacks a complete chunked body — read more and retry.
    incomplete,
    /// Malformed chunk framing → 400.
    malformed,
    /// Decoded length would exceed `max` → 413.
    too_large,
};

/// Decode a chunked request body IN PLACE. `buf` starts at the first chunk-size
/// line. On `.done`, the decoded body is buf[0..body_len]; bytes at
/// buf[consumed..] (a pipelined next request) are untouched. `max` caps decoded
/// length (0 = unbounded). Tolerates chunk extensions (`<hex>;...`) and trailer
/// headers after the 0-chunk (both skipped, not surfaced).
///
/// TWO-PASS and REPEAT-SAFE: pass 1 validates framing + measures WITHOUT writing,
/// so calling this repeatedly on a growing buffer (incremental reads) never
/// corrupts the input — `.incomplete`/`.malformed`/`.too_large` leave `buf`
/// untouched. Only a complete body triggers pass 2 (the in-place compaction).
pub fn decodeInPlace(buf: []u8, max: usize) DecodeResult {
    // --- Pass 1: validate + measure, NO mutation ---
    var i: usize = 0;
    var total: usize = 0;
    const consumed = blk: {
        while (true) {
            const line_end = std.mem.indexOfPos(u8, buf, i, "\r\n") orelse return .incomplete;
            var size_end = line_end;
            if (std.mem.indexOfScalarPos(u8, buf[0..line_end], i, ';')) |semi| size_end = semi;
            const size_tok = buf[i..size_end];
            if (size_tok.len == 0) return .malformed;
            const size = std.fmt.parseInt(usize, size_tok, 16) catch return .malformed;
            const data_start = line_end + 2;
            if (size == 0) {
                // last chunk: skip trailer header lines to the final blank line.
                var j = data_start;
                while (true) {
                    const te = std.mem.indexOfPos(u8, buf, j, "\r\n") orelse return .incomplete;
                    if (te == j) break :blk te + 2; // empty line → end of body
                    j = te + 2;
                }
            }
            if (data_start + size + 2 > buf.len) return .incomplete;
            if (buf[data_start + size] != '\r' or buf[data_start + size + 1] != '\n') return .malformed;
            if (max != 0 and total + size > max) return .too_large;
            total += size;
            i = data_start + size + 2;
        }
    };

    // --- Pass 2: compact in place (forward copy, dest <= src) ---
    var ri: usize = 0;
    var w: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, buf, ri, "\r\n").?;
        var size_end = line_end;
        if (std.mem.indexOfScalarPos(u8, buf[0..line_end], ri, ';')) |semi| size_end = semi;
        const size = std.fmt.parseInt(usize, buf[ri..size_end], 16) catch unreachable;
        const data_start = line_end + 2;
        if (size == 0) break;
        std.mem.copyForwards(u8, buf[w .. w + size], buf[data_start .. data_start + size]);
        w += size;
        ri = data_start + size + 2;
    }
    return .{ .done = .{ .body_len = w, .consumed = consumed } };
}
```

Note: pass 1 leaves `buf` byte-for-byte unchanged, so `readBody`'s read→decode loop can call `decodeInPlace` on each partial buffer safely until it returns `.done`.

- [ ] **Step 4: Run tests — verify they pass**

Run: `zig build test --summary all`
Expected: PASS, all 10 decoder tests green.

- [ ] **Step 5: Commit**

```bash
git add src/http/chunked.zig
git commit -m "feat(http): in-place chunked request body decoder"
```

---

### Task 2: Parser field + threaded backend integration

Add `Parsed.body_consumed`, remove the threaded 411, decode chunked in threaded `readBody`, add the 400 error.

**Files:**
- Modify: `src/http/parser.zig` (`Parsed` struct ~:28-33; set in `parseHead` return — leave default)
- Modify: `src/server.zig` (delete 411 `:657-661`; `readBody` `:949-962`; `consumed` `:667`; `RequestError` + `terminalResponse` `:964+`)
- Test: `src/server.zig` (e2e test block — mirror existing keep-alive body tests)

**Interfaces:**
- Consumes: `chunked.decodeInPlace` + `DecodeResult` (Task 1).
- Produces: `parser.Parsed.body_consumed: usize` (default 0; = encoded body length); `error.MalformedBody` in `RequestError`.

- [ ] **Step 1: Add `body_consumed` to `Parsed`**

In `src/http/parser.zig`, add to the `Parsed` struct (after `head_len`):

```zig
    /// Encoded body bytes after the head: the Content-Length value, or the full
    /// encoded length of a chunked body. The stream advances by
    /// `head_len + body_consumed`. parseHead leaves 0; readBody sets it.
    body_consumed: usize = 0,
```

- [ ] **Step 2: Write failing threaded e2e tests**

In the `src/server.zig` test block, mirror the existing "keep-alive: chunked request body is rejected with 411" test (search for it ~`:1046`) but invert the expectation. Add a handler that echoes `ctx.req.body`. Two tests:

```zig
// (a) chunked POST is decoded; body echoed; keep-alive survives.
//     Request: "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
//     Expect: 200, response body "hello world", then a SECOND request on the same conn succeeds.
// (b) malformed chunk → 400.
//     Request body framing: "zz\r\n..." → expect "400".
```

Write these using the same loopback/ConnReader harness the existing 411 test uses (reuse its server setup, just change the request bytes + assertions). Replace the OLD 411 test (it is now wrong) with test (a).

- [ ] **Step 3: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL (still 411 / body not decoded).

- [ ] **Step 4: Remove the threaded 411 block**

In `src/server.zig` delete (`:657-661`):

```zig
                // Chunked request bodies are unsupported: reject and close.
                if (parsed.request.isChunked()) {
                    _ = writeResponse(w, Response.fromStatus(.length_required), false);
                    break;
                }
```

- [ ] **Step 5: Add `MalformedBody` error + 400 mapping**

In `src/server.zig`, add `MalformedBody` to the `RequestError` set (find its definition — search `RequestError = error{`), and in `terminalResponse` (`:965+`) add:

```zig
        error.MalformedBody => _ = writeResponse(w, Response.fromStatus(.bad_request), false),
```

- [ ] **Step 6: Decode chunked in threaded `readBody`**

Replace `readBody` (`src/server.zig:949-962`) with a version that branches on chunked and sets `body_consumed` on BOTH paths:

```zig
fn readBody(cr: *ConnReader, parsed: *parser.Parsed, max_body: usize, read_to: Io.Timeout) RequestError!void {
    if (parsed.request.isChunked()) {
        const max = max_body; // bounds decoded length (0 = unbounded)
        while (true) {
            const enc = cr.buffered()[parsed.head_len..];
            switch (chunked.decodeInPlace(@constCast(enc), max)) {
                .done => |d| {
                    parsed.request.body = cr.buffered()[parsed.head_len .. parsed.head_len + d.body_len];
                    parsed.body_consumed = d.consumed;
                    return;
                },
                .incomplete => cr.fill(read_to) catch |e| switch (e) {
                    error.Timeout => return error.Timeout,
                    error.BufferFull => return error.BodyTooLarge,
                    error.Closed => return error.Closed,
                },
                .malformed => return error.MalformedBody,
                .too_large => return error.BodyTooLarge,
            }
        }
    }
    const clen = parsed.request.contentLength() orelse return;
    const buf_bound = cr.buf.len - parsed.head_len;
    const limit = if (max_body == 0) buf_bound else @min(max_body, buf_bound);
    if (clen > limit) return error.BodyTooLarge;
    while (cr.buffered().len < parsed.head_len + clen) {
        cr.fill(read_to) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.BufferFull => return error.BodyTooLarge,
            error.Closed => return error.Closed,
        };
    }
    parsed.request.body = cr.buffered()[parsed.head_len .. parsed.head_len + clen];
    parsed.body_consumed = clen;
}
```

Add `const chunked = @import("http/chunked.zig");` near the top imports of `src/server.zig` if not already imported (check first; the outbound path may already import it). Note: `decodeInPlace` needs a mutable slice — `cr.buffered()` returns `[]const u8`, so `@constCast` is used because the decode mutates the read buffer in place (the underlying buffer IS mutable; `buffered()` just types it const). Verify `cr.buf` is the mutable backing and that `@constCast` here is sound (it is — the bytes are owned by the ConnReader's mutable buffer).

- [ ] **Step 7: Use `body_consumed` for the consumed calc**

In `src/server.zig` `handleConn` (`:667`), change:

```zig
                const consumed = parsed.head_len + parsed.body_consumed;
```

- [ ] **Step 8: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS, threaded chunked e2e + malformed-400 green, Content-Length tests unaffected.

- [ ] **Step 9: Commit**

```bash
git add src/http/parser.zig src/server.zig
git commit -m "feat(server): decode inbound chunked request bodies (threaded)"
```

---

### Task 3: Evented backend integration

Remove the evented 411, decode chunked in evented `readBody`, advance `r_start` by encoded length.

**Files:**
- Modify: `src/reactor/conn.zig` (delete 411 `:294-296`; `RequestError` `ChunkedNotSupported` `:81` + mapping `:473`; `readBody` `:292-338`; advance `:493`)
- Test: `src/reactor/conn.zig` (fake-transport test block)

**Interfaces:**
- Consumes: `chunked.decodeInPlace` + `DecodeResult` (Task 1); `parser.Parsed.body_consumed` (Task 2).

- [ ] **Step 1: Write failing evented tests**

In the `src/reactor/conn.zig` test block, replace the existing "conn: step — chunked transfer-encoding → 411 length_required" test (~`:873`) with decode tests. Mirror that test's fake-transport + conn setup. Three tests:

```zig
// (a) chunked POST decoded in one read: body == "hello world"; step returns the
//     dispatched/written response (200), not 411.
// (b) split delivery: feed the head + first chunk on read #1 (decode → .need_more →
//     step returns .want_read), then the rest on read #2 → decode .done → 200.
//     Asserts incremental decode works.
// (c) malformed chunk → 400 (error.Malformed path).
```

Use the existing fake transport that can return queued reads / `.would_block` (the sparse-SSE and 411 tests already use one — reuse it).

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL (still 411).

- [ ] **Step 3: Remove the evented 411 + error variant**

In `src/reactor/conn.zig`:
- Delete the rejection (`:294-296`):
  ```zig
          // Reject chunked transfer-encoding (v1.1 → 411 in Task 5).
          if (p.request.isChunked()) {
              return .{ .failed = error.ChunkedNotSupported };
          }
  ```
- Remove `ChunkedNotSupported,` from the `RequestError` set (`:81`).
- Remove its mapping line in the `.failed` switch (`:473`): `error.ChunkedNotSupported => .length_required,`.

- [ ] **Step 4: Decode chunked in evented `readBody`**

In `src/reactor/conn.zig` `readBody` (`:292-338`), add a chunked branch before the Content-Length logic, and set `body_consumed` on the Content-Length path too. Insert after the (now-removed) 411 site:

```zig
    fn readBody(self: *Conn, t: Transport, p: parser.Parsed) ParseOutcome {
        if (p.request.isChunked()) {
            self.state = .reading_body;
            const head_abs = self.r_start + p.head_len;
            const max = self.max_body_size; // bounds decoded length (0 = unbounded)
            while (true) {
                const enc = self.read_buf[head_abs..self.r_end];
                switch (chunked.decodeInPlace(enc, max)) {
                    .done => |d| {
                        var result = p;
                        result.request.body = self.read_buf[head_abs .. head_abs + d.body_len];
                        result.body_consumed = d.consumed;
                        return .{ .parsed = result };
                    },
                    .malformed => return .{ .failed = error.Malformed },
                    .too_large => return .{ .failed = error.BodyTooLarge },
                    .incomplete => {
                        if (self.r_end == self.read_buf.len) return .{ .failed = error.BodyTooLarge };
                        const space = self.read_buf[self.r_end..];
                        switch (t.read(space)) {
                            .ok => |n| {
                                if (n == 0) return .closed;
                                self.r_end += n;
                            },
                            .would_block => return .need_more,
                            .closed => return .closed,
                        }
                    },
                }
            }
        }

        // No Content-Length → body is empty; done.
        const clen = p.request.contentLength() orelse {
            var result = p;
            result.request.body = "";
            result.body_consumed = 0;
            return .{ .parsed = result };
        };

        const buf_bound = self.read_buf.len - (self.r_start + p.head_len);
        const limit = if (self.max_body_size == 0) buf_bound else @min(self.max_body_size, buf_bound);
        if (clen > limit) return .{ .failed = error.BodyTooLarge };

        self.state = .reading_body;
        const body_end = self.r_start + p.head_len + clen;
        while (self.r_end < body_end) {
            const space = self.read_buf[self.r_end..];
            switch (t.read(space)) {
                .ok => |n| {
                    if (n == 0) return .closed;
                    self.r_end += n;
                },
                .would_block => return .need_more,
                .closed => return .closed,
            }
        }
        var result = p;
        const head_abs = self.r_start + p.head_len;
        result.request.body = self.read_buf[head_abs .. head_abs + clen];
        result.body_consumed = clen;
        return .{ .parsed = result };
    }
```

Add `const chunked = @import("../http/chunked.zig");` to the imports at the top of `src/reactor/conn.zig` if not already present (check — the outbound chunked framing from gap #1 likely already imports it; reuse the existing alias). `read_buf` is `[]u8` (mutable) so `decodeInPlace` takes it directly — no `@constCast` needed here.

- [ ] **Step 5: Advance `r_start` by encoded length**

In `src/reactor/conn.zig` the `.parsed` branch (`:493`), change:

```zig
                            const consumed = p.head_len + p.body_consumed;
                            self.r_start += consumed;
```

- [ ] **Step 6: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS — evented chunked one-shot + split-delivery + malformed-400 green. (3 Linux skips on mac unchanged.)

- [ ] **Step 7: Commit**

```bash
git add src/reactor/conn.zig
git commit -m "feat(reactor): decode inbound chunked request bodies (evented)"
```

---

### Task 4: Docs + CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document in `docs/evented-backend.md`**

Add a short subsection: inbound `Transfer-Encoding: chunked` request bodies are now decoded on both backends and delivered to handlers as the normal `ctx.req.body` slice. Bounded by `max_body_size` (decoded) and the read buffer (encoded); chunk extensions and trailer headers are tolerated but not surfaced; malformed framing → 400, over-limit → 413. (Replaces the previous 411 behavior.)

- [ ] **Step 2: CHANGELOG entry**

Under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- Inbound `Transfer-Encoding: chunked` request bodies are now decoded on both backends (previously rejected with 411). Bounded by `max_body_size`; chunk extensions and trailers tolerated; malformed framing → 400.
```

(If `### Changed` fits better given it removes the 411, use that — match the changelog's existing convention.)

- [ ] **Step 3: Run + commit**

Run: `zig build test --summary all` (expect green, no count change from docs)

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(http): document inbound chunked request body decoding"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 235 + decoder unit tests + per-backend e2e/integration tests; the two old "→ 411" tests are now "→ decoded" tests.
- Spec coverage: T1 decoder (8 spec test cases) + DecodeResult; T2 parser field + threaded decode + 400 + consumed; T3 evented decode + r_start advance + split-delivery; T4 docs/CHANGELOG. All spec sections covered.
- Regression: Content-Length requests unchanged (`body_consumed == body.len`); pipelining intact (advance by encoded length).
- Manual: `curl -v -H "Transfer-Encoding: chunked" --data-binary @file URL` → 200 echo; malformed → 400.
