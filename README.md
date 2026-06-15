# Zax

An [Axum](https://github.com/tokio-rs/axum)-style HTTP web framework for **Zig 0.16.0**.
Typed handlers, comptime extractors, a radix router, read-only shared state, and
graceful shutdown — built from scratch on the new `std.Io` interface.

```zig
const zax = @import("zax");

fn index() zax.Response {
    return zax.Response.text("Hello from Zax\n");
}

fn getUser(p: zax.Path(struct { id: u64 }), a: zax.Alloc) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "user {d}\n", .{p.value.id});
    return zax.Response.text(body);
}

pub fn main(init: std.process.Init) !void {
    var app = try zax.App(*const Db).init(init.gpa, &db, .{});
    defer app.deinit();
    try app.get("/", index);
    try app.get("/users/:id", getUser);
    try app.serve(init.io, .{ .ip4 = .loopback(8080) });
}
```

## Why 0.16.0

Zax is built on genuinely-new 0.16.0 capabilities (verified against the shipped
compiler — see [`docs/zig016-api-notes.md`](docs/zig016-api-notes.md)):

- **`std.Io` as an interface.** The server takes a `std.Io` value the same way
  other code takes an `Allocator`. It names no concrete backend, so the same
  framework code runs on `Io.Threaded` (thread pool) today and a future
  `Io.Evented` (io_uring/kqueue) unchanged — your middleware and handlers are
  portable across the concurrency model.
- **"Juicy Main."** `pub fn main(init: std.process.Init)` hands you a ready
  allocator (`init.gpa`) and Io (`init.io`) — no manual GPA/event-loop setup.
- **Comptime signature reflection.** Handlers are plain functions; Zax inspects
  their parameter types at compile time (`@typeInfo(...).@"fn".params` +
  `std.meta.ArgsTuple`) and wires each to an extractor. Zero runtime dispatch.

## Extractors

A handler is any function whose parameters are extractor types. They are filled
in declaration order; the order maps to nothing magic except that a **body
extractor must come last** (enforced at compile time).

| Extractor | Binds |
|---|---|
| `Path(T)` | URL path params (`/users/:id`) → struct fields or a scalar |
| `Query(T)` | query string → struct fields (optional fields = `?T`) |
| `Json(T)` | request body parsed as JSON (arena-allocated) — must be last |
| `State(T)` | the app's read-only shared state (no locks, no refcount) |
| `Alloc` | the per-request arena allocator, for building response bodies |

Handlers return anything that satisfies `IntoResponse`: a `Response`, a `Status`,
a byte-string, or a custom type with `pub fn intoResponse(self) Response`. A
returned error becomes a `500`.

## Design notes

- **Zero-copy.** The HTTP/1.1 parser and router return `[]const u8` slices
  pointing into the connection read buffer — no heap copies for methods,
  headers, path params, or query values. `Json` is the only allocating
  extractor. Borrowed slices are valid for the request's lifetime only.
- **Per-request arena.** Each connection gets its own `ArenaAllocator` over a
  backing allocator, freed wholesale at end of request. Because each request
  owns its arena, there is no cross-thread arena sharing.
- **Graceful drain.** `app.requestShutdown(io)` stops accepting (it closes the
  listening socket, which unblocks `accept`) and the accept loop then awaits an
  `Io.Group` of in-flight connections before returning.

## Run

```sh
zig build test     # 34 tests
zig build run      # demo server on :8080
```

```sh
curl localhost:8080/                              # Hello from Zax
curl localhost:8080/users/42                      # user 42
curl -X POST localhost:8080/users -d '{"name":"ada"}'   # zax-demo: created user ada
```

## Status & limitations (v1)

v1 is a core vertical slice. Designed-for but not yet built: TLS, a
tower-style middleware/layer chain, `Headers`/`Form`/`Cookie` extractors, a full
rejection-type taxonomy, HTTP keep-alive (responses currently send
`connection: close`), and the experimental `Io.Evented` backend (its std
networking is incomplete in 0.16.0, so Zax runs on `Io.Threaded`).

A `SIGINT`/`SIGTERM` handler is not auto-installed (`Io.Threaded` itself uses
signals for cancellation); wire one to call `app.requestShutdown(io)`.
