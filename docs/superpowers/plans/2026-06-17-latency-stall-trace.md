# Plan: trace the ~35ms per-connection latency stall (localize only)

Executes `docs/superpowers/specs/2026-06-17-latency-stall-trace-design.md`. Investigation —
instrument, run experiments, write findings. **No fix.** Branch `spike/latency-trace`.
Test baseline **155** (must stay green with the flag off).

## Global constraints
- Build-flag gated (`-Dtrace-latency`, default false). With the flag off, the default build
  and all 155 tests are byte-for-byte unchanged (comptime-elided trace path).
- Lock-free aggregation (atomics); no per-request alloc/log in the hot loop.
- Reuse `nowNs(io)` (`src/server.zig:522`). Do not add a time source.

## Task 1 — Build option + phase tracer
- `build.zig`: add `-Dtrace-latency` bool option (default false) → `build_options` module
  exposed to the zax module as `pub const trace_latency: bool`.
- `src/server.zig`: in `handleConn`'s keep-alive loop (~L346), behind
  `if (comptime build_options.trace_latency)`, stamp `nowNs` at loop-top / after `readHead` /
  after `readBody` / after `dispatch` / after `writeResponse`, and feed segment deltas
  (`head`, `body`, `dispatch`, `write`) into a process-global lock-free `Trace` struct
  (atomic per-segment max + count-over-threshold + dominant-segment tally). Dump a summary in
  `requestShutdown` (~L315) and/or a periodic tick.
- Verify: default `zig build test --summary all` → 155 green (flag off, path elided);
  `zig build -Dtrace-latency` compiles.

## Task 2 — Wire the flag through the cross-bench + a non-keep-alive knob
- `benchmarks/cross/zax/build.zig` + `build.zig.zon`: forward `-Dtrace-latency=true` to the
  zax path dependency so the bench server can be built traced. (If forwarding proves heavy,
  use the spec's `src/trace.zig` comptime-const fallback and note it.)
- `benchmarks/cross/zax/src/main.zig`: optional `ZAX_KEEPALIVE=0` env → set
  `Options.keep_alive = false` (for experiment E2, non-keep-alive). Also allow the bench
  server to construct its own `std.Io.Threaded` with a thread/`async_limit` count from
  `ZAX_THREADS` (for E4) instead of `init.io`. Both default to today's behavior.
- `run.sh`: a `TRACE=1` note/flag documenting how to build+run the traced server and dump the
  summary. Curl-smoke only; Chris runs the load.
- Verify: traced bench builds; `bash -n run.sh`; curl-smoke `/`, `/users/42`, `POST /echo`.

## Task 3 — Run experiments + findings doc
Chris runs (needs `oha`); I prep the exact commands + interpret:
- **E1**: traced build under standard oha → per-segment max + dominant tally. Identify the
  35ms segment.
- **E2**: `ZAX_KEEPALIVE=0` (or oha `--disable-keepalive`) → does the tail vanish? (H1)
- **E4**: sweep `ZAX_THREADS` → does the tail move? (H3)
- **E5**: traced build on Linux → does ~35ms reproduce? (macOS artifact vs model)
Write `docs/superpowers/specs/2026-06-17-latency-stall-findings.md`: dominant segment + its
distribution, hypothesis that held, component to blame, recommended fix theme.

## Verification
1. `zig build test --summary all` → 155 green with flag off.
2. `zig build -Dtrace-latency` (lib) + `( cd benchmarks/cross/zax && zig build -Dtrace-latency=true -Doptimize=ReleaseFast )` build; traced server boots, dumps a phase summary on shutdown; curl-smoke passes.
3. `bash -n benchmarks/cross/run.sh`.
4. Experiments run by Chris; findings doc written from real numbers.

## Execution
Subagent-driven (T1 → T2 sequential; both touch build plumbing + server). Task reviews per
task; final whole-branch review. **Stop after localization** — the fix is a separate theme
chosen from the findings. Chris merges/pushes per the usual handoff.

## Out of scope
The fix; a permanent latency-observer feature; touching `src/observe.zig`.
