# Benchmark Coverage (E3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `zig build bench` to cover the framework's real surface: micros for the middleware chain, wildcard + nested routing, and the `Path`/`Query`/`Json` extractors; plus e2e scenarios for a param route and a JSON-echo POST (per-scenario throughput + bytes/req).

**Architecture:** Add six micros to `microBenchmarks` (warmup+sample loop, like existing ones), using duck-typed fake contexts (`fromContext`/the chain take `anytype`/opaque ctx) and a per-iteration `FixedBufferAllocator` for the allocating extractors. Parameterize `runLoad`/`worker` with a `req: []const u8` and drive a `Scenario { name, req }` list from both `endToEnd` (throughput) and `memoryMetrics` (bytes/req). No new unit tests — E3 is benchmark code over already-tested paths; the suite stays at **136**, verified by `zig build bench` + `zig build test`.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-bench-coverage-design.md`. Branch: `feat/bench-coverage`. All needed symbols are exported: `zax.Chain`, `zax.Path`/`Query`/`Json`, `zax.radix`, `zax.Request`/`Param`/`Response`.

**Conventions:** Tests via `zig build test --summary all` (stays 136). Bench verified by running `zig build bench`. Self-relative only. Reuse existing helpers (`nsPerOp`, `report`, `metrics.median`/`stddev`/`percentile`, `runLoad`).

---

## File Structure

- **Modify** `src/bench.zig` — 6 new micros; `Scenario` list + `userHandler`/`echoHandler`; parameterize `runLoad`/`worker` with `req`; per-scenario `endToEnd` + `memoryMetrics`.
- **Modify** `README.md`, `docs/getting-started.md` — expanded coverage note.

---

## Task 1: Six new micro-benchmarks

**Files:** Modify `src/bench.zig`

- [ ] **Step 1: Add file-scope helpers** for the chain micro (near the other handlers):

```zig
const FakeCtx = struct {};
const FChn = zax.Chain(FakeCtx);
fn passThru(_: *const FakeCtx, next: *FChn.Next) anyerror!zax.Response {
    return next.run();
}
fn chainHandler(_: *const FakeCtx) anyerror!zax.Response {
    return zax.Response.text("ok");
}
```

- [ ] **Step 2: Add the six micros** inside `microBenchmarks`, each mirroring the existing warmup-then-`for (buf) |*slot|` sample pattern (setup outside the loops; `doNotOptimizeAway(sink)`; `slot.* = nsPerOp(ns, iters)`; final `report`). Sketches:

```zig
// middleware chain (3 pass-through mws)
{
    const mws = [_]FChn.Middleware{ &passThru, &passThru, &passThru };
    var ctx = FakeCtx{};
    // warmup + samples: const r = FChn.run(&mws, &chainHandler, &ctx) catch unreachable; sink +%= r.body.len;
    // report "middleware x3"
}

// radix wildcard match
{
    var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
    defer tree.deinit();
    (try tree.getOrPutSlot("/assets/*path")).* = 1;
    var pb: [8]zax.radix.Param = undefined;
    // match("/assets/a/b/c", &pb); sink +%= m.value + m.params.len;
    // report "radix wildcard"
}

// radix nested match (stands in for group-prefixed routes)
{
    var tree = try zax.radix.Tree(usize).init(std.heap.page_allocator);
    defer tree.deinit();
    (try tree.getOrPutSlot("/api/v1/users/:id")).* = 1;
    var pb: [8]zax.radix.Param = undefined;
    // match("/api/v1/users/42", &pb); sink +%= m.value + m.params.len;
    // report "radix nested"
}

// Path extract
{
    const params = [_]zax.Param{.{ .name = "id", .value = "42" }};
    var fbuf: [512]u8 = undefined;
    // per iter: var fba = std.heap.FixedBufferAllocator.init(&fbuf);
    //           const p = zax.Path(struct{ id: u64 }).fromContext(.{ .params = &params, .arena = fba.allocator() }) catch unreachable;
    //           sink +%= p.value.id;
    // report "Path extract"
}

// Query extract
{
    const qreq = zax.Request{ .method = .GET, .target = "", .path = "", .query = "active=true&page=2", .version_minor = 1, .headers = &.{}, .body = "" };
    var fbuf: [512]u8 = undefined;
    // per iter: fba reset; const q = zax.Query(struct{ active: bool, page: u32 }).fromContext(.{ .req = &qreq, .arena = fba.allocator() }) catch unreachable;
    //           sink +%= @intFromBool(q.value.active) + q.value.page;
    // report "Query extract"
}

// Json extract
{
    const jreq = zax.Request{ .method = .POST, .target = "", .path = "", .query = "", .version_minor = 1, .headers = &.{}, .body = "{\"id\":42,\"msg\":\"hello\"}" };
    var fbuf: [4096]u8 = undefined;
    // per iter: fba reset; const j = zax.Json(struct{ id: u64, msg: []const u8 }).fromContext(.{ .arena = fba.allocator(), .req = &jreq }) catch unreachable;
    //           sink +%= j.value.id + j.value.msg.len;
    // report "Json extract"
}
```

Confirm the exact `zax.Request` field set against `src/http/request.zig` (method, target, path, query, version_minor, headers, body) and adapt if it differs. Confirm `zax.Query`/`zax.Json` field-binding works for the chosen structs (they're exercised by existing unit tests).

- [ ] **Step 3: Build + run**

Run: `zig build bench -- --samples 2 --conns 2 --reqs 200 2>&1 | sed -n '/micro/,/end-to-end/p'`
Expected: the micro section now lists the original 3 plus `middleware x3`, `radix wildcard`, `radix nested`, `Path extract`, `Query extract`, `Json extract`, each with `ns/op +/- sd`.

- [ ] **Step 4: Tests still green**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: 136 (no new unit tests; bench-only change must not break the build).

- [ ] **Step 5: Commit**

```bash
git add src/bench.zig
git commit -m "feat(bench): micros for middleware chain, wildcard/nested match, extractors"
```

---

## Task 2: e2e scenarios (param route + JSON echo)

**Files:** Modify `src/bench.zig`

- [ ] **Step 1: Add scenario handlers + list + route registration** (file scope):

```zig
fn userHandler(p: zax.Path(struct { id: u64 })) zax.Response {
    _ = p;
    return zax.Response.text("ok");
}
fn echoHandler(b: zax.Json(struct { msg: []const u8 })) !zax.Response {
    return zax.Response.text(b.value.msg);
}

const Scenario = struct { name: []const u8, req: []const u8 };
const scenarios = [_]Scenario{
    .{ .name = "static GET", .req = "GET /bench HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "param GET", .req = "GET /users/123 HTTP/1.1\r\nHost: x\r\n\r\n" },
    .{ .name = "json POST", .req = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 15\r\n\r\n{\"msg\":\"hello\"}" },
};

fn registerBenchRoutes(app: *Api) !void {
    try app.get("/bench", benchHandler);
    try app.get("/users/:id", userHandler);
    try app.post("/echo", echoHandler);
}
```

VERIFY the JSON body byte length equals the `Content-Length` (``{"msg":"hello"}`` is 15 bytes) — if you change the body, update the header. Mismatched framing breaks the load.

- [ ] **Step 2: Parameterize `runLoad`/`worker` with `req`** — add `req: []const u8` to `runLoad`, thread it into `io.async(worker, .{ io, port, req, lat[c] })`; `worker(io, port, req, out_lat)` / `workerFallible` send `req` instead of the hardcoded `"GET /bench ..."`. `skipResponse` is unchanged (Content-Length framed).

- [ ] **Step 3: Make `endToEnd` loop scenarios** — register all routes once via `registerBenchRoutes`, bind + acceptLoop once, then for each scenario run the existing measured-samples + median-throughput + percentile logic (extract it into a small `benchScenario(io, gpa, out, port, cfg, sc)` helper to avoid duplication), printing a per-scenario block headed by `sc.name`. The first scenario (`static GET`) keeps the same shape as today so its numbers stay comparable.

- [ ] **Step 4: Make `memoryMetrics` loop scenarios** — register routes via `registerBenchRoutes`; for each scenario, snapshot the counting allocator around a measured load with `sc.req` and print `sc.name` + `bytes/req`; print peak RSS once at the end. (json POST should show clearly higher bytes/req than static/param.)

- [ ] **Step 5: Build + run**

Run: `zig build bench -- --samples 2 --conns 2 --reqs 300 2>&1 | sed -n '/end-to-end/,$p'`
Expected: the e2e section shows three named scenarios each with throughput + latency; the memory section shows three `bytes/req` lines (json POST highest) + peak RSS. Paste it in the report.

- [ ] **Step 6: Flakiness + tests**

Run: `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done`
Expected: three ok lines.
Run: `zig build test --summary all 2>&1 | grep "tests passed"` — 136.

- [ ] **Step 7: Commit**

```bash
git add src/bench.zig
git commit -m "feat(bench): param + JSON-echo e2e scenarios with per-scenario throughput and bytes/req"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — in the benchmarking/performance area, note the harness now covers the middleware chain, wildcard/nested routing, and the `Path`/`Query`/`Json` extractors (micros), plus param-route and JSON-echo e2e scenarios with per-scenario throughput and bytes/req. Keep the self-relative caveat.

- [ ] **Step 2: getting-started** — extend the `zig build bench` note to mention the broader coverage in one line.

- [ ] **Step 3: Verify**

Run: `zig build test --summary all 2>&1 | grep "tests passed"` — 136.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: note expanded benchmark coverage"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical 136 lines.
- [ ] Bench smoke: `zig build bench -- --samples 2 --conns 2 --reqs 300` shows the 6 new micros, 3 e2e scenarios, and 3 per-scenario bytes/req lines.

---

## Self-review notes

- **Spec coverage:** 6 micros (Task 1); e2e scenarios + per-scenario throughput/bytes/req (Task 2); docs (Task 3). All E3 spec components covered.
- **No new unit tests:** E3 drives already-tested library code (extractors/chain/radix); correctness is covered elsewhere. Suite stays 136; verification is `zig build bench` + green `zig build test`.
- **Group routing:** no dedicated micro — covered by the nested-match micro (the patterns groups produce) + the chain micro (group middleware). Documented in the spec.
- **Allocation honesty:** extractor micros reset a `FixedBufferAllocator` per iteration (bounded memory); the json POST e2e scenario surfaces real per-request allocation in `memoryMetrics`.
- **Regression safety:** the static `GET /bench` scenario stays first and unchanged in shape, so E1/E2 numbers remain comparable; bench is excluded from the default build/test, so the library and the 136 tests are untouched.
