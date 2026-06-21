# Large-payload load test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a configurable large-buffered-response scenario to the cross-framework bench (all 4 servers) plus a soak script, to load-test the evented large-response + lazy-slot fixes.

**Architecture:** Each bench server gains a `GET /large` route returning a buffered ~`PAYLOAD_KB` body built once at startup. `run.sh` adds a `large` scenario + exports `PAYLOAD_KB`; the existing MEMORY table captures peak RSS under large bodies. A standalone `soak.sh` runs N load waves against zax-ev and prints an RSS-per-wave series + plateau verdict (leak check).

**Tech Stack:** Zig 0.16 (zax/httpz), Rust/axum, Go; bash + oha + `ps`.

## Global Constraints

- Additive bench tooling only — no framework (`src/`) changes. Existing scenarios, memory table, and server routes unchanged.
- `PAYLOAD_KB` env (default 64) sizes the body on ALL 4 servers; `run.sh` exports it so every server launch agrees.
- `/large` returns a BUFFERED response (content-length set, NOT streamed) — that is the evented large-response path under test. >8KB (64KB default) ≫ the 8KB write_buf.
- One process per server → RSS = whole server (existing memory-table assumption holds).
- Soak is OBSERVATIONAL (RSS thresholds are env-specific); leak signal = RSS plateaus across identical waves (lazy-slot retain → won't return to baseline, but must not climb).
- Full `oha` run is Chris's; verify here via per-server builds + `bash -n` + a standalone RSS-sampler check (no oha).
- No CHANGELOG entry (internal bench tooling).

---

### Task 1: `/large` route on all 4 bench servers

**Files:**
- Modify: `benchmarks/cross/zax/src/main.zig`
- Modify: `benchmarks/cross/go/main.go`
- Modify: `benchmarks/cross/axum/src/main.rs`
- Modify: `benchmarks/cross/httpz/src/main.zig`

**Interfaces:**
- Produces: a `GET /large` route on each server returning a buffered body of ~`PAYLOAD_KB`*1024 bytes (env `PAYLOAD_KB`, default 64), shape `{"data":"x…x"}`.

- [ ] **Step 1: zax — build body + route**

In `benchmarks/cross/zax/src/main.zig`: near the other env reads, read `PAYLOAD_KB`:
```zig
    const payload_kb: usize = if (init.environ_map.get("PAYLOAD_KB")) |v|
        (std.fmt.parseInt(usize, v, 10) catch 64) else 64;
```
Before the route registrations, build a module-level body once (use the app's gpa/long-lived allocator that outlives `serve`). Add at module scope:
```zig
var large_body: []const u8 = "";
```
In `main`, after computing `payload_kb` and before `app.get` calls, build it (wrap `{"data":"` + filler + `"}`):
```zig
    {
        const n = payload_kb * 1024;
        const buf = try init.gpa.alloc(u8, n);
        const prefix = "{\"data\":\"";
        const suffix = "\"}";
        @memcpy(buf[0..prefix.len], prefix);
        const fill_end = n - suffix.len;
        @memset(buf[prefix.len..fill_end], 'x');
        @memcpy(buf[fill_end..n], suffix);
        large_body = buf;
    }
```
Add the route + handler:
```zig
    try app.get("/large", large);
```
```zig
fn large() zax.Response {
    return zax.Response.json2(large_body); // use whatever raw-JSON ctor exists; else Response.text(large_body)
}
```
NOTE: use the framework's actual buffered-JSON-or-text constructor — read the zax import alias + `Response` API in this file's existing handlers (`hello`/`echo`) and mirror it (e.g. `Response.text(large_body)` is fine; the goal is a buffered body with content-length). Confirm the handler signature matches the other handlers in this file (e.g. they may take no args or a ctx — match `hello`).

- [ ] **Step 2: zax — build**

Run: `cd benchmarks/cross/zax && zig build -Doptimize=ReleaseFast`
Expected: builds clean; `zig-out/bin/zax-bench` produced.

- [ ] **Step 3: go — body + route**

In `benchmarks/cross/go/main.go`, in `main` before `ListenAndServe`, build the body from env and register the route:
```go
	largeKB := 64
	if v := os.Getenv("PAYLOAD_KB"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			largeKB = n
		}
	}
	large := make([]byte, largeKB*1024)
	copy(large, []byte(`{"data":"`))
	for i := len(`{"data":"`); i < len(large)-2; i++ {
		large[i] = 'x'
	}
	copy(large[len(large)-2:], []byte(`"}`))
	mux.HandleFunc("GET /large", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(large)
	})
```
Add imports `os` and `strconv` if not present.

- [ ] **Step 4: go — build**

Run: `cd benchmarks/cross/go && go build -o go-bench .`
Expected: builds clean.

- [ ] **Step 5: axum — body + route**

In `benchmarks/cross/axum/src/main.rs`, in `main` build the body from env and add the route. Read `std::env::var("PAYLOAD_KB")` (default 64), build a `String`, and serve it via a closure capturing an `Arc<String>` (or `axum::extract::State`). Minimal closure approach:
```rust
    let kb: usize = std::env::var("PAYLOAD_KB").ok().and_then(|v| v.parse().ok()).unwrap_or(64);
    let n = kb * 1024;
    let mut body = String::with_capacity(n);
    body.push_str("{\"data\":\"");
    body.extend(std::iter::repeat('x').take(n - 11));
    body.push_str("\"}");
    let large_body = std::sync::Arc::new(body);
    let lb = large_body.clone();
    let app = Router::new()
        .route("/", get(hello))
        .route("/users/{id}", get(user))
        .route("/echo", post(echo))
        .route("/large", get(move || { let lb = lb.clone(); async move { ([("content-type","application/json")], (*lb).clone()) } }));
```
(Adapt to the file's exact axum version/imports — read the existing `.route(...)` block and `use` lines; the goal is a buffered JSON body of ~`n` bytes. `n - 11` accounts for the 9-byte prefix + 2-byte suffix.)

- [ ] **Step 6: axum — build**

Run: `cd benchmarks/cross/axum && cargo build --release`
Expected: builds clean.

- [ ] **Step 7: httpz — body + route**

In `benchmarks/cross/httpz/src/main.zig`, read `PAYLOAD_KB` in `main` (via `init.environ_map` mirroring the other zig server, or `std.process` env), build a module-level `var large_body: []const u8 = "";` filled once in `main`, and register:
```zig
    router.get("/large", large, .{});
```
```zig
fn large(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = large_body;
    res.content_type = .JSON; // or set the header per httpz API used by `echo`
}
```
Mirror how `echo` sets JSON in this file. Build the body the same way as zax (prefix/fill/suffix).

- [ ] **Step 8: httpz — build**

Run: `cd benchmarks/cross/httpz && zig build -Doptimize=ReleaseFast`
Expected: builds clean.

- [ ] **Step 9: Commit**

```bash
git add benchmarks/cross/zax/src/main.zig benchmarks/cross/go/main.go benchmarks/cross/axum/src/main.rs benchmarks/cross/httpz/src/main.zig
git commit -m "bench(cross): add /large buffered-response route (PAYLOAD_KB) to all servers"
```

(If a toolchain is unavailable locally, syntax-review that server, note it in the report, and let the Docker/CI build catch it.)

---

### Task 2: run.sh scenario, soak.sh, docs

**Files:**
- Modify: `benchmarks/cross/run.sh`
- Create: `benchmarks/cross/soak.sh`
- Modify: `benchmarks/cross/README.md`

- [ ] **Step 1: run.sh — export PAYLOAD_KB + add the scenario**

In `benchmarks/cross/run.sh`, near the env-default section (where DURATION/CONNS etc. are set), add:
```sh
export PAYLOAD_KB="${PAYLOAD_KB:-64}"
```
After the json drive line (`drive "$name" json …`, ~:345), add:
```sh
  drive "$name" large "http://127.0.0.1:$port/large"
```

- [ ] **Step 2: run.sh — syntax check**

Run: `bash -n benchmarks/cross/run.sh`
Expected: clean (exit 0).

- [ ] **Step 3: Create soak.sh**

Create `benchmarks/cross/soak.sh` (executable). It launches zax-ev once, runs `SOAK_WAVES` load waves against `/large`, samples RSS after each, prints the series + a plateau verdict:

```sh
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

for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/large" >/dev/null 2>&1 && break; sleep 0.1; done

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
```

- [ ] **Step 4: soak.sh — make executable + syntax check**

Run: `chmod +x benchmarks/cross/soak.sh && bash -n benchmarks/cross/soak.sh`
Expected: clean (exit 0).

- [ ] **Step 5: Standalone RSS-sampler check (no oha)**

Run:
```sh
bash -c '
  rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d " "; }
  sleep 5 & p=$!
  v=$(rss_kb "$p"); kill "$p" 2>/dev/null
  echo "rss_kb=$v"
  case "$v" in (""|*[!0-9]*) echo FAIL; exit 1;; esac
  echo OK
'
```
Expected: prints `rss_kb=<n>` then `OK` (positive integer) — confirms the soak's measurement primitive works on this machine.

- [ ] **Step 6: README docs**

In `benchmarks/cross/README.md`, document:
- the `large` scenario + `PAYLOAD_KB` (default 64) — a buffered large response across all 4 servers; the MEMORY table shows peak RSS under large bodies.
- `soak.sh` — `SOAK_WAVES` (default 5), `SOAK_DUR` (default 10s): repeated load waves against zax-ev, RSS-per-wave series + plateau/leak verdict.
- expected outcome: zax-ev serves `/large` (200, not 500) with competitive throughput; RSS plateaus across soak waves (no leak).

- [ ] **Step 7: Commit**

```bash
git add benchmarks/cross/run.sh benchmarks/cross/soak.sh benchmarks/cross/README.md
git commit -m "bench(cross): large scenario in run.sh + soak.sh leak check + docs"
```

---

## Final verification

- All 4 servers build with `/large` (zig/cargo/go); `bash -n` clean on run.sh + soak.sh; sampler check OK.
- Spec coverage: T1 = `/large` on all 4 servers (PAYLOAD_KB); T2 = run.sh scenario + PAYLOAD_KB export + soak.sh + README. All spec sections covered.
- Real run (Chris): `BACKEND=both PAYLOAD_KB=64 ./run.sh` → `large` row per framework (zax-ev 200 + competitive) + memory-table peak; `SOAK_WAVES=5 ./soak.sh` → RSS plateaus. Record in results.md.
