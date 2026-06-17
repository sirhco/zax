//! Non-blocking per-connection state machine — read & parse phase (Task 2).
//!
//! `Conn` wraps two caller-owned buffers (read + write) and drives HTTP/1.1
//! request ingestion without blocking the calling thread. All IO is mediated
//! through the `Transport` vtable so the logic is fully unit-testable on any
//! platform via `FakeTransport`.
//!
//! Task 2 scope: `fillAndParse` — fill the read buffer from the transport,
//! parse the request head, validate no chunked encoding, read the body by
//! Content-Length, and return a `ParseOutcome`.  Response serialisation,
//! dispatch, keep-alive, and the `step` driver are added in Tasks 3–5.

const std = @import("std");
const parser = @import("../http/parser.zig");
const request = @import("../http/request.zig");
const response_mod = @import("../http/response.zig");
const transport_mod = @import("transport.zig");

const Response = response_mod.Response;

const Transport = transport_mod.Transport;
const Header = request.Header;

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
    /// Returns the serialized length.
    /// Caller must ensure `write_buf` is large enough for the response; if the
    /// response overflows the buffer the serialization is truncated (the fixed
    /// writer returns error.WriteFailed which we treat as a short write — Task 5
    /// will emit a 500 + close in that case; for now we just take what fit).
    pub fn serializeResponse(self: *Conn, resp: Response) usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        resp.write(&w) catch {};
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
    const len = c.serializeResponse(resp);

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

    _ = c.serializeResponse(Response.text("hello"));

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
    const total_len = c.serializeResponse(resp);
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
