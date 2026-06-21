# Zax

[![CI](https://github.com/sirhco/zax/actions/workflows/ci.yml/badge.svg)](https://github.com/sirhco/zax/actions/workflows/ci.yml)

An [Axum](https://github.com/tokio-rs/axum)-style HTTP web framework for **Zig 0.16.0**.
Typed handlers, comptime extractors, a radix router, read-only shared state, and
graceful shutdown — built from scratch on the new `std.Io` interface.

**New here?** Read [`docs/getting-started.md`](docs/getting-started.md) and run the
standalone consumer in [`examples/hello-service/`](examples/hello-service).

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
| `Path(T)` | path params (`/users/:id`) → struct fields or a scalar (percent-decoded) |
| `Query(T)` | query string → struct fields (`?T` = optional, percent-decoded) |
| `Json(T)` | request body parsed as JSON (arena-allocated) — must be last |
| `State(T)` | the app's read-only shared state (no locks, no refcount) |
| `Alloc` | the per-request arena allocator, for building response bodies |
| `Forwarded` | proxied connection info (`scheme`/`host`/`client_ip`) from `X-Forwarded-*` |
| `Form(T)` | urlencoded request body → struct fields (must be last) |
| `Cookies` | request cookies via `.get(name)` |
| `Bytes` | the raw request body (`[]const u8`, must be last) |
| `Files` | serve files: `files.file(path)` / `files.dir(root, requested)` (traversal-safe) |

Handlers return anything that satisfies `IntoResponse`: a `Response`, a `Status`,
a byte-string, or a custom type with `pub fn intoResponse(self) Response`. A
returned error becomes a `500`.

## Middleware

Register an ordered chain wrapping matched route handlers. A middleware gets the
context and a `*Next` cursor; calling `next.run()` continues the chain. This
covers pass-through, **short-circuit** (return without `next` — e.g. auth), and
**post-processing** (call `next`, then mutate the response).

```zig
const Api = zax.App(*const Db);

fn requestId(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    const r = try next.run();
    return r.withHeader(ctx.arena, "x-request-id", "…");
}

try app.use(&requestId);
```

Middleware run after routing, so `404`/`405` short-circuit before the chain.

### Per-route middleware

`getWith` / `postWith` / `putWith` / `deleteWith` (and the generic `routeWith`)
attach middleware to a single route. They run after the global chain and before
the handler, in tuple order:

```zig
fn requireAuth(ctx: *const Api.Context, next: *Api.Next) anyerror!zax.Response {
    if (ctx.req.header("authorization") == null) return zax.Response.fromStatus(.unauthorized);
    return next.run();
}

try app.getWith("/admin", .{&requireAuth}, adminHandler);
try app.get("/", homeHandler); // unchanged, no per-route middleware
```

### Route groups

`app.group(prefix, .{ ...middleware })` returns a group that shares a path prefix
and middleware across its routes. Groups nest and reuse the same verbs
(`get`/`post`/… and `getWith`/…). Order is global → group → route → handler:

```zig
const api = app.group("/api", .{&requireAuth});
try api.get("/users", listUsers);      // GET /api/users (global -> requireAuth -> handler)

const v1 = api.group("/v1", .{&requestId});
try v1.post("/items", createItem);     // POST /api/v1/items
```

## Observability

`app.observe(obs)` registers an `zax.Observer` that fires after every routed
request — matched routes, 404, 405, and handler errors — including after streamed
responses. (Parse/transport-level failures that close the connection before
routing — malformed head, read timeout, oversized or chunked body — have no
parsed request and are not observed.)
Multiple observers may be registered; they run in registration order. Zero
overhead when none are registered.

Each observer receives a `zax.AccessRecord`:

| Field | Type | Description |
|---|---|---|
| `method` | `zax.Method` | HTTP method |
| `path` | `[]const u8` | request path (slice into the read buffer) |
| `status` | `u16` | response status code |
| `duration_ns` | `u64` | dispatch + write time in nanoseconds |
| `bytes` | `usize` | buffered response body length (0 for streamed responses) |

The built-in `zax.AccessLogger` is thread-safe and writes one line per request.
Default format is `.text` (`GET /users/42 200 0.412ms 18b`); set `.json` for
newline-delimited JSON (`{"method":"GET","path":"/users/42","status":200,"dur_us":412,"bytes":18}`).
Call `logger.observer()` to get the `Observer` to pass to `app.observe`.

```zig
pub fn main(init: std.process.Init) !void {
    var app = try zax.App(*const Db).init(init.gpa, &db, .{});
    defer app.deinit();

    var stderr_writer = init.io.stderr(); // std.Io.Writer
    var logger = zax.AccessLogger{ .writer = &stderr_writer, .format = .text };
    try app.observe(logger.observer());

    try app.get("/users/:id", getUser);
    try app.serve(init.io, .{ .ip4 = .loopback(8080) });
}
```

> **Streamed-bytes caveat:** `bytes` is the buffered response body length; it is
> `0` for streamed responses (`Response.stream` / `Response.sse`) because the
> streamed body bytes are not counted.

### Request IDs

Enable per-request correlation IDs with `.{ .request_id = true }`:

```zig
var app = try zax.App(*const Db).init(init.gpa, &db, .{ .request_id = true });
```

When enabled, each request is assigned an ID: a validated incoming `x-request-id`
header is accepted if it is 1–128 characters with charset `[A-Za-z0-9._-]`; an
absent or unsafe header causes a 16-hex-digit ID to be generated instead (per-app
atomic counter). The ID is:

- accessible in handlers via the `zax.RequestId` extractor (`rid.value`) or
  directly as `ctx.request_id`;
- echoed on the response as the `x-request-id` header;
- included in access-log records (`id=…` text / `"request_id":"…"` JSON) when an
  `AccessLogger` is registered.

Incoming IDs are validated against a safe charset before being echoed or logged,
preventing CRLF response-header injection and log-injection attacks.

```zig
fn echoId(rid: zax.RequestId, a: zax.Alloc) !zax.Response {
    const body = try std.fmt.allocPrint(a.value, "request id: {s}\n", .{rid.value});
    return zax.Response.text(body);
}
```

Off by default — zero overhead and identical behavior when disabled.

### Metrics

`zax.Metrics` is a built-in observer that aggregates request outcomes into
lock-free atomic counters. Wire it the same way as `AccessLogger`:

```zig
var metrics = zax.Metrics{};
try app.observe(metrics.observer());
```

It tracks (thread-safely, from the post-response hook):

- **Total requests** and **per-status-class counters** (`1xx`–`5xx`)
- **Total response bytes** (buffered; `0` for streamed responses)
- **Request-latency histogram** using the Prometheus default buckets
  (0.005 s, 0.01 s, 0.025 s … 10 s)

> In-flight request count is **not** tracked — the hook fires after the
> response is written.

**Point-in-time snapshot** (plain `u64`s, no atomics):

```zig
const snap: zax.MetricsSnapshot = metrics.snapshot();
// snap.total, snap.class[2], snap.bytes_total, snap.duration_sum_ns, snap.buckets[…]
```

**Prometheus text exposition** — call `metrics.writePrometheus(writer)` where
`writer` is a `*std.Io.Writer`. It emits:

- `zax_requests_total{class="Nxx"} N` (one line per class)
- `zax_response_bytes_total N`
- `zax_request_duration_seconds` histogram (`_bucket{le="…"}` cumulative,
  `_sum`, `_count`)

There is **no built-in `/metrics` route** — serve it yourself with a small
handler. Access `metrics` via app state or a module-level variable:

```zig
var METRICS = zax.Metrics{};

fn metricsHandler(a: zax.Alloc) !zax.Response {
    var w = std.Io.Writer.Allocating.init(a.value);
    try METRICS.writePrometheus(&w.writer);
    return .{ .status = .ok, .content_type = "text/plain; version=0.0.4", .body = w.written() };
}

// in main, after creating app:
try app.observe(METRICS.observer());
try app.get("/metrics", metricsHandler);
```

## Fallback

Register a handler for requests that match no route — a custom 404 or an SPA
index fallback. It runs through the global middleware chain (not-found only;
method-not-allowed still returns 405):

```zig
fn notFound() zax.Response { return zax.Response.fromStatus(.not_found); }
try app.fallback(notFound);

// SPA: serve index.html for any unknown path
fn spa(files: zax.Files) !zax.Response { return files.file("static/index.html"); }
try app.fallback(spa);
```

## Wildcard routes

A `*name` segment is a catch-all: it matches one or more remaining path
segments and captures the tail (slashes included) into `name`. It must be the
last segment, and does not match the bare prefix (`/assets/*path` matches
`/assets/a/b` but not `/assets`). Static and `:param` routes take priority.

```zig
fn serveAsset(p: zax.Path(struct { path: []const u8 }), files: zax.Files) !zax.Response {
    return files.dir("static", p.value.path);
}
try app.get("/assets/*path", serveAsset);
// GET /assets/css/app.css -> path = "css/app.css"
```

## Design notes

- **Zero-copy.** The HTTP/1.1 parser and router return `[]const u8` slices
  pointing into the connection read buffer — no heap copies for methods,
  headers, path params, or query values. `Json` is the only allocating
  extractor. Borrowed slices are valid for the request's lifetime only.
- **Per-request arena.** Each connection gets its own `ArenaAllocator` over a
  backing allocator, freed wholesale at end of request. Because each request
  owns its arena, there is no cross-thread arena sharing.
- **Per-connection keep-alive.** Persistent HTTP/1.1 connections (Content-Length
  framing); the arena is reset between requests and the read buffer reused via
  `toss`/`rebase`. Honors `Connection`. Inbound `Transfer-Encoding: chunked`
  request bodies are decoded (bounded by `max_body_size`); streamed responses use
  chunked framing to keep the connection alive on HTTP/1.1 persistent clients.
- **`TCP_NODELAY` on every connection.** Nagle's algorithm is disabled so small
  responses are sent immediately instead of being held for the peer's delayed
  ACK (~40 ms) — standard for low-latency HTTP servers.
- **Graceful drain.** `app.requestShutdown(io)` stops accepting (it closes the
  listening socket, which unblocks `accept`) and the accept loop then awaits an
  `Io.Group` of in-flight connections before returning.

## HTTPS

std 0.16 has no server-side TLS, so terminate TLS at a reverse proxy
(nginx/Caddy/Cloudflare) and run Zax plaintext on localhost. Enable
`.trust_forwarded = true` and read `zax.Forwarded` for the real scheme/host/IP.
See [`docs/deploy-https.md`](docs/deploy-https.md).

## Run

```sh
zig build test     # full unit + integration suite
zig build run      # demo server on :8080
zig build bench    # micro + loopback load benchmarks (ReleaseFast); warmup + multi-sample
```

```sh
curl localhost:8080/                              # Hello from Zax
curl localhost:8080/users/42                      # user 42
curl -X POST localhost:8080/users -d '{"name":"ada"}'   # zax-demo: created user ada
```

## Error handling

Extractor failures and handler errors map to real HTTP statuses (not a blanket
500). Handlers raise typed statuses with the canonical `zax.Error` set:

```zig
fn getUser(s: zax.State(*const Db), p: zax.Path(struct { id: u64 })) !zax.Response {
    const user = s.value.lookup(p.value.id) orelse return error.NotFound; // -> 404
    return zax.Response.text(user.name);
}
```

A non-numeric `:id` becomes `400`, a malformed `Json` body `422`, `error.Conflict`
`409`, and any unrecognized error `500`. Customize rendering (e.g. JSON bodies)
with one hook:

```zig
fn renderError(e: anyerror, info: zax.ErrorInfo, ctx: *const Api.Context) zax.Response {
    _ = e;
    const body = std.fmt.allocPrint(ctx.arena, "{{\"error\":\"{s}\"}}", .{info.reason}) catch
        return zax.Response.fromStatus(info.status);
    var r = zax.Response.jsonRaw(body);
    r.status = info.status;
    return r;
}

app.onError(&renderError); // applies to extractor, handler, 404, and 405 responses
```

Note: classification keys off the error value, so handlers should use the
canonical `zax.Error` set; an unrecognized error is treated as `500`, and
`on_error` can re-classify by inspecting the raw error. The full standard HTTP
status set is supported as `Status` variants (`.gone`, `.unsupported_media_type`,
`.not_acceptable`, `.precondition_failed`, `.bad_gateway`, `.gateway_timeout`,
and more). For arbitrary or non-standard codes, use `Response.fromCode(u16)`.
The expanded `zax.Error` set covers all common handler-facing statuses; each
variant maps to a canonical status via `classify`.

## Responses

Build responses with the `Response` constructors:

| Constructor | Result |
|---|---|
| `Response.text(s)` | `text/plain` body |
| `Response.html(s)` | `text/html` body |
| `Response.json(arena, value)` | JSON-serialized body (`application/json`) |
| `Response.jsonRaw(s)` | pre-serialized JSON string |
| `Response.stream(Ctx, ctx, fn, ct)` | push-streamed body written by `fn` |
| `Response.sse(Ctx, ctx, fn)` | push-streamed Server-Sent Events |
| `Response.streamPull(Ctx, ctx, nextFn)` | pull-streamed body (backpressure-aware; both backends) |
| `Response.ssePull(Ctx, ctx, nextFn)` | pull-streamed Server-Sent Events (both backends) |
| `Response.redirect(status, loc)` | redirect with a `Location` header |
| `Response.seeOther/temporaryRedirect/permanentRedirect(loc)` | 303 / 307 / 308 redirects |
| `Response.fromStatus(s)` | bare status |
| `r.withHeader(arena, name, value)` | add a response header |

A streamed response writes its body incrementally to the connection; the `ctx`
must be arena-allocated. Useful for large or generated bodies. On HTTP/1.1
persistent clients the body is framed with **`Transfer-Encoding: chunked`** and
the connection is kept alive; HTTP/1.0, `Connection: close`, or a keep-alive-
disabled server fall back to connection-close framing.

```zig
const Lines = struct { n: usize };
fn writeLines(c: *const Lines, w: *zax.Writer) anyerror!void {
    var i: usize = 0;
    while (i < c.n) : (i += 1) try w.print("line {d}\n", .{i});
}
fn handler(a: zax.Alloc) !zax.Response {
    const c = try a.value.create(Lines);
    c.* = .{ .n = 100 };
    return zax.Response.stream(Lines, c, writeLines, "text/plain");
}
```

For Server-Sent Events, `Response.sse(Ctx, ctx, fn)` sets `text/event-stream` and
hands the handler an `Sse` writer (each `send` is flushed):

```zig
const Feed = struct { n: usize };
fn feed(f: *const Feed, s: *zax.Sse) anyerror!void {
    var i: usize = 0;
    while (i < f.n) : (i += 1) try s.send(.{ .event = "tick", .data = "hi" });
}
fn handler(a: zax.Alloc) !zax.Response {
    const f = try a.value.create(Feed);
    f.* = .{ .n = 10 };
    return zax.Response.sse(Feed, f, feed);
}
```

`stream` and `sse` are **push** streamers — the handler drives a `Writer` and
blocks the worker while producing. For non-blocking, backpressure-aware streaming
that runs on **both backends** (threaded and the evented reactor), use the
**pull** model: `Response.streamPull(Ctx, ctx, nextFn)` and
`Response.ssePull(Ctx, ctx, nextFn)`. `nextFn` is called whenever the connection
can accept more bytes and returns the next chunk, `not_ready` (no data yet), or
`done`:

```zig
const Feed = struct { i: usize, n: usize };
fn next(f: *Feed, buf: []u8) zax.PullResult {
    if (f.i >= f.n) return .done;
    if (!ready()) return .{ .chunk = 0 }; // not ready yet — no busy-spin
    const w = std.fmt.bufPrint(buf, "row {d}\n", .{f.i}) catch return .err;
    f.i += 1;
    return .{ .chunk = w.len };
}
fn handler(a: zax.Alloc) !zax.Response {
    const f = try a.value.create(Feed);
    f.* = .{ .i = 0, .n = 100 };
    return zax.Response.streamPull(Feed, f, next);
}
```

A `chunk = 0` (`not_ready`) producer does **not** busy-spin: the evented backend
parks the connection on its timer wheel and the threaded backend sleeps, both
re-polling every `stream_repoll_ms` (default 5 ms; `0` = legacy busy behavior).
Set `stream_idle_timeout_ms` (default `0` = off) to hard-close a stream that
produces no data for that long (truncated — no chunked terminator). These knobs
live on `Options` (threaded) and `EventedOptions` (evented).

Serve static files with the `Files` extractor — `files.file("static/index.html")`
for an explicit path, or `files.dir("static", requested)` to safely serve a
request-derived path under a root (rejects `..`/absolute → 404). Files are
buffered (Content-Length set), content-type inferred by extension.

## Limits & timeouts

Configurable via `ServerOptions`:

| Option | Default | Effect |
|---|---|---|
| `max_body_size` | `0` (buffer-bound) | Content-Length over the limit → `413` |
| `read_timeout_ms` | `30000` | full head+body must arrive within this once started → `408` |
| `idle_timeout_ms` | `60000` | max wait for the next keep-alive request → connection closed |

Request bodies are buffered in the read buffer, so they are bounded by
`read_buffer_size`; oversized header blocks return `431`. Set a timeout to `0` to
disable it.

## Performance

Zax aims for low per-request overhead, but treat that as a design goal backed by
specific measurements — not a benchmarked claim of being "fast" relative to
anything else. What is actually validated:

- **Zero-copy parsing** — unit tests assert parsed method/path/header/param
  slices alias the read buffer (pointer-range checks in `parser.zig`,
  `radix.zig`).
- **Zero heap allocation on the hot path** — a deterministic test runs
  parse → route → extract → handler → serialize with the request arena backed by
  a counting `FailingAllocator` and asserts **zero** backing allocations for a
  handler that uses no allocating extractor (`server.zig`). `Json` is the only
  extractor that allocates, and a contrast test confirms it does.
- **Reproducible micro + load benchmarks** — `zig build bench` (ReleaseFast)
  runs a discarded warmup pass then N timed samples, reporting
  `median ns/op +/- stddev` for micro-benchmarks and median throughput with
  latency percentiles for the end-to-end loopback run.
  Micro-benchmarks cover: HTTP head parse, radix match (static+param), response
  serialize, middleware chain (3 pass-throughs), wildcard and nested routing,
  and the `Path`/`Query`/`Json` extractors.
  The e2e section runs three named scenarios — static `GET /bench`, param
  `GET /users/:id`, and JSON `POST /echo` — each with throughput and latency
  percentiles.
  Configurable via flags forwarded after `--`:

  | Flag | Default | Meaning |
  |------|---------|---------|
  | `--iters N` | 2 000 000 | micro-benchmark loop size |
  | `--samples N` | 5 | timed passes (median is taken across these) |
  | `--warmup N` | 1 | discarded warmup passes (0 = skip) |
  | `--conns N` | 8 | keep-alive connections for e2e load |
  | `--reqs N` | 5 000 | requests per connection |

  Example: `zig build bench -- --conns 64 --reqs 2000 --samples 5 --warmup 1`

  `iters`, `conns`, `reqs`, and `samples` must be ≥ 1; a bad or zero value
  prints a usage line and exits nonzero.

- **Memory section** — after the throughput/latency output, a `-- memory
  (loopback, N conns x M reqs) --` section reports two figures:
  - `bytes/req` — cumulative bytes the server's allocator requested per
    request, reported per scenario (static GET / param GET / JSON POST).
    Includes amortized per-connection buffers; measured by wrapping the app
    allocator in a counting allocator; the loopback client is not counted.
    **Interpretability caveat:** at small request counts the per-connection
    buffer amortization dominates, so the three scenarios read nearly
    identical — cross-scenario differences only become meaningful at higher
    request counts.
  - `peak RSS` — process lifetime high-water mark (whole process, across all
    bench sections) in MB, via `getrusage`.

  These numbers are self-relative — not comparative against other frameworks
  or servers.

- **Regression check** — capture a baseline with `zig build bench -- --json > src/bench/baseline.json`
  (then recommit), then gate future runs with `zig build bench -- --check` (optionally
  `--tolerance 0.2` to widen the default 15% band). The check gates the stable metrics only —
  micro `ns/op` and per-scenario `bytes/req` — and exits nonzero on any regression. Throughput
  and latency are emitted in `--json` but not gated (loopback noise makes them environment-sensitive).
  The baseline encodes the numbers from the machine that generated it; use a stable CI runner or
  a local before/after on the same machine for meaningful results. Because the numbers are
  self-relative, a generous default tolerance (15%) is intentional.

**Read the benchmark caveats.** The e2e numbers are **loopback, in-process,
single-machine, and not comparative** — the client shares the process and Io
with the server, so throughput is inflated and sub-microsecond latency is below
the monotonic clock's resolution (p50 may print `0.0 us`). The micro ns/op
figures (amortized over millions of iterations) are the trustworthy ones. No
comparison against `std.http.Server`, http.zig, or non-Zig servers exists yet.

## Status & limitations

A focused HTTP/1.1 framework. **Shipped:** routing, comptime extractors,
keep-alive, middleware, graceful drain, HTTPS via reverse-proxy termination
(forwarded-header trust), request size limits, read/idle timeouts, and full
standard HTTP status support (the `Status` enum covers all IANA-registered codes;
`Response.fromCode(u16)` handles non-standard codes; the `zax.Error` set covers
all common handler-facing statuses).

CI runs `zig build test` on Linux (epoll) and macOS (kqueue) plus a bench compile-check on every push and PR.

Streaming is full-featured: push (`stream`/`sse`) and pull
(`streamPull`/`ssePull`) bodies, `Transfer-Encoding: chunked` with keep-alive,
inbound chunked request-body decoding, and a not-ready backoff + idle cap — on
both the threaded and evented backends.

**Not yet built:** in-process TLS (blocked on std — use a proxy), `Headers`
extractor, and HTTP/2. The evented reactor (`App.serveEvented`, epoll/kqueue) is
shipped and opt-in; the default backend remains `Io.Threaded`. (Zax's reactor is
its own epoll/kqueue loop — std's `Io.Evented` still can't serve TCP in 0.16.0.)

A `SIGINT`/`SIGTERM` handler is not auto-installed (`Io.Threaded` uses signals
for cancellation) — wire one to call `app.requestShutdown(io)`.
