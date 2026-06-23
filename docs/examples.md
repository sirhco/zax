# Examples cookbook

Each example under [`examples/`](../examples) is a standalone package that depends on
this repo by relative path, so it always tracks the local source:

```zig
// build.zig.zon
.dependencies = .{ .zax = .{ .path = "../.." } },
```

Run any example with `cd examples/<name> && zig build run`, and unit-test its handlers
with `zig build test`. Copy a directory out of the repo and swap the path dependency for
a `zig fetch --save git+https://…/zax` URL to use it as a starting point.

## [hello-service](../examples/hello-service)

The minimal app. Demonstrates `State`, `Path`, `Query`, `Json`, and `Alloc` extractors,
a response-stamping middleware (`poweredBy` stamps every reply with `x-powered-by: zax`),
and handler unit tests that call handlers directly with constructed extractor values — no
sockets, no server, fast and deterministic. **Start here.**

```
cd examples/hello-service && zig build run   # http://127.0.0.1:8081
```

Key file: [`src/main.zig`](../examples/hello-service/src/main.zig).

## [todo-api](../examples/todo-api)

A REST/CRUD JSON API. Shows **mutable shared state** done safely: `App(*Store)` with an
atomic spinlock (`std.atomic.Value(bool)` + `cmpxchgWeak`; `std.Thread.Mutex` was removed in Zig 0.16).
Store methods copy results into the request arena under the lock so handlers serialize
JSON lock-free and immune to concurrent mutation.

Also demonstrates real HTTP status codes (201/204/404), Prometheus `/metrics` via
`zax.Metrics`, and an access log on stderr via `zax.AccessLogger` — both wired with
`app.observe`.

```
cd examples/todo-api && zig build run   # http://127.0.0.1:8082
```

Key file: [`src/main.zig`](../examples/todo-api/src/main.zig).

## [auth-sessions](../examples/auth-sessions)

Cookie sessions + a **guard middleware**. `POST /login` issues a random token and sets it
with `Response.withCookie` (HttpOnly, SameSite=Lax); `POST /logout` expires it.
A `Chain` middleware (`requireAuth`) reads the `Cookies` extractor and short-circuits
with `401` when the session is missing or invalid; it is attached per-route with
`app.getWith("/me", .{&requireAuth}, me)`.

Sessions are stored in a `StringHashMap` behind the same atomic spinlock pattern as `todo-api`.

```
cd examples/auth-sessions && zig build run   # http://127.0.0.1:8083
```

Key file: [`src/main.zig`](../examples/auth-sessions/src/main.zig).

## [file-upload](../examples/file-upload)

`multipart/form-data` uploads + static serving. The `Multipart` body extractor (must be
the last parameter) parses the uploaded file; the filename is sanitized against path
traversal by stripping everything up to the last `/`. `Files.dir` serves the saved file
back under `GET /files/:name`.

```
cd examples/file-upload && zig build run   # http://127.0.0.1:8084
```

Key file: [`src/main.zig`](../examples/file-upload/src/main.zig).

## [websocket-live](../examples/websocket-live)

A WebSocket echo endpoint that runs on **both** `app.serve` (threaded) and
`app.serveEvented` (reactor) with the same handler — pass `-- evented` to switch
backends at runtime. `onUpgrade(.{ .on_message = onMessage })` delivers whole
reassembled messages; ping/pong and the close handshake are automatic.

A lock-free atomic counter (`std.atomic.Value(usize)`) tracks total messages echoed
across all connections; `conn.state(*Counter)` reaches it from within the WebSocket
callback. `GET /stats` exposes the live count.

```
cd examples/websocket-live && zig build run             # ws://127.0.0.1:8085/ws (threaded)
cd examples/websocket-live && zig build run -- evented  # evented backend
```

Key file: [`src/main.zig`](../examples/websocket-live/src/main.zig).

## See also

- [Getting started](getting-started.md) — set up a project from scratch.
- [README](../README.md) — the full feature reference.
- [Evented backend](evented-backend.md) — when to use `serveEvented`.
