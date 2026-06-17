# Design spec — trace the fixed ~35ms per-connection latency stall

Investigation theme (localize only — no fix this round). Read first:
`benchmarks/cross/results.md` (the negative cap result) and
`2026-06-17-evented-io-decision.md`.

## Problem

zax has the best median of zax/axum/go (~0.086ms) and competitive throughput (~160k
req/s), but a **fixed ~35ms p99.9 / ~50ms max** that is rock-stable across every config
tested: 64-conn uncapped, capped to 8 in-flight (8 threads on 18 cores — undersubscribed),
Nagle on/off. axum (~0.55ms) and go (~1.4ms) on the identical loopback/oha do not have it.
Ruled out: Nagle, CPU oversubscription, socket tuning. Evented IO is blocked upstream. The
tail is therefore a **fixed periodic stall inside zax's per-connection serving path on
`std.Io.Threaded`**, independent of load.

## Goal

**Localize the 35ms to one phase and one component** (zax logic vs `Io.Threaded` vs OS).
Output is a findings doc naming where the time goes and the recommended fix theme — no fix
implemented here.

## Instrumentation — build-flag phase timer

Compile-time gated, **zero overhead when off**. Add a build option `-Dtrace-latency`
(default false) to zax's `build.zig`, exposed to source via a `build_options` module as a
`pub const trace_latency: bool`. In `handleConn`'s keep-alive loop (`src/server.zig:346`),
behind `if (comptime build_options.trace_latency)`, stamp the existing `nowNs(io)` at phase
boundaries:

```
t_loop  = nowNs (loop top, after arena.reset)
  readHead(...)          // ← keep-alive read wait: the prime suspect
t_head  = nowNs
  readBody(...)
t_body  = nowNs
  dispatch(...)
t_disp  = nowNs
  writeResponse(... + flush)
t_write = nowNs
```
Segments: `head = t_head-t_loop` (wait for + parse next request), `body`, `dispatch`,
`write = t_write-t_disp`. Record into a process-global lock-free struct (one set of
`std.atomic.Value` per segment): running **max** (CAS-max), **count over threshold** (e.g.
>5ms), and the **segment that dominated** each slow request. Dump the summary on
`requestShutdown` (and/or every N seconds). Under load, do NOT log per-request (floods) —
aggregate.

Plumbing note: the cross-bench zax is a path dependency, so its `build.zig`/`build.zig.zon`
must forward `-Dtrace-latency=true` to the zax dependency. If that proves heavy, fallback to
a `comptime pub const trace_latency` in a dedicated `src/trace.zig` flipped for the spike
build. Prefer the build option.

## Hypotheses (ranked)

- **H1 — keep-alive read wakeup (`readHead`→`cr.fill`→`receiveTimeout`, `src/server.zig:559`).**
  Under oha keep-alive the client sends the next request immediately, so `head` *should* be
  ~0. A 35ms `head` = the serving thread was parked and `Io.Threaded` woke it late → the
  stall is **scheduler/wakeup latency**, not zax logic. Most likely.
- **H2 — write/flush (`writeResponse`→`w.flush()`→socket send).** A 35ms `write` = send-side
  stall (kernel buffer / scheduling).
- **H3 — `Io.Threaded` timer/poll granularity.** A coarse internal wait quantum would pin the
  tail near a fixed value regardless of load (consistent with the rock-stable ~35ms).
- **H4 — zax logic (arena, parse).** Unlikely (median is excellent; arena reset retains), but
  the `dispatch`/`body` segments will confirm or exclude it.

## Experiments (each isolates one variable)

- **E1 — phase distribution under load.** Traced build + standard oha → which segment carries
  the 35ms. The headline result.
- **E2 — non-keep-alive.** Drive with `Connection: close` (oha flag or a bench variant). If
  the tail vanishes, it's the keep-alive read-wait (H1). If it persists, it's per-request
  write/dispatch.
- **E3 — trivial vs JSON handler.** Already known equal across `/`, `/users`, `/echo` → handler
  work isn't the cause; the trace confirms `dispatch` is small.
- **E4 — thread count.** Have the bench server construct its own `Io.Threaded` with varied
  `async_limit`/thread count (instead of `init.io`); does the tail move? Tests H3.
- **E5 — platform.** Run the traced build on **Linux** (`Io.Threaded` there is threads +
  blocking syscalls too). If the ~35ms is macOS-only, it's a Darwin scheduler/timer artifact;
  if it reproduces on Linux, it's the model. Also satisfies the off-box check.

## Deliverable

`docs/superpowers/specs/2026-06-17-latency-stall-findings.md`: the dominant segment + its
value distribution, which hypothesis held, the component to blame (zax / `Io.Threaded` / OS),
and the recommended fix theme (e.g. a different read/wait strategy, an `Io.Threaded` config,
an upstream std issue, or "wait for evented TCP"). No fix this round.

## Constraints
- Build-flag gated; **default build + all 155 tests unaffected** (the traced path is comptime
  elided when off).
- Use the existing `nowNs(io)`; no new time source. Aggregation lock-free (atomics), no per-
  request allocation or logging in the hot loop.

## Out of scope
The fix itself; any permanent latency-observer feature (the existing `src/observe.zig` hook is
left alone). Decided after localization.
