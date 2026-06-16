# Zax — static file serving (C-c3) design

Date: 2026-06-16
Status: approved, ready for implementation planning
Scope: sub-project C-c3 of theme C — serve files from disk via a `Files`
extractor. Completes theme C. Out of scope: sized-streaming of huge files,
directory listings, caching/conditional requests, range requests.

## Context

Zax can build responses but cannot serve files from disk. Three wrinkles:

1. Reading a file needs a `std.Io` instance. The handler `Context` carries
   `{req, params, state, arena, trust_forwarded}` — no `io`. The server has `io`
   in `handleConn`. Handlers receive extractors (not the raw `Context`), so the
   file API must be an extractor that pulls `io`/`arena` from the context.
2. Body production: buffer the whole file into the request arena (simple,
   correct Content-Length, keep-alive preserved) vs sized-streaming.
3. Content-type by extension; path-traversal safety for request-derived paths.

## Decisions (from brainstorming)

- **Buffer into the request arena** via `Io.Dir.readFileAlloc` with a size cap.
  Memory = file size; Content-Length and keep-alive are preserved. Sized-streaming
  is a later refinement.
- **`Files` extractor** with `file(path)` (handler-controlled path) AND
  `dir(root, requested)` (safe join, rejects traversal).

## Verified primitives (Zig 0.16.0)

- `std.Io.Dir.cwd() Dir`.
- `Dir.readFileAlloc(dir, io, sub_path, gpa, limit: Io.Limit) ReadFileAllocError![]u8`
  — reads the whole file into `gpa` (use the arena); `error.StreamTooLong` if the
  file reaches/exceeds `limit`. `ReadFileAllocError` includes `FileNotFound`,
  `AccessDenied`, `PermissionDenied`, `NotDir`, `IsDir`, `StreamTooLong`, plus
  `Allocator.Error` and other I/O errors.
- `Io.Limit.limited(n: usize) Limit`.

## Architecture

```
handler param Files (extractor) ── fromContext → { io = ctx.io, arena = ctx.arena }
  files.file("static/x.css")
     → Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max)) → bytes
     → Response{ content_type = contentType(path), body = bytes }   // buffered
     (read error → canonical error → existing classifier → 404/403/413/500)
  files.dir("static", requested)
     → safeJoin(arena, "static", requested) orelse error.NotFound → files.file(joined)
```

### Component 1 — `io` on `Context` (`src/extract/extract.zig`)

Add `io: std.Io` (no default) to `Context`. The two `Context` literal sites set
it:
- `src/server.zig` `makeCtx` gains an `io` parameter and sets `.io = io`; the
  server's `dispatch` gains an `io` parameter threaded from `handleConn`, and its
  three `makeCtx` call sites (`not_found`/`method_not_allowed`/`found` and the
  `match`-error path) pass it. The alloc-accounting test that calls `dispatch`
  directly passes an `io` (a `Threaded` instance, or `undefined` since that path
  doesn't read it).
- `src/extract/extract.zig`'s test `makeCtx` builder sets `.io = undefined`
  (file serving is not exercised there).

Other extractor unit tests use anonymous duck-typed contexts (not `Context`), so
they are unaffected.

### Component 2 — `src/extract/files.zig` (new)

```zig
const std = @import("std");
const Response = @import("../http/response.zig").Response;

pub const default_max_file_size: usize = 16 * 1024 * 1024;

pub const Files = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    pub fn fromContext(ctx: anytype) error{}!Files {
        return .{ .io = ctx.io, .arena = ctx.arena };
    }

    /// Serve an explicit (handler-controlled) file path, relative to the cwd.
    pub fn file(self: Files, path: []const u8) !Response {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io, path, self.arena, std.Io.Limit.limited(default_max_file_size),
        ) catch |e| switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.Forbidden,
            error.StreamTooLong => return error.PayloadTooLarge,
            else => return error.Internal,
        };
        return .{ .content_type = contentType(path), .body = bytes };
    }

    /// Safely serve `requested` under `root`. Traversal (`..`/absolute) → 404.
    pub fn dir(self: Files, root: []const u8, requested: []const u8) !Response {
        const joined = safeJoin(self.arena, root, requested) orelse return error.NotFound;
        return self.file(joined);
    }
};

/// Content type by file extension; defaults to application/octet-stream.
pub fn contentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    const map = .{
        .{ "html", "text/html; charset=utf-8" }, .{ "css", "text/css" },
        .{ "js", "text/javascript" },            .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },             .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },                .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },                 .{ "txt", "text/plain; charset=utf-8" },
        .{ "ico", "image/x-icon" },              .{ "wasm", "application/wasm" },
    };
    inline for (map) |kv| if (std.mem.eql(u8, ext, kv[0])) return kv[1];
    return "application/octet-stream";
}

/// Join `requested` under `root`, rejecting any traversal. Returns null if
/// `requested` is empty or contains a `.`, `..`, or empty path segment
/// (blocking absolute paths, `..`, `./`, `//`). Result is arena-allocated.
pub fn safeJoin(arena: std.mem.Allocator, root: []const u8, requested: []const u8) ?[]const u8 {
    if (requested.len == 0) return null;
    var it = std.mem.splitScalar(u8, requested, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null) return null; // reject backslash too
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, requested }) catch null;
}
```

### Component 3 — `error.zig`

Add to `classify`: `error.PayloadTooLarge => { .status = .payload_too_large,
.reason = "payload too large" }` (the 413 status already exists;
`NotFound`/`Forbidden`/`Internal` already map).

### Component 4 — exports (`src/root.zig`)

```zig
pub const Files = @import("extract/files.zig").Files;
```

## Handler usage

```zig
fn index(files: zax.Files) !zax.Response {
    return files.file("static/index.html");
}
fn asset(p: zax.Path(struct { rest: []const u8 }), files: zax.Files) !zax.Response {
    return files.dir("static", p.value.rest);   // traversal-safe
}
```

## Error handling

`Files.file`/`dir` return canonical errors (`error.NotFound`/`Forbidden`/
`PayloadTooLarge`/`Internal`). The handler `try`s them; the dispatcher's existing
`renderError` → `classify` maps them to 404/403/413/500. `dir` maps a traversal
attempt to `NotFound` (404, not 403 — does not reveal that a guarded path exists).

## Testing

**Unit (`files.zig`):**
- `contentType`: `.html`→text/html, `.css`, `.js`, `.json`, `.png`, no-ext/unknown
  → `application/octet-stream`.
- `safeJoin`: `"a/b.txt"` under `"static"` → `"static/a/b.txt"`; `".."`,
  `"a/../x"`, `"/etc/passwd"` (leading slash → empty seg), `"./x"`, `"a//b"` →
  null.
- `classify(error.PayloadTooLarge)` → 413.

**File + socket (`server.zig`, real `Io.Threaded`):**
- `Files.file`: write a temp file (via `Io.Dir`), serve it, assert `body` ==
  contents and `content_type` by extension; a nonexistent path → `error.NotFound`.
- Socket integration: a route serving a temp file; client receives the bytes,
  `content-type`, and a `content-length` header. A `dir` traversal request
  (`..`) → 404.

## Files

- New: `src/extract/files.zig` (+ unit tests).
- Modify: `src/extract/extract.zig` (`Context.io`), `src/server.zig` (`dispatch`/
  `makeCtx` thread `io`; alloc-test `dispatch` call; integration test),
  `src/error.zig` (`PayloadTooLarge`→413), `src/root.zig` (export `Files`).
- Docs: README + `docs/getting-started.md` — a file-serving note.

## Risks & edge cases

- **Threading `io` through `dispatch`/`makeCtx`** touches several call sites and
  the alloc-accounting test's direct `dispatch` call. Mitigated by `Context.io`
  having no default (compile error flags any missed literal).
- **`safeJoin` strictness:** rejecting every `.`/`..`/empty segment also forbids
  legitimate `.`-only oddities, but is the safe default; documented.
- **Temp-file test cleanup:** the file test writes to and deletes a temp path; use
  a unique name and best-effort delete.
- **Buffered memory:** a request for a large (but under-cap) file allocates its
  full size in the arena; the `default_max_file_size` cap bounds it. Over-cap →
  413.

## Out of scope

Sized-streaming large files, directory listings, `If-Modified-Since`/ETag,
range requests, symlink policy, and a configurable per-app `max_file_size`
(a module default is used; a knob can come later).
