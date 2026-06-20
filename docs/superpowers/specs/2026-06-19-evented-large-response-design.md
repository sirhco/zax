# Design — large buffered responses on the evented backend

**Status:** approved 2026-06-19. Branch `feat/evented-large-response` (off main `4d0a6d8`).

## Problem

A buffered (non-streamed) response on the **evented** backend whose serialized size
(status line + headers + **body**) exceeds the per-connection `write_buf`
(`write_buffer_size`, default 8 KB) overflows and is **replaced with a 500 + connection
close**. Confirmed:

- `serializeResponse` (`src/reactor/conn.zig:382-393`) serializes the whole response into
  `std.Io.Writer.fixed(self.write_buf)`; overflow → `error.ResponseTooLarge`.
- The dispatch buffered branch (`conn.zig:567-589`) catches that error and synthesizes a
  `500` + `close_after_write`.

So any `Response.json` / `Response.text` over ~8 KB returns **500 on evented while working
on threaded** (the threaded path writes to a flushing `Io.Writer` — `server.zig:830` — with
no fixed cap). This is the reported "errors on large JSON response bodies" bug.

The response body already lives fully in memory (`resp.body`, an arena-allocated slice valid
through the `.writing` state) — copying it into the fixed `write_buf` is the only reason for
the cap.

## Goal

Send buffered responses of any size on the evented backend, without copying the body, by
pumping the body in place across writable events. Reuse the existing `.writing` state and
`pumpWrite` partial-write/backpressure machinery.

Non-goals: the threaded backend (already works); streamed responses (`streamPull`/`ssePull`,
already unbounded); a response-size cap (the body is already in handler memory — same as
threaded); changing the fast path for responses that fit `write_buf`.

### Decisions (confirmed with Chris)
- **Split head/body, pump the body in place — only when oversized.** Responses that fit
  `write_buf` keep today's one-shot serialize + single pump (fast path unchanged).
- **No copy:** the oversized path serializes only the head into `write_buf`, then pumps
  `resp.body` directly from the arena slice. Zero extra memory beyond the handler's body.
- **No response-size cap.** The body is already fully in memory; matches threaded semantics.
- **Evented-only.**

## Key facts

- `pumpWrite` (`conn.zig:417-427`) writes `self.write_buf[self.w_off..self.w_len]`, advancing
  `w_off` on partial writes and returning `.want_write` until `w_off == w_len` → `.wrote_all`.
  The source buffer is hardcoded to `self.write_buf` — the one place needing indirection.
- `.writing` `wrote_all`, non-streaming path (`conn.zig:740-765`): `served++`, then either
  close (`close_after_write`) or keep-alive (reset: `close_after_write=false`,
  `stream_chunked=false`, `arena.reset(.retain_capacity)`, `compact`, → `reading_head`).
- The pull-stream `wrote_all` continuation (head-then-chunks) lives just above (`~:681-738`),
  guarded by `pull_streamer != null` — the buffered body-phase logic sits AFTER it.
- `Response.write` (`response.zig`) = `writeHeaders(w, body.len)` + `writeAll(body)`. The
  head-only serializer is `writeHeaders(w, content_length)` — it emits `content-length`.
- `arena` valid through `.writing`; reset only in the keep-alive block after `wrote_all`.
- A fresh `Conn` is constructed per accept (`worker.zig:475 Conn.init(...)`), so new conn
  fields default cleanly each connection; only the keep-alive (pipelined) path needs explicit
  reset.

## Components

### Modified: `src/http/response.zig`

Ensure the head-only serializer is callable from the reactor: confirm `writeHeaders` is `pub`
(it is called by `write`); if not, make it `pub`. No behavior change.

### Modified: `src/reactor/conn.zig`

New `Conn` fields:
```zig
/// Large buffered response: the body to pump in place after the head (the
/// handler's arena slice — never copied). Empty when not in use.
pending_body: []const u8 = &.{},
/// True once the head has been written and we are pumping `pending_body`.
body_phase: bool = false,
```

`pumpWrite` (`:418`) — drain from the active source:
```zig
const remaining = if (self.body_phase)
    self.pending_body[self.w_off..self.w_len]
else
    self.write_buf[self.w_off..self.w_len];
```
(The body branch is `[]const u8`; `t.write` takes `[]const u8`, so both coerce.)

New head-with-content-length helper (mirrors `serializeHead` but emits content-length):
```zig
fn serializeHeadWithLen(self: *Conn, resp: Response) error{ResponseTooLarge}!usize {
    var w = std.Io.Writer.fixed(self.write_buf);
    resp.writeHeaders(&w, resp.body.len) catch {
        self.w_len = w.end; self.w_off = 0;
        return error.ResponseTooLarge;
    };
    self.w_len = w.end; self.w_off = 0;
    return self.w_len;
}
```

Dispatch buffered branch overflow handler (`conn.zig:583-588`) — replace the
"synthesize 500" with the split path, falling back to 500 only if the **head** doesn't fit:
```zig
} else |_| {
    // Response too large for write_buf. Send the head from write_buf, then pump
    // the body directly from resp.body (no copy). Only a head that itself
    // overflows falls back to 500.
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
(The fast path — `serializeResponse` succeeds — is unchanged.)

`.writing` `wrote_all`, after the `pull_streamer` block and BEFORE the "Normal path"
(`conn.zig:740`):
```zig
// Large buffered response: head fully written → pump the body in place.
if (self.pending_body.len > 0 and !self.body_phase) {
    self.body_phase = true;
    self.w_off = 0;
    self.w_len = self.pending_body.len;
    continue; // pump the body via pumpWrite
}
```
When the body completes (`body_phase == true` → `wrote_all`), control falls through to the
Normal path. In the keep-alive reset block (`conn.zig:748-751`), also clear:
```zig
self.pending_body = &.{};
self.body_phase = false;
```
(Close path discards the Conn, so no reset needed there.)

## Data flow (evented, oversized buffered response)

```
dispatch → buffered resp, serializeResponse overflows
  → serializeHeadWithLen(resp) into write_buf      // head + content-length
       └ head overflows too → 500 + close (rare)
  → pending_body = resp.body; state = .writing
  → pump head (write_buf) … wrote_all
  → pending_body set & !body_phase → body_phase = true; w_off=0; w_len=body.len
  → pump body (resp.body) across writable events … partial writes advance w_off … wrote_all
  → Normal path: served++; keep-alive (clear pending_body/body_phase, arena.reset) or close
```

## Error handling

- Head overflows `write_buf` (pathological huge headers) → existing 500 + close.
- Peer closes mid-body → `pumpWrite` returns `.closed` → `.done_close` (existing path).
- Write-stall deadline still applies (`.writing` arms it on entry — unchanged).

## Behavior change & test impact

- Buffered responses > ~8 KB now succeed on evented (200 + full body) instead of 500.
- Responses that fit `write_buf` are byte-for-byte unchanged (fast path).
- Streamed responses unchanged. Threaded backend untouched.

## Testing

Unit (`src/reactor/conn.zig`, fake transport; mirror the pull-streamer partial-write tests
like "mid-chunk backpressure resume" ~:1611):
1. **Large buffered response sends fully:** dispatch a response whose body far exceeds
   `write_buf` (e.g. write_buffer_size 64, body 500 bytes). Drive `step`/`pumpWrite` with a
   fake transport that returns SMALL partial writes (e.g. 16 bytes) to force many
   `.want_write` cycles. Assert: the full serialized response (head with correct
   `content-length` + entire body, in order) is emitted across the writes, status 200, NO 500,
   no bytes lost/duplicated.
2. **Keep-alive after a large response:** persistent request → large response fully sent →
   `pending_body`/`body_phase` cleared, arena reset, a SECOND request on the same conn is
   served (proves the body-phase state is reset).
3. **Fast path unchanged:** a small response that fits `write_buf` takes the one-shot path
   (`pending_body` stays empty), still correct.
4. **Head-too-large → 500:** a response with headers exceeding `write_buf` (tiny buffer) →
   500 + close (the rare fallback still holds).

Evented e2e (loopback via `serveEvented`, if the existing harness supports it): a handler
returning a ~50 KB `Response.json` over HTTP/1.1 → client receives the complete body + 200.

## Verification

- `zig build test --summary all` — baseline 257/260 mac (3 Linux-epoll skips); after this
  feature, baseline + new tests, 0 failures, on mac (kqueue) and Linux (epoll/Docker).
- Manual: `curl` a large-JSON endpoint under `serveEvented` → full body + 200 (was 500).

## Docs

- `docs/evented-backend.md`: note buffered responses of any size are supported on the evented
  backend (head sent from the write buffer, body streamed in place); update any
  statement implying a response-size limit.
- `CHANGELOG.md`: entry under `[Unreleased]` (`### Fixed`).
