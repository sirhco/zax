//! `WebSocket` extractor (RFC 6455 handshake). Used in a normal handler; its
//! `onUpgrade(cb)` returns a Response that the threaded server turns into a 101 +
//! socket takeover (see `server.zig` handleConn). Validation only here — framing
//! lives in `ws.zig`, takeover in the server.

const std = @import("std");
const ws = @import("../ws.zig");
const Response = @import("../http/response.zig").Response;
const classify = @import("../error.zig").classify;

/// True if `list` (a comma-separated HTTP header list) contains `token`,
/// case-insensitively, after trimming surrounding whitespace from each element.
fn hasToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

/// RFC 6455 upgrade handshake extractor. `fromContext` validates the request;
/// `onUpgrade` attaches the takeover callback to a 101 Response.
pub const WebSocket = struct {
    /// Sec-WebSocket-Key (borrows request memory; consumed only in `onUpgrade`).
    key: []const u8,
    /// App-state pointer captured from `ctx.state`; forwarded into `ws.Upgrade`.
    state_ptr: *anyopaque,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{NotWebSocketUpgrade}!@This() {
        const up = ctx.req.header("upgrade") orelse return error.NotWebSocketUpgrade;
        if (!hasToken(up, "websocket")) return error.NotWebSocketUpgrade;

        const conn = ctx.req.header("connection") orelse return error.NotWebSocketUpgrade;
        if (!hasToken(conn, "upgrade")) return error.NotWebSocketUpgrade;

        const ver = ctx.req.header("sec-websocket-version") orelse return error.NotWebSocketUpgrade;
        if (!std.mem.eql(u8, ver, "13")) return error.NotWebSocketUpgrade;

        const key = ctx.req.header("sec-websocket-key") orelse return error.NotWebSocketUpgrade;
        return .{ .key = key, .state_ptr = @ptrCast(@constCast(ctx.state)) };
    }

    pub fn onUpgrade(self: @This(), handler: ws.Handler) Response {
        var accept: [28]u8 = undefined;
        _ = ws.acceptKey(self.key, &accept);
        var r = Response.fromStatus(.switching_protocols);
        r.upgrade = .{ .accept = accept, .handler = handler, .state_ptr = self.state_ptr };
        return r;
    }
};

const testing = std.testing;

// Minimal fake request exposing the case-insensitive `header` lookup the
// extractor uses, so fromContext can be tested without a full server.
const FakeReq = struct {
    pairs: []const [2][]const u8,
    fn header(self: *const FakeReq, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
        return null;
    }
};

fn ctxWith(req: *const FakeReq) struct { req: *const FakeReq, state: *u8 } {
    return .{ .req = req, .state = &dummy_state };
}
var dummy_state: u8 = 0;

const valid_pairs = [_][2][]const u8{
    .{ "Upgrade", "websocket" },
    .{ "Connection", "Upgrade" },
    .{ "Sec-WebSocket-Version", "13" },
    .{ "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==" },
};

test "WebSocket.fromContext accepts a valid handshake" {
    const req = FakeReq{ .pairs = &valid_pairs };
    const w = try WebSocket.fromContext(ctxWith(&req));
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", w.key);
}

test "WebSocket.fromContext rejects each missing handshake header" {
    // Drop one header at a time; each omission must reject.
    inline for (.{ "Upgrade", "Connection", "Sec-WebSocket-Version", "Sec-WebSocket-Key" }) |drop| {
        var pairs: [3][2][]const u8 = undefined;
        var i: usize = 0;
        inline for (valid_pairs) |p| {
            if (!std.mem.eql(u8, p[0], drop)) {
                pairs[i] = p;
                i += 1;
            }
        }
        const req = FakeReq{ .pairs = &pairs };
        try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&req)));
    }
}

test "WebSocket.fromContext rejects a non-13 version" {
    const pairs = [_][2][]const u8{
        .{ "Upgrade", "websocket" }, .{ "Connection", "Upgrade" },
        .{ "Sec-WebSocket-Version", "8" }, .{ "Sec-WebSocket-Key", "x" },
    };
    const req = FakeReq{ .pairs = &pairs };
    try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&req)));
}

test "WebSocket.onUpgrade builds a 101 with the RFC accept value" {
    const req = FakeReq{ .pairs = &valid_pairs };
    const w = try WebSocket.fromContext(ctxWith(&req));
    const H = struct {
        fn onMsg(conn: *ws.WsConn, f: ws.Frame) void { _ = conn; _ = f; }
    };
    const resp = w.onUpgrade(.{ .on_message = H.onMsg });
    try testing.expectEqual(@import("../http/response.zig").Status.switching_protocols, resp.status);
    try testing.expect(resp.upgrade != null);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &resp.upgrade.?.accept);
}

test "classify maps NotWebSocketUpgrade to 426" {
    try testing.expectEqual(
        @import("../http/response.zig").Status.upgrade_required,
        classify(error.NotWebSocketUpgrade).status,
    );
}

test "WebSocket.fromContext rejects an Upgrade header without the websocket token" {
    const pairs = [_][2][]const u8{
        .{ "Upgrade", "not-websocket" }, .{ "Connection", "Upgrade" },
        .{ "Sec-WebSocket-Version", "13" }, .{ "Sec-WebSocket-Key", "x" },
    };
    const req = FakeReq{ .pairs = &pairs };
    try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&req)));
}

test "WebSocket.fromContext accepts a Connection list and rejects a non-token substring" {
    // Real browsers send e.g. "Connection: keep-alive, Upgrade" -> accepted.
    const ok_pairs = [_][2][]const u8{
        .{ "Upgrade", "websocket" }, .{ "Connection", "keep-alive, Upgrade" },
        .{ "Sec-WebSocket-Version", "13" }, .{ "Sec-WebSocket-Key", "x" },
    };
    const ok_req = FakeReq{ .pairs = &ok_pairs };
    _ = try WebSocket.fromContext(ctxWith(&ok_req));

    // "upgrade-insecure-requests" contains "upgrade" as a substring but is not the token -> rejected.
    const bad_pairs = [_][2][]const u8{
        .{ "Upgrade", "websocket" }, .{ "Connection", "upgrade-insecure-requests" },
        .{ "Sec-WebSocket-Version", "13" }, .{ "Sec-WebSocket-Key", "x" },
    };
    const bad_req = FakeReq{ .pairs = &bad_pairs };
    try testing.expectError(error.NotWebSocketUpgrade, WebSocket.fromContext(ctxWith(&bad_req)));
}
