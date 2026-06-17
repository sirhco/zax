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
```

`run.sh` builds each server in release mode, boots it, warms up, runs the measured
load for each scenario, then moves on. Copy req/s + p50/p99 into `results.md`.

## Toolchains

- zax: Zig 0.16.0 (`zig build -Doptimize=ReleaseFast`)
- axum: Rust + cargo (`cargo build --release`, axum 0.8)
- go: Go 1.22+ (`go build`)

## Fairness & caveats (read before quoting any number)

These wreck cross-framework comparisons if ignored:

- **Loopback ≠ network.** Same-host runs measure the kernel + scheduler as much
  as the framework. For real numbers, run the load generator on a **separate
  machine** over the network, or at minimum pin server vs client to disjoint
  cores (`taskset`/cpuset on Linux; macOS has no easy core pinning).
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
