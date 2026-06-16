# Zax — benchmark harness rigor (E1) design

Date: 2026-06-16. Status: accepted. Scope: sub-project E1 of theme E
(benchmarking), the post-v0.1.0 roadmap's measurement theme. Themes A–D are done.

**Theme E decomposition** (all self-relative — cross-framework comparison is out
of scope for the whole theme; the harness measures zax's own overhead only):

- **E1 (this spec): harness rigor** — warmup, multi-sample statistics
  (median + stddev), and CLI-configurable parameters.
- **E2: allocation/memory metrics** — bytes allocated per request and peak RSS
  per scenario via a counting allocator.
- **E3: coverage** — micro-benchmarks for the middleware chain, `Path`/`Query`/
  `Json` extractors, and wildcard/group routing; extra e2e scenarios.
- **E4: regression baseline** — machine-readable output compared to a committed
  baseline with a tolerance (`--check` exits nonzero on regression); CI-friendly.

E2–E4 build on E1's harness and are out of scope here.

## Context

`src/bench.zig` (run via `zig build bench`, ReleaseFast) has two sections: micro
(parseHead, radix match, response write) and an e2e loopback load (throughput +
p50/p90/p99/max latency). Limitations that make the numbers hard to trust:

1. **Single-shot.** Each measurement runs once. No warmup (first run pays
   cold-cache/JIT-of-nothing/branch-predictor warmup costs), no repeats, so
   run-to-run variance is invisible — a number could be 20% off and you'd never
   know.
2. **Hardcoded parameters.** `iters`, `conns`, `reqs_per_conn` are constants.
   Exploring "what happens at 64 connections" means editing source.
3. **No variance reporting.** A single ns/op or req/sec figure with no spread is
   not a measurement, it's an anecdote.

E1 makes the harness produce trustworthy, configurable numbers — the foundation
E2–E4 depend on.

## Decision (from brainstorming)

1. **Warmup then sample.** Each micro-benchmark runs a discarded warmup pass,
   then `samples` timed passes. The e2e load runs a discarded warmup load, then
   `samples` measured loads.
2. **Report median + sample stddev.** Micros report `median ns/op` and the
   sample standard deviation across passes (ops/sec derived from the median).
   The e2e load reports median throughput + its stddev, and latency percentiles
   from the median-throughput sample.
3. **CLI flags with current values as defaults.** `--iters N`, `--conns N`,
   `--reqs N`, `--samples N`, `--warmup N`. Defaults reproduce today's run shape
   (with `samples`/`warmup` defaulting on). Bad flags print usage and exit
   nonzero.
4. **Pure, testable helpers.** Argument parsing and statistics
   (`median`/`stddev`/`percentile`) live in a new `src/bench/metrics.zig`, unit-
   tested under `zig build test` via a dedicated bench test target. The timing
   loops in `bench.zig` stay thin wrappers around them.
5. **Duration-based load is deferred** (a possible E1 follow-up). Configurable
   `--reqs` + sampling already deliver the rigor; duration mode adds
   dynamically-sized latency buffers without changing the methodology story.

## Architecture

```
zig build bench -- --conns 64 --reqs 2000 --samples 5 --warmup 1
        |
   metrics.Config.parse(argv)            (src/bench/metrics.zig, tested)
        |
   micro: warmup pass; then `samples` timed passes -> [ns/op...]
          -> metrics.median / metrics.stddev -> report
   e2e:   warmup load; then `samples` loads -> [req/sec...], latencies
          -> median throughput + stddev; metrics.percentile on median sample
```

`src/bench/metrics.zig` is a leaf module (no `zax`/`Io` dependency) holding only
pure functions + the `Config` parser, so its tests are fast and deterministic.
`src/bench.zig` imports it and keeps the I/O/timing/socket code.

## Components

### 1. `src/bench/metrics.zig` (new, pure + tested)

```zig
pub const Config = struct {
    iters: usize = 2_000_000,
    conns: usize = 8,
    reqs: usize = 5_000,
    samples: usize = 5,
    warmup: usize = 1,
};
pub const ParseError = error{ UnknownFlag, MissingValue, BadValue };
/// Parse argv (excluding argv[0]); unknown/missing/bad flags -> ParseError.
pub fn parse(args: []const []const u8) ParseError!Config { ... }

pub fn median(samples: []f64) f64 { ... }        // sorts a scratch copy or in place
pub fn stddev(samples: []f64) f64 { ... }        // sample stddev (n-1); 0 for n<2
pub fn percentile(sorted: []const i96, p: usize) i96 { ... } // moved from bench.zig
```

### 2. `src/bench.zig` refactor

- `main` reads process args (skip argv[0]), calls `metrics.parse`; on error,
  prints a one-line usage to stderr and exits nonzero.
- `microBenchmarks` takes `Config`; each micro: one warmup pass of `cfg.iters`,
  then `cfg.samples` timed passes, collecting ns/op into a stack/`gpa` buffer,
  then `report(name, median, stddev, ops/sec)`.
- `endToEnd` takes `Config`; runs `cfg.warmup` discarded load(s), then
  `cfg.samples` measured loads (each `cfg.conns` × `cfg.reqs`), recording per-
  sample throughput; reports median throughput + stddev and the latency
  percentiles of the median-throughput sample.
- `report` is widened to print `median ns/op`, `± stddev`, and `ops/sec`.

### 3. `build.zig` (two additive changes)

- Forward args to the bench run: `if (b.args) |args| bench_run.addArgs(args);`.
- Add a bench test target so `metrics.zig` tests run under `zig build test`:
  `const bench_tests = b.addTest(.{ .root_module = bench_exe.root_module });
   test_step.dependOn(&b.addRunArtifact(bench_tests).step);`.

## Testing

- **Unit (run under `zig build test`):** `metrics.parse` — defaults, each flag,
  unknown flag → `UnknownFlag`, missing value → `MissingValue`, non-integer →
  `BadValue`. `median` — odd/even lengths, unsorted input. `stddev` — known
  values, n<2 → 0. `percentile` — p50/p99/edge on a small sorted slice.
- **Manual (run under `zig build bench`):** default run prints `median ns/op ±
  sd` and median throughput; `zig build bench -- --samples 2 --conns 2 --reqs
  500 --warmup 1` honors the flags and finishes quickly; a bad flag
  (`--nope`) prints usage and exits nonzero.
- **Regression:** full `zig build test` stays green (123 + new metrics tests).

## Files

- Add: `src/bench/metrics.zig`.
- Modify: `src/bench.zig` (use metrics; warmup + sampling + CLI), `build.zig`
  (arg forwarding + bench test target).
- Modify: `README.md`, `docs/getting-started.md` (bench flags + sampling note).

## Risks & edge cases

- **Measurement perturbation:** collecting per-sample results uses a tiny buffer
  outside the timed region; the timed loops are unchanged in shape, so ns/op
  stays comparable to today's single-shot numbers (now median of N).
- **`samples`/`warmup` = 0:** treat `warmup 0` as "no warmup"; `samples` must be
  ≥1 (parse rejects 0 as `BadValue`).
- **Runtime cost:** default `samples = 5` multiplies wall time ~5×; the e2e load
  is small (8×5000) so this stays a few seconds. Documented.
- **Arg source:** uses the process args (`std.process.argsAlloc` or the
  `std.process.Init` args), skipping argv[0]; the build forwards everything after
  `--`.

## Out of scope

Duration-based load (`--duration`), allocation/memory metrics (E2), expanded
coverage (E3), regression baselines/CI (E4), cross-framework comparison (whole
theme E).
