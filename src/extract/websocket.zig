//! `WebSocket` extractor (RFC 6455 handshake). Used in a normal handler; its
//! `onUpgrade(cb)` returns a Response that the threaded server turns into a 101 +
//! socket takeover (see `server.zig` handleConn). Validation only here — framing
//! lives in `ws.zig`, takeover in the server.

const std = @import("std");
const ws = @import("../ws.zig");
const Response = @import("../http/response.zig").Response;
const classify = @import("../error.zig").classify;

/// RFC 6455 upgrade handshake extractor. `fromContext` validates the request;
/// `onUpgrade` attaches the takeover callback to a 101 Response.
pub const WebSocket = struct {
    /// Sec-WebSocket-Key (borrows request memory; consumed only in `onUpgrade`).
    key: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{NotWebSocketUpgrade}!@This() {
        const up = ctx.req.header("upgrade") orelse return error.NotWebSocketUpgrade;
        if (std.ascii.indexOfIgnoreCase(up, "websocket") == null) return error.NotWebSocketUpgrade;

        const conn = ctx.req.header("connection") orelse return error.NotWebSocketUpgrade;
        if (std.ascii.indexOfIgnoreCase(conn, "upgrade") == null) return error.NotWebSocketUpgrade;

        const ver = ctx.req.header("sec-websocket-version") orelse return error.NotWebSocketUpgrade;
        if (!std.mem.eql(u8, ver, "13")) return error.NotWebSocketUpgrade;

        const key = ctx.req.header("sec-websocket-key") orelse return error.NotWebSocketUpgrade;
        return .{ .key = key };
    }

    pub fn onUpgrade(self: @This(), cb: ws.Handler) Response {
        var accept: [28]u8 = undefined;
        _ = ws.acceptKey(self.key, &accept);
        var r = Response.fromStatus(.switching_protocols);
        r.upgrade = .{ .accept = accept, .cb = cb };
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

fn ctxWith(req: *const FakeReq) struct { req: *const FakeReq } {
    return .{ .req = req };
}

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
    const dummy = struct {
        fn run(_: *ws.WsConn) void {}
    }.run;
    const resp = w.onUpgrade(dummy);
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
