# Pull-model SSE helper (`ssePull`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pull-model SSE helper (`Response.ssePull`) so Server-Sent Events work on the evented backend, reusing the existing SSE wire formatter and the `streamPull` path.

**Architecture:** `ssePull` returns a `Response` whose `pull_streamer` closure bridges a user `nextFn(*Ctx) -> SsePull` to the existing `PullResult` protocol — framing each event/comment into the driver's write buffer via `sse.formatEvent`/`formatComment`. No reactor or threaded-driver changes; both backends already drive `pull_streamer`. Purely additive.

**Tech Stack:** Zig 0.16, `std.Io.Writer` (`Writer.fixed`), the existing `src/http/sse.zig` formatter, the existing `streamPull`/`PullResult` machinery in `src/http/response.zig`.

## Global Constraints

- Zig 0.16 — no `std.Thread.Mutex`.
- Purely additive: do NOT modify `sse()`, `stream()`, `streamPull()`, the reactor (`src/reactor/*`), or the threaded driver (`src/server.zig`).
- Zero new heap allocation — frame into the buffer the driver already passes to `nextFn`.
- Connection-close framing (`keep_alive = false`), `content_type = "text/event-stream"`.
- Reuse `sse_mod.formatEvent` / `sse_mod.formatComment` (already `pub`, unit-tested); do not duplicate framing logic.
- In `src/http/response.zig`: `Writer = std.Io.Writer` (line 7), `sse_mod = @import("sse.zig")` (line 9), `PullResult` and `Response` are defined in-file. `Writer.fixed(buf)` + `w.buffered()` are the framing idiom (see `src/http/sse.zig` tests).
- Test baseline: `zig build test --summary all` = **213/216 passed, 3 skipped** (the 3 skips are Linux-only epoll tests on macOS — expected; do not touch them).

---

### Task 1: `SsePull` union + `Response.ssePull`

**Files:**
- Modify: `src/http/response.zig` (add the union + function near `streamPull`, ~line 190–206; add tests in the test block, after the existing `streamPull` test ~line 496–509)
- Test: same file (`src/http/response.zig` test block)

**Interfaces:**
- Consumes: `Response`, `PullResult` (in-file), `sse_mod.Event`/`sse_mod.formatEvent`/`sse_mod.formatComment` (from `sse.zig`), `Writer = std.Io.Writer`.
- Produces:
  - `pub const SsePull = union(enum) { event: sse_mod.Event, comment: []const u8, not_ready, done }`
  - `pub fn ssePull(comptime Ctx: type, context: *Ctx, comptime nextFn: fn (*Ctx) SsePull) Response`

- [ ] **Step 1: Write the failing tests**

Add to the `src/http/response.zig` test block (after the existing `streamPull` test):

```zig
test "ssePull: builds text/event-stream Response, connection-close, pull_streamer set, no body" {
    const Ctx = struct {
        fn next(_: *@This()) SsePull {
            return .done;
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    try testing.expectEqualStrings("text/event-stream", r.content_type);
    try testing.expect(r.pull_streamer != null);
    try testing.expect(!r.keep_alive);
    try testing.expectEqual(@as(usize, 0), r.body.len);
}

test "ssePull: event is framed via formatEvent into the buffer, then done" {
    const Ctx = struct {
        sent: bool = false,
        fn next(c: *@This()) SsePull {
            if (c.sent) return .done;
            c.sent = true;
            return .{ .event = .{ .event = "tick", .data = "hi" } };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;

    var buf: [256]u8 = undefined;
    const res = ps.next(&buf);

    // Reference: what formatEvent would write for the same event.
    var rbuf: [256]u8 = undefined;
    var rw = Writer.fixed(&rbuf);
    try sse_mod.formatEvent(&rw, .{ .event = "tick", .data = "hi" });
    const expected = rw.buffered();

    switch (res) {
        .chunk => |n| try testing.expectEqualStrings(expected, buf[0..n]),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "ssePull: comment framed; not_ready → chunk 0; done" {
    const Ctx = struct {
        step: usize = 0,
        fn next(c: *@This()) SsePull {
            defer c.step += 1;
            return switch (c.step) {
                0 => .{ .comment = "ping" },
                1 => .not_ready,
                else => .done,
            };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;
    var buf: [64]u8 = undefined;

    switch (ps.next(&buf)) {
        .chunk => |n| try testing.expectEqualStrings(": ping\n", buf[0..n]),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(PullResult{ .chunk = 0 }, ps.next(&buf));
    try testing.expectEqual(PullResult.done, ps.next(&buf));
}

test "ssePull: event larger than the buffer → err" {
    const Ctx = struct {
        fn next(_: *@This()) SsePull {
            return .{ .event = .{ .data = "x" ** 200 } };
        }
    };
    var ctx = Ctx{};
    const r = Response.ssePull(Ctx, &ctx, Ctx.next);
    const ps = r.pull_streamer.?;
    var buf: [16]u8 = undefined; // far smaller than the 200-byte payload
    try testing.expectEqual(PullResult.err, ps.next(&buf));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test --summary all`
Expected: compile error — `SsePull` / `ssePull` not defined (`error: no member named 'ssePull' in struct 'Response'` or `use of undeclared identifier 'SsePull'`).

- [ ] **Step 3: Implement `SsePull` + `ssePull`**

Add, immediately after the `streamPull` function (~line 206) in `src/http/response.zig`:

```zig
/// One step of a pull-model SSE producer (see `ssePull`).
pub const SsePull = union(enum) {
    /// A full SSE event (event/data/id/retry) — framed via `sse.formatEvent`.
    event: sse_mod.Event,
    /// An SSE comment line (`: text`) — keepalive heartbeat, via `sse.formatComment`.
    comment: []const u8,
    /// No event ready yet — emits a 0-byte chunk (parks on the evented backend).
    not_ready,
    /// End of stream.
    done,
};

/// Build a pull-model SSE (`text/event-stream`) response. `nextFn` is called
/// repeatedly; zax frames each returned event/comment into the driver's write
/// buffer via the SSE wire formatter. Connection-close framing. Works on both
/// backends — on the evented backend `not_ready` parks the connection on the
/// timer wheel (no busy-spin); on threaded it loops, so for sparse streams on
/// the threaded backend prefer the push `sse()` helper. A single event larger
/// than the driver buffer yields `.err` (the connection closes).
/// `context` must outlive the request (use the request arena).
pub fn ssePull(
    comptime Ctx: type,
    context: *Ctx,
    comptime nextFn: fn (*Ctx) SsePull,
) Response {
    const Erased = struct {
        fn call(c: *anyopaque, buf: []u8) PullResult {
            const ctx: *Ctx = @ptrCast(@alignCast(c));
            switch (nextFn(ctx)) {
                .event => |e| {
                    var w = Writer.fixed(buf);
                    sse_mod.formatEvent(&w, e) catch return .err;
                    return .{ .chunk = w.buffered().len };
                },
                .comment => |text| {
                    var w = Writer.fixed(buf);
                    sse_mod.formatComment(&w, text) catch return .err;
                    return .{ .chunk = w.buffered().len };
                },
                .not_ready => return .{ .chunk = 0 },
                .done => return .done,
            }
        }
    };
    return .{
        .content_type = "text/event-stream",
        .pull_streamer = .{ .context = context, .nextFn = &Erased.call },
        .keep_alive = false,
    };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test --summary all`
Expected: PASS — baseline + 4 new tests (217/220 passed, 3 skipped), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): ssePull — pull-model SSE helper (evented-native)"
```

---

### Task 2: Reactor integration test (drive `ssePull` through the evented conn)

**Files:**
- Test only: `src/reactor/conn.zig` (add to the pull-streamer test block, after the existing pull-streamer / sparse tests, ~line 1316+)

**Interfaces:**
- Consumes: `Response.ssePull` + `SsePull` (Task 1), and the existing conn test harness in this file: `FakeTransport`, `Dispatcher`, `Conn.init`, `c.step(t, d)`, `c.onDeadline()`, `StepResult`, `request.Request`, `response_mod` (the alias for `response.zig` used in this test block).
- Produces: nothing (test only).

- [ ] **Step 1: Write the failing test**

Add to the pull-streamer test section of `src/reactor/conn.zig`:

```zig
test "conn: ssePull producer — events flush, not_ready parks (want_stream_repoll), done closes" {
    const SseCtx = struct {
        step: usize = 0,
        fn next(c: *@This()) response_mod.SsePull {
            defer c.step += 1;
            return switch (c.step) {
                0 => .{ .event = .{ .data = "one" } },
                1 => .not_ready,
                2 => .{ .event = .{ .data = "two" } },
                else => .done,
            };
        }
    };

    const raw = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = SseCtx{};

    const SseDispatch = struct {
        p: *SseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req;
            _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.ssePull(SseCtx, s.p, SseCtx.next);
        }
    };
    var sd = SseDispatch{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SseDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    const t = ft.transport();

    // Drive the conn to completion. A not-ready producer parks
    // (want_stream_repoll); simulate the readiness timer firing via onDeadline.
    var parked_once = false;
    var guard: usize = 0;
    var result = c.step(t, d);
    while (result != .done_close) : (guard += 1) {
        if (guard > 50) return error.TestUnexpectedResult;
        if (result == .want_stream_repoll) {
            parked_once = true;
            _ = c.onDeadline();
        }
        result = c.step(t, d);
    }

    try testing.expect(parked_once);

    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, written, "text/event-stream") != null);
    try testing.expect(std.mem.indexOf(u8, written, "connection: close") != null);
    const p1 = std.mem.indexOf(u8, written, "data: one") orelse return error.TestUnexpectedResult;
    const p2 = std.mem.indexOf(u8, written, "data: two") orelse return error.TestUnexpectedResult;
    try testing.expect(p1 < p2);
}
```

Note: if the exact drive sequence differs from the existing sparse-stream test in this file (the one asserting `want_stream_repoll` + `onDeadline`), mirror that test's stepping rather than this loop — the loop+guard form above is written to be robust to either sequencing. Verify `response_mod` is the alias used for `Response`/`PullResult` in this test block (it is, e.g. `response_mod.PullResult`); `SsePull` is reached as `response_mod.SsePull`.

- [ ] **Step 2: Run the test to verify it fails (then passes)**

Run: `zig build test --summary all`
Expected first run (before Task 1 merged into the working tree — it is, so this should PASS). If Task 1 is present, this test should PASS immediately since it exercises real behavior. If it FAILS, inspect: head framing, the park step, or the drive sequencing (see the note above) — fix the test to match the existing sparse-test pattern, not the production code.

- [ ] **Step 3: Commit**

```bash
git add src/reactor/conn.zig
git commit -m "test(reactor): drive ssePull producer through the evented conn"
```

---

### Task 3: Docs + CHANGELOG + final verification

**Files:**
- Modify: `docs/evented-backend.md` (Streaming section, ~line 64–88)
- Modify: `CHANGELOG.md` (add an `## [Unreleased]` section at the top, below the intro)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `docs/evented-backend.md`**

In the Streaming section, after the `streamPull` example/paragraph, add:

```markdown
### Server-Sent Events on the evented backend

The push `sse()` helper is threaded-only (it writes to a blocking writer). For SSE on the
evented backend, use the pull-model `ssePull` — `nextFn` returns one `SsePull` step at a time
and zax frames it:

```zig
const Feed = struct {
    fn next(self: *Feed) zax.SsePull {
        if (self.poll()) |ev| return .{ .event = .{ .data = ev } };
        if (self.ended) return .done;
        return .not_ready;   // nothing yet — parks on the timer wheel (no busy-spin)
    }
};

fn events(feed: *Feed) zax.Response {
    return zax.Response.ssePull(Feed, feed, Feed.next);
}
```

`not_ready` emits a 0-byte chunk: on evented it parks the connection and re-polls after
`stream_repoll_ms`; on threaded it loops, so for sparse streams on the threaded backend prefer
the push `sse()` helper. A single event larger than the write buffer yields an error and closes
the connection.
```

(Keep the existing note that `sse()` / push `stream` are threaded-only.)

- [ ] **Step 2: Update `CHANGELOG.md`**

Add directly below the intro paragraph (before `## [0.3.0]`):

```markdown
## [Unreleased]

### Added

- **`Response.ssePull` — pull-model Server-Sent Events.** Emits SSE on **both** backends
  (the push `sse()` helper remains threaded-only). `nextFn(*Ctx) -> SsePull` returns
  `{ event, comment, not_ready, done }`; zax frames each event/comment via the SSE wire
  formatter. `not_ready` parks on the evented backend (no busy-spin); an event larger than the
  write buffer closes the connection.

```

- [ ] **Step 3: Final verification**

Run: `zig build test --summary all`
Expected: 217/220 passed, 3 skipped, 0 failures (baseline 213 + 4 unit tests; the reactor integration test is one of the +N — confirm the exact count and that there are 0 failures).

- [ ] **Step 4: Commit**

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(sse): document ssePull (evented-native SSE) + changelog"
```

---

## Self-Review

- **Spec coverage:** API (`SsePull` union + `ssePull`) → Task 1. Framing/not_ready/done/oversize semantics → Task 1 tests. Reactor `not_ready` park behavior → Task 2 integration test. Docs (evented-backend.md + CHANGELOG) → Task 3. Verification → Task 3 Step 3. All spec sections covered.
- **Placeholder scan:** none — all steps carry real code/commands.
- **Type consistency:** `SsePull` variants (`event: sse_mod.Event`, `comment: []const u8`, `not_ready`, `done`), `ssePull(comptime Ctx, *Ctx, comptime fn(*Ctx) SsePull) Response`, and `PullResult` (`.chunk`, `.done`, `.err`) are used identically across tasks. The erased closure returns `PullResult`, matching `Response.pull_streamer.nextFn`'s signature (`fn(*anyopaque, []u8) PullResult`).

## Notes for the integration test (Task 2)

The exact `c.step` ↔ `onDeadline` sequence for a parked stream is defined by the v0.3.0 sparse-SSE
fix. If the loop form in Task 2 misbehaves, open the existing sparse pull-streamer tests in
`src/reactor/conn.zig` (the ones asserting `StepResult.want_stream_repoll` and calling
`c.onDeadline()`) and mirror their drive sequence exactly. The production code is correct (shipped in
v0.3.0); only the test's driving needs to match it.
