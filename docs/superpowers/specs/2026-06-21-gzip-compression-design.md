# Design — gzip compression middleware

**Status:** approved 2026-06-21. Branch `v0.12.0` (off main `9b5edfb`).

## Problem

zax has no response compression — every response goes out uncompressed, wasting
bandwidth on the text payloads (HTML/JSON/JS) that dominate web traffic. Now that
the middleware chain has a proven post-processing path (the `cors` middleware,
v0.11.0), gzip is naturally expressible as a second built-in middleware that
compresses the handler's response body.

## Goal

A built-in `compress` middleware factory that gzip-compresses eligible buffered
responses when the client advertises `Accept-Encoding: gzip`, setting
`content-encoding: gzip` + `vary: accept-encoding`. Built on
`std.compress.flate` (Container `.gzip`), the existing `Response.withHeader`, and
the `Chain(Ctx)` post-process pattern.

Non-goals (YAGNI): `deflate`/`br`/`zstd` encodings (gzip is universal);
compressing streamed/SSE responses (can't post-hoc compress a streamer);
precomputed/static-asset compression caches; per-route compression config beyond
the comptime factory; honoring full `Accept-Encoding` q-value ordering (only the
`gzip` token + an explicit `gzip;q=0` refusal are considered).

### Decisions (confirmed with Chris)
- **gzip only.** Negotiate just the `gzip` token.
- **Text-like allowlist.** Compress only when the response content-type is
  text-like; never burn CPU on already-compressed binary.
- **Config: `level` + `min_length`** with sane defaults; always emit
  `vary: accept-encoding` **when compressing**; skip streaming responses.
- **Comptime factory** `compress(Ctx, config)` (bare fn-pointer chain), same shape
  as `cors`.
- Version bump to **0.12.0**.

## Background (verified against installed Zig 0.16)

`std.compress.flate.Compress.init(output: *std.Io.Writer, window: []u8, container:
flate.Container, opts: flate.Compress.Options) !Compress` — write the input to
`comp.writer`, then `comp.finish()` emits the gzip footer (CRC + length).
`window` must be `>= flate.max_window_len` (65536). Output sink:
`std.Io.Writer.Allocating.init(arena)` (already used at `src/server.zig:2204`);
`aw.written()` returns the produced bytes. Level presets:
`flate.Compress.Options.level_1` (fastest) / `.level_6` (default) / `.level_9`
(best). `flate.Compress.Container.gzip`. Decompression for round-trip tests:
`std.compress.flate.Decompress`.

`Response` (`src/http/response.zig`): buffered body in `body: []const u8`;
`writeHeaders` emits `content-length: {body.len}` (so replacing `body` with the
compressed slice auto-corrects content-length); `streamer`/`pull_streamer`
non-null mark a streamed (non-buffered) response; `withHeader(arena, name, value)`
appends an arena header. The middleware `Chain(Ctx).Middleware` and `app.use`
work exactly as for `cors`.

## Components

### Added: `src/compress.zig`

```zig
//! gzip response-compression middleware (built-in). `compress(Ctx, config)`
//! returns a Chain(Ctx) middleware that gzips eligible buffered responses when
//! the client sends `Accept-Encoding: gzip`. Streamed responses, small bodies,
//! non-text content types, and already-encoded responses are passed through
//! untouched. Config is comptime.

const std = @import("std");
const flate = std.compress.flate;
const middleware = @import("middleware.zig");
const Response = @import("http/response.zig").Response;

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
            if (gz.len >= r.body.len) return r; // no gain; skip
            r.body = gz;
            r = try r.withHeader(ctx.arena, "content-encoding", "gzip");
            r = try r.withHeader(ctx.arena, "vary", "accept-encoding");
            return r;
        }
    };
    return Impl.mw;
}
```

Helpers (file-private):
- `fn gzip(arena, body, opts) ![]const u8` — `var aw =
  std.Io.Writer.Allocating.init(arena); const window = try
  arena.alloc(u8, flate.max_window_len); var c = try
  flate.Compress.init(&aw.writer, window, .gzip, opts); try
  c.writer.writeAll(body); try c.finish(); return aw.written();` (match the exact
  0.16 method names against the std source / `server.zig:2204`).
- `fn acceptsGzip(h: ?[]const u8) bool` — true iff the header contains a `gzip`
  token that is not explicitly disabled (`gzip;q=0` / `gzip;q=0.0`). A simple,
  defensive scan; full q-ordering not honored.
- `fn isCompressible(content_type: []const u8) bool` — true for the media type
  (portion before `;`) being `text/*`, `application/json`,
  `application/javascript`, `application/xml`, `image/svg+xml`, or ending in
  `+xml`.
- `fn hasHeader(r: Response, name) bool` — case-insensitive scan of `r.headers`.

### Modified: `src/root.zig`

```zig
pub const Compress = @import("compress.zig").Compress;
pub const compress = @import("compress.zig").compress;
```

### No `error.zig` change

Compression failure is swallowed (return the original response). The only error
type touched is arena `OutOfMemory` from `withHeader`, which propagates as today.

## Data flow

```
handler → Response{ body, content_type }
  → compress mw: r = next.run(); eligible?  (streaming? size? accept-encoding? already-encoded? text-like?)
      yes → gzip(body) → r.body = gz; +content-encoding: gzip; +vary: accept-encoding
      no  → r unchanged
  → writeHeaders emits content-length = gz.len; client inflates
```

## Error handling

- Any `gzip()` error → return the uncompressed response (never fail a response
  over compression).
- Compressed output not smaller than input → skip (return original).
- `withHeader` `OutOfMemory` → propagates (existing behavior).

## Behavior change & test impact

Additive: one new file + two root re-exports. Opt-in (only active when the user
adds the middleware). No change to existing response/middleware/routing behavior;
existing tests unaffected.

## Testing

Unit (`src/compress.zig`) — drive the middleware via `Chain(TestCtx).run` with a
fake `TestCtx` (`.req` with an `Accept-Encoding` header, `.arena`) and a handler
returning a chosen body/content-type:
1. Compressible text body, `Accept-Encoding: gzip`, over threshold → response
   `content-encoding: gzip`, `vary: accept-encoding`, body starts with gzip magic
   `0x1f 0x8b`, and **round-trips** (decompress via `flate.Decompress` equals the
   original body) — proves correctness, not just "header present".
2. Body below `min_length` → untouched (no content-encoding).
3. No `gzip` in `Accept-Encoding` (and `gzip;q=0`) → untouched.
4. Non-text content-type (e.g. `image/png`) → untouched.
5. Response already has `content-encoding` → untouched.
6. Streamed response (`streamer` set) → untouched.
7. `level = .best` and `.fastest` both produce a valid gzip that round-trips.

e2e (`src/server.zig`, loopback; mirror the cors/Headers e2e + `doRequest`):
8. `app.use(zax.compress(App(S).Context, .{}))`; a route returning a large
   (> 1 KiB) text body. `GET` with `Accept-Encoding: gzip` → response has
   `content-encoding: gzip` and a gzip-magic body. A small-body route → not
   compressed.

## Verification

- `zig build test --summary all` — baseline green + new unit + e2e, 0 failures
  (mac kqueue + Linux epoll). No timing-sensitive paths → single run.
- Manual: `zig build run` with `compress`; JS-fetch smoke (curl hooked) —
  request a large text route with `Accept-Encoding: gzip` → `content-encoding:
  gzip`, smaller transfer.

## Docs

- `README.md` (middleware section, by `cors`): document `compress` + `Compress`
  config, the text-like allowlist, gzip-only/Accept-Encoding behavior,
  streaming/threshold skips, and a snippet.
- `docs/getting-started.md`: add if it covers middleware.
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added`.
