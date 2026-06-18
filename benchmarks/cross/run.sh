#!/usr/bin/env bash
# Cross-framework load benchmark: zax vs axum vs Go net/http.
# Builds all three release servers, then drives identical load against each with
# an EXTERNAL generator (oha by default) across three scenarios. Honest,
# same-methodology indicators — NOT a definitive "X beats Y" claim (see README).
#
# Usage:
#   ./run.sh                         # 30s, 64 conns, oha
#   DURATION=10s CONNS=128 ./run.sh
#   LOAD=wrk ./run.sh                # oha | wrk | bombardier
#   PIN=1 ./run.sh                   # pin server vs load generator to disjoint
#                                    # cores (Linux/taskset) so they don't fight
#                                    # for CPU — isolates the server's real tail
#                                    # latency from same-host oversubscription
#
# ── Latency-trace experiments (spike/latency-trace branch) ──────────────────
#
# Build the zax bench server with phase timers enabled (E1/E2/E4/E5):
#   ( cd zax && zig build -Dtrace-latency=true -Doptimize=ReleaseFast )
#
# The bench server self-stops via ZAX_RUN_SECS=N (calls requestShutdown after N
# seconds, which dumps the phase summary to stderr). No signal handler needed.
#
# Trace the ~35ms stall (localize):
#   ZAX_RUN_SECS=35 ./zax/zig-out/bin/zax-bench 2>trace.log &   # self-stops at 35s, dumps summary
#   oha -z 30s -c 64 --no-tui http://127.0.0.1:8081/            # (or /users/42, POST /echo)
#   wait; grep -A8 'trace' trace.log                             # read the phase summary
#
# Experiment knobs (set before starting the server):
#   ZAX_RUN_SECS=N           self-stop after N seconds and dump trace summary
#   ZAX_KEEPALIVE=0          E2 — disable HTTP keep-alive (each request uses a
#                                 fresh connection); does the 35ms tail vanish?
#   ZAX_THREADS=N            E4 — override async_limit to N worker threads
#                                 instead of the default (cpu_count - 1); does
#                                 the tail move with fewer/more threads?
#
# Examples:
#   ZAX_RUN_SECS=35 ZAX_KEEPALIVE=0 ./zax/zig-out/bin/zax-bench 2>trace.log &  # E2: no keep-alive
#   ZAX_RUN_SECS=35 ZAX_THREADS=1   ./zax/zig-out/bin/zax-bench 2>trace.log &  # E4: single thread
#   ZAX_RUN_SECS=35 ZAX_THREADS=8   ./zax/zig-out/bin/zax-bench 2>trace.log &  # E4: 8 threads
#
# The existing ZAX_NODELAY and ZAX_MAX_INFLIGHT knobs remain unchanged.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

DURATION="${DURATION:-30s}"
CONNS="${CONNS:-64}"
LOAD="${LOAD:-oha}"
WARMUP="${WARMUP:-3s}"
PIN="${PIN:-0}"
RAW="${RAW:-0}"       # 1 = also print the full oha output per scenario (default: table only)
AB="${AB:-0}"         # 1 = run zax twice (ZAX_NODELAY on vs off) to A/B the Nagle tail.
                      # The on-vs-off delta on p99.9/max cancels same-box oversubscription
                      # (it's identical across both passes), so AB=1 is valid even unpinned.
INFLIGHT="${INFLIGHT:-0}"  # N>0 = run zax twice (ZAX_MAX_INFLIGHT=0 then =N) to A/B the
                      # worker-pool cap. Adds a "zax-cap" row alongside the default "zax".
                      # NOTE: AB=1 and INFLIGHT are mutually exclusive for the zax passes —
                      # AB=1 takes precedence (INFLIGHT is silently ignored when AB=1 is set).
BACKEND="${BACKEND:-threaded}"  # "both" = run zax twice (threaded then evented epoll reactor).
                      # "evented" = evented only. Default "threaded" = classic std.Io.Threaded.
                      # Evented is Linux-only (ZAX_BACKEND=evented calls App.serveEvented).
# ── Work-stealing spike (spike/work-stealing branch) ────────────────────────
# STEAL induces vCPU-steal-like worker starvation on the evented reactor so the
# spike can measure worst-case MAX with/without it (Linux/taskset only).
#   STEAL=none     (default) no induction.
#   STEAL=cpuset   pin the server to STEAL_CORES cores and run ZAX_WORKERS=2*cores
#                  workers on them — oversubscription forces the OS to deschedule
#                  runnable workers (the steal analogue). Client gets disjoint cores.
#   STEAL=hog      additionally pin a busy-loop to ONE server core during each load
#                  window, freeing it after — a sharper, single-core starvation.
# Use with BACKEND=evented (or both). STEAL implies its own server/client pinning,
# independent of PIN.
STEAL="${STEAL:-none}"
STEAL_CORES="${STEAL_CORES:-2}"
ROWS=()               # accumulated "framework|scenario|reqs|p50|p99|p999|max" for the table

# When PIN=1, run the server on the first half of the cores and the load
# generator on the second half (disjoint) via taskset, so client CPU never
# steals from the server. taskset is Linux-only; macOS has no shell core
# pinning — run the load generator on a SEPARATE machine for a fair test.
#
# SMT-aware split: group logical CPUs by physical core (pkg:core key from
# sysfs), split physical cores in half, give server all logical CPUs of the
# first half and client all logical CPUs of the second half. No physical core
# is shared, eliminating SMT cross-contention. Falls back to naive split if
# sysfs topology is unavailable.

# _build_pin_lists <nlogical>
# Reads /sys/.../topology/{physical_package_id,core_id} for each logical CPU,
# groups them by physical-core key (pkg:core), splits physical cores in half,
# and prints two lines: "SRV_CPUS=<comma-list>" and "CLT_CPUS=<comma-list>".
# Returns non-zero if sysfs is unavailable so the caller can fall back.
# Uses awk for grouping — compatible with bash 3.x (macOS) and bash 4/5.
_build_pin_lists() {
  local ncpus="$1"
  local cpu pkg core

  # Collect "cpu pkg core" triples; bail immediately if any sysfs file is missing
  local triples=""
  for (( cpu=0; cpu<ncpus; cpu++ )); do
    local topo="/sys/devices/system/cpu/cpu${cpu}/topology"
    local pkg_f="${topo}/physical_package_id"
    local core_f="${topo}/core_id"
    [ -r "$pkg_f" ] && [ -r "$core_f" ] || return 1
    pkg=$(cat "$pkg_f")
    core=$(cat "$core_f")
    triples="${triples}${cpu} ${pkg} ${core}"$'\n'
  done

  # Sort triples by pkg then core (numeric), pipe into awk.
  # awk sees rows in physical-core order, groups consecutive rows with the same
  # key, counts distinct keys, and splits in half — no asort needed (POSIX awk).
  printf '%s' "$triples" | sort -k2,2n -k3,3n | awk '
  {
    cpu=$1; pkg=$2; core=$3
    key = pkg ":" core
    # accumulate cpus per key in encounter order
    if (key != prev_key) {
      if (prev_key != "") { keys[++nkeys]=prev_key; grp[prev_key]=acc }
      prev_key=key; acc=cpu
    } else {
      acc = acc "," cpu
    }
  }
  END {
    if (prev_key != "") { keys[++nkeys]=prev_key; grp[prev_key]=acc }
    half = int((nkeys+1)/2); if (half<1) half=1
    srv=""; clt=""
    for (i=1; i<=nkeys; i++) {
      g = grp[keys[i]]
      if (i <= half) srv = (srv=="" ? g : srv "," g)
      else           clt = (clt=="" ? g : clt "," g)
    }
    print "SRV_CPUS=" srv
    print "CLT_CPUS=" clt
  }
  '
}

SRV_PIN=""
CLT_PIN=""
if [ "$PIN" = 1 ]; then
  if command -v taskset >/dev/null 2>&1; then
    NCPUS="$(nproc)"
    # Try SMT-aware grouping via sysfs
    if pin_out=$(_build_pin_lists "$NCPUS" 2>/dev/null); then
      eval "$pin_out"
      SRV_PIN="taskset -c ${SRV_CPUS}"
      CLT_PIN="taskset -c ${CLT_CPUS}"
      echo "== core pinning (physical-core-aware): server [${SRV_PIN}]  client [${CLT_PIN}] =="
    else
      # Fallback: naive logical-cpu split (original behavior)
      HALF=$(( NCPUS / 2 )); [ "$HALF" -lt 1 ] && HALF=1
      SRV_PIN="taskset -c 0-$((HALF - 1))"
      CLT_PIN="taskset -c ${HALF}-$((NCPUS - 1))"
      echo "== core pinning (naive fallback — sysfs topology unavailable): server [${SRV_PIN}]  client [${CLT_PIN}] =="
    fi
  else
    echo "PIN=1 but 'taskset' not found (Linux only)."
    echo "  macOS has no shell core pinning — run the load generator on a"
    echo "  SEPARATE machine for a fair test. Proceeding UNPINNED."
  fi
fi

# Work-stealing steal-induction pinning (independent of PIN). Pins the server to
# the first STEAL_CORES cores and forces 2*STEAL_CORES evented workers onto them
# (oversubscription → descheduling); client runs on the remaining cores.
STEAL_ENV=""
STEAL_SRV_PIN=""
STEAL_HOG_CORE=""
if [ "$STEAL" != none ]; then
  if command -v taskset >/dev/null 2>&1; then
    NCPUS="$(nproc)"
    if [ "$STEAL_CORES" -ge "$NCPUS" ]; then
      echo "STEAL: STEAL_CORES=$STEAL_CORES >= nproc=$NCPUS — need cores left for the client. Aborting." >&2
      exit 1
    fi
    STEAL_WORKERS=$(( STEAL_CORES * 2 ))
    STEAL_SRV_PIN="taskset -c 0-$((STEAL_CORES - 1))"
    CLT_PIN="taskset -c ${STEAL_CORES}-$((NCPUS - 1))"   # client on the disjoint remainder
    STEAL_ENV="ZAX_WORKERS=${STEAL_WORKERS}"
    STEAL_HOG_CORE=0
    echo "== STEAL=$STEAL: server [${STEAL_SRV_PIN}] workers=${STEAL_WORKERS} on ${STEAL_CORES} cores; client [${CLT_PIN}] =="
  else
    echo "STEAL set but 'taskset' not found (Linux only). Proceeding WITHOUT steal induction." >&2
    STEAL=none
  fi
fi

# CPU-hog helpers (STEAL=hog): a busy-loop pinned to one server core during a load window.
HOG_PID=""
start_hog() {
  [ "$STEAL" = hog ] || return 0
  taskset -c "$STEAL_HOG_CORE" sh -c 'while :; do :; done' &
  HOG_PID=$!
}
stop_hog() {
  [ -n "$HOG_PID" ] || return 0
  kill "$HOG_PID" 2>/dev/null || true
  wait "$HOG_PID" 2>/dev/null || true
  HOG_PID=""
}

if ! command -v "$LOAD" >/dev/null 2>&1; then
  echo "load generator '$LOAD' not found."
  echo "  install oha:  brew install oha   (or: cargo install oha)"
  echo "  or set LOAD=wrk / LOAD=bombardier"
  exit 1
fi

echo "== building (release) =="
( cd zax   && zig build -Doptimize=ReleaseFast )
( cd axum  && cargo build --release )
( cd go    && go build -o go-bench . )
[ -d httpz ] && ( cd httpz && zig build -Doptimize=ReleaseFast )

# name  port  start-command
FRAMEWORKS=(
  "zax   8081 ./zax/zig-out/bin/zax-bench"
  "axum  8082 ./axum/target/release/axum-bench"
  "go    8083 ./go/go-bench"
  "httpz 8084 ./httpz/zig-out/bin/httpz-bench"
)

# drive <name> <scenario> <url> [method] [data]
# Warmup (discarded) then a measured run; appends "name|scenario|reqs|p50|p99" to
# ROWS. For oha the metrics are parsed into the summary table; wrk/bombardier
# print raw and record n/a (parsing supports oha only).
drive() {
  local name="$1" scenario="$2" url="$3"; shift 3
  local method="${1:-GET}" data="${2:-}"
  local out reqs p50 p99 p999 max
  case "$LOAD" in
    oha)
      if [ "$method" = POST ]; then
        $CLT_PIN oha -z "$WARMUP" -c "$CONNS" --no-tui -m POST -d "$data" -T application/json "$url" >/dev/null 2>&1
        out=$($CLT_PIN oha -z "$DURATION" -c "$CONNS" --no-tui -m POST -d "$data" -T application/json "$url")
      else
        $CLT_PIN oha -z "$WARMUP" -c "$CONNS" --no-tui "$url" >/dev/null 2>&1
        out=$($CLT_PIN oha -z "$DURATION" -c "$CONNS" --no-tui "$url")
      fi
      reqs=$(awk '/Requests\/sec:/{printf "%.0f", $2; exit}' <<<"$out")
      p50=$(awk '/^[[:space:]]*50\.00% in/{print $3; exit}' <<<"$out")
      p99=$(awk '/^[[:space:]]*99\.00% in/{print $3; exit}' <<<"$out")
      # The Nagle/delayed-ACK tail lives at p99.9 + max, not p99 — surface both.
      p999=$(awk '/^[[:space:]]*99\.90% in/{print $3; exit}' <<<"$out")
      max=$(awk '/^[[:space:]]*Slowest:/{print $2; exit}' <<<"$out")
      printf '  %-7s %-7s %12s req/s   p50 %sms   p99 %sms   p99.9 %sms   max %sms\n' \
        "$name" "$scenario" "${reqs:-?}" "${p50:-?}" "${p99:-?}" "${p999:-?}" "${max:-?}"
      [ "$RAW" = 1 ] && printf '%s\n' "$out"
      ROWS+=("$name|$scenario|${reqs:-?}|${p50:-?}|${p99:-?}|${p999:-?}|${max:-?}")
      ;;
    wrk)
      echo "  ($LOAD: raw output below; summary table supports oha only)"
      $CLT_PIN wrk -d "$DURATION" -c "$CONNS" "$url"
      ROWS+=("$name|$scenario|n/a|n/a|n/a|n/a|n/a")
      ;;
    bombardier)
      echo "  ($LOAD: raw output below; summary table supports oha only)"
      $CLT_PIN bombardier -d "$DURATION" -c "$CONNS" "$url"
      ROWS+=("$name|$scenario|n/a|n/a|n/a|n/a|n/a")
      ;;
  esac
}

# Expand frameworks into runnable passes: "label|port|env|cmd". With AB=1, zax
# runs twice — Nagle off (ZAX_NODELAY=0) then on (=1) — so the same-box tail can
# be A/B'd; the other frameworks run once. INFLIGHT=N (when AB=0): zax runs twice
# (ZAX_MAX_INFLIGHT=0 then =N) to A/B the worker-pool cap.
# BACKEND=both: zax runs twice — threaded then evented (ZAX_BACKEND=evented).
# AB=1 and INFLIGHT are mutually exclusive for zax — AB=1 takes precedence.
# BACKEND takes effect when AB=0 and INFLIGHT=0.
# axum/go/httpz always run once.
[ "$AB" = 1 ] && [ "${INFLIGHT:-0}" != 0 ] && echo "WARNING: AB=1 takes precedence for zax; INFLIGHT ignored this run." >&2 || true
PASSES=()
for entry in "${FRAMEWORKS[@]}"; do
  read -r name port cmd <<<"$entry"
  if [ "$name" = zax ] && [ "$AB" = 1 ]; then
    PASSES+=("zax-off|$port|ZAX_NODELAY=0|$cmd")
    PASSES+=("zax-on|$port|ZAX_NODELAY=1|$cmd")
  elif [ "$name" = zax ] && [ "${INFLIGHT:-0}" != 0 ]; then
    PASSES+=("zax|$port|ZAX_MAX_INFLIGHT=0|$cmd")
    PASSES+=("zax-cap|$port|ZAX_MAX_INFLIGHT=$INFLIGHT|$cmd")
  elif [ "$name" = zax ] && [ "$BACKEND" = both ]; then
    PASSES+=("zax|$port|ZAX_BACKEND=threaded|$cmd")
    PASSES+=("zax-ev|$port|ZAX_BACKEND=evented|$cmd")
  elif [ "$name" = zax ] && [ "$BACKEND" = evented ]; then
    PASSES+=("zax-ev|$port|ZAX_BACKEND=evented|$cmd")
  else
    PASSES+=("$name|$port||$cmd")
  fi
done

for pass in "${PASSES[@]}"; do
  IFS='|' read -r name port kv cmd <<<"$pass"
  echo
  echo "######################## $name (:$port) ########################"
  # STEAL applies to the zax server passes only (the reactor under test); its
  # pin/worker-count override the generic PIN pin for those passes.
  srv_pin="$SRV_PIN"; steal_kv=""
  case "$name" in
    zax|zax-ev|zax-on|zax-off|zax-cap)
      [ "$STEAL" != none ] && { srv_pin="$STEAL_SRV_PIN"; steal_kv="$STEAL_ENV"; } ;;
  esac
  env ${kv:+"$kv"} ${steal_kv:+"$steal_kv"} $srv_pin $cmd >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; stop_hog' EXIT
  # wait for readiness
  for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.1
  done

  start_hog
  drive "$name" static "http://127.0.0.1:$port/"
  drive "$name" param  "http://127.0.0.1:$port/users/42"
  drive "$name" json   "http://127.0.0.1:$port/echo" POST '{"msg":"hi"}'
  stop_hog

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - EXIT
done

# Summary table
echo
printf '==================== RESULTS (%s, %s conns, %s%s%s) ====================\n' \
  "$DURATION" "$CONNS" "$LOAD" "$([ "$PIN" = 1 ] && echo ', pinned')" "$([ "$AB" = 1 ] && echo ', A/B')"
printf '%-8s %-8s %12s %9s %9s %9s %9s\n' \
  "FRAMEWORK" "SCENARIO" "REQ/S" "P50(ms)" "P99(ms)" "P99.9(ms)" "MAX(ms)"
for row in "${ROWS[@]}"; do
  IFS='|' read -r f s r a b c d <<<"$row"
  printf '%-8s %-8s %12s %9s %9s %9s %9s\n' "$f" "$s" "$r" "$a" "$b" "$c" "$d"
done
echo
echo "(p50/p99/p99.9/max parsed from oha; copy into results.md. RAW=1 for full output.)"
[ "$AB" = 1 ] && echo "(A/B: compare zax-on vs zax-off on P99.9/MAX — the delta isolates Nagle.)"
[ "${INFLIGHT:-0}" != 0 ] && echo "(INFLIGHT=$INFLIGHT: compare zax vs zax-cap on P99.9/MAX — cap flattens the thread-per-conn tail.)"
[ "$BACKEND" = both ] && echo "(BACKEND=both: compare zax (threaded) vs zax-ev (evented epoll reactor) — throughput + tail.)"
[ "$BACKEND" = evented ] && echo "(BACKEND=evented: evented epoll reactor only.)"
