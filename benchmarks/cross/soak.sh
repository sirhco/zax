#!/usr/bin/env bash
# Soak/leak check for the evented large-response + lazy-slot fixes.
# Launches zax-ev, runs SOAK_WAVES load waves against /large, samples the
# server RSS after each wave, and reports whether RSS plateaus (no leak).
set -euo pipefail
cd "$(dirname "$0")"

PAYLOAD_KB="${PAYLOAD_KB:-64}"
SOAK_WAVES="${SOAK_WAVES:-5}"
SOAK_DUR="${SOAK_DUR:-10s}"
CONNS="${CONNS:-64}"
PORT=8081

rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }

command -v oha >/dev/null 2>&1 || { echo "oha not found (install: brew install oha)"; exit 1; }

echo "== building zax bench (release) =="
( cd zax && zig build -Doptimize=ReleaseFast )

echo "== launching zax-ev (PAYLOAD_KB=$PAYLOAD_KB) =="
env ZAX_BACKEND=evented PAYLOAD_KB="$PAYLOAD_KB" ./zax/zig-out/bin/zax-bench >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 50); do
  if curl -fs "http://127.0.0.1:$PORT/large" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "ERROR: zax-ev did not become ready on port $PORT" >&2
  exit 1
fi

printf '%-6s %10s\n' "WAVE" "RSS(MB)"
first_kb=0; last_kb=0
for w in $(seq 1 "$SOAK_WAVES"); do
  oha -z "$SOAK_DUR" -c "$CONNS" --no-tui "http://127.0.0.1:$PORT/large" >/dev/null 2>&1 || true
  kb=$(rss_kb "$pid"); kb="${kb:-0}"
  mb=$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1024}')
  printf '%-6s %10s\n' "$w" "$mb"
  [ "$w" -eq 1 ] && first_kb="$kb"
  last_kb="$kb"
done

echo
if [ "$first_kb" -gt 0 ] && [ "$last_kb" -gt $(( first_kb + first_kb / 10 )) ]; then
  echo "POSSIBLE LEAK — RSS climbed >10% from wave 1 to wave $SOAK_WAVES (${first_kb}KB -> ${last_kb}KB)."
else
  echo "OK — RSS plateaued (${first_kb}KB -> ${last_kb}KB across $SOAK_WAVES waves)."
fi
