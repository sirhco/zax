//! Tower-style middleware: an ordered chain wrapped around a route's handler.
//! A middleware receives the request context and a `*Next` cursor; calling
//! `next.run()` invokes the rest of the chain (eventually the handler). This
//! gives three behaviors from one shape:
//!   - pass-through: `return next.run();`
//!   - short-circuit: return a Response without calling `next` (e.g. auth → 401)
//!   - post-process: `var r = try next.run(); ...mutate r...; return r;`
//!
//! `Chain` is generic over the request-context type so it composes with the
//! server's `App(AppState)` (which instantiates it with its own `Context`).

const std = @import("std");
const Response = @import("http/response.zig").Response;

pub fn Chain(comptime Ctx: type) type {
    return struct {
        /// A routed handler after extractor wrapping: context in, response out.
        pub const Handler = *const fn (ctx: *const Ctx) anyerror!Response;
        /// A middleware: context + cursor in, response out.
        pub const Middleware = *const fn (ctx: *const Ctx, next: *Next) anyerror!Response;

        /// Cursor through the middleware list, terminating at the handler.
        pub const Next = struct {
            mws: []const Middleware,
            handler: Handler,
            ctx: *const Ctx,
            idx: usize = 0,

            /// Invoke the next middleware in the chain, or the handler if the
            /// chain is exhausted.
            pub fn run(self: *Next) anyerror!Response {
                if (self.idx < self.mws.len) {
                    const mw = self.mws[self.idx];
                    self.idx += 1;
                    return mw(self.ctx, self);
                }
                return self.handler(self.ctx);
            }
        };

        /// Run `h` (the route handler) wrapped by `mws` for `ctx`.
        pub fn run(mws: []const Middleware, h: Handler, ctx: *const Ctx) anyerror!Response {
            var next = Next{ .mws = mws, .handler = h, .ctx = ctx };
            return next.run();
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

const TestCtx = struct {
    buf: []u8,
    len: *usize,
    fn emit(self: *const TestCtx, c: u8) void {
        self.buf[self.len.*] = c;
        self.len.* += 1;
    }
};

const C = Chain(TestCtx);

fn handler(ctx: *const TestCtx) anyerror!Response {
    ctx.emit('H');
    return Response.text("ok");
}
fn mwA(ctx: *const TestCtx, next: *C.Next) anyerror!Response {
    ctx.emit('A');
    const r = try next.run();
    ctx.emit('a');
    return r;
}
fn mwB(ctx: *const TestCtx, next: *C.Next) anyerror!Response {
    ctx.emit('B');
    const r = try next.run();
    ctx.emit('b');
    return r;
}
fn deny(ctx: *const TestCtx, next: *C.Next) anyerror!Response {
    _ = next; // short-circuit: never call the rest of the chain
    ctx.emit('X');
    return Response.fromStatus(.unauthorized);
}
fn bump(ctx: *const TestCtx, next: *C.Next) anyerror!Response {
    var r = try next.run(); // post-process
    _ = ctx;
    r.status = .created;
    return r;
}

fn makeCtx(buf: []u8, len: *usize) TestCtx {
    return .{ .buf = buf, .len = len };
}

test "chain runs middleware outer->inner, unwinds inner->outer" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    const ctx = makeCtx(&buf, &len);
    const mws = [_]C.Middleware{ &mwA, &mwB };
    const r = try C.run(&mws, &handler, &ctx);
    try testing.expectEqualStrings("ok", r.body);
    try testing.expectEqualStrings("ABHba", buf[0..len]);
}

test "middleware can short-circuit without invoking the handler" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    const ctx = makeCtx(&buf, &len);
    const mws = [_]C.Middleware{ &deny, &mwA };
    const r = try C.run(&mws, &handler, &ctx);
    try testing.expectEqual(@import("http/response.zig").Status.unauthorized, r.status);
    try testing.expectEqualStrings("X", buf[0..len]); // mwA and handler never ran
}

test "middleware can post-process the response" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    const ctx = makeCtx(&buf, &len);
    const mws = [_]C.Middleware{&bump};
    const r = try C.run(&mws, &handler, &ctx);
    try testing.expectEqual(@import("http/response.zig").Status.created, r.status);
    try testing.expectEqualStrings("H", buf[0..len]);
}

test "empty chain calls the handler directly" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    const ctx = makeCtx(&buf, &len);
    const r = try C.run(&.{}, &handler, &ctx);
    try testing.expectEqualStrings("ok", r.body);
    try testing.expectEqualStrings("H", buf[0..len]);
}
