# Design spec — bounded in-flight connections (worker-pool cap)

Theme G (revised). Closes the latency-tail gap surfaced by the cross-framework bench
without an architecture change. Read first: `2026-06-17-evented-io-decision.md` (why not
evented IO) and `benchmarks/cross/results.md` (the ~50× p99.9/max tail).

## Problem

zax's `acceptLoop` (`src/server.zig:277`) dispatches every accepted connection with
`conn_group.async(io, handleConn, …)` — **unbounded**. Under `std.Io.Threaded` that is one
OS thread per live connection. With connections > cores the threads oversubscribe the CPU;
the 1-in-1000 request that loses the scheduler lottery spikes to tens of ms. Measured: zax
median ~0.086ms (best of zax/axum/go) but p99.9/max ~36/51ms — **~50× axum/go**, which stay
flat because their schedulers cap concurrency to cores. This is the thread-per-conn
oversubscription signature, confirmed by the A/B that ruled out Nagle.

## Goal

Bound the number of **in-flight connections** so the live-thread count stays near the core
count, flattening the tail — same concurrency model, no rewrite, purely additive.

## Design

### New Option
`src/server.zig` `Options` (~L39), alongside `keep_alive`, `max_keep_alive_requests`:
```zig
/// Cap concurrent in-flight connections (backpressure). When this many
/// connections are being served, the accept loop stops accepting until one
/// finishes — new connections wait in the kernel accept backlog. Bounds the
/// live-thread count under `Io.Threaded` to tame CPU oversubscription and the
/// latency tail. 0 = unbounded (default; unchanged behavior). A good starting
/// value is roughly the core count.
max_in_flight: usize = 0,
```

### Enforcement — `std.Io.Semaphore` in `acceptLoop`
`std.Io.Semaphore` is static-init (`.{ .permits = N }`), `Io`-agnostic, no deinit. Acquire a
permit right before `accept`; release when the connection finishes.

```zig
pub fn acceptLoop(self: *Self, io: Io) void {
    var conn_group: Io.Group = .init;
    var sem: Io.Semaphore = .{ .permits = self.opts.max_in_flight };
    const cap = self.opts.max_in_flight != 0;
    while (!self.shutting_down.load(.acquire)) {
        const srv = if (self.server) |*s| s else break;
        if (cap) sem.waitUncancelable(io);                 // backpressure: block at cap
        const stream = srv.accept(io) catch {
            if (cap) sem.post(io);                          // release on accept error
            break;
        };
        conn_group.async(io, handleConn, .{ self, io, stream, if (cap) &sem else null });
    }
    conn_group.await(io) catch {};
}
```
`handleConn` gains a trailing `sem: ?*Io.Semaphore` param and releases its permit on exit:
```zig
fn handleConn(self: *Self, io: Io, stream_in: net.Stream, sem: ?*Io.Semaphore) void {
    defer if (sem) |s| s.post(io);
    // …unchanged…
}
```

**Why before-accept:** blocking in `wait` before `accept` leaves excess connections in the
kernel accept backlog (true backpressure → eventual SYN backpressure), rather than accepting
sockets we have no capacity to serve.

**Lifetime:** `sem` lives on the `acceptLoop` stack; `conn_group.await` drains all tasks
before it returns, so every `&sem` reference outlives its use. Safe.

### Chosen behavior (confirmed): backpressure, not reject
At cap the loop blocks accepting (connections queue in the kernel). No client-visible error.
Rejecting with 503 was considered and declined for v1 (more code; accept-then-close still
spends a thread). Could be added later as `Options.overflow = .backpressure | .reject`.

## Known limitations (document, don't fix in v1)
- **Shutdown while saturated:** if the loop is parked in `waitUncancelable` at cap, shutdown
  proceeds only once an in-flight connection finishes and posts a permit (they will, and
  fast). Acceptable; note it. A cancelable wait keyed on `shutting_down` is a later refinement.
- **Keep-alive holds a permit for the connection's life**, not per request. That is correct:
  a live keep-alive connection is a live thread. Sizing guidance accounts for this.

## App-level complement (docs only)
zax cannot set `std.Io.Threaded`'s own `async_limit` — the caller constructs the `Io` and
passes it to `serve`. Document, in the bench README and zax docs, that an app can also bound
the runtime directly:
```zig
var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = .limited(n) }); // see InitOptions
const io = threaded.io();
try app.serve(io, addr);
```
`Options.max_in_flight` is the framework-level, `Io`-agnostic cap (works on any backend);
`async_limit` is the runtime-level thread cap. They compose; the in-flight cap is the one
zax owns and the one we test/bench.

## Out of scope
SO_REUSEPORT / sharded acceptors (separate, and can *worsen* tail — Cloudflare); reject mode;
evented IO (blocked upstream). All deferred.
