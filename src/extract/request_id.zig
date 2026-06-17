//! `RequestId` — inject the per-request id into a handler. The server computes it
//! (a validated incoming `X-Request-Id` or a generated counter value) only when
//! `Options.request_id` is enabled; otherwise `value` is the empty string.

const std = @import("std");

pub const RequestId = struct {
    value: []const u8,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!@This() {
        return .{ .value = ctx.request_id };
    }
};

const testing = std.testing;

test "RequestId reads request_id from context" {
    const rid = try RequestId.fromContext(.{ .request_id = "abc-123" });
    try testing.expectEqualStrings("abc-123", rid.value);
}
