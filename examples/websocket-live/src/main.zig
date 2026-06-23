//! websocket-live — a WebSocket echo endpoint on zax, running on BOTH the threaded
//! (app.serve) and evented (app.serveEvented) backends with the same handler.
//! on_message receives whole reassembled messages; ping/pong + close are automatic.
//!
//!   zig build run            # threaded backend, ws://127.0.0.1:8085/ws
//!   zig build run -- evented # evented (reactor) backend

const std = @import("std");
const zax = @import("zax");

/// Global message counter shared across all connections (app state). Lock-free:
/// a plain atomic counter needs no lock.
const Counter = struct {
    n: std.atomic.Value(usize) = .init(0),
};

const Api = zax.App(*Counter);

fn onMessage(conn: *zax.WsConn, frame: zax.WsFrame) void {
    const counter = conn.state(*Counter);
    _ = counter.n.fetchAdd(1, .monotonic);
    conn.send(frame.opcode, frame.payload) catch {}; // echo the whole message back
}

fn ws(sock: zax.WebSocket) zax.Response {
    return sock.onUpgrade(.{ .on_message = onMessage });
}

fn stats(s: zax.State(*Counter), a: zax.Alloc) !zax.Response {
    const n = s.value.n.load(.monotonic);
    const body = try std.fmt.allocPrint(a.value, "messages echoed: {d}\n", .{n});
    return zax.Response.text(body);
}

fn home() zax.Response {
    return zax.Response.text("connect a WebSocket to /ws (it echoes messages)\n");
}

pub fn main(init: std.process.Init) !void {
    var counter = Counter{};
    var app = try Api.init(init.gpa, &counter, .{});
    defer app.deinit();
    try app.get("/", home);
    try app.get("/stats", stats);
    try app.get("/ws", ws);

    // Parse the optional "evented" arg via the iterator API (Zig 0.16 Juicy Main).
    var use_evented = false;
    var it = init.minimal.args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "evented")) use_evented = true;
    }

    if (use_evented) {
        std.debug.print("websocket-live (evented) on ws://127.0.0.1:8085/ws\n", .{});
        try app.serveEvented(init.io, .{ .ip4 = .loopback(8085) }, .{});
    } else {
        std.debug.print("websocket-live (threaded) on ws://127.0.0.1:8085/ws\n", .{});
        try app.serve(init.io, .{ .ip4 = .loopback(8085) });
    }
}

const testing = std.testing;

test "home handler" {
    try testing.expect(std.mem.indexOf(u8, home().body, "WebSocket") != null);
}
