# Theme G decision — evented IO vs the real tail fix

Spike + research outcome for the zax latency-tail problem. Reverses the original
"migrate to evented IO" hypothesis. Read the cross-bench context first:
`benchmarks/cross/results.md` and `2026-06-17-perf-headroom-assessment.md`.

## Verdict

1. **`std.Io.Evented` is a dead end on macOS and Linux in Zig 0.16** — its TCP socket
   ops are unimplemented. Not viable for a server today; not zax's bug to fix (upstream
   std maturity).
2. **zax's `Io` abstraction is correct and pluggable** — the spike confirmed the
   fiber-entry construction works; only the std *backend* is missing TCP.
3. **The real, available tail fix is the *same* concurrency model, bounded**: cap the
   worker/thread count (~cores) + add connection backpressure. zax currently spawns an
   **unbounded** thread per accepted connection — that is the oversubscription that
   produces the ~50× p99.9/max tail. This is cheap, additive, and testable on this box
   now. **This becomes the recommended Theme G.**

## Evidence

### The spike (authoritative — it ran)
`benchmarks/cross/zax` gained a `ZAX_IO=evented` selector (commit `da493c6`; refusal
cleanup `f05b80b`). Constructing `std.Io.Evented` and running `Api.serve` inside a fiber
(`io.async`/`future.await`) — the fiber-entry model — **works**. But `serve` aborts
(SIGABRT) on `listen()` → `error.NetworkDown`, which the evented runtime panics on inside
the fiber rather than returning catchably.

### Why: std's evented backends have no TCP (Zig 0.16)
| Backend | Platform (`Io.Evented` resolves to) | TCP listen/accept/send/read |
|---|---|---|
| `Io/Dispatch.zig` | **macOS** (GCD) | all `*Unavailable` stubs |
| `Io/Uring.zig` | **Linux** (io_uring) | only `netBindIp` real; listen/accept/send/read `*Unavailable` |
| `Io/Kqueue.zig` | BSD only (freebsd/netbsd/openbsd/dragonfly) | real listen/accept — but **not selected on macOS or Linux** |

So the two platforms that matter both stub TCP. Kqueue (which has it) is unreachable on
our targets. `fiber.supported` is fine (aarch64/x86_64); the gap is socket IO, not fibers.

### Research contradiction, resolved by the spike
The `std.Io.Evented` source-reading research (G3) concluded "fully compatible, zero
changes needed, network IO fully async." That was **wrong** — it read the vtable
optimistically and missed that the net ops are `*Unavailable` stubs. The empirical spike
(G1) caught it. Lesson: for "is X ready" questions, run it; don't trust a read of the
happy path.

## The real lever (from G4 landscape + G5 sweep)

A best-in-class median with a ~50× p99.9/max tail on a thread-per-conn server is the
**scheduler-jitter + head-of-line signature**: with threads > cores, the 1-in-1000
request that hits a timer-tick preemption / run-queue wait / cache-cold migration spikes
into tens of ms while the median stays in µs. Cloudflare and Dropbox writeups confirm the
mechanism. `httpz` (the closest Zig analog to zax) fixes it with a **fixed worker pool
(~cores) + bounded handler queue + per-worker connection cap**.

**Ranked, for a follow-up theme (not implemented this round):**
1. **Bound the worker pool** — expose `std.Io.Threaded`'s `async_limit` (and/or a worker
   count) as a zax `Options` field; default ~`nproc`. Single biggest lever; purely
   additive; testable on mac today. `src/server.zig` `Options` (~L39) + `App.init`
   (~L107) where the `Io.Threaded` is constructed/received.
2. **Connection backpressure** — `Options.max_concurrent_connections`; stop accepting at
   the cap (atomic counter around `acceptLoop`'s `conn_group.async`, `src/server.zig`
   ~L278). Pairs with #1. Also tune kernel accept queue (`somaxconn`, listen backlog).
3. **Buffer pooling / retained arenas** — already largely done (per-conn arena
   reset-retain); confirm no per-request `malloc` under load.
- **Caution (do not cargo-cult):** `SO_REUSEPORT` + sharded acceptors fixes *accept
  lock contention*, not tail — and per Cloudflare can *worsen* tail (uneven per-worker
  queues). Adopt only with equal queue depths + monitoring.
- **Do never:** header-lookup hash table (linear scan over ≤64 headers is fine).

## Alternatives considered

- **`libxev`** (mitchellh) and **`tardy`** (powers `zzz`) both run on Zig 0.16 and give
  real io_uring/kqueue/epoll event loops. **But neither is a `std.Io` backend** — adopting
  either means importing its own loop/coroutine runtime and abandoning zax's clean `Io`
  pluggability (large rewrite, new dep). Not worth it versus lever #1, which closes most
  of the gap within the existing model. Revisit only if pool-bounding plateaus.
- **Wait for upstream** — when std lands io_uring/GCD TCP, the evented swap becomes the
  near-drop-in we originally hoped for (the framework is already ready). Track it; don't
  build against stubs now.

## Recommended next steps

1. **Off-box confirmation** (procedure in `benchmarks/cross/README.md`, "Off-box / true
   tail" section): run `oha` from a second LAN machine, or Linux `PIN=1`, to confirm the
   ~50× tail survives off-loopback (i.e. it's the model, not same-host contention). Chris
   runs; numbers → `results.md`.
2. **New theme: bounded worker pool + backpressure** (lever #1+#2). Spec it; implement
   additively; A/B unbounded vs bounded `async_limit` on the cross-bench p99.9/max. This
   is the likely real win and needs no rewrite.
3. **Track upstream `std.Io.Evented` TCP**; re-spike when Uring/Dispatch implement sockets.

## Status of this round's artifacts
- `benchmarks/cross/zax` — `ZAX_IO` selector (threaded works; evented refuses with the
  finding). `ZAX_NODELAY` A/B from the prior theme unchanged.
- This decision doc + the exploration plan (`docs/superpowers/plans/2026-06-17-evented-io-exploration.md`).
- Headroom assessment lever ranking updated to match (evented demoted, pool-bounding promoted).
- Off-box procedure: `benchmarks/cross/README.md`.
