# Plan: Theme G — evented-IO exploration (spike + enhancement sweep)

## Context

The 2026-06-17 cross-framework bench showed zax has the **best median (~0.086ms, ~4× axum)
and competitive throughput (~160k req/s, beats go)** but a **p99.9/max tail ~50× worse**
(zax ~36/51ms vs axum ~0.65/5ms, go ~1.5/8ms). The A/B proved `TCP_NODELAY` helps p99 but
not the 35ms cluster → the tail is the **thread-per-connection model** (`std.Io.Threaded`,
one OS thread/conn) under same-host oversubscription, not a socket option. axum (tokio M:N)
and go (goroutines) stay flat on the *same* box because of their schedulers.

**Decisive grounding (this session):**
- zax is **already `Io`-pluggable** — `src/server.zig:4-5` states the same `serve`/
  `acceptLoop` run on `Io.Threaded` today and a future `Io.Evented` unchanged. The swap is
  at the **entry point** (which `Io` you construct), not server internals.
- `std.Io.Evented` **exists in Zig 0.16**, gated on `fiber.supported` (true on aarch64 +
  x86_64 + riscv64): **Linux → `Uring` (io_uring)**, **macOS → `Dispatch` (GCD)**, BSD →
  `Kqueue`. Construct: `var ev: Io.Evented = undefined; try ev.init(gpa, .{}); const io =
  ev.io();` then pass `io` to `serve`.

**Goal of this theme:** cheaply test whether evented IO flattens zax's tail toward axum/go,
and sweep for other enhancements worth a theme — *before* committing to a full migration.

**Decisions (confirmed):** run the code spike + same-box bench this session (code on this
branch, Chris merges); off-box validation = a **documented procedure** for Chris to run
(no second machine driven from here). The actual `oha` load runs are executed by Chris
(`oha` not installed in this session) — I build + curl-smoke both Io backends and wire the
harness.

## Execution model

Subagent-driven. Research tasks (G3–G5) are read-only and **independent → dispatched in
parallel**. Code tasks (G1→G2) are sequential on this branch. G6 is a doc. G7 synthesizes
everything (bench numbers land when Chris runs the AB).

## Tasks

### G1 — Evented-Io variant of the cross-bench zax server  *(code, spike)*
Add an `Io` selector to `benchmarks/cross/zax/src/main.zig`: env `ZAX_IO=evented` (default
`threaded`) constructs `std.Io.Evented` (`ev.init(init.gpa, .{})`, `ev.io()`, `defer
ev.deinit()`) and passes it to `app.serve`; otherwise keep `init.io`.
- **Discover & document** the evented run model: does `serve`'s accept loop +
  `conn_group.async` run concurrently on `Io.Evented` as-is, or does the backend need its
  event loop driven (Dispatch `main_loop`)? Capture any API friction in the report.
- **Verify:** builds ReleaseFast; both `ZAX_IO=threaded` and `ZAX_IO=evented` serve all 3
  routes via curl (`/`, `/users/42`, `POST /echo`); print the selected backend on boot.
- If `Io.Evented` cannot serve unchanged, **stop and report the exact blocker** (this is a
  valid spike outcome — it tells us the "unchanged" claim needs work).

### G2 — Wire Threaded-vs-Evented A/B into the harness  *(code)*
Extend `benchmarks/cross/run.sh` so zax can run under both backends in one pass (reuse the
`AB=1` pattern: an `IO=evented`/`both` selector that launches zax-threaded and zax-evented
rows, env `ZAX_IO` set per pass). Curl-smoke only here; Chris runs the oha numbers. Add an
`results.md` section: zax-threaded vs zax-evented on p99.9/max vs axum/go.

### G3 — `std.Io.Evented` readiness deep-dive  *(research, parallel, read-only)*
Map `Io/Dispatch.zig` (mac), `Io/Uring.zig` (linux), `Io/Kqueue.zig`: init/deinit, the
`io()` vtable, how concurrency/async is realized, the run/drive model, limits, known gotchas
(blocking syscalls, file IO, signals), and whether zax's `acceptLoop`/`Io.Group` usage is
compatible. Deliverable: readiness report + the minimal correct construction/run snippet.

### G4 — Zig HTTP-server concurrency landscape  *(research, parallel, read-only)*
Survey how other Zig HTTP servers handle concurrency/tail latency (e.g. httpz, zzz, zap,
tokamak, http.zig, zinc). Who uses io_uring/evented vs thread-per-conn? What patterns
(SO_REUSEPORT, multi-acceptor, fixed worker pools) do they use? Deliverable: landscape table
+ which patterns transfer to zax.

### G5 — Enhancement sweep beyond evented IO  *(research, parallel, read-only)*
From the zax hot path, enumerate + rank other levers: thread-pool-size Option (cheap interim
for Threaded), `SO_REUSEPORT` + sharded acceptors, accept-loop backpressure / conn caps,
`sendfile`/zero-copy for static bodies, keep-alive/timeout tuning, buffer-size defaults,
header-parse micro-opts. Each: expected impact, effort, blast radius, additive? Deliverable:
ranked candidate list (don't implement).

### G6 — Off-box measurement procedure  *(doc)*
Write a runnable procedure (in `benchmarks/cross/README.md` or a sibling) for Chris: oha from
a second LAN machine against this mac, **or** Linux `PIN=1` (io_uring Evented backend), with
an analysis template to drop into `results.md`. Purpose: confirm the ~50× tail is the model,
not same-host oversubscription.

### G7 — Theme G synthesis / decision doc  *(synthesis, last)*
Fold G1–G6 into `docs/superpowers/specs/2026-06-17-evented-io-decision.md`: does evented IO
flatten the tail (from the spike + AB once Chris runs it)? Is it worth a full Theme G
implementation? Recommended next steps + a rough implementation-plan outline, or a "not yet /
blocked because X" verdict. Update the headroom assessment's lever ranking with findings.

## Global constraints
- **Spike, not production.** Code stays in `benchmarks/cross/` + entry points; do **not**
  change `src/server.zig` server internals this round (the whole point is that it's already
  pluggable — prove it without edits).
- Purely additive, default behavior unchanged (`ZAX_IO` unset = today's `Io.Threaded`).
- Test baseline **153** must stay green (`zig build test --summary all`).
- Honest reporting: a spike that finds `Io.Evented` *not* ready is a successful spike.

## Verification
- `zig build test --summary all` → 153, green.
- `( cd benchmarks/cross/zax && zig build -Doptimize=ReleaseFast )` builds.
- Both backends serve 3 routes via curl (G1).
- `run.sh` A/B wiring dry-runs (G2); Chris runs oha → fills `results.md`.
- G3–G5 findings docs exist; G7 decision doc references them.

## Out of scope (this round)
Full evented-IO migration of `src/server.zig`; implementing any G5 enhancement; CI changes.
All deferred to Theme G proper, gated on G7's verdict.
