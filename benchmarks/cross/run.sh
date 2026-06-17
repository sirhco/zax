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

# Run one scenario with the configured load tool (warmup discarded, then measured).
drive() {
  local url="$1"; shift
  local method="${1:-GET}"; local data="${2:-}"
  case "$LOAD" in
    oha)
      if [ "$method" = POST ]; then
        $CLT_PIN oha -z "$WARMUP" -c "$CONNS" --no-tui -m POST -d "$data" -T application/json "$url" >/dev/null
        $CLT_PIN oha -z "$DURATION" -c "$CONNS" --no-tui -m POST -d "$data" -T application/json "$url"
      else
        $CLT_PIN oha -z "$WARMUP" -c "$CONNS" --no-tui "$url" >/dev/null
        $CLT_PIN oha -z "$DURATION" -c "$CONNS" --no-tui "$url"
      fi ;;
    wrk)
      $CLT_PIN wrk -d "$DURATION" -c "$CONNS" "$url" ;;
    bombardier)
      $CLT_PIN bombardier -d "$DURATION" -c "$CONNS" "$url" ;;
  esac
}

for entry in "${FRAMEWORKS[@]}"; do
  read -r name port cmd <<<"$entry"
  echo
  echo "######################## $name (:$port) ########################"
  $SRV_PIN $cmd >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true' EXIT
  # wait for readiness
  for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.1
  done

  echo "--- $name: static  GET / ---"
  drive "http://127.0.0.1:$port/"
  echo "--- $name: param   GET /users/42 ---"
  drive "http://127.0.0.1:$port/users/42"
  echo "--- $name: json    POST /echo ---"
  drive "http://127.0.0.1:$port/echo" POST '{"msg":"hi"}'

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - EXIT
done

echo
echo "Done. Record req/s + p50/p99 per (framework x scenario) into results.md."
