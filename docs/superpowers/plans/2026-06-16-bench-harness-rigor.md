# Benchmark Harness Rigor (E1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `zig build bench` produce trustworthy, configurable numbers — a discarded warmup pass, multiple samples reported as `median ± stddev`, and CLI flags (`--iters/--conns/--reqs/--samples/--warmup`) with today's values as defaults.

**Architecture:** Extract pure, testable helpers (CLI `Config.parse` + `median`/`stddev`/`percentile`) into a new leaf module `src/bench/metrics.zig` (no `zax`/`Io` deps), unit-tested under `zig build test` via a dedicated bench test target. Refactor `src/bench.zig` to parse args, warm up, then run `samples` timed passes and report median + sample stddev (micros) / median throughput + stddev + median-sample latency percentiles (e2e). Two additive `build.zig` changes: forward `b.args` to the bench run, and add the bench test target.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-bench-harness-rigor-design.md`. Branch: `feat/bench-harness-rigor`.

**Conventions:** Tests via `zig build test --summary all`. TDD for the pure helpers. Bench itself is verified by running `zig build bench` (it prints timings; not a unit test). Baseline = **123 tests** (after theme D). Self-relative only — keep the "not comparative" caveat.

---

## File Structure

- **Add** `src/bench/metrics.zig` — `Config` + `parse`, `median`, `stddev`, `percentile`, with unit tests.
- **Modify** `src/bench.zig` — import metrics; warmup + sampling loops; CLI; widened `report`.
- **Modify** `build.zig` — forward `b.args` to `bench_run`; add a bench test target to `test_step`.
- **Modify** `README.md`, `docs/getting-started.md` — bench flags + sampling note.

---

## Task 1: `src/bench/metrics.zig` — pure helpers + tests, wired into `zig build test`

**Files:** Add `src/bench/metrics.zig`; modify `build.zig`

- [ ] **Step 1: Write the failing unit tests** — create `src/bench/metrics.zig` with the public API and a test block. Write the tests first (they won't compile until the functions exist — that's the red state):

```zig
const std = @import("std");

pub const Config = struct {
    iters: usize = 2_000_000,
    conns: usize = 8,
    reqs: usize = 5_000,
    samples: usize = 5,
    warmup: usize = 1,
};

pub const ParseError = error{ UnknownFlag, MissingValue, BadValue };

// ... implementations added in Step 3 ...

const testing = std.testing;

test "parse: defaults when no args" {
    const c = try parse(&.{});
    try testing.expectEqual(@as(usize, 2_000_000), c.iters);
    try testing.expectEqual(@as(usize, 8), c.conns);
    try testing.expectEqual(@as(usize, 5_000), c.reqs);
    try testing.expectEqual(@as(usize, 5), c.samples);
    try testing.expectEqual(@as(usize, 1), c.warmup);
}

test "parse: flags override" {
    const c = try parse(&.{ "--conns", "64", "--reqs", "2000", "--samples", "3", "--warmup", "0", "--iters", "10" });
    try testing.expectEqual(@as(usize, 10), c.iters);
    try testing.expectEqual(@as(usize, 64), c.conns);
    try testing.expectEqual(@as(usize, 2000), c.reqs);
    try testing.expectEqual(@as(usize, 3), c.samples);
    try testing.expectEqual(@as(usize, 0), c.warmup);
}

test "parse: errors" {
    try testing.expectError(error.UnknownFlag, parse(&.{"--nope"}));
    try testing.expectError(error.MissingValue, parse(&.{"--conns"}));
    try testing.expectError(error.BadValue, parse(&.{ "--conns", "x" }));
    try testing.expectError(error.BadValue, parse(&.{ "--samples", "0" })); // samples must be >=1
}

test "median: odd and even, unsorted" {
    var a = [_]f64{ 3, 1, 2 };
    try testing.expectApproxEqAbs(@as(f64, 2), median(&a), 1e-9);
    var b = [_]f64{ 4, 1, 3, 2 };
    try testing.expectApproxEqAbs(@as(f64, 2.5), median(&b), 1e-9);
}

test "stddev: known values and n<2" {
    var a = [_]f64{ 2, 4, 4, 4, 5, 5, 7, 9 }; // sample stddev = 2.13809...
    try testing.expectApproxEqAbs(@as(f64, 2.13809), stddev(&a), 1e-4);
    var one = [_]f64{42};
    try testing.expectApproxEqAbs(@as(f64, 0), stddev(&one), 1e-9);
}

test "percentile: p50/p99/edges" {
    const s = [_]i96{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try testing.expectEqual(@as(i96, 60), percentile(&s, 50));
    try testing.expectEqual(@as(i96, 100), percentile(&s, 99));
    try testing.expectEqual(@as(i96, 100), percentile(&s, 100));
    try testing.expectEqual(@as(i96, 10), percentile(&s, 0));
}
```

(The exact `median`/`stddev` semantics: `median` may sort the slice in place or a copy — tests pass either way since they don't reuse the array after. `stddev` is the sample standard deviation with `n-1` denominator, `0` when `n < 2`.)

- [ ] **Step 2: Wire a bench test target into `zig build test`** — in `build.zig`, after the existing `bench_exe`/`bench_run`/`bench_step` block and the existing `test_step` definition, add a test target over the bench module so `metrics.zig` tests run:

```zig
    const bench_tests = b.addTest(.{ .root_module = bench_exe.root_module });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
```

(Place it after `test_step` is created. `metrics.zig` must be reachable from `bench.zig` — Step 3 of Task 2 adds the import; for now add a temporary `comptime { _ = @import("bench/metrics.zig"); }` reference in `bench.zig` if needed so its tests are discovered, or rely on the import added in Task 2. Simplest: do Task 2 Step "import metrics" alongside this so the reference exists.)

- [ ] **Step 3: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error|FAIL|expected" | head`
Expected: failures — `parse`/`median`/`stddev`/`percentile` are not yet implemented (or undefined reference).

- [ ] **Step 4: Implement the helpers** in `src/bench/metrics.zig`:
  - `parse(args)` — iterate `args`; for each known `--flag`, require a following value (`MissingValue` if absent), `std.fmt.parseInt(usize, val, 10)` (`BadValue` on failure); unknown flag → `UnknownFlag`; reject `samples == 0` as `BadValue`. Return the populated `Config`.
  - `median(samples: []f64) f64` — sort (e.g. `std.mem.sort`), return middle (average of two middles for even length); `0` for empty.
  - `stddev(samples: []f64) f64` — sample stddev (`n-1`); `0` for `n < 2`.
  - `percentile(sorted: []const i96, p: usize) i96` — moved from `bench.zig` (`idx = min(len*p/100, len-1)`).

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — the new metrics tests plus the existing 123. Report the actual count.

- [ ] **Step 6: Commit**

```bash
git add src/bench/metrics.zig build.zig
git commit -m "test(bench): metrics module (config parse + stats) wired into test step"
```

---

## Task 2: Refactor `bench.zig` — warmup, sampling, CLI

**Files:** Modify `src/bench.zig`, `build.zig`

- [ ] **Step 1: Forward args to the bench run** — in `build.zig`, after `const bench_run = b.addRunArtifact(bench_exe);`, add:

```zig
    if (b.args) |args| bench_run.addArgs(args);
```

- [ ] **Step 2: Parse args in `main`** — import metrics (`const metrics = @import("bench/metrics.zig");`), read process args (skip argv[0]) via `std.process.argsAlloc(gpa)` (free with `argsFree`), call `metrics.parse`; on `ParseError`, write a one-line usage to stderr and exit nonzero (`std.process.exit(2)`), else thread the `Config` into `microBenchmarks` and `endToEnd`.

- [ ] **Step 3: Warmup + sampling in `microBenchmarks(io, out, cfg)`** — for each of the three micros: run one warmup pass of `cfg.iters` (only when `cfg.warmup > 0`), then loop `cfg.samples` times, each timing `cfg.iters` ops and pushing `ns/op` into a `[cfg.samples]f64`-style buffer (use a small `gpa` slice sized `cfg.samples`), then `report(out, name, metrics.median(buf), metrics.stddev(buf))`. Keep the inner timed loop identical in shape to today's.

- [ ] **Step 4: Warmup + sampling in `endToEnd(io, gpa, out, cfg)`** — replace the constants `conns`/`reqs_per_conn` with `cfg.conns`/`cfg.reqs`. Run `cfg.warmup` discarded load(s), then `cfg.samples` measured loads; record each load's throughput (req/sec) into a `gpa` slice. Report median throughput + `stddev`, and compute latency percentiles (`metrics.percentile`) from the median-throughput sample's sorted latencies. Reuse the existing worker/skipResponse code.

- [ ] **Step 5: Widen `report`** — change to `report(out, name, median_ns, sd_ns)` printing e.g. `  {s:<16} {median:>8.1} ns/op  ± {sd:>6.1}  {ops:>12.0} ops/sec` (ops/sec from the median). Remove the now-unused single-shot signature; remove `percentile`/`pct` from bench.zig (moved to metrics).

- [ ] **Step 6: Verify the harness runs and honors flags**

Run: `zig build bench -- --samples 2 --conns 2 --reqs 500 --warmup 1 2>&1 | tail -20`
Expected: completes quickly; micro lines show `ns/op ± sd`; e2e shows `2 keep-alive conns`, median throughput, and latency percentiles.

Run: `zig build bench 2>&1 | tail -20`
Expected: default run (5 samples) completes in a few seconds and prints medians.

Run: `zig build bench -- --nope 2>&1; echo "exit=$?"`
Expected: a usage line and `exit=2` (nonzero).

- [ ] **Step 7: Confirm tests still green**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass (123 + metrics tests).

- [ ] **Step 8: Commit**

```bash
git add src/bench.zig build.zig
git commit -m "feat(bench): warmup, multi-sample median/stddev, and CLI flags"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — in the benchmarking area of `README.md` (around the `zig build bench` description and the caveats), note the new flags and that figures are now medians:

```markdown
`zig build bench` runs a discarded warmup then several samples, reporting each
micro as `median ns/op ± stddev` and the load as median throughput. Tune with
flags: `zig build bench -- --conns 64 --reqs 2000 --samples 5 --warmup 1`
(`--iters` sizes the micro loops). Numbers remain self-relative, not comparative.
```

- [ ] **Step 2: getting-started** — update the `zig build bench` line in `docs/getting-started.md` to mention the flags and sampling briefly.

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document bench flags and sampling"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines (123 + new metrics tests).
- [ ] Bench smoke: `zig build bench -- --samples 2 --conns 2 --reqs 500` completes and shows `median ± sd`; default `zig build bench` runs; `--nope` exits nonzero.

---

## Self-review notes

- **Spec coverage:** metrics module + tests + build wiring (Task 1); warmup/sampling/CLI in bench.zig + arg forwarding (Task 2); docs (Task 3). All E1 spec components covered.
- **Testability:** pure helpers (`parse`/`median`/`stddev`/`percentile`) are unit-tested under `zig build test` via the new bench test target; the timing/socket code is verified by running `zig build bench`.
- **Methodology:** warmup discarded; `samples` timed passes; median + sample stddev so run-to-run spread is visible. Inner timed loops unchanged in shape, so medians stay comparable to prior single-shot numbers.
- **Defaults preserve behavior:** flags default to today's values (plus `samples=5`, `warmup=1`); `zig build bench` with no args still works.
- **Scope discipline:** duration-based load, allocation metrics (E2), coverage (E3), and regression baselines (E4) are explicitly deferred; self-relative only.
- **Regression safety:** bench is excluded from the default build/test; the only test-suite change is additive (new metrics tests via the bench test target). The library and existing 123 tests are untouched.
