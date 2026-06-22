# gzip compression middleware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in `compress` middleware that gzip-compresses eligible buffered responses when the client sends `Accept-Encoding: gzip`.

**Architecture:** A new `src/compress.zig` defines a comptime `Compress` config and `compress(comptime Ctx, comptime config)` returning a `middleware.Chain(Ctx).Middleware`. The generated middleware post-processes the handler's response: if eligible (buffered, large enough, gzip-accepted, not already encoded, text-like), it gzips `r.body` via `std.compress.flate` into the request arena and sets `content-encoding: gzip` + `vary: accept-encoding`. Wired via two `root.zig` re-exports.

**Tech Stack:** Zig 0.16, `std.compress.flate`.

## Global Constraints

- Zig 0.16. Additive: new file `src/compress.zig` + 2 root re-exports. No `error.zig` change, no change to existing middleware/routing/response behavior. Opt-in.
- gzip only (Container `.gzip`). Never `deflate`/`br`/`zstd`.
- Compress ONLY when ALL hold: response not streaming (`streamer == null and pull_streamer == null`); `body.len >= config.min_length`; client `Accept-Encoding` contains a `gzip` token not disabled by `;q=0`; response has no existing `content-encoding`; content-type is text-like. Also skip if the compressed output is not smaller than the input.
- Text-like = media type (portion before `;`) is `text/*`, `application/json`, `application/javascript`, `application/xml`, `image/svg+xml`, or ends with `+xml`.
- On success: set `r.body = gz`, append `content-encoding: gzip` and `vary: accept-encoding` (lowercase). `content-length` auto-corrects (`writeHeaders` uses `body.len`).
- On any compression error → return the ORIGINAL uncompressed response (never fail a response over compression).
- Comptime factory `compress(comptime Ctx, comptime config: Compress)` — config MUST be comptime (bare fn-pointer chain), same shape as `cors`.
- **CRITICAL (verified against installed Zig 0.16):** `flate.Compress.init` asserts `output.buffer.len > 8`. `std.Io.Writer.Allocating.init` starts with a ZERO-length buffer → the assert trips. Use `std.Io.Writer.Allocating.initCapacity(arena, N)` (N > 8). The deflate `window` buffer must be `>= flate.max_window_len` (65536).
- Test baseline: current `v0.12.0` branch green (`zig build test --summary all`, 0 failures). `timeout` not on this mac — run zig directly. No timing-sensitive paths → single run.

---

### Task 1: compress config + factory + helpers + unit tests

**Files:**
- Create: `src/compress.zig`
- Modify: `src/root.zig` (two re-exports)

**Interfaces:**
- Produces: `pub const Compress = struct { pub const Level = enum { fastest, default, best }; level: Level = .default, min_length: usize = 1024 }`; `pub fn compress(comptime Ctx: type, comptime config: Compress) middleware.Chain(Ctx).Middleware`.

- [ ] **Step 1: Write the module + failing tests (TDD).**

Create `src/compress.zig`:

```zig
//! gzip response-compression middleware (built-in). `compress(Ctx, config)`
//! returns a Chain(Ctx) middleware that gzips eligible buffered responses when
//! the client sends `Accept-Encoding: gzip`. Streamed responses, small bodies,
//! non-text content types, and already-encoded responses pass through untouched.
//! Config is comptime.

const std = @import("std");
const flate = std.compress.flate;
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;
const Header = @import("http/request.zig").Header;

pub const Compress = struct {
    pub const Level = enum { fastest, default, best };
    level: Level = .default,
    /// Skip bodies smaller than this many bytes (compression overhead).
    min_length: usize = 1024,

    fn options(self: Compress) flate.Compress.Options {
        return switch (self.level) {
            .fastest => flate.Compress.Options.level_1,
            .default => flate.Compress.Options.level_6,
            .best => flate.Compress.Options.level_9,
        };
    }
};

pub fn compress(comptime Ctx: type, comptime config: Compress) middleware.Chain(Ctx).Middleware {
    const Next = middleware.Chain(Ctx).Next;
    const Impl = struct {
        fn mw(ctx: *const Ctx, next: *Next) anyerror!Response {
            var r = try next.run();
            if (r.streamer != null or r.pull_streamer != null) return r;
            if (r.body.len < config.min_length) return r;
            if (!acceptsGzip(ctx.req.header("accept-encoding"))) return r;
            if (hasHeader(r, "content-encoding")) return r;
            if (!isCompressible(r.content_type)) return r;

            const gz = gzip(ctx.arena, r.body, comptime config.options()) catch return r;
            if (gz.len >= r.body.len) return r; // no gain
            r.body = gz;
            r = try r.withHeader(ctx.arena, "content-encoding", "gzip");
            r = try r.withHeader(ctx.arena, "vary", "accept-encoding");
            return r;
        }
    };
    return Impl.mw;
}

/// gzip `body` into `arena`. Returns the compressed bytes.
fn gzip(arena: std.mem.Allocator, body: []const u8, opts: flate.Compress.Options) ![]const u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(arena, 4096); // >8: Compress.init asserts
    const window = try arena.alloc(u8, flate.max_window_len);
    var c = try flate.Compress.init(&aw.writer, window, .gzip, opts);
    try c.writer.writeAll(body);
    try c.finish();
    try aw.writer.flush();
    return aw.written();
}

/// True iff `accept-encoding` advertises gzip and does not disable it (`gzip;q=0`).
fn acceptsGzip(header: ?[]const u8) bool {
    const h = header orelse return false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        // token is "gzip" optionally followed by ";q=..."
        const name_end = std.mem.indexOfScalar(u8, t, ';') orelse t.len;
        const name = std.mem.trim(u8, t[0..name_end], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "gzip")) continue;
        // check for an explicit q=0
        if (std.mem.indexOf(u8, t[name_end..], "q=0")) |_| {
            // disabled unless it's q=0.<nonzero> — keep it simple: treat any q=0 prefix as disabled
            // (q=0.5 would also match "q=0"; acceptable conservative behavior — see note)
            return false;
        }
        return true;
    }
    return false;
}

/// True for text-like media types worth compressing.
fn isCompressible(content_type: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const mt = std.mem.trim(u8, content_type[0..semi], " \t");
    if (std.ascii.startsWithIgnoreCase(mt, "text/")) return true;
    if (std.mem.endsWith(u8, mt, "+xml")) return true;
    const exact = [_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "image/svg+xml",
    };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(mt, e)) return true;
    return false;
}

fn hasHeader(r: Response, name: []const u8) bool {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    return false;
}
```

**Verify against the installed Zig 0.16 std source before relying on it:**
- `std.Io.Writer.Allocating.initCapacity(allocator, capacity) error{OutOfMemory}!Allocating` and `aw.written()` (see `src/server.zig:2204` for the `Allocating` + `written()` idiom).
- `flate.Compress.init(&aw.writer, window, .gzip, opts) !Compress`, write to `c.writer`, `c.finish()`. The std flate compress test (`std/compress/flate/Compress.zig` ~lines 1514/1571/1591) shows the finalize sequence — match it (the `aw.writer.flush()` after `finish()` mirrors that; drop it only if it doesn't compile/is redundant).
- `flate.Compress.Options.level_1/level_6/level_9` and `flate.max_window_len`.

Note on `acceptsGzip` q-handling: the simple `q=0` substring check also rejects `q=0.5`. This is acceptable conservative behavior (a client sending `gzip;q=0.5` rarely happens and just gets an uncompressed response). Document it; do not over-engineer q-parsing.

- [ ] **Step 2: Unit tests** (append to `compress.zig`):

```zig
const testing = std.testing;
const Request = @import("http/request.zig").Request;
const Method = @import("http/request.zig").Method;

const TestCtx = struct {
    req: *const Request,
    arena: std.mem.Allocator,
};

fn fakeReq(headers: []const Header) Request {
    return .{ .method = .GET, .target = "/", .path = "/", .query = "", .version_minor = 1, .headers = headers, .body = "" };
}

fn hdr(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Run `config`'s compress middleware over a request, with a handler that returns `resp`.
fn runCompress(arena: std.mem.Allocator, comptime config: Compress, req: *const Request, resp: Response) !Response {
    const C = middleware.Chain(TestCtx);
    const H = struct {
        var out: Response = undefined;
        fn handler(_: *const TestCtx) anyerror!Response {
            return out;
        }
    };
    H.out = resp;
    var ctx = TestCtx{ .req = req, .arena = arena };
    const mws = [_]C.Middleware{compress(TestCtx, config)};
    return C.run(&mws, &H.handler, &ctx);
}

/// gunzip helper for round-trip assertions.
fn gunzip(arena: std.mem.Allocator, gz: []const u8) ![]const u8 {
    var in = std.Io.Reader.fixed(gz);
    const dbuf = try arena.alloc(u8, flate.max_window_len);
    var dec = flate.Decompress.init(&in, .gzip, dbuf);
    return dec.reader.allocRemaining(arena, .unlimited);
}

test "compress: gzip a large text body and round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const r = try runCompress(a, .{}, &req, Response.text(body));
    try testing.expectEqualStrings("gzip", hdr(r, "content-encoding").?);
    try testing.expectEqualStrings("accept-encoding", hdr(r, "vary").?);
    try testing.expect(r.body.len >= 2 and r.body[0] == 0x1f and r.body[1] == 0x8b); // gzip magic
    try testing.expect(r.body.len < body.len);
    const round = try gunzip(a, r.body);
    try testing.expectEqualStrings(body, round);
}

test "compress: body below min_length untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text("small"));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: no gzip in accept-encoding untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "br, deflate" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text(body));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: gzip;q=0 disables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip;q=0" }});
    const r = try runCompress(arena.allocator(), .{}, &req, Response.text(body));
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: non-text content-type untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    var resp = Response.text(body);
    resp.content_type = "image/png";
    const r = try runCompress(arena.allocator(), .{}, &req, resp);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: already content-encoded untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "x" ** 2000;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const pre = try Response.text(body).withHeader(a, "content-encoding", "br");
    const r = try runCompress(a, .{}, &req, pre);
    // still only the original br encoding; no second gzip applied
    try testing.expectEqualStrings("br", hdr(r, "content-encoding").?);
    try testing.expect(r.body.len == body.len); // body not replaced
}

test "compress: streamed response untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    const Streamed = struct {
        fn run(_: *const u8, w: *std.Io.Writer) anyerror!void {
            try w.writeAll("x" ** 2000);
        }
    };
    const dummy: u8 = 0;
    const resp = Response.stream(u8, &dummy, Streamed.run, "text/plain");
    const r = try runCompress(arena.allocator(), .{}, &req, resp);
    try testing.expectEqual(@as(?[]const u8, null), hdr(r, "content-encoding"));
}

test "compress: level best and fastest both round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "hello world " ** 200;
    const req = fakeReq(&.{.{ .name = "Accept-Encoding", .value = "gzip" }});
    inline for (.{ Compress.Level.fastest, Compress.Level.best }) |lvl| {
        const r = try runCompress(a, .{ .level = lvl }, &req, Response.text(body));
        try testing.expectEqualStrings("gzip", hdr(r, "content-encoding").?);
        try testing.expectEqualStrings(body, try gunzip(a, r.body));
    }
}
```

Verify the `Decompress` round-trip idiom against the std source (`std/compress/flate/Decompress.zig`): `flate.Decompress.init(&reader, .gzip, buffer)` then read all from `dec.reader`. If `allocRemaining(arena, .unlimited)` is not the exact 0.16 spelling, use the std `Reader` read-all idiom that compiles (e.g. a `readSliceShort` loop, as in the Decompress test ~line 1137) — the assertion (round-trip equals original) is what matters.

- [ ] **Step 3: Export** in `src/root.zig` (near the `cors`/middleware exports):

```zig
pub const Compress = @import("compress.zig").Compress;
pub const compress = @import("compress.zig").compress;
```
Confirm `Compress`/`compress` are not already public symbols.

- [ ] **Step 4: Gate** — `zig build test --summary all` green (RED first to confirm failure without the impl, then GREEN).

- [ ] **Step 5: Commit** — `feat(compress): built-in gzip response-compression middleware`.

---

### Task 2: e2e test in server.zig

**Files:**
- Modify: `src/server.zig` (add test routes + e2e test)

**Interfaces:**
- Consumes: `zax.compress` / `App(S).Context` (Task 1). Register via `try app.use(zax.compress(<CtxType>, .{}))` — adapt the Ctx-type spelling and `app.use` call to how the existing cors e2e test does it (study that test; do not invent a new convention).

- [ ] **Step 1:** Mirror the cors/Headers e2e (`doRequest` loopback + test-app setup). Register `compress(.{})` via `app.use`, a `GET /big` route returning a > 1 KiB text body, and a `GET /small` route returning a short body, on a fresh port:

```zig
test "e2e: gzip compresses a large text response when accepted" {
    // ... standard test-app setup on a fresh port; app.use(compress(...)); app.get("/big", bigHandler); app.get("/small", smallHandler) ...
    var rb1: [4096]u8 = undefined;
    const big = doRequest(io, port, "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n", &rb1);
    try testing.expect(std.mem.indexOf(u8, big, "content-encoding: gzip\r\n") != null);

    var rb2: [4096]u8 = undefined;
    const small = doRequest(io, port, "GET /small HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, small, "content-encoding: gzip") == null);
}
```
(Adapt handler signatures, `app.use`/`app.get`, ports, and teardown to the EXACT conventions already in `src/server.zig`. `bigHandler` returns a text body > 1024 bytes; `smallHandler` returns something short.)

- [ ] **Step 2: Gate** — `zig build test --summary all` green.

- [ ] **Step 3: Commit** — `test(compress): e2e gzip over loopback (large compressed, small skipped)`.

---

### Task 3: docs

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `CHANGELOG.md`

- [ ] **Step 1:** `README.md` — in the middleware section near `cors`, document `compress` + `Compress` config (`level`, `min_length`), the gzip-only/Accept-Encoding behavior, the text-like allowlist, streaming/threshold/already-encoded skips, and a snippet (`try app.use(zax.compress(App(S).Context, .{}))`). Match neighboring format.
- [ ] **Step 2:** `docs/getting-started.md` — add `compress` if it covers middleware; else leave and note it.
- [ ] **Step 3:** `CHANGELOG.md` — entry under `[Unreleased]` → `### Added` (match existing style).
- [ ] **Step 4: Gate** — docs match shipped API; `zig build test` still green.
- [ ] **Step 5: Commit** — `docs(compress): document the gzip compression middleware`.

---

## Verification (end-to-end, after all tasks)

1. `zig build test --summary all` — all green (unit incl. round-trip + e2e).
2. `zig build run` with `compress`; JS-fetch smoke (curl hooked): large text route + `Accept-Encoding: gzip` → `content-encoding: gzip`, smaller body.
3. `grep -n "compress\|Compress" README.md` — appears in the middleware docs.
4. Version is `0.12.0` in `build.zig.zon`.
