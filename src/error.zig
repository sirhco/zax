//! Error model: a canonical handler-facing error set and a central mapping from
//! any error value to an HTTP status + short reason. Zig errors are payload-less
//! global identities, so one table classifies both the canonical set and the
//! extractor error tags unambiguously.

const std = @import("std");
const Status = @import("http/response.zig").Status;

pub const ErrorInfo = struct {
    status: Status,
    reason: []const u8,
};

/// Canonical errors a handler can `return` to produce a specific status, e.g.
/// `const u = store.get(id) orelse return error.NotFound;`
pub const Error = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    Conflict,
    UnprocessableEntity,
    TooManyRequests,
    Internal,
    NotImplemented,
    ServiceUnavailable,
    Gone,
    UnsupportedMediaType,
    NotAcceptable,
    PreconditionFailed,
    BadGateway,
    GatewayTimeout,
    InvalidMultipart,
    TooManyParts,
};

/// Map any error to a status + reason. Covers the canonical `Error` set and the
/// extractor error tags; everything else is a 500.
pub fn classify(e: anyerror) ErrorInfo {
    return switch (e) {
        error.BadRequest => .{ .status = .bad_request, .reason = "bad request" },
        error.Unauthorized => .{ .status = .unauthorized, .reason = "unauthorized" },
        error.Forbidden => .{ .status = .forbidden, .reason = "forbidden" },
        error.NotFound => .{ .status = .not_found, .reason = "not found" },
        error.MethodNotAllowed => .{ .status = .method_not_allowed, .reason = "method not allowed" },
        error.Conflict => .{ .status = .conflict, .reason = "conflict" },
        error.UnprocessableEntity => .{ .status = .unprocessable_entity, .reason = "unprocessable entity" },
        error.TooManyRequests => .{ .status = .too_many_requests, .reason = "too many requests" },
        error.Internal => .{ .status = .internal_server_error, .reason = "internal server error" },
        error.NotImplemented => .{ .status = .not_implemented, .reason = "not implemented" },
        error.ServiceUnavailable => .{ .status = .service_unavailable, .reason = "service unavailable" },
        error.PayloadTooLarge => .{ .status = .payload_too_large, .reason = "payload too large" },
        error.Gone => .{ .status = .gone, .reason = "gone" },
        error.UnsupportedMediaType => .{ .status = .unsupported_media_type, .reason = "unsupported media type" },
        error.NotAcceptable => .{ .status = .not_acceptable, .reason = "not acceptable" },
        error.PreconditionFailed => .{ .status = .precondition_failed, .reason = "precondition failed" },
        error.BadGateway => .{ .status = .bad_gateway, .reason = "bad gateway" },
        error.GatewayTimeout => .{ .status = .gateway_timeout, .reason = "gateway timeout" },

        error.InvalidMultipart => .{ .status = .bad_request, .reason = "invalid multipart body" },
        error.TooManyParts => .{ .status = .payload_too_large, .reason = "too many multipart parts" },

        // Extractor tags (from path.zig/query.zig/json.zig/scalar.zig).
        error.MissingPathParam => .{ .status = .bad_request, .reason = "missing path parameter" },
        // Retained for back-compat; Query now yields error.MissingField.
        error.MissingQueryParam => .{ .status = .bad_request, .reason = "missing query parameter" },
        error.MissingField => .{ .status = .bad_request, .reason = "missing field" },
        error.InvalidScalar => .{ .status = .bad_request, .reason = "invalid parameter" },
        error.InvalidEnum => .{ .status = .bad_request, .reason = "invalid parameter" },
        error.InvalidJson => .{ .status = .unprocessable_entity, .reason = "invalid JSON body" },

        else => .{ .status = .internal_server_error, .reason = "internal server error" },
    };
}

const testing = std.testing;

test "classify maps the canonical Error set" {
    try testing.expectEqual(Status.bad_request, classify(Error.BadRequest).status);
    try testing.expectEqual(Status.not_found, classify(Error.NotFound).status);
    try testing.expectEqual(Status.conflict, classify(Error.Conflict).status);
    try testing.expectEqual(Status.too_many_requests, classify(Error.TooManyRequests).status);
    try testing.expectEqual(Status.service_unavailable, classify(Error.ServiceUnavailable).status);
    try testing.expectEqualStrings("not found", classify(Error.NotFound).reason);
}

test "classify maps extractor tags to 4xx" {
    try testing.expectEqual(Status.bad_request, classify(error.MissingPathParam).status);
    try testing.expectEqual(Status.bad_request, classify(error.InvalidScalar).status);
    try testing.expectEqual(Status.bad_request, classify(error.MissingQueryParam).status);
    try testing.expectEqual(Status.unprocessable_entity, classify(error.InvalidJson).status);
    try testing.expectEqualStrings("invalid JSON body", classify(error.InvalidJson).reason);
}

test "classify maps PayloadTooLarge to 413" {
    try testing.expectEqual(Status.payload_too_large, classify(error.PayloadTooLarge).status);
}

test "classify maps multipart errors" {
    try testing.expectEqual(Status.bad_request, classify(error.InvalidMultipart).status);
    try testing.expectEqual(Status.payload_too_large, classify(error.TooManyParts).status);
}

test "classify maps unknown errors to 500" {
    const info = classify(error.SomethingNobodyDefined);
    try testing.expectEqual(Status.internal_server_error, info.status);
    try testing.expectEqualStrings("internal server error", info.reason);
}

test "classify maps the expanded error set" {
    try testing.expectEqual(Status.gone, classify(Error.Gone).status);
    try testing.expectEqual(Status.unsupported_media_type, classify(Error.UnsupportedMediaType).status);
    try testing.expectEqual(Status.not_acceptable, classify(Error.NotAcceptable).status);
    try testing.expectEqual(Status.precondition_failed, classify(Error.PreconditionFailed).status);
    try testing.expectEqual(Status.bad_gateway, classify(Error.BadGateway).status);
    try testing.expectEqual(Status.gateway_timeout, classify(Error.GatewayTimeout).status);
    try testing.expectEqualStrings("gone", classify(Error.Gone).reason);
}
