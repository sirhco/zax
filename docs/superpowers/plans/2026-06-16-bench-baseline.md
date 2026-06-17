# Benchmark Regression Baseline (E4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zig build bench -- --json` emits a machine-readable snapshot; `zig build bench -- --check` compares the current run's stable metrics (micro ns/op + bytes/req) to a committed baseline within `--tolerance` (default 0.15) and exits nonzero on regression. CI/pre-merge perf guard.

**Architecture:** Add `json`/`check`/`tolerance` to `metrics.Config` (restructure `parse` for boolean/float/usize flags) and a pure `metrics.regressed`/`pctDelta` — all unit-tested. In `bench.zig`, always collect each metric into a `Collector`; print human lines only when not in machine mode; `--json` emits a flat JSON object; `--check` parses an `@embedFile` baseline (`src/bench/baseline.json`), compares gated metrics, and `exit(1)` on regression. Only micro ns/op and bytes/req are gated; throughput/latency are emitted but never fail (loopback-noisy).

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-bench-baseline-design.md`. Branch: `feat/bench-baseline`. This is the LAST sub-project of theme E (and the A–F roadmap).

**Conventions:** Tests via `zig build test --summary all`. TDD for the metrics additions. Bench modes verified by running `zig build bench`. Baseline ≥ 136 tests (new metrics tests add to the bench test target).

---

## File Structure

- **Modify** `src/bench/metrics.zig` — `Config` flags + restructured `parse` + `regressed`/`pctDelta` + tests.
- **Modify** `src/bench.zig` — `Collector`; collect-always / human-print-conditionally; `--json` emit; `--check` vs `@embedFile` baseline + exit code; header gated on human mode.
- **Add** `src/bench/baseline.json` — committed (bootstrapped `{}`, then real numbers).
- **Modify** `README.md`, `docs/getting-started.md` — regression-check usage + CI/regeneration note.

---

## Task 1: `metrics.zig` — flags + compare helpers (TDD)

**Files:** Modify `src/bench/metrics.zig`

- [ ] **Step 1: Write the failing tests** — add to the metrics test block:

```zig
test "parse: boolean and float flags" {
    const c = try parse(&.{ "--json", "--conns", "4" });
    try testing.expect(c.json);
    try testing.expect(!c.check);
    try testing.expectEqual(@as(usize, 4), c.conns);

    const d = try parse(&.{ "--check", "--tolerance", "0.2" });
    try testing.expect(d.check);
    try testing.expectApproxEqAbs(@as(f64, 0.2), d.tolerance, 1e-9);

    const e = try parse(&.{}); // defaults
    try testing.expect(!e.json and !e.check);
    try testing.expectApproxEqAbs(@as(f64, 0.15), e.tolerance, 1e-9);
}

test "parse: bad/negative tolerance" {
    try testing.expectError(error.BadValue, parse(&.{ "--tolerance", "x" }));
    try testing.expectError(error.BadValue, parse(&.{ "--tolerance", "-0.1" }));
    try testing.expectError(error.MissingValue, parse(&.{"--tolerance"}));
}

test "regressed: tolerance band" {
    try testing.expect(!regressed(100, 110, 0.15)); // +10% within 15%
    try testing.expect(regressed(100, 120, 0.15));   // +20% beyond 15%
    try testing.expect(!regressed(100, 80, 0.15));   // improvement
    try testing.expect(!regressed(100, 115, 0.15));  // exactly +15% is not a regression
}

test "pctDelta" {
    try testing.expectApproxEqAbs(@as(f64, 20), pctDelta(100, 120), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), pctDelta(100, 90), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), pctDelta(0, 5), 1e-9); // baseline 0 -> 0
}
```

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|expected" | head`. Expected: `json`/`check`/`tolerance` fields and `regressed`/`pctDelta` don't exist.

- [ ] **Step 3: Extend `Config`** — add `json: bool = false`, `check: bool = false`, `tolerance: f64 = 0.15`.

- [ ] **Step 4: Restructure `parse`** — per arg: if `--json` → `cfg.json = true` (no value); if `--check` → `cfg.check = true` (no value); if `--tolerance` → require next value, `std.fmt.parseFloat(f64, val) catch return error.BadValue`, reject NaN/negative as `BadValue`; the existing usize flags (`--iters`/`--conns`/`--reqs`/`--samples`/`--warmup`) → require next value, `parseInt` (existing logic); else `UnknownFlag`. Keep the existing `iters/conns/reqs/samples >= 1` validation.

- [ ] **Step 5: Add compare helpers**

```zig
/// True when `current` is worse than `baseline` by more than `tol` (fractional).
/// Lower is better for the gated metrics (ns/op, bytes/req).
pub fn regressed(baseline: f64, current: f64, tol: f64) bool {
    return current > baseline * (1.0 + tol);
}
/// Percent change of `current` vs `baseline` (positive = worse). 0 if baseline == 0.
pub fn pctDelta(baseline: f64, current: f64) f64 {
    if (baseline == 0) return 0;
    return (current - baseline) / baseline * 100.0;
}
```

- [ ] **Step 6: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (136 + new metrics tests). Report the count.

- [ ] **Step 7: Commit**

```bash
git add src/bench/metrics.zig
git commit -m "test(bench): --json/--check/--tolerance flags + regressed/pctDelta"
```

---

## Task 2: `bench.zig` — collection, `--json`, `--check`, baseline

**Files:** Modify `src/bench.zig`; add `src/bench/baseline.json`

- [ ] **Step 1: Bootstrap the baseline file** — create `src/bench/baseline.json` containing exactly `{}` so `@embedFile` compiles.

- [ ] **Step 2: Add the collector + embed** — in `src/bench.zig`:

```zig
const Metric = struct { key: []const u8, value: f64, gated: bool };
const baseline_json = @embedFile("bench/baseline.json");
```
Thread a `coll: *std.ArrayList(Metric)` and a `human: bool` (= `!(cfg.json or cfg.check)`) into `microBenchmarks`, `endToEnd`/`benchScenario`, and `memoryMetrics`. Build keys with the program-lifetime `init.arena` allocator (pass it in): micros use their report name (gated=true); memory `mem.<scenario>` (gated=true); throughput `thr.<scenario>` (gated=false).

- [ ] **Step 3: Collect-always, print-conditionally** — at each result print site: append the `Metric` to `coll`, and emit the existing human line only `if (human)`. Update `report` to take `coll`/`human`/`arena` (or append at its call sites). The `=== Zax benchmark ===` header and section headers print only when `human`.

- [ ] **Step 4: `--json` output** — after running, if `cfg.json`, print a flat JSON object of ALL collected metrics to stdout and nothing else:

```zig
// { "key": value, "key2": value2, ... }  (2-space-free, machine-readable)
```
Use `std.json.Stringify`/manual emit; ensure valid JSON (escape keys if needed — keys here are simple ASCII). This must be the ONLY thing on stdout in `--json` mode so `zig build bench -- --json > file` yields valid JSON.

- [ ] **Step 5: `--check` mode** — after running, if `cfg.check`:
  - Parse `baseline_json` with `std.json.parseFromSlice(std.json.Value, gpa, baseline_json, .{})` (free it); treat the root object as key→number.
  - For each collected metric with `gated == true`: look up `key` in the baseline. If absent → print `  (no baseline)  <key>`. If present → `const reg = metrics.regressed(base, cur, cfg.tolerance); const d = metrics.pctDelta(base, cur);` and print `  OK  <key>: cur vs base (+d%)` or `  FAIL <key>: ...`. Track `any_fail`.
  - Print a one-line summary (`N checked, M regressed, tolerance X%`). `std.process.exit(1)` if `any_fail` else return (exit 0).

- [ ] **Step 6: Build with empty baseline** — `zig build bench -- --check 2>&1 | tail -20`. Expected: every gated metric `(no baseline)`, exit 0 (no false failures). Also `zig build bench 2>&1 | tail -5` (human, unchanged) and `zig build bench -- --json 2>&1 | head -3` (valid JSON, no human noise).

- [ ] **Step 7: Generate the real baseline + verify check passes**

```bash
zig build bench -- --json > src/bench/baseline.json
zig build bench -- --check 2>&1 | tail -20   # all OK (current ≈ baseline), exit 0
```
Confirm `src/bench/baseline.json` is valid JSON with the gated keys, and `--check` exits 0. (Re-running `--check` right after generating should pass within tolerance.)

- [ ] **Step 8: Confirm tests green** — `zig build test --summary all 2>&1 | grep "tests passed"`.

- [ ] **Step 9: Commit**

```bash
git add src/bench.zig src/bench/baseline.json
git commit -m "feat(bench): --json snapshot and --check regression gate vs committed baseline"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — document the perf-guard workflow: `zig build bench -- --json > src/bench/baseline.json` to (re)generate the committed baseline; `zig build bench -- --check [--tolerance 0.2]` to compare and exit nonzero on regression (gates micro ns/op + bytes/req only; throughput/latency are informational). Note the baseline is environment-specific (use a stable CI runner or local before/after). Keep the self-relative caveat.

- [ ] **Step 2: getting-started** — one-line note on `--json`/`--check`.

- [ ] **Step 3: Verify** — `zig build test --summary all 2>&1 | grep "tests passed"`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document benchmark regression check (--json/--check)"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines (136 + new metrics tests).
- [ ] `zig build bench -- --json | head -c 200` — valid JSON snapshot.
- [ ] `zig build bench -- --check; echo exit=$?` — OK lines, `exit=0` (within tolerance of the committed baseline).
- [ ] `zig build bench` — human output unchanged.

---

## Self-review notes

- **Spec coverage:** flags + compare helpers + tests (Task 1); collection + `--json` + `--check` + embedded baseline (Task 2); docs (Task 3). All E4 spec components covered.
- **Testable core restored:** `parse` flag handling and `regressed`/`pctDelta` are unit-tested under `zig build test`; only the bench wiring (collection/JSON/exit) is run-verified.
- **Gating discipline:** only stable metrics (micro ns/op, bytes/req) gate `--check`; noisy throughput/latency are emitted but never fail — no flaky CI.
- **Machine-output purity:** `--json` suppresses all human output so the snapshot redirects cleanly; `--check` reads an `@embedFile` baseline (no cwd/fs dependence).
- **Honest limitation:** the committed baseline is environment-specific; `--check` targets a stable runner or local before/after, with a generous default tolerance — documented.
- **Regression safety:** bench excluded from the default build/test; library + the existing 136 tests untouched; only the bench test target grows (new metrics tests).
- **Theme E + roadmap A–F complete** after E4.
