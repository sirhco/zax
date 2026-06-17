# Metrics Collector (F2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A built-in `zax.Metrics` observer that aggregates F1 `AccessRecord`s into thread-safe counters + a latency histogram, with `snapshot()` and `writePrometheus(writer)` so users can serve `/metrics`.

**Architecture:** Add `Metrics` + `MetricsSnapshot` to `src/observe.zig`. `Metrics` implements the F1 `Observer` interface (`metrics.observer()`), so it's wired via `app.observe(metrics.observer())` — no server change. Atomic counters (total, per-status-class, bytes_total, latency histogram with Prometheus-default buckets + duration sum). `writePrometheus` emits standard Prometheus text from a `snapshot()`. In-flight gauge deferred (needs a request-start hook). `/metrics` is a documented handler pattern (primitives + example), not a built-in route.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-17-observe-metrics-design.md`. Branch: `feat/observe-metrics`. Reuses F1 (`Observer`/`AccessRecord` in `src/observe.zig`).

**Conventions:** Tests via `zig build test --summary all`. TDD for the metrics logic + Prometheus output. End-to-end wiring verified by a server integration test. Baseline = **143 tests**.

---

## File Structure

- **Modify** `src/observe.zig` — `Metrics`, `MetricsSnapshot` (+ unit tests).
- **Modify** `src/root.zig` — export `Metrics`, `MetricsSnapshot`.
- **Modify** `src/server.zig` — integration test (metrics observer + `/metrics` handler).
- **Modify** `README.md`, `docs/getting-started.md` — metrics + `/metrics` example.

---

## Task 1: `Metrics` + `MetricsSnapshot` in observe.zig (TDD)

**Files:** Modify `src/observe.zig`, `src/root.zig`

- [ ] **Step 1: Write the failing unit tests** — add to the observe.zig test block:

```zig
test "metrics: counts, classes, bytes, sum, buckets" {
    var m = Metrics{};
    const obs = m.observer();
    // 3ms 200, 30ms 200, 2s 404, 30s 500
    obs.func(obs.context, .{ .method = .GET, .path = "/a", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });
    obs.func(obs.context, .{ .method = .GET, .path = "/b", .status = 200, .duration_ns = 30_000_000, .bytes = 20 });
    obs.func(obs.context, .{ .method = .GET, .path = "/c", .status = 404, .duration_ns = 2_000_000_000, .bytes = 0 });
    obs.func(obs.context, .{ .method = .GET, .path = "/d", .status = 500, .duration_ns = 30_000_000_000, .bytes = 5 });

    const s = m.snapshot();
    try testing.expectEqual(@as(u64, 4), s.total);
    try testing.expectEqual(@as(u64, 2), s.class[2]); // 2xx
    try testing.expectEqual(@as(u64, 1), s.class[4]); // 4xx
    try testing.expectEqual(@as(u64, 1), s.class[5]); // 5xx
    try testing.expectEqual(@as(u64, 35), s.bytes_total);
    try testing.expectEqual(@as(u64, 3_000_000 + 30_000_000 + 2_000_000_000 + 30_000_000_000), s.duration_sum_ns);
    // 3ms -> bucket[0] (le 0.005s); 30ms -> bucket[3] (le 0.05s); 2s -> bucket[8] (le 2.5s);
    // 30s -> no bucket (>10s; counted only in total / +Inf).
    try testing.expectEqual(@as(u64, 1), s.buckets[0]);
    try testing.expectEqual(@as(u64, 1), s.buckets[3]);
    try testing.expectEqual(@as(u64, 1), s.buckets[8]);
}

test "metrics: prometheus exposition" {
    var m = Metrics{};
    const obs = m.observer();
    obs.func(obs.context, .{ .method = .GET, .path = "/a", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });
    obs.func(obs.context, .{ .method = .GET, .path = "/b", .status = 200, .duration_ns = 3_000_000, .bytes = 10 });

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try m.writePrometheus(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "zax_requests_total{class=\"2xx\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_bucket{le=\"0.005\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_bucket{le=\"+Inf\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_request_duration_seconds_count 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zax_response_bytes_total 20") != null);
}
```

- [ ] **Step 2: Run to verify it fails** — `zig build test 2>&1 | grep -E "error|expected" | head`. Expected: `Metrics`/`snapshot`/`writePrometheus` undefined.

- [ ] **Step 3: Implement `Metrics` + `MetricsSnapshot`** per the spec's Component 1/2:
  - Fields: `total`, `class: [6]`, `bytes_total`, `duration_sum_ns`, `buckets: [bucket_bounds_ns.len]` (all `std.atomic.Value(u64)`), with defaults so `Metrics{}` zero-inits (use `@splat(.init(0))`; if unavailable, `[_]std.atomic.Value(u64){.init(0)} ** N`).
  - `observer()` → `Observer{ .context = self, .func = record }`.
  - `record`: fetchAdd total, `class[status/100]` (guard 1..5), bytes_total, duration_sum_ns; increment the first bucket whose bound ≥ duration (`break`); durations beyond the last bound increment no bucket.
  - `snapshot()`: atomic `.load(.monotonic)` of every counter into `MetricsSnapshot`.
  - `writePrometheus(w)`: take a snapshot; emit the lines in the spec (HELP/TYPE; `zax_requests_total{class="Nxx"}` for classes 1–5; `zax_response_bytes_total`; histogram with CUMULATIVE `le` buckets using the `bucket_bounds_ns` in seconds, `le="+Inf"` = total, `_sum` = `duration_sum_ns`/1e9 with enough precision, `_count` = total). Format `le` labels as the seconds value (e.g. `0.005`, `0.01`, `0.025`, ... `10`); match the test's exact strings (`le="0.005"`).

- [ ] **Step 4: Export from root** — in `src/root.zig`, under the observability section: `pub const Metrics = observe.Metrics;` and `pub const MetricsSnapshot = observe.MetricsSnapshot;`.

- [ ] **Step 5: Run to verify it passes** — `zig build test --summary all 2>&1 | grep -E "tests passed|error"`. Expected: all pass (143 + 2 new). Report the count.

- [ ] **Step 6: Commit**

```bash
git add src/observe.zig src/root.zig
git commit -m "feat(observe): Metrics collector with snapshot and Prometheus exposition"
```

---

## Task 2: end-to-end integration test (metrics + /metrics handler)

**Files:** Modify `src/server.zig`

- [ ] **Step 1: Write the failing integration test** — add to the test section of `src/server.zig`. Use a file-scope `Metrics` + a `/metrics` handler (the documented pattern), register the observer, drive requests, then GET `/metrics`:

```zig
var test_metrics: observe_mod.Metrics = .{};
fn metricsTestHandler(a: zax.Alloc) !Response {
    var w = std.Io.Writer.Allocating.init(a.value);
    try test_metrics.writePrometheus(&w.writer);
    return .{ .status = .ok, .content_type = "text/plain; version=0.0.4", .body = w.written() };
}

test "metrics: end-to-end via observer + /metrics handler" {
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = Db{ .msg = "" };
    var app = try TestApp.init(testing.allocator, &db, .{});
    defer app.deinit();
    test_metrics = .{}; // reset (tests may share process)
    try app.get("/ping", pingHandler);
    try app.get("/metrics", metricsTestHandler);
    try app.observe(test_metrics.observer());

    const port: u16 = 18191;
    var loop_fut = startTestApp(io, &app, port);

    var rb: [2048]u8 = undefined;
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);
    _ = doRequest(io, port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n", &rb);

    var rb2: [4096]u8 = undefined;
    const r = doRequest(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n", &rb2);
    try testing.expect(std.mem.indexOf(u8, r, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, r, "zax_requests_total{class=\"2xx\"}") != null);
    // 2 pings + (the /metrics request itself is observed AFTER its response, so not yet counted)
    try testing.expect(std.mem.indexOf(u8, r, "zax_requests_total{class=\"2xx\"} 2") != null);

    app.requestShutdown(io);
    loop_fut.await(io);
}
```
CONFIRM: `observe_mod` is the import name used in server.zig (from F1); `zax.Alloc`/`std.Io.Writer.Allocating`/`.written()` exist in this Zig (adapt the writer if the Allocating API differs — e.g. render into a fixed buffer from `a.value` instead). The `/metrics` request is observed only after its own response is written, so at render time only the 2 prior pings are counted — assert `2`. If the count differs due to ordering, assert `>= 2` and note it. Pick a free port.

- [ ] **Step 2: Run to verify it fails then passes** — first it fails (handler/metrics not wired or assertion), then after Task 1 it should pass. Run `zig build test --summary all 2>&1 | grep -E "tests passed|error"` → 146 (143 + 2 unit + 1 integration). Report.

- [ ] **Step 3: Flakiness check** — `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo "run $i ok"; done` → three ok lines.

- [ ] **Step 4: Commit**

```bash
git add src/server.zig
git commit -m "test(server): metrics end-to-end via observer and /metrics handler"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — extend the Observability section: `zax.Metrics` is a built-in observer (`try app.observe(metrics.observer())`) tracking total/by-status-class/bytes/latency-histogram; `metrics.writePrometheus(writer)` emits Prometheus text; show the `/metrics` handler pattern (the spec's Component 3 example, verified against shipped names). Note in-flight is not tracked (post-response only).

- [ ] **Step 2: getting-started** — a couple of lines on `Metrics` + serving `/metrics`.

- [ ] **Step 3: Verify** — `zig build test --summary all 2>&1 | grep "tests passed"` (146).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document the Metrics collector and /metrics exposition"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines (146).
- [ ] (Optional) scratch app: register `Metrics` + `/metrics`, hit a few routes, `curl /metrics` shows counters + histogram.

---

## Self-review notes

- **Spec coverage:** Metrics + snapshot + Prometheus + tests (Task 1); end-to-end integration (Task 2); docs (Task 3). All F2 spec components covered.
- **Reuses F1:** `Metrics` is an `Observer`; wired via `app.observe` with zero server change.
- **Thread safety:** all counters are `.monotonic` atomics; `snapshot()` is eventually-consistent (documented).
- **Histogram correctness:** non-cumulative bucket storage at record time, accumulated to `le`-cumulative at export; `+Inf` = total (so out-of-range durations are still counted). Unit-tested incl. an out-of-range (30s) duration.
- **No `/metrics` route built in:** primitives + documented handler pattern (instance reachable via app state or a global), validated end-to-end.
- **Regression safety:** additive (observe.zig + root export + tests); existing 143 tests untouched; server unchanged except a new test.
