# Cross-bench memory (RSS) capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture each server's idle + peak RSS in the cross-framework benchmark and print a memory table, so zax's footprint is comparable against axum/go/httpz.

**Architecture:** Add a portable `ps -o rss=` sampler to `benchmarks/cross/run.sh`: sample idle RSS once after readiness, run a background peak-sampler during the load drives, then print a separate MEMORY table after the latency table. No changes to latency measurement or existing knobs.

**Tech Stack:** POSIX shell (bash), `ps`, `awk`. Runs on macOS (dev) and Linux (Docker/bare-metal).

## Global Constraints

- Pure shell; no new tool dependencies (`ps`, `awk` only — no `bc`, no `/usr/bin/time`).
- `ps -o rss= -p <pid>` reports KB on both macOS (BSD) and Linux (procps).
- Additive only: latency table, oha parsing, and all env knobs (PIN/AB/INFLIGHT/BACKEND/STEAL) unchanged.
- Memory is per-server (one process per pass) — NOT per-scenario. Report idle (post-readiness, at rest) + peak (max under load), in a separate table, one row per pass.
- Background sampler must be cleaned up by the existing `EXIT` trap (no stray jobs on abort); temp file via `mktemp`, removed per pass.
- Do NOT fabricate RSS numbers in results.md — real figures come from an actual run (Chris owns bench runs; needs oha + built servers).
- Full e2e run needs oha + servers (Chris). Verifiable here: `bash -n` + a standalone sampler check against a dummy `sleep` process.

---

### Task 1: RSS sampler + memory table in run.sh

**Files:**
- Modify: `benchmarks/cross/run.sh` (helpers near `drive`; per-pass loop ~:295-324; after the latency table ~:335)

**Interfaces:**
- Produces: shell functions `rss_kb <pid>` (echoes KB or empty) and `sample_peak <pid> <outfile>` (background loop writing running-max KB to outfile); a `MEM=()` array of `name|idle_mb|peak_mb`; a new MEMORY table printed after the latency table.

- [ ] **Step 1: Add the RSS helpers**

In `benchmarks/cross/run.sh`, near the other helper functions (above the `drive()` definition, ~line 226), add:

```sh
# rss_kb <pid> — resident set size in KB, or empty if the process is gone.
# `ps -o rss=` prints KB on both macOS (BSD ps) and Linux (procps).
rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }

# sample_peak <pid> <outfile> — poll RSS ~2x/sec, keep the running max in outfile.
# Exits when the process is gone.
sample_peak() {
  local max=0 cur
  while cur=$(rss_kb "$1"); do
    [ -z "$cur" ] && break
    [ "$cur" -gt "$max" ] && max="$cur"
    printf '%s' "$max" > "$2"
    sleep 0.5
  done
}

# kb_to_mb <kb> — KB→MB with one decimal (awk; no bc/locale dependency).
kb_to_mb() { awk -v k="${1:-0}" 'BEGIN{printf "%.1f", k/1024}'; }
```

- [ ] **Step 2: Declare the MEM array**

Find where `ROWS` is first used/declared (it is appended in `drive` via `ROWS+=(...)`; there is no explicit `ROWS=()` if it relies on bash auto-array — check). Immediately before the `for pass in "${PASSES[@]}"; do` loop (~line 295), add:

```sh
MEM=()
```

- [ ] **Step 3: Capture idle RSS + start the sampler after readiness**

In the per-pass loop, the readiness curl loop ends around line 313 (`done`), followed by `start_hog` (line 315). Between the readiness `done` and `start_hog`, insert:

```sh
  # --- memory: idle RSS (at rest, post-readiness) + background peak sampler ---
  rssfile=$(mktemp)
  idle_kb=$(rss_kb "$pid")
  printf '%s' "${idle_kb:-0}" > "$rssfile"
  sample_peak "$pid" "$rssfile" & sampler=$!
```

- [ ] **Step 4: Extend the cleanup trap to kill the sampler**

The existing trap is at line 308: `trap 'kill "$pid" 2>/dev/null || true; stop_hog' EXIT`. Change it to also kill the sampler (guard `${sampler:-}` since it is set after the trap on the first lines):

```sh
  trap 'kill "$pid" 2>/dev/null || true; kill "${sampler:-}" 2>/dev/null || true; stop_hog' EXIT
```

(The trap is re-armed each pass at line 308 and cleared at line 323; `sampler` from the prior pass is already dead, so killing a stale value is harmless.)

- [ ] **Step 5: Stop the sampler + record peak after the drives**

After the three `drive` calls and `stop_hog` (line 319), before `kill "$pid"` (line 321), insert:

```sh
  # --- memory: stop sampler, read peak, record idle+peak in MB ---
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  peak_kb=$(cat "$rssfile" 2>/dev/null)
  rm -f "$rssfile"
  MEM+=("$name|$(kb_to_mb "${idle_kb:-0}")|$(kb_to_mb "${peak_kb:-0}")")
```

- [ ] **Step 6: Print the memory table**

After the latency-table `for row in "${ROWS[@]}"; ... done` block and its trailing `echo` (after line 335/336), add:

```sh
echo
echo "==================== MEMORY (RSS) ===================="
printf '%-8s %10s %10s\n' "FRAMEWORK" "IDLE(MB)" "PEAK(MB)"
for row in "${MEM[@]}"; do
  IFS='|' read -r f i p <<<"$row"
  printf '%-8s %10s %10s\n' "$f" "$i" "$p"
done
echo "(RSS via ps: idle = post-readiness at rest, peak = max under load; one process per server.)"
```

- [ ] **Step 7: Syntax check**

Run: `bash -n benchmarks/cross/run.sh`
Expected: no output, exit 0 (clean parse).

- [ ] **Step 8: Standalone sampler check (no oha/servers needed)**

Run this inline check (validates the portable capture on the dev machine):

```sh
bash -c '
  rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d " "; }
  sample_peak() { local max=0 cur; while cur=$(rss_kb "$1"); do [ -z "$cur" ] && break; [ "$cur" -gt "$max" ] && max="$cur"; printf "%s" "$max" > "$2"; sleep 0.2; done; }
  sleep 5 & p=$!
  f=$(mktemp)
  sample_peak "$p" "$f" & s=$!
  sleep 1
  v=$(rss_kb "$p"); peak=$(cat "$f")
  kill "$p" "$s" 2>/dev/null
  echo "live_rss_kb=$v peak_kb=$peak"
  case "$v" in (""|*[!0-9]*) echo FAIL-live; exit 1;; esac
  case "$peak" in (""|*[!0-9]*) echo FAIL-peak; exit 1;; esac
  echo OK
'
```
Expected: prints `live_rss_kb=<n> peak_kb=<n>` then `OK` (both positive integers). Confirms `rss_kb` returns a live pid's KB and `sample_peak` records a positive max.

- [ ] **Step 9: Commit**

```bash
git add benchmarks/cross/run.sh
git commit -m "bench(cross): capture idle + peak RSS per server, print memory table"
```

---

### Task 2: Docs — README methodology + results.md format

**Files:**
- Modify: `benchmarks/cross/README.md`
- Modify: `benchmarks/cross/results.md`

- [ ] **Step 1: README methodology note**

In `benchmarks/cross/README.md`, in the methodology/metrics section, add a short paragraph:

> **Memory.** The harness samples each server's resident set size via `ps` — idle RSS
> (at rest, right after readiness) and peak RSS (max during the load run) — and prints a
> separate MEMORY table. Each server is a single process, so the figure is whole-server
> resident memory. Portable across macOS and Linux/Docker.

- [ ] **Step 2: results.md memory-table heading**

In `benchmarks/cross/results.md`, add a memory-table section/heading matching the doc's
existing style so a real run's numbers have a home, e.g.:

```markdown
### Memory (RSS)

| Framework | idle (MB) | peak (MB) |
|-----------|----------:|----------:|
| zax       |           |           |
| axum      |           |           |
| go        |           |           |
| httpz     |           |           |

(Filled from a real run: `cd benchmarks/cross && ./run.sh`. RSS via `ps`; idle = at rest, peak = under load.)
```

Leave the cells blank (or a `—`) — do NOT invent figures.

- [ ] **Step 3: Commit**

```bash
git add benchmarks/cross/README.md benchmarks/cross/results.md
git commit -m "docs(bench): document cross-framework memory (RSS) capture"
```

---

## Final verification

- `bash -n benchmarks/cross/run.sh` → clean.
- Standalone sampler check (Task 1 Step 8) → prints `OK` with positive KB values.
- Spec coverage: T1 = helpers + idle/peak capture + trap cleanup + memory table + syntax/sampler checks; T2 = README + results.md format. All spec sections covered.
- Real run (Chris): `cd benchmarks/cross && ./run.sh` (and Docker) prints the MEMORY table with plausible MB; zax/httpz expected well below axum/go. Numbers copied into results.md.
