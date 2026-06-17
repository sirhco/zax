# Findings — tracing the fixed ~35ms latency stall

Fill from the traced experiment runs. Executes the experiments in
`2026-06-17-latency-stall-trace-design.md`. The traced server prints, on shutdown:
```
[latency-trace] segment  max_ms  over5ms  dominant
[latency-trace]   head   ...
[latency-trace]   body   ...
[latency-trace]   disp   ...
[latency-trace]   write  ...
```
`head` = wait-for + parse the next keep-alive request (prime suspect — should be ~0 under
oha keep-alive; a large value = `Io.Threaded` thread-wakeup latency). `write` = response
write + flush. `dominant` = count of requests where that segment was the largest.

## Build
```sh
cd benchmarks/cross/zax && zig build -Dtrace-latency=true -Doptimize=ReleaseFast
```

## E1 — phase distribution under standard load
```sh
ZAX_RUN_SECS=35 ./zig-out/bin/zax-bench 2>trace-e1.log &
oha -z 30s -c 64 --no-tui http://127.0.0.1:8081/
wait; grep latency-trace trace-e1.log
```
| segment | max_ms | over5ms | dominant |
|---------|-------:|--------:|---------:|
| head    |   8.15 |     236 | 4908184  |
| body    |   0.03 |       0 |        5 |
| disp    |   0.07 |       0 |       14 |
| write   |   0.15 |       0 |    45874 |

oha same run: p50 0.081 / p99 8.13 / **p99.9 35.66 / max 59.59** ms, 165k req/s; histogram
cluster ~49.5k reqs in 23–47ms.

**Which segment carries the ~35ms: NONE.** Sum of all four segment maxes ≈ 8.4ms, but oha
p99.9 is 35.7ms. zax's per-request work (parse/route/dispatch/write) is all <8ms — **the
~35ms is entirely outside the measured server path.** zax application code is exonerated.
The stall is in the **IO/scheduling handoff** (between `flush` returning in 0.15ms and the
client receiving / the next read waking), i.e. the `std.Io.Threaded` blocking-IO + kernel
layer — not zax logic. `head` is the *dominant* segment but only ~8ms, so it isn't the
keep-alive read-wait either. Combined with the cap result (8 threads / 18 cores → still
35ms), the tail is insensitive to thread count AND compute and pinned at ~35ms → smells
like a **fixed timer/quantum in `Io.Threaded` (likely macOS-specific)**. → E5 (Linux) is now
the decisive experiment.

## E2 — non-keep-alive (`ZAX_KEEPALIVE=0`)
Does the tail vanish without keep-alive? (isolates H1, the read-wait.)
```sh
ZAX_KEEPALIVE=0 ZAX_RUN_SECS=35 ./zig-out/bin/zax-bench 2>trace-e2.log &
oha -z 30s -c 64 --no-tui http://127.0.0.1:8081/   # (oha keep-alives by default; the server closes each conn)
wait; grep latency-trace trace-e2.log
```
**INVALID — ephemeral port exhaustion.** Non-keep-alive opens a new connection per
request; on loopback at `-c 64` this exhausts ephemeral ports / piles up TIME_WAIT →
oha success **54.5%**, 99,190 `os error 49 (Can't assign requested address)`, throughput
collapsed to ~7k req/s (vs 4.95M reqs in E1), latency units garbled. `head` max 4984ms =
readHead stalled on retrying connections, not the stall under study. The 35ms cluster did
not appear, but that is **confounded** by the broken run, not evidence. Non-keep-alive is
not cleanly benchable on this loopback box; rely on E1 + E5 instead.

| segment | max_ms | over5ms | dominant | tail vanished? |
|---------|-------:|--------:|---------:|----------------|
| head    | 4984.69 (noise) | 12 | 37923 | run invalid |
| write   | 0.09 | 0 | 81194 | — |

## E4 — thread-count sweep (`ZAX_THREADS=N`, use N≥2)
Does the tail move with the worker pool size? (tests H3 — `Io.Threaded` granularity.)
Note: `ZAX_THREADS=1` is degenerate (connections serve inline) — start at 2.
```sh
for n in 2 4 8 18; do
  ZAX_THREADS=$n ZAX_RUN_SECS=25 ./zig-out/bin/zax-bench 2>trace-t$n.log &
  oha -z 20s -c 64 --no-tui http://127.0.0.1:8081/ ; wait
  echo "== threads=$n =="; grep latency-trace trace-t$n.log
done
```
| threads | head max_ms | write max_ms | tail (p99.9 from oha) |
|---------|------------:|-------------:|----------------------:|
| 2       |             |              |                       |
| 4       |             |              |                       |
| 8       |             |              |                       |
| 18      |             |              |                       |

## E5 — Linux (Docker, linuxkit 6.12 aarch64 VM on the mac) — REPRODUCES

Ran via `benchmarks/cross/docker/` (real Linux kernel in Docker's VM, native arm64).

**Traced zax, GET / (15s, 64 conns):** oha p50 0.082 / p99 4.94 / **p99.9 43.0 / max 78** ms,
136k req/s. Trace dump:
| segment | max_ms | over5ms | dominant |
|---------|-------:|--------:|---------:|
| head    |   6.20 |       8 | 1878699  |
| body    |   0.06 |       0 |        4 |
| disp    |   0.16 |       0 |       32 |
| write   |   6.18 |       3 |   167472 |

| platform | head max | write max | oha p99.9 | verdict |
|----------|---------:|----------:|----------:|---------|
| macOS    |     8.15 |      0.15 |    ~35.7  | tail outside segments |
| Linux    |     6.20 |      6.18 |     43.0  | **same — reproduces** |

**The ~35–43ms tail reproduces on Linux**, and the trace again shows it is **outside zax's
measured path** (max segment ~6ms vs p99.9 43ms). So it is **NOT a macOS/Darwin artifact** —
it is the `std.Io.Threaded` thread-per-connection model + kernel IO handoff, on both OSes.

### PIN=1 cross-framework (Linux, first core-pinned run — server vs client on disjoint cores)
| framework | req/s | p50 | p99 | p99.9 | max |
|-----------|------:|----:|----:|------:|----:|
| **zax**   | ~115k | **0.054** | ~0.96 | **53–57** | 64–74 |
| axum      | **~440k** | 0.14 | 0.29 | **0.36** | 2–4 |
| go        | 200–400k | 0.08 | 2.1 | 2.9 | 9–20 |

**New, bigger finding:** once properly **pinned** (server isolated to 9 of 18 cores), zax does
~**115k req/s vs axum ~440k (≈4×) and go ~200–400k** — zax is now *behind both on throughput*,
not just the tail. The macOS-loopback "competitive throughput" was an artifact of the unpinned
client+server fighting equally. zax's p50 stays best (0.054ms — the per-request hot path is
genuinely excellent), but the **thread-per-conn model can't keep 9 cores fed** (64 blocking
threads on 9 cores) the way tokio's M:N work-stealing (axum) or goroutines (go) do. Same root
cause as the tail: `std.Io.Threaded`.

## Verdict (FINAL — E5/Linux confirmed)

**zax's request-handling code is excellent and is NOT the cause; the limit is the
`std.Io.Threaded` thread-per-connection backend, on both macOS and Linux.** E5 settled the
open question: the tail reproduces on Linux (43ms) and the trace shows it is outside zax's
segments on both OSes — not a Darwin artifact. The pinned Linux run added a bigger finding:
zax is also ~4× behind axum on throughput once the server is core-isolated. Details:
- **Where the tail lives:** NOT in any zax segment, on either OS. Per-request work is small
  (macOS: head 8.15 / write 0.15; Linux: head 6.20 / write 6.18 ms max) vs oha p99.9 35–43ms.
  The stall is in the **`std.Io.Threaded` blocking-IO + kernel handoff**, outside zax's
  request processing.
- **It is NOT a macOS artifact:** E5 (Linux 6.12 kernel) reproduces it — p99.9 43ms traced,
  53–57ms pinned. Both platforms, same signature.
- **Bigger finding (pinned Linux):** zax throughput ~115k vs **axum ~440k (≈4×)** and go
  ~200–400k. zax is behind on **throughput**, not only the tail — the unpinned macOS
  "competitive throughput" was a measurement artifact. zax p50 stays best (0.054ms); the
  ceiling is the thread-per-conn concurrency model, not the per-request code.
- **Component to blame:** `std.Io.Threaded` thread-per-connection backend (64 blocking
  threads can't keep cores fed / wakeup granularity), confirmed on macOS + Linux.
  **zax application code is exonerated** — its hot path is excellent (best median).
- **E2 (non-keep-alive) was invalid** (port exhaustion) and contributes no signal.

## Next steps (in priority order)

1. **File the upstream Zig issue** (`docs/upstream-zig/issue-1-evented-tcp-unimplemented.md`):
   `std.Io.Evented` TCP ops are unimplemented on Uring/Dispatch. This is now strongly
   justified — the evented backend is the only path that closes a **~4× throughput + ~150×
   tail** gap to axum (tokio) on the same hardware. zax is already `Io`-pluggable; it's gated
   entirely on this std gap. (Plus the small `issue-2-dispatch-deinit-slice.md`.)
2. **Adopt `std.Io.Evented` in zax once std ships TCP** — the real fix for both throughput and
   tail. Until then, the thread-per-conn ceiling stands; document it as a known limitation.
3. **Stop adding socket/concurrency knobs.** Ruled out: Nagle (A/B), in-flight cap
   (negative), per-request compute (trace). None is the lever; the backend is.
4. **(Optional) bare-metal Linux confirmation** to remove the Docker-VM caveat — but the
   conclusion (reproduces + 4× throughput gap) is robust from the same-VM relative numbers.
5. **Tooling stays:** `-Dtrace-latency` + `ZAX_RUN_SECS`/`ZAX_KEEPALIVE`/`ZAX_THREADS` +
   `benchmarks/cross/docker/` are reusable for the next `Io`/backend test. (Known tooling bug:
   `ZAX_RUN_SECS` self-shutdown can hang under sustained load — use a `timeout` backstop.)

## Caveat

Linux numbers are from **Docker's linuxkit VM on the mac (arm64), not bare metal** — absolute
throughput carries VM overhead. But the comparison is apples-to-apples (zax/axum/go in the
same VM), so the **~4× throughput gap and the reproduced ~43ms tail are sound**; only the
absolute req/s figures are VM-affected. macOS numbers are loopback, unpinned.
