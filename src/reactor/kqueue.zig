//! Poller — kqueue wrapper for macOS/BSD.
//!
//! Mirrors the epoll Poller interface in poller.zig exactly so the worker is
//! transparent to the backend.  Platform selection is done in poller.zig.
//!
//! kqueue vs epoll semantic difference: kqueue returns READ and WRITE readiness
//! as *separate* kevents (one per filter), whereas epoll combines them in a
//! single event bitmask.  The worker calls `conn.step` per decoded Event; since
//! conn.step is naturally idempotent for a given readiness state, receiving two
//! Events for the same fd in one batch (one readable, one writable) simply
//! means step() runs twice — the second call will immediately return WouldBlock
//! or be a no-op.  This is correct and safe.
//!
//! Level-triggered: kqueue is level-triggered by default (EV_CLEAR is NOT set),
//! matching epoll's default mode.
//!
//! Usage (Darwin/BSD only):
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

// ---------------------------------------------------------------------------
// Platform guard
// ---------------------------------------------------------------------------

// kqueue exists on Darwin (macOS, iOS, …) and the BSDs.
const is_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit,
    .freebsd, .dragonfly, .netbsd, .openbsd => true,
    else => false,
};
comptime {
    if (!is_bsd) @compileError("kqueue.zig is only for macOS/BSD targets");
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A decoded kqueue event (same shape as poller.zig's Event).
pub const Event = struct {
    /// The u64 value registered with add/mod (e.g. connection slot index).
    data: u64,
    readable: bool,
    writable: bool,
    /// True when EOF/ERR is signalled — peer closed or error.
    hup: bool,
};

// ---------------------------------------------------------------------------
// Helper: translate a raw Kevent to Event
// ---------------------------------------------------------------------------

/// Decode a raw `NativeEvent` (std.posix.Kevent) into an `Event`.
pub fn eventFromRaw(raw: Poller.NativeEvent) Event {
    const is_read = raw.filter == std.c.EVFILT.READ;
    const is_write = raw.filter == std.c.EVFILT.WRITE;
    const is_eof = (raw.flags & std.c.EV.EOF) != 0;
    const is_err = (raw.flags & std.c.EV.ERROR) != 0;
    return .{
        .data = @intCast(raw.udata),
        .readable = is_read,
        .writable = is_write,
        .hup = is_eof or is_err,
    };
}

// ---------------------------------------------------------------------------
// Poller
// ---------------------------------------------------------------------------

pub const Poller = struct {
    kqfd: i32,

    /// The native event type for this backend.
    pub const NativeEvent = std.posix.Kevent;

    /// Create a kqueue instance via `kqueue(2)`.
    pub fn init() !Poller {
        const rc = std.c.kqueue();
        if (rc < 0) {
            const e = std.posix.errno(rc);
            return std.posix.unexpectedErrno(e);
        }
        return .{ .kqfd = rc };
    }

    /// Close the kqueue file descriptor.
    pub fn deinit(self: *Poller) void {
        _ = std.c.close(self.kqfd);
        self.kqfd = -1;
    }

    /// Register `fd` with interest in read and/or write.
    /// `data` is packed into `udata` (slot index).
    pub fn add(self: *Poller, fd: i32, data: u64, read: bool, write: bool) !void {
        var changes: [2]NativeEvent = undefined;
        var n: usize = 0;
        if (read) {
            changes[n] = makeKevent(@intCast(fd), std.c.EVFILT.READ, std.c.EV.ADD | std.c.EV.ENABLE, data);
            n += 1;
        }
        if (write) {
            changes[n] = makeKevent(@intCast(fd), std.c.EVFILT.WRITE, std.c.EV.ADD | std.c.EV.ENABLE, data);
            n += 1;
        }
        if (n == 0) return; // nothing to do
        try callKevent(self.kqfd, changes[0..n], &.{}, null);
    }

    /// Modify the interest set for an already-registered `fd`.
    /// Enables the requested filters; disables the others.
    pub fn mod(self: *Poller, fd: i32, data: u64, read: bool, write: bool) !void {
        // Always update both filters — enable the requested ones, disable the
        // other.  Using ADD+ENABLE / ADD+DISABLE is idempotent and safe whether
        // the filter was previously registered or not.
        const changes = [2]NativeEvent{
            makeKevent(
                @intCast(fd),
                std.c.EVFILT.READ,
                if (read) std.c.EV.ADD | std.c.EV.ENABLE else std.c.EV.ADD | std.c.EV.DISABLE,
                data,
            ),
            makeKevent(
                @intCast(fd),
                std.c.EVFILT.WRITE,
                if (write) std.c.EV.ADD | std.c.EV.ENABLE else std.c.EV.ADD | std.c.EV.DISABLE,
                data,
            ),
        };
        try callKevent(self.kqfd, &changes, &.{}, null);
    }

    /// Deregister `fd` from both filters.  Errors are silently ignored.
    pub fn del(self: *Poller, fd: i32) void {
        const changes = [2]NativeEvent{
            makeKevent(@intCast(fd), std.c.EVFILT.READ, std.c.EV.DELETE, 0),
            makeKevent(@intCast(fd), std.c.EVFILT.WRITE, std.c.EV.DELETE, 0),
        };
        // Ignore errors: fd may already be closed / never registered.
        _ = std.c.kevent(self.kqfd, &changes, 2, @constCast(&[0]NativeEvent{}), 0, null);
    }

    /// Block until events are ready or `timeout_ms` elapses.
    /// Returns the number of events written into `events` (0..events.len).
    pub fn wait(self: *Poller, events: []NativeEvent, timeout_ms: i32) usize {
        const ts: std.c.timespec = if (timeout_ms < 0) .{
            // Negative: block indefinitely (pass null to kevent instead).
            .sec = 0,
            .nsec = 0,
        } else .{
            .sec = @intCast(@divTrunc(timeout_ms, 1000)),
            .nsec = @intCast(@mod(timeout_ms, 1000) * std.time.ns_per_ms),
        };
        const ts_ptr: ?*const std.c.timespec = if (timeout_ms < 0) null else &ts;

        const rc = std.c.kevent(
            self.kqfd,
            @constCast(&[0]NativeEvent{}), // no changes
            0,
            events.ptr,
            @intCast(events.len),
            ts_ptr,
        );
        if (rc < 0) {
            const e = std.posix.errno(rc);
            if (e == .INTR) return 0;
            std.log.warn("kevent wait: unexpected errno {}", .{e});
            return 0;
        }
        return @intCast(rc);
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn makeKevent(ident: usize, filter: i16, flags: u16, udata: u64) Poller.NativeEvent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = @intCast(udata),
    };
}

/// Call kevent() for a changelist and return an error on failure.
fn callKevent(
    kqfd: i32,
    changes: []const Poller.NativeEvent,
    eventlist: []Poller.NativeEvent,
    timeout: ?*const std.c.timespec,
) !void {
    const rc = std.c.kevent(
        kqfd,
        changes.ptr,
        @intCast(changes.len),
        eventlist.ptr,
        @intCast(eventlist.len),
        timeout,
    );
    if (rc < 0) {
        const e = std.posix.errno(rc);
        return std.posix.unexpectedErrno(e);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "kqueue poller: self-pipe smoke" {
    // This file is only compiled on BSD/Darwin so no skip guard needed.
    const testing = std.testing;

    var p = try Poller.init();
    defer p.deinit();

    // Create a self-pipe.
    var fds: [2]std.c.fd_t = undefined;
    const pr = std.c.pipe(&fds);
    try testing.expectEqual(@as(c_int, 0), pr);
    const rd: i32 = fds[0];
    const wr: i32 = fds[1];
    defer _ = std.c.close(rd);
    defer _ = std.c.close(wr);

    const slot: u64 = 42;
    try p.add(rd, slot, true, false);

    // Write 1 byte to make the read end readable.
    const byte: u8 = 1;
    const wrc = std.c.write(wr, @ptrCast(&byte), 1);
    try testing.expectEqual(@as(isize, 1), wrc);

    // wait — expect exactly 1 event.
    var evs: [8]Poller.NativeEvent = undefined;
    const n = p.wait(evs[0..], 200);
    try testing.expectEqual(@as(usize, 1), n);

    // Decode and verify.
    const ev = eventFromRaw(evs[0]);
    try testing.expectEqual(slot, ev.data);
    try testing.expect(ev.readable);
    try testing.expect(!ev.hup);
}
