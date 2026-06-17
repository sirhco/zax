# Cross-framework results

Record runs here. Include the methodology so numbers are interpretable.

> Tail note: the Nagle/delayed-ACK cluster lives at **p99.9 + max**, not p99 —
> always fill those columns. On a single box, treat absolute numbers as
> oversubscription-dominated; use the `AB=1` A/B section to isolate Nagle.

## Environment

- Date: 2026-06-17
- Hardware (CPU, cores, RAM): macOS dev box, ~18 cores
- OS: macOS (darwin 25.4)
- zig / rustc / go versions: zig 0.16.0 / (rustc per cargo) / (go ≥1.22)
- Load generator + version: oha
- `DURATION` / `CONNS`: 30s / 64
- Client location: **same host (loopback)** — absolute numbers are
  oversubscription-bound; only the A/B delta isolates Nagle
- Core pinning: **none** (macOS has no `taskset`; client + server share cores)

## Results (median of N runs)

zax row = `zax-on` (shipping default, `TCP_NODELAY`). Note the split: zax has the
**best median and competitive throughput** but a **p99.9/max tail ~50× worse** than
axum/go — the thread-per-connection signature under same-host oversubscription (see
Notes). Tokio (axum) and Go's M:N schedulers keep flat tails on the same box.

### static — `GET /`

| Framework | req/s  | p50    | p99     | p99.9   | max     |
|-----------|-------:|-------:|--------:|--------:|--------:|
| zax       | 161416 | 0.0862 |  7.4394 | 36.2033 | 49.8773 |
| axum      | 171565 | 0.3667 |  0.5170 |  0.6538 |  5.1949 |
| go        | 128069 | 0.4832 |  1.1057 |  1.4563 |  8.0751 |

### param — `GET /users/42`

| Framework | req/s  | p50    | p99     | p99.9   | max     |
|-----------|-------:|-------:|--------:|--------:|--------:|
| zax       | 162313 | 0.0854 |  7.4766 | 36.0277 | 51.5662 |
| axum      | 171854 | 0.3672 |  0.5092 |  0.6139 |  2.7379 |
| go        | 127528 | 0.4830 |  1.1556 |  1.4983 |  8.4524 |

### json — `POST /echo`

| Framework | req/s  | p50    | p99     | p99.9   | max     |
|-----------|-------:|-------:|--------:|--------:|--------:|
| zax       | 158923 | 0.0882 |  7.0991 | 36.9841 | 53.8925 |
| axum      | 167373 | 0.3780 |  0.5099 |  0.6126 |  2.3512 |
| go        | 107549 | 0.4174 |  2.1170 |  2.8816 |  6.1218 |

## A/B — TCP_NODELAY (`AB=1 ./run.sh`)

Compare `zax-on` (Nagle off / `TCP_NODELAY`) vs `zax-off` (Nagle on). The delta on
**p99.9/max** isolates Nagle — oversubscription is identical across both passes so
it cancels. Roughly equal ⇒ same-box tail is oversubscription, not Nagle.

AB=1 DURATION=30s ./run.sh
== building (release) ==
    Finished `release` profile [optimized] target(s) in 0.10s

######################## zax-off (:8081) ########################
  zax-off static        163710 req/s   p50 0.0859ms   p99 10.1670ms   p99.9 35.7085ms   max 51.6506ms
  zax-off param         163635 req/s   p50 0.0860ms   p99 10.6069ms   p99.9 35.7460ms   max 50.0222ms
  zax-off json          159584 req/s   p50 0.0879ms   p99 11.3024ms   p99.9 36.6383ms   max 51.0391ms

######################## zax-on (:8081) ########################
  zax-on  static        161416 req/s   p50 0.0862ms   p99 7.4394ms   p99.9 36.2033ms   max 49.8773ms
  zax-on  param         162313 req/s   p50 0.0854ms   p99 7.4766ms   p99.9 36.0277ms   max 51.5662ms
  zax-on  json          158923 req/s   p50 0.0882ms   p99 7.0991ms   p99.9 36.9841ms   max 53.8925ms

######################## axum (:8082) ########################
  axum    static        171565 req/s   p50 0.3667ms   p99 0.5170ms   p99.9 0.6538ms   max 5.1949ms
  axum    param         171854 req/s   p50 0.3672ms   p99 0.5092ms   p99.9 0.6139ms   max 2.7379ms
  axum    json          167373 req/s   p50 0.3780ms   p99 0.5099ms   p99.9 0.6126ms   max 2.3512ms

######################## go (:8083) ########################
  go      static        128069 req/s   p50 0.4832ms   p99 1.1057ms   p99.9 1.4563ms   max 8.0751ms
  go      param         127528 req/s   p50 0.4830ms   p99 1.1556ms   p99.9 1.4983ms   max 8.4524ms
  go      json          107549 req/s   p50 0.4174ms   p99 2.1170ms   p99.9 2.8816ms   max 6.1218ms

==================== RESULTS (30s, 64 conns, oha, A/B) ====================
FRAMEWORK SCENARIO        REQ/S   P50(ms)   P99(ms) P99.9(ms)   MAX(ms)
zax-off  static         163710    0.0859   10.1670   35.7085   51.6506
zax-off  param          163635    0.0860   10.6069   35.7460   50.0222
zax-off  json           159584    0.0879   11.3024   36.6383   51.0391
zax-on   static         161416    0.0862    7.4394   36.2033   49.8773
zax-on   param          162313    0.0854    7.4766   36.0277   51.5662
zax-on   json           158923    0.0882    7.0991   36.9841   53.8925
axum     static         171565    0.3667    0.5170    0.6538    5.1949
axum     param          171854    0.3672    0.5092    0.6139    2.7379
axum     json           167373    0.3780    0.5099    0.6126    2.3512
go       static         128069    0.4832    1.1057    1.4563    8.0751
go       param          127528    0.4830    1.1556    1.4983    8.4524
go       json           107549    0.4174    2.1170    2.8816    6.1218

| Pass    | scenario | p99     | p99.9   | max     |
|---------|----------|--------:|--------:|--------:|
| zax-off | static   | 10.1670 | 35.7085 | 51.6506 |
| zax-on  | static   |  7.4394 | 36.2033 | 49.8773 |
| zax-off | param    | 10.6069 | 35.7460 | 50.0222 |
| zax-on  | param    |  7.4766 | 36.0277 | 51.5662 |
| zax-off | json     | 11.3024 | 36.6383 | 51.0391 |
| zax-on  | json     |  7.0991 | 36.9841 | 53.8925 |

**Verdict: oversubscription-dominated.** Turning on `TCP_NODELAY` (zax-off→zax-on)
moves **p99 ~10.5ms → ~7.4ms** (a real delayed-ACK win — keep it) but leaves
**p99.9 (~36ms) and max (~51ms) unchanged**. So the 35ms cluster is **not Nagle** —
the earlier "Nagle at p99.9" diagnosis was wrong. `TCP_NODELAY` stays (correct
best-practice, helps p99) but it is not what drives the tail.

## Worker-pool cap (`INFLIGHT=N ./run.sh`) — NEGATIVE RESULT

`zax` = uncapped (`ZAX_MAX_INFLIGHT=0`). `zax-cap` = capped (`ZAX_MAX_INFLIGHT=N`). The
cap limits concurrent in-flight connections via backpressure, bounding live threads under
`Io.Threaded`. Hypothesis (from the decision doc): p99.9/max flatten toward axum/go.
**Result: it does not.** Numbers below are the `INFLIGHT=18` run (18 = core count); a sweep
of `INFLIGHT=8/18/32/48` was run (20s each) and all behave the same.

### static — `GET /` (INFLIGHT=18)

| Framework / pass | req/s  | p50    | p99     | p99.9   | max     |
|------------------|-------:|-------:|--------:|--------:|--------:|
| zax (uncapped)   | 169743 | 0.0847 |  6.4672 | 34.4023 | 43.6788 |
| zax-cap          | 165714 | 0.0856 |  7.2220 | 35.3336 | 48.6202 |
| axum             | 174559 | 0.3621 |  0.4807 |  0.5704 |  5.0764 |
| go               | 129575 | 0.4783 |  1.0854 |  1.4135 |  2.0391 |

### param — `GET /users/42` (INFLIGHT=18)

| Framework / pass | req/s  | p50    | p99     | p99.9   | max     |
|------------------|-------:|-------:|--------:|--------:|--------:|
| zax (uncapped)   | 167709 | 0.0847 | 10.3381 | 34.8325 | 47.4096 |
| zax-cap          | 164398 | 0.0855 | 11.2955 | 35.5909 | 50.7566 |
| axum             | 175295 | 0.3617 |  0.4731 |  0.5468 |  5.1565 |
| go               | 129351 | 0.4777 |  1.1217 |  1.4501 |  3.4581 |

### json — `POST /echo` (INFLIGHT=18)

| Framework / pass | req/s  | p50    | p99     | p99.9   | max     |
|------------------|-------:|-------:|--------:|--------:|--------:|
| zax (uncapped)   | 163606 | 0.0873 | 10.7078 | 35.8111 | 58.3292 |
| zax-cap          | 161099 | 0.0873 | 10.0186 | 36.3990 | 50.3694 |
| axum             | 169056 | 0.3756 |  0.4833 |  0.5560 |  1.7633 |
| go               | 107898 | 0.4126 |  2.1089 |  2.8830 |  5.2452 |

### Sweep (json p99.9 / max, ms) — flat across every cap

| INFLIGHT | uncapped | 8 | 18 | 32 | 48 |
|----------|---------:|--:|---:|---:|---:|
| p99.9    | ~35.8 | 40.2 | 36.4 | 36.7 | 35.7 |
| max      | ~52  | 54.4 | 50.4 | 50.3 | ~46 |

**Verdict: the cap does NOT flatten the tail — oversubscription is refuted.** At
`INFLIGHT=8` only **8 connections** are served (keep-alive holds a permit for the
connection's lifetime, so oha's other 56 conns sit in the accept backlog all run) — i.e.
**8 live threads on 18 cores, undersubscribed** — and the p99.9 cluster is *still ~35ms*.
Few threads, idle cores, identical tail. So the ~35ms tail is **not** thread count /
CPU oversubscription. (Side effect: at `INFLIGHT=8`, p50 fell 0.085→0.045ms — less
contention helps the median, not the tail.) The cap remains a valid resource-bounding
knob; it is **not** the latency-tail fix.

## Notes

- **zax is fastest at the median and competitive on throughput.** p50 ~0.086ms is ~4×
  better than axum and ~5× better than go; req/s ~160–170k is within ~5% of axum and
  ahead of go. The per-request hot path is excellent.
- **The ~35ms tail is a FIXED, intrinsic stall — not concurrency volume.** It is
  rock-stable at p99.9 ~34–36ms / max ~46–60ms across *every* configuration tested:
  uncapped 64-conn, capped down to 8-conn, Nagle on/off. axum (~0.55ms) and go (~1.4ms)
  on the same box, same loopback, same oha do not have it. Combined with the cap
  refutation (8 threads, 18 cores, still 35ms), this points to a **periodic stall in
  zax's per-connection read path on `std.Io.Threaded`** — most likely the keep-alive
  `receiveTimeout` wakeup / thread park-unpark granularity — independent of how many
  connections are live.
- **What this rules out:** Nagle (A/B), CPU oversubscription / thread count (this cap
  sweep), and socket tuning generally. And `std.Io.Evented` is blocked upstream (no TCP
  on Dispatch/Uring in 0.16 — `2026-06-17-evented-io-decision.md`), so it is not the
  available fix either.
- **Next direction — trace the stall, don't add knobs.** Instrument `handleConn`: stamp
  time around `receiveTimeout`/the keep-alive read and the response write to locate where
  the ~35ms goes. Check whether it's `Io.Threaded`-specific (e.g. poll/timer granularity,
  thread wakeup latency) vs zax logic, and whether a non-keep-alive run or a different
  `Io.Threaded` config changes it. That investigation — not more concurrency caps — is
  the path to the tail.
- **Caveat:** loopback, unpinned, macOS. An off-box / Linux `PIN=1` run (README "Off-box /
  true tail") would confirm the stall isn't a macOS-loopback artifact — worth doing before
  the tracing theme.
</content>

## Linux (Docker linuxkit VM, arm64) — PIN=1 core-pinned

First **core-pinned** cross-framework run (server vs client on disjoint cores; `taskset`
works on Linux, mac can't). Run via `benchmarks/cross/docker/`. 15s, 64 conns. Absolute
req/s carries Docker-VM overhead; the **relative** gap (same VM) is sound.

| framework | scenario | req/s | p50 | p99 | p99.9 | max |
|-----------|----------|------:|----:|----:|------:|----:|
| zax  | static | 117326 | 0.0534 | 0.9629 | 53.4625 | 63.5676 |
| zax  | param  | 115959 | 0.0549 | 0.5272 | 54.4679 | 66.7251 |
| zax  | json   | 111000 | 0.0577 | 0.9858 | 56.7911 | 73.9299 |
| axum | static | 434587 | 0.1410 | 0.2923 |  0.3645 |  3.7545 |
| axum | param  | 442588 | 0.1385 | 0.2863 |  0.3573 |  2.2813 |
| axum | json   | 447869 | 0.1351 | 0.2974 |  0.3730 |  2.0840 |
| go   | static | 402036 | 0.0817 | 2.0535 |  2.8652 |  8.8668 |
| go   | param  | 390450 | 0.0840 | 2.0806 |  2.8506 |  8.6216 |
| go   | json   | 200734 | 0.1100 | 2.6246 |  3.3998 | 20.5402 |

**Pinned reveals what loopback hid:** zax ~115k req/s vs **axum ~440k (≈4×)** and go
~200–400k — zax is behind on **throughput**, not just the tail (p99.9 53–57ms vs axum 0.36ms,
go 2.9ms). zax p50 is still best (0.054ms — hot path excellent). Root cause = `std.Io.Threaded`
thread-per-conn (64 blocking threads on 9 pinned cores). The unpinned macOS "competitive
throughput" was an artifact. See `docs/superpowers/specs/2026-06-17-latency-stall-findings.md`.
