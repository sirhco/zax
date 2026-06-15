//! `Forwarded` — connection info derived from reverse-proxy headers. Zig 0.16
//! std has no server-side TLS, so the production HTTPS story is to terminate TLS
//! at a proxy (nginx/Caddy/Cloudflare) that forwards plaintext to Zax and sets
//! `X-Forwarded-Proto/Host/For`. This extractor surfaces those — but ONLY when
//! `Options.trust_forwarded` is enabled (the flag rides on the request context).
//! When untrusted, it ignores the forwarded headers and reports the direct
//! connection so a client cannot spoof `https`.
//!
//! All fields are borrowed slices into the request buffer (zero-copy).

const std = @import("std");

pub const Forwarded = struct {
    /// "https" or "http".
    scheme: []const u8,
    /// Effective host (forwarded host, else the `Host` header).
    host: []const u8,
    /// Originating client IP (first hop of `X-Forwarded-For`), empty if unknown.
    client_ip: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        const req = ctx.req;
        if (ctx.trust_forwarded) {
            return .{
                .scheme = req.header("x-forwarded-proto") orelse "http",
                .host = req.header("x-forwarded-host") orelse (req.header("host") orelse ""),
                .client_ip = firstHop(req.header("x-forwarded-for")),
            };
        }
        return .{
            .scheme = "http",
            .host = req.header("host") orelse "",
            .client_ip = "",
        };
    }

    pub fn isHttps(self: @This()) bool {
        return std.ascii.eqlIgnoreCase(self.scheme, "https");
    }
};

/// First hop of a comma-separated `X-Forwarded-For` value (the original client).
fn firstHop(xff: ?[]const u8) []const u8 {
    const v = xff orelse return "";
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
    return std.mem.trim(u8, v[0..comma], " \t");
}

// ----------------------------------------------------------------------------
const testing = std.testing;
const Request = @import("../http/request.zig").Request;
const Header = @import("../http/request.zig").Header;

fn ctxWith(trust: bool, headers: []const Header) struct { req: *const Request, trust_forwarded: bool } {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .version_minor = 1,
        .headers = headers,
        .body = "",
    };
    return .{ .req = &S.req, .trust_forwarded = trust };
}

test "trusted: reads forwarded proto/host/for (first hop)" {
    const f = try Forwarded.fromContext(ctxWith(true, &.{
        .{ .name = "X-Forwarded-Proto", .value = "https" },
        .{ .name = "X-Forwarded-Host", .value = "api.example.com" },
        .{ .name = "X-Forwarded-For", .value = "203.0.113.7, 10.0.0.1" },
        .{ .name = "Host", .value = "backend:8080" },
    }));
    try testing.expectEqualStrings("https", f.scheme);
    try testing.expect(f.isHttps());
    try testing.expectEqualStrings("api.example.com", f.host);
    try testing.expectEqualStrings("203.0.113.7", f.client_ip);
}

test "untrusted: ignores forwarded headers, falls back to direct" {
    const f = try Forwarded.fromContext(ctxWith(false, &.{
        .{ .name = "X-Forwarded-Proto", .value = "https" },
        .{ .name = "X-Forwarded-For", .value = "203.0.113.7" },
        .{ .name = "Host", .value = "backend:8080" },
    }));
    try testing.expectEqualStrings("http", f.scheme);
    try testing.expect(!f.isHttps());
    try testing.expectEqualStrings("backend:8080", f.host);
    try testing.expectEqualStrings("", f.client_ip);
}

test "trusted but headers absent: sensible defaults" {
    const f = try Forwarded.fromContext(ctxWith(true, &.{
        .{ .name = "Host", .value = "h:80" },
    }));
    try testing.expectEqualStrings("http", f.scheme);
    try testing.expectEqualStrings("h:80", f.host);
    try testing.expectEqualStrings("", f.client_ip);
}
