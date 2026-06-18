//! Poller — platform dispatcher.
//!
//! Selects the correct backend at comptime:
//!   Linux  → epoll (this file's EpollPoller, via std.os.linux)
//!   Darwin/BSD → kqueue (kqueue.zig)
//!   Other  → compile-error (unreachable for supported targets)
//!
//! The `Poller` type and `eventFromRaw` function are re-exported so callers
//! (worker.zig, tests) always reference `poller_mod.Poller` and
//! `poller_mod.eventFromRaw` without caring which backend is active.
//!
//! The `Event` type is the same on all platforms:
//!   { data: u64, readable: bool, writable: bool, hup: bool }
//!
//! Syscall path for epoll: all epoll calls go through `std.os.linux` (raw
//! syscall wrappers) because `std.posix` does not expose epoll in Zig 0.16.
//!
//! Usage (all platforms):
//!   var p = try Poller.init();
//!   defer p.deinit();
//!   try p.add(fd, slot_index, true, false);
//!   var evs: [64]Poller.NativeEvent = undefined;
//!   const n = p.wait(evs[0..], 100);
//!   for (evs[0..n]) |raw| {
//!       const ev = eventFromRaw(raw);
//!       // ev.data == slot_index, ev.readable, ev.writable, ev.hup
//!   }

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// Platform selection
// ---------------------------------------------------------------------------

const is_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
    .freebsd, .dragonfly, .netbsd, .openbsd => true,
    else => false,
};

// ---------------------------------------------------------------------------
// Public types (defined on all supported platforms)
// ---------------------------------------------------------------------------

/// A decoded event — same shape across epoll and kqueue backends.
pub const Event = struct {
    /// The u64 value registered with add/mod (e.g. connection slot index).
    data: u64,
    readable: bool,
    writable: bool,
    /// True when HUP, RDHUP, or ERR is set — peer closed or error.
    hup: bool,
};

// ---------------------------------------------------------------------------
// Backend selection
// ---------------------------------------------------------------------------

const kqueue_mod = if (is_bsd) @import("kqueue.zig") else void;

// ---------------------------------------------------------------------------
// eventFromRaw — dispatch to the right backend decoder
// ---------------------------------------------------------------------------

/// Decode a raw `NativeEvent` into an `Event`.
pub fn eventFromRaw(raw: Poller.NativeEvent) Event {
    if (builtin.os.tag == .linux) {
        return .{
            .data = raw.data.u64,
            .readable = (raw.events & linux.EPOLL.IN) != 0,
            .writable = (raw.events & linux.EPOLL.OUT) != 0,
            .hup = (raw.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR)) != 0,
        };
    } else if (is_bsd) {
        // kqueue_mod.eventFromRaw returns a structurally identical Event.
        // Convert field by field to produce this module's Event type.
        const kev = kqueue_mod.eventFromRaw(raw);
        return .{
            .data = kev.data,
            .readable = kev.readable,
            .writable = kev.writable,
            .hup = kev.hup,
        };
    } else {
        unreachable;
    }
}

// ---------------------------------------------------------------------------
// Poller — platform-dispatched struct
// ---------------------------------------------------------------------------

pub const Poller = if (builtin.os.tag == .linux) EpollPoller else if (is_bsd) kqueue_mod.Poller else void;

// ---------------------------------------------------------------------------
// EpollPoller (Linux only)
// ---------------------------------------------------------------------------

const EpollPoller = struct {
    epfd: i32,

    /// The native event type for this backend.  The worker allocates its event
    /// buffer as `[N]Poller.NativeEvent` so the kqueue backend can swap
    /// this to `std.posix.Kevent` without touching the worker.
    pub const NativeEvent = linux.epoll_event;

    /// Create an epoll instance via `epoll_create1(0)`.  Level-triggered (no
    /// EPOLLET).
    pub fn init() !EpollPoller {
        const rc = linux.epoll_create1(0);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
        return .{ .epfd = @intCast(rc) };
    }

    /// Close the epoll file descriptor.
    pub fn deinit(self: *EpollPoller) void {
        _ = linux.close(@intCast(self.epfd));
        self.epfd = -1;
    }

    /// Register `fd`.  `data` is stored in `epoll_event.data.u64`
    /// (use the connection slot index here).
    pub fn add(self: *EpollPoller, fd: i32, data: u64, read: bool, write: bool) !void {
        var ev = makeEvent(data, read, write);
        const rc = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
    }

    /// Modify the interest set for an already-registered `fd`.
    pub fn mod(self: *EpollPoller, fd: i32, data: u64, read: bool, write: bool) !void {
        var ev = makeEvent(data, read, write);
        const rc = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
    }

    /// Deregister `fd`.  Errors are silently ignored (fd may already be closed).
    pub fn del(self: *EpollPoller, fd: i32) void {
        // Linux ≥ 2.6.9 ignores the event pointer for EPOLL_CTL_DEL.
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Block until events are ready or `timeout_ms` elapses.
    /// Returns the number of events written into `events` (0..events.len).
    /// Never returns a sentinel: EINTR and other errors are mapped to 0 so the
    /// caller's `for (events[0..n])` loop is always in-bounds.
    pub fn wait(self: *EpollPoller, events: []NativeEvent, timeout_ms: i32) usize {
        const rc = linux.epoll_wait(self.epfd, events.ptr, @intCast(events.len), timeout_ms);
        const e = linux.errno(rc);
        switch (e) {
            .SUCCESS => return @intCast(rc),
            .INTR => return 0, // interrupted by signal — benign, loop will retry
            else => {
                std.log.warn("epoll_wait: unexpected errno {}", .{e});
                return 0;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Internal helpers (epoll only)
// ---------------------------------------------------------------------------

fn makeEvent(data: u64, read: bool, write: bool) linux.epoll_event {
    // Always subscribe to error / hangup conditions.
    var events: u32 = linux.EPOLL.RDHUP | linux.EPOLL.ERR | linux.EPOLL.HUP;
    if (read) events |= linux.EPOLL.IN;
    if (write) events |= linux.EPOLL.OUT;
    // Level-triggered (no EPOLLET) for v1.
    return .{ .events = events, .data = .{ .u64 = data } };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "poller: eventfd smoke" {
    // Self-skip on non-Linux: epoll doesn't exist; test infrastructure runs
    // this in Docker on Linux.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var p = try Poller.init();
    defer p.deinit();

    // Create an eventfd with initial count 0.
    const efd_rc = linux.eventfd(0, 0);
    const efd_e = linux.errno(efd_rc);
    if (efd_e != .SUCCESS) return std.posix.unexpectedErrno(efd_e);
    const efd: i32 = @intCast(efd_rc);
    defer _ = linux.close(@intCast(efd));

    const slot: u64 = 42;
    try p.add(efd, slot, true, false);

    // Write 8 bytes (counter increment = 1) to make the eventfd readable.
    const val: u64 = 1;
    const wrc = linux.write(@intCast(efd), @ptrCast(&val), 8);
    const we = linux.errno(wrc);
    if (we != .SUCCESS) return std.posix.unexpectedErrno(we);
    try std.testing.expectEqual(@as(usize, 8), wrc);

    // wait — expect exactly 1 event.
    var evs: [8]Poller.NativeEvent = undefined;
    const n = p.wait(evs[0..], 200);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Decode and verify.
    const ev = eventFromRaw(evs[0]);
    try std.testing.expectEqual(slot, ev.data);
    try std.testing.expect(ev.readable);
    try std.testing.expect(!ev.hup);
}
