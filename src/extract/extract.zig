//! The comptime extractor dispatcher — the heart of Zax's Axum-style ergonomics.
//! A handler is any function whose parameters are Zax extractor types. At
//! comptime we reflect the signature, build the argument tuple by running each
//! parameter's extractor against the request `Context`, then `@call` the handler
//! and convert its return value through `IntoResponse`.

const std = @import("std");
const response = @import("../http/response.zig");
const Response = response.Response;
const Request = @import("../http/request.zig").Request;
const Param = @import("../router/radix.zig").Param;

/// Per-request context handed to every extractor. `AppState` is the concrete,
/// read-only application state type the router is parameterized by.
pub fn Context(comptime AppState: type) type {
    return struct {
        req: *const Request,
        params: []const Param,
        state: AppState,
        arena: std.mem.Allocator,
        io: std.Io,
        /// Whether `X-Forwarded-*` headers should be trusted (set by the server
        /// from `Options.trust_forwarded`; only true behind a controlled proxy).
        trust_forwarded: bool = false,
    };
}

/// True if `T` (a function type) is a valid handler signature: every parameter
/// is an extractor and any body-consuming extractor is the final parameter.
/// Non-failing companion to `validate` (which hard-errors) so the rule is
/// unit-testable.
pub fn signatureValid(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"fn") return false;
    const params = info.@"fn".params;
    inline for (params, 0..) |p, i| {
        const P = p.type orelse return false;
        if (!isExtractor(P)) return false;
        if (isBody(P) and i != params.len - 1) return false;
    }
    return true;
}

fn isExtractor(comptime P: type) bool {
    if (@typeInfo(P) != .@"struct") return false;
    if (!@hasDecl(P, "zax_is_extractor")) return false;
    return P.zax_is_extractor;
}

fn isBody(comptime P: type) bool {
    if (@typeInfo(P) != .@"struct") return false;
    if (!@hasDecl(P, "zax_is_body")) return false;
    return P.zax_is_body;
}

fn validate(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"fn") @compileError("handler must be a function, got " ++ @typeName(T));
    const params = info.@"fn".params;
    inline for (params, 0..) |p, i| {
        const P = p.type orelse @compileError("handler has a generic/anytype parameter");
        if (!isExtractor(P))
            @compileError("handler parameter " ++ digits(i) ++ " (" ++ @typeName(P) ++ ") is not a Zax extractor");
        if (isBody(P) and i != params.len - 1)
            @compileError("body extractor " ++ @typeName(P) ++ " must be the handler's last parameter");
    }
}

fn digits(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// Run `handler` for the given context: extract each argument, call, and convert
/// the result into a `Response`. Returns the merged error set of all extractors
/// and the handler itself; the server maps a returned error to a 500.
pub fn callHandler(comptime handler: anytype, ctx: anytype) !Response {
    const F = @TypeOf(handler);
    comptime validate(F);
    const info = @typeInfo(F).@"fn";
    var args: std.meta.ArgsTuple(F) = undefined;
    inline for (info.params, 0..) |p, i| {
        const extracted = try p.type.?.fromContext(ctx);
        args[i] = extracted;
    }
    const ret = @call(.auto, handler, args);
    return toResponse(ret);
}

fn toResponse(ret: anytype) !Response {
    const RT = @TypeOf(ret);
    if (@typeInfo(RT) == .error_union) {
        const val = try ret;
        return response.intoResponse(val);
    }
    return response.intoResponse(ret);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const Path = @import("path.zig").Path;
const Query = @import("query.zig").Query;
const Json = @import("json.zig").Json;
const State = @import("state.zig").State;

const Db = struct { greeting: []const u8 };
const App = *const Db;
const Ctx = Context(App);

fn makeCtx(db: *const Db, params: []const Param, query: []const u8, body: []const u8, arena: std.mem.Allocator) Ctx {
    const S = struct {
        var req: Request = undefined;
    };
    S.req = .{
        .method = .POST,
        .target = "",
        .path = "",
        .query = query,
        .version_minor = 1,
        .headers = &.{},
        .body = body,
    };
    return .{ .req = &S.req, .params = params, .state = db, .arena = arena, .io = undefined };
}

// Handlers under test.
fn hello() Response {
    return Response.text("hi");
}
fn greetPath(p: Path(struct { name: []const u8 })) Response {
    return Response.text(p.value.name);
}
fn withState(s: State(App)) Response {
    return Response.text(s.value.greeting);
}
fn createUser(s: State(App), p: Path(struct { id: u64 }), body: Json(struct { name: []const u8 })) !Response {
    _ = s;
    if (p.value.id == 0) return error.BadId;
    return Response.text(body.value.name);
}

test "signatureValid accepts valid and rejects body-not-last / non-extractor" {
    try testing.expect(signatureValid(@TypeOf(hello)));
    try testing.expect(signatureValid(@TypeOf(createUser)));

    const BodyFirst = fn (Json(struct { x: u8 }), Path(u8)) Response;
    try testing.expect(!signatureValid(BodyFirst));

    const RawParam = fn (u32) Response;
    try testing.expect(!signatureValid(RawParam));
}

test "callHandler dispatches niladic, path, and state handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const db = Db{ .greeting = "hello-from-state" };

    try testing.expectEqualStrings("hi", (try callHandler(hello, makeCtx(&db, &.{}, "", "", arena.allocator()))).body);

    const params = [_]Param{.{ .name = "name", .value = "ada" }};
    try testing.expectEqualStrings("ada", (try callHandler(greetPath, makeCtx(&db, &params, "", "", arena.allocator()))).body);

    try testing.expectEqualStrings("hello-from-state", (try callHandler(withState, makeCtx(&db, &.{}, "", "", arena.allocator()))).body);
}

test "callHandler with State+Path+Json and error propagation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const db = Db{ .greeting = "g" };

    const ok_params = [_]Param{.{ .name = "id", .value = "9" }};
    const ok = try callHandler(createUser, makeCtx(&db, &ok_params, "", "{\"name\":\"grace\"}", arena.allocator()));
    try testing.expectEqualStrings("grace", ok.body);

    const bad_params = [_]Param{.{ .name = "id", .value = "0" }};
    try testing.expectError(error.BadId, callHandler(createUser, makeCtx(&db, &bad_params, "", "{\"name\":\"x\"}", arena.allocator())));
}
