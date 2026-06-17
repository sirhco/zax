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
ROWS=()               # accumulated "framework|scenario|reqs|p50|p99|p999|max" for the table

# When PIN=1, run the server on the first half of the cores and the load
# generator on the second half (disjoint) via taskset, so client CPU never
# steals from the server. taskset is Linux-only; macOS has no shell core
# pinning — run the load generator on a SEPARATE machine for a fair test.
SRV_PIN=""
CLT_PIN=""
if [ "$PIN" = 1 ]; then
  if command -v taskset >/dev/null 2>&1; then
    NCORES="$(nproc)"
    HALF=$(( NCORES / 2 )); [ "$HALF" -lt 1 ] && HALF=1
    SRV_PIN="taskset -c 0-$((HALF - 1))"
    CLT_PIN="taskset -c ${HALF}-$((NCORES - 1))"
    echo "== core pinning: server [$SRV_PIN]  client [$CLT_PIN] =="
  else
    echo "PIN=1 but 'taskset' not found (Linux only)."
    echo "  macOS has no shell core pinning — run the load generator on a"
    echo "  SEPARATE machine for a fair test. Proceeding UNPINNED."
  fi
fi

if ! command -v "$LOAD" >/dev/null 2>&1; then
  echo "load generator '$LOAD' not found."
  echo "  install oha:  brew install oha   (or: cargo install oha)"
  echo "  or set LOAD=wrk / LOAD=bombardier"
  exit 1
fi

echo "== building (release) =="
( cd zax  && zig build -Doptimize=ReleaseFast )
( cd axum && cargo build --release )
( cd go   && go build -o go-bench . )

# name  port  start-command
FRAMEWORKS=(
  "zax  8081 ./zax/zig-out/bin/zax-bench"
  "axum 8082 ./axum/target/release/axum-bench"
  "go   8083 ./go/go-bench"
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
# AB=1 and INFLIGHT are mutually exclusive for zax — AB=1 takes precedence.
# axum/go always run once.
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
  else
    PASSES+=("$name|$port||$cmd")
  fi
done

for pass in "${PASSES[@]}"; do
  IFS='|' read -r name port kv cmd <<<"$pass"
  echo
  echo "######################## $name (:$port) ########################"
  env ${kv:+"$kv"} $SRV_PIN $cmd >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT
  # wait for readiness
  for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.1
  done

  drive "$name" static "http://127.0.0.1:$port/"
  drive "$name" param  "http://127.0.0.1:$port/users/42"
  drive "$name" json   "http://127.0.0.1:$port/echo" POST '{"msg":"hi"}'

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
