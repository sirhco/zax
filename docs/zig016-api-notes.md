# Zig 0.16.0 API ground-truth notes (Phase 0)

Verified against the **installed** std at
`/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` (`zig version` → `0.16.0`).
These are the real signatures Zax builds on. Where the original request's premises
were wrong, the correction is noted.

## Juicy Main / process init  — `std/process.zig:30`
```zig
pub fn main(init: std.process.Init) !void { ... }
```
`std.process.Init` fields (all confirmed):
- `minimal: Minimal` — `.environ`, `.args`
- `arena: *std.heap.ArenaAllocator` — process-lifetime, **threadsafe** (auto-cleaned on exit)
- `gpa: std.mem.Allocator` — general-purpose temp allocator, threadsafe, leak-checked in Debug
- `io: std.Io` — default Io impl chosen for the target, leak-checked in Debug
- `environ_map: *Environ.Map` (not threadsafe), `preopens: Preopens`

So `main` gets **both** an allocator (`init.gpa`) and an `Io` (`init.io`) for free.
"Juicy Main" is real and is the idiomatic 0.16 entry point.

## Io interface  — `std/Io.zig` (136 KB)
`std.Io` is a value passed like `Allocator`. Async surface (confirmed):
- `io.async(function, args) Future(Ret)` — `Io.zig:2326`. `args` is
  `std.meta.ArgsTuple(@TypeOf(function))`. Always succeeds (may run inline).
- `io.concurrent(function, args) ConcurrentError!Future(Ret)` — `Io.zig:2365`.
  Stronger guarantee; fails `error.ConcurrencyUnavailable` on limited impls.
- `Future(T)`: `.await(io)`, `.cancel(io)`.
- `Io.Group` — `Io.zig:1218`: `group.async(io, fn, args) void`,
  `group.concurrent(io, fn, args) ConcurrentError!void`, plus await/cancel.
- `io.recancel()` — `Io.zig:1310`. `Io.Cancelable` error set — `Io.zig:704`
  (contains `error.Canceled`).

### Io implementations  — `std/Io/`
- `Io.Threaded` (production) — `init(gpa: Allocator, options: InitOptions) Threaded`
  (`Threaded.zig:1607`), then `t.io() Io` (`:1806`), `t.deinit()` (`:1712`).
  Const `Io.Threaded.init_single_threaded`. `gpa` must be threadsafe; only used by
  async/concurrent/group — pass `Allocator.failing` if those are unused.
  Under `builtin.single_threaded`, `concurrent` → `error.ConcurrencyUnavailable`.
- `Io.Uring`, `Io.Kqueue` exist (evented) but are **experimental / networking
  incomplete** — do NOT target for v1. Backend = `Io.Threaded`.

## Networking  — `std/Io/net.zig`  (old `std.net` is gone)
- `IpAddress` union `{ ip4, ip6 }`. Helpers: `Ip4Address.loopback(port)`,
  `IpAddress.parse(text, port)`, `addr.setPort(p)`, `addr.getPort()`.
- `addr.listen(io, ListenOptions) ListenError!Server` — `net.zig:246`.
  `ListenOptions{ kernel_backlog=128, reuse_address=false, mode=.stream, protocol=.tcp }`.
- `Server.accept(io) AcceptError!Stream` — `net.zig:1442`. Blocks until a client
  connects. `Server.deinit(io)`. **`Socket.shutdown` makes a blocking `accept`
  return `error.SocketNotListening`** — the documented concurrent-cancellation
  hook we use for graceful drain.
- `Stream.reader(io, buffer: []u8) Stream.Reader` — `.interface` is an `Io.Reader`.
  `Stream.writer(io, buffer: []u8) Stream.Writer` — `.interface` is an `Io.Writer`.
  `Stream.close(io)`.
- `IpAddress.connect(io, ConnectOptions) ConnectError!Stream` (for tests/clients).

## Comptime reflection (handler signatures)  — confirmed in std itself
- `@typeInfo(@TypeOf(f)).@"fn".return_type.?` — used verbatim in `Io.async`.
- `@typeInfo(@TypeOf(f)).@"fn".params` — slice; each has `.type: ?type`.
- `std.meta.ArgsTuple(@TypeOf(f))` — builds the call-args tuple type; pair with
  `@call(.auto, f, args)`. This is exactly the machinery for the extractor system.

## Allocators  — `std/heap.zig`
- `std.heap.ArenaAllocator` (`heap.zig:12`) — per-request arena (`arena.allocator()`,
  `arena.deinit()`). **Not independently lock-free**; we give each request its own,
  so cross-thread sharing never happens.
- `std.heap.smp_allocator` (`heap.zig:353`) — SMP backing allocator, for ReleaseFast
  servers.
- `std.heap.DebugAllocator` (`heap.zig:20`) — Debug builds, leak detection.
  `GeneralPurposeAllocator` is **gone** (renamed). `page_allocator` (`heap.zig:341`).

## Corrections to original premises
- "thread-safe lock-free `ArenaAllocator`" → arena is not independently lock-free;
  the *process* arena from `Init` is threadsafe, but our design uses per-request
  arenas regardless. ✗ premise / ✓ design unaffected.
- "`zig-pkg` directory" → no such thing. Deps = `build.zig.zon` + `zig fetch --save`,
  wired via `b.dependency(...).module(...)`. ✗ premise.
- `std.process.Init` / "Juicy Main" → **real**. ✓
- "new `Io` interface, `io.async`/`io.concurrent`" → **real**. ✓
- `Io.Evented` single-thread-epoll networking → experimental/incomplete. Use
  `Io.Threaded`. ✓ caveat.
