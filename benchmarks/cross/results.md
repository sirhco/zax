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

## Notes

- **zax is fastest at the median and competitive on throughput.** p50 ~0.086ms is
  ~4× better than axum (0.37ms) and ~5× better than go (0.48ms); req/s ~159–163k is
  within ~5% of axum and ahead of go. Per-request, zax's hot path is excellent.
- **The tail is the problem, and it's the concurrency model — not a socket option.**
  zax p99.9 ~36ms / max ~51ms vs axum ~0.65ms/5ms and go ~1.5ms/8ms — **~50× worse**.
  axum (tokio M:N) and go (goroutine scheduler) stay flat on the *same* oversubscribed
  box; zax's **thread-per-connection** model (`std.Io.Threaded`, one OS thread per
  conn) means 64 conns contend for cores and threads get parked ~35ms. This is the
  textbook thread-per-conn-under-oversubscription signature.
- **Implication:** the tail is hard evidence for the evented-IO lever
  (`docs/superpowers/specs/2026-06-17-perf-headroom-assessment.md`, lever #1). Socket
  tuning is exhausted; the next real win is `std.Io.Evented` (kqueue/epoll/io_uring)
  replacing thread-per-conn.
- **Caveat:** loopback, unpinned, macOS — absolute tail is inflated by client/server
  CPU contention. To quantify how much is the model vs raw oversubscription, re-run
  from a **separate machine** (or Linux `PIN=1`). The cross-framework flat-tail
  contrast already strongly implicates the scheduler model, not the kernel.
</content>
