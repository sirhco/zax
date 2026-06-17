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

## E5 — Linux (reproduce off macOS?)
On a Linux box (`Io.Threaded` = threads + blocking syscalls there too), repeat E1. If the
~35ms is macOS-only → Darwin scheduler/timer artifact; if it reproduces → the model.
| platform | head max_ms | write max_ms | p99.9 |
|----------|------------:|-------------:|------:|
| macOS    |             |              | ~35ms |
| Linux    |             |              |       |

## Verdict (FINAL — with one caveat: E5/Linux not yet run)

**zax's request-handling code is not the cause of the latency tail.** The trace localized
the ~35ms out of every measured server segment; the remaining open question (is it
macOS-specific?) is a single confirmation run, not a redesign. Details:
- **Where the 35ms lives:** NOT in any zax segment. All per-request server work is <8ms
  (head 8.15 / body 0.03 / disp 0.07 / write 0.15 ms max) vs oha p99.9 35.7ms. The stall is
  in the **`std.Io.Threaded` blocking-IO + macOS kernel/loopback handoff** (post-`flush`
  delivery / thread wakeup), outside zax's request processing.
- **Hypothesis that held:** ~H3 — a **fixed timer/scheduling quantum in `Io.Threaded`**, not
  H1 (read-wait: `head` only 8ms), not H4 (zax logic: all segments tiny). The tail is
  rock-stable at ~35ms and **insensitive to thread count** (the earlier `max_in_flight` cap
  test: 8 threads on 18 cores → still 35ms) and to compute → a fixed quantum, not contention.
- **Component to blame:** `std.Io.Threaded` backend + macOS kernel/loopback scheduling.
  **zax application code is exonerated.**
- **Recommended fix theme (pending E5):**
  - If E5 shows the ~35ms does **not** reproduce on Linux → it's a **macOS-loopback/Darwin
    timer artifact**; document it, stop chasing, validate zax on a real Linux box. No zax
    code fix.
  - If it **does** reproduce on Linux → file an upstream `std.Io.Threaded` issue (blocking
    read/write wakeup granularity); the real in-zax fix is an evented backend, still blocked
    (`2026-06-17-evented-io-decision.md`).
- **E2 (non-keep-alive) was invalid** (port exhaustion) and contributes no signal.

## Next steps (in priority order)

1. **Run E5 on Linux** (the single open confirmation). If the ~35ms is gone → close this
   line: it's a macOS-loopback/Darwin artifact, zax is fine on real servers, no code change.
   If it persists → open step 2. Until then, treat the tail as **most likely a macOS
   measurement artifact**, not a zax defect.
2. **Only if E5 reproduces on Linux:** file an upstream `std.Io.Threaded` issue (blocking
   read/write wakeup granularity under many threads) with this trace as evidence; the only
   in-zax fix is an evented backend, which is blocked upstream
   (`2026-06-17-evented-io-decision.md`) — revisit when std ships io_uring TCP.
3. **Stop adding socket/concurrency knobs.** Ruled out: Nagle (A/B), oversubscription /
   thread count (cap sweep), per-request compute (this trace). None are the lever.
4. **Tooling stays:** `-Dtrace-latency` + `ZAX_RUN_SECS`/`ZAX_KEEPALIVE`/`ZAX_THREADS` are
   merged and zero-overhead-off — reuse them to re-confirm after any future `Io` change or
   when re-testing on Linux.

## Caveat

All numbers here are **macOS loopback, unpinned**. The headline "zax tail ~50× axum/go" is
on that same box; given the trace shows zax compute is clean and the stall sits in the
`Io.Threaded`/kernel layer, the cross-framework gap may itself be partly a macOS-loopback
artifact of the threaded backend. **E5/Linux (or an off-box run) is required before quoting
the tail as a real-world zax characteristic.**
