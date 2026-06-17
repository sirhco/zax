# Plan: bounded in-flight connections (worker-pool cap)

Executes `docs/superpowers/specs/2026-06-17-bounded-worker-pool-design.md`. Additive,
default-off, no architecture change. Branch `feat/bounded-in-flight`. Test baseline **153**.

## Global constraints
- Purely additive. `max_in_flight = 0` (default) → today's behavior, byte-for-byte.
- `Io`-agnostic: use `std.Io.Semaphore`; no dependence on `Io.Threaded` internals.
- No edits to `handleConn`'s existing body beyond the new trailing param + the release
  `defer`. Keep the per-conn arena / keep-alive loop untouched.
- All 153 existing tests stay green; new tests added on top.

## Task 1 — Option + acceptLoop backpressure
`src/server.zig`:
- Add `max_in_flight: usize = 0` to `Options` (~L39) with the doc comment from the spec.
- Rewrite `acceptLoop` (L277) per the spec: stack `var sem: Io.Semaphore = .{ .permits =
  max_in_flight }`; `const cap = max_in_flight != 0`; `if (cap) sem.waitUncancelable(io)`
  before `accept`; `if (cap) sem.post(io)` on the accept-error break; pass
  `if (cap) &sem else null` as a new trailing arg to `conn_group.async(handleConn, …)`.
- Add trailing param `sem: ?*Io.Semaphore` to `handleConn` (L300) and `defer if (sem) |s|
  s.post(io);` as its first statement. Body otherwise unchanged.
- Verify: `zig build test --summary all` → 153 still green (no behavior change at default 0).

## Task 2 — Cap-enforcement test (deterministic)
`src/server.zig` tests (the `Io.Threaded` + loopback block ~L610):
- Add a test app whose handler increments an atomic `in_flight` on entry, updates an atomic
  `max_seen` (CAS-max), briefly parks (e.g. waits on a small `Io` sleep / a condition so
  several requests overlap), decrements on exit.
- Start the server with `Options{ .max_in_flight = 2 }`; fire e.g. 8 concurrent client
  requests (spawn them as Group tasks against the loopback port); await all.
- Assert all 8 responses are correct (cap throttles, never drops) AND `max_seen <= 2`
  (the cap held). This deterministically proves backpressure without timing flakiness.
- Add a second test: `Options{ .max_in_flight = 0 }` (default) serves the same 8 concurrently
  with `max_seen` allowed > 2 — i.e. unbounded path still works. (Assert correctness; do not
  assert an exact max — just that all succeed.)
- Expected: baseline 153 → ~155.

## Task 3 — Bench A/B + docs
- `benchmarks/cross/zax/src/main.zig`: read `ZAX_MAX_INFLIGHT` env (default 0) and pass it
  as `Options.max_in_flight`, mirroring the existing `ZAX_NODELAY` knob. Print it on boot.
- `benchmarks/cross/run.sh`: extend so zax can run capped vs uncapped in one pass (reuse the
  `AB=1` pattern shape — e.g. an `INFLIGHT=<n>` that adds a `zax-cap<n>` row alongside the
  default `zax`). Curl-smoke only; Chris runs the oha numbers.
- `benchmarks/cross/results.md`: add a "Worker-pool cap" section — `zax` (uncapped) vs
  `zax-cap<ncores>` on p99.9/max vs axum/go. Verdict line to fill after running.
- `benchmarks/cross/README.md` + the app-level `Io.Threaded.async_limit` snippet from the
  spec (the complementary runtime-level tuning zax can't set itself).

## Verification
1. `zig build test --summary all` → ~155, green; default path unchanged.
2. `( cd benchmarks/cross/zax && zig build -Doptimize=ReleaseFast )` builds; boot prints the
   cap; curl serves `/`, `/users/42`, `POST /echo` at `ZAX_MAX_INFLIGHT=0` and `=4`.
3. `run.sh` cap-vs-uncapped wiring dry-runs (curl-smoke). Chris runs `oha` → fills
   `results.md`. **Success signal:** capped zax p99.9/max collapses toward axum/go while
   median + throughput hold. That is the theme's payoff (and confirms the decision-doc thesis).

## Execution
Subagent-driven (Task 1 → 2 → 3 sequential; 1 and 2 are coupled in `src/server.zig`).
Task reviews per task; final whole-branch review. Chris merges/pushes per the usual handoff
(this round's merge was an explicit one-off).

## Out of scope
Reject/503 overflow mode, SO_REUSEPORT, cancelable-wait shutdown refinement — noted in the
spec's limitations / out-of-scope; revisit if the cap alone doesn't fully flatten the tail.
