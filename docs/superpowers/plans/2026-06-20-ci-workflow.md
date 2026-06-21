# GitHub Actions CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CI that builds + tests zax on Linux and macOS (both reactor backends) and compile-checks the bench exe, on every push to main and every PR.

**Architecture:** A new `bench-build` step in `build.zig` (build the ReleaseFast bench exe, no run), plus `.github/workflows/ci.yml` with a Linux+macOS `test` matrix (`zig build test`) and a `bench-build` job, using `mlugg/setup-zig` pinned to 0.16.0. README gets a CI badge.

**Tech Stack:** Zig 0.16.0, GitHub Actions, `mlugg/setup-zig@v1`.

## Global Constraints

- Zig **0.16.0** (pin in the workflow; matches `build.zig.zon` minimum + local toolchain).
- Repo infrastructure only — no `src/`/library behavior change; `build.zig` change is one additive step; existing `test`/`bench`/`run` steps unchanged.
- NO perf gate (`bench --check` baseline is machine-specific → false-fails on shared runners); NO `zig fmt --check` (tree isn't fmt-clean); NO cross-framework bench/soak in CI (needs oha + Rust/Go + noisy).
- `fail-fast: false` on the OS matrix so one OS's failure doesn't mask the other.
- No CHANGELOG entry (repo infra).
- Test baseline unchanged: **265/268 mac** (3 Linux-epoll skips). `zig build test --summary all`.

---

### Task 1: `bench-build` step in build.zig

**Files:**
- Modify: `build.zig` (after the `bench` step, ~:145)

**Interfaces:**
- Produces: a `zig build bench-build` step that builds `bench_exe` (ReleaseFast) without running it.

- [ ] **Step 1: Add the step**

In `build.zig`, immediately after the existing `bench` step block (the `bench_step.dependOn(&bench_run.step);` line ~:145), add:

```zig
    // Build-only check of the ReleaseFast bench exe (no run) — used by CI to
    // catch bench-code breakage without the machine-specific perf gate.
    const bench_build = b.step("bench-build", "Build the benchmark exe (compile-check, no run)");
    bench_build.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
```

(`bench_exe` is already defined just above at ~:131. Do not modify the `bench`/`test`/`run` steps.)

- [ ] **Step 2: Verify the step builds (no run)**

Run: `zig build bench-build`
Expected: exit 0; it compiles the bench exe (ReleaseFast) and installs it under `zig-out/bin/`; it does NOT run benchmarks (no benchmark output).

- [ ] **Step 3: Verify tests still pass**

Run: `zig build test --summary all`
Expected: green, 265/268 (3 Linux-epoll skips) — unchanged.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: add bench-build step (compile-check bench exe, no run)"
```

---

### Task 2: CI workflow + README badge

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `zig build test`, `zig build bench-build` (Task 1).

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/ci.yml`:

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

- [ ] **Step 2: Validate the YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"`
Expected: prints `yaml ok` (well-formed). If `actionlint` is installed, also run `actionlint .github/workflows/ci.yml` (optional).

- [ ] **Step 3: README badge + note**

In `README.md`, add the CI badge near the top (just under the title `# Zax` / its tagline):

```markdown
[![CI](https://github.com/sirhco/zax/actions/workflows/ci.yml/badge.svg)](https://github.com/sirhco/zax/actions/workflows/ci.yml)
```

And in the "Status & limitations" (or a fitting) section, add a one-line note:
`CI runs `zig build test` on Linux (epoll) and macOS (kqueue) plus a bench compile-check on every push and PR.`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "ci: GitHub Actions — test on Linux+macOS + bench build-check"
```

---

## Final verification

- `zig build bench-build` exit 0 (builds bench exe, no run); `zig build test --summary all` green.
- `.github/workflows/ci.yml` is valid YAML.
- Spec coverage: T1 = `bench-build` step; T2 = ci.yml (Linux+macOS test matrix + bench-build job, setup-zig 0.16.0, fail-fast:false) + README badge/note. All spec sections covered.
- Excluded as designed: no perf `--check` gate, no `zig fmt` gate, no cross-bench in CI.
- Real validation: on the next push, the `test` (ubuntu + macos) and `bench-build` jobs run + pass; the README badge goes green. (Chris owns the push.)
