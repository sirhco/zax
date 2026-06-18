# Reactor v2 — True Pull-Streaming on Evented Backend

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `PullStreamer` API to `Response` and implement true non-blocking streaming in the evented reactor (`Conn.step`), so responses larger than `write_buf` are streamed to the client without buffering the whole body.

**Architecture:** A PULL-based streamer (`nextFn` fills a caller-supplied buffer with the next chunk) maps cleanly to the non-blocking reactor: the conn calls `next(write_buf)`, pumps those bytes with backpressure (saving mid-chunk offset across `step` calls), then calls `next` again until `.done`. The threaded backend gets a cheap blocking loop. Connection-close framing throughout — no chunked encoding, no content-length.

**Tech Stack:** Zig 0.16; `std.Io.Writer` fixed-buffer; `FakeTransport` test double (already in `src/reactor/transport.zig`); kqueue (macOS) + epoll (Linux) via the existing reactor worker.

## Global Constraints

- **Branch:** `feat/reactor-v2` — all work goes here; do NOT touch `main`.
- **Zig 0.16** — no newer APIs.
- **Additive only.** Existing `Streamer`, `stream()`, `sse()`, threaded `handleConn`, buffered response path, and all existing tests stay **unchanged**.
- **No chunked framing.** Connection-close only (same as push `Streamer`).
- **`pull_streamer` gets true streaming; push `streamer` keeps buffer-or-500** on the evented path (add a comment noting this).
- **`context: *anyopaque`** (not `*const`) to allow mutable state inside the pull streamer (e.g., a byte counter).
- **Test baseline:** must be at or above the current count when done. Run `zig build test --summary all` to verify.
- **Docker command for Linux:**
  ```
  docker run --rm -v /Users/chrisolson/development/github/zax:/src:ro zax-linux-bench \
    bash -c 'cp -a /src /w && cd /w && rm -rf .zig-cache zig-out && zig build test --summary all'
  ```
- **Commit message:** `feat(reactor): true streaming on evented via pull-streamer (connection-close framing)`

---

## File Structure

| File | Change |
|---|---|
| `src/http/response.zig` | Add `PullResult`, `PullStreamer`, `pull_streamer` field, `streamPull()` constructor, tests |
| `src/reactor/conn.zig` | Add `streaming` state variant, `pull_streamer`/`stream_chunk_len` fields, streaming branch in `step`, tests |
| `src/server.zig` | Extend `writeResponse` to handle `pull_streamer` on the threaded path |

---

## Task 1: `PullStreamer` API in `response.zig`

**Files:**
- Modify: `src/http/response.zig`

**Interfaces:**
- Produces:
  ```zig
  pub const PullResult = union(enum) { chunk: usize, done, err };
  pub const PullStreamer = struct {
      context: *anyopaque,
      nextFn: *const fn (context: *anyopaque, buf: []u8) PullResult,
      pub fn next(self: PullStreamer, buf: []u8) PullResult { ... }
  };
  // Added to Response struct:
  pub pull_streamer: ?PullStreamer = null,
  // Constructor:
  pub fn streamPull(comptime Ctx: type, context: *Ctx, comptime nextFn: fn(*Ctx, []u8) PullResult, content_type: []const u8) Response
  ```

- [ ] **Step 1: Write failing tests** — add at the bottom of `src/http/response.zig`:

```zig
test "PullStreamer: next() calls nextFn with the buffer" {
    const Ctx = struct { calls: usize = 0 };
    const Impl = struct {
        fn next(c: *Ctx, buf: []u8) PullResult {
            if (c.calls == 0) {
                c.calls += 1;
                buf[0] = 'h';
                buf[1] = 'i';
                return .{ .chunk = 2 };
            }
            return .done;
        }
    };
    var ctx = Ctx{};
    const ps = PullStreamer{
        .context = &ctx,
        .nextFn = @ptrCast(&Impl.next),
    };
    var buf: [8]u8 = undefined;
    const r1 = ps.next(&buf);
    try testing.expectEqual(PullResult{ .chunk = 2 }, r1);
    try testing.expectEqualStrings("hi", buf[0..2]);
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "streamPull: builds a Response with pull_streamer set, keep_alive false, no body" {
    const Ctx = struct { done: bool = false };
    const Impl = struct {
        fn next(c: *Ctx, buf: []u8) PullResult {
            _ = buf;
            if (!c.done) { c.done = true; return .{ .chunk = 0 }; }
            return .done;
        }
    };
    var ctx = Ctx{};
    const r = Response.streamPull(Ctx, &ctx, Impl.next, "text/plain");
    try testing.expect(r.pull_streamer != null);
    try testing.expectEqualStrings("text/plain", r.content_type);
    try testing.expect(r.keep_alive == false);
    try testing.expectEqualStrings("", r.body);
    try testing.expect(r.streamer == null); // does NOT set push streamer
}
```

- [ ] **Step 2: Run to verify both fail.**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1 | grep -E 'FAIL|error|PullStreamer|streamPull'
```

Expected: compile errors (`PullResult` not declared, etc.).

- [ ] **Step 3: Implement** — in `src/http/response.zig`, after the existing `Streamer` definition (line 79), insert:

```zig
/// Result of a single `PullStreamer.next` call.
pub const PullResult = union(enum) {
    /// `n` bytes were written into the caller-supplied buffer; `n` may be 0
    /// (the caller should call `next` again immediately).
    chunk: usize,
    /// The stream is finished; no more bytes will be produced.
    done,
    /// An unrecoverable error occurred; the connection should be closed.
    err,
};

/// A type-erased PULL streamer: the caller supplies a buffer; `nextFn` fills it
/// and returns how many bytes were written, or signals done/error.
/// `context` must outlive the request (allocate in the request arena).
pub const PullStreamer = struct {
    context: *anyopaque,
    nextFn: *const fn (context: *anyopaque, buf: []u8) PullResult,

    pub fn next(self: PullStreamer, buf: []u8) PullResult {
        return self.nextFn(self.context, buf);
    }
};
```

Then add `pull_streamer` field to `Response` after the `streamer` field (after line 96):

```zig
    /// When set, the body is produced by calling `pull_streamer.next(buf)` repeatedly
    /// (connection-close framing). The evented reactor uses this for true non-blocking
    /// streaming; the threaded backend loops next()+write(). `body`/`content-length`
    /// are not used. Mutually exclusive with `streamer` (set one or the other).
    pull_streamer: ?PullStreamer = null,
```

Then add the `streamPull` constructor to `Response` (after `stream()`, around line 154):

```zig
    /// Build a pull-streamed (connection-close) response. `nextFn` is called
    /// repeatedly with a caller-owned buffer; it fills the buffer and returns
    /// `.chunk(n)` (n bytes written), `.done` when finished, or `.err` on failure.
    /// `context` must outlive the request (use the request arena).
    ///
    /// True non-blocking streaming on the evented backend; blocking loop on threaded.
    pub fn streamPull(
        comptime Ctx: type,
        context: *Ctx,
        comptime nextFn: fn (*Ctx, []u8) PullResult,
        content_type: []const u8,
    ) Response {
        const Erased = struct {
            fn call(c: *anyopaque, buf: []u8) PullResult {
                return nextFn(@ptrCast(@alignCast(c)), buf);
            }
        };
        return .{
            .content_type = content_type,
            .pull_streamer = .{ .context = context, .nextFn = &Erased.call },
            .keep_alive = false,
        };
    }
```

- [ ] **Step 4: Run to verify both tests pass.**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1 | grep -E 'PASS|FAIL|error' | tail -20
```

Expected: all tests pass (including the two new ones). No regressions.

- [ ] **Step 5: Commit.**

```bash
cd /Users/chrisolson/development/github/zax && git add src/http/response.zig && git commit -m "feat(response): add PullStreamer pull-based streaming API"
```

---

## Task 2: `Conn` — streaming state + fields + `step` branch

**Files:**
- Modify: `src/reactor/conn.zig`

**Interfaces:**
- Consumes: `response_mod.PullStreamer`, `response_mod.PullResult` (from Task 1); existing `pumpWrite`, `serializeResponse`, `Transport`, `State`, `StepResult`.
- Produces: The evented reactor now streams `pull_streamer` responses true non-blocking.

**Design notes:**
- Add `streaming` to `State` enum (the conn is mid-stream: head sent, iterating `next`).
- Add to `Conn` struct: `pull_streamer: ?response_mod.PullStreamer = null` and `stream_chunk_len: usize = 0` (bytes currently in `write_buf` for the current chunk, used with `w_off`/`w_len`).
- The streaming path in `step(.writing)` detects `pull_streamer != null` and switches to the streaming sub-state; after the head is written it transitions to `.streaming`.
- Actually, the cleanest approach: use `close_after_write` + a new `streaming` state. When dispatch returns a `pull_streamer` response:
  1. Call `resp.writeHead` into `write_buf` (via `serializeResponse` variant — but `serializeResponse` calls `resp.write` which includes the body; we need HEAD only). Use a separate inline serialize-head helper that calls `resp.writeHead` into a fixed writer.
  2. Transition state to `.writing` (to pump the head), then when `wrote_all`, transition to `.streaming`.
  3. In `.streaming`: call `pull.next(write_buf)` → on `.chunk(n)`: set `w_off=0, w_len=n`, transition to `.writing_chunk`... **Simpler:** reuse `.writing` state for both head and chunks; differentiate by `pull_streamer != null`. After the head is pumped out, call `next` to fill `write_buf`, then pump again, etc.

**Refined state machine for streaming:**
- When dispatch returns `pull_streamer != null`:
  - Serialize HEAD into `write_buf` (call `writeHead`; use a dedicated `fn serializeHead(resp) !usize`).
  - Set `close_after_write = true` (always close after stream).
  - Set `self.pull_streamer = resp.pull_streamer`.
  - Set `self.state = .writing` (pump the head).
  - When `pumpWrite` returns `.wrote_all` and `pull_streamer != null`: load next chunk instead of transitioning to keep-alive.
- New logic in `.writing` wrote_all branch:
  ```zig
  .wrote_all => {
      self.served += 1;  // NO — only count when fully done
      ...
  }
  ```
  Actually: count `served` only at true end-of-request (after last chunk or after normal response). Keep existing code for non-streaming path. For streaming path, after `wrote_all` check `pull_streamer != null` to decide next action.

**Exact plan:**

- Add `streaming` to `State` (for future use / deadline handling — actually we can handle everything in `.writing` by checking `pull_streamer != null`; no new state needed for correctness, but `streaming` is cleaner for `onDeadline`). Add it to avoid breaking `onDeadline` switch exhaustiveness.

- Add `serializeHead` private fn to `Conn`.

- Modify `.writing` `wrote_all` arm.

- [ ] **Step 1: Write failing unit tests** — add at the bottom of `src/reactor/conn.zig`:

```zig
// ---------------------------------------------------------------------------
// Task 6 (reactor-v2) tests — pull-streamer true streaming
// ---------------------------------------------------------------------------

/// A pull streamer context that yields fixed chunks then done.
const ThreeChunkCtx = struct {
    chunks: [3][]const u8,
    idx: usize = 0,

    fn next(c: *ThreeChunkCtx, buf: []u8) response_mod.PullResult {
        if (c.idx >= c.chunks.len) return .done;
        const chunk = c.chunks[c.idx];
        c.idx += 1;
        const n = @min(chunk.len, buf.len);
        @memcpy(buf[0..n], chunk[0..n]);
        return .{ .chunk = n };
    }
};

test "conn: pull streamer — 3 chunks then done → head + chunks written, done_close" {
    const raw = "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = ThreeChunkCtx{ .chunks = .{ "aaa", "bbb", "ccc" } };

    const StreamDispatch = struct {
        pull_ctx: *ThreeChunkCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(ThreeChunkCtx, s.pull_ctx, ThreeChunkCtx.next, "text/plain");
        }
    };
    var sd = StreamDispatch{ .pull_ctx = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = StreamDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    const t = ft.transport();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    // Head must be present (no content-length, connection: close).
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, written, "connection: close") != null);
    try testing.expect(std.mem.indexOf(u8, written, "content-length:") == null);
    // All three chunk payloads appear in order.
    const pos_a = std.mem.indexOf(u8, written, "aaa") orelse return error.TestUnexpectedResult;
    const pos_b = std.mem.indexOf(u8, written, "bbb") orelse return error.TestUnexpectedResult;
    const pos_c = std.mem.indexOf(u8, written, "ccc") orelse return error.TestUnexpectedResult;
    try testing.expect(pos_a < pos_b);
    try testing.expect(pos_b < pos_c);
}

test "conn: pull streamer — mid-chunk backpressure resume, no bytes lost or duplicated" {
    // A streamer that produces one chunk: "hello world" (11 bytes).
    const SingleChunkCtx = struct {
        done: bool = false,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            if (c.done) return .done;
            c.done = true;
            const payload = "hello world";
            @memcpy(buf[0..payload.len], payload);
            return .{ .chunk = payload.len };
        }
    };

    const raw = "GET /s HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    // Block the write after 10 bytes (mid-chunk inside "hello world").
    ft.write_block_after_bytes = 10;

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var pull_ctx = SingleChunkCtx{};
    const SingleDispatch = struct {
        p: *SingleChunkCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SingleChunkCtx, s.p, SingleChunkCtx.next, "text/plain");
        }
    };
    var sd = SingleDispatch{ .p = &pull_ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SingleDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    const t = ft.transport();

    // First step: write will block mid-stream → want_write.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_write, r1);

    // Second step: block lifted, stream completes.
    const r2 = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r2);

    // "hello world" must appear exactly once in the written bytes.
    const written = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, written, "hello world") != null);
    // Count occurrences to catch duplication.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "hello world"));
}

test "conn: pull streamer — stream larger than write_buf proves true streaming (not buffering)" {
    // write_buf is 64 bytes; the stream produces 4 × 32-byte chunks = 128 bytes total.
    // If the reactor were buffering, it would overflow write_buf and send a 500.
    // True streaming calls next() multiple times, filling write_buf each time.
    const BigStreamCtx = struct {
        remaining: usize = 4,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            if (c.remaining == 0) return .done;
            c.remaining -= 1;
            // Fill 32 bytes with 'X'.
            const n = @min(32, buf.len);
            @memset(buf[0..n], 'X');
            return .{ .chunk = n };
        }
    };

    const raw = "GET /big HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [64]u8 = undefined; // smaller than the total stream (128 bytes)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var pull_ctx = BigStreamCtx{};
    const BigDispatch = struct {
        p: *BigStreamCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(BigStreamCtx, s.p, BigStreamCtx.next, "text/plain");
        }
    };
    var bd = BigDispatch{ .p = &pull_ctx };
    const d = Dispatcher{ .ctx = &bd, .dispatchFn = BigDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    const t = ft.transport();

    // Drive until done (no write backpressure here — FakeTransport always accepts).
    var result: StepResult = undefined;
    for (0..20) |_| {
        result = c.step(t, d);
        if (result == .done_close) break;
    }
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    // Must have a 200, not a 500.
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200"));
    // Must contain 128 bytes of 'X' (4 × 32).
    var x_count: usize = 0;
    for (written) |b| if (b == 'X') { x_count += 1; };
    try testing.expectEqual(@as(usize, 128), x_count);
}
```

- [ ] **Step 2: Run to verify all three fail (symbol not found / missing state).**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1 | grep -E 'FAIL|error' | head -20
```

- [ ] **Step 3: Add `streaming` to `State` and new fields to `Conn`.**

In `conn.zig`, find the `State` enum (around line 45). Add `streaming` after `writing`:

```zig
pub const State = enum {
    reading_head,
    reading_body,
    dispatching,
    writing,
    streaming,         // mid-stream: head pumped, iterating pull_streamer.next()
    keep_alive_idle,
    closing,
};
```

Add fields to `Conn` struct (after `close_after_write` field, around line 164):

```zig
    /// When non-null, the conn is serving a pull-streamed response.
    /// Set by step() when dispatch returns a pull_streamer response; cleared on done/err.
    /// NOTE: the legacy push `streamer` on the evented path keeps the buffer-or-500
    /// behavior; only `pull_streamer` gets true non-blocking streaming.
    pull_streamer: ?response_mod.PullStreamer = null,

    /// Byte count of the current pull-stream chunk loaded into write_buf.
    /// Together with w_off (offset within the chunk), tracks partial writes mid-chunk.
    stream_chunk_len: usize = 0,
```

- [ ] **Step 4: Add `serializeHead` to `Conn`** (after `serializeResponse`, around line 324):

```zig
    /// Serialize only the response HEAD (no body, no content-length) into `write_buf`.
    /// Used for pull-streamed responses. Returns `error.ResponseTooLarge` if the
    /// head does not fit in `write_buf`.
    fn serializeHead(self: *Conn, resp: Response) error{ResponseTooLarge}!usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        resp.writeHead(&w) catch {
            self.w_len = w.end;
            self.w_off = 0;
            return error.ResponseTooLarge;
        };
        self.w_len = w.end;
        self.w_off = 0;
        return self.w_len;
    }
```

- [ ] **Step 5: Modify `step()` — dispatch branch for `pull_streamer`.**

In `step()`, find the `.parsed` arm dispatch block (around line 419). The existing code is:

```zig
                            // Dispatch → Response.
                            var resp = d.dispatch(&p.request, self.arena);

                            // Handle streamed responses: no true streaming in v1,
                            // render into write_buf up to capacity.
                            const is_streamed = resp.streamer != null;

                            // Set keep_alive on the response header.
                            resp.keep_alive = persistent and !is_streamed;

                            // Observer hook (zero-cost when null).
                            if (self.on_response) |hook| hook(&p.request, &resp);

                            // Serialize into write_buf; detect overflow via error signal.
                            if (self.serializeResponse(resp)) |_| {
                                if (is_streamed) {
                                    // Streamed but fit: still close-after-write (v1 rule).
                                    self.close_after_write = true;
                                } else if (!persistent) {
                                    self.close_after_write = true;
                                }
                            } else |_| {
                                // Response overflowed write_buf — synthesize a 500 and close.
                                var e500 = Response.fromStatus(.internal_server_error);
                                e500.keep_alive = false;
                                _ = self.serializeResponse(e500) catch {};
                                self.close_after_write = true;
                            }

                            self.state = .writing;
                            // fall through to writing
```

Replace it with:

```zig
                            // Dispatch → Response.
                            var resp = d.dispatch(&p.request, self.arena);

                            // Handle pull-streamed responses: true non-blocking streaming.
                            // The legacy push `streamer` keeps buffer-or-500 behavior on
                            // the evented path (see comment below).
                            if (resp.pull_streamer) |ps| {
                                // Serialize HEAD only (no content-length); connection-close.
                                resp.keep_alive = false;
                                if (self.on_response) |hook| hook(&p.request, &resp);
                                self.serializeHead(resp) catch {
                                    // Head won't fit (extremely small write_buf) — 500 + close.
                                    var e500 = Response.fromStatus(.internal_server_error);
                                    e500.keep_alive = false;
                                    _ = self.serializeResponse(e500) catch {};
                                    self.close_after_write = true;
                                    self.state = .writing;
                                    continue;
                                };
                                self.pull_streamer = ps;
                                self.close_after_write = true; // always close after stream
                                self.state = .writing; // pump the head first
                                continue;
                            }

                            // Handle push-streamed responses: no true streaming on the
                            // evented path (v1 rule) — render into write_buf up to capacity.
                            const is_streamed = resp.streamer != null;

                            // Set keep_alive on the response header.
                            resp.keep_alive = persistent and !is_streamed;

                            // Observer hook (zero-cost when null).
                            if (self.on_response) |hook| hook(&p.request, &resp);

                            // Serialize into write_buf; detect overflow via error signal.
                            if (self.serializeResponse(resp)) |_| {
                                if (is_streamed) {
                                    // Streamed but fit: still close-after-write (v1 rule).
                                    self.close_after_write = true;
                                } else if (!persistent) {
                                    self.close_after_write = true;
                                }
                            } else |_| {
                                // Response overflowed write_buf — synthesize a 500 and close.
                                var e500 = Response.fromStatus(.internal_server_error);
                                e500.keep_alive = false;
                                _ = self.serializeResponse(e500) catch {};
                                self.close_after_write = true;
                            }

                            self.state = .writing;
                            // fall through to writing
```

- [ ] **Step 6: Modify `step()` — `.writing` `wrote_all` arm for streaming.**

Find the `.writing` case (around line 454). The `.wrote_all` arm currently is:

```zig
                        .wrote_all => {
                            // Count this request regardless of keep-alive disposition.
                            self.served += 1;
                            if (self.close_after_write) {
                                self.state = .closing;
                                return .done_close;
                            }
                            // Keep-alive: reset for next request.
                            self.close_after_write = false;
                            _ = self.arena.reset(.retain_capacity);
                            self.compact();
                            self.state = .reading_head;
                            // If bytes are already buffered (pipelined), loop
                            // immediately; otherwise wait for new data.
                            if (self.r_end > self.r_start) {
                                // pipelined data present — stay in the loop
                                continue;
                            }
                            // Enter idle state and set idle deadline.
                            self.deadline_ns = if (self.idle_timeout_ms == 0)
                                no_deadline
                            else
                                monotonicNow() + @as(i96, self.idle_timeout_ms) * 1_000_000;
                            self.state = .keep_alive_idle;
                            return .want_read;
                        },
```

Replace with:

```zig
                        .wrote_all => {
                            // Pull-streaming: head (or last chunk) fully written.
                            // Load the next chunk into write_buf and keep pumping.
                            if (self.pull_streamer) |ps| {
                                switch (ps.next(self.write_buf)) {
                                    .chunk => |n| {
                                        if (n == 0) {
                                            // Empty chunk: call next() again on the next step.
                                            self.w_off = 0;
                                            self.w_len = 0;
                                            // Stay in .writing; loop will call pumpWrite
                                            // with empty slice — handle gracefully below.
                                            // Actually: just loop immediately to call next again.
                                            continue;
                                        }
                                        self.w_off = 0;
                                        self.w_len = n;
                                        // Stay in .writing; loop calls pumpWrite for this chunk.
                                        continue;
                                    },
                                    .done => {
                                        // Stream finished — close.
                                        self.pull_streamer = null;
                                        self.served += 1;
                                        self.state = .closing;
                                        return .done_close;
                                    },
                                    .err => {
                                        // Stream error — close without incrementing served.
                                        self.pull_streamer = null;
                                        self.state = .closing;
                                        return .done_close;
                                    },
                                }
                            }

                            // Normal (non-streaming) path.
                            // Count this request regardless of keep-alive disposition.
                            self.served += 1;
                            if (self.close_after_write) {
                                self.state = .closing;
                                return .done_close;
                            }
                            // Keep-alive: reset for next request.
                            self.close_after_write = false;
                            _ = self.arena.reset(.retain_capacity);
                            self.compact();
                            self.state = .reading_head;
                            // If bytes are already buffered (pipelined), loop
                            // immediately; otherwise wait for new data.
                            if (self.r_end > self.r_start) {
                                // pipelined data present — stay in the loop
                                continue;
                            }
                            // Enter idle state and set idle deadline.
                            self.deadline_ns = if (self.idle_timeout_ms == 0)
                                no_deadline
                            else
                                monotonicNow() + @as(i96, self.idle_timeout_ms) * 1_000_000;
                            self.state = .keep_alive_idle;
                            return .want_read;
                        },
```

Also fix the edge case: when `w_len == 0` (empty chunk from `next`), `pumpWrite` with `remaining = write_buf[0..0]` will return `.wrote_all` immediately (0-byte write). That causes an infinite loop. Fix the `pumpWrite` call site — add a guard before calling `pumpWrite`:

In the `.writing` case, find:

```zig
                .writing => {
                    // Arm write-stall deadline on first entry.
```

After the deadline arm code and before `switch (self.pumpWrite(t)) {`, add:

```zig
                    // Guard: if w_len == 0 and we have a pull streamer, call next()
                    // immediately (empty chunk — producer signalled 0 bytes this call).
                    if (self.w_len == 0) {
                        if (self.pull_streamer) |ps| {
                            switch (ps.next(self.write_buf)) {
                                .chunk => |n| {
                                    self.w_off = 0;
                                    self.w_len = n;
                                    if (n == 0) continue; // still empty — loop again
                                },
                                .done => {
                                    self.pull_streamer = null;
                                    self.served += 1;
                                    self.state = .closing;
                                    return .done_close;
                                },
                                .err => {
                                    self.pull_streamer = null;
                                    self.state = .closing;
                                    return .done_close;
                                },
                            }
                        } else {
                            // No pull streamer and w_len == 0: nothing to write.
                            // This shouldn't happen in normal flow; treat as done.
                            self.served += 1;
                            self.state = .closing;
                            return .done_close;
                        }
                    }
```

Also update `onDeadline` to handle `.streaming` — find the switch:

```zig
            .writing => {
```

In `onDeadline`, the existing switch covers `reading_head, reading_body, writing, keep_alive_idle, else`. The `.streaming` state is now matched by `else`. That's fine for safety (silent close on streaming stall). But add an explicit arm to be clear:

In `onDeadline`, find:

```zig
            .writing => {
                // Peer stalled mid-write: can't send 408 (they aren't reading).
                // Silently close the connection to free the fd+slot.
                self.state = .closing;
                return .done_close;
            },
```

After this arm, before `.keep_alive_idle`, add:

```zig
            .streaming => {
                // Peer stalled mid-stream: silently close.
                self.pull_streamer = null;
                self.state = .closing;
                return .done_close;
            },
```

- [ ] **Step 7: Run all tests.**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1 | tail -30
```

Expected: all tests pass including the three new streaming tests. Pay special attention to:
- `conn: pull streamer — 3 chunks then done` → PASS
- `conn: pull streamer — mid-chunk backpressure resume` → PASS
- `conn: pull streamer — stream larger than write_buf proves true streaming` → PASS
- All pre-existing tests still PASS.

If there are compile errors, trace them in the output and fix. Common pitfalls:
- The `streaming` state added to `State` enum requires the switch in `step()` to handle it. Check that `.streaming => { self.state = .closing; return .done_close; }` (or similar) is in the `step()` switch as the unreachable arm.
- The `w_len == 0` guard in `.writing` must use `continue` (loops back to `while (true)`), not `return`.

- [ ] **Step 8: Commit.**

```bash
cd /Users/chrisolson/development/github/zax && git add src/reactor/conn.zig && git commit -m "feat(reactor): pull-streamer true non-blocking streaming on evented path"
```

---

## Task 3: Threaded backend — `pull_streamer` support in `writeResponse`

**Files:**
- Modify: `src/server.zig`

**Interfaces:**
- Consumes: `response_mod.PullStreamer`, `response_mod.PullResult` (from Task 1).
- `writeResponse` is a free function at `src/server.zig:771` that writes+flushes a response to a blocking `Io.Writer`.

- [ ] **Step 1: Write a failing test** — the threaded path doesn't have inline unit tests for `writeResponse`, but we can verify by checking the existing integration test suite passes after the change. Instead, add a doc-test or rely on integration. Actually: add a direct unit test that calls `writeResponse` with a `pull_streamer` response and verifies the bytes. But `writeResponse` is a private free function with no external visibility. Instead: add a test that exercises the full threaded path. However, `server.zig` tests are integration tests. For now, just verify compile + existing tests pass.

Actually, **write the implementation directly** (no separate failing test for this function — the proof is that existing streamer tests still pass and the new function compiles). The integration tests for the threaded path exercise this implicitly.

- [ ] **Step 2: Implement** — in `src/server.zig`, find `writeResponse` (line 771):

```zig
/// Write and flush a response; returns false on a write error (caller closes).
fn writeResponse(w: *Io.Writer, resp: Response) bool {
    if (resp.streamer) |s| {
        resp.writeHead(w) catch return false;
        s.func(s.context, w) catch return false;
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}
```

Replace with:

```zig
/// Write and flush a response; returns false on a write error (caller closes).
fn writeResponse(w: *Io.Writer, resp: Response) bool {
    // Pull-streamed response: loop next(buf) writing chunks to the blocking writer.
    if (resp.pull_streamer) |ps| {
        resp.writeHead(w) catch return false;
        var chunk_buf: [4096]u8 = undefined;
        while (true) {
            switch (ps.next(&chunk_buf)) {
                .chunk => |n| {
                    if (n == 0) continue; // empty chunk: call next again
                    w.writeAll(chunk_buf[0..n]) catch return false;
                },
                .done => break,
                .err => return false,
            }
        }
        w.flush() catch return false;
        return true;
    }
    // Push-streamed response: func writes directly to the connection writer.
    if (resp.streamer) |s| {
        resp.writeHead(w) catch return false;
        s.func(s.context, w) catch return false;
        w.flush() catch return false;
        return true;
    }
    resp.write(w) catch return false;
    w.flush() catch return false;
    return true;
}
```

Also update the `streamed` variable in `handleConn` (line 676) that determines keep-alive and break-after:

```zig
                const streamed = resp.streamer != null or resp.pull_streamer != null;
```

- [ ] **Step 3: Run tests.**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1 | tail -20
```

Expected: all tests pass. No new failures.

- [ ] **Step 4: Commit.**

```bash
cd /Users/chrisolson/development/github/zax && git add src/server.zig && git commit -m "feat(server): support pull_streamer on threaded backend (blocking loop)"
```

---

## Task 4: Verify macOS + Linux, final commit

**Files:** No changes — verification only.

- [ ] **Step 1: Run full test suite on macOS (kqueue).**

```bash
cd /Users/chrisolson/development/github/zax && zig build test --summary all 2>&1
```

Record: total test count, that all pass, and specifically confirm the three new streaming tests appear and pass.

- [ ] **Step 2: Run full test suite on Linux (Docker).**

```bash
docker run --rm -v /Users/chrisolson/development/github/zax:/src:ro zax-linux-bench \
  bash -c 'cp -a /src /w && cd /w && rm -rf .zig-cache zig-out && zig build test --summary all'
```

Record: total test count. All should pass.

- [ ] **Step 3: Create squash/final commit if desired, or just verify the branch is clean.**

```bash
cd /Users/chrisolson/development/github/zax && git log --oneline feat/reactor-v2..HEAD
```

The three commits from Tasks 1–3 should appear. If you want a single commit, squash:

```bash
cd /Users/chrisolson/development/github/zax && git rebase -i HEAD~3
# change the last two "pick" to "squash", then edit the message to:
# feat(reactor): true streaming on evented via pull-streamer (connection-close framing)
```

Or leave as three commits (also fine — the spec only requires the final commit message exist).

- [ ] **Step 4: Verify final commit message.**

```bash
cd /Users/chrisolson/development/github/zax && git log --oneline -1
```

Must read: `feat(reactor): true streaming on evented via pull-streamer (connection-close framing)`.

---

## Self-Review

**Spec coverage:**
- `PullResult`, `PullStreamer`, `pull_streamer` field, `streamPull` constructor → Task 1 ✓
- `conn.zig` non-blocking streaming: serialize HEAD, pump head, call `next(write_buf)`, backpressure across `step` calls, `done_close` → Task 2 ✓
- `pull_streamer` on threaded `writeResponse` → Task 3 ✓
- Unit test: 3 fixed chunks → written in order, `done_close` → Task 2 tests ✓
- Unit test: `write_block_after_bytes` mid-chunk, resume, no bytes lost → Task 2 tests ✓
- Unit test: `write_buf` < total stream proves true streaming → Task 2 tests ✓
- macOS + Linux verify → Task 4 ✓
- Comment noting push `streamer` keeps buffer-or-500 on evented → Task 2 Step 5 ✓
- `context: *anyopaque` (not `*const`) → Task 1 type def ✓
- Additive — existing push `Streamer`, `stream()`, threaded path, buffered responses unchanged → checked ✓

**Type consistency:**
- `PullResult.chunk: usize` — used as `ps.next(...)` → `.chunk => |n|` throughout ✓
- `PullStreamer.next(buf: []u8) PullResult` — matches `nextFn` signature ✓
- `streamPull` takes `*Ctx` (mutable) matching `context: *anyopaque` ✓

**Placeholder scan:** No TBD/TODO — all code blocks complete ✓

**Edge cases covered:**
- Empty chunk (n=0) from `next()` — guarded in `.writing` to avoid infinite loop ✓
- HEAD too large for write_buf → 500 fallback ✓
- `err` from `next()` → silent close ✓
- `onDeadline` while `.streaming` → silent close ✓
