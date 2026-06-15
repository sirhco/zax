//! Zax — an Axum-style HTTP framework for Zig 0.16.0.
//! Public API surface. (Filled out across the build; see docs/zig016-api-notes.md
//! for the verified 0.16.0 primitives this is built on.)

const std = @import("std");

// --- HTTP core (Phase 1) ---
pub const request = @import("http/request.zig");
pub const response = @import("http/response.zig");
pub const parser = @import("http/parser.zig");

pub const Request = request.Request;
pub const Method = request.Method;
pub const Header = request.Header;
pub const Response = response.Response;
pub const Status = response.Status;
pub const intoResponse = response.intoResponse;

// --- Routing (Phase 2) ---
pub const radix = @import("router/radix.zig");
pub const router = @import("router/router.zig");
pub const Router = router.Router;
pub const Param = router.Param;

// --- Comptime extractors (Phase 3) ---
pub const extract = @import("extract/extract.zig");
pub const Context = extract.Context;
pub const callHandler = extract.callHandler;
pub const Path = @import("extract/path.zig").Path;
pub const Query = @import("extract/query.zig").Query;
pub const Json = @import("extract/json.zig").Json;
pub const State = @import("extract/state.zig").State;
pub const Alloc = @import("extract/alloc.zig").Alloc;
pub const Forwarded = @import("extract/forwarded.zig").Forwarded;

// --- Middleware ---
pub const middleware = @import("middleware.zig");
pub const Chain = middleware.Chain;

// --- Server (Phase 4) ---
pub const server = @import("server.zig");
pub const App = server.App;
pub const ServerOptions = server.Options;

test {
    // Pull every module into analysis so their `test` blocks run under
    // `zig build test`.
    std.testing.refAllDecls(@This());
}
