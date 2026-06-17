# Evented Reactor Backend (Linux epoll, v1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, non-blocking epoll reactor backend to zax (`app.serveEvented`) that closes the throughput/tail gap to httpz/axum while reusing all existing request machinery.

**Architecture:** A bespoke per-worker epoll reactor (N shared-nothing workers + `SO_REUSEPORT`). Each connection is a transport-abstracted, non-blocking **state machine** that reuses zax's existing `parser`, radix router, `dispatch`, and `response` serialization unchanged. The state machine is decoupled from sockets via a tiny transport interface, so its logic is unit-tested with a fake in-memory transport in `zig build test` on any platform; only the epoll/socket glue is Linux-only and integration-tested in Docker. `Io.Threaded` (`app.serve`) stays the default and the only path off-Linux.

**Tech Stack:** Zig 0.16.0, `std.posix` (epoll, eventfd, sockets), the existing zax modules (`src/http/parser.zig`, `src/router`, `src/http/response.zig`, `src/server.zig`).

## Global Constraints

- **Purely additive.** Existing `app.serve(io, addr)` and all 155 existing tests unchanged. New code under `src/reactor/` + additive members on `App`.
- **Linux-only at runtime** for the reactor. `serveEvented` returns `error.EventedUnsupported` on non-Linux. Guard epoll/socket code so the library still **compiles** on macOS (the state-machine unit tests must build + run on macOS).
- **Reuse, don't reimplement:** `parser.parseHead`, the radix router/`dispatch`, `response.write`, extractors, middleware, observers, `request_id`, and the existing `Options` (`read_buffer_size`, `write_buffer_size`, `keep_alive`, `max_keep_alive_requests`, `max_body_size`, `read_timeout_ms`, `idle_timeout_ms`, `tcp_nodelay`, `request_id`).
- **No fibers, no `std.Io` in the hot path.** Response serialization targets a fixed in-memory buffer (`std.Io.Writer` over a slice), not a socket writer.
- **v1 = buffered responses only.** Streamed responses (`resp.streamer`) are buffered up to the write buffer; over cap → `500` + close. True streaming stays on the threaded backend.
- **Shared-nothing workers:** no locks, no cross-worker mutable state.
- Test baseline before this plan: **155**. It only grows.

## File Structure

- `src/reactor/transport.zig` — the transport interface + a fake in-memory transport for tests.
- `src/reactor/conn.zig` — the per-connection non-blocking state machine (the testable core).
- `src/reactor/timer.zig` — per-worker coarse timer wheel (deadlines).
- `src/reactor/poller.zig` — epoll wrapper (Linux). (kqueue is a future sibling; not in v1.)
- `src/reactor/worker.zig` — listen(`SO_REUSEPORT`) + epoll loop + accept + drive conns + timer sweep + eventfd shutdown.
- `src/server.zig` — add `EventedOptions`, `serveEvented`, evented shutdown wiring (additive).
- `src/root.zig` — export new public types as needed.
- `benchmarks/cross/zax/src/main.zig`, `benchmarks/cross/run.sh`, `benchmarks/cross/docker/` — an evented bench variant for the Docker comparison.

Tasks 1–6 are TDD on macOS (`zig build test`). Tasks 7–10 are Linux glue, integration-tested in the Docker harness.

---

### Task 1: Transport interface + fake transport

**Files:**
- Create: `src/reactor/transport.zig`
- Test: tests live in `src/reactor/transport.zig` (Zig in-file `test {}` blocks).

**Interfaces:**
- Produces:
  ```zig
  pub const IoResult = union(enum) { ok: usize, would_block, closed };
  pub const Transport = struct {
      context: *anyopaque,
      readFn: *const fn (ctx: *anyopaque, buf: []u8) IoResult,
      writeFn: *const fn (ctx: *anyopaque, buf: []const u8) IoResult,
      pub fn read(self: Transport, buf: []u8) IoResult { return self.readFn(self.context, buf); }
      pub fn write(self: Transport, buf: []const u8) IoResult { return self.writeFn(self.context, buf); }
  };
  // Test double:
  pub const FakeTransport = struct {
      reads: []const []const u8,   // scripted chunks returned by successive read()s
      read_idx: usize = 0,
      block_after: usize = std.math.maxInt(usize), // after N reads, return .would_block once
      written: std.ArrayList(u8),
      closed_after_reads: ?usize = null,
      pub fn init(gpa, reads) FakeTransport;
      pub fn transport(self: *FakeTransport) Transport;
  };
  ```

- [ ] **Step 1: Write failing tests** in `src/reactor/transport.zig`:
```zig
const std = @import("std");
const testing = std.testing;

test "FakeTransport: returns scripted read chunks then closed" {
    var ft = FakeTransport.init(testing.allocator, &.{ "GET / HTTP/1.1\r\n", "\r\n" });
    defer ft.deinit();
    const t = ft.transport();
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 15), (t.read(&buf)).ok);   // first chunk
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n", buf[0..15]);
    try testing.expectEqual(@as(usize, 2), (t.read(&buf)).ok);    // "\r\n"
    try testing.expect((t.read(&buf)) == .closed);                 // scripts exhausted
}

test "FakeTransport: write() accumulates into `written`" {
    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    const t = ft.transport();
    _ = t.write("HTTP/1.1 200 OK\r\n");
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", ft.written.items);
}

test "FakeTransport: would_block injected once at block_after" {
    var ft = FakeTransport.init(testing.allocator, &.{ "a", "b" });
    defer ft.deinit();
    ft.block_after = 1;
    const t = ft.transport();
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), (t.read(&buf)).ok);
    try testing.expect((t.read(&buf)) == .would_block);   // injected
    try testing.expectEqual(@as(usize, 1), (t.read(&buf)).ok); // resumes
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` → fails (types undefined).
- [ ] **Step 3: Implement** `IoResult`, `Transport`, `FakeTransport` (with `init`/`deinit`/`transport`, honoring `read_idx`, `block_after` one-shot, `closed_after_reads`). Register the new module so its tests run: add `_ = @import("reactor/transport.zig");` to the test aggregator (find where `src/server.zig` or the root test block imports sibling modules and mirror it).
- [ ] **Step 4: Run, verify pass** — `zig build test --summary all`.
- [ ] **Step 5: Commit** — `git commit -m "feat(reactor): transport interface + fake transport for tests"`.

---

### Task 2: Conn — read & parse a request (ReadingHead + ReadingBody)

**Files:**
- Create: `src/reactor/conn.zig`
- Test: in-file `test {}` in `src/reactor/conn.zig`

**Interfaces:**
- Consumes: `Transport`/`IoResult` (Task 1); `parser.parseHead` + `request.max_headers`/`Header` (`src/http/parser.zig`, `src/http/request.zig`).
- Produces:
  ```zig
  pub const State = enum { reading_head, reading_body, dispatching, writing, keep_alive_idle, closing };
  pub const StepResult = enum { want_read, want_write, done_close }; // what the worker should arm
  pub const Conn = struct {
      state: State = .reading_head,
      read_buf: []u8, write_buf: []u8,   // owned by the worker, lent to the conn
      r_start: usize = 0, r_end: usize = 0, // buffered read region
      // parsed request scratch (header array), arena, write cursor, served count, deadline...
      // (full fields added across Tasks 2–5)
      pub fn init(read_buf: []u8, write_buf: []u8, arena: *std.heap.ArenaAllocator) Conn;
      /// Drive the machine until it would block / completes / closes. Returns what to arm.
      pub fn step(self: *Conn, t: Transport, h: Dispatcher) StepResult; // Dispatcher added in Task 4
  };
  ```
  For Task 2, implement a narrower entry `fn fillAndParse(self: *Conn, t: Transport) ParseOutcome` where
  `ParseOutcome = union(enum) { need_more, parsed: parser.Parsed, failed: RequestError, closed }`.

- [ ] **Step 1: Write failing tests** — feed scripted reads (including a request split across two chunks) via `FakeTransport`, assert `fillAndParse` returns `.need_more` until the head is complete, then `.parsed` with the right method/path; assert a `Content-Length` body is read into `request.body`:
```zig
test "conn: parses a request arriving in two reads" {
    var ft = FakeTransport.init(testing.allocator, &.{ "GET /users/42 HTTP", "/1.1\r\nHost: x\r\n\r\n" });
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined; var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator); defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();
    try testing.expect(c.fillAndParse(t) == .need_more);     // only first chunk so far
    const out = c.fillAndParse(t);
    try testing.expect(out == .parsed);
    try testing.expectEqualStrings("/users/42", out.parsed.request.path);
}

test "conn: reads a POST body by content-length" { /* "POST /echo ... Content-Length: 12\r\n\r\n{\"msg\":\"hi\"}" → request.body == {\"msg\":\"hi\"} */ }
test "conn: rejects chunked with error.* (411 decided in Task 5)" { /* Transfer-Encoding: chunked → .failed */ }
test "conn: body over max_body_size → .failed (BodyTooLarge)" { /* small cap */ }
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** `Conn.init` + `fillAndParse`: `recv` via `t.read` into `read_buf[r_end..]`; on `.would_block` return `.need_more`; on `.closed` return `.closed`; call `parser.parseHead(read_buf[r_start..r_end], &header_scratch)`; on `error.Incomplete` keep reading; on success, validate chunked → `.failed`, read body up to `head_len + content_length` (looping reads, enforcing `max_body_size`), attach `request.body`, return `.parsed`. Mirror the logic in `src/server.zig`'s `readHead`/`readBody` but non-blocking. Add `_ = @import("reactor/conn.zig");` to the test aggregator.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(reactor): conn request read+parse state (non-blocking)`.

---

### Task 3: Conn — response serialization + non-blocking write with backpressure

**Files:** Modify `src/reactor/conn.zig`; tests in-file.

**Interfaces:**
- Consumes: `response.Response` + `response.write` (`src/http/response.zig`); `Transport`.
- Produces:
  ```zig
  // serialize a Response into write_buf (returns total len), then drive a non-blocking write:
  fn serializeResponse(self: *Conn, resp: Response) usize;     // fills write_buf, sets w_len, w_off=0
  fn pumpWrite(self: *Conn, t: Transport) enum { wrote_all, want_write, closed };
  ```

- [ ] **Step 1: Write failing tests:**
```zig
test "conn: serializes a text Response into write_buf" {
    // build a Response.text("hello"); serializeResponse; assert write_buf starts with "HTTP/1.1 200"
    // and contains "content-length: 5" and ends with "hello".
}
test "conn: pumpWrite resumes after would_block (backpressure)" {
    // FakeTransport.write returns .would_block once mid-response; pumpWrite returns .want_write,
    // then on resume writes the remainder; total written bytes == serialized length, in order.
}
```
  For the backpressure test, extend `FakeTransport` with a `write_block_after_bytes: ?usize` that returns `.would_block` once after N bytes written (add this knob in Task 3, with its own small test).

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** `serializeResponse` using a fixed-buffer `std.Io.Writer` over `write_buf` (e.g. `var w = std.Io.Writer.fixed(self.write_buf); resp.write(&w) catch ...; self.w_len = w.end;` — confirm the exact 0.16 fixed-writer constructor/`end` field against `std/Io/Writer.zig`) so `response.write` is reused verbatim. Implement `pumpWrite`: `t.write(write_buf[w_off..w_len])`; advance `w_off`; `.would_block` → return `.want_write`; `w_off == w_len` → `.wrote_all`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(reactor): conn response serialize + backpressured write`.

---

### Task 4: Conn — full cycle + dispatch + keep-alive + pipelining

**Files:** Modify `src/reactor/conn.zig`; tests in-file.

**Interfaces:**
- Consumes: Tasks 2–3; a `Dispatcher` indirection so `conn` does not depend on `App`:
  ```zig
  pub const Dispatcher = struct {
      ctx: *anyopaque,
      dispatchFn: *const fn (ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response,
  };
  ```
  The worker (Task 8) builds this from `App.dispatch`. (NOTE: `App.dispatch` currently takes an `io`; see Task 8 — the worker captures a suitable `io` for handler context and the non-blocking-handler constraint is documented. `conn` stays `io`-free.)
- Produces: the full `Conn.step(self, t, d) StepResult` wiring `reading_head → reading_body → dispatching → writing → keep_alive_idle/closing`, including arena reset + `compact()` of pipelined leftovers between requests, and the keep-alive decision (reuse `keep_alive`, `max_keep_alive_requests`, request persistence — port `isPersistent` use from `src/server.zig`).

- [ ] **Step 1: Write failing tests:**
```zig
test "conn: one request → 200 response → close (keep_alive off)" {
    // Dispatcher returns Response.text("hi"); FakeTransport scripts one request, keep_alive=false.
    // step() drives to done_close; ft.written contains a full valid 200 with "hi".
}
test "conn: two pipelined keep-alive requests, two responses in order" {
    // FakeTransport delivers two requests in one chunk; Dispatcher echoes path.
    // Assert ft.written contains response1 then response2; arena reset between; served==2.
}
test "conn: keep-alive idle then second request on a later read" { /* want_read between requests */ }
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** `step()` as the state machine driving Tasks 2–3 + the `Dispatcher`, returning `want_read`/`want_write`/`done_close`. Fire the observer hook if present (port from `handleConn`; the worker passes the observer list via the dispatcher context or a field — keep it optional/zero-cost when none). Buffered streamer handling: if `resp.streamer != null`, render into `write_buf` up to capacity; over cap → synthesize `500` + mark closing.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(reactor): conn full request/response cycle + keep-alive + pipelining`.

---

### Task 5: Conn — error paths, limits, deadlines

**Files:** Modify `src/reactor/conn.zig`; tests in-file.

**Interfaces:**
- Consumes: `err`/`Response.fromStatus` + `terminalResponse` equivalents from `src/server.zig`/`src/http/response.zig`.
- Produces: error → proper status (`400` malformed head, `411` chunked, `413` body too large), peer close/RST → `closing`; a `deadline_ns: i96` field set on state entry (read deadline in `reading_head`/`reading_body`, idle deadline in `keep_alive_idle`) using `read_timeout_ms`/`idle_timeout_ms`; a `fn onDeadline(self) StepResult` that emits `408` (read) or closes (idle). Reuse `nowNs`/`msTimeout` patterns (factor them out of `src/server.zig` into a shared spot if needed, or duplicate the tiny helper).

- [ ] **Step 1: Write failing tests:** malformed head → response starts `HTTP/1.1 400`; chunked → `411`; oversized body → `413`; `onDeadline` in `reading_head` → `408` then close; `onDeadline` in `keep_alive_idle` → close, no bytes written.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the error mapping + deadline fields/handler.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(reactor): conn error responses, limits, deadlines`.

---

### Task 6: Timer wheel

**Files:** Create `src/reactor/timer.zig`; tests in-file.

**Interfaces:**
- Produces:
  ```zig
  pub const TimerWheel = struct {
      // coarse buckets at tick_ms granularity; intrusive slot ids (connection indices).
      pub fn init(gpa, tick_ms: u32, wheel_size: usize) !TimerWheel;
      pub fn insert(self: *TimerWheel, slot: usize, deadline_ns: i96) void;
      pub fn remove(self: *TimerWheel, slot: usize) void;
      /// advance to `now_ns`, calling `expired(slot)` for each due slot.
      pub fn advance(self: *TimerWheel, now_ns: i96, expired: *const fn (slot: usize) void) void;
      pub fn nextDeadlineMs(self: *TimerWheel, now_ns: i96) i32; // for epoll_wait timeout; -1 if empty
  };
  ```

- [ ] **Step 1: Write failing tests:** insert 3 slots at different deadlines; `advance` past the first → only slot 1 expired; `remove` a slot before its deadline → not expired; `nextDeadlineMs` returns the soonest. Use injected `now_ns` (no real clock — pass timestamps), satisfying the "no `Date.now` in tests" style.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the wheel (an array of buckets, each a small list of slot ids; map slot→bucket for O(1) remove).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(reactor): coarse per-worker timer wheel`.

---

### Task 7: Poller (epoll wrapper) — Linux, Docker-tested

**Files:** Create `src/reactor/poller.zig`. Guard the whole impl behind `if (builtin.os.tag == .linux)`; on other OSes expose the same type with bodies that `@compileError`-free no-op or `unreachable` (it's never constructed off-Linux). Library must still compile on macOS.

**Interfaces:**
- Produces:
  ```zig
  pub const Event = struct { data: u64, readable: bool, writable: bool, hup: bool };
  pub const Poller = struct {
      epfd: i32,
      pub fn init() !Poller;                 // std.posix.epoll_create1(0)
      pub fn deinit(self: *Poller) void;
      pub fn add(self, fd: i32, data: u64, read: bool, write: bool) !void;  // epoll_ctl ADD
      pub fn mod(self, fd: i32, data: u64, read: bool, write: bool) !void;  // epoll_ctl MOD
      pub fn del(self, fd: i32) void;        // epoll_ctl DEL
      pub fn wait(self, events: []std.os.linux.epoll_event, timeout_ms: i32) usize; // epoll_wait
  };
  ```
  Use `std.posix.epoll_create1`, `std.posix.epoll_ctl`, `std.posix.epoll_wait`, `std.os.linux.EPOLL.{IN,OUT,RDHUP,ERR,HUP}`, level-triggered (no `EPOLLET`) for v1. Pack `data` with the connection slot index.

- [ ] **Step 1 (Docker integration test):** add a Docker-run smoke that creates a `Poller`, registers an `eventfd`, writes to it, and asserts `wait` returns it readable. Put it behind a Linux-only `test {}` and run via the Docker harness (it won't run in macOS `zig build test`).
- [ ] **Step 2: Implement** the wrapper.
- [ ] **Step 3: Verify** in Docker: `docker run ... bash -c 'cd /zax && zig build test'` (Linux build runs the Linux-only tests too). Expected: pass.
- [ ] **Step 4: Commit** — `feat(reactor): epoll poller (linux)`.

---

### Task 8: Worker — listen, accept, event loop, timer sweep, shutdown

**Files:** Create `src/reactor/worker.zig`. Linux-guarded like Task 7.

**Interfaces:**
- Consumes: `Poller` (T7), `Conn` (T2–5), `TimerWheel` (T6), `Transport` (T1 — implement a **real socket transport** here: `readFn`/`writeFn` calling `std.posix.recv`/`send`, mapping `error.WouldBlock`→`.would_block`, `0`/`ECONNRESET`→`.closed`), and a `Dispatcher` built from `*App`.
- Produces:
  ```zig
  pub const Worker = struct {
      pub fn init(gpa, app_dispatcher: Dispatcher, opts: WorkerOpts, addr, shutdown: *std.atomic.Value(bool)) !Worker;
      pub fn run(self: *Worker) void;   // listen(SO_REUSEPORT) → epoll loop until shutdown
      pub fn wake(self: *Worker) void;  // write the eventfd to break epoll_wait (shutdown)
  };
  ```
  Listen socket: `std.posix.socket(AF.INET, SOCK.STREAM | SOCK.NONBLOCK | SOCK.CLOEXEC, 0)`, `setsockopt SO_REUSEADDR + SO_REUSEPORT`, `bind`, `listen`. Accept loop: `std.posix.accept4(lfd, ..., SOCK.NONBLOCK | SOCK.CLOEXEC)` in a loop until `WouldBlock`; set `TCP_NODELAY` per the existing option; allocate a connection slot (preallocated pool, bounded by `max_connections`), `poller.add(connfd, slot, read=true, write=false)`. On each event: look up the slot, build the socket `Transport`, call `conn.step`; arm read/write per `StepResult`; `done_close` → `poller.del` + close + free slot + `timer.remove`. After draining events, `timer.advance(nowNs, expireCb)` (expire → `conn.onDeadline` → write 408 best-effort + close). An `eventfd` registered in epoll handles `wake()` for shutdown: on shutdown flag, stop accepting, drain in-flight, return.

  **ctx.io decision:** `App.dispatch` needs an `io` for `makeCtx`. First **verify what `ctx.io` is used for** (grep handlers/extractors/`makeCtx`). If it's only consumed by streaming/response paths the reactor owns, pass a harmless default. Otherwise give each worker a process/default `std.Io` (e.g. derived from the `init.io` passed into `serveEvented`) purely for handler context, and **document that blocking IO inside a handler stalls that worker** (the standard reactor constraint). Implement the `Dispatcher.dispatchFn` to call `app.dispatch(captured_io, req, arena, rid)`.

- [ ] **Step 1 (Docker integration test):** Linux-only `test {}` (run in Docker): start one `Worker` on an ephemeral port in a thread, connect a raw `std.posix` client socket, send `GET / HTTP/1.1\r\n\r\n`, assert a `200`/`hello` response; send a second request on the same connection (keep-alive); then `wake()` + join, assert clean shutdown.
- [ ] **Step 2: Implement** the worker.
- [ ] **Step 3: Verify** in Docker `zig build test`. Expected: pass.
- [ ] **Step 4: Commit** — `feat(reactor): epoll worker (listen/accept/loop/timeouts/shutdown)`.

---

### Task 9: `App.serveEvented` + shutdown wiring

**Files:** Modify `src/server.zig` (additive); maybe `src/root.zig` exports.

**Interfaces:**
- Produces:
  ```zig
  pub const EventedOptions = struct { workers: usize = 0, max_connections: usize = 0 };
  pub fn serveEvented(self: *App, io: Io, addr: net.IpAddress, opts: EventedOptions) error{EventedUnsupported}!void;
  ```
  (`io` is taken only to source a handler-context `Io` per Task 8's decision; if Task 8 finds `ctx.io` unused by handlers, drop the param.) On non-Linux: `return error.EventedUnsupported;`. On Linux: spawn `workers` (0 → `std.Thread.getCpuCount()`) `Worker` threads sharing one `shutting_down` atomic; build each worker's `Dispatcher` from `self`; join all. Extend `requestShutdown` to also set the flag and `wake()` every worker (store worker `wake` handles/eventfds on the `App` when evented).

- [ ] **Step 1 (Docker integration test):** Linux-only `test {}`: `app.serveEvented` with `.workers = 2` in a thread; fire 50 concurrent keep-alive requests across the 3 bench routes via raw client sockets; assert all 50 correct; `requestShutdown`; assert `serveEvented` returns.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify** macOS `zig build test` (compiles; `serveEvented` returns `error.EventedUnsupported` — add that tiny test, runs on mac) AND Docker `zig build test` (the integration test). Baseline grows.
- [ ] **Step 4: Commit** — `feat(server): App.serveEvented (linux epoll backend, opt-in)`.

---

### Task 10: Bench integration + Docker comparison

**Files:** Modify `benchmarks/cross/zax/src/main.zig` (env `ZAX_BACKEND=evented` → call `serveEvented` instead of `serve`; default `threaded`), `benchmarks/cross/run.sh` (a way to run the evented zax variant), and reuse `benchmarks/cross/docker/`.

- [ ] **Step 1:** Add the `ZAX_BACKEND` switch to the bench server; print the active backend on boot; curl-smoke both backends locally (threaded on mac; evented will `error.EventedUnsupported` on mac — that's expected, it runs in Docker).
- [ ] **Step 2:** Run the Docker cross-bench `PIN=1` with evented zax alongside threaded zax + httpz + axum + go.
- [ ] **Step 3:** Record results in `benchmarks/cross/results.md`: does evented zax reach httpz/axum-class throughput + sub-few-ms p99.9 while keeping best-in-class p50? (Success criterion 3.)
- [ ] **Step 4: Commit** — `bench(cross): evented zax backend vs httpz/axum/go (linux)`.

---

## Self-Review notes (coverage)

- Spec §Architecture/components → Tasks 1–9 (transport, conn, timer, poller, worker, serveEvented). ✅
- Spec §state machine (all states + backpressure + pipelining) → Tasks 2–5. ✅
- Spec §timeouts (timer wheel, 408/idle close, reuse Options) → Tasks 5–6, enforced in 8. ✅
- Spec §threading (N workers, SO_REUSEPORT, shared-nothing, ncpu) → Tasks 8–9. ✅
- Spec §error handling/limits (max_connections, RST, fd-exhaustion) → Tasks 5, 8. ✅
- Spec §observability (reuse observer hook) → Task 4. ✅
- Spec §streaming v1 (buffer-cap, defer true streaming) → Task 4. ✅
- Spec §testing (fake-transport unit tests on mac; Docker integration; cross-bench) → Tasks 1–6 (mac), 7–9 (Docker), 10 (bench). ✅
- Spec §API (`serveEvented`, `EventedOptions`, `error.EventedUnsupported`) → Task 9. ✅
- Spec §out-of-scope (kqueue/TLS/HTTP2/true-streaming) → not implemented; threaded backend untouched. ✅
- Open implementation question flagged for the implementer: `ctx.io` usage in `dispatch` (Task 8) — verify before wiring; documented constraint either way.
