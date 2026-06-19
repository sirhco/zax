# Threaded streamPull backoff + idle cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the threaded `streamPull` chunk(0) busy-loop with a backoff sleep + an optional whole-stream idle cap, achieving parity with the evented backend.

**Architecture:** Add `Options.stream_repoll_ms` (default 5) and `Options.stream_idle_timeout_ms` (default 0) mirroring `EventedOptions`. Thread `io` + both knob values into `writeResponse`; in its pull branch, on `chunk(0)` sleep `stream_repoll_ms` between re-polls (instead of `continue`-spinning) and, if `stream_idle_timeout_ms` is set and exceeded, hard-close (return false → caller closes, no chunked terminator = truncate).

**Tech Stack:** Zig 0.16, zax threaded backend (`std.Io.Threaded`), loopback e2e tests.

## Global Constraints

- Zig 0.16. Purely additive; new `Options` fields default to mirror evented: `stream_repoll_ms = 5`, `stream_idle_timeout_ms = 0`.
- Threaded backend only (`src/server.zig`). Do NOT touch the evented reactor (`src/reactor/conn.zig`) or the decoder.
- `stream_repoll_ms == 0` → legacy busy-loop (opt-out). `stream_idle_timeout_ms == 0` → no idle cap.
- Idle cap = HARD CLOSE TRUNCATE: `return false` from `writeResponse` (caller closes) WITHOUT writing the chunked terminator.
- Sleep via `Io.sleep(io, Io.Duration.fromMilliseconds(ms), .awake) catch {}`. Monotonic time via existing `nowNs(io) i96` (`src/server.zig:863`) — do NOT import the reactor's `monotonicNow`.
- `last_produce` stamped at stream start + reset on every real chunk (n>0); idle measured against it.
- Common case (producer always ready, `chunk(n>0)`) must incur ZERO new overhead — no sleep, no extra clock read beyond the per-chunk `last_produce` stamp.
- Test baseline: **251/254 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Backoff + idle cap in threaded `writeResponse`

Add the two `Options` knobs, thread `io` + knobs through `writeResponse` (and `terminalResponse`), implement the chunk(0) backoff + idle cap, and cover with e2e tests.

**Files:**
- Modify: `src/server.zig` — `Options` (~:126); `writeResponse` (~:775-815); the streaming caller (~:682); `terminalResponse` (~:982) + its callers in `handleConn`.
- Test: `src/server.zig` (e2e test block — mirror existing streaming/loopback tests).

**Interfaces:**
- Produces: `Options.stream_repoll_ms: u32 = 5`, `Options.stream_idle_timeout_ms: u32 = 0`; new `writeResponse` signature `fn writeResponse(w: *Io.Writer, resp: Response, chunked: bool, io: Io, repoll_ms: u32, idle_ms: u32) bool`; `terminalResponse(io: Io, w: *Io.Writer, e: RequestError) void`.

- [ ] **Step 1: Write failing e2e tests**

In the `src/server.zig` test block, mirror an existing threaded streaming/loopback test (search for `streamPull` / `pull_streamer` / a streaming e2e using `ConnReader` + a real socket pair). Add three tests with a test-local pull producer struct (a counter-driven `nextFn`):

```zig
// Test A — backoff path yields correct stream:
//   producer returns chunk(0) twice, then "hello", then "world", then .done.
//   Server Options.stream_repoll_ms = 1 (fast). Drive a GET to a streamPull route.
//   Assert the response body contains "hello" and "world" (full stream, in order),
//   and (chunked path) ends with the terminator "0\r\n\r\n".
//
// Test B — idle cap truncates:
//   producer returns chunk(0) forever. Options.stream_idle_timeout_ms = small (e.g. 5),
//   stream_repoll_ms = 1. Assert the connection closes and the received bytes do NOT
//   contain the chunked terminator "0\r\n\r\n" (truncated — mirrors the evented idle-cap test).
//
// Test C — repoll_ms == 0 legacy still completes:
//   producer returns chunk(0) once then "ok" then .done. Options.stream_repoll_ms = 0.
//   Assert body contains "ok" (no sleep path; correctness preserved).
```

Use the existing streaming-e2e harness (server setup + socket) exactly; only the route's producer and the assertions differ. Pick unique ports not already used by other tests in the file.

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — `Options.stream_repoll_ms`/`stream_idle_timeout_ms` not defined (and the new `writeResponse` behavior absent).

- [ ] **Step 3: Add the two `Options` fields**

In `src/server.zig` `Options` (~:126), after the existing timeout fields (e.g. after `idle_timeout_ms`/`tcp_nodelay`), add:

```zig
    /// Sleep (ms) between re-polls of a not-ready (`chunk(0)`) pull-stream
    /// producer on the threaded backend; 0 = legacy busy-loop.
    stream_repoll_ms: u32 = 5,
    /// Whole-stream idle cap (ms): close a threaded pull stream that has
    /// produced no data for this long; 0 = disabled. Hard-close (truncate,
    /// no chunked terminator).
    stream_idle_timeout_ms: u32 = 0,
```

- [ ] **Step 4: Rewrite the `writeResponse` pull branch**

Change the signature and the pull branch in `src/server.zig` (~:775). New signature:

```zig
fn writeResponse(w: *Io.Writer, resp: Response, chunked: bool, io: Io, repoll_ms: u32, idle_ms: u32) bool {
```

Replace the pull branch (the `if (resp.pull_streamer) |ps| { ... }` block) with:

```zig
    if (resp.pull_streamer) |ps| {
        resp.writeHead(w, chunked) catch return false;
        var chunk_buf: [4096]u8 = undefined;
        var last_produce: i96 = nowNs(io); // idle window starts at stream start
        while (true) {
            switch (ps.next(&chunk_buf)) {
                .chunk => |n| {
                    if (n == 0) {
                        // Whole-stream idle cap: no data for too long → hard close (truncate).
                        if (idle_ms != 0 and nowNs(io) - last_produce > @as(i96, idle_ms) * 1_000_000)
                            return false; // caller closes; NO terminator
                        if (repoll_ms != 0)
                            Io.sleep(io, Io.Duration.fromMilliseconds(repoll_ms), .awake) catch {};
                        continue;
                    }
                    last_produce = nowNs(io); // real data resets the idle window
                    if (chunked) {
                        chunked_mod.writeChunk(w, chunk_buf[0..n]) catch return false;
                    } else {
                        w.writeAll(chunk_buf[0..n]) catch return false;
                    }
                },
                .done => break,
                .err => return false,
            }
        }
        if (chunked) chunked_mod.writeTerminator(w) catch return false;
        w.flush() catch return false;
        return true;
    }
```

Leave the push-stream and buffered branches unchanged (the new params are unused there).

- [ ] **Step 5: Update the streaming caller**

In `handleConn` (~:682), change:

```zig
                if (!writeResponse(w, resp, chunked, io, self.opts.stream_repoll_ms, self.opts.stream_idle_timeout_ms)) break;
```

- [ ] **Step 6: Thread `io` through `terminalResponse`**

Change `terminalResponse` (~:982) to take `io`:

```zig
fn terminalResponse(io: Io, w: *Io.Writer, e: RequestError) void {
```

Update each `writeResponse(w, Response.fromStatus(...), false)` inside it to
`writeResponse(w, Response.fromStatus(...), false, io, 0, 0)` (error responses never stream, so the repoll/idle args are unused). Then update the `terminalResponse(w, e)` call sites in `handleConn` (the `readHead`/`readBody` catch blocks) to `terminalResponse(io, w, e)` — `io` is in scope there.

- [ ] **Step 7: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS — Tests A/B/C green; existing streaming tests unaffected.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): backoff + idle cap for threaded pull streams (no busy-loop)"
```

---

### Task 2: Docs + CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md` (or the streaming docs section)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document the threaded behavior**

In `docs/evented-backend.md` (the streaming section that mentions `stream_repoll_ms`/the
busy-loop note), add a short note: the threaded backend now also backs off
(`Options.stream_repoll_ms`, default 5ms) instead of busy-looping on a not-ready
(`chunk(0)`) pull producer, and supports the same `Options.stream_idle_timeout_ms` idle cap
(hard-close truncate) — full parity with the evented backend. If the docs previously stated
"threaded busy-loops", update that statement.

- [ ] **Step 2: CHANGELOG entry**

Under `## [Unreleased]` in `CHANGELOG.md` (create the `[Unreleased]` section + `### Added`/`### Changed` subsection if absent, matching the changelog's convention — note v0.6.0 just shipped so `[Unreleased]` may be empty):

```markdown
- Threaded backend: pull streams (`streamPull`/`ssePull`) now back off (`Options.stream_repoll_ms`, default 5ms) instead of busy-looping on a not-ready (`chunk(0)`) producer, and honor `Options.stream_idle_timeout_ms` (idle cap, hard-close) — parity with the evented backend.
```

- [ ] **Step 3: Run + commit**

Run: `zig build test --summary all` (expect green, no count change from docs)

```bash
git add docs/evented-backend.md CHANGELOG.md
git commit -m "docs(server): document threaded pull-stream backoff + idle cap"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 251 + Tests A/B/C.
- Spec coverage: T1 = Options knobs + writeResponse backoff/idle + io threading + 3 e2e tests; T2 = docs/CHANGELOG. All spec sections covered.
- Regression: producers that are always ready (`chunk(n>0)`) take no sleep; non-streamed / push / evented responses unchanged.
- Manual: a sparse threaded `streamPull` SSE endpoint no longer pins a CPU core while idle (`top`); a stuck producer with `stream_idle_timeout_ms` set closes after the cap.
