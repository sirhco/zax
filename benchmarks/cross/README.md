# Cross-framework load benchmark

zax vs [axum](https://github.com/tokio-rs/axum) (Rust) vs Go `net/http` (std lib),
under identical load with the same methodology. These are **indicative**
same-methodology numbers, **not** a definitive "X beats Y" — read the caveats.

> zax's own `zig build bench` is deliberately *self-relative* (it shares the
> client's process/Io). This directory is the separate, explicitly comparative
> harness: real servers, real sockets, an external load generator.

## Layout

```
benchmarks/cross/
  zax/    Zig server (path-depends on the repo-root zax package)   -> :8081
  axum/   Rust/axum server                                          -> :8082
  go/     Go net/http server                                        -> :8083
  run.sh  builds all three (release) + drives load across scenarios
  results.md  record your numbers here
```

## Equivalent app (all three, byte-for-byte)

| Route             | Behavior                                  |
|-------------------|-------------------------------------------|
| `GET /`           | returns `hello`                           |
| `GET /users/{id}` | returns the captured `id` (path param)    |
| `POST /echo`      | parses `{"msg":"..."}` and echoes it back |

## Run

```sh
# install a load generator first (external, neutral):
brew install oha          # or: cargo install oha

cd benchmarks/cross
./run.sh                              # 30s, 64 connections, oha
DURATION=10s CONNS=128 ./run.sh
LOAD=wrk ./run.sh                     # oha | wrk | bombardier
PIN=1 ./run.sh                        # pin server vs client to disjoint cores
                                      # (Linux/taskset) so they don't fight for CPU
AB=1 ./run.sh                         # A/B zax Nagle on vs off (see below)
```

`PIN=1` runs the server on the first half of the cores and the load generator on
the second half (via `taskset`), so client CPU never steals from the server —
this isolates the server's true tail latency from same-host oversubscription.
Linux only; on macOS run the load generator on a separate machine instead.

`run.sh` builds each server in release mode, boots it, warms up, runs the measured
load for each scenario, then moves on. The table reports **req/s, p50, p99, p99.9
and max** — the Nagle/delayed-ACK tail lives at **p99.9 + max**, not p99, so those
two columns are what to watch. Copy them into `results.md`.

### A/B the Nagle effect (`AB=1`)

The zax server disables Nagle (`TCP_NODELAY`) by default. Set `ZAX_NODELAY=0` to
leave Nagle on. `AB=1` runs zax **twice** — `zax-off` (Nagle on) then `zax-on`
(Nagle off) — so you can compare the two directly:

```sh
AB=1 ./run.sh                         # adds zax-off / zax-on rows
```

Why this works on **any** box, even macOS unpinned: absolute same-host numbers are
dominated by CPU oversubscription, so they can't validate the fix on their own. But
oversubscription is **identical** across the two zax passes, so it cancels in the
`zax-on` − `zax-off` delta on **p99.9/max** — that delta isolates Nagle. If they're
roughly equal, the same-box tail is oversubscription (not Nagle), and `TCP_NODELAY`
is still correct best-practice (axum/hyper and Go set it) but won't move same-box
numbers. For absolute numbers, run `oha` from a separate machine.

### A/B the worker-pool cap (`INFLIGHT=N`)

`ZAX_MAX_INFLIGHT=N` caps concurrent in-flight connections at N via backpressure: when N
connections are being served, the accept loop stops accepting (new connections wait in the
kernel accept backlog). This bounds the live-thread count under `Io.Threaded`, reducing
CPU oversubscription. `INFLIGHT=N` in `run.sh` runs zax **twice** — once uncapped
(`ZAX_MAX_INFLIGHT=0`, label `zax`) and once capped (`ZAX_MAX_INFLIGHT=N`, label
`zax-cap`) — so p99.9/max can be compared directly. axum/go run once as usual.

```sh
INFLIGHT=$(nproc) ./run.sh            # cap = core count; adds zax / zax-cap rows
INFLIGHT=8 ./run.sh                   # fixed cap of 8
```

A good starting value is roughly the core count. The hypothesis: p99.9/max flatten
toward axum/go while median + throughput hold (backpressure shifts work to the kernel
backlog instead of burning threads). `INFLIGHT` and `AB` are independent composable
knobs — they can run together, but a clean single-knob run per section is clearest.

#### App-level complement: `std.Io.Threaded.async_limit`

`Options.max_in_flight` is the framework-level, `Io`-agnostic cap (works on any backend;
zax owns it). A complementary runtime-level thread cap is also available: the app
constructs `std.Io.Threaded` with `async_limit` before passing the `Io` to `serve`:

```zig
var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = .limited(n) }); // see InitOptions
const io = threaded.io();
try app.serve(io, addr);
```

The two caps compose: `async_limit` bounds OS threads at the runtime level;
`max_in_flight` bounds live connections at the framework level. `max_in_flight` is the
one zax owns and the one we test/bench here; `async_limit` is set by the calling app
and is outside zax's control.

### Off-box / true tail (confirm model vs oversubscription)

Same-host (loopback) runs make the load generator fight the server for cores, so the
p99.9/max tail is inflated by oversubscription. zax's tail is ~50× axum/go on loopback
(`results.md`); to confirm that's the **thread-per-connection model** and not just
same-host contention, measure off the loopback. Two options:

**A. Second machine over the LAN (truest).** On this box, start a server bound to all
interfaces (edit the bench server's `loopback(port)` → an all-interfaces bind, or front
it). From machine B on the same LAN:
```sh
# machine B -> machine A (this box) at <A-IP>
oha -z 30s -c 64 --no-tui http://<A-IP>:8081/
oha -z 30s -c 64 --no-tui http://<A-IP>:8082/        # axum
oha -z 30s -c 64 --no-tui http://<A-IP>:8083/        # go
```
No shared cores → the tail you see is the server's, not the scheduler fighting the client.

**B. Linux box with `PIN=1` (good proxy).** On Linux, `taskset` pins server and client to
disjoint cores, and `std.Io.Evented` would resolve to io_uring (note: std's io_uring TCP
is not yet usable — see the decision doc):
```sh
PIN=1 DURATION=30s ./run.sh                 # server cores 0..N/2-1, client N/2..N-1
```

**Record:** drop the numbers into `results.md` under a new "Off-box" heading with the
client location noted. **Interpret:** if zax's p99.9/max stays ~tens-of-ms while axum/go
stay sub-ms **off-box**, the tail is the concurrency model (thread-per-conn
oversubscription) → pursue the bounded-worker-pool theme
(`docs/superpowers/specs/2026-06-17-evented-io-decision.md`). If zax's tail collapses
toward axum/go off-box, it was mostly same-host contention.

## Toolchains

- zax: Zig 0.16.0 (`zig build -Doptimize=ReleaseFast`)
- axum: Rust + cargo (`cargo build --release`, axum 0.8)
- go: Go 1.22+ (`go build`)

## Fairness & caveats (read before quoting any number)

These wreck cross-framework comparisons if ignored:

- **Loopback ≠ network.** Same-host runs measure the kernel + scheduler as much
  as the framework. For real numbers, run the load generator on a **separate
  machine** over the network, or at minimum pin server vs client to disjoint
  cores — use **`PIN=1`** (Linux/`taskset`; macOS has no easy core pinning).
- **Client starves server on one box.** The load tool competes for the same
  cores. Isolate them or expect noise.
- **Runtime models differ.** Go has a GC (pause jitter); Rust/axum (tokio) and
  zax are GC-free but allocate differently (zax uses a per-request arena). Match
  worker counts: tokio workers ≈ `GOMAXPROCS` ≈ zax `Io.Threaded` pool ≈ pinned
  core count.
- **Release builds only**, logging off (these servers don't log) — otherwise you
  bench the logger or a debug build.
- **The apps must stay equivalent.** Same routes, same response bytes, same work
  (parse + re-serialize for `/echo`). A subtle mismatch means you measure the
  mistake, not the framework.
- **Warm up and repeat.** `run.sh` discards a warmup run; do several measured
  runs and report median + spread, not a single number.

Treat results as "same methodology, same box, indicative." If you publish them,
publish the methodology and hardware too.
