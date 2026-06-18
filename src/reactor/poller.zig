//! Poller — thin epoll wrapper (Linux only).
//!
//! On non-Linux platforms the types are defined but all function bodies are
//! `unreachable`; they are never constructed off-Linux so this is safe.  The
//! library therefore compiles on macOS without error and the single test block
//! self-skips off-Linux via `return error.SkipZigTest`.
//!
//! Syscall path: all epoll calls go through `std.os.linux` (raw syscall
//! wrappers) because `std.posix` does not expose epoll in Zig 0.16.
//!
//! Usage (Linux only):
//!   var p = try Poller.init();
//!   defer p.deinit();
//!   try p.add(fd, slot_index, true, false);
//!   var evs: [64]std.os.linux.epoll_event = undefined;
//!   const n = p.wait(evs[0..], 100);
//!   for (evs[0..n]) |raw| {
//!       const ev = eventFromRaw(raw);
//!       // ev.data == slot_index, ev.readable, ev.writable, ev.hup
//!   }

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// Public types (defined on all platforms so the library compiles everywhere)
// ---------------------------------------------------------------------------

/// A decoded epoll event.
pub const Event = struct {
    /// The u64 value registered with add/mod (e.g. connection slot index).
    data: u64,
    readable: bool,
    writable: bool,
    /// True when HUP, RDHUP, or ERR is set — peer closed or error.
    hup: bool,
};

// ---------------------------------------------------------------------------
// Helper: translate a raw epoll_event to Event
// ---------------------------------------------------------------------------

/// Decode a raw `epoll_event` into an `Event`.
/// Only meaningful on Linux; bodies guarded — calling off-Linux is `unreachable`.
pub fn eventFromRaw(raw: linux.epoll_event) Event {
    if (builtin.os.tag != .linux) unreachable;
    return .{
        .data = raw.data.u64,
        .readable = (raw.events & linux.EPOLL.IN) != 0,
        .writable = (raw.events & linux.EPOLL.OUT) != 0,
        .hup = (raw.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR)) != 0,
    };
}

// ---------------------------------------------------------------------------
// Poller
// ---------------------------------------------------------------------------

pub const Poller = struct {
    epfd: i32,

    /// Create an epoll instance via `epoll_create1(0)`.  Level-triggered for v1
    /// (no `EPOLLET`).
    pub fn init() !Poller {
        if (builtin.os.tag != .linux) unreachable;
        const rc = linux.epoll_create1(0);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
        return .{ .epfd = @intCast(rc) };
    }

    /// Close the epoll file descriptor.
    pub fn deinit(self: *Poller) void {
        if (builtin.os.tag != .linux) unreachable;
        _ = linux.close(@intCast(self.epfd));
        self.epfd = -1;
    }

    /// Register `fd`.  `data` is stored in `epoll_event.data.u64`
    /// (use the connection slot index here).
    pub fn add(self: *Poller, fd: i32, data: u64, read: bool, write: bool) !void {
        if (builtin.os.tag != .linux) unreachable;
        var ev = makeEvent(data, read, write);
        const rc = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
    }

    /// Modify the interest set for an already-registered `fd`.
    pub fn mod(self: *Poller, fd: i32, data: u64, read: bool, write: bool) !void {
        if (builtin.os.tag != .linux) unreachable;
        var ev = makeEvent(data, read, write);
        const rc = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return std.posix.unexpectedErrno(e);
    }

    /// Deregister `fd`.  Errors are silently ignored (fd may already be closed).
    pub fn del(self: *Poller, fd: i32) void {
        if (builtin.os.tag != .linux) unreachable;
        // Linux ≥ 2.6.9 ignores the event pointer for EPOLL_CTL_DEL.
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Block until events are ready or `timeout_ms` elapses.
    /// Returns the number of events written into `events` (0..events.len).
    /// Never returns a sentinel: EINTR and other errors are mapped to 0 so the
    /// caller's `for (events[0..n])` loop is always in-bounds.
    pub fn wait(self: *Poller, events: []linux.epoll_event, timeout_ms: i32) usize {
        if (builtin.os.tag != .linux) unreachable;
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
// Internal helpers
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
    var evs: [8]linux.epoll_event = undefined;
    const n = p.wait(evs[0..], 200);
    try std.testing.expectEqual(@as(usize, 1), n);

    // Decode and verify.
    const ev = eventFromRaw(evs[0]);
    try std.testing.expectEqual(slot, ev.data);
    try std.testing.expect(ev.readable);
    try std.testing.expect(!ev.hup);
}
