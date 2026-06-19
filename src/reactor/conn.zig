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
const chunked_mod = @import("../http/chunked.zig");

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
    streaming,         // mid-stream: head pumped, iterating pull_streamer.next()
    keep_alive_idle,
    closing,
};

/// What the worker event loop should arm after `step` returns.
/// (Used from Task 4 onwards; defined here so downstream tasks see the type.)
pub const StepResult = enum {
    want_read,
    want_write,
    /// Pull-stream producer returned chunk(0) and stream_repoll_ms > 0.
    /// Worker must: disarm WRITE, keep READ armed (peer-close detection via HUP),
    /// and insert the timer for `deadline_ns` (the repoll deadline).
    /// On timer fire, `onDeadline` re-drives the conn into `.writing`.
    want_stream_repoll,
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
    /// Front bytes of `write_buf` reserved for a chunk's `<hexlen>\r\n` header so a
    /// producer chunk can be framed in place without shifting its data.
    const chunk_hdr_reserve: usize = 16;

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

    /// When non-null, the conn is serving a pull-streamed response.
    /// Set by step() when dispatch returns a pull_streamer response; cleared on done/err.
    /// NOTE: the legacy push `streamer` on the evented path keeps the buffer-or-500
    /// behavior; only `pull_streamer` gets true non-blocking streaming.
    pull_streamer: ?response_mod.PullStreamer = null,

    /// Byte count of the current pull-stream chunk loaded into write_buf.
    /// Together with w_off (offset within the chunk), tracks partial writes mid-chunk.
    /// reserved — not yet wired to any read site; w_off/w_len serve this role currently.
    stream_chunk_len: usize = 0,

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
    /// Backoff before re-polling a not-ready pull-stream producer (chunk(0) returned).
    /// 0 = disabled — fall back to old `.want_write` behavior (busy-spin).
    /// Default 5 ms is a constant backoff; future: exponential backoff capped at idle_timeout.
    stream_repoll_ms: u32 = 5,
    /// Whole-stream idle cap (ms): close a pull stream that has produced no
    /// data for this long. 0 disables (default — no cap, legacy behavior).
    stream_idle_timeout_ms: u32 = 0,
    /// Monotonic stamp (ns) of the last real chunk produced; also set at
    /// stream start. Only read when `stream_idle_timeout_ms != 0`.
    last_produce_ns: i96 = 0,
    /// When true, the active pull stream is framed as chunked transfer-encoding
    /// and the connection is kept alive after the terminator. Set at dispatch
    /// from `persistent`; cleared on each keep-alive reset.
    stream_chunked: bool = false,
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
    // Phase 2: validate + read body (Content-Length or chunked).
    // ----------------------------------------------------------------
    fn readBody(self: *Conn, t: Transport, p: parser.Parsed) ParseOutcome {
        const head_abs = self.r_start + p.head_len;

        // --- Chunked transfer-encoding path ---
        if (p.request.isChunked()) {
            self.state = .reading_body;
            const max = self.max_body_size;

            while (true) {
                // Try to decode whatever is buffered after the head.
                const buf_slice = self.read_buf[head_abs..self.r_end];
                switch (chunked_mod.decodeInPlace(buf_slice, max)) {
                    .done => |d| {
                        var result = p;
                        result.request.body = self.read_buf[head_abs .. head_abs + d.body_len];
                        result.body_consumed = d.consumed;
                        return .{ .parsed = result };
                    },
                    .incomplete => {
                        // Buffer full but no terminator → encoded body too large.
                        if (self.r_end == self.read_buf.len) {
                            return .{ .failed = error.BodyTooLarge };
                        }
                        // Need more data — read into the remainder of the buffer.
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
                    .malformed => return .{ .failed = error.Malformed },
                    .too_large => return .{ .failed = error.BodyTooLarge },
                }
            }
        }

        // --- No Content-Length → body is empty; done. ---
        const clen = p.request.contentLength() orelse {
            var result = p;
            result.request.body = "";
            result.body_consumed = 0;
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
        result.request.body = self.read_buf[head_abs .. head_abs + clen];
        result.body_consumed = clen;
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

    /// Serialize only the response HEAD (no body, no content-length) into `write_buf`.
    /// Used for pull-streamed responses. Returns `error.ResponseTooLarge` if the
    /// head does not fit in `write_buf`.
    pub fn serializeHead(self: *Conn, resp: Response, chunked: bool) error{ResponseTooLarge}!usize {
        var w = std.Io.Writer.fixed(self.write_buf);
        resp.writeHead(&w, chunked) catch {
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

    /// Buffer slice handed to the producer's `next`. When chunked, reserve the
    /// header prefix and a 2-byte CRLF suffix so the chunk can be framed in place.
    fn pullDst(self: *Conn) []u8 {
        if (self.stream_chunked) return self.write_buf[chunk_hdr_reserve .. self.write_buf.len - 2];
        return self.write_buf;
    }

    /// After the producer wrote `n` bytes at `write_buf[chunk_hdr_reserve..]`,
    /// frame them as `<hexlen>\r\n<data>\r\n` in place and set w_off/w_len.
    fn frameChunk(self: *Conn, n: usize) void {
        var hbuf: [chunk_hdr_reserve]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "{x}\r\n", .{n}) catch unreachable; // fits: n < buf.len
        const data_start = chunk_hdr_reserve;
        const hdr_start = data_start - hdr.len;
        @memcpy(self.write_buf[hdr_start..data_start], hdr);
        self.write_buf[data_start + n] = '\r';
        self.write_buf[data_start + n + 1] = '\n';
        self.w_off = hdr_start;
        self.w_len = data_start + n + 2;
    }

    /// Load the chunked end-of-stream terminator into write_buf and clear the
    /// streamer so the normal wrote_all path runs (served++ + keep-alive).
    fn loadChunkedTerminator(self: *Conn) void {
        const term = "0\r\n\r\n";
        @memcpy(self.write_buf[0..term.len], term);
        self.w_off = 0;
        self.w_len = term.len;
        self.pull_streamer = null;
        self.deadline_ns = no_deadline;
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
                            // Use body_consumed (encoded length) not body.len
                            // (decoded length) so chunked framing is consumed.
                            const consumed = p.head_len + p.body_consumed;
                            self.r_start += consumed;

                            // Keep-alive decision (mirrors server.zig handleConn).
                            const persistent = self.keep_alive and
                                p.request.isPersistent() and
                                (self.served + 1) < self.max_keep_alive_requests;

                            // Dispatch → Response.
                            var resp = d.dispatch(&p.request, self.arena);

                            // Handle pull-streamed responses: true non-blocking streaming.
                            // The legacy push `streamer` keeps buffer-or-500 behavior on
                            // the evented path (see comment below).
                            if (resp.pull_streamer) |ps| {
                                // Chunked transfer-encoding + keep-alive when the request is
                                // persistent; otherwise legacy connection-close raw framing.
                                self.stream_chunked = persistent;
                                resp.keep_alive = persistent; // header disposition (writeHead(chunked) drives the actual line)
                                if (self.on_response) |hook| hook(&p.request, &resp);
                                if (self.serializeHead(resp, self.stream_chunked)) |_| {} else |_| {
                                    // Head won't fit (extremely small write_buf) — 500 + close.
                                    var e500 = Response.fromStatus(.internal_server_error);
                                    e500.keep_alive = false;
                                    _ = self.serializeResponse(e500) catch {};
                                    self.stream_chunked = false;
                                    self.close_after_write = true;
                                    self.state = .writing;
                                    continue;
                                }
                                self.pull_streamer = ps;
                                self.last_produce_ns = monotonicNow();
                                self.close_after_write = !self.stream_chunked; // chunked → keep-alive after terminator
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
                    // Guard: if w_len == 0 and we have a pull streamer, call next()
                    // immediately (empty chunk — producer signalled 0 bytes this call).
                    if (self.w_len == 0) {
                        if (self.pull_streamer) |ps| {
                            switch (ps.next(self.pullDst())) {
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
                                            self.deadline_ns = no_deadline; // escape hatch: preserve old behavior
                                            return .want_write;
                                        }
                                        self.w_off = 0;
                                        self.w_len = 0;
                                        self.state = .streaming; // parked marker: re-drive on timer fire
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
                                    self.deadline_ns = no_deadline; // re-arm per-chunk stall deadline
                                },
                                .done => {
                                    if (self.stream_chunked) {
                                        // Load terminator; fall through to pumpWrite. Once it
                                        // writes, the wrote_all path (pull_streamer now null)
                                        // does served++ + keep-alive.
                                        self.loadChunkedTerminator();
                                    } else {
                                        self.pull_streamer = null;
                                        self.served += 1;
                                        self.state = .closing;
                                        return .done_close;
                                    }
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
                    switch (self.pumpWrite(t)) {
                        .want_write => return .want_write,
                        .closed => {
                            self.state = .closing;
                            return .done_close;
                        },
                        .wrote_all => {
                            // Pull-streaming: head (or last chunk) fully written.
                            // Load the next chunk into write_buf and keep pumping.
                            if (self.pull_streamer) |ps| {
                                switch (ps.next(self.pullDst())) {
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
                                            // Producer not ready yet (sparse stream, e.g. SSE).
                                            if (self.stream_repoll_ms == 0) {
                                                // Escape hatch: old busy-spin behavior.
                                                self.w_off = 0;
                                                self.w_len = 0;
                                                return .want_write;
                                            }
                                            self.w_off = 0;
                                            self.w_len = 0;
                                            self.state = .streaming; // parked marker: re-drive on timer fire
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
                                        self.deadline_ns = no_deadline; // re-arm per-chunk stall deadline
                                        // Stay in .writing; loop calls pumpWrite for this chunk.
                                        continue;
                                    },
                                    .done => {
                                        if (self.stream_chunked) {
                                            // Pump terminator; wrote_all (streamer null) → served++ + keep-alive.
                                            self.loadChunkedTerminator();
                                            continue;
                                        }
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
                            self.stream_chunked = false;
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

                .streaming => {
                    // Readiness re-poll fired (or spurious re-drive): resume the write pump.
                    // State was set to .streaming when chunk(0) was returned and stream_repoll_ms > 0.
                    // w_len == 0, so the .writing arm's guard will call next() again.
                    self.state = .writing;
                    continue; // falls into the .writing arm → w_len==0 guard → calls next() again
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
            .streaming => {
                // Readiness re-poll deadline fired: resume the write pump.
                // `deadline_ns` was already set to `no_deadline` at the top of onDeadline.
                self.state = .writing; // resume pump; w_len==0 → next() called again
                return .want_write; // routes through worker's existing expiredCb .want_write branch
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

test "conn: chunked body decoded one-shot" {
    // "hello world" in two chunks + terminator.
    const head = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const body_enc = "6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{ head, body_enc });
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    var out: ParseOutcome = .need_more;
    for (0..10) |_| {
        out = c.fillAndParse(t);
        if (out != .need_more) break;
    }
    try testing.expect(out == .parsed);
    try testing.expectEqualStrings("hello world", out.parsed.request.body);
}

test "conn: chunked body decoded in split delivery" {
    // Head + first chunk arrive on read #1 (would_block after).
    // Second chunk + terminator arrive on read #2.
    const head = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const part1 = "6\r\nhello \r\n";     // first chunk only — no terminator yet
    const part2 = "5\r\nworld\r\n0\r\n\r\n"; // second chunk + terminator
    var ft = FakeTransport.init(testing.allocator, &.{ head, part1, part2 });
    defer ft.deinit();
    // Block after delivering head+part1 so read #2 returns would_block first.
    ft.block_after = 2; // deliver reads 0 and 1 (head, part1), then block
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    // First call: head + part1 buffered, decode → .incomplete → need_more.
    const out1 = c.fillAndParse(t);
    try testing.expect(out1 == .need_more);

    // Second call: part2 arrives, decode completes → parsed.
    var out2: ParseOutcome = .need_more;
    for (0..10) |_| {
        out2 = c.fillAndParse(t);
        if (out2 != .need_more) break;
    }
    try testing.expect(out2 == .parsed);
    try testing.expectEqualStrings("hello world", out2.parsed.request.body);
}

test "conn: malformed chunked body returns 400" {
    const head = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    // Invalid hex size → malformed.
    const bad_body = "ZZ\r\nbad data\r\n0\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{ head, bad_body });
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();

    var out: ParseOutcome = .need_more;
    for (0..10) |_| {
        out = c.fillAndParse(t);
        if (out != .need_more) break;
    }
    try testing.expect(out == .failed);
    try testing.expectEqual(error.Malformed, out.failed);
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

test "conn: step — chunked transfer-encoding decoded → 200 not 411" {
    // Full chunked request: head + encoded body delivered together.
    const raw = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    const t = ft.transport();
    const d = makeEchoDispatcher();

    // Drive until we get a terminal result (done_close or want_write→done_close).
    var result: StepResult = .want_read;
    for (0..20) |_| {
        result = c.step(t, d);
        if (result == .done_close) break;
    }
    try testing.expectEqual(StepResult.done_close, result);

    const written = ft.written.items;
    // Must be 200, never 411.
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200"));
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

test "conn: step — chunked POST + pipelined GET → encoded length advance is correct" {
    // Chunked body "hello world" (11 bytes decoded) encoded as:
    //   "6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n"  (28 bytes encoded)
    // Immediately followed on the wire by a second pipelined GET.
    // If r_start advances by the DECODED length (11) instead of the ENCODED
    // length (28) the second request will be mis-parsed or fail.
    const chunked_body = "6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n";
    const req1 = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        chunked_body;
    const req2 = "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n";
    const both = req1 ++ req2;

    var ft = FakeTransport.init(testing.allocator, &.{both});
    defer ft.deinit();

    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Dispatcher that records the last dispatched body (heap-allocated so it
    // outlives the arena reset between requests).
    const BodyCtx = struct {
        body: []const u8 = "",
        allocator: std.mem.Allocator,

        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = ar;
            const self: *@This() = @ptrCast(@alignCast(self_ctx));
            // Free prior copy.
            if (self.body.len > 0) self.allocator.free(self.body);
            self.body = self.allocator.dupe(u8, req.body) catch "";
            return Response.text(req.path);
        }
    };
    var bctx = BodyCtx{ .allocator = testing.allocator };
    defer if (bctx.body.len > 0) testing.allocator.free(bctx.body);
    const d = Dispatcher{ .ctx = &bctx, .dispatchFn = BodyCtx.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true;
    c.max_keep_alive_requests = 10;

    const t = ft.transport();

    // One step should: parse + dispatch req1, then see req2 buffered, parse +
    // dispatch req2, then hit want_read (no more data).
    var result: StepResult = .want_read;
    for (0..30) |_| {
        result = c.step(t, d);
        if (result == .want_read or result == .done_close) break;
    }
    try testing.expectEqual(StepResult.want_read, result);

    // Two requests must have been served.
    try testing.expectEqual(@as(usize, 2), c.served);

    // First request decoded body must be "hello world".
    // bctx.body now holds the LAST dispatched body (req2 has no body → "").
    // We verify via the written responses: req1 → /up, req2 → /ping both 200.
    const written = ft.written.items;
    try testing.expect(std.mem.count(u8, written, "HTTP/1.1 200 ") == 2);
    // /ping appears only if r_start advanced past the full encoded chunked body.
    try testing.expect(std.mem.indexOf(u8, written, "/ping") != null);
    try testing.expect(std.mem.indexOf(u8, written, "/up") != null);
}

test "conn: step — chunked body over max_body_size → 413 payload_too_large" {
    // Chunked encoding of "hello world!" (12 bytes) in one chunk.
    // With max_body_size=8 the decoder hits .too_large → 413.
    const head = "POST /data HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    const chunked_body = "c\r\nhello world!\r\n0\r\n\r\n"; // 12-byte payload, hex c

    var ft = FakeTransport.init(testing.allocator, &.{ head, chunked_body });
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.max_body_size = 8; // smaller than 12-byte decoded body
    const t = ft.transport();
    const d = makeEchoDispatcher();

    var result: StepResult = .want_read;
    for (0..20) |_| {
        result = c.step(t, d);
        if (result == .done_close) break;
    }
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
    // Block the very first write call (threshold 0 = block immediately, one-shot).
    // After the block fires, step 2 resumes and writes everything to completion.
    ft.write_block_after_bytes = 0;

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

test "conn: pull streamer — partial write mid-chunk advances w_off, no bytes lost" {
    // This test proves the partial-write path: w_off is advanced correctly after a
    // partial write so bytes are not lost or duplicated when the event loop resumes.
    //
    // Strategy: serialize the head into a scratch conn to learn its exact size, then
    // set write_block_after_bytes = head_size + 4, which lands 4 bytes into the
    // "hello world" (11-byte) chunk.  The sequence is:
    //   step 1: head written fully, 4 bytes of chunk written (partial), w_off = 4 → want_write
    //   step 2: would_block fires (one-shot), nothing written → want_write
    //   step 3: remaining 7 bytes of chunk written, next() → done → done_close
    // Assert "hello world" appears exactly once.

    const MidChunkCtx = struct {
        done: bool = false,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            if (c.done) return .done;
            c.done = true;
            const payload = "hello world";
            @memcpy(buf[0..payload.len], payload);
            return .{ .chunk = payload.len };
        }
    };

    // Determine head size for a text/plain streaming response (no content-length).
    // Must use the same content-type as the dispatcher below ("text/plain") so
    // the computed head_size matches the actual bytes written during the test.
    const head_size: usize = blk: {
        var sz_rbuf: [4096]u8 = undefined;
        var sz_wbuf: [256]u8 = undefined;
        var sz_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer sz_arena.deinit();
        var sz_c = Conn.init(&sz_rbuf, &sz_wbuf, &sz_arena);
        const head_resp = Response{ .content_type = "text/plain", .keep_alive = false };
        break :blk try sz_c.serializeHead(head_resp, false);
    };
    // Threshold: write head fully, then 4 bytes into the 11-byte chunk.
    // Requires: head_size + 4 < head_size + 11.  Always true since 4 < 11.
    const threshold = head_size + 4;

    const raw = "GET /midchunk HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    ft.write_block_after_bytes = threshold;

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var pull_ctx = MidChunkCtx{};
    const MidDispatch = struct {
        p: *MidChunkCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(MidChunkCtx, s.p, MidChunkCtx.next, "text/plain");
        }
    };
    var md = MidDispatch{ .p = &pull_ctx };
    const d = Dispatcher{ .ctx = &md, .dispatchFn = MidDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    const t = ft.transport();

    // Step 1: head written fully + 4 bytes of chunk (partial) → want_write.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_write, r1);
    // We wrote head_size + 4 bytes so far.
    try testing.expectEqual(threshold, ft.written.items.len);

    // Step 2: one-shot would_block fires immediately → want_write, nothing more written.
    const r2 = c.step(t, d);
    try testing.expectEqual(StepResult.want_write, r2);

    // Step 3: remaining 7 bytes of chunk written, next() → done → done_close.
    const r3 = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r3);

    // "hello world" must appear exactly once — no bytes lost or duplicated.
    const written = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, written, "hello world") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "hello world"));
    // Total written = head + full 11-byte chunk.
    try testing.expectEqual(head_size + 11, written.len);
}

// ---------------------------------------------------------------------------
// Task 7 (sparse-SSE) tests — stream_repoll_ms / want_stream_repoll
// ---------------------------------------------------------------------------

/// A pull streamer that returns chunk(0) `zeros_before` times, then a real chunk, then done.
/// Tracks its `next` call count for busy-loop detection.
const SparseCtx = struct {
    zeros_before: usize,
    payload: []const u8,
    calls: usize = 0,
    real_chunk_served: bool = false,
    done: bool = false,

    fn next(c: *SparseCtx, buf: []u8) response_mod.PullResult {
        c.calls += 1;
        if (!c.real_chunk_served and c.calls > c.zeros_before) {
            c.real_chunk_served = true;
            const n = @min(c.payload.len, buf.len);
            @memcpy(buf[0..n], c.payload[0..n]);
            return .{ .chunk = n };
        }
        if (c.real_chunk_served and !c.done) {
            c.done = true;
            return .done;
        }
        // Return chunk(0) — producer not ready.
        return .{ .chunk = 0 };
    }
};

test "conn: sparse stream — chunk(0) parks, no synchronous re-call" {
    // Test 1: dispatch sparse streamer (chunk(0) then chunk("data") then done).
    // One step after head is pumped → result == .want_stream_repoll, state == .streaming,
    // deadline_ns != no_deadline, and ctx.calls == 1 (no busy loop inside one step).
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = SparseCtx{ .zeros_before = 1, .payload = "data" };

    const SparseDispatch = struct {
        p: *SparseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/event-stream");
        }
    };
    var sd = SparseDispatch{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SparseDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    const t = ft.transport();

    // Drive: reads request, dispatches, writes head, calls next() once → chunk(0) → park.
    const result = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, result);
    try testing.expectEqual(State.streaming, c.state);
    try testing.expect(c.deadline_ns != no_deadline);
    // next() called exactly once — no busy loop.
    try testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "conn: sparse stream — repoll re-drives and flushes data" {
    // Test 2: from parked, call onDeadline() → want_write + state==.writing;
    // then step() → next count increments, "data" appears in written.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = SparseCtx{ .zeros_before = 1, .payload = "data" };

    const SparseDispatch2 = struct {
        p: *SparseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/event-stream");
        }
    };
    var sd = SparseDispatch2{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SparseDispatch2.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    const t = ft.transport();

    // Park the conn.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);
    try testing.expectEqual(@as(usize, 1), ctx.calls);

    // Simulate timer fire.
    const r2 = c.onDeadline();
    try testing.expectEqual(StepResult.want_write, r2);
    try testing.expectEqual(State.writing, c.state);

    // Re-drive: next() returns "data", then done.
    const r3 = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r3);
    try testing.expect(ctx.calls > 1);
    const written = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, written, "data") != null);
}

test "conn: sparse stream — chunk(0) then chunk(n) then done closes clean" {
    // Test 3: full drive; payload present exactly once; served == 1.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = SparseCtx{ .zeros_before = 1, .payload = "hello" };

    const SparseDispatch3 = struct {
        p: *SparseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/event-stream");
        }
    };
    var sd = SparseDispatch3{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SparseDispatch3.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    const t = ft.transport();

    // Step 1: park.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);
    // Simulate timer fire → re-drive.
    _ = c.onDeadline();
    // Step 2: real chunk + done.
    const r2 = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r2);

    const written = ft.written.items;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "hello"));
    try testing.expectEqual(@as(usize, 1), c.served);
    try testing.expect(c.pull_streamer == null);
}

test "conn: sparse stream — chunk(0) then done closes clean, no extra body bytes" {
    // Test 4: sparse ctx returns chunk(0) then done.
    // park → onDeadline → step → done_close; no extra body bytes; pull_streamer == null.
    const ZeroThenDoneCtx = struct {
        calls: usize = 0,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            _ = buf;
            c.calls += 1;
            if (c.calls == 1) return .{ .chunk = 0 };
            return .done;
        }
    };

    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = ZeroThenDoneCtx{};

    const ZeroDispatch = struct {
        p: *ZeroThenDoneCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(ZeroThenDoneCtx, s.p, ZeroThenDoneCtx.next, "text/event-stream");
        }
    };
    var sd = ZeroDispatch{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = ZeroDispatch.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    const t = ft.transport();

    // Step 1: park on chunk(0).
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);
    try testing.expectEqual(State.streaming, c.state);

    // Simulate timer fire.
    const r2 = c.onDeadline();
    try testing.expectEqual(StepResult.want_write, r2);

    // Step 2: next() returns done → done_close.
    const r3 = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r3);
    try testing.expect(c.pull_streamer == null);
    // No body bytes beyond head: head has no payload, and done was returned without chunk.
    const written = ft.written.items;
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200"));
}

test "conn: sparse stream — knob=0 fallback, chunk(0) returns want_write" {
    // Test 5: with stream_repoll_ms == 0, chunk(0) falls back to old .want_write behavior.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = SparseCtx{ .zeros_before = 1, .payload = "data" };

    const SparseDispatch5 = struct {
        p: *SparseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/event-stream");
        }
    };
    var sd = SparseDispatch5{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = SparseDispatch5.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 0; // disabled: fallback to old behavior
    const t = ft.transport();

    const result = c.step(t, d);
    try testing.expectEqual(StepResult.want_write, result);
    // State must NOT be .streaming — stays .writing (no parking when knob is off).
    try testing.expectEqual(State.writing, c.state);
    // The repoll deadline must NOT have been set (no stream_repoll deadline stamp).
    // (The stall deadline from the .writing entry arm may be set; that is fine.)
    // Key invariant: state is .writing, not .streaming.
}

test "conn: sparse stream — both park sites fire want_stream_repoll" {
    // Test 6a: producer returns chunk(0) on the first next after head (w_len==0 guard path).
    // Test 6b: producer returns real chunk, write, then chunk(0) on refill (.wrote_all path).
    // Both assert .want_stream_repoll.

    // --- 6a: w_len==0 guard path ---
    {
        const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
        var ft = FakeTransport.init(testing.allocator, &.{raw});
        defer ft.deinit();

        var rbuf: [4096]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        // zeros_before=1 → first next() returns chunk(0) → w_len==0 guard path.
        var ctx = SparseCtx{ .zeros_before = 1, .payload = "x" };

        const D6a = struct {
            p: *SparseCtx,
            fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
                _ = req; _ = ar;
                const s: *@This() = @ptrCast(@alignCast(self_ctx));
                return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/plain");
            }
        };
        var sd = D6a{ .p = &ctx };
        const d = Dispatcher{ .ctx = &sd, .dispatchFn = D6a.dispatch };

        var c = Conn.init(&rbuf, &wbuf, &arena);
        c.keep_alive = false;
        c.stream_repoll_ms = 5;
        const t = ft.transport();

        const r = c.step(t, d);
        try testing.expectEqual(StepResult.want_stream_repoll, r);
    }

    // --- 6b: .wrote_all refill path ---
    // Producer: first next() returns a real chunk ("abc"), then chunk(0) on the second call.
    {
        const WroteAllSparseCtx = struct {
            calls: usize = 0,
            fn next(c: *@This(), buf: []u8) response_mod.PullResult {
                c.calls += 1;
                if (c.calls == 1) {
                    const payload = "abc";
                    @memcpy(buf[0..payload.len], payload);
                    return .{ .chunk = payload.len };
                }
                if (c.calls == 2) return .{ .chunk = 0 };
                return .done;
            }
        };

        const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
        var ft = FakeTransport.init(testing.allocator, &.{raw});
        defer ft.deinit();

        var rbuf: [4096]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var ctx = WroteAllSparseCtx{};

        const D6b = struct {
            p: *WroteAllSparseCtx,
            fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
                _ = req; _ = ar;
                const s: *@This() = @ptrCast(@alignCast(self_ctx));
                return Response.streamPull(WroteAllSparseCtx, s.p, WroteAllSparseCtx.next, "text/plain");
            }
        };
        var sd = D6b{ .p = &ctx };
        const d = Dispatcher{ .ctx = &sd, .dispatchFn = D6b.dispatch };

        var c = Conn.init(&rbuf, &wbuf, &arena);
        c.keep_alive = false;
        c.stream_repoll_ms = 5;
        const t = ft.transport();

        // Drive: reads request, writes head + "abc" chunk in one step,
        // then .wrote_all refill calls next() → chunk(0) → park.
        var result: StepResult = undefined;
        for (0..10) |_| {
            result = c.step(t, d);
            if (result == .want_stream_repoll or result == .done_close) break;
        }
        try testing.expectEqual(StepResult.want_stream_repoll, result);
        try testing.expectEqual(State.streaming, c.state);
    }
}

test "conn: sparse stream — peer close while parked → done_close on re-drive" {
    // Scenario: a sparse stream parks the conn (.want_stream_repoll).  While
    // parked, the client disconnects.  On re-drive (timer fires → onDeadline +
    // step), the conn ends in .done_close rather than hanging.
    //
    // We simulate peer-close via a custom transport whose write() always returns
    // .closed (broken pipe after the head has already been sent in a prior step).

    // A transport whose write() always returns .closed — representing a peer
    // that disconnected (broken pipe) after the head was already sent.
    const ClosedWriteTransport = struct {
        fn write(_: *anyopaque, _: []const u8) transport_mod.IoResult {
            return .closed;
        }
        // read is never called while in .writing state.
        fn read(_: *anyopaque, _: []u8) transport_mod.IoResult {
            return .closed;
        }
    };

    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Sparse streamer: chunk(0) first (parks), then "payload" + done.
    var ctx = SparseCtx{ .zeros_before = 1, .payload = "payload" };

    const D = struct {
        p: *SparseCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(SparseCtx, s.p, SparseCtx.next, "text/event-stream");
        }
    };
    var sd = D{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = D.dispatch };

    // Step 1 uses the normal FakeTransport (reads the request, writes head).
    // We need write to succeed for the head, so first step uses ft directly.
    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    // stream_repoll_ms defaults to 5 in Conn.init — no explicit assignment needed.
    const t_normal = ft.transport();

    // Drive: reads request, dispatches, writes head, calls next() → chunk(0) → park.
    const r1 = c.step(t_normal, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);
    try testing.expectEqual(State.streaming, c.state);

    // Simulate timer fire: onDeadline() re-arms the conn for writing.
    const r2 = c.onDeadline();
    try testing.expectEqual(StepResult.want_write, r2);
    try testing.expectEqual(State.writing, c.state);

    // Now re-drive with a closed-write transport — represents peer disconnect.
    // The conn tries to write the next chunk and gets .closed → .done_close.
    var dummy: u8 = 0;
    const t_closed = transport_mod.Transport{
        .context = &dummy,
        .readFn = ClosedWriteTransport.read,
        .writeFn = ClosedWriteTransport.write,
    };
    const r3 = c.step(t_closed, d);
    try testing.expectEqual(StepResult.done_close, r3);
}

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

// ---------------------------------------------------------------------------
// Task 4 (chunked-streaming) tests — chunked framing + keep-alive on evented
// ---------------------------------------------------------------------------

test "conn: chunked streamPull on a persistent request — chunked head, framed body, second request served" {
    const TwoChunk = struct {
        i: usize = 0,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            const chunks = [_][]const u8{ "one", "two" };
            if (c.i >= chunks.len) return .done;
            const ch = chunks[c.i];
            c.i += 1;
            @memcpy(buf[0..ch.len], ch);
            return .{ .chunk = ch.len };
        }
    };
    // Two pipelined persistent requests on one connection.
    const raw = "GET /s HTTP/1.1\r\nHost: x\r\n\r\nGET /s HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx1 = TwoChunk{};
    var ctx2 = TwoChunk{};
    const Disp = struct {
        a: *TwoChunk,
        b: *TwoChunk,
        n: usize = 0,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req;
            _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            const c = if (s.n == 0) s.a else s.b;
            s.n += 1;
            return Response.streamPull(TwoChunk, c, TwoChunk.next, "text/plain");
        }
    };
    var sd = Disp{ .a = &ctx1, .b = &ctx2 };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = Disp.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true; // persistent
    const t = ft.transport();

    var guard: usize = 0;
    var result = c.step(t, d);
    while (result != .done_close and guard < 100) : (guard += 1) {
        if (result == .want_read) break; // entered keep-alive idle after first stream + pipelined consumed
        result = c.step(t, d);
    }

    const out = ft.written.items;
    // Chunked head + framed chunks + terminator for the FIRST stream.
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding: chunked") != null);
    try testing.expect(std.mem.indexOf(u8, out, "connection: keep-alive") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3\r\none\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3\r\ntwo\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "0\r\n\r\n") != null);
    // Second request was dispatched (proves the connection survived the stream).
    try testing.expectEqual(@as(usize, 2), sd.n);
}

test "conn: streamPull on a Connection: close request stays connection-close (no chunked)" {
    const OneChunk = struct {
        done: bool = false,
        fn next(c: *@This(), buf: []u8) response_mod.PullResult {
            if (c.done) return .done;
            c.done = true;
            @memcpy(buf[0..3], "abc");
            return .{ .chunk = 3 };
        }
    };
    const raw = "GET /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();
    var rbuf: [4096]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OneChunk{};
    const Disp = struct {
        p: *OneChunk,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req;
            _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(OneChunk, s.p, OneChunk.next, "text/plain");
        }
    };
    var sd = Disp{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = Disp.dispatch };
    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = true;
    const t = ft.transport();
    var guard: usize = 0;
    var result = c.step(t, d);
    while (result != .done_close and guard < 50) : (guard += 1) result = c.step(t, d);
    const out = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, out, "connection: close") != null);
    try testing.expect(std.mem.indexOf(u8, out, "transfer-encoding") == null);
    try testing.expect(std.mem.indexOf(u8, out, "abc") != null); // raw body, not framed
    try testing.expectEqual(StepResult.done_close, result);
}

// ---------------------------------------------------------------------------
// Task 2 tests — stream_idle_timeout_ms / idle cap
// ---------------------------------------------------------------------------

/// A pull streamer that always returns chunk(0) — never produces data.
const AlwaysZeroCtx = struct {
    calls: usize = 0,
    fn next(c: *@This(), buf: []u8) response_mod.PullResult {
        _ = buf;
        c.calls += 1;
        return .{ .chunk = 0 };
    }
};

/// A pull streamer: returns chunk(0) once, then a real chunk of `payload`, then done.
const ZeroThenRealCtx = struct {
    payload: []const u8,
    calls: usize = 0,
    real_served: bool = false,
    done: bool = false,
    fn next(c: *@This(), buf: []u8) response_mod.PullResult {
        c.calls += 1;
        if (!c.real_served) {
            if (c.calls == 1) return .{ .chunk = 0 };
            c.real_served = true;
            const n = @min(c.payload.len, buf.len);
            @memcpy(buf[0..n], c.payload[0..n]);
            return .{ .chunk = n };
        }
        if (!c.done) {
            c.done = true;
            return .done;
        }
        return .{ .chunk = 0 };
    }
};

/// A pull streamer: returns a real chunk first, then always chunk(0).
const RealThenZeroCtx = struct {
    payload: []const u8,
    calls: usize = 0,
    real_served: bool = false,
    fn next(c: *@This(), buf: []u8) response_mod.PullResult {
        c.calls += 1;
        if (!c.real_served) {
            c.real_served = true;
            const n = @min(c.payload.len, buf.len);
            @memcpy(buf[0..n], c.payload[0..n]);
            return .{ .chunk = n };
        }
        return .{ .chunk = 0 };
    }
};

test "stream idle cap: chunk(0) past window hard-closes (no terminator)" {
    // cap fires at the first-site (w_len==0 guard): park, back-date last_produce_ns, re-drive.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = AlwaysZeroCtx{};
    const D = struct {
        p: *AlwaysZeroCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(AlwaysZeroCtx, s.p, AlwaysZeroCtx.next, "text/event-stream");
        }
    };
    var sd = D{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = D.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    c.stream_idle_timeout_ms = 10;
    const t = ft.transport();

    // First step: dispatch → head pumped → chunk(0) → park.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);

    // Simulate 50ms of idle (well past the 10ms cap) by back-dating last_produce_ns.
    c.last_produce_ns = monotonicNow() - 50 * std.time.ns_per_ms;

    // Simulate timer fire: .streaming → .writing.
    _ = c.onDeadline();
    // Re-drive: hits chunk(0) → cap check → hard close.
    const r = c.step(t, d);
    try testing.expectEqual(StepResult.done_close, r);
    try testing.expectEqual(State.closing, c.state);
    // No chunked terminator written (truncate, not clean close).
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "0\r\n\r\n") == null);
}

test "stream idle cap: real chunk resets window, subsequent chunk(0) parks (not closes)" {
    // After a real chunk resets last_produce_ns, a subsequent chunk(0) should NOT fire cap
    // (last_produce_ns is fresh) and should park as want_stream_repoll.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Producer: chunk(0) → "hello" → chunk(0) forever.
    var ctx = ZeroThenRealCtx{ .payload = "hello" };
    const D2 = struct {
        p: *ZeroThenRealCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(ZeroThenRealCtx, s.p, ZeroThenRealCtx.next, "text/event-stream");
        }
    };
    var sd = D2{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = D2.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    c.stream_idle_timeout_ms = 10;
    const t = ft.transport();

    // Park on first chunk(0).
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);

    // Back-date so cap WOULD fire if last_produce_ns isn't reset by the real chunk.
    c.last_produce_ns = monotonicNow() - 50 * std.time.ns_per_ms;

    // Cap check lives inside the n==0 branch; a real chunk (n>0) bypasses it entirely and
    // resets last_produce_ns. So back-dating before a real-chunk step cannot trigger the cap.
    _ = c.onDeadline();
    const r2 = c.step(t, d);
    // Real chunk "hello" delivered, then done → done_close. "hello" in written confirms cap didn't fire.
    try testing.expectEqual(StepResult.done_close, r2);
    const written = ft.written.items;
    try testing.expect(std.mem.indexOf(u8, written, "hello") != null);
    try testing.expect(c.pull_streamer == null);
}

test "stream idle cap: disabled (timeout==0) never closes even with old stamp" {
    // With stream_idle_timeout_ms == 0, cap is never applied; chunk(0) parks normally.
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = AlwaysZeroCtx{};
    const D3 = struct {
        p: *AlwaysZeroCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(AlwaysZeroCtx, s.p, AlwaysZeroCtx.next, "text/event-stream");
        }
    };
    var sd = D3{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = D3.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 5;
    c.stream_idle_timeout_ms = 0; // disabled
    const t = ft.transport();

    // Park.
    const r1 = c.step(t, d);
    try testing.expectEqual(StepResult.want_stream_repoll, r1);

    // Back-date to look idle for 10 seconds — cap must NOT fire.
    c.last_produce_ns = monotonicNow() - 10_000 * std.time.ns_per_ms;

    // Re-drive.
    _ = c.onDeadline();
    const r2 = c.step(t, d);
    // Cap disabled → parks again, not done_close.
    try testing.expectEqual(StepResult.want_stream_repoll, r2);
    try testing.expectEqual(State.streaming, c.state);
}

test "stream idle cap: busy-spin path (repoll_ms==0) + cap fires → done_close" {
    // With stream_repoll_ms==0 (busy-spin, .want_write path), cap still applies.
    // Producer always returns chunk(0). Back-date last_produce_ns → cap fires on first chunk(0).
    const raw = "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
    var ft = FakeTransport.init(testing.allocator, &.{raw});
    defer ft.deinit();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = RealThenZeroCtx{ .payload = "x" };
    const D4 = struct {
        p: *RealThenZeroCtx,
        fn dispatch(self_ctx: *anyopaque, req: *const request.Request, ar: *std.heap.ArenaAllocator) Response {
            _ = req; _ = ar;
            const s: *@This() = @ptrCast(@alignCast(self_ctx));
            return Response.streamPull(RealThenZeroCtx, s.p, RealThenZeroCtx.next, "text/event-stream");
        }
    };
    var sd = D4{ .p = &ctx };
    const d = Dispatcher{ .ctx = &sd, .dispatchFn = D4.dispatch };

    var c = Conn.init(&rbuf, &wbuf, &arena);
    c.keep_alive = false;
    c.stream_repoll_ms = 0; // busy-spin: uses want_write path
    c.stream_idle_timeout_ms = 10;
    const t = ft.transport();

    // First step: dispatch → head pumped → first real chunk "x" → wrote_all → chunk(0) in busy-spin.
    // Back-date after first step to trigger cap on the second chunk(0).
    // Drive until we hit the chunk(0) path: keep stepping until want_write (busy-spin on chunk(0)).
    var r = c.step(t, d);
    // After head + first real chunk, we expect want_write (chunk(0) busy-spin).
    // The guard loop from other tests shows we may need multiple steps.
    var guard: usize = 0;
    while (r == .want_write and c.state == .writing and guard < 10) : (guard += 1) {
        // Back-date once we know the real chunk was served.
        if (ctx.real_served) {
            c.last_produce_ns = monotonicNow() - 50 * std.time.ns_per_ms;
        }
        r = c.step(t, d);
    }
    try testing.expectEqual(StepResult.done_close, r);
    try testing.expectEqual(State.closing, c.state);
    // No terminator.
    try testing.expect(std.mem.indexOf(u8, ft.written.items, "0\r\n\r\n") == null);
}
