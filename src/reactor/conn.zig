//! Non-blocking per-connection state machine — read, parse, dispatch, write.
//!
//! `Conn` wraps two caller-owned buffers (read + write) and drives HTTP/1.1
//! request ingestion without blocking the calling thread. All IO is mediated
//! through the `Transport` vtable so the logic is fully unit-testable on any
//! platform via `FakeTransport`.
//!
//! Task 2 scope: `fillAndParse` — fill the read buffer from the transport,
//! parse the request head, validate no chunked encoding, read the body by
//! Content-Length, and return a `ParseOutcome`.  Response serialisation,
//! dispatch, keep-alive, and the `step` driver are added in Tasks 3–4.
//! Task 5 adds error→status mapping, deadlines, and truncation signalling.

const std = @import("std");
const parser = @import("../http/parser.zig");
const request = @import("../http/request.zig");
const response_mod = @import("../http/response.zig");
const transport_mod = @import("transport.zig");

const Response = response_mod.Response;

const Transport = transport_mod.Transport;
const Header = request.Header;

// ---------------------------------------------------------------------------
// Dispatcher — decouples Conn from App (Task 4)
// ---------------------------------------------------------------------------

/// Vtable-based dispatch indirection so `Conn` does not import `App`.
/// The worker (Task 8) builds this from `App.dispatch`.
pub const Dispatcher = struct {
    ctx: *anyopaque,
    dispatchFn: *const fn (ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response,

    pub fn dispatch(self: Dispatcher, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
        return self.dispatchFn(self.ctx, req, arena);
    }
};

// ---------------------------------------------------------------------------
// State / StepResult — full enums wired across Tasks 2–5
// ---------------------------------------------------------------------------

/// Per-connection state machine states.
pub const State = enum {
    reading_head,
    reading_body,
    dispatching,
    writing,
    keep_alive_idle,
    closing,
};

/// What the worker event loop should arm after `step` returns.
/// (Used from Task 4 onwards; defined here so downstream tasks see the type.)
pub const StepResult = enum {
    want_read,
    want_write,
    done_close,
};

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

/// Errors that can arise while reading/parsing a request.
pub const RequestError = error{
    /// More than `request.max_headers` header fields present.
    HeaderFieldsTooLarge,
    /// Body exceeds `max_body_size` or the read buffer.
    BodyTooLarge,
    /// Request line or headers are syntactically invalid.
    Malformed,
    /// Chunked transfer-encoding is not supported (v1.1 → reject with 411).
    ChunkedNotSupported,
};

// ---------------------------------------------------------------------------
// ParseOutcome
// ---------------------------------------------------------------------------

/// Result of a single `fillAndParse` call.
pub const ParseOutcome = union(enum) {
    /// More bytes are needed — transport returned `.would_block`; re-arm read.
    need_more,
    /// A complete request (head + body) has been parsed.
    parsed: parser.Parsed,
    /// A protocol or limit error occurred.
    failed: RequestError,
    /// The peer closed the connection.
    closed,
};

// ---------------------------------------------------------------------------
// Conn
// ---------------------------------------------------------------------------

/// Default body size cap when the caller does not set `max_body_size`.
/// 0 means "bounded only by the read buffer".
const default_max_body_size: usize = 0;

/// Sentinel deadline_ns meaning "no deadline set / deadline disabled".
const no_deadline: i96 = std.math.maxInt(i96);

/// Return the current monotonic time in nanoseconds.
/// Uses the Linux vDSO clock_gettime syscall on Linux (no libc needed) and
/// std.c on other platforms (macOS).
pub fn monotonicNow() i96 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
    }
}

pub const Conn = struct {
    state: State = .reading_head,

    /// Caller-owned read buffer (lent from the worker pool).
    read_buf: []u8,
    /// Caller-owned write buffer (lent from the worker pool).
    write_buf: []u8,

    /// Offset into `read_buf` where unconsumed data starts.
    /// After a full request is consumed this advances to `head_len + body_len`
    /// so pipelined requests (Task 4) can continue from the remainder.
    r_start: usize = 0,
    /// Offset into `read_buf` one past the last byte received.
    r_end: usize = 0,

    /// Scratch storage for parsed headers; slices inside `Parsed.request.headers`
    /// point here — no heap allocation for the header array.
    header_scratch: [request.max_headers]Header = undefined,

    /// Arena for any per-request heap allocation (body copies, extractor results).
    arena: *std.heap.ArenaAllocator,

    /// Upper bound on the accepted body size in bytes.
    /// 0 = bounded only by the available read buffer space.
    max_body_size: usize = default_max_body_size,

    /// Number of valid bytes in `write_buf` (set by `serializeResponse`).
    w_len: usize = 0,
    /// Offset of the next byte to transmit (advanced by `pumpWrite`).
    w_off: usize = 0,

    // -----------------------------------------------------------------------
    // Task 4: keep-alive / pipeline fields
    // -----------------------------------------------------------------------

    /// Enable keep-alive on this connection. Mirrors `Options.keep_alive`.
    keep_alive: bool = true,
    /// Maximum requests to serve before closing. Mirrors `Options.max_keep_alive_requests`.
    max_keep_alive_requests: usize = 100,
    /// Number of requests fully served on this connection so far.
    served: usize = 0,
    /// When true, `step` must close after the current write completes
    /// (used when a response overflowed the write buffer or was a stream).
    close_after_write: bool = false,

    /// Observer hook: called after each response is serialized, before writing.
    /// Null = zero-cost no-op. Task 8 will wire this up; the seam is here.
    on_response: ?*const fn (req: *const request.Request, resp: *const Response) void = null,

    // -----------------------------------------------------------------------
    // Task 5: deadlines + timeout configuration
    // -----------------------------------------------------------------------

    /// Read deadline in ms. Applied when entering reading_head / reading_body.
    /// Mirrors Options.read_timeout_ms. 0 = no deadline.
    read_timeout_ms: u32 = 30_000,
    /// Idle keep-alive deadline in ms. Applied when entering keep_alive_idle.
    /// Mirrors Options.idle_timeout_ms. 0 = no deadline.
    idle_timeout_ms: u32 = 60_000,
    /// Absolute monotonic deadline in nanoseconds for the current state.
    /// Set by step() on state entry; read by the worker's timer wheel via
    /// `conn.deadline_ns`. Sentinel `no_deadline` means no active deadline.
    deadline_ns: i96 = no_deadline,

    /// Construct a `Conn` backed by the given lent buffers and arena.
    pub fn init(read_buf: []u8, write_buf: []u8, arena: *std.heap.ArenaAllocator) Conn {
        return .{
            .read_buf = read_buf,
            .write_buf = write_buf,
            .arena = arena,
        };
    }

    /// Buffered region: bytes received so far for the current request.
    fn buffered(self: *const Conn) []const u8 {
        return self.read_buf[self.r_start..self.r_end];
    }

    /// Read more bytes from the transport into `read_buf[r_end..]`, parse the
    /// request head, validate it, and read body bytes if Content-Length is set.
    ///
    /// **One call = one read attempt.** On a non-blocking socket (or
    /// `FakeTransport`) each successful read drains what the OS has buffered,
    /// then the next call blocks (would_block) until the event loop fires again.
    /// Callers drive the state machine by calling `fillAndParse` whenever the
    /// event loop indicates the fd is readable, stopping when the outcome is
    /// not `.need_more`.
    ///
    /// Zero-copy: `Parsed.request` fields are slices into `read_buf`; the
    /// buffer must remain live for the lifetime of the returned `Parsed`.
    pub fn fillAndParse(self: *Conn, t: Transport) ParseOutcome {
        self.state = .reading_head;

        // ----------------------------------------------------------------
        // Phase 1: if head already buffered, skip straight to body phase.
        // ----------------------------------------------------------------
        if (parser.parseHead(self.buffered(), &self.header_scratch)) |p| {
            return self.readBody(t, p);
        } else |err| switch (err) {
            error.Incomplete => {}, // fall through to read
            error.TooManyHeaders => return .{ .failed = error.HeaderFieldsTooLarge },
            else => return .{ .failed = error.Malformed },
        }

        // ----------------------------------------------------------------
        // Phase 2: read one batch of bytes, then re-attempt the parse.
        // ----------------------------------------------------------------
        const space = self.read_buf[self.r_end..];
        if (space.len == 0) {
            // Buffer full but head still incomplete → headers too large.
            return .{ .failed = error.HeaderFieldsTooLarge };
        }
        switch (t.read(space)) {
            .ok => |n| {
                if (n == 0) return .closed;
                self.r_end += n;
            },
            .would_block => return .need_more,
            .closed => return .closed,
        }

        // ----------------------------------------------------------------
        // Phase 3: try to parse with freshly received bytes.
        // ----------------------------------------------------------------
        if (parser.parseHead(self.buffered(), &self.header_scratch)) |p| {
            return self.readBody(t, p);
        } else |err| switch (err) {
            error.Incomplete => return .need_more,
            error.TooManyHeaders => return .{ .failed = error.HeaderFieldsTooLarge },
            else => return .{ .failed = error.Malformed },
        }
    }

    // ----------------------------------------------------------------
    // Phase 2: validate + read body by Content-Length.
    // ----------------------------------------------------------------
    fn readBody(self: *Conn, t: Transport, p: parser.Parsed) ParseOutcome {
        // Reject chunked transfer-encoding (v1.1 → 411 in Task 5).
        if (p.request.isChunked()) {
            return .{ .failed = error.ChunkedNotSupported };
        }

        // No Content-Length → body is empty; done.
        const clen = p.request.contentLength() orelse {
            var result = p;
            result.request.body = "";
            return .{ .parsed = result };
        };

        // Compute effective body limit.
        // The body must fit in read_buf after the head.
        const buf_bound = self.read_buf.len - (self.r_start + p.head_len);
        const limit = if (self.max_body_size == 0)
            buf_bound
        else
            @min(self.max_body_size, buf_bound);

        if (clen > limit) return .{ .failed = error.BodyTooLarge };

        self.state = .reading_body;

        // The absolute offset into read_buf where the body ends.
        const body_end = self.r_start + p.head_len + clen;

        // Fill until the full body is buffered.
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

        // Attach body as a zero-copy slice.
        var result = p;
        const head_abs = self.r_start + p.head_len;
        result.request.body = self.read_buf[head_abs .. head_abs + clen];
        return .{ .parsed = result };
    }

    // -----------------------------------------------------------------------
    // Task 3: response serialization + non-blocking write with backpressure
    // -----------------------------------------------------------------------

    /// Serialize `resp` into `write_buf` using a fixed-buffer writer (no IO).
    /// Sets `w_len` to the serialized byte count and resets `w_off` to 0.
    /// Returns the serialized length, or `error.ResponseTooLarge` if the
    /// response did not fit in `write_buf` (fixed writer overflowed).
    pub fn serializeResponse(self: *Conn, resp: Response) error{ResponseTooLarge}!usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        resp.write(&w) catch {
            // WriteFailed means the fixed buffer overflowed — signal truncation.
            self.w_len = w.end;
            self.w_off = 0;
            return error.ResponseTooLarge;
        };
        self.w_len = w.end;
        self.w_off = 0;
        return self.w_len;
    }

    /// Drive a non-blocking write of `write_buf[w_off..w_len]` through `t`.
    ///
    /// - `.ok n` → advance `w_off` by `n`; if `w_off == w_len` → `.wrote_all`.
    ///   A partial write (n < remaining) is treated like `.would_block` — the
    ///   caller should re-arm the writable event and call again.
    /// - `.would_block` → `.want_write` (resume next time the fd is writable).
    /// - `.closed` → `.closed`.
    pub fn pumpWrite(self: *Conn, t: Transport) enum { wrote_all, want_write, closed } {
        const remaining = self.write_buf[self.w_off..self.w_len];
        switch (t.write(remaining)) {
            .ok => |n| {
                self.w_off += n;
                if (self.w_off == self.w_len) return .wrote_all;
                return .want_write; // partial write — re-arm writable
            },
            .would_block => return .want_write,
            .closed => return .closed,
        }
    }

    // -----------------------------------------------------------------------
    // Task 4: compact + full step() state machine
    // -----------------------------------------------------------------------

    /// Move pipelined leftover bytes (`read_buf[r_start..r_end]`) to the
    /// front of the buffer, resetting `r_start = 0`. Mirrors `ConnReader.compact`
    /// in `src/server.zig`. Call at the start of each new request cycle.
    pub fn compact(self: *Conn) void {
        if (self.r_start == 0) return;
        const len = self.r_end - self.r_start;
        std.mem.copyForwards(u8, self.read_buf[0..len], self.read_buf[self.r_start..self.r_end]);
        self.r_start = 0;
        self.r_end = len;
    }

    /// Drive the connection state machine one step.
    ///
    /// Returns:
    /// - `.want_read`  — re-arm the readable event; call again when data arrives.
    /// - `.want_write` — re-arm the writable event; call again when fd is writable.
    /// - `.done_close` — the connection is finished; caller should close the fd.
    ///
    /// The machine loops internally when it can make synchronous progress
    /// (e.g. pipelined request already buffered after a write completes).
    pub fn step(self: *Conn, t: Transport, d: Dispatcher) StepResult {
        while (true) {
            switch (self.state) {
                .reading_head, .reading_body => {
                    // Set read deadline on state entry (first time or re-entry).
                    if (self.deadline_ns == no_deadline) {
                        self.deadline_ns = if (self.read_timeout_ms == 0)
                            no_deadline
                        else
                            monotonicNow() + @as(i96, self.read_timeout_ms) * 1_000_000;
                    }
                    switch (self.fillAndParse(t)) {
                        .need_more => return .want_read,
                        .closed => {
                            self.state = .closing;
                            return .done_close;
                        },
                        .failed => |e| {
                            // Map parse error → HTTP status.
                            const status: response_mod.Status = switch (e) {
                                error.Malformed => .bad_request, // 400
                                error.ChunkedNotSupported => .length_required, // 411
                                error.BodyTooLarge => .payload_too_large, // 413
                                error.HeaderFieldsTooLarge => .request_header_fields_too_large, // 431
                            };
                            var err_resp = Response.fromStatus(status);
                            err_resp.keep_alive = false;
                            self.deadline_ns = no_deadline;
                            self.close_after_write = true;
                            // Serialize; ignore truncation for error responses
                            // (a short error response is still sent best-effort).
                            _ = self.serializeResponse(err_resp) catch {};
                            self.state = .writing;
                            // fall through to writing on the next iteration
                        },
                        .parsed => |p| {
                            // Clear deadline — we successfully parsed.
                            self.deadline_ns = no_deadline;

                            // Advance r_start past this request so the next
                            // compact() sees only pipelined leftovers.
                            const consumed = p.head_len + p.request.body.len;
                            self.r_start += consumed;

                            // Keep-alive decision (mirrors server.zig handleConn).
                            const persistent = self.keep_alive and
                                p.request.isPersistent() and
                                (self.served + 1) < self.max_keep_alive_requests;

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
                        },
                    }
                },

                .writing => {
                    // Arm write-stall deadline on first entry.  A peer that
                    // advertises a zero/tiny receive window and never reads
                    // would hold the fd+slot indefinitely without this guard.
                    // We set it once (set-once: reuse read_timeout_ms — a
                    // stalled write is a stalled peer); 0 → no deadline.
                    if (self.deadline_ns == no_deadline and self.read_timeout_ms != 0) {
                        self.deadline_ns = monotonicNow() +
                            @as(i96, self.read_timeout_ms) * 1_000_000;
                    }
                    switch (self.pumpWrite(t)) {
                        .want_write => return .want_write,
                        .closed => {
                            self.state = .closing;
                            return .done_close;
                        },
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
                    }
                },

                .keep_alive_idle => {
                    // Waiting for the next pipelined/keep-alive request.
                    // Clear idle deadline and set read deadline for the new request.
                    self.deadline_ns = no_deadline;
                    self.state = .reading_head;
                    // Loop: fillAndParse will call t.read; on would_block it
                    // returns .need_more → want_read. On data it proceeds.
                },

                .dispatching => {
                    // Not used in step(); dispatch is inline in .reading_head handling.
                    self.state = .closing;
                    return .done_close;
                },

                .closing => return .done_close,
            }
        }
    }

    /// Called by the worker's timer wheel when `deadline_ns` has expired.
    ///
    /// - `reading_head` / `reading_body`: serialize a 408 Request Timeout into
    ///   `write_buf` best-effort and return `.want_write` so the worker can drain
    ///   it before closing. The caller must close after the write completes
    ///   (`close_after_write` is set to `true`).
    /// - `writing`: the peer has stalled mid-write (zero/tiny receive window,
    ///   not reading); we cannot send a 408 (the peer isn't reading), so silent
    ///   close — returns `.done_close`.
    /// - `keep_alive_idle`: silent close — no bytes, returns `.done_close`.
    /// - Any other state: returns `.done_close` (shouldn't happen normally).
    pub fn onDeadline(self: *Conn) StepResult {
        self.deadline_ns = no_deadline;
        switch (self.state) {
            .reading_head, .reading_body => {
                var r408 = Response.fromStatus(.request_timeout);
                r408.keep_alive = false;
                self.close_after_write = true;
                _ = self.serializeResponse(r408) catch {};
                self.state = .writing;
                return .want_write;
            },
            .writing => {
                // Peer stalled mid-write: can't send 408 (they aren't reading).
                // Silently close the connection to free the fd+slot.
                self.state = .closing;
                return .done_close;
            },
            .keep_alive_idle => {
                self.state = .closing;
                return .done_close;
            },
            else => {
                self.state = .closing;
                return .done_close;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const FakeTransport = transport_mod.FakeTransport;

test "conn: parses a request arriving in two reads" {
    var ft = FakeTransport.init(
        testing.allocator,
        &.{ "GET /users/42 HTTP", "/1.1\r\nHost: x\r\n\r\n" },
    );
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    // First chunk: head incomplete → need_more.
    try testing.expect(c.fillAndParse(t) == .need_more);

    // Second chunk: head complete → parsed.
    const out = c.fillAndParse(t);
    try testing.expect(out == .parsed);
    try testing.expectEqualStrings("/users/42", out.parsed.request.path);
    try testing.expectEqual(request.Method.GET, out.parsed.request.method);
}

test "conn: reads a POST body by content-length" {
    const body = "{\"msg\":\"hi\"}";
    const head = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n";
    var ft = FakeTransport.init(
        testing.allocator,
        &.{ head, body },
    );
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    // Both chunks arrive; may take one or two calls.
    var out: ParseOutcome = .need_more;
    for (0..10) |_| {
        out = c.fillAndParse(t);
        if (out != .need_more) break;
    }
    try testing.expect(out == .parsed);
    try testing.expectEqualStrings(body, out.parsed.request.body);
    try testing.expectEqual(request.Method.POST, out.parsed.request.method);
    try testing.expectEqualStrings("/echo", out.parsed.request.path);
}

test "conn: rejects chunked transfer-encoding" {
    const raw = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    const out = c.fillAndParse(t);
    try testing.expect(out == .failed);
    try testing.expectEqual(error.ChunkedNotSupported, out.failed);
}

test "conn: body over max_body_size returns BodyTooLarge" {
    const body = "hello world!"; // 12 bytes
    const head = "POST /data HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{ head, body });
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.max_body_size = 8; // cap smaller than body
    const t = ft.transport();

    var out: ParseOutcome = .need_more;
    for (0..10) |_| {
        out = c.fillAndParse(t);
        if (out != .need_more) break;
    }
    try testing.expect(out == .failed);
    try testing.expectEqual(error.BodyTooLarge, out.failed);
}

test "conn: returns closed when transport closes" {
    // Transport with no data at all — immediate close.
    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    try testing.expect(c.fillAndParse(t) == .closed);
}

test "conn: state is reading_body when body read blocks mid-way" {
    const body = "{\"msg\":\"hi\"}"; // 12 bytes
    const head = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n";
    var ft = FakeTransport.init(
        testing.allocator,
        &.{ head, body },
    );
    defer ft.deinit();
    ft.block_after = 1; // deliver head, then block on body read
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    // First call: head arrives, body read blocks → need_more.
    const out1 = c.fillAndParse(t);
    try testing.expect(out1 == .need_more);
    try testing.expectEqual(State.reading_body, c.state);

    // Second call: body arrives → parsed.
    const out2 = c.fillAndParse(t);
    try testing.expect(out2 == .parsed);
    try testing.expectEqualStrings(body, out2.parsed.request.body);
}

test "conn: returns need_more on would_block before any data" {
    var ft = FakeTransport.init(
        testing.allocator,
        &.{"GET / HTTP/1.1\r\nHost: x\r\n\r\n"},
    );
    defer ft.deinit();
    ft.block_after = 0; // block before the very first chunk
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    // First call → would_block → need_more.
    try testing.expect(c.fillAndParse(t) == .need_more);

    // Second call → data arrives → parsed.
    const out = c.fillAndParse(t);
    try testing.expect(out == .parsed);
    try testing.expectEqualStrings("/", out.parsed.request.path);
}

// ---------------------------------------------------------------------------
// Task 3 tests — serializeResponse + pumpWrite
// ---------------------------------------------------------------------------

test "conn: serializes a text Response into write_buf" {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);

    const resp = Response.text("hello");
    const len = try c.serializeResponse(resp);

    // Must have written something and positioned w_off at 0.
    try testing.expect(len > 0);
    try testing.expectEqual(@as(usize, 0), c.w_off);
    try testing.expectEqual(len, c.w_len);

    const out = wbuf[0..len];
    // Status line.
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200"));
    // Content-Length header.
    try testing.expect(std.mem.indexOf(u8, out, "content-length: 5") != null);
    // Body at the end.
    try testing.expect(std.mem.endsWith(u8, out, "hello"));
}

test "conn: pumpWrite completes in one shot when transport is free" {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);

    _ = try c.serializeResponse(Response.text("hello"));

    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    const t = ft.transport();

    const result = c.pumpWrite(t);
    try testing.expectEqual(.wrote_all, result);
    try testing.expectEqual(c.w_len, ft.written.items.len);
}

test "conn: pumpWrite resumes after would_block (backpressure)" {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);

    const resp = Response.text("hello");
    const total_len = try c.serializeResponse(resp);
    try testing.expect(total_len > 0);

    // Block after 0 bytes written: first write call immediately returns .would_block.
    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    ft.write_block_after_bytes = 0;
    const t = ft.transport();

    // First pump: transport blocks immediately — returns want_write, nothing written yet.
    const r1 = c.pumpWrite(t);
    try testing.expectEqual(.want_write, r1);
    try testing.expectEqual(@as(usize, 0), ft.written.items.len);
    try testing.expectEqual(@as(usize, 0), c.w_off);

    // Second pump: block is lifted — writes everything.
    const r2 = c.pumpWrite(t);
    try testing.expectEqual(.wrote_all, r2);
    try testing.expectEqual(total_len, ft.written.items.len);

    // Entire serialized response arrived in order.
    try testing.expectEqualStrings(wbuf[0..total_len], ft.written.items);
}

// ---------------------------------------------------------------------------
// Task 4 tests — step() + Dispatcher + keep-alive + pipelining
// ---------------------------------------------------------------------------

/// Minimal fake dispatcher: echoes the request path as the response body.
fn echoPathDispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
    _ = ctx;
    _ = arena;
    return Response.text(req.path);
}

fn makeEchoDispatcher() Dispatcher {
    return .{
        .ctx = undefined, // not used
        .dispatchFn = echoPathDispatch,
    };
}

test "conn: step — one request → 200 → done_close (keep_alive off)" {
    const raw = "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false; // force close after first response

    const t = ft.transport();
    const d = makeEchoDispatcher();

    // step drives: reading_head → (parsed) → writing → wrote_all → done_close.
    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    // ft.written must contain a valid 200 with "/hello" as body.
    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, written, "/hello") != null);
    try testing.expectEqual(@as(usize, 1), c.served);
}

test "conn: step — two pipelined keep-alive requests → two responses in order" {
    // Two full HTTP/1.1 requests delivered in a single read chunk.
    const req1 = "GET /first HTTP/1.1\r\nHost: x\r\n\r\n";
    const req2 = "GET /second HTTP/1.1\r\nHost: x\r\n\r\n";
    const both = req1 ++ req2;

    var ft = FakeTransport.init(testing.allocator, &.{both});
    defer ft.deinit();

    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true;
    c.max_keep_alive_requests = 10;

    const t = ft.transport();
    const d = makeEchoDispatcher();

    // First step: reads both requests from one chunk, handles req1,
    // then sees req2 buffered → handles req2, then hits want_read (no more data).
    const r1 = c.step(t, d);
    // After both requests are processed we hit keep_alive_idle → want_read.
    try testing.expectEqual(StepResult.want_read, r1);
    try testing.expectEqual(@as(usize, 2), c.served);

    const written = ft.written.items;
    // Both responses must appear in order.
    const pos1 = std.mem.indexOf(u8, written, "/first") orelse return error.TestUnexpectedResult;
    const pos2 = std.mem.indexOf(u8, written, "/second") orelse return error.TestUnexpectedResult;
    try testing.expect(pos1 < pos2);
    // Both are 200s.
    try testing.expect(std.mem.count(u8, written, "HTTP/1.1 200 ") == 2);
}

test "conn: step — keep-alive idle then second request on later read" {
    const raw1 = "GET /one HTTP/1.1\r\nHost: x\r\n\r\n";
    const raw2 = "GET /two HTTP/1.1\r\nHost: x\r\n\r\n";

    // Deliver requests in two separate chunks (simulates two separate read events).
    var ft = FakeTransport.init(testing.allocator, &.{ raw1, raw2 });
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true;
    c.max_keep_alive_requests = 10;

    const t = ft.transport();
    const d = makeEchoDispatcher();

    // First call: handles /one, then no more data → keep_alive_idle → want_read.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_read, r1);
    try testing.expectEqual(@as(usize, 1), c.served);
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "/one") != null);

    // Second call (simulating the event loop re-arming read): handles /two,
    // then transport is exhausted (closed) so keep-alive loop ends.
    const r2 = c.step(t, d);
    // After /two is served, no more data → transport closes → done_close
    // OR want_read depending on whether transport signals closed.
    // With FakeTransport, after all chunks consumed the next read returns .closed.
    // The keep_alive_idle→reading_head→fillAndParse path hits .closed → done_close.
    try testing.expect(r2 == .done_close or r2 == .want_read);
    try testing.expect(c.served >= 2);
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "/two") != null);
}

test "conn: step — oversize response → 500 + done_close" {
    // A tiny write buffer forces overflow detection.
    const raw = "GET /path HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    // Write buf deliberately tiny so the echo response overflows.
    var wbuf: [32]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;

    const t = ft.transport();
    const d = makeEchoDispatcher();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    // The written bytes should contain a 500 (not a 200), since the response overflowed.
    // The 500 itself may also be truncated to fit in 32 bytes, but it should start with
    // HTTP/1.1 5 at minimum.
    const written = ft.written.items;
    try testing.expect(written.len > 0);
    // Check that a 500 status appears (overflow path emits 500).
    try testing.expect(std.mem.indexOf(u8, written, "500") != null or
        std.mem.indexOf(u8, written, "HTTP/1.1 5") != null);
}

// ---------------------------------------------------------------------------
// Task 5 tests — error→status mapping, deadlines, truncation signal
// ---------------------------------------------------------------------------

test "conn: step — malformed head → 400 bad_request" {
    const raw = "GARBAGE /path BADPROTO\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();
    const d = makeEchoDispatcher();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 400"));
}

test "conn: step — chunked transfer-encoding → 411 length_required" {
    const raw = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();
    const d = makeEchoDispatcher();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 411"));
}

test "conn: step — body over max_body_size → 413 payload_too_large" {
    const body = "hello world!"; // 12 bytes
    const head = "POST /data HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{ head, body });
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.max_body_size = 8; // smaller than 12-byte body
    const t = ft.transport();
    const d = makeEchoDispatcher();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 413"));
}

test "conn: onDeadline while reading_head → 408 + want_write + close flag" {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.state = .reading_head;

    // Fire the deadline.
    const result = c.onDeadline();
    try testing.expectEqual(StepResult.want_write, result);
    try testing.expect(c.close_after_write);
    try testing.expectEqual(State.writing, c.state);

    // write_buf should start with "HTTP/1.1 408".
    const serialized = wbuf[0..c.w_len];
    try testing.expect(std.mem.startsWith(u8, serialized, "HTTP/1.1 408"));

    // Drain the write through a fake transport to confirm bytes flow.
    var ft = FakeTransport.init(testing.allocator, &.{});
    defer ft.deinit();
    const tw = ft.transport();
    const pump = c.pumpWrite(tw);
    try testing.expectEqual(.wrote_all, pump);
    try testing.expect(std.mem.startsWith(u8, ft.written.items, "HTTP/1.1 408"));
}

test "conn: onDeadline while keep_alive_idle → done_close, zero bytes written" {
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.state = .keep_alive_idle;
    c.w_len = 0; // nothing in write buf

    const result = c.onDeadline();
    try testing.expectEqual(StepResult.done_close, result);
    try testing.expectEqual(State.closing, c.state);
    // No bytes serialized.
    try testing.expectEqual(@as(usize, 0), c.w_len);
}

test "conn: serializeResponse signals ResponseTooLarge on overflow" {
    var rbuf: [4096]u8 = undefined;
    // Tiny write buf — a real HTTP response won't fit.
    var wbuf: [16]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    const result = c.serializeResponse(Response.text("hello"));
    try testing.expectError(error.ResponseTooLarge, result);
}

test "conn: step — truncated response → 500 via real overflow signal" {
    // Same as the overflow test above but now verifies the real signal path.
    const raw = "GET /longpath HTTP/1.1\r\nHost: example.com\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [32]u8 = undefined; // tiny — will overflow
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;

    const t = ft.transport();
    const d = makeEchoDispatcher();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, result);

    // Even if 500 itself is truncated to 32 bytes, the start of what we wrote
    // must begin with "HTTP/1.1 5" (5xx = server error range).
    const written = ft.written.items;
    try testing.expect(written.len > 0);
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 5"));
}
