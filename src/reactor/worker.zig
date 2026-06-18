//! Single-worker event loop: listen(SO_REUSEPORT) → epoll/kqueue → Conn state machines.
//!
//! Linux: epoll backend.  macOS/BSD: kqueue backend.  Both are fully supported.
//! On unsupported platforms (Windows, wasm) all `Worker` fn bodies are
//! `unreachable`; tests self-skip via `return error.SkipZigTest`.
//!
//! Cross-platform shape
//! --------------------
//! OS-specific bits are isolated:
//!
//!   • Socket syscalls: `std.posix.setsockopt` where available; `std.os.linux.*`
//!     raw calls on Linux; `std.c.*` on macOS/BSD for functions that `std.posix`
//!     does not yet expose in Zig 0.16 (socket, bind, listen, accept, close,
//!     getsockname, pipe, fcntl, nanosleep, write, read, connect).
//!
//!   • Wake mechanism: a self-pipe (pipe2 on Linux, pipe+fcntl on macOS) with
//!     CLOEXEC|NONBLOCK on both ends.  `wake()` writes 1 byte; the loop drains.
//!
//!   • accept: Linux uses linux.accept4 (sets NONBLOCK+CLOEXEC atomically).
//!     macOS has no accept4 — we use std.c.accept + fcntl(O_NONBLOCK|O_CLOEXEC).
//!
//!   • SIGPIPE: Linux uses MSG_NOSIGNAL on sendto.  macOS: SO_NOSIGPIPE is set
//!     on each accepted fd at accept time to prevent SIGPIPE on writes to a
//!     closed peer.
//!
//!   • Event buffer: typed as `[MAX_EVENTS]poller_mod.Poller.NativeEvent`.
//!     epoll → linux.epoll_event; kqueue → std.posix.Kevent.
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

// Whether this platform has a functional reactor backend.
const reactor_supported = switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
    .freebsd, .dragonfly, .netbsd, .openbsd => true,
    else => false,
};

/// A self-contained epoll/kqueue worker: one listen socket, one self-pipe (wake),
/// and a preallocated pool of connection slots each owning its own buffers + arena.
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
    /// Self-pipe wake: write 1 byte to wake_wr to break epoll_wait;
    /// the loop drains wake_rd.  Both are CLOEXEC | NONBLOCK.
    wake_rd: i32,
    wake_wr: i32,
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
        if (!reactor_supported) unreachable;

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
        // Linux: linux.socket returns usize (raw syscall); macOS/BSD: std.c.socket returns c_int.
        const lfd: i32 = if (builtin.os.tag == .linux) blk: {
            const rc = linux.socket(
                std.posix.AF.INET,
                std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
                0,
            );
            if (linux.errno(rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(rc));
            break :blk @intCast(rc);
        } else blk: {
            const rc = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
            if (rc < 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
            // Set NONBLOCK + CLOEXEC via fcntl.
            setFdFlags(rc, std.c.O{ .NONBLOCK = true, .CLOEXEC = true });
            break :blk rc;
        };
        errdefer closeFd(lfd);

        // SO_REUSEADDR and SO_REUSEPORT via std.posix.setsockopt (available on
        // both Linux and macOS in Zig 0.16).
        const one: c_int = 1;
        try std.posix.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one));
        try std.posix.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&one));

        // Bind.
        var sa: std.posix.sockaddr = undefined;
        const sa_len = ipAddrToSockaddr(addr, &sa);
        if (builtin.os.tag == .linux) {
            const rc = linux.bind(lfd, &sa, sa_len);
            if (linux.errno(rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(rc));
        } else {
            const rc = std.c.bind(lfd, @ptrCast(&sa), sa_len);
            if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
        }

        // Listen.
        if (builtin.os.tag == .linux) {
            const rc = linux.listen(lfd, BACKLOG);
            if (linux.errno(rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(rc));
        } else {
            const rc = std.c.listen(lfd, BACKLOG);
            if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
        }

        // Self-pipe for wake(): CLOEXEC | NONBLOCK on both ends.
        // Linux: pipe2 (atomic). macOS: pipe + fcntl (no pipe2 on macOS).
        var wake_rd: i32 = undefined;
        var wake_wr: i32 = undefined;
        if (builtin.os.tag == .linux) {
            var pipe_fds: [2]i32 = undefined;
            const pipe_rc = linux.pipe2(&pipe_fds, linux.O{ .CLOEXEC = true, .NONBLOCK = true });
            if (linux.errno(pipe_rc) != .SUCCESS) return std.posix.unexpectedErrno(linux.errno(pipe_rc));
            wake_rd = pipe_fds[0];
            wake_wr = pipe_fds[1];
        } else {
            var pipe_fds: [2]std.c.fd_t = undefined;
            const pipe_rc = std.c.pipe(&pipe_fds);
            if (pipe_rc != 0) return std.posix.unexpectedErrno(std.posix.errno(pipe_rc));
            wake_rd = pipe_fds[0];
            wake_wr = pipe_fds[1];
            setFdFlags(wake_rd, std.c.O{ .NONBLOCK = true, .CLOEXEC = true });
            setFdFlags(wake_wr, std.c.O{ .NONBLOCK = true, .CLOEXEC = true });
        }
        errdefer closeFd(wake_rd);
        errdefer closeFd(wake_wr);

        var p = poller;
        try p.add(lfd, LISTEN_TOKEN, true, false);
        try p.add(wake_rd, WAKE_TOKEN, true, false);

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
            .wake_rd = wake_rd,
            .wake_wr = wake_wr,
        };
    }

    pub fn deinit(self: *Worker) void {
        if (!reactor_supported) unreachable;
        closeFd(self.listen_fd);
        closeFd(self.wake_rd);
        closeFd(self.wake_wr);
        self.poller.deinit();
        self.timer.deinit();
        for (self.slots) |*s| s.deinit(self.gpa);
        self.gpa.free(self.slots);
        self.gpa.free(self.free);
        self.* = undefined;
    }

    /// Write 1 byte to the self-pipe write end to break a blocked poll wait.
    /// Safe to call from any thread.
    pub fn wake(self: *Worker) void {
        if (!reactor_supported) unreachable;
        const byte: u8 = 1;
        if (builtin.os.tag == .linux) {
            _ = linux.write(@intCast(self.wake_wr), @ptrCast(&byte), 1);
        } else {
            _ = std.c.write(self.wake_wr, @ptrCast(&byte), 1);
        }
    }

    /// Main event loop.  Runs until `shutdown.load(.acquire)` is true and a
    /// `wake()` call (or timer expiry) breaks the poll wait.
    pub fn run(self: *Worker) void {
        if (!reactor_supported) unreachable;

        // Capture a pointer to self for use in the timer expiry callback.
        // We store it in a thread-local so the *const fn(usize) callback can
        // reach it without needing a closure.
        g_worker = self;

        // Event buffer typed via the poller's native event type — when a
        // kqueue backend defines NativeEvent = std.posix.Kevent, this line
        // is the only worker declaration that changes.
        var events: [MAX_EVENTS]poller_mod.Poller.NativeEvent = undefined;

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
                    // Drain the self-pipe read end (discard bytes; purpose is
                    // only to unblock the poll wait).
                    var drain: [64]u8 = undefined;
                    while (true) {
                        if (builtin.os.tag == .linux) {
                            const rc = linux.read(@intCast(self.wake_rd), &drain, drain.len);
                            if (linux.errno(rc) == .AGAIN) break;
                            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
                        } else {
                            const rc = std.c.read(self.wake_rd, &drain, drain.len);
                            if (rc < 0) {
                                const e = std.posix.errno(rc);
                                if (e == .AGAIN) break; // EAGAIN == EWOULDBLOCK on Darwin
                                break;
                            }
                            if (rc == 0) break;
                        }
                    }
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
            const conn_fd: i32 = if (builtin.os.tag == .linux) blk: {
                const rc = linux.accept4(
                    @intCast(self.listen_fd),
                    &sa,
                    &salen,
                    std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
                );
                const e = linux.errno(rc);
                if (e == .AGAIN) break; // EAGAIN == EWOULDBLOCK
                if (e == .MFILE or e == .NFILE) {
                    std.log.warn("accept4: fd exhaustion ({}), pausing accept", .{e});
                    self.poller.del(self.listen_fd);
                    self.accept_paused = true;
                    break;
                }
                if (e != .SUCCESS) {
                    std.log.warn("accept4: unexpected errno {}, stopping accept loop", .{e});
                    break;
                }
                break :blk @as(i32, @intCast(rc));
            } else blk: {
                // macOS/BSD: no accept4 — use accept + fcntl.
                const rc = std.c.accept(self.listen_fd, @ptrCast(&sa), &salen);
                if (rc < 0) {
                    const e = std.posix.errno(rc);
                    if (e == .AGAIN) break; // EAGAIN == EWOULDBLOCK on Darwin
                    if (e == .MFILE or e == .NFILE) {
                        std.log.warn("accept: fd exhaustion ({}), pausing accept", .{e});
                        self.poller.del(self.listen_fd);
                        self.accept_paused = true;
                        break;
                    }
                    std.log.warn("accept: unexpected errno {}, stopping accept loop", .{e});
                    break;
                }
                setFdFlags(rc, std.c.O{ .NONBLOCK = true, .CLOEXEC = true });
                break :blk rc;
            };

            // macOS: set SO_NOSIGPIPE to prevent SIGPIPE when writing to a
            // closed peer (Linux uses MSG_NOSIGNAL on sendto instead).
            if (builtin.os.tag != .linux) {
                const one: c_int = 1;
                _ = std.c.setsockopt(
                    conn_fd,
                    std.posix.SOL.SOCKET,
                    std.c.SO.NOSIGPIPE,
                    &one,
                    @sizeOf(c_int),
                );
            }

            // Set TCP_NODELAY if requested.
            if (self.opts.tcp_nodelay) {
                const one: c_int = 1;
                if (builtin.os.tag == .linux) {
                    _ = linux.setsockopt(
                        conn_fd,
                        std.posix.IPPROTO.TCP,
                        @intCast(std.posix.TCP.NODELAY),
                        @ptrCast(&one),
                        @sizeOf(c_int),
                    );
                } else {
                    _ = std.c.setsockopt(
                        conn_fd,
                        std.posix.IPPROTO.TCP,
                        std.posix.TCP.NODELAY,
                        &one,
                        @sizeOf(c_int),
                    );
                }
            }

            // Override SO_SNDBUF if requested (useful in tests to force write
            // stalls on loopback where the default send buffer is very large).
            if (self.opts.sndbuf_override != 0) {
                const sndbuf: c_int = @intCast(self.opts.sndbuf_override);
                if (builtin.os.tag == .linux) {
                    _ = linux.setsockopt(
                        conn_fd,
                        std.posix.SOL.SOCKET,
                        std.posix.SO.SNDBUF,
                        @ptrCast(&sndbuf),
                        @sizeOf(c_int),
                    );
                } else {
                    _ = std.c.setsockopt(
                        conn_fd,
                        std.posix.SOL.SOCKET,
                        std.posix.SO.SNDBUF,
                        &sndbuf,
                        @sizeOf(c_int),
                    );
                }
            }

            // Grab a free slot; shed the connection if pool is exhausted.
            if (self.free_len == 0) {
                closeFd(conn_fd);
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

            // Register with poller (start readable).
            self.poller.add(conn_fd, @intCast(slot_idx), true, false) catch {
                closeFd(conn_fd);
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
            .want_stream_repoll => {
                // Producer returned chunk(0) — not ready yet (e.g. sparse SSE stream).
                // Disarm WRITE to stop busy-spin; KEEP READ armed so a peer disconnect
                // during a parked stream is reaped (RDHUP/EOF → hup → closeSlot).
                self.poller.mod(fd, @intCast(slot_idx), true, false) catch {
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
        closeFd(fd);
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
            closeFd(slot.fd);
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
    // std.posix.read handles EINTR internally (retries) and maps EAGAIN →
    // error.WouldBlock.  Works on both Linux and macOS.
    const n = std.posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        error.ConnectionResetByPeer => return .closed,
        else => return .closed,
    };
    if (n == 0) return .closed; // EOF
    return .{ .ok = n };
}

fn sockWriteFn(ctx: *anyopaque, buf: []const u8) IoResult {
    const fd: i32 = @intCast(@intFromPtr(ctx));
    if (builtin.os.tag == .linux) {
        // MSG_NOSIGNAL suppresses SIGPIPE on Linux when writing to a closed peer.
        const rc = linux.sendto(@intCast(fd), buf.ptr, buf.len, linux.MSG.NOSIGNAL, null, 0);
        const e = linux.errno(rc);
        return switch (e) {
            .SUCCESS => .{ .ok = @intCast(rc) },
            .AGAIN => .would_block,
            .CONNRESET, .CONNABORTED, .PIPE => .closed,
            .INTR => .would_block,
            else => .closed,
        };
    } else {
        // macOS/BSD: SO_NOSIGPIPE is set on the socket at accept time so we
        // don't need MSG_NOSIGNAL.  Use std.c.send (no flags needed).
        const rc = std.c.send(fd, buf.ptr, buf.len, 0);
        if (rc < 0) {
            const e = std.posix.errno(rc);
            return switch (e) {
                .AGAIN => .would_block, // EAGAIN == EWOULDBLOCK on Darwin
                .CONNRESET, .CONNABORTED, .PIPE => .closed,
                .INTR => .would_block,
                else => .closed,
            };
        }
        return .{ .ok = @intCast(rc) };
    }
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
        .want_stream_repoll => {
            // onDeadline for .streaming returns .want_write, not .want_stream_repoll.
            // This branch is unreachable in practice but required by the exhaustive switch.
            // Treat as another park: keep read armed, re-insert the timer.
            w.poller.mod(fd, @intCast(slot_idx), true, false) catch {
                w.closeSlot(slot_idx, fd);
                return;
            };
            if (slot.conn.deadline_ns != no_deadline) {
                w.timer.insert(slot_idx, slot.conn.deadline_ns);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Cross-platform fd helpers
// ---------------------------------------------------------------------------

/// Close a file descriptor.  Works on Linux (linux.close) and macOS/BSD (std.c.close).
fn closeFd(fd: i32) void {
    if (builtin.os.tag == .linux) {
        _ = linux.close(@intCast(fd));
    } else {
        _ = std.c.close(fd);
    }
}

/// Set O_NONBLOCK + O_CLOEXEC on `fd` via fcntl.  macOS/BSD only.
/// On Linux, prefer to set these flags atomically at socket/pipe creation time.
fn setFdFlags(fd: i32, flags: std.c.O) void {
    // Get current file status flags and add the requested ones.
    const cur = std.c.fcntl(fd, std.c.F.GETFL);
    // Build the new flags value by ORing the packed struct bits.
    // Cast through u32 to avoid packed-struct comparisons.
    const cur_u: u32 = @bitCast(@as(std.c.O, @bitCast(@as(u32, @intCast(if (cur < 0) 0 else cur)))));
    const add_u: u32 = @bitCast(flags);
    _ = std.c.fcntl(fd, std.c.F.SETFL, cur_u | add_u);
    // Also set FD_CLOEXEC via F.SETFD (separate from O_CLOEXEC on some BSDs).
    if (flags.CLOEXEC) {
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
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
// Test helpers — cross-platform socket primitives
// ---------------------------------------------------------------------------

/// Get the bound port from a listening fd via getsockname.
fn testGetPort(fd: i32) u16 {
    var sa: std.posix.sockaddr = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    if (builtin.os.tag == .linux) {
        _ = linux.getsockname(@intCast(fd), &sa, &sa_len);
    } else {
        _ = std.c.getsockname(fd, @ptrCast(&sa), &sa_len);
    }
    const sa_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&sa));
    return std.mem.bigToNative(u16, sa_in.port);
}

/// Create a blocking client socket and connect to localhost:port.
/// Returns the fd; caller must closeFd.
fn testConnect(port: u16) !i32 {
    const fd: i32 = if (builtin.os.tag == .linux) blk: {
        const rc = linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        break :blk @as(i32, @intCast(rc));
    } else blk: {
        const rc = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (rc < 0) return error.SocketFailed;
        setFdFlags(rc, std.c.O{ .CLOEXEC = true });
        break :blk rc;
    };
    errdefer closeFd(fd);

    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    const ok: bool = if (builtin.os.tag == .linux) blk: {
        const rc = linux.connect(@intCast(fd), @ptrCast(&sa_in), @sizeOf(std.posix.sockaddr.in));
        break :blk linux.errno(rc) == .SUCCESS;
    } else blk: {
        const rc = std.c.connect(fd, @ptrCast(&sa_in), @sizeOf(std.posix.sockaddr.in));
        break :blk rc == 0;
    };
    if (!ok) return error.ConnectFailed;
    return fd;
}

/// Sleep for `ms` milliseconds.
fn testSleep(ms: u64) void {
    if (builtin.os.tag == .linux) {
        const ts = linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = linux.nanosleep(&ts, null);
    } else {
        const ts = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Write all bytes to fd.
fn testWrite(fd: i32, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(linux.write(@intCast(fd), data[sent..].ptr, data.len - sent))
        else
            std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.SendFailed;
        sent += @intCast(n);
    }
}

/// Read bytes from a blocking fd into buf until a complete HTTP response.
fn testRecvResponse(fd: i32, buf: []u8) []u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(linux.read(@intCast(fd), buf[total..].ptr, buf.len - total))
        else
            std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        const so_far = buf[0..total];
        if (std.mem.indexOf(u8, so_far, "\r\n\r\n")) |sep| {
            const headers = so_far[0 .. sep + 4];
            if (std.mem.indexOf(u8, headers, "content-length: ")) |cl_start| {
                const after = headers[cl_start + "content-length: ".len ..];
                const end = std.mem.indexOfAny(u8, after, "\r\n") orelse after.len;
                const clen = std.fmt.parseInt(usize, after[0..end], 10) catch 0;
                if (total - (sep + 4) >= clen) break;
            } else break;
        }
    }
    return buf[0..total];
}

/// Set fd to non-blocking mode.
fn testSetNonblock(fd: i32) void {
    if (builtin.os.tag == .linux) {
        _ = linux.fcntl(@intCast(fd), linux.F.SETFL, linux.SOCK.NONBLOCK);
    } else {
        setFdFlags(fd, std.c.O{ .NONBLOCK = true });
    }
}

/// Read one chunk from fd in non-blocking mode.
/// Returns: positive = bytes read, 0 = EOF, -1 = EAGAIN, -2 = RST/error.
fn testReadNonblock(fd: i32, buf: []u8) isize {
    if (builtin.os.tag == .linux) {
        const rc = linux.read(@intCast(fd), buf.ptr, buf.len);
        const e = linux.errno(rc);
        if (e == .SUCCESS and rc == 0) return 0; // EOF
        if (e == .AGAIN) return -1;
        if (e == .CONNRESET or e == .PIPE) return -2;
        if (e != .SUCCESS) return -2;
        return @intCast(rc);
    } else {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc == 0) return 0; // EOF
        if (rc < 0) {
            const e = std.posix.errno(rc);
            if (e == .AGAIN) return -1; // EAGAIN == EWOULDBLOCK on Darwin
            return -2;
        }
        return rc;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "worker: integration — accept, keep-alive, shutdown" {
    // Skip only on platforms without a reactor backend (Windows, wasm).
    if (!reactor_supported) return error.SkipZigTest;

    const testing = std.testing;

    // Build a minimal dispatcher that serves three routes.
    const Bundle = struct { io: std.Io };

    const DispCtx = struct {
        fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            _ = @as(*Bundle, @ptrCast(@alignCast(ctx))).io;
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

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var bundle = Bundle{ .io = threaded.io() };

    const disp = Dispatcher{
        .ctx = @ptrCast(&bundle),
        .dispatchFn = DispCtx.dispatch,
    };

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

    var shutdown = std.atomic.Value(bool).init(false);
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    const port = testGetPort(worker.listen_fd);

    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    testSleep(10);

    const cfd = try testConnect(port);
    defer closeFd(cfd);

    // --- Request 1: GET / ---
    try testWrite(cfd, "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    var rbuf1: [4096]u8 = undefined;
    const resp1 = testRecvResponse(cfd, &rbuf1);
    try testing.expect(std.mem.indexOf(u8, resp1, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp1, "hello") != null);

    // --- Request 2: keep-alive ---
    try testWrite(cfd, "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    var rbuf2: [4096]u8 = undefined;
    const resp2 = testRecvResponse(cfd, &rbuf2);
    try testing.expect(std.mem.indexOf(u8, resp2, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp2, "hello") != null);

    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}

test "worker: idle connection closed after read timeout (no bytes sent)" {
    if (!reactor_supported) return error.SkipZigTest;

    const testing = std.testing;

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

    const opts = WorkerOpts{
        .max_connections = 64,
        .read_buffer_size = 4 * 1024,
        .write_buffer_size = 4 * 1024,
        .keep_alive = false,
        .max_keep_alive_requests = 1,
        .max_body_size = 0,
        .read_timeout_ms = 200,
        .idle_timeout_ms = 200,
        .tcp_nodelay = true,
    };

    var shutdown = std.atomic.Value(bool).init(false);
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    const port = testGetPort(worker.listen_fd);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    testSleep(10);

    // Connect a client but send ZERO bytes.
    const cfd = try testConnect(port);
    defer closeFd(cfd);

    // Wait up to 1 s for the worker to time-out and close the idle connection.
    var got_eof = false;
    var drain_buf: [4096]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        testSleep(50);
        const n = testReadNonblock(cfd, &drain_buf);
        if (n == 0 or n == -2) { // EOF or RST
            got_eof = true;
            break;
        }
        // n > 0: drained some bytes (likely 408 response); keep polling.
        // n == -1: EAGAIN, nothing yet.
    }

    try testing.expect(got_eof);

    // Verify the slot was freed by doing a real request on a second connection.
    const cfd2 = try testConnect(port);
    defer closeFd(cfd2);

    try testWrite(cfd2, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    var rbuf: [2048]u8 = undefined;
    var total: usize = 0;
    var attempts2: usize = 0;
    while (total < rbuf.len and attempts2 < 40) : (attempts2 += 1) {
        const n: isize = if (builtin.os.tag == .linux)
            @bitCast(linux.read(@intCast(cfd2), rbuf[total..].ptr, rbuf.len - total))
        else
            std.c.read(cfd2, rbuf[total..].ptr, rbuf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, rbuf[0..total], "\r\n\r\n") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, rbuf[0..total], "200") != null);

    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}

test "worker: write-stall deadline — server reaps a peer that stops reading" {
    // TCP_WINDOW_CLAMP is Linux-specific; skip on macOS/BSD.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    // Response body must exceed sndbuf_override + client rcvbuf to force EAGAIN.
    const BODY_SIZE: usize = 3 * 1024;

    const Bundle = struct { io: std.Io };
    const DispCtx = struct {
        fn dispatch(ctx: *anyopaque, req: *const request.Request, arena: *std.heap.ArenaAllocator) Response {
            _ = @as(*Bundle, @ptrCast(@alignCast(ctx))).io;
            _ = req;
            _ = arena;
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

    const opts = WorkerOpts{
        .max_connections = 64,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 4 * 1024,
        .keep_alive = false,
        .max_keep_alive_requests = 1,
        .max_body_size = 0,
        .read_timeout_ms = 300,
        .idle_timeout_ms = 5000,
        .tcp_nodelay = true,
        .sndbuf_override = 2048,
    };

    var shutdown = std.atomic.Value(bool).init(false);
    const listen_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };

    var worker = try Worker.init(testing.allocator, disp, opts, listen_addr, &shutdown);
    defer worker.deinit();

    const port = testGetPort(worker.listen_fd);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    testSleep(10);

    // Create client socket with a very small receive buffer.
    const cfd_rc = linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(cfd_rc));
    const cfd: i32 = @intCast(cfd_rc);
    defer closeFd(cfd);

    const rcvbuf: c_int = 128;
    _ = linux.setsockopt(@intCast(cfd), std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, @ptrCast(&rcvbuf), @sizeOf(c_int));
    const TCP_WINDOW_CLAMP: u32 = 10;
    const wclamp: c_int = 1;
    _ = linux.setsockopt(@intCast(cfd), std.posix.IPPROTO.TCP, TCP_WINDOW_CLAMP, @ptrCast(&wclamp), @sizeOf(c_int));

    var sa_in = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = linux.connect(@intCast(cfd), @ptrCast(&sa_in), @sizeOf(std.posix.sockaddr.in));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(connect_rc));

    try testWrite(cfd, "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    // Do NOT read — let the server's send fill the tiny receive window.
    testSetNonblock(cfd);

    var drain_buf: [4096]u8 = undefined;
    var got_close = false;
    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        testSleep(50);
        var inner: usize = 0;
        while (inner < 256) : (inner += 1) {
            const n = testReadNonblock(cfd, &drain_buf);
            if (n == 0 or n == -2) { got_close = true; break; }
            if (n == -1) break;
        }
        if (got_close) break;
    }

    try testing.expect(got_close);

    shutdown.store(true, .release);
    worker.wake();
    thread.join();
}
