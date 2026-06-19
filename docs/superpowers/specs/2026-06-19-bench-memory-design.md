# Design — per-server memory (RSS) capture in the cross-framework benchmark

**Status:** approved 2026-06-19. Branch `feat/bench-memory` (off main `8fc90a3`).

## Problem

The cross-framework benchmark (`benchmarks/cross/run.sh`, comparing zax vs axum vs
Go net/http vs httpz) reports throughput + latency (req/s, p50/p99/p99.9/max) but
captures **no memory information**. A grep across `benchmarks/cross/` finds no RSS /
`/usr/bin/time` / `/proc` usage. We want to surface each server's resident memory so
the comparison shows zax's footprint against the tokio (axum) and goroutine (go)
runtimes — the expectation being that the Zig servers use much less.

## Goal

Add per-server **idle RSS** (at rest, after readiness) and **peak RSS** (under load)
to the harness, printed as a separate memory table after the existing latency table,
on both macOS (dev) and Linux (Docker / bare-metal, the real numbers).

Non-goals: per-scenario memory (RSS is a per-process property; one server process
serves all 3 scenarios per pass); heap profiling / allocation breakdowns (the
in-process `src/bench/` self-harness already has `memoryMetrics`); changing the
latency table or any existing knob.

### Decisions (confirmed with Chris)
- **ps-sampling** (not `/usr/bin/time` wrapping): poll `ps -o rss= -p $pid` — portable
  across mac + Linux, doesn't disturb the existing launch / readiness / kill / taskset
  flow. Under steady load RSS plateaus, so periodic sampling captures the true peak.
- **Report idle + peak**: idle RSS sampled once right after readiness (pre-load);
  peak RSS = max sampled during the 3 load drives.
- **Separate memory table** (one row per pass) — avoids repeating a single per-server
  number across the 3 scenario rows of the latency table.

## Key facts (harness)

- Each pass (`run.sh:295-324`) launches ONE server: `env $kv $srv_pin $cmd & pid=$!`,
  waits for readiness via a curl loop, runs 3 `drive` scenarios, then `kill $pid`.
- `$pid` is the server process: `env`/`taskset` exec into the same pid (execvp), and
  all four servers are single-process (threaded zax workers and evented SO_REUSEPORT
  workers are threads within one process; axum/go/httpz one process each). So
  `ps -o rss= -p $pid` yields whole-server RSS.
- `ps -o rss=` reports KB on both macOS (BSD ps) and Linux (procps) — portable.
- Results currently accumulate in `ROWS[]` and print a 7-column latency table
  (`run.sh:326-335`). A parallel `MEM[]` array + a second table is the clean fit.
- The Docker harness (`docker/run-linux-bench.sh`) just calls `run.sh`; `ps` is
  available in the linuxkit VM, so the memory table flows through with no Docker change.

## Components

### Modified: `benchmarks/cross/run.sh`

1. **RSS helper** (portable, near the other helpers):
   ```sh
   # rss_kb <pid> — resident set size in KB, or empty if the process is gone.
   rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
   ```

2. **Background peak sampler** — started right after readiness, stopped before kill:
   ```sh
   # sample_peak <pid> <outfile> — poll RSS ~2x/sec, keep the max in outfile.
   sample_peak() {
     local max=0 cur
     while cur=$(rss_kb "$1"); do
       [ -z "$cur" ] && break
       [ "$cur" -gt "$max" ] && max="$cur"
       printf '%s' "$max" > "$2"
       sleep 0.5
     done
   }
   ```

3. **Per-pass integration** (in the loop at `run.sh:309-322`, after the readiness
   curl loop, before `start_hog`):
   - Sample idle once: `idle_kb=$(rss_kb "$pid")`.
   - Seed the peak file with idle, launch the sampler:
     `printf '%s' "${idle_kb:-0}" > "$rssfile"; sample_peak "$pid" "$rssfile" & sampler=$!`.
   - After the 3 `drive` calls + `stop_hog`, stop the sampler and read the peak:
     `kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true;`
     `peak_kb=$(cat "$rssfile" 2>/dev/null)`.
   - Convert KB→MB (one decimal) and append:
     `MEM+=("$name|$idle_mb|$peak_mb")`.
   - Extend the existing `trap '...' EXIT` to also `kill "$sampler"` (guard unset).
     Create `rssfile` via `mktemp`; remove it at pass end.

4. **Memory table** — after the latency table (after `run.sh:335`):
   ```sh
   echo
   echo "==================== MEMORY (RSS) ===================="
   printf '%-8s %10s %10s\n' "FRAMEWORK" "IDLE(MB)" "PEAK(MB)"
   for row in "${MEM[@]}"; do
     IFS='|' read -r f i p <<<"$row"
     printf '%-8s %10s %10s\n' "$f" "$i" "$p"
   done
   echo "(RSS sampled via ps; idle = post-readiness at rest, peak = max under load.)"
   ```

KB→MB conversion uses `awk` (no bc dependency):
`idle_mb=$(awk -v k="${idle_kb:-0}" 'BEGIN{printf "%.1f", k/1024}')`.

### Modified: `benchmarks/cross/README.md`

Add a short methodology note: the harness samples each server's RSS via `ps`
(idle at rest + peak under load) and prints a memory table; one process per server so
the figure is whole-server resident memory; portable across mac + Linux/Docker.

### Modified: `benchmarks/cross/results.md`

Add the memory-table heading/format to the results document so a real run's numbers
have a home. Do NOT fabricate RSS figures — leave the table to be filled by an actual
run (Chris owns bench runs; oha + built servers required).

## Error handling

- Server already gone when sampled (`rss_kb` empty) → idle/peak fall back to `0`/seeded
  value; the table shows what was captured, never errors.
- Sampler is a background job; the `EXIT` trap kills it alongside the server so an
  aborted run leaves no stray sampler. `mktemp` file removed per pass.
- KB→MB via `awk` — no `bc`/locale dependency.

## Behavior change & test impact

- Additive: the latency table, all env knobs (PIN/AB/INFLIGHT/BACKEND/STEAL), and the
  oha parsing are unchanged. A new memory table prints after the latency table.
- Slightly longer teardown per pass (stop sampler) — negligible.

## Testing

This is a shell harness; full end-to-end needs `oha` + built servers (Chris's run).
What is verifiable here:
1. `bash -n benchmarks/cross/run.sh` — syntax check passes.
2. **Standalone RSS-helper test:** launch a dummy process (`sleep 5 & dummypid=$!`),
   assert `rss_kb "$dummypid"` returns a positive integer, and that `sample_peak`
   writes a positive max to its outfile within ~1s — proves the portable capture works
   on the dev machine (mac) without needing oha or the servers. Run this as a small
   inline check (a scratch script or `bash -c`), not a committed test.
3. Manual/real: `cd benchmarks/cross && ./run.sh` (and the Docker path) shows the
   MEMORY table with plausible MB figures; zax/httpz expected well below axum/go.

## Verification

- `bash -n benchmarks/cross/run.sh` clean.
- Standalone sampler check returns positive KB for a live pid, empty for a dead one.
- Real bench run (Chris): memory table populated; numbers copied into results.md.

## Docs

- `benchmarks/cross/README.md`: methodology note (above).
- `benchmarks/cross/results.md`: memory-table format/heading (numbers from a real run).
- No CHANGELOG entry — internal benchmark tooling, not a library-facing change.
