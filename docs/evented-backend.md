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
const Body = struct {
    // ...your producer state...
    fn next(self: *Body, buf: []u8) zax.PullResult {
        const n = self.read(buf);                 // fill buf with the next chunk
        if (n == 0) return .done;                 // end of stream
        return .{ .chunk = n };
    }
};

fn download(body: *Body) zax.Response {
    // streamPull(comptime Ctx, *Ctx, nextFn, content_type)
    return zax.Response.streamPull(Body, body, Body.next, "application/octet-stream");
}
```

`nextFn` should return `.chunk = n` (n>0) when data is ready, `.chunk = 0` when no data is
ready yet (sparse/long-idle streams, e.g. SSE waiting on external events), or `.done` at end.
Streamed responses use connection-close framing (the connection closes after the body).

On the evented backend a `.chunk = 0` parks the connection on the timer wheel and re-polls
after `EventedOptions.stream_repoll_ms` (default 5 ms; `0` = the legacy busy behavior) — it
does **not** busy-spin the reactor (since v0.3.0), so sparse SSE works on evented. Note the
`sse()` helper and the push `stream` streamer are Writer-based and **threaded-only**; for SSE
on the evented backend, drive `streamPull` directly or use `ssePull` (below).

`EventedOptions.stream_idle_timeout_ms` (default `0` = disabled) hard-closes a pull stream
(`streamPull` / `ssePull`) that produces no data for that many milliseconds. When triggered,
the connection is truncated (no `0\r\n\r\n` chunked terminator) so the client detects an
incomplete stream. This composes with `stream_repoll_ms` — the re-poll cadence is the check
granularity. Evented backend only.

### Server-Sent Events on the evented backend

The push `sse()` helper is threaded-only (it writes to a blocking writer). For SSE on the
evented backend, use the pull-model `ssePull` — `nextFn` returns one `SsePull` step at a time
and zax frames it:

```zig
const Feed = struct {
    fn next(self: *Feed) zax.SsePull {
        if (self.poll()) |ev| return .{ .event = .{ .data = ev } };
        if (self.ended) return .done;
        return .not_ready;   // nothing yet — parks on the timer wheel (no busy-spin)
    }
};

fn events(feed: *Feed) zax.Response {
    return zax.Response.ssePull(Feed, feed, Feed.next);
}
```

`not_ready` emits a 0-byte chunk: on evented it parks the connection and re-polls after
`stream_repoll_ms`; on threaded it loops, so for sparse streams on the threaded backend prefer
the push `sse()` helper. A single event larger than the write buffer yields an error and closes
the connection.

### Keep-alive after a stream (chunked transfer-encoding)

Streamed responses are sent with **`Transfer-Encoding: chunked`** and keep the connection alive
when the client is HTTP/1.1 and persistent (the default unless it sent `Connection: close`). The
connection is then reused for the next request. HTTP/1.0 clients, `Connection: close`, exceeding
`max_keep_alive_requests`, or a server with keep-alive disabled fall back to connection-close
framing. This applies to all streaming APIs (`stream`, `sse`, `streamPull`, `ssePull`) on both
backends; a not-ready (`chunk(0)`) producer never emits a zero-length chunk (only end-of-stream does).

## Limitations

See "Evented backend status" in `docs/superpowers/specs/2026-06-17-evented-reactor-design.md`.
The key one: **handlers must not block** under `serveEvented` (a blocking handler stalls its
worker's whole event loop) — use sync/compute-only extractors.
