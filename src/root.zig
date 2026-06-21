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
pub const sse = @import("http/sse.zig");
pub const chunked = @import("http/chunked.zig");
pub const Sse = sse.Sse;
pub const SseEvent = sse.Event;
pub const Writer = std.Io.Writer;
pub const Streamer = response.Streamer;
pub const SsePull = response.SsePull;
pub const PullResult = response.PullResult;
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
pub const url = @import("url.zig");
pub const urlencoded = @import("extract/urlencoded.zig");
pub const Form = @import("extract/form.zig").Form;
pub const Cookies = @import("extract/cookie.zig").Cookies;
pub const Bytes = @import("extract/bytes.zig").Bytes;
pub const files = @import("extract/files.zig");
pub const Files = files.Files;

// --- Observability ---
pub const observe = @import("observe.zig");
pub const Observer = observe.Observer;
pub const AccessRecord = observe.AccessRecord;
pub const AccessLogger = observe.AccessLogger;
pub const RequestId = @import("extract/request_id.zig").RequestId;
pub const Metrics = observe.Metrics;
pub const MetricsSnapshot = observe.MetricsSnapshot;

// --- Error model ---
pub const err = @import("error.zig");
pub const ErrorInfo = err.ErrorInfo;
pub const Error = err.Error;
pub const classify = err.classify;

// --- Middleware ---
pub const middleware = @import("middleware.zig");
pub const Chain = middleware.Chain;

// --- Server (Phase 4) ---
pub const server = @import("server.zig");
pub const App = server.App;
pub const ServerOptions = server.Options;

// --- Reactor (evented backend, additive) ---
pub const reactor_transport = @import("reactor/transport.zig");
pub const reactor_conn = @import("reactor/conn.zig");
pub const reactor_timer = @import("reactor/timer.zig");
pub const reactor_poller = @import("reactor/poller.zig");
pub const reactor_worker = @import("reactor/worker.zig");

// Expose the build-time trace flag so downstream binaries (e.g. the cross-bench
// server) can print it in their boot line without importing build_options directly.
pub const trace_latency: bool = @import("build_options").trace_latency;

test "root re-exports streaming types" {
    _ = SsePull;
    _ = PullResult;
}

test {
    // Pull every module into analysis so their `test` blocks run under
    // `zig build test`.
    std.testing.refAllDecls(@This());
    // Task 1: multipart.zig not yet re-exported from root; pull it in for tests.
    _ = @import("extract/multipart.zig");
}
