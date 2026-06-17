# Zax — benchmark coverage (E3) design

Date: 2026-06-16. Status: accepted. Scope: sub-project E3 of theme E
(benchmarking, self-relative only). E1 (harness rigor) and E2 (alloc/memory
metrics) are done; E4 (regression baseline) remains, out of scope here.

## Context

The harness (post-E2) benchmarks only three micro paths (`parseHead`, radix
static+param `match`, `Response.write`) and one e2e scenario (a static `GET
/bench`). It measures nothing about the features built in themes C/D: the
middleware chain, the `Path`/`Query`/`Json` extractors, wildcard routing, or
group-prefixed routes. E3 adds that coverage — both in-process micros and richer
e2e scenarios — so the rigor (E1) and memory (E2) machinery actually exercise the
framework's real surface.

## Decision (from brainstorming)

1. **Six new micros**, mirroring the existing warmup+sample loop:
   - **middleware chain** — `zax.Chain(FakeCtx).run(&mws, handler, &ctx)` with 3
     pass-through middleware (per-request chain overhead).
   - **radix wildcard match** — `/assets/*path` matching `/assets/a/b/c` (the D2
     backtracking matcher).
   - **radix nested match** — `/api/v1/users/:id` matching `/api/v1/users/42`.
     This stands in for **group routing**: groups (D4) just register longer
     prefixed patterns in the same tree, so their match cost is ordinary radix
     match of a deeper path — there is no separate hot path to bench.
   - **Path extract** — `Path(struct{ id: u64 }).fromContext(fake)`.
   - **Query extract** — `Query(struct{ active: bool, page: u32 }).fromContext(fake)`.
   - **Json extract** — `Json(struct{ id: u64, msg: []const u8 }).fromContext(fake)`.

2. **Duck-typed fake contexts for extractor/chain micros.** `fromContext` and the
   chain take `anytype`/an opaque `*const Ctx`, so a minimal struct with only the
   fields each reads suffices (as the extractor unit tests already do): Path needs
   `{ params, arena }`; Query needs `{ req: *const Request, arena }`; Json needs
   `{ arena, req: *const Request }`; the chain needs only an opaque ctx value.

3. **Extractor micros reset a `FixedBufferAllocator` each iteration.** Path/Query/
   Json allocate into `ctx.arena` (URL-decode, urlencoded bind, JSON parse), so
   each micro re-inits a stack `FixedBufferAllocator` per iteration — bounded
   memory, no growth across millions of iterations, negligible reset cost.

4. **Group routing gets no dedicated micro** (decision 1) — covered by the
   nested-match micro (the patterns groups produce) plus the chain micro (group/
   per-route middleware). Documented so the omission is explicit, not an oversight.

5. **Three e2e scenarios via a parameterized load.** `runLoad`/`worker` gain a
   `req: []const u8` parameter (today they hardcode `GET /bench`). A `Scenario {
   name, req }` list drives the load: static `GET /bench`, param `GET
   /users/123` (→ `Path` handler), and `POST /echo` with a JSON body (→ `Json`
   handler echoing a field). `endToEnd` reports per-scenario throughput +
   latency; `memoryMetrics` (E2) reports per-scenario bytes/req. The JSON echo
   scenario is the standout — the one path with real per-request allocation.

## Architecture

```
micro section: existing 3 + chain, wildcard, nested-match, Path, Query, Json
e2e section:   scenarios = [ static GET /bench, param GET /users/:id, json POST /echo ]
   endToEnd   -> register all routes once; per scenario: warmup+samples -> median throughput + latency
   memoryMetrics (E2) -> per scenario: counter delta -> bytes/req ; peak RSS once
```

Shared helpers: `registerBenchRoutes(app)` registers `/bench`, `/users/:id`,
`/echo`; `const scenarios` array; `runLoad(io, gpa, port, req, conns, reqs, all)`.

## Components (all in `src/bench.zig` unless noted)

### 1. Micros (extend `microBenchmarks`)
File-scope helpers: `FakeCtx`/`passThru`/`chainHandler` for the chain micro; a
static `params` array and fake `Request` values for the extractor micros. Each
micro follows the existing warmup-then-`cfg.samples` loop and calls
`report(out, name, metrics.median(buf), metrics.stddev(buf))`.

### 2. e2e scenarios
- `const Scenario = struct { name: []const u8, req: []const u8 };`
- `const scenarios = [_]Scenario{ ... }` (the JSON POST's `Content-Length` must
  equal its body's byte length).
- Handlers: `userHandler(p: zax.Path(struct{ id: u64 })) Response` → `Response.text("ok")`;
  `echoHandler(b: zax.Json(struct{ msg: []const u8 })) !Response` → `Response.text(b.value.msg)`.
- `worker`/`workerFallible`/`runLoad` take `req: []const u8`.
- `endToEnd` registers all routes once, binds, then loops scenarios printing a
  per-scenario throughput + latency block (reusing the median-sample logic).
- `memoryMetrics` loops scenarios printing per-scenario `bytes/req`, then peak RSS.

## Testing

- **No new unit tests.** E3 adds benchmark code that drives already-tested
  library paths; correctness of extractors/chain/radix is covered by their
  existing unit tests. The suite stays at 136.
- **Manual (`zig build bench`):** the micro section shows the 6 new lines with
  `median ns/op ± sd`; the e2e section shows three named scenarios with
  throughput + latency; the memory section shows per-scenario bytes/req (json
  POST marginally higher than static/param — per-connection buffer amortization
  dominates at small loads, see Risks) + peak RSS. Honored by `--conns`/
  `--reqs`/`--samples`/`--warmup`. Self-relative only.
- **Regression:** `zig build test` stays green (136).

## Files

- Modify: `src/bench.zig` (6 micros; `Scenario` list + handlers; parameterize
  `runLoad`/`worker`; per-scenario `endToEnd` + `memoryMetrics`).
- Modify: `README.md`, `docs/getting-started.md` (note the expanded coverage).

## Risks & edge cases

- **FixedBufferAllocator sizing:** Json needs the most (a few KB); size each
  micro's buffer for its payload, with headroom. If an extractor ever exceeds it,
  the micro would error — sizes are fixed for the fixed sample inputs.
- **Content-Length correctness:** the JSON POST request's `Content-Length` must
  match the body length exactly or the server will mis-frame; verified against
  the literal's byte length.
- **e2e refactor regressions:** parameterizing `runLoad`/`worker` and looping
  scenarios must not change the static `GET /bench` numbers vs E2 — the static
  scenario stays first and identical in shape.
- **Micro realism:** the extractor micros measure extraction with a reset FBA,
  not the server's per-request arena; numbers are component cost, not end-to-end
  (the e2e scenarios cover end-to-end). Documented.

## Out of scope

Regression baselines/`--check` (E4), cross-framework comparison (whole theme E),
a dedicated group-routing micro (covered by nested-match + chain).
