# `std.Io.Evented` cannot do TCP: net ops are `*Unavailable` stubs on Uring (Linux) and Dispatch (macOS)

## Zig version
`0.16.0`

## Summary

`std.Io.Evented` resolves to a working fiber scheduler on the platforms that matter, but its
TCP socket operations are unimplemented — the vtable wires them to `*Unavailable` stubs that
return `error.NetworkDown`. As a result, a server written against the generic `std.Io`
interface (the documented "write once, run on `Io.Threaded` or `Io.Evented`" pattern) compiles
and runs on `Io.Evented`, then **aborts on the first `listen()`**. Today, evented TCP is only
reachable on the BSD `Kqueue` backend, which is *not* selected on Linux or macOS.

This blocks the obvious use case for `Io.Evented` — a high-concurrency network server — on the
two primary server/dev platforms.

## Where it resolves

`lib/std/Io.zig:31`:
```zig
pub const Evented = if (fiber.supported) switch (builtin.os.tag) {
    .linux => Uring,
    .dragonfly, .freebsd, .netbsd, .openbsd => Kqueue,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => Dispatch,
    else => void,
} else void;
```
`fiber.supported` is true on `aarch64`, `x86_64`, `riscv64`, so on a typical Linux x86_64 box
or an arm64 mac you get `Uring` / `Dispatch` respectively.

## The gap

**`Dispatch` (macOS) — every TCP op stubbed** (`lib/std/Io/Dispatch.zig` vtable, ~L454):
```zig
.netListenIp = netListenIpUnavailable,
.netAccept   = netAcceptUnavailable,
.netBindIp   = netBindIpUnavailable,
.netConnectIp= netConnectIpUnavailable,
.netSend     = netSendUnavailable,
.netRead     = netReadUnavailable,
.netWrite    = netWriteUnavailable,
// ...netClose is real
```

**`Uring` (Linux) — only `netBindIp` is real; listen/accept/send/read/write stubbed**
(`lib/std/Io/Uring.zig` vtable, ~L774):
```zig
.netListenIp = netListenIpUnavailable,
.netAccept   = netAcceptUnavailable,
.netBindIp   = netBindIp,            // real
.netSend     = netSendUnavailable,
.netRead     = netReadUnavailable,
.netWrite    = netWriteUnavailable,
// ...netClose, netShutdown real
```

**`Kqueue` (BSD only) — implemented** (`lib/std/Io/Kqueue.zig` vtable, ~L647), and unreachable
on Linux/macOS:
```zig
.netListenIp = netListenIp,
.netListenUnix = netListenUnix,
.netAccept   = netAccept,
.netBindIp   = netBindIp,
.netConnectIp= netConnectIp,
```

So the reference implementation already exists in-tree (Kqueue); Uring and Dispatch need the
equivalent — io_uring `IORING_OP_ACCEPT`/`RECV`/`SEND` (and `listen()` via the existing socket
path) for `Uring`, and GCD `dispatch_source` read/write sources for `Dispatch`.

## Reproduction

```zig
const std = @import("std");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var ev: std.Io.Evented = undefined;       // Dispatch on macOS, Uring on Linux
    try ev.init(gpa.allocator(), .{});
    const io = ev.io();
    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    _ = try addr.listen(io, .{ .reuse_address = true }); // -> error.NetworkDown
}
```
Running inside a fiber (`io.async(server, .{})` + `await`) makes no difference — `listen`
hits `netListenIpUnavailable` immediately. On Dispatch the failure surfaces as an abort
inside the fiber rather than a catchable error return.

## Expected vs actual

- **Expected:** `Io.Evented` supports TCP listen/accept/send/recv on Linux and macOS, matching
  the `Kqueue` backend, so the generic `std.Io` server pattern works on the evented backend.
- **Actual:** TCP is unavailable on `Uring` and `Dispatch`; only file/timer/CPU and (for
  Uring) `netBindIp`/`netShutdown`/`netClose` are wired.

## Impact

This is the single blocker for using `std.Io.Evented` as an HTTP/TCP server backend on the
mainstream platforms. We hit it building an evented backend for a Zig web framework: the
framework's `Io` is fully generic and runs on `Io.Threaded` today, but swapping in
`Io.Evented` dies at `listen`.

Concretely, the missing evented backend is costing real performance, and we have measured
exactly what it would recover. Benchmarked on Linux (core-pinned, server vs load-generator on
disjoint cores, same hardware):

| backend | req/s | p50 | p99.9 |
|---|---|---|---|
| our framework on `Io.Threaded` (thread-per-conn) | ~115k | 0.053ms | **~53ms** |
| Rust/axum (tokio, evented) | ~447k | 0.137ms | 0.35ms |
| **our framework on a hand-rolled epoll reactor (stock Zig)** | **~750k** | **0.074ms** | **0.35ms** |

When we worked around this gap by writing our own non-blocking **epoll reactor** inside the
framework (bypassing `std.Io` for the socket layer), the same request code jumped from ~115k
to **~750k req/s** and the ~53ms p99.9 tail collapsed to **~0.35ms** — faster than axum/tokio
on the same box. So the request path was never the bottleneck; the thread-per-connection
`Io.Threaded` model was, and an evented reactor fully fixes it.

That hand-rolled reactor is precisely the workload `std.Io.Evented` is meant to serve. We only
built it because `Io.Evented` can't `listen`/`accept`/`recv`/`send` — had the TCP ops been
implemented, the framework's already-`Io`-generic server would have run on `Io.Evented`
unchanged, with no bespoke reactor and no `std` bypass. Implementing these ops would give every
Zig `std.Io` server this performance for free.

## Questions for maintainers

- Is io_uring / GCD TCP for `Io.Evented` already planned / in progress? (Don't want to
  duplicate.)
- Would a PR implementing `Uring` `netAccept`/`netListenIp`/`netSend`/`netRead`/`netWrite`
  (mirroring `Kqueue`) be welcome, or is the `Io` net vtable still in flux?
