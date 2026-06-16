# Getting started with Zax

This walks through creating a new Zax service from scratch, validating it, and
running it. A complete, working version of everything here lives in
[`examples/hello-service/`](../examples/hello-service) — build and run that if you
just want something to poke at:

```sh
cd examples/hello-service
zig build test     # unit-tests the handlers
zig build run      # serves on http://127.0.0.1:8081
```

## 1. Create a project

```sh
mkdir my-service && cd my-service
zig init
```

## 2. Add Zax as a dependency

Fetch Zax into your `build.zig.zon` (this writes a `.url` + `.hash` entry):

```sh
zig fetch --save git+https://github.com/<you>/zax
```

Or, for a local checkout (what the example does), edit `build.zig.zon` by hand:

```zig
.dependencies = .{
    .zax = .{ .path = "../path/to/zax" },
},
```

## 3. Wire the module in `build.zig`

```zig
const zax = b.dependency("zax", .{
    .target = target,
    .optimize = optimize,
}).module("zax");

const exe = b.addExecutable(.{
    .name = "my-service",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zax", .module = zax } },
    }),
});
```

## 4. Write the service

Zax uses Zig 0.16's "Juicy Main" — the runtime hands you an allocator and an Io.

```zig
const std = @import("std");
const zax = @import("zax");

const Store = struct { greeting: []const u8 };
const Api = zax.App(*const Store);

fn health() zax.Response {
    return zax.Response.text("ok\n");
}

// Handlers are plain functions whose parameters are extractors.
fn greet(
    s: zax.State(*const Store),
    p: zax.Path(struct { name: []const u8 }),
    a: zax.Alloc, // request arena, for building the response body
) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "Hi {s}, {s}\n", .{ p.value.name, s.value.greeting });
    return zax.Response.text(body);
}

pub fn main(init: std.process.Init) !void {
    var store = Store{ .greeting = "welcome" };
    var app = try Api.init(init.gpa, &store, .{});
    defer app.deinit();

    try app.get("/health", health);
    try app.get("/greet/:name", greet);

    try app.serve(init.io, .{ .ip4 = .loopback(8080) });
}
```

### Extractors

Each handler parameter is filled from the request. A **body** extractor (`Json`)
must be the **last** parameter (enforced at compile time).

| Extractor | Binds |
|---|---|
| `Path(T)` | path params (`/users/:id`) → struct fields or a scalar |
| `Query(T)` | query string → struct fields (`?T` = optional) |
| `Json(T)` | JSON body (arena-parsed) — must be last |
| `State(T)` | read-only app state |
| `Alloc` | the per-request arena allocator |
| `Forwarded` | proxied scheme/host/client-ip (see HTTPS) |
| `Form(T)` | urlencoded body → struct (must be last) |
| `Cookies` | request cookies via `.get(name)` |
| `Bytes` | raw request body |

Handlers return anything `IntoResponse`: a `Response`, a `Status`, a byte-string,
or a type with `pub fn intoResponse(self) Response`. A returned error → `500`.

### Middleware

```zig
fn poweredBy(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const r = try next.run();                       // continue the chain
    return r.withHeader(ctx.arena, "x-powered-by", "zax");
}

try app.use(&poweredBy);
```

Return a response *without* calling `next` to short-circuit (e.g. auth → 401).

### Per-route middleware

`app.getWith(pattern, .{ &mwA, &mwB }, handler)` (also `postWith`/`putWith`/
`deleteWith`/`routeWith`) runs middleware for that route only — after the global
chain, before the handler, in tuple order.

### Errors

Return a canonical error to produce a status, or let an extractor failure map
itself:

```zig
fn getUser(s: zax.State(*const Store), p: zax.Path(struct { id: u64 })) !zax.Response {
    if (p.value.id == 0) return error.NotFound; // -> 404
    return zax.Response.text("found\n");
}
```

A bad `:id` (non-numeric) is a `400`, a malformed `Json` body a `422`. Customize
error bodies with `app.onError(&renderFn)`.

### Fallback

`app.fallback(handler)` handles unmatched requests (custom 404 or SPA index); it
runs through the global middleware chain.

### Wildcard / catch-all routes

`*name` captures the rest of the path (with slashes) into one param — useful for
serving a static directory: `app.get("/assets/*path", handler)` with
`Path(struct { path: []const u8 })`. Catch-all must be last and does not match
the bare prefix.

### Responses

`Response.text` / `.html` / `.json(arena, value)` / `.redirect(.found, "/path")` /
`.fromStatus(.created)` cover the common cases; `r.withHeader(arena, n, v)` adds
headers. For large or generated bodies, `Response.stream(Ctx, ctx, fn, "text/plain")`
writes the body incrementally (connection-close, no Content-Length). `Response.sse(Ctx, ctx, fn)`
streams Server-Sent Events: `fn` gets an `Sse` writer and calls
`s.send(.{ .event = "...", .data = "..." })` per event.

Serve files with the `Files` extractor: `files.file("static/app.css")` or the
traversal-safe `files.dir("static", requested)`.

### Limits & timeouts

Harden the server via options: `max_body_size` (413 over-limit), `read_timeout_ms`
(408 on slow requests), `idle_timeout_ms` (close idle keep-alive connections):

```zig
var app = try Api.init(init.gpa, &store, .{
    .max_body_size = 1 << 20,
    .read_timeout_ms = 15_000,
    .idle_timeout_ms = 30_000,
});
```

## 5. Validate

**Unit-test handlers without a server.** Each extractor is a struct with a public
`value` field, so construct them directly and call the handler:

```zig
test "greet handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = Store{ .greeting = "hi" };
    const r = try greet(
        .{ .value = &store },              // State(*const Store)
        .{ .value = .{ .name = "ada" } },  // Path(struct{ name })
        .{ .value = arena.allocator() },   // Alloc
    );
    try std.testing.expectEqualStrings("Hi ada, hi\n", r.body);
}
```

```sh
zig build test
```

**Run it and hit the routes:**

```sh
zig build run
# in another shell:
curl localhost:8080/health
curl localhost:8080/greet/ada
```

## 6. Production HTTPS

std 0.16 has no server TLS. Terminate TLS at a reverse proxy and run Zax
plaintext on localhost; enable `.trust_forwarded = true` and read `zax.Forwarded`.
See [`deploy-https.md`](deploy-https.md).

## Next

- API reference and design notes: [`../README.md`](../README.md)
- Verified 0.16.0 primitives Zax is built on: [`zig016-api-notes.md`](zig016-api-notes.md)
- Performance: `zig build bench` (read the caveats).
