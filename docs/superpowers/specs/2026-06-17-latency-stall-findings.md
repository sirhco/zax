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
| head    |        |         |          |
| body    |        |         |          |
| disp    |        |         |          |
| write   |        |         |          |

**Which segment carries the ~35ms:** ______

## E2 — non-keep-alive (`ZAX_KEEPALIVE=0`)
Does the tail vanish without keep-alive? (isolates H1, the read-wait.)
```sh
ZAX_KEEPALIVE=0 ZAX_RUN_SECS=35 ./zig-out/bin/zax-bench 2>trace-e2.log &
oha -z 30s -c 64 --no-tui http://127.0.0.1:8081/   # (oha keep-alives by default; the server closes each conn)
wait; grep latency-trace trace-e2.log
```
| segment | max_ms | over5ms | dominant |  | tail vanished? |
|---------|-------:|--------:|---------:|--|----------------|
| head    |        |         |          |  |                |
| write   |        |         |          |  |                |

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

## E5 — Linux (reproduce off macOS?)
On a Linux box (`Io.Threaded` = threads + blocking syscalls there too), repeat E1. If the
~35ms is macOS-only → Darwin scheduler/timer artifact; if it reproduces → the model.
| platform | head max_ms | write max_ms | p99.9 |
|----------|------------:|-------------:|------:|
| macOS    |             |              | ~35ms |
| Linux    |             |              |       |

## Verdict (fill in)
- **Dominant segment / where the 35ms lives:** ______
- **Hypothesis that held** (H1 read-wakeup / H2 write-flush / H3 Io.Threaded granularity / H4 zax logic): ______
- **Component to blame** (zax logic / `std.Io.Threaded` / OS scheduler): ______
- **Recommended fix theme:** ______ (e.g. different read/wait strategy, an `Io.Threaded`
  config, an upstream std issue to file, or "wait for evented TCP").
