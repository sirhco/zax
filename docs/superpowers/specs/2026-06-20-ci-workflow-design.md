# Design — GitHub Actions CI

**Status:** approved 2026-06-20. Branch `feat/ci-workflow` (off main `ea2cefd`).

## Problem

zax has no CI (`.github/` absent). Tests + the bench compile only run when someone runs them
locally. This is the biggest remaining "battle-tested" gap: regressions (including
backend-specific ones — epoll vs kqueue) can land unnoticed, and the bench target can break
without anyone seeing it until a manual run.

## Goal

A GitHub Actions workflow that builds + tests zax on Linux and macOS (both reactor backends)
and compile-checks the benchmark exe, on every push to `main` and every pull request.

Non-goals: a perf regression gate (`bench --check` baseline is machine-specific → false-fails
on shared runners); `zig fmt --check` (the tree is not zig-fmt-clean — a gate would fail;
reformatting is a separate decision); running the cross-framework bench / `soak.sh` (needs
`oha` + Rust/Go toolchains + is noisy — stays manual/Docker).

### Decisions (confirmed with Chris)
- **Linux + macOS matrix** for `zig build test` → epoll (Linux, runs the 3 currently
  mac-skipped tests) + kqueue (macOS) coverage.
- **Test + bench build-check**, NO perf gate: a separate job compile-checks the ReleaseFast
  bench exe via a new build-only step.

## Key facts

- Zig **0.16.0** (`build.zig.zon` minimum + local `zig version`).
- `build.zig` steps: `test` (`:170`, runs mod + exe + bench-module tests), `bench` (`:144`,
  builds AND runs the ReleaseFast bench exe), `run`. The `test` step already compiles the
  bench module in Debug (via `bench_tests` `:175-176`); there is no build-only step for the
  ReleaseFast bench exe.
- `bench_exe` (`build.zig:131`) is a ReleaseFast executable; `bench_run` (`:142`) is its run
  artifact wired to the `bench` step.
- No `.github/` dir yet.

## Components

### Added: `build.zig` — a `bench-build` step

Add a build-only step (build the bench exe, do not run it):
```zig
    const bench_build = b.step("bench-build", "Build the benchmark exe (compile-check, no run)");
    bench_build.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
```
Place it next to the existing `bench` step (after `:145`). Existing `bench`/`test`/`run` steps
unchanged. `zig build bench-build` then compile-checks `src/bench.zig` + helpers in ReleaseFast
without running benchmarks.

### Added: `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    name: test (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0
      - run: zig build test --summary all

  bench-build:
    name: bench build-check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0
      - run: zig build bench-build
```

- `fail-fast: false` so a Linux failure doesn't cancel the macOS job (and vice versa) — both
  backends' results are always visible.
- `mlugg/setup-zig@v1` fetches + caches Zig 0.16.0 (the de-facto Zig CI action).
- The `test` job's Linux leg runs the epoll reactor tests (currently skipped on mac); the
  macOS leg runs kqueue. Together = both backends.

### Modified: `README.md`

Add a CI status badge near the top and a short "Continuous Integration" note (tests on
Linux+macOS + bench build-check, every push/PR). Badge:
`[![CI](https://github.com/sirhco/zax/actions/workflows/ci.yml/badge.svg)](https://github.com/sirhco/zax/actions/workflows/ci.yml)`

## Error handling / edge cases

- If Zig 0.16.0 is not fetchable by `setup-zig` under that exact string, the workflow fails
  loudly on the setup step (clear signal); fix by adjusting the version string. (Local
  `zig version` = 0.16.0, so the tagged release exists.)
- `fail-fast: false` keeps one OS's failure from masking the other.

## Behavior change & test impact

- Repo infrastructure only — no `src/` or library behavior change. `build.zig` gains one
  additive step; existing steps unchanged. No test-count change.

## Testing

This is CI config; the authoritative run is on GitHub after push. Verifiable locally:
1. `zig build bench-build` — builds the bench exe (no run), exit 0; confirms the new step.
2. `zig build test --summary all` — still green (baseline 265/268 mac; the new step doesn't
   affect it).
3. YAML well-formedness — `.github/workflows/ci.yml` parses (e.g. `python3 -c "import yaml,sys;
   yaml.safe_load(open('.github/workflows/ci.yml'))"`, or `actionlint` if available).

## Verification

- `zig build bench-build` exit 0; `zig build test` green; CI YAML valid.
- On Chris's next push, the `test` (ubuntu + macos) and `bench-build` jobs run + pass; the
  README badge goes green.

## Docs

- `README.md`: CI badge + a one-line CI note.
- No CHANGELOG entry — repo infrastructure, not a library change.
