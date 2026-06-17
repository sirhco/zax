#!/usr/bin/env bash
# Runs inside the Linux container. Two experiments:
#   1) E5  — traced zax under load: does the macOS ~35ms tail reproduce on Linux?
#   2) PIN=1 cross-framework — first core-pinned zax vs axum vs go (taskset).
set -uo pipefail
cd /zax/benchmarks/cross

DUR="${DURATION:-30s}"
CONNS="${CONNS:-64}"

echo "######################################################################"
echo "# Linux: $(uname -srm)  |  nproc=$(nproc)  |  oha $(oha --version 2>&1 | awk '{print $2}')"
echo "######################################################################"

echo
echo "============================ E5: traced zax =========================="
( cd zax && zig build -Dtrace-latency=true -Doptimize=ReleaseFast ) || { echo "trace build FAILED"; }
ZAX_RUN_SECS=40 ./zax/zig-out/bin/zax-bench 2>/tmp/e5.log &
srv=$!
for _ in $(seq 1 50); do curl -fs http://127.0.0.1:8081/ >/dev/null 2>&1 && break; sleep 0.1; done
echo "-- oha $DUR x $CONNS conns vs traced zax (GET /) --"
oha -z "$DUR" -c "$CONNS" --no-tui http://127.0.0.1:8081/ \
  | grep -E 'Requests/sec|Slowest|50\.00%|99\.00%|99\.90%|Success'
wait "$srv" 2>/dev/null || true
echo "-- [latency-trace] phase summary (Linux) --"
grep latency-trace /tmp/e5.log || echo "(no trace output — check build)"

echo
echo "==================== PIN=1 cross-framework (Linux) ==================="
echo "(taskset core-pinning works here; server vs client on disjoint cores)"
PIN=1 DURATION="$DUR" CONNS="$CONNS" ./run.sh

echo
echo "######################## DONE ########################################"
echo "Compare the E5 [latency-trace] head/write maxes + oha 99.90% above against"
echo "the macOS run (p99.9 ~35ms). If Linux p99.9 is sub-ms, the stall is a"
echo "macOS/Darwin-loopback artifact, not zax."
