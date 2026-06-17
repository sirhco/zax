# Zax — benchmark regression baseline (E4) design

Date: 2026-06-16. Status: accepted. Scope: sub-project E4 of theme E
(benchmarking, self-relative only) — the FINAL sub-project of theme E and of the
post-v0.1.0 roadmap (themes A–F). E1 (rigor), E2 (memory), E3 (coverage) are
done.

## Context

The harness (post-E3) prints rich human-readable results: 9 micros, 3 e2e
scenarios (throughput + latency), and per-scenario memory + peak RSS. But there's
no way to (a) emit those numbers machine-readably or (b) detect a *regression*
against a known-good baseline. E4 adds a JSON snapshot and a `--check` mode that
compares the current run to a committed baseline and exits nonzero on regression
— a CI- and pre-merge-friendly perf guard.

## Decision (from brainstorming)

1. **Gate only stable metrics.** Micro `ns/op` medians (low variance) and
   `bytes/req` (deterministic) are gated by `--check`. Throughput and latency are
   loopback-noisy (E1/E3 showed throughput stddev can be ~50% of the value), so
   they are emitted in `--json` for information but **never** gate a pass/fail —
   avoiding flaky CI.
2. **`--json`** emits a flat JSON object `{ "<key>": <number>, ... }` of all
   collected metrics to stdout, and suppresses all human output (so it is a clean
   redirectable snapshot). Keys: micros by their report name (e.g. `parseHead`,
   `radix wildcard`); memory as `mem.<scenario>`; throughput as `thr.<scenario>`.
3. **`--check`** runs the benchmark, then for each GATED metric looks up its key
   in the committed baseline and flags a regression when `current - baseline >
   baseline × tolerance` (equivalent to `current > baseline × (1 + tolerance)`
   but avoids float-rounding at the exact boundary; lower is better for both
   ns/op and bytes/req). It prints
   `OK`/`FAIL  <key>: current vs baseline (+x%)` per gated metric, a summary, and
   `std.process.exit(1)` if any regressed (else exit 0). Missing baseline keys
   are reported as `(no baseline)` and never fail.
4. **`--tolerance <frac>`** sets the allowed fractional worsening (default
   `0.15`). Parsed as f64.
5. **Baseline is a committed `@embedFile`.** `src/bench/baseline.json` is compiled
   in (`@embedFile`), so `--check` needs no filesystem/cwd access (robust in CI).
   Regenerate with `zig build bench -- --json > src/bench/baseline.json` and
   recommit. The baseline is environment-specific — `--check` is meant for a
   stable CI runner or local before/after on the same machine; the generous
   default tolerance absorbs cross-run noise. Documented.
6. **Pure, testable core.** The new flags (`--json`/`--check`/`--tolerance`) live
   in `metrics.parse` (unit-tested), and the comparison is a pure
   `metrics.regressed(baseline, current, tol) bool` + `metrics.pctDelta(baseline,
   current) f64` (unit-tested). Bench wiring (collection, JSON emit, baseline
   parse, exit code) is verified by running `zig build bench`.

## Architecture

```
zig build bench [-- --json | --check [--tolerance F]]
        |
   metrics.parse(argv) -> Config{ ..., json, check, tolerance }
        |
   run sections, appending each result to a Collector (always);
   human prints happen only when NOT (json or check)
        |
   --json  -> print flat JSON of all collected metrics (no human output)
   --check -> parse @embedFile baseline; per gated metric:
                metrics.regressed(baseline[key], current, tol) ? FAIL : OK
              print report; exit(1) if any FAIL
   default -> human output (today's behavior)
```

## Components

### 1. `src/bench/metrics.zig` (extend; pure + tested)
- `Config` gains `json: bool = false`, `check: bool = false`, `tolerance: f64 = 0.15`.
- `parse` restructured to handle: boolean flags (`--json`/`--check`, no value);
  the float flag (`--tolerance`, parse f64, bad → `BadValue`); and the existing
  usize flags. Unknown → `UnknownFlag`; missing value for value-flags →
  `MissingValue`.
- `pub fn regressed(baseline: f64, current: f64, tol: f64) bool` → `current -
  baseline > baseline * tol` (algebraically `current > baseline * (1 + tol)`, but
  this form avoids f64 rounding flagging an exact +tol as a regression).
- `pub fn pctDelta(baseline: f64, current: f64) f64` → `(current - baseline) /
  baseline * 100` (0 if baseline == 0).
- Tests for all of the above.

### 2. `src/bench.zig` (collection + JSON + check)
- `const Metric = struct { key: []const u8, value: f64, gated: bool };` and a
  collector (`std.ArrayList(Metric)`) threaded into the sections (keys built with
  the program-lifetime `init.arena`).
- `report`/memory/throughput print sites: always append to the collector; print
  the human line only when `human` (i.e. `!(cfg.json or cfg.check)`).
- `const baseline_json = @embedFile("bench/baseline.json");`.
- After running: `--json` prints the flat JSON snapshot; `--check` parses the
  baseline (`std.json`), compares gated metrics, prints the report, exits 1 on
  regression; otherwise the human output already printed.
- `main` prints the `=== Zax benchmark ===` header only in human mode.

### 3. `src/bench/baseline.json` (committed)
Bootstrapped as `{}`, then regenerated from a real `--json` run and committed.

## Testing

- **Unit (`zig build test`, bench test target):** `metrics.parse` — `--json`/
  `--check` set their bools without consuming a value; `--tolerance 0.2` parses;
  `--tolerance x` → `BadValue`; combinations (`--json --conns 4`,
  `--check --tolerance 0.1`) parse; existing flags unaffected. `regressed` —
  within tol → false, beyond tol → true, improvement → false, boundary.
  `pctDelta` — known values, baseline 0 → 0.
- **Manual (`zig build bench`):**
  - `--json` prints ONLY a valid JSON object (redirectable).
  - `--check` against the committed baseline prints OK/FAIL lines and exits 0 when
    within tolerance; a deliberately-tiny `--tolerance 0.0001` on a noisy-enough
    metric can show FAIL + nonzero exit (sanity of the gate).
  - default run unchanged (human output).
- **Regression:** `zig build test` stays green (136 + new metrics tests).

## Files

- Modify: `src/bench/metrics.zig` (flags + `regressed`/`pctDelta` + tests).
- Modify: `src/bench.zig` (collection, `--json`, `--check`, `@embedFile`).
- Add: `src/bench/baseline.json` (committed, real numbers).
- Modify: `README.md`, `docs/getting-started.md` (regression-check usage + CI note).

## Risks & edge cases

- **Environment-specific baseline:** numbers vary by machine; `--check` is for a
  stable runner or local before/after. Documented; default tolerance generous.
- **`--json` purity:** machine mode must suppress ALL human output (header +
  section lines) so the stdout is valid JSON for redirection.
- **`@embedFile` bootstrap:** the file must exist to compile — start with `{}`,
  then generate. `--check` against `{}` reports every metric `(no baseline)` and
  exits 0 (no false failures).
- **Missing/extra keys:** baseline missing a current key → `(no baseline)`, not a
  failure; baseline keys absent from the current run → ignored.
- **Float parsing:** `--tolerance` uses `std.fmt.parseFloat`; reject NaN/negative
  as `BadValue`.

## Out of scope

Cross-framework comparison (whole theme E); gating throughput/latency (too noisy);
auto-updating the committed baseline (regeneration is a manual `--json` +
recommit). Theme E and the A–F roadmap are complete after E4.
