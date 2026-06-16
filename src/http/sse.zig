//! Server-Sent Events wire format. `formatEvent`/`formatComment` write the bytes
//! (no flush, unit-testable); `Sse` wraps the connection writer and flushes after
//! each event so events reach the client in real time.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8 = "",
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// Write one SSE event block (no flush): event/id/retry lines when set, one
/// `data:` line per `\n`-split line of `e.data`, then a blank terminator.
pub fn formatEvent(w: *Writer, e: Event) Writer.Error!void {
    if (e.event) |x| try w.print("event: {s}\n", .{x});
    if (e.id) |x| try w.print("id: {s}\n", .{x});
    if (e.retry) |x| try w.print("retry: {d}\n", .{x});
    var it = std.mem.splitScalar(u8, e.data, '\n');
    while (it.next()) |line| try w.print("data: {s}\n", .{line});
    try w.writeByte('\n');
}

/// Write an SSE comment line (`: <text>`) — used for keep-alive (no flush).
pub fn formatComment(w: *Writer, text: []const u8) Writer.Error!void {
    try w.print(": {s}\n", .{text});
}

/// Event writer over the connection writer. Each method flushes (real-time).
pub const Sse = struct {
    w: *Writer,

    pub fn send(self: *Sse, e: Event) Writer.Error!void {
        try formatEvent(self.w, e);
        try self.w.flush();
    }
    pub fn data(self: *Sse, s: []const u8) Writer.Error!void {
        return self.send(.{ .data = s });
    }
    pub fn comment(self: *Sse, text: []const u8) Writer.Error!void {
        try formatComment(self.w, text);
        try self.w.flush();
    }
};

const testing = std.testing;

test "formatEvent emits all fields and splits multi-line data" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try formatEvent(&w, .{ .event = "tick", .id = "5", .retry = 1000, .data = "a\nb" });
    try testing.expectEqualStrings("event: tick\nid: 5\nretry: 1000\ndata: a\ndata: b\n\n", w.buffered());
}

test "formatEvent minimal data-only" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try formatEvent(&w, .{ .data = "x" });
    try testing.expectEqualStrings("data: x\n\n", w.buffered());
}

test "formatComment writes a comment line" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try formatComment(&w, "ping");
    try testing.expectEqualStrings(": ping\n", w.buffered());
}
