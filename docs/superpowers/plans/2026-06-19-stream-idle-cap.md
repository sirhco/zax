# Whole-stream idle cap (evented) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `stream_idle_timeout_ms` knob that hard-closes an evented pull stream which has produced no data for N ms.

**Architecture:** Track `last_produce_ns` on the conn (set at stream start, reset on every real chunk). At the `chunk(0)` decision point in `Conn.step()` — which runs on every repoll cycle — compare elapsed time against the cap; if exceeded, hard-close (`.done_close`, no chunked terminator). No new timer: reuses the single `deadline_ns` model. Knob flows `EventedOptions → WorkerOpts → applyConnConfig → Conn`.

**Tech Stack:** Zig 0.16, zax evented reactor (epoll/kqueue), fake-transport unit tests.

## Global Constraints

- Zig 0.16 — no `std.Thread.Mutex` (removed); not needed here.
- Purely additive; new fields default to `0` (disabled) → zero behavior change unless set.
- Evented backend only. Do NOT touch the threaded `streamPull` path (`src/server.zig` `writeResponse`).
- Hard close on cap = truncate: NO `loadChunkedTerminator` before `.done_close`.
- Monotonic time via existing `monotonicNow()` (`src/reactor/conn.zig:1342`); type `i96` ns.
- Single deadline slot per conn (`deadline_ns: i96`) — do NOT add a second timer.
- Test baseline: **230/233 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Plumb `stream_idle_timeout_ms` through the config chain

Wire the knob end-to-end with no behavior change yet. Default `0` everywhere.

**Files:**
- Modify: `src/reactor/conn.zig` (Conn struct, ~:204)
- Modify: `src/reactor/worker.zig` (`WorkerOpts` ~:76, `applyConnConfig` ~:790)
- Modify: `src/server.zig` (`EventedOptions` ~:178, `serveEvented` worker_opts ~:518)
- Test: `src/reactor/worker.zig` (config-propagation test alongside existing worker tests)

**Interfaces:**
- Produces: `Conn.stream_idle_timeout_ms: u32` (default 0), `Conn.last_produce_ns: i96` (default 0); `WorkerOpts.stream_idle_timeout_ms: u32`; `EventedOptions.stream_idle_timeout_ms: u32`.

- [ ] **Step 1: Add Conn fields**

In `src/reactor/conn.zig`, immediately after the `stream_repoll_ms: u32 = 5,` field (~:204):

```zig
        /// Whole-stream idle cap (ms): close a pull stream that has produced no
        /// data for this long. 0 disables (default — no cap, legacy behavior).
        stream_idle_timeout_ms: u32 = 0,
        /// Monotonic stamp (ns) of the last real chunk produced; also set at
        /// stream start. Only read when `stream_idle_timeout_ms != 0`.
        last_produce_ns: i96 = 0,
```

- [ ] **Step 2: Add WorkerOpts field**

In `src/reactor/worker.zig` `WorkerOpts`, after `stream_repoll_ms: u32 = 5,` (~:76):

```zig
    stream_idle_timeout_ms: u32 = 0,
```

- [ ] **Step 3: Propagate in applyConnConfig**

In `src/reactor/worker.zig` `applyConnConfig`, after `conn.stream_repoll_ms = opts.stream_repoll_ms;` (~:790):

```zig
    conn.stream_idle_timeout_ms = opts.stream_idle_timeout_ms;
```

- [ ] **Step 4: Add EventedOptions field**

In `src/server.zig` `EventedOptions`, after `stream_repoll_ms: u32 = 5,` (:178):

```zig
    /// Whole-stream idle cap (ms) for pull streams: close a stream that has
    /// produced no data for this long. 0 disables (default — no cap).
    stream_idle_timeout_ms: u32 = 0,
```

- [ ] **Step 5: Map into worker_opts**

In `src/server.zig` `serveEvented`, in the `WorkerOpts{...}` literal after `.stream_repoll_ms = opts.stream_repoll_ms,` (~:518):

```zig
                .stream_idle_timeout_ms = opts.stream_idle_timeout_ms,
```

- [ ] **Step 6: Write config-propagation test**

In `src/reactor/worker.zig` test block, add a test that builds a `WorkerOpts` with `stream_idle_timeout_ms = 1234`, applies it via `applyConnConfig` to a conn, and asserts it lands. Mirror the existing `stream_repoll_ms` propagation test if one exists; otherwise:

```zig
test "applyConnConfig propagates stream_idle_timeout_ms" {
    var conn: Conn = undefined;
    const opts = WorkerOpts{
        .read_buffer_size = 1024,
        .write_buffer_size = 1024,
        .keep_alive = true,
        .max_keep_alive_requests = 100,
        .max_body_size = 1024,
        .read_timeout_ms = 30_000,
        .idle_timeout_ms = 60_000,
        .stream_repoll_ms = 5,
        .stream_idle_timeout_ms = 1234,
        .tcp_nodelay = true,
    };
    applyConnConfig(&conn, opts);
    try std.testing.expectEqual(@as(u32, 1234), conn.stream_idle_timeout_ms);
}
```

(Adjust the `WorkerOpts` literal to match the struct's exact required fields at edit time.)

- [ ] **Step 7: Build + test**

Run: `zig build test --summary all`
Expected: PASS, new propagation test green, baseline 230 → 231 (or +1 from current).

- [ ] **Step 8: Commit**

```bash
git add src/reactor/conn.zig src/reactor/worker.zig src/server.zig
git commit -m "feat(reactor): plumb stream_idle_timeout_ms knob (no behavior yet)"
```

---

### Task 2: Idle-cap logic in `Conn.step()`

Stamp `last_produce_ns` at stream start and on each real chunk; close on cap at the `chunk(0)` sites.

**Files:**
- Modify: `src/reactor/conn.zig` (stream-start ~:517; both `chunk(0)`/`n>0` sites ~:570-590 and ~:629-650)
- Test: `src/reactor/conn.zig` (fake-transport tests in the existing test block)

**Interfaces:**
- Consumes: `Conn.stream_idle_timeout_ms`, `Conn.last_produce_ns` (Task 1); `monotonicNow()`; `Conn.pull_streamer`, `Conn.state`, `StepResult.done_close`.

- [ ] **Step 1: Write failing test — cap fires (truncate)**

In the `src/reactor/conn.zig` test block, add a test that drives a persistent request to a pull producer that always returns `chunk(0)`, with `stream_idle_timeout_ms` set small (e.g. 1ms) and `stream_repoll_ms` non-zero. Simulate elapsed time by setting `conn.last_produce_ns` to a stamp older than the cap before re-driving the parked `.streaming` conn (call `onDeadline()` then `step()`), and assert the `chunk(0)` step returns `.done_close`, `conn.state == .closing`, and the write buffer was NOT loaded with the `0\r\n\r\n` terminator. Model the new test on the existing v0.3.0 sparse-SSE park test (search the test block for `want_stream_repoll`).

```zig
test "stream idle cap: chunk(0) past window hard-closes (no terminator)" {
    // ... set up conn with a pull_streamer that always returns .chunk(0),
    //     stream_chunked = true, stream_repoll_ms = 5, stream_idle_timeout_ms = 10
    //     (follow the existing sparse-SSE park test harness)
    conn.last_produce_ns = monotonicNow() - 50 * std.time.ns_per_ms; // 50ms idle > 10ms cap
    // re-drive the parked stream
    _ = conn.onDeadline();            // .streaming -> .writing
    const r = conn.step(transport);   // hits chunk(0) -> cap check
    try std.testing.expectEqual(StepResult.done_close, r);
    try std.testing.expectEqual(Conn.State.closing, conn.state);
    // terminator not written:
    try std.testing.expect(!std.mem.endsWith(u8, conn.write_buf[0..conn.w_len], "0\r\n\r\n"));
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `zig build test --summary all`
Expected: FAIL (no cap logic yet → returns `.want_stream_repoll`, not `.done_close`).

- [ ] **Step 3: Stamp `last_produce_ns` at stream start**

In `src/reactor/conn.zig`, where `pull_streamer` is assigned in the dispatch branch (~:517, `self.pull_streamer = ps;`), add directly after:

```zig
                                self.last_produce_ns = monotonicNow();
```

- [ ] **Step 4: Add cap check + real-chunk reset at the first chunk(0) site**

At the first pull `next()` site (~:570), in the `.chunk => |n|` branch. For the `n == 0` not-ready case, BEFORE the `stream_repoll_ms` park logic (~:571), add the cap check; and in the `n > 0` case set `last_produce_ns`. Result:

```zig
                                .chunk => |n| {
                                    if (n == 0) {
                                        // Whole-stream idle cap: no data for too long → hard close (truncate).
                                        if (self.stream_idle_timeout_ms != 0) {
                                            const now = monotonicNow();
                                            if (now - self.last_produce_ns >
                                                @as(i96, self.stream_idle_timeout_ms) * 1_000_000)
                                            {
                                                self.pull_streamer = null;
                                                self.state = .closing;
                                                return .done_close;
                                            }
                                        }
                                        // Producer not ready yet (sparse stream, e.g. SSE).
                                        if (self.stream_repoll_ms == 0) {
                                            self.deadline_ns = no_deadline;
                                            return .want_write;
                                        }
                                        self.w_off = 0;
                                        self.w_len = 0;
                                        self.state = .streaming;
                                        self.deadline_ns = monotonicNow() + @as(i96, self.stream_repoll_ms) * 1_000_000;
                                        return .want_stream_repoll;
                                    }
                                    self.last_produce_ns = monotonicNow();
                                    if (self.stream_chunked) {
                                        self.frameChunk(n);
                                    } else {
                                        self.w_off = 0;
                                        self.w_len = n;
                                    }
                                    self.deadline_ns = no_deadline;
                                },
```

- [ ] **Step 5: Same cap check + reset at the second chunk(0) site**

At the `.wrote_all` pull `next()` site (~:629), apply the identical pattern. For `n == 0`, add the cap check before the `stream_repoll_ms == 0` busy-spin branch; for `n > 0`, set `self.last_produce_ns = monotonicNow();` before framing:

```zig
                                    .chunk => |n| {
                                        if (n == 0) {
                                            if (self.stream_idle_timeout_ms != 0) {
                                                const now = monotonicNow();
                                                if (now - self.last_produce_ns >
                                                    @as(i96, self.stream_idle_timeout_ms) * 1_000_000)
                                                {
                                                    self.pull_streamer = null;
                                                    self.state = .closing;
                                                    return .done_close;
                                                }
                                            }
                                            if (self.stream_repoll_ms == 0) {
                                                self.w_off = 0;
                                                self.w_len = 0;
                                                return .want_write;
                                            }
                                            self.w_off = 0;
                                            self.w_len = 0;
                                            self.state = .streaming;
                                            self.deadline_ns = monotonicNow() + @as(i96, self.stream_repoll_ms) * 1_000_000;
                                            return .want_stream_repoll;
                                        }
                                        self.last_produce_ns = monotonicNow();
                                        if (self.stream_chunked) {
                                            self.frameChunk(n);
                                        } else {
                                            self.w_off = 0;
                                            self.w_len = n;
                                        }
```

(Keep the remainder of this branch — the deadline re-arm / pump continuation — unchanged.)

- [ ] **Step 6: Run cap-fires test — verify it passes**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 7: Write + run window-reset test**

Add a test: producer returns `chunk(0)` once, then a real chunk `chunk(n>0)`, then `chunk(0)` again. With a moderate cap, assert the real chunk advanced `last_produce_ns` so the second `chunk(0)` does NOT close (returns `.want_stream_repoll`). Run `zig build test --summary all` → PASS.

- [ ] **Step 8: Write + run disabled + busy-spin tests**

Add two tests:
- `stream_idle_timeout_ms == 0`: `chunk(0)` with a long-ago `last_produce_ns` still parks (`.want_stream_repoll`), never `.done_close`.
- `stream_repoll_ms == 0` + cap set + idle past window: the busy-spin `chunk(0)` path returns `.done_close`.

Run: `zig build test --summary all`
Expected: PASS, all four idle-cap tests green.

- [ ] **Step 9: Commit**

```bash
git add src/reactor/conn.zig
git commit -m "feat(reactor): whole-stream idle cap closes stuck pull streams"
```

---

### Task 3: Docs + CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document the knob in `docs/evented-backend.md`**

In the streaming / options section, add a paragraph: `EventedOptions.stream_idle_timeout_ms` (default 0 = disabled) hard-closes a pull stream (`streamPull`/`ssePull`) that has produced no data for that many ms; the connection is truncated (no `0\r\n\r\n` terminator) so the client detects the incomplete stream. Note it composes with `stream_repoll_ms` (the re-poll cadence is the check granularity) and is evented-only.

- [ ] **Step 2: Add CHANGELOG entry**

Under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- Evented reactor: `EventedOptions.stream_idle_timeout_ms` — opt-in whole-stream idle cap that hard-closes a pull stream (`streamPull`/`ssePull`) producing no data for N ms (default 0 = disabled).
```

- [ ] **Step 3: Commit**

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(streaming): document stream_idle_timeout_ms idle cap"
```

---

## Final verification

- `zig build test --summary all` → 0 failures, baseline grew from 230 by the new tests.
- Spec coverage: Task 1 = config plumbing; Task 2 = cap logic + last_produce_ns + 4 unit tests (cap-fires, reset, disabled, busy-spin); Task 3 = docs/CHANGELOG. All spec sections covered.
- Regression: with the knob unset (default 0), sparse-SSE park behaves exactly as before.
