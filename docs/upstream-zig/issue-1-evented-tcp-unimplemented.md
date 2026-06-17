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

Concretely, the missing evented backend is costing real performance. Benchmarked on Linux
(core-pinned, server vs load-generator on disjoint cores), the same framework on `Io.Threaded`
(thread-per-connection) does **~115k req/s with a p99.9 of ~53ms**, while Rust/axum (tokio,
evented) on the identical hardware does **~440k req/s with p99.9 ~0.36ms** — a ~4× throughput
and ~150× tail-latency gap, traced not to the framework's request code (all per-request work
profiles <7ms) but to the thread-per-connection IO model. An `Io.Evented` TCP backend is the
direct fix, and it is gated entirely on this gap.

## Questions for maintainers

- Is io_uring / GCD TCP for `Io.Evented` already planned / in progress? (Don't want to
  duplicate.)
- Would a PR implementing `Uring` `netAccept`/`netListenIp`/`netSend`/`netRead`/`netWrite`
  (mirroring `Kqueue`) be welcome, or is the `Io` net vtable still in flux?
