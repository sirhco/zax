# Connection Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add request body/header size limits (413/431) and read/idle timeouts (408 + idle close) to the Zax server, defeating oversized-request and slowloris/idle DoS.

**Architecture:** Replace the buffered `Io.Reader` read path with a manual `ConnReader` that fills a connection buffer via `socket.receiveTimeout` (validated on TCP by spike). Head/body stay zero-copy slices into that buffer; compaction happens only at request boundaries so parsed slices never move mid-request. Timeouts are `Io.Timeout` deadlines; limits are checked against the buffer and `Options`.

**Tech Stack:** Zig 0.16.0, `std.Io`/`std.Io.net`. Spec: `docs/superpowers/specs/2026-06-15-connection-hardening-design.md`. Branch: `feat/connection-hardening`.

**Conventions:** Tests via `zig build test --summary all`. TDD per task. Do NOT touch main. Timing tests use small timeouts and run 3×.

**Key API (validated):**
- `stream.socket.receiveTimeout(io, buf: []u8, timeout: Io.Timeout) !IncomingMessage` — `msg.data` is the received slice (into `buf`); `error.Timeout` on expiry; `msg.data.len == 0` means peer closed.
- Timeout value: `.none` (disabled/blocking) or `.{ .duration = .{ .raw = Io.Duration.fromMilliseconds(n), .clock = .awake } }`.
- `Io.sleep(io, Io.Duration.fromMilliseconds(n), .awake)` (used in timing tests).

---

## File Structure

- **Modify** `src/http/response.zig` — add `Status` 408/413/431.
- **Modify** `src/server.zig` — `Options` fields; new `ConnReader`, `msTimeout`, `readHead`/`readBody`, `terminalResponse`; rewrite `handleConn`; delete old `readHead`/`attachBody`/`ReadError`; tests.
- **Modify** `README.md`, `docs/getting-started.md` — document limits/timeouts.

---

## Task 1: Add 408/413/431 statuses

**Files:** Modify `src/http/response.zig`

- [ ] **Step 1: Write the failing test** — add to the test section:

```zig
test "hardening statuses: 408/413/431 codes and reasons" {
    try testing.expectEqual(@as(u16, 408), Status.request_timeout.code());
    try testing.expectEqualStrings("Request Timeout", Status.request_timeout.reason());
    try testing.expectEqual(@as(u16, 413), Status.payload_too_large.code());
    try testing.expectEqualStrings("Payload Too Large", Status.payload_too_large.reason());
    try testing.expectEqual(@as(u16, 431), Status.request_header_fields_too_large.code());
    try testing.expectEqualStrings("Request Header Fields Too Large", Status.request_header_fields_too_large.reason());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error|request_timeout"`
Expected: compile error — `Status` has no member `request_timeout`.

- [ ] **Step 3: Implement** — in the `Status` enum, add these members (place `request_timeout` after `length_required = 411,` / `too_many_requests = 429,`; group sensibly):

```zig
    request_timeout = 408,
    payload_too_large = 413,
    request_header_fields_too_large = 431,
```

And in the `reason` switch add:

```zig
            .request_timeout => "Request Timeout",
            .payload_too_large => "Payload Too Large",
            .request_header_fields_too_large => "Request Header Fields Too Large",
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat(http): add 408/413/431 statuses for connection hardening"
```

---

## Task 2: `ConnReader` + `msTimeout` helper

Adds the buffer/receive primitive and the timeout builder. The buffer mechanics (`buffered`/`consume`/`compact`) are unit-tested without a socket; `fill` is covered by integration in later tasks.

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing unit test** — add to the test section of `src/server.zig` (near the other tests):

```zig
test "ConnReader buffer mechanics: buffered/consume/compact" {
    var backing: [16]u8 = "ABCDEFGH________".*;
    var cr = ConnReader{ .socket = undefined, .io = undefined, .buf = &backing, .start = 0, .end = 8 };
    try testing.expectEqualStrings("ABCDEFGH", cr.buffered());
    cr.consume(3); // drop "ABC"
    try testing.expectEqualStrings("DEFGH", cr.buffered());
    cr.compact(); // move "DEFGH" to front
    try testing.expectEqual(@as(usize, 0), cr.start);
    try testing.expectEqual(@as(usize, 5), cr.end);
    try testing.expectEqualStrings("DEFGH", cr.buffered());
    try testing.expectEqualStrings("DEFGH", backing[0..5]);
}

test "msTimeout: 0 disables, n builds a duration" {
    try testing.expect(msTimeout(0) == .none);
    const t = msTimeout(100);
    try testing.expect(t == .duration);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error:|ConnReader|msTimeout"`
Expected: compile error — `ConnReader` and `msTimeout` undefined.

- [ ] **Step 3: Implement** — add to `src/server.zig`. Put `ConnReader` and `msTimeout` near the other free helpers, just before the line `const ReadError = error{ HeadTooLarge, IncompleteRequest };` (that line is removed in Task 3; for now add above it):

```zig
/// Build an Io.Timeout from milliseconds; 0 means no timeout (blocking).
fn msTimeout(ms_val: u32) Io.Timeout {
    if (ms_val == 0) return .none;
    return .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(@intCast(ms_val)), .clock = .awake } };
}

/// A manual, timeout-capable connection reader. Owns a fixed buffer and a
/// [start, end) window of received-but-unconsumed bytes. Compaction runs only at
/// request boundaries, so slices the parser hands out never move mid-request.
const ConnReader = struct {
    socket: net.Socket,
    io: Io,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    const FillError = error{ Timeout, BufferFull, Closed };

    fn buffered(self: *const ConnReader) []const u8 {
        return self.buf[self.start..self.end];
    }

    fn consume(self: *ConnReader, n: usize) void {
        self.start += n;
    }

    fn compact(self: *ConnReader) void {
        if (self.start == 0) return;
        const len = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..len], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = len;
    }

    /// Receive more bytes (up to the buffer's free tail) with `timeout`. Never
    /// compacts (callers keep start==0 during a request), so returns BufferFull
    /// when the buffer is full rather than moving in-use slices.
    fn fill(self: *ConnReader, timeout: Io.Timeout) FillError!void {
        if (self.end == self.buf.len) return error.BufferFull;
        const msg = self.socket.receiveTimeout(self.io, self.buf[self.end..], timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return error.Closed,
        };
        if (msg.data.len == 0) return error.Closed;
        self.end += msg.data.len;
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all tests pass (2 new).

- [ ] **Step 5: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): add ConnReader and msTimeout helper"
```

---

## Task 3: Rewrite the read path (limits + timeouts) and `handleConn`

Replaces the `Io.Reader`-based read with `ConnReader`, adds the limit checks (413/431) and timeout deadlines, and the terminal-error responder. Existing keep-alive/pipelining/error tests must stay green.

**Files:** Modify `src/server.zig` (Options, helpers, handleConn, delete old helpers, tests)

- [ ] **Step 1: Write the failing deterministic tests** — add to the test section of `src/server.zig` (after the error tests). They use existing helpers `TestApp`, `Db`, `pingHandler`, `startTestApp`, `doRequest`, `Response`, `Io`, `testing`:

```zig
test "limits: oversized body returns 413" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{ .max_body_size = 10 });
    defer app.deinit();
    try app.post("/u", pingHandler);

    const port: u16 = 18110;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    // Content-Length 20 exceeds max_body_size 10.
    const r = doRequest(io, port, "POST /u HTTP/1.1\r\nContent-Length: 20\r\n\r\n01234567890123456789", &rb);
    try testing.expect(std.mem.indexOf(u8, r, "413 Payload Too Large") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "limits: oversized header block returns 431" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    // Tiny read buffer so the header block overflows it.
    var app = try TestApp.init(testing.allocator, &db, .{ .read_buffer_size = 64 });
    defer app.deinit();
    try app.get("/", pingHandler);

    const port: u16 = 18111;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    const long = "GET / HTTP/1.1\r\nX-Long: " ++ ("a" ** 120) ++ "\r\n\r\n";
    const r = doRequest(io, port, long, &rb);
    try testing.expect(std.mem.indexOf(u8, r, "431 Request Header Fields Too Large") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | grep -E "413|431|error:|FAIL"`
Expected: FAIL — current path returns 400 (or hangs/closes) for these, not 413/431.

- [ ] **Step 3: Add the Options fields** — in `pub const Options = struct { ... }` in `src/server.zig`, add (after `max_keep_alive_requests` / before `trust_forwarded`):

```zig
    /// Reject a body whose Content-Length exceeds this (413). 0 = bounded only
    /// by the read buffer. Effective limit = min(max_body_size, read_buffer_size
    /// − head length).
    max_body_size: usize = 0,
    /// Deadline (ms) to receive a request's full head+body once its first byte
    /// arrives. Defeats slow-trickle. 0 = no timeout.
    read_timeout_ms: u32 = 30_000,
    /// Max wait (ms) for the next request on a keep-alive connection. 0 = none.
    idle_timeout_ms: u32 = 60_000,
```

- [ ] **Step 4: Add the new read helpers + terminal responder** — in `src/server.zig`, replace the OLD free helpers (delete exactly these):

```zig
const ReadError = error{ HeadTooLarge, IncompleteRequest };

/// Fill the reader until a full request head is buffered, returning a `Parsed`
/// whose slices point into the reader buffer (body not yet attached).
fn readHead(r: *Io.Reader, hs: *[request.max_headers]Header) ReadError!parser.Parsed {
    while (true) {
        if (parser.parseHead(r.buffered(), hs)) |p| {
            return p;
        } else |err| switch (err) {
            error.Incomplete => {},
            else => return error.IncompleteRequest,
        }
        r.fillMore() catch return error.IncompleteRequest;
        if (r.buffered().len == r.buffer.len) return error.HeadTooLarge;
    }
}

/// Ensure the Content-Length body is buffered and attach it as a zero-copy slice.
fn attachBody(r: *Io.Reader, parsed: *parser.Parsed) ReadError!void {
    if (parsed.request.contentLength()) |clen| {
        while (r.buffered().len < parsed.head_len + clen) {
            r.fillMore() catch return error.IncompleteRequest;
        }
        parsed.request.body = r.buffered()[parsed.head_len .. parsed.head_len + clen];
    }
}
```

with the NEW versions:

```zig
const RequestError = error{
    HeaderFieldsTooLarge, // -> 431
    BodyTooLarge, // -> 413
    Timeout, // -> 408
    Malformed, // -> 400
    Closed, // -> close, no response
};

/// Fill until a full head is parsed. The first receive (no bytes yet for this
/// request) uses the idle deadline; subsequent receives use the read deadline.
fn readHead(cr: *ConnReader, hs: *[request.max_headers]Header, read_to: Io.Timeout, idle_to: Io.Timeout) RequestError!parser.Parsed {
    while (true) {
        if (parser.parseHead(cr.buffered(), hs)) |p| {
            return p;
        } else |err| switch (err) {
            error.Incomplete => {},
            error.TooManyHeaders => return error.HeaderFieldsTooLarge,
            else => return error.Malformed,
        }
        const waiting_for_first_byte = cr.buffered().len == 0;
        cr.fill(if (waiting_for_first_byte) idle_to else read_to) catch |e| switch (e) {
            error.Timeout => return if (waiting_for_first_byte) error.Closed else error.Timeout,
            error.BufferFull => return error.HeaderFieldsTooLarge,
            error.Closed => return error.Closed,
        };
    }
}

/// Validate Content-Length against the effective limit, then fill until the body
/// is buffered and attach it as a zero-copy slice.
fn readBody(cr: *ConnReader, parsed: *parser.Parsed, max_body: usize, read_to: Io.Timeout) RequestError!void {
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
}

/// Send the terminal response for a RequestError (or nothing for Closed).
fn terminalResponse(w: *Io.Writer, e: RequestError) void {
    switch (e) {
        error.HeaderFieldsTooLarge => _ = writeResponse(w, Response.fromStatus(.request_header_fields_too_large)),
        error.BodyTooLarge => _ = writeResponse(w, Response.fromStatus(.payload_too_large)),
        error.Timeout => _ = writeResponse(w, Response.fromStatus(.request_timeout)),
        error.Malformed => _ = writeResponse(w, Response.fromStatus(.bad_request)),
        error.Closed => {},
    }
}
```

- [ ] **Step 5: Rewrite `handleConn`** — replace the entire existing `handleConn` method. The current one is:

```zig
        fn handleConn(self: *Self, io: Io, stream_in: net.Stream) void {
            var stream = stream_in;
            defer stream.close(io);

            const read_buf = self.gpa.alloc(u8, self.opts.read_buffer_size) catch return;
            defer self.gpa.free(read_buf);
            const write_buf = self.gpa.alloc(u8, self.opts.write_buffer_size) catch return;
            defer self.gpa.free(write_buf);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            var sr = stream.reader(io, read_buf);
            var sw = stream.writer(io, write_buf);
            const r = &sr.interface;
            const w = &sw.interface;

            var served: usize = 0;
            while (true) {
                _ = arena.reset(.retain_capacity);

                var hs: [request.max_headers]Header = undefined;
                var parsed = readHead(r, &hs) catch break; // EOF or malformed head -> close

                // Chunked request bodies are unsupported: reject and close.
                if (parsed.request.isChunked()) {
                    _ = writeResponse(w, Response.fromStatus(.length_required));
                    break;
                }
                attachBody(r, &parsed) catch break;
                const consumed = parsed.head_len + parsed.request.body.len;

                const persistent = self.opts.keep_alive and
                    parsed.request.isPersistent() and
                    (served + 1) < self.opts.max_keep_alive_requests;

                var resp = self.dispatch(&parsed.request, &arena);
                resp.keep_alive = persistent;
                if (!writeResponse(w, resp)) break;

                r.toss(consumed);
                served += 1;
                if (!persistent) break;
            }
        }
```

Replace it with:

```zig
        fn handleConn(self: *Self, io: Io, stream_in: net.Stream) void {
            var stream = stream_in;
            defer stream.close(io);

            const read_buf = self.gpa.alloc(u8, self.opts.read_buffer_size) catch return;
            defer self.gpa.free(read_buf);
            const write_buf = self.gpa.alloc(u8, self.opts.write_buffer_size) catch return;
            defer self.gpa.free(write_buf);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            var cr = ConnReader{ .socket = stream.socket, .io = io, .buf = read_buf };
            var sw = stream.writer(io, write_buf);
            const w = &sw.interface;

            const read_to = msTimeout(self.opts.read_timeout_ms);
            const idle_to = msTimeout(self.opts.idle_timeout_ms);

            var served: usize = 0;
            while (true) {
                _ = arena.reset(.retain_capacity);
                cr.compact(); // request boundary: move pipelined leftover to front (start=0)

                var hs: [request.max_headers]Header = undefined;
                var parsed = readHead(&cr, &hs, read_to, idle_to) catch |e| {
                    terminalResponse(w, e);
                    break;
                };

                // Chunked request bodies are unsupported: reject and close.
                if (parsed.request.isChunked()) {
                    _ = writeResponse(w, Response.fromStatus(.length_required));
                    break;
                }

                readBody(&cr, &parsed, self.opts.max_body_size, read_to) catch |e| {
                    terminalResponse(w, e);
                    break;
                };
                const consumed = parsed.head_len + parsed.request.body.len;

                const persistent = self.opts.keep_alive and
                    parsed.request.isPersistent() and
                    (served + 1) < self.opts.max_keep_alive_requests;

                var resp = self.dispatch(&parsed.request, &arena);
                resp.keep_alive = persistent;
                if (!writeResponse(w, resp)) break;

                cr.consume(consumed);
                served += 1;
                if (!persistent) break;
            }
        }
```

- [ ] **Step 6: Run the full suite + the new limit tests**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all tests pass — the 413/431 tests plus every existing keep-alive/pipelining/error/405 test (the rewrite must preserve them).

- [ ] **Step 7: Flakiness check**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.

- [ ] **Step 8: Commit**

```bash
git add src/server.zig
git commit -m "feat(server): ConnReader read path with body/header limits (413/431) and timeouts"
```

---

## Task 4: Timeout behavior tests (408 + idle close)

The timeout logic ships in Task 3; this task proves it with timing tests using small timeouts.

**Files:** Modify `src/server.zig` (tests only)

- [ ] **Step 1: Write the verifying tests** — add to the test section of `src/server.zig`. These manage the client connection manually (partial sends + sleeps). Note each uses a SEPARATE buffer for the reader (`rb`) and the `readResp` copy-out (`out`) to avoid aliasing:

```zig
test "timeout: slow header (slowloris) returns 408 then closes" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{ .read_timeout_ms = 100 });
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18112;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);

    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    cw.interface.writeAll("GET /ping HTTP/1.1\r\n") catch unreachable; // partial, no terminator
    cw.interface.flush() catch unreachable;

    Io.sleep(io, Io.Duration.fromMilliseconds(300), .awake) catch {};

    var rb: [1024]u8 = undefined;
    var rdr = cs.reader(io, &rb);
    var out: [1024]u8 = undefined;
    const resp = readResp(&rdr.interface, &out); // reads the 408 head (content-length 0)
    try testing.expect(std.mem.indexOf(u8, resp, "408 Request Timeout") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}

test "timeout: idle keep-alive connection is closed after idle_timeout" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "pong" };
    var app = try TestApp.init(testing.allocator, &db, .{ .idle_timeout_ms = 100 });
    defer app.deinit();
    try app.get("/ping", pingHandler);

    const port: u16 = 18113;
    var loop_fut = startTestApp(io, &app, port);

    var caddr: net.IpAddress = .{ .ip4 = .loopback(port) };
    var cs = caddr.connect(io, .{ .mode = .stream }) catch unreachable;
    defer cs.close(io);

    var wb: [128]u8 = undefined;
    var cw = cs.writer(io, &wb);
    var rb: [1024]u8 = undefined;
    var rdr = cs.reader(io, &rb);

    // One full request + response, keeping the connection open.
    cw.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n") catch unreachable;
    cw.interface.flush() catch unreachable;
    var out: [1024]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, readResp(&rdr.interface, &out), "pong"));

    // Now stall past idle_timeout; the server should close the connection.
    Io.sleep(io, Io.Duration.fromMilliseconds(300), .awake) catch {};
    try testing.expectError(error.EndOfStream, rdr.interface.fillMore());

    app.requestShutdown(io);
    loop_fut.await(io);
}
```

- [ ] **Step 2: Run to verify they pass**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|408|error"`
Expected: all tests pass (the timeout behavior was implemented in Task 3).

- [ ] **Step 3: Flakiness check (timing-sensitive)**

Run: `for i in 1 2 3 4 5; do zig build test >/dev/null 2>&1 && echo "run $i ok" || echo "run $i FAIL"; done`
Expected: five ok lines. If any flakes, increase the sleeps (300→500 ms) — the timeouts (100 ms) plus a generous sleep should be stable on loopback.

- [ ] **Step 4: Commit**

```bash
git add src/server.zig
git commit -m "test(server): verify 408 slowloris and idle-timeout connection close"
```

---

## Task 5: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: Update README limitations** — in `README.md` under `## Status & limitations`:
  - In the shipped list (the "**Shipped:**" sentence), add `request size limits, and read/idle timeouts` to the list of shipped features.
  - In the "A keep-alive **idle timeout** is not yet wired..." sentence, DELETE that clause (idle timeout now exists). Keep the SIGINT note.

Concretely, replace the paragraph:

```
A keep-alive **idle timeout** is not yet wired (connections close on client
disconnect or the per-connection request cap); and a `SIGINT`/`SIGTERM` handler
is not auto-installed (`Io.Threaded` uses signals for cancellation) — wire one to
call `app.requestShutdown(io)`.
```

with:

```
A `SIGINT`/`SIGTERM` handler is not auto-installed (`Io.Threaded` uses signals
for cancellation) — wire one to call `app.requestShutdown(io)`.
```

- [ ] **Step 2: Add a README hardening note** — insert this subsection immediately before `## Performance` (after the `## Error handling` section):

```markdown
## Limits & timeouts

Configurable via `ServerOptions`:

| Option | Default | Effect |
|---|---|---|
| `max_body_size` | `0` (buffer-bound) | Content-Length over the limit → `413` |
| `read_timeout_ms` | `30000` | full head+body must arrive within this once started → `408` |
| `idle_timeout_ms` | `60000` | max wait for the next keep-alive request → connection closed |

Request bodies are buffered in the read buffer, so they are bounded by
`read_buffer_size`; oversized header blocks return `431`. Set a timeout to `0` to
disable it.
```

- [ ] **Step 3: Add a getting-started note** — in `docs/getting-started.md`, in the "## 4. Write the service" section near the `### Errors` subsection, add:

```markdown
### Limits & timeouts

Harden the server via options: `max_body_size` (413 over-limit), `read_timeout_ms`
(408 on slow requests), `idle_timeout_ms` (close idle keep-alive connections):

```zig
var app = try Api.init(init.gpa, &store, .{
    .max_body_size = 1 << 20,
    .read_timeout_ms = 15_000,
    .idle_timeout_ms = 30_000,
});
```
```

(The inner ```zig fence is part of the content; write balanced fences in the file.)

- [ ] **Step 4: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document request size limits and read/idle timeouts"
```

---

## Final verification

- [ ] Full suite, 3×:

Run: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done`
Expected: three identical pass lines.

- [ ] Live smoke (optional): `zig build run` (demo uses default 30s/60s timeouts), confirm normal requests still work; oversized/slow behavior is covered by the automated tests.

---

## Self-review notes (already applied)

- **Spec coverage:** statuses (Task 1); ConnReader + msTimeout (Task 2); Options + readHead/readBody limits + timeout deadlines + handleConn rewrite + 413/431 tests (Task 3); 408/idle timing tests (Task 4); docs (Task 5). All spec sections covered.
- **Slice-safety:** `fill` never compacts; `compact` runs only at the request boundary in `handleConn` (start==0 during a request), so parsed head/body slices never move mid-request. `readBody`'s limit (`≤ buf − head`) guarantees the body fits without the buffer filling.
- **Type consistency:** `ConnReader{socket,io,buf,start,end}`, `FillError{Timeout,BufferFull,Closed}`, `RequestError{HeaderFieldsTooLarge,BodyTooLarge,Timeout,Malformed,Closed}`, `msTimeout(u32)->Io.Timeout`, `readHead(cr,hs,read_to,idle_to)`, `readBody(cr,parsed,max_body,read_to)`, `terminalResponse(w,e)` — consistent across tasks; statuses `request_timeout`/`payload_too_large`/`request_header_fields_too_large` match Task 1.
- **No placeholders:** complete code in every step; the one awkward test draft in Task 4 is explicitly replaced by the full version with a delete instruction.
- **Back-compat:** default timeouts (30s/60s) and `max_body_size=0` leave existing fast tests unaffected; `0` → `.none` → blocking (current behavior).
```
