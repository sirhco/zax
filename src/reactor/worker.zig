//! Single-worker event loop: listen(SO_REUSEPORT) → epoll → Conn state machines.
//!
//! Linux only.  On macOS all types compile but all `Worker` fn bodies are
//! `unreachable`; the module is reachable through `root.zig` / `refAllDecls`
//! so it participates in comptime analysis on every platform.  The one `test`
//! block self-skips off-Linux via `return error.SkipZigTest`.
//!
//! Dispatcher ctx contract (Task 8 → Task 9)
//! ------------------------------------------
//! `App(S).dispatch` takes a `std.Io` as its first argument (it is forwarded to
//! `makeCtx` and stored in `Ctx.io`).  Rather than storing `std.Io` on the
//! Worker itself, the `std.Io` travels inside the `Dispatcher.ctx`.  Callers
//! (Worker.init test, and `serveEvented` in Task 9) must build the Dispatcher
//! with a ctx that bundles both `*App` and the `std.Io`, then have `dispatchFn`
//! cast ctx → bundle and call `app.dispatch(bundle.io, req, arena, rid)`.
//!
//! USERS: do not use `Files` or any other blocking-IO extractor inside a handler
//! served by a Worker; blocking IO stalls the entire worker event loop (no new
//! accepts, no timer sweeps, no other connections can make progress).  Use only
//! sync/compute-only extractors (Path, Query, Json, State, etc.).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const net = std.Io.net;

const conn_mod = @import("conn.zig");
const poller_mod = @import("poller.zig");
const timer_mod = @import("timer.zig");
const transport_mod = @import("transport.zig");
const request = @import("../http/request.zig");
const Response = @import("../http/response.zig").Response;

const Conn = conn_mod.Conn;
const Dispatcher = conn_mod.Dispatcher;
const monotonicNow = conn_mod.monotonicNow;
const Poller = poller_mod.Poller;
const TimerWheel = timer_mod.TimerWheel;
const Transport = transport_mod.Transport;
const IoResult = transport_mod.IoResult;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const WorkerOpts = struct {
    max_connections: usize = 1024,
    read_buffer_size: usize,
    write_buffer_size: usize,
    keep_alive: bool,
    max_keep_alive_requests: usize,
    max_body_size: usize,
    read_timeout_ms: u32,
    idle_timeout_ms: u32,
    tcp_nodelay: bool,
    /// If nonzero, set SO_SNDBUF to this value on each accepted socket.
    /// 0 = system default (no override).  Useful in tests to force write
    /// stalls on loopback where the default send buffer is too large.
    sndbuf_override: u32 = 0,
};

/// A self-contained epoll worker: one listen socket, one eventfd (wake), and a
/// preallocated pool of connection slots each owning its own buffers + arena.
pub const Worker = struct {
    gpa: std.mem.Allocator,
    dispatcher: Dispatcher,
    opts: WorkerOpts,
    addr: net.IpAddress,
    shutdown: *std.atomic.Value(bool),

    /// Preallocated connection slots.
    slots: []Slot,
    /// Free-list: indices into `slots` that are currently unused.
    free: []usize,
    free_len: usize,

    poller: Poller,
    timer: TimerWheel,
    listen_fd: i32,
    wake_fd: i32, // eventfd used by wake()
    /// Set when accept4 returns EMFILE/ENFILE (fd exhaustion).  The listen fd
    /// is removed from epoll to stop busy-spinning; it is re-added in closeSlot
    /// once a slot + fd frees up.
    accept_paused: bool = false,

    // Sentinel data.u64 values for the listen and wake fds.
    // They must not collide with any valid slot index (0..max_connections-1).
    const LISTEN_TOKEN: u64 = std.math.maxInt(u64);
    const WAKE_TOKEN: u64 = std.math.maxInt(u64) - 1;

    // Timer-wheel parameters: 100 ms tick, 1024 buckets → ~102 s range.
    const TW_TICK_MS: u32 = 100;
    const TW_WHEEL: usize = 1024;

    // epoll batch size.
    const MAX_EVENTS: usize = 64;

    // TCP listen backlog.
    const BACKLOG: u32 = 128;

    pub fn init(
        gpa: std.mem.Allocator,
        dispatcher: Dispatcher,
        opts: WorkerOpts,
        addr: net.IpAddress,
        shutdown: *std.atomic.Value(bool),
    ) !Worker {
        if (builtin.os.tag != .linux) unreachable;

        const slots = try gpa.alloc(Slot, opts.max_connections);
        errdefer gpa.free(slots);
        for (slots, 0..) |*s, i| {
            s.* = try Slot.init(gpa, opts.read_buffer_size, opts.write_buffer_size);
            s.free_idx = i; // not meaningful yet but keeps things tidy
        }

        const free = try gpa.alloc(usize, opts.max_connections);
        errdefer gpa.free(free);
        for (free, 0..) |*f, i| f.* = opts.max_connections - 1 - i; // push in reverse so [0] is cheapest

        var poller = try Poller.init();
        errdefer poller.deinit();

        var timer = try TimerWheel.init(gpa, TW_TICK_MS, TW_WHEEL);
        errdefer timer.deinit();

        // Create listen socket.
        const lfd_rc = linux.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        if (linux.errno(lfd_rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(lfd_rc));
        const lfd: i32 = @intCast(lfd_rc);
        errdefer _ = linux.close(@intCast(lfd));

        const one: c_int = 1;
        _ = linux.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));
        _ = linux.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, @ptrCast(&one), @sizeOf(c_int));

        // Bind.
        var sa: std.posix.sockaddr = undefined;
        const sa_len = ipAddrToSockaddr(addr, &sa);
        const bind_rc = linux.bind(lfd, &sa, sa_len);
        if (linux.errno(bind_rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(bind_rc));

        // Listen.
        const listen_rc = linux.listen(lfd, BACKLOG);
        if (linux.errno(listen_rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(listen_rc));

        // eventfd for wake().
        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd_rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(efd_rc));
        const efd: i32 = @intCast(efd_rc);
        errdefer _ = linux.close(@intCast(efd));

        var p = poller;
        try p.add(lfd, LISTEN_TOKEN, true, false);
        try p.add(efd, WAKE_TOKEN, true, false);

        return .{
            .gpa = gpa,
            .dispatcher = dispatcher,
            .opts = opts,
            .addr = addr,
            .shutdown = shutdown,
            .slots = slots,
            .free = free,
            .free_len = opts.max_connections,
            .poller = p,
            .timer = timer,
            .listen_fd = lfd,
            .wake_fd = efd,
        };
    }

    pub fn deinit(self: *Worker) void {
        if (builtin.os.tag != .linux) unreachable;
        _ = linux.close(@intCast(self.listen_fd));
        _ = linux.close(@intCast(self.wake_fd));
        self.poller.deinit();
        self.timer.deinit();
        for (self.slots) |*s| s.deinit(self.gpa);
        self.gpa.free(self.slots);
        self.gpa.free(self.free);
        self.* = undefined;
    }

    /// Write to the eventfd to break a blocked `epoll_wait`.  Safe to call
    /// from any thread.
    pub fn wake(self: *Worker) void {
        if (builtin.os.tag != .linux) unreachable;
        const val: u64 = 1;
        _ = linux.write(@intCast(self.wake_fd), @ptrCast(&val), 8);
    }

    /// Main event loop.  Runs until `shutdown.load(.acquire)` is true and a
    /// `wake()` call (or timer expiry) breaks the `epoll_wait`.
    pub fn run(self: *Worker) void {
        if (builtin.os.tag != .linux) unreachable;

        // Capture a pointer to self for use in the timer expiry callback.
        // We store it in a thread-local so the *const fn(usize) callback can
        // reach it without needing a closure.
        g_worker = self;

        var events: [MAX_EVENTS]linux.epoll_event = undefined;

        while (true) {
            const now = monotonicNow();
            const timeout_ms = blk: {
                const t = self.timer.nextDeadlineMs(now);
                // -1 from nextDeadlineMs means no timers; cap to a maximum
                // so shutdown checks happen periodically.
                if (t < 0) break :blk @as(i32, 1000);
                break :blk t;
            };

            const n = self.poller.wait(events[0..], timeout_ms);

            // Process events.
            for (events[0..n]) |raw_ev| {
                const ev = poller_mod.eventFromRaw(raw_ev);

                if (ev.data == LISTEN_TOKEN) {
                    // Accept new connections (loop until WouldBlock).
                    self.acceptLoop();
                } else if (ev.data == WAKE_TOKEN) {
                    // Drain the eventfd counter.
                    var buf: u64 = 0;
                    _ = linux.read(@intCast(self.wake_fd), @ptrCast(&buf), 8);
                    // Shutdown check happens after the event loop below.
                } else {
                    // Connection event.
                    const slot_idx: usize = @intCast(ev.data);
                    if (slot_idx >= self.opts.max_connections) continue; // stale
                    const slot = &self.slots[slot_idx];
                    if (!slot.active) continue; // stale event for a recycled slot

                    const fd = slot.fd;

                    if (ev.hup) {
                        // Peer closed or error.
                        self.closeSlot(slot_idx, fd);
                        continue;
                    }

                    const t = sockTransport(fd);
                    const result = slot.conn.step(t, self.dispatcher);
                    self.handleStepResult(slot_idx, fd, result, &slot.conn);
                }
            }

            // Advance timer wheel after draining all events.
            const now2 = monotonicNow();
            self.timer.advance(now2, expiredCb);

            // Check shutdown after processing events + timers.
            if (self.shutdown.load(.acquire)) break;
        }

        // Graceful drain: close all active connections.
        self.drainAll();
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    fn acceptLoop(self: *Worker) void {
        while (true) {
            var sa: std.posix.sockaddr = undefined;
            var salen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const rc = linux.accept4(
                @intCast(self.listen_fd),
                &sa,
                &salen,
                std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            );
            const e = linux.errno(rc);
            if (e == .AGAIN) break; // EAGAIN == EWOULDBLOCK on Linux
            if (e == .MFILE or e == .NFILE) {
                // fd table exhausted — remove listen fd from epoll to stop
                // busy-spinning.  closeSlot will re-add it once a slot frees.
                std.log.warn("accept4: fd exhaustion ({}), pausing accept", .{e});
                self.poller.del(self.listen_fd);
                self.accept_paused = true;
                break;
            }
            if (e != .SUCCESS) {
                std.log.warn("accept4: unexpected errno {}, stopping accept loop", .{e});
                break;
            }
            const conn_fd: i32 = @intCast(rc);

            // Set TCP_NODELAY if requested.
            if (self.opts.tcp_nodelay) {
                const one: c_int = 1;
                _ = linux.setsockopt(
                    conn_fd,
                    std.posix.IPPROTO.TCP,
                    @intCast(std.posix.TCP.NODELAY),
                    @ptrCast(&one),
                    @sizeOf(c_int),
                );
            }

            // Override SO_SNDBUF if requested (useful in tests to force write
            // stalls on loopback where the default send buffer is very large).
            if (self.opts.sndbuf_override != 0) {
                const sndbuf: c_int = @intCast(self.opts.sndbuf_override);
                _ = linux.setsockopt(
                    conn_fd,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.SNDBUF,
                    @ptrCast(&sndbuf),
                    @sizeOf(c_int),
                );
            }

            // Grab a free slot; shed the connection if pool is exhausted.
            if (self.free_len == 0) {
                _ = linux.close(@intCast(conn_fd));
                continue;
            }
            self.free_len -= 1;
            const slot_idx = self.free[self.free_len];
            const slot = &self.slots[slot_idx];

            // Initialise / reuse the slot.
            slot.conn = Conn.init(slot.read_buf, slot.write_buf, &slot.arena);
            slot.conn.keep_alive = self.opts.keep_alive;
            slot.conn.max_keep_alive_requests = self.opts.max_keep_alive_requests;
            slot.conn.max_body_size = self.opts.max_body_size;
            slot.conn.read_timeout_ms = self.opts.read_timeout_ms;
            slot.conn.idle_timeout_ms = self.opts.idle_timeout_ms;
            slot.fd = conn_fd;
            slot.active = true;

            // Register with epoll (start readable).
            self.poller.add(conn_fd, @intCast(slot_idx), true, false) catch {
                _ = linux.close(@intCast(conn_fd));
                self.freeSlot(slot_idx);
                continue;
            };

            // Arm the read deadline at accept time — NOT deferred to the first
            // conn.step call.  A peer that completes the TCP handshake but sends
            // nothing never triggers EPOLLIN, so conn.step never runs, the deadline
            // is never set, and the fd+slot would leak until process exit (idle-conn
            // DoS / fd exhaustion).  Pre-arming here closes that window.
            //
            // We mirror exactly what conn.step does on reading_head entry:
            //   if read_timeout_ms == 0 → no deadline (sentinel)
            //   else                    → now + timeout_ms * 1_000_000 ns
            //
            // conn.step detects "deadline already set" via `if (deadline_ns ==
            // no_deadline)` and skips re-arming on first readable event, so there
            // is no double-arm.
            if (self.opts.read_timeout_ms != 0) {
                slot.conn.deadline_ns = monotonicNow() +
                    @as(i96, self.opts.read_timeout_ms) * 1_000_000;
                self.timer.insert(slot_idx, slot.conn.deadline_ns);
            }
            // If read_timeout_ms == 0, deadline_ns stays at no_deadline (maxInt(i96))
            // and no timer entry is created — consistent with conn.step's own logic.
        }
    }

    fn handleStepResult(
        self: *Worker,
        slot_idx: usize,
        fd: i32,
        result: conn_mod.StepResult,
        c: *Conn,
    ) void {
        switch (result) {
            .want_read => {
                self.poller.mod(fd, @intCast(slot_idx), true, false) catch {
                    // epoll_ctl MOD failed — connection is unregisterable; close it.
                    self.closeSlot(slot_idx, fd);
                    return;
                };
                // Update timer deadline.
                if (c.deadline_ns != no_deadline) {
                    self.timer.insert(slot_idx, c.deadline_ns);
                } else {
                    self.timer.remove(slot_idx);
                }
            },
            .want_write => {
                self.poller.mod(fd, @intCast(slot_idx), false, true) catch {
                    self.closeSlot(slot_idx, fd);
                    return;
                };
                if (c.deadline_ns != no_deadline) {
                    self.timer.insert(slot_idx, c.deadline_ns);
                } else {
                    self.timer.remove(slot_idx);
                }
            },
            .done_close => {
                self.closeSlot(slot_idx, fd);
            },
        }
    }

    fn closeSlot(self: *Worker, slot_idx: usize, fd: i32) void {
        self.poller.del(fd);
        _ = linux.close(@intCast(fd));
        self.timer.remove(slot_idx);
        self.freeSlot(slot_idx);
        // If accept was paused due to fd exhaustion, re-register the listen fd
        // now that a slot + fd have been freed.
        if (self.accept_paused) {
            self.poller.add(self.listen_fd, LISTEN_TOKEN, true, false) catch {};
            self.accept_paused = false;
        }
    }

    fn freeSlot(self: *Worker, slot_idx: usize) void {
        const slot = &self.slots[slot_idx];
        slot.active = false;
        slot.fd = -1;
        // Reset arena (retain capacity so the allocator re-uses it).
        _ = slot.arena.reset(.retain_capacity);
        self.free[self.free_len] = slot_idx;
        self.free_len += 1;
    }

    fn drainAll(self: *Worker) void {
        for (self.slots, 0..) |*slot, i| {
            if (!slot.active) continue;
            self.poller.del(slot.fd);
            _ = linux.close(@intCast(slot.fd));
            self.timer.remove(i);
            _ = slot.arena.reset(.retain_capacity);
            slot.active = false;
        }
        // Reset free list.
        self.free_len = self.opts.max_connections;
        for (self.free, 0..) |*f, i| f.* = self.opts.max_connections - 1 - i;
    }
};

// ---------------------------------------------------------------------------
// Connection slot
// ---------------------------------------------------------------------------

/// Owns the memory for one connection: buffers, arena, and the Conn state machine.
const Slot = struct {
    read_buf: []u8,
    write_buf: []u8,
    arena: std.heap.ArenaAllocator,
    conn: Conn = undefined, // valid only when active
    fd: i32 = -1,
    active: bool = false,
    free_idx: usize = 0, // index back into Worker.slots (set at alloc time)

    fn init(gpa: std.mem.Allocator, read_buf_size: usize, write_buf_size: usize) !Slot {
        const rb = try gpa.alloc(u8, read_buf_size);
        errdefer gpa.free(rb);
        const wb = try gpa.alloc(u8, write_buf_size);
        return .{
            .read_buf = rb,
            .write_buf = wb,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
        gpa.free(self.read_buf);
        gpa.free(self.write_buf);
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// SockTransport — real non-blocking socket IO
// ---------------------------------------------------------------------------

/// Build a `Transport` vtable that reads/writes the given fd via syscalls.
fn sockTransport(fd: i32) Transport {
    // We store the fd as a usize and cast it in the vtable functions.
    // Zig requires that `context` is `*anyopaque`, so we bitcast the fd integer
    // into a pointer (it is never dereferenced, only bitcast back).
    const ctx: *anyopaque = @ptrFromInt(@as(usize, @intCast(fd)));
    return .{
        .context = ctx,
        .readFn = sockReadFn,
        .writeFn = sockWriteFn,
    };
}

fn sockReadFn(ctx: *anyopaque, buf: []u8) IoResult {
    const fd: i32 = @intCast(@intFromPtr(ctx));
    const rc = linux.read(@intCast(fd), buf.ptr, buf.len);
    const e = linux.errno(rc);
    return switch (e) {
        .SUCCESS => {
            if (rc == 0) return .closed; // EOF
            return .{ .ok = @intCast(rc) };
        },
        .AGAIN => .would_block, // EAGAIN == EWOULDBLOCK on Linux
        .CONNRESET, .CONNABORTED, .PIPE => .closed,
        .INTR => .would_block, // treat signal interrupts as transient
        else => .closed,
    };
}

fn sockWriteFn(ctx: *anyopaque, buf: []const u8) IoResult {
    const fd: i32 = @intCast(@intFromPtr(ctx));
    // MSG_NOSIGNAL prevents SIGPIPE when writing to a closed peer.
    const MSG_NOSIGNAL: u32 = if (builtin.os.tag == .linux) linux.MSG.NOSIGNAL else 0;
    const rc = linux.sendto(@intCast(fd), buf.ptr, buf.len, MSG_NOSIGNAL, null, 0);
    const e = linux.errno(rc);
    return switch (e) {
        .SUCCESS => .{ .ok = @intCast(rc) },
        .AGAIN => .would_block, // EAGAIN == EWOULDBLOCK on Linux
        .CONNRESET, .CONNABORTED, .PIPE => .closed,
        .INTR => .would_block,
        else => .closed,
    };
}

// ---------------------------------------------------------------------------
// Timer-expiry callback (thread-local worker pointer)
// ---------------------------------------------------------------------------

/// Thread-local pointer to the running Worker.  Set at the top of `run`.
threadlocal var g_worker: ?*Worker = null;

fn expiredCb(slot_idx: usize) void {
    const w = g_worker orelse return;
    if (slot_idx >= w.opts.max_connections) return;
    const slot = &w.slots[slot_idx];
    if (!slot.active) return;

    const fd = slot.fd;
    const result = slot.conn.onDeadline();
    switch (result) {
        .want_write => {
            // Send the 408 best-effort.
            const t = sockTransport(fd);
            const r2 = slot.conn.step(t, w.dispatcher);
            w.handleStepResult(slot_idx, fd, r2, &slot.conn);
        },
        .done_close => {
            w.closeSlot(slot_idx, fd);
        },
        .want_read => {
            // Shouldn't happen from onDeadline, but handle gracefully.
            w.poller.mod(fd, @intCast(slot_idx), true, false) catch {
                w.closeSlot(slot_idx, fd);
            };
        },
    }
}

// Sentinel value matching conn.zig's private `no_deadline` constant.
// conn.zig initialises `deadline_ns` to `maxInt(i96)`; we compare against this
// to decide whether to arm the timer wheel after accepting a connection.
const no_deadline: i96 = std.math.maxInt(i96);

// ---------------------------------------------------------------------------
// Address helpers
// ---------------------------------------------------------------------------

/// Convert a `net.IpAddress` to a `std.posix.sockaddr` for syscall use.
/// Returns the sockaddr length.
fn ipAddrToSockaddr(addr: net.IpAddress, out: *std.posix.sockaddr) std.posix.socklen_t {
    switch (addr) {
        .ip4 => |ip4| {
            const sa: *std.posix.sockaddr.in = @ptrCast(@alignCast(out));
            sa.* = .{
                .family = std.posix.AF.INET,
                // Ip4Address.bytes is in network byte order (big-endian).
                .addr = @bitCast(ip4.bytes),
                // Ip4Address.port is in native byte order; syscalls want big-endian.
                .port = std.mem.nativeToBig(u16, ip4.port),
                .zero = @splat(0),
            };
            return @sizeOf(std.posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            const sa: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(out));
            sa.* = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = 0,
            };
            return @sizeOf(std.posix.sockaddr.in6);
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "worker: integration — accept, keep-alive, shutdown" {
    // Self-skip on non-Linux: epoll doesn't exist.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    // Build a minimal dispatcher that serves three routes.
    // The Dispatcher ctx bundles io + app state so io travels through the
    // vtable rather than being stored on Worker (Task 9 contract: serveEvented
    // builds the real Dispatcher the same way, bundling *App + init.io).
    const Bundle = struct {
        io: std.Io,
    };

    const DispCtx = struct {
        fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            _ = @as(*Bundle, @ptrCast(@alignCast(ctx))).io; // io available here
            _ = arena;
            if (std.mem.eql(u8, req.path, "/")) {
                return Response.text("hello");
            } else if (std.mem.startsWith(u8, req.path, "/users/")) {
                return Response.text(req.path["/users/".len..]);
            } else if (std.mem.eql(u8, req.path, "/echo")) {
                return Response.text(req.body);
            }
            return Response.fromStatus(.not_found);
        }
    };

    // Use std.Io.Threaded for the bundle io (not actually exercised by these
    // sync-only test handlers, but proves the contract compiles and links).
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bundle = Bundle{ .io = threaded.io() };

    const disp = Dispatcher{
        .ctx = @ptrCast(&bundle),
        .dispatchFn = DispCtx.dispatch,
    };

    // Build opts.
    const opts = WorkerOpts{
        .max_connections = 64,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 8 * 1024,
        .keep_alive = true,
        .max_keep_alive_requests = 100,
        .max_body_size = 0,
        .read_timeout_ms = 5000,
        .idle_timeout_ms = 5000,
        .tcp_nodelay = true,
    };

    // Bind to an ephemeral port on loopback.
    var shutdown = std.atomic.Value(bool).init(false);

    // Pick an ephemeral port (port 0 → kernel assigns).
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    // Find out which port the kernel assigned by getsockname.
    var bound: std.posix.sockaddr = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const grc = linux.getsockname(@intCast(worker.listen_fd), &bound, &bound_len);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(grc));
    const bound_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&bound));
    const port = std.mem.bigToNative(u16, bound_in.port);

    // Start the worker in a thread.
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Give the worker a moment to enter epoll_wait.
    {
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }

    // Connect a raw client socket.
    const cfd_rc = linux.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(cfd_rc));
    const cfd: i32 = @intCast(cfd_rc);
    defer _ = linux.close(@intCast(cfd));

    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = linux.connect(
        @intCast(cfd),
        @ptrCast(&sa_in),
        @sizeOf(std.posix.sockaddr.in),
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(connect_rc));

    // Helper: send + receive on the blocking client socket.
    const sendAll = struct {
        fn f(fd: i32, data: []const u8) !void {
            var sent: usize = 0;
            while (sent < data.len) {
                const n = linux.write(@intCast(fd), data[sent..].ptr, data.len - sent);
                if (linux.errno(n) != .SUCCESS) return error.SendFailed;
                sent += @intCast(n);
            }
        }
    }.f;

    const recvResponse = struct {
        fn f(fd: i32, buf: []u8) ![]u8 {
            var total: usize = 0;
            while (total < buf.len) {
                const n = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
                if (linux.errno(n) != .SUCCESS) return buf[0..total];
                if (n == 0) return buf[0..total];
                total += @intCast(n);
                // Check if we have a complete HTTP response: headers + body.
                const so_far = buf[0..total];
                // Find header/body separator.
                if (std.mem.indexOf(u8, so_far, "\r\n\r\n")) |sep| {
                    // Check if Content-Length is present to know how much body to expect.
                    const headers = so_far[0 .. sep + 4];
                    if (std.mem.indexOf(u8, headers, "content-length: ")) |cl_start| {
                        const after = headers[cl_start + "content-length: ".len ..];
                        const end = std.mem.indexOfAny(u8, after, "\r\n") orelse after.len;
                        const clen = std.fmt.parseInt(usize, after[0..end], 10) catch 0;
                        const body_received = total - (sep + 4);
                        if (body_received >= clen) return buf[0..total];
                    } else {
                        // No content-length: assume done (e.g. 0-byte body).
                        return buf[0..total];
                    }
                }
            }
            return buf[0..total];
        }
    }.f;

    // --- Request 1: GET / ---
    const req1 = "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n";
    try sendAll(cfd, req1);

    var rbuf1: [4096]u8 = undefined;
    const resp1 = try recvResponse(cfd, &rbuf1);
    try testing.expect(std.mem.indexOf(u8, resp1, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp1, "hello") != null);

    // --- Request 2: GET / on same connection (keep-alive) ---
    const req2 = "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n";
    try sendAll(cfd, req2);

    var rbuf2: [4096]u8 = undefined;
    const resp2 = try recvResponse(cfd, &rbuf2);
    try testing.expect(std.mem.indexOf(u8, resp2, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp2, "hello") != null);

    // --- Shutdown ---
    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}

test "worker: idle connection closed after read timeout (no bytes sent)" {
    // Linux-only: epoll doesn't exist elsewhere.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    // Minimal dispatcher — never called for this test (client sends nothing).
    const Bundle = struct { io: std.Io };
    const DispCtx = struct {
        fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            _ = @as(*Bundle, @ptrCast(@alignCast(ctx))).io;
            _ = req;
            _ = arena;
            return Response.text("ok");
        }
    };

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bundle = Bundle{ .io = threaded.io() };

    const disp = Dispatcher{
        .ctx = @ptrCast(&bundle),
        .dispatchFn = DispCtx.dispatch,
    };

    // Short read_timeout so the test completes quickly.
    const opts = WorkerOpts{
        .max_connections = 64,
        .read_buffer_size = 4 * 1024,
        .write_buffer_size = 4 * 1024,
        .keep_alive = false,
        .max_keep_alive_requests = 1,
        .max_body_size = 0,
        .read_timeout_ms = 200, // 200 ms — short enough for a unit test
        .idle_timeout_ms = 200,
        .tcp_nodelay = true,
    };

    var shutdown = std.atomic.Value(bool).init(false);
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    // Find out which port the kernel assigned.
    var bound: std.posix.sockaddr = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const grc = linux.getsockname(@intCast(worker.listen_fd), &bound, &bound_len);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(grc));
    const bound_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&bound));
    const port = std.mem.bigToNative(u16, bound_in.port);

    // Start the worker.
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Brief pause for the worker to enter epoll_wait.
    {
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }

    // Connect a client but send ZERO bytes.
    const cfd_rc = linux.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(cfd_rc));
    const cfd: i32 = @intCast(cfd_rc);
    defer _ = linux.close(@intCast(cfd));

    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = linux.connect(
        @intCast(cfd),
        @ptrCast(&sa_in),
        @sizeOf(std.posix.sockaddr.in),
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(connect_rc));

    // Wait up to 1 s for the worker to time-out and close the idle connection.
    // On read timeout the worker sends a 408 Request Timeout and then closes.
    // Drain all incoming bytes until we get EOF (read returns 0).
    var got_eof = false;
    var drain_buf: [4096]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const ts = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);

        const n = linux.read(@intCast(cfd), &drain_buf, drain_buf.len);
        const e = linux.errno(n);
        if (e == .SUCCESS and n == 0) {
            got_eof = true; // clean EOF — worker closed the connection
            break;
        }
        if (e == .CONNRESET or e == .PIPE) {
            got_eof = true; // RST — also counts as closed
            break;
        }
        // n > 0: we received the 408 response bytes — keep draining until EOF.
        // EAGAIN: nothing yet, keep waiting.
    }

    try testing.expect(got_eof); // idle connection must be closed by the timeout

    // Slot is reusable: the free-list length should have recovered.
    // We can't easily inspect worker internals from outside the struct,
    // but we verify by connecting *again* and doing a real request — if the
    // slot was properly freed we get a 200; if not, the pool would be at
    // capacity and the second connect would be shed.
    const cfd2_rc = linux.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(cfd2_rc));
    const cfd2: i32 = @intCast(cfd2_rc);
    defer _ = linux.close(@intCast(cfd2));

    const con2_rc = linux.connect(
        @intCast(cfd2),
        @ptrCast(&sa_in),
        @sizeOf(std.posix.sockaddr.in),
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(con2_rc));

    // Send a valid request on the second connection.
    const req_str = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var sent: usize = 0;
    while (sent < req_str.len) {
        const n = linux.write(@intCast(cfd2), req_str[sent..].ptr, req_str.len - sent);
        if (linux.errno(n) != .SUCCESS) break;
        sent += @intCast(n);
    }

    var rbuf: [2048]u8 = undefined;
    var total: usize = 0;
    var attempts2: usize = 0;
    while (total < rbuf.len and attempts2 < 40) : (attempts2 += 1) {
        const n = linux.read(@intCast(cfd2), rbuf[total..].ptr, rbuf.len - total);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, rbuf[0..total], "\r\n\r\n") != null) break;
    }

    try testing.expect(std.mem.indexOf(u8, rbuf[0..total], "200") != null);

    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}

test "worker: write-stall deadline — server reaps a peer that stops reading" {
    // Linux-only: epoll + SO_RCVBUF behaviour tested here.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    // Response body must fit in write_buffer_size (4 KB) but exceed the
    // combined SO_SNDBUF (2 KB override) + SO_RCVBUF (1 KB) so the server's
    // send() hits EAGAIN and enters the want_write stall path.
    // Body 3 KB + ~100 bytes headers = ~3.1 KB → fits in 4 KB write buffer
    // but exceeds the 2 KB sndbuf_override + 1 KB rcvbuf = 3 KB total.
    const BODY_SIZE: usize = 3 * 1024; // 3 KB

    const Bundle = struct { io: std.Io };
    const DispCtx = struct {
        fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            _ = @as(*Bundle, @ptrCast(@alignCast(ctx))).io;
            _ = req;
            _ = arena;
            // Build a 3 KB body: all 'X' bytes.
            var body_buf: [BODY_SIZE]u8 = undefined;
            @memset(&body_buf, 'X');
            return Response.text(&body_buf);
        }
    };

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bundle = Bundle{ .io = threaded.io() };

    const disp = Dispatcher{
        .ctx = @ptrCast(&bundle),
        .dispatchFn = DispCtx.dispatch,
    };

    // Short read_timeout_ms doubles as the write-stall deadline.
    const opts = WorkerOpts{
        .max_connections = 64,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 4 * 1024, // fits the 3 KB body + headers
        .keep_alive = false,
        .max_keep_alive_requests = 1,
        .max_body_size = 0,
        .read_timeout_ms = 300, // 300 ms write-stall deadline
        .idle_timeout_ms = 5000,
        .tcp_nodelay = true,
        // Force a tiny SO_SNDBUF on accepted fds so the server hits EAGAIN
        // quickly on loopback (default loopback sndbuf is ~200 KB).
        .sndbuf_override = 2048,
    };

    var shutdown = std.atomic.Value(bool).init(false);
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    var bound: std.posix.sockaddr = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const grc = linux.getsockname(@intCast(worker.listen_fd), &bound, &bound_len);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(grc));
    const bound_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&bound));
    const port = std.mem.bigToNative(u16, bound_in.port);

    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Wait for worker to enter epoll_wait.
    {
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }

    // Create client socket with a very small receive buffer (1 KB).
    // This ensures the server's send() fills the client window quickly and
    // blocks (EAGAIN / want_write) — the classic write-stall scenario.
    const cfd_rc = linux.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(cfd_rc));
    const cfd: i32 = @intCast(cfd_rc);
    defer _ = linux.close(@intCast(cfd));

    // Set SO_RCVBUF to minimum so the kernel allocates a tiny receive buffer.
    const rcvbuf: c_int = 128;
    _ = linux.setsockopt(
        @intCast(cfd),
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        @ptrCast(&rcvbuf),
        @sizeOf(c_int),
    );
    // TCP_WINDOW_CLAMP = 10: clamp the advertised receive window to 1 byte.
    // Once 1 byte lands in the kernel receive buffer (and we never read),
    // the client advertises window=0.  The server's send() then returns
    // EAGAIN → want_write stall.  This is reliable even on loopback where
    // the default send buffer would otherwise absorb the whole response.
    const TCP_WINDOW_CLAMP: u32 = 10;
    const wclamp: c_int = 1;
    _ = linux.setsockopt(
        @intCast(cfd),
        std.posix.IPPROTO.TCP,
        TCP_WINDOW_CLAMP,
        @ptrCast(&wclamp),
        @sizeOf(c_int),
    );

    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = linux.connect(
        @intCast(cfd),
        @ptrCast(&sa_in),
        @sizeOf(std.posix.sockaddr.in),
    );
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(connect_rc));

    // Send a valid GET request.
    const req_str = "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    var sent: usize = 0;
    while (sent < req_str.len) {
        const n = linux.write(@intCast(cfd), req_str[sent..].ptr, req_str.len - sent);
        if (linux.errno(n) != .SUCCESS) break;
        sent += @intCast(n);
    }

    // Do NOT read the response — let the server's send fill the tiny receive
    // window.  The server will hit EAGAIN → want_write → write-stall deadline.
    // After ~300 ms the server should close the connection.

    // Set the client socket non-blocking so we can drain + detect EOF without
    // blocking the test thread indefinitely.
    // linux.SOCK.NONBLOCK == O_NONBLOCK on Linux (same constant, 0o4000).
    _ = linux.fcntl(@intCast(cfd), linux.F.SETFL, linux.SOCK.NONBLOCK);

    // Poll for EOF/RST: drain all available data (consuming it), watching for
    // rc==0 (EOF) or ECONNRESET (RST) which signals the server closed.
    // We try up to ~1.5 s (30 × 50 ms) to allow the 300 ms deadline to fire.
    var drain_buf: [4096]u8 = undefined;
    var got_close = false;
    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        const ts = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);

        // Drain all available bytes in a tight loop.
        var inner: usize = 0;
        while (inner < 256) : (inner += 1) {
            const rc = linux.read(@intCast(cfd), &drain_buf, drain_buf.len);
            const e = linux.errno(rc);
            if (e == .SUCCESS and rc == 0) {
                got_close = true; // clean EOF
                break;
            }
            if (e == .CONNRESET or e == .PIPE) {
                got_close = true; // RST
                break;
            }
            if (e == .AGAIN) break; // no more data right now
            // rc > 0: consumed bytes, keep draining
        }
        if (got_close) break;
    }

    try testing.expect(got_close); // server must reap the stalled connection

    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}

