# The evented backend (`serveEvented`)

zax ships two server backends:

- **`app.serve(io, addr)`** — the **default**: `std.Io.Threaded`, one OS thread per connection.
  Portable (every platform), simple, great median latency.
- **`app.serveEvented(io, addr, opts)`** — **opt-in**: a non-blocking epoll/kqueue reactor with
  N shared-nothing workers and `SO_REUSEPORT`. Dramatically higher throughput and a flat tail
  under load. Linux (epoll) + macOS/BSD (kqueue).

Both run the *same* handlers, router, middleware, extractors, and observers — only the IO layer
differs. Switching backends is one call; your application code doesn't change.

## When to use which

- **`serve` (default):** simplest deployments, lowest median latency, any platform, handlers
  that do blocking IO, or true keep-alive streaming with the push `streamer`.
- **`serveEvented`:** high connection counts / high throughput, latency-tail-sensitive services.
  Requires handlers to be non-blocking (see limitations).

## Usage

```zig
pub fn main(init: std.process.Init) !void {
    var app = try App(*Db).init(init.gpa, &db, .{});
    defer app.deinit();
    try app.get("/", hello);

    // Threaded (default, portable):
    // try app.serve(init.io, .{ .ip4 = .loopback(8080) });

    // Evented (opt-in; Linux + macOS/BSD):
    try app.serveEvented(init.io, .{ .ip4 = .loopback(8080) }, .{ .workers = 0 });
}
```

`EventedOptions`:
- `workers: usize = 0` — number of worker threads. `0` = the CPU **affinity** count
  (`sched_getaffinity` / online CPUs), so it respects `taskset`/cgroup/container limits.
- `max_connections: usize = 1024` — per-worker cap; excess connections are shed (accept+close).

The rest comes from the app's existing `Options` (buffer sizes, `keep_alive`,
`max_keep_alive_requests`, `max_body_size`, `read_timeout_ms`, `idle_timeout_ms`, `tcp_nodelay`,
`request_id`).

`serveEvented` returns `error.EventedUnsupported` on platforms without a poller backend
(Windows/WASM); use `serve` there.

## Performance

Core-pinned cross-framework benchmarks (see `benchmarks/cross/results.md`) consistently show the
evented backend as the **throughput and p99.9 leader**, scaling with cores:

| metric | `serve` (threaded) | `serveEvented` | axum (tokio) |
|---|---|---|---|
| throughput | baseline | **~1.7–1.9× axum** | — |
| p99.9 | tens of ms (thread-park tail) | **sub-ms, best-in-class** | sub-ms |
| median (p50) | best | excellent | higher |

The threaded backend's multi-ms p99.9 tail (a `std.Io.Threaded` thread-park artifact) is
eliminated by the reactor. The only metric where tokio can edge the reactor is worst-case `max`
on overcommitted cloud VMs (work-stealing vs shared-nothing — see limitations).

## Streaming

For large or unbounded bodies, use the pull streamer (`streamPull`) — it streams in bounded
chunks without buffering the whole body, with backpressure, on both backends:

```zig
fn download(/* ... */) zax.Response {
    return zax.Response.streamPull(ctx, struct {
        fn next(c: *anyopaque, buf: []u8) zax.PullResult {
            const self: *MyState = @ptrCast(@alignCast(c));
            const n = self.read(buf);            // fill buf with the next chunk
            if (n == 0) return .done;             // end of stream
            return .{ .chunk = n };
        }
    }.next);
}
```

`nextFn` should return `.chunk = n` (n>0) when data is ready, or `.done` at end. Streamed
responses use connection-close framing (the connection closes after the body). For sparse,
long-idle event streams (SSE waiting on external events), prefer the threaded backend in this
version — a producer returning `.chunk = 0` to mean "nothing yet" busy-polls on the reactor.

## Limitations

See "Evented backend status" in `docs/superpowers/specs/2026-06-17-evented-reactor-design.md`.
The key one: **handlers must not block** under `serveEvented` (a blocking handler stalls its
worker's whole event loop) — use sync/compute-only extractors.
