# Design — large-payload load test for the evented payload fixes

**Status:** approved 2026-06-20. Branch `feat/bench-large-payload` (off main `5674c39`).

## Problem

Two evented fixes shipped in v0.8.0 — large buffered responses (head/body split pump) and
lazy slot buffers — are only unit-tested + an 8s smoke bench. The cross-framework harness
(`benchmarks/cross/`) only exercises tiny bodies (≤12B): `/` "hello", `/users/{id}`, `/echo`.
The new evented large-response code path and the lazy-slot memory high-water-mark are
**unmeasured under load**. We need a load test that (a) drives large buffered responses across
frameworks and (b) checks memory does not leak under sustained large-body traffic.

## Goal

Add a configurable large-payload scenario to the cross harness (all 4 servers) and a soak
script that watches zax-ev's RSS across repeated load waves to confirm it plateaus (no leak).

Non-goals: changing the framework code; a hard pass/fail memory threshold (RSS limits are
environment-specific — the soak is observational); streamed large responses (this validates
the BUFFERED large-response path specifically).

### Decisions (confirmed with Chris)
- **Configurable size** via `PAYLOAD_KB` env (default 64).
- **All 4 servers** (zax/axum/go/httpz) get a `/large` route → cross-framework comparison.
- **Leak/soak** = repeated-wave RSS-plateau observation against zax-ev (the lazy-slot retain
  model means RSS won't return to baseline, but across identical waves it must plateau after
  wave 1; climbing = leak).

## Key facts (harness)

- `benchmarks/cross/run.sh` scenarios (`:343-345`): `drive "$name" static|param|json …`. `drive`
  runs oha + parses metrics; the MEMORY table samples per-pass idle/peak RSS via `ps -o rss=`
  (added in the bench-memory feature; `rss_kb` helper exists).
- Server routes (3 each): zax `app.get/post` (`zax/src/main.zig:68-70`, reads `ZAX_*`/env via
  `init.environ_map`); go `mux.HandleFunc` (`go/main.go`); axum `.route(...)` (`axum/src/main.rs:35-37`);
  httpz `router.get/post` (`httpz/src/main.zig`). Each server is one process (RSS = whole server).
- A BUFFERED response (content-length set, not streamed) of >8KB is exactly what exercises the
  evented large-response body-phase pump. `PAYLOAD_KB=64` ≫ the 8KB write_buf.

## Components

### Modified: the 4 bench servers — add a `/large` route

Each server reads `PAYLOAD_KB` (env, default 64), builds a buffered JSON-ish body of about that
size **once at startup**, and serves it at `GET /large` as a normal buffered response
(content-length set). Body shape: `{"data":"xxxx…"}` padded so total ≈ `PAYLOAD_KB*1024` bytes
(mirrors the reported "large JSON" case). One process → the body buffer is a module/startup
value shared by the handler.

- **zax** (`benchmarks/cross/zax/src/main.zig`): read `init.environ_map.get("PAYLOAD_KB")`
  (default 64); allocate + fill the body in `main` (gpa/arena that outlives serving); a
  module-level `var large_body: []const u8` set before `app.get("/large", large)`; `fn large`
  returns `Response.text(large_body)` (or `.json`/`jsonRaw`). Buffered → hits the evented
  large-response path under `ZAX_BACKEND=evented`.
- **go** (`go/main.go`): `mux.HandleFunc("GET /large", …)` writing a `[]byte` body built from
  `os.Getenv("PAYLOAD_KB")` at startup; set `Content-Type` + write the buffer.
- **axum** (`axum/src/main.rs`): build a `String`/`Bytes` body once in `main` from
  `std::env::var("PAYLOAD_KB")`, share into a `get(...)` handler (closure/state); `.route("/large", …)`.
- **httpz** (`httpz/src/main.zig`): module-level `var large_body` set in `main` from env;
  `router.get("/large", large, .{})`; `fn large(_, res) res.body = large_body;`.

All return a buffered body (content-length), NOT a stream — that is the path under test.

### Modified: `benchmarks/cross/run.sh`

- Export the payload size so every server launch sees it: near the env defaults, add
  `export PAYLOAD_KB="${PAYLOAD_KB:-64}"`.
- Add a scenario after the json drive (`:345`):
  `drive "$name" large "http://127.0.0.1:$port/large"`.
- The latency table gains `large` rows; the existing MEMORY table now reflects peak RSS under
  large bodies (no code change to the memory path).

### Added: `benchmarks/cross/soak.sh`

A standalone leak/plateau check (bash). Steps:
1. Build the zax bench server (or assume `run.sh`/Docker built it).
2. Launch zax-ev once: `env ZAX_BACKEND=evented PAYLOAD_KB="${PAYLOAD_KB:-64}" ./zax/zig-out/bin/zax-bench &`; capture pid; wait readiness via the curl loop.
3. Loop `SOAK_WAVES` (default 5): each wave run `oha -z "${SOAK_DUR:-10s}" -c "${CONNS:-64}" --no-tui http://127.0.0.1:8081/large >/dev/null`; after the wave sample `rss_kb $pid`; record `wave→rss_mb`.
4. Kill the server. Print the RSS-per-wave series + a verdict: compare the last wave's RSS to
   wave 1's; if growth exceeds a soft threshold (e.g. >10%) print "POSSIBLE LEAK — RSS climbing",
   else "OK — RSS plateaued". Observational (threshold is a hint, not CI gate).
5. Reuse the `ps -o rss=` sampler idiom; portable mac+Linux. Clean up server + temp on EXIT trap.

## Data flow (soak)

```
launch zax-ev (PAYLOAD_KB) → readiness
  for wave in 1..N: oha -z DUR /large → sample RSS(pid) → record
kill → print wave→RSS series + plateau-vs-climb verdict
```

## Error handling

- Server fails to start / oha missing → soak.sh errors out clearly (oha is Chris's tool).
- `ps` empty (server died) → report and stop.
- EXIT trap kills the server (no stray process).

## Behavior change & test impact

- Purely additive to the bench harness: a new `/large` route + `large` scenario + `soak.sh`.
  Existing scenarios, the memory table, and all framework code are unchanged.

## Testing

This is bench tooling; the full oha run (large scenario + soak) is Chris's. Verifiable here:
1. **Each server builds** with the new route: `zig build -Doptimize=ReleaseFast` (zax, httpz),
   `cargo build --release` (axum), `go build` (go) — confirm `/large` compiles. If a toolchain
   is unavailable locally, syntax-review + note it.
2. `bash -n benchmarks/cross/run.sh` and `bash -n benchmarks/cross/soak.sh` — clean.
3. **Standalone RSS-sampler check** (no oha): launch a dummy `sleep` process, confirm
   `ps -o rss= -p <pid>` returns a positive integer (the soak's measurement primitive works).

## Verification

- The 4 servers build; `bash -n` clean on both scripts; sampler check passes.
- Real run (Chris): `cd benchmarks/cross && BACKEND=both PAYLOAD_KB=64 ./run.sh` shows a `large`
  row per framework (zax-ev serves it — 200, not 500 — with competitive throughput) + the
  MEMORY table's peak under large load; `SOAK_WAVES=5 ./soak.sh` prints an RSS series that
  plateaus (no leak). Numbers recorded in `results.md`.

## Docs

- `benchmarks/cross/README.md`: document the `large` scenario (`PAYLOAD_KB`, default 64) and
  `soak.sh` (`SOAK_WAVES`/`SOAK_DUR`), with the expected outcome (zax-ev serves large bodies,
  no 500; RSS bounded and plateaus across waves).
- No CHANGELOG entry — internal benchmark tooling, not a library change.
