# Work-Stealing Spike — Evented Reactor `max`-under-vCPU-steal

**Status:** IN PROGRESS — harness built (commit d549dcc on `spike/work-stealing`), **gate run PENDING (Chris runs on a Linux VM).** Throwaway branch; deliverable = this doc + recorded numbers. Do NOT merge the prototype.

## Question
Does *any* work-stealing scheme actually recover the evented reactor's worst-case `max` latency
under vCPU steal — enough to justify the invasive production design (live fd migration across
pollers + cross-worker sync, which breaks the proven zero-sync shared-nothing model)?

## Context / prior art
The evented reactor (N shared-nothing workers, SO_REUSEPORT, one epoll/kqueue+timer+slot-pool per
worker; conns never cross workers; only shared state = a `shutdown` atomic) is the throughput leader
(1.65–1.9× axum) with best p99.9 on cloud Linux VMs. The one measured weak spot: worst-case `max`
under cloud-VM **vCPU steal** — a descheduled worker's owned keep-alive conns stall while other
workers' vCPUs idle (tokio work-steals across this; zax can't). p99.9 unaffected; only `max`.
SMT was ruled out (SMT-aware PIN didn't fix `max` → confirmed vCPU-steal, not SMT — commits
`8531c0f`, `ebb6721`). See `docs/superpowers/specs/2026-06-17-latency-stall-findings.md`.

Why a steal is *implementable* at all: the IO layer imposes no thread affinity — `sockTransport`
is a stateless fd vtable; epoll/kqueue is level-triggered (a re-added fd re-fires on the new owner);
`Worker.wake()` is safe from any thread; `serveEvented` already registers `evented_workers` for
cross-thread access. The ONLY single-owner invariant is unsynchronized mutation of `slot.conn` +
slot arena/buffers. A steal is correct iff exactly one thread touches a slot at a time.

## Harness (built — commit d549dcc)
- `benchmarks/cross/zax/src/main.zig`: `ZAX_WORKERS=N` forces N evented workers (0/unset = ncpu).
- `benchmarks/cross/run.sh`:
  - `STEAL=cpuset STEAL_CORES=M` — pins the zax server to cores `0..M-1` and runs `ZAX_WORKERS=2M`
    workers on them (oversubscription → OS descheduling = the steal analogue); client pinned to the
    disjoint remainder `M..nproc-1`.
  - `STEAL=hog` — additionally pins a busy-loop to core 0 during each load window (sharper
    single-core starvation), freed after.
  - Linux/taskset only. Use with `BACKEND=evented`.

## GATE RUNBOOK (Chris — run on a Linux VM; the VM must have ≥ STEAL_CORES+spare cores)
The bench builds zax as a path dependency against the working tree, so run from this branch:

```
git fetch && git checkout spike/work-stealing
cd benchmarks/cross
# choose STEAL_CORES so 2*STEAL_CORES workers oversubscribe; leave cores for the client.
# e.g. on an 8-vCPU VM: STEAL_CORES=2 → 4 workers on 2 cores, client on cores 2-7.

# Run A — baseline, no steal (reference MAX):
DURATION=30s CONNS=64 BACKEND=evented ./run.sh 2>&1 | tee /tmp/steal-A-baseline.txt

# Run B — cpuset oversubscription steal (the symptom):
DURATION=30s CONNS=64 BACKEND=evented STEAL=cpuset STEAL_CORES=2 ./run.sh 2>&1 | tee /tmp/steal-B-cpuset.txt

# Run C (sharper) — pinned hog on top (STEAL=hog implies the cpuset oversubscription AND the hog):
DURATION=30s CONNS=64 BACKEND=evented STEAL=hog STEAL_CORES=2 ./run.sh 2>&1 | tee /tmp/steal-C-hog.txt
```
Run each ≥3× (tail is noisy — report median + spread of the **static `GET /` MAX**). Also capture
host steal with `vmstat 1` (the `st` column) during a run, to confirm the induction is real.

**GATE CRITERION:** Run B (and/or C) must show the zax-ev `static` **MAX** materially worse than
Run A (the blow-up the production steal exhibits). If B/C do NOT reproduce a `max` blow-up, the
cpuset analogue is insufficient → escalate to SIGSTOP/SIGCONT of one worker thread before building
the prototype (or conclude the Mac/VM can't reproduce and defer). **Paste the three result tables
back to me; I record them below and decide whether to build T2/T3.**

## Measurement protocol (AFTER gate passes — T4)
On the same VM, ≥3 trials/config, report median + spread of `static GET /` MAX:
1. Baseline no-steal (Run A above) — reference.
2. Evented + steal, baseline binary (Run B/C) — injured `max`; confirm steal-window count > 0 (T2).
3. Evented + steal + prototype (`-Dwork-steal=true`, T3) — treated `max`.

**Pre-registered decision criterion — ship a production design only if ALL hold:**
- Recover ≥50% of the injury: `(max_2 − max_3) / (max_2 − max_1) ≥ 0.5`.
- Throughput (run 3) within 5% of baseline.
- p99.9 (run 3) ≤ baseline + 10%.
- Steal-window counts comparable between runs 2 and 3 (recovery from *processing* stolen work,
  not from fewer steals).

Verdict ∈ {**RECOVER** → greenlight invasive design / **NEEDS-DIFFERENT-DESIGN** / **NOT-WORTH-IT**
→ shared-nothing stands}.

## Planned prototype (T3 — build ONLY if gate passes; throwaway, NOT shippable)
Detect-and-migrate via a watchdog (chosen over a shared MPMC ready-queue or a global shared epoll —
both front-load the hard concurrent-`step` problem). Migration = handoff of exclusive ownership at a
quiescent point, not concurrent access, so the single-owner invariant holds:
- Watchdog thread in `serveEvented` via `worker_ptrs`; each worker publishes `last_progress_ns`
  (T2 counter); a worker stale >~20 ms with active slots = stalled.
- Migrate only parked/idle slots (`keep_alive_idle`/`reading_head`, no in-flight `step`): per-slot
  atomic claim (`std.atomic.Value(u8)` CAS — Zig 0.16 has no `std.Thread.Mutex`), `src.poller.del(fd)`,
  hand fd to a destination free slot, `dst.poller.add(...)`, `dst.wake()`. Destination's normal
  `run()` processes it (reuses `step`/`handleStepResult`).
- **Explicit cuts (NOT shippable):** no return migration; move fd + re-init conn state on
  destination (valid at request boundaries; mid-request conns left behind → honestly count against
  `max`); drop migrated deadlines. The prototype `max` is a **best-case lower bound** — a negative
  result kills stealing cheaply; a positive result still leaves hard production work unproven.

## Results — gate run 2026-06-18 (Chris, 64-vCPU cloud Linux VM, STEAL_CORES=2, single trial)

`static GET /` row per run (full tables in /tmp/steal-{A,B,C}.txt):

| run | induction | zax-ev req/s | zax-ev p50 | zax-ev p99 | zax-ev p99.9 | zax-ev MAX | axum MAX | httpz MAX |
|-----|-----------|-------------:|-----------:|-----------:|-------------:|-----------:|---------:|----------:|
| A | none (baseline) | 714009 | 0.076 | 0.225 | **0.438** | **34.06** | 15.19 | 14.22 |
| B | STEAL=cpuset (4 workers / 2 cores) | 137381 | 0.173 | 9.92 | 20.39 | 36.82 | 15.11¹ | 7.39¹ |
| C | STEAL=hog (cpuset + core-0 hog) | 97291 | 0.152 | 16.48 | 28.29 | 42.13 | 16.01¹ | 9.57¹ |

¹ axum/go/httpz are NOT pinned by STEAL (it applies the cpuset to the zax passes only), so they ran on
all 64 cores in B/C — their columns are NOT comparable to zax-ev under steal. Only zax A-vs-B/C is valid.

### Analysis — the cpuset/hog induction does NOT reproduce the target signature
- **Production vCPU-steal signature** (the thing we want to fix): p99.9 *intact*, an isolated worst-case
  MAX spike, with *idle capacity on other cores* that a thief could use. Baseline **Run A already
  exhibits it**: p99.9 0.438 ms (best of all four) but MAX 34.06 ms (~2.3× axum/httpz ~15 ms), produced
  by the shared VM's background hypervisor steal — no induction required.
- **What cpuset/hog actually did**: cramming 4 workers onto 2 cores is *global CPU oversubscription*, not
  isolated steal. The whole distribution shifted up (p99 0.22→9.9→16.5 ms, p99.9 0.44→20→28 ms) and
  throughput collapsed (714k→137k→97k). MAX barely moved (34→42) because it was already steal-dominated
  at baseline. This is the already-studied oversubscription regime (cap A/B negative result,
  `2026-06-17-latency-stall-findings.md`), not the work-stealing target.
- **Why cpuset can't isolate it**: it removes the idle capacity (only 2 server cores), so there is
  nothing to steal *to*. And SIGSTOP can't freeze a single worker thread (job-control signals are
  process-wide on Linux). Faithfully isolating one stalled worker while others stay idle-capable would
  need per-worker CPU-affinity pinning (pin worker[i]→core[i], then hog one core) — reactor-side
  build-gated `chaos` code, not a shell knob.

### Read on the weak spot's magnitude
At 714k req/s × 30 s ≈ 21M requests, the 34 ms figure is the **single worst sample** (p99.9 is 0.438 ms,
best in class). The "weak spot" is a ~1-in-21M tail event ~2.3× the peers' worst sample. Invasive
work-stealing (live fd migration across pollers + cross-worker sync, breaking the zero-sync
shared-nothing model) to shave that single sample is a marginal return.

## Verdict
_(pending Chris decision — build prototype for hard numbers vs document as NOT-WORTH-IT; see below)_

## Verdict
_(pending)_
