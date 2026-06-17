# Zax — metrics collector (F2) design

Date: 2026-06-17. Status: accepted. Scope: sub-project F2 of theme F
(observability). F1 (observation hook + access logger) is done; F3 (request id)
remains, out of scope here.

## Context

F1 added `App.observe(observer)` and the type-erased `Observer{context, func}`
fired per routed request with an `AccessRecord{method, path, status,
duration_ns, bytes}`. F2 adds a built-in `Metrics` observer that aggregates those
records into thread-safe counters + a latency histogram, with a snapshot API and
Prometheus-text exposition so users can serve `/metrics`.

## Decision (from brainstorming)

1. **Post-response only; reuse the F1 hook.** `Metrics` implements the `Observer`
   interface (`metrics.observer()` → `Observer`), so it's registered with
   `app.observe(metrics.observer())`. No server change. The **in-flight gauge is
   deferred** (it needs a request-start hook F1 doesn't expose) — documented as a
   possible future addition.
2. **Thread-safe atomic counters.** Observers fire from the `Io.Threaded` pool, so
   every counter is a `std.atomic.Value(u64)` updated with `.monotonic` fetchAdd.
   Metrics tracked: `total`; per-status-class counters (1xx–5xx, indexed by
   `status/100`); `bytes_total`; a latency histogram (per-bucket counts +
   `duration_sum_ns`).
3. **Prometheus-default histogram buckets** (seconds): 0.005, 0.01, 0.025, 0.05,
   0.1, 0.25, 0.5, 1, 2.5, 5, 10 (stored in ns). Bucket counts are stored
   non-cumulatively (each record increments the single smallest bucket it fits)
   and accumulated to cumulative `le` form at export; `+Inf` = `total`.
4. **Snapshot + exposition.** `snapshot()` does atomic loads into a plain
   `MetricsSnapshot` (point-in-time, no atomics) for reading/testing.
   `writePrometheus(writer)` emits Prometheus text from a snapshot.
5. **No `/metrics` handler factory.** A ready-made handler can't know where the
   `Metrics` instance lives (it's the user's, not the framework's), and zax
   handlers are comptime-wrapped. Instead provide the primitives and a documented
   ~6-line handler pattern (the `Metrics` reachable via `State`/app state or a
   module global; render via `writePrometheus` into the request arena). Validated
   by an integration test.
6. **Lives in `src/observe.zig`** alongside `AccessLogger` (cohesive
   observability module), exported as `zax.Metrics` / `zax.MetricsSnapshot`.

## Architecture

```
app.observe(metrics.observer())     // F1 hook fans each AccessRecord to metrics.record
   record(rec): total++; class[status/100]++; bytes_total += bytes;
                duration_sum_ns += duration_ns; buckets[firstFit]++

GET /metrics handler -> metrics.writePrometheus(arena_writer) -> text/plain body
```

## Components (all in `src/observe.zig`)

### 1. `Metrics`

```zig
pub const Metrics = struct {
    pub const bucket_bounds_ns = [_]u64{ 5_000_000, 10_000_000, 25_000_000, 50_000_000,
        100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000, 10_000_000_000 };

    total: std.atomic.Value(u64) = .init(0),
    class: [6]std.atomic.Value(u64) = @splat(.init(0)), // index by status/100; 1..5 used
    bytes_total: std.atomic.Value(u64) = .init(0),
    duration_sum_ns: std.atomic.Value(u64) = .init(0),
    buckets: [bucket_bounds_ns.len]std.atomic.Value(u64) = @splat(.init(0)),

    pub fn observer(self: *Metrics) Observer { return .{ .context = self, .func = record }; }

    fn record(ctx: *anyopaque, rec: AccessRecord) void {
        const self: *Metrics = @ptrCast(@alignCast(ctx));
        _ = self.total.fetchAdd(1, .monotonic);
        const cls = rec.status / 100;
        if (cls >= 1 and cls <= 5) _ = self.class[cls].fetchAdd(1, .monotonic);
        _ = self.bytes_total.fetchAdd(rec.bytes, .monotonic);
        _ = self.duration_sum_ns.fetchAdd(rec.duration_ns, .monotonic);
        for (bucket_bounds_ns, 0..) |bound, i| {
            if (rec.duration_ns <= bound) { _ = self.buckets[i].fetchAdd(1, .monotonic); break; }
        } // > largest bound -> only counted in total (the +Inf bucket at export)
    }

    pub fn snapshot(self: *const Metrics) MetricsSnapshot { /* atomic loads */ }
    pub fn writePrometheus(self: *const Metrics, w: *std.Io.Writer) !void { /* from snapshot */ }
};

pub const MetricsSnapshot = struct {
    total: u64,
    class: [6]u64,
    bytes_total: u64,
    duration_sum_ns: u64,
    buckets: [Metrics.bucket_bounds_ns.len]u64,
};
```
(`@splat(.init(0))` for the atomic arrays; if that form is unavailable in this
Zig, use `[_]std.atomic.Value(u64){.init(0)} ** N` — `Metrics{}` must default-init.)

### 2. Prometheus exposition (`writePrometheus`)

Emits (counts from snapshot; durations in seconds; cumulative buckets):
```
# HELP zax_requests_total Total HTTP requests by status class.
# TYPE zax_requests_total counter
zax_requests_total{class="1xx"} N
zax_requests_total{class="2xx"} N
... 3xx 4xx 5xx
# HELP zax_response_bytes_total Total response body bytes.
# TYPE zax_response_bytes_total counter
zax_response_bytes_total N
# HELP zax_request_duration_seconds Request duration.
# TYPE zax_request_duration_seconds histogram
zax_request_duration_seconds_bucket{le="0.005"} C0
zax_request_duration_seconds_bucket{le="0.01"} C0+C1
... (cumulative)
zax_request_duration_seconds_bucket{le="+Inf"} total
zax_request_duration_seconds_sum X.XXXXXX
zax_request_duration_seconds_count total
```

### 3. Serving `/metrics` (documented pattern, not built-in)

```zig
// METRICS reachable via app state or a module global.
fn metricsHandler(a: zax.Alloc) !zax.Response {
    var w = std.Io.Writer.Allocating.init(a.value);
    try METRICS.writePrometheus(&w.writer);
    return .{ .status = .ok, .content_type = "text/plain; version=0.0.4", .body = w.written() };
}
try app.get("/metrics", metricsHandler);
```

## Testing

- **Unit (`zig build test`):** drive `metrics.observer().func` with several
  `AccessRecord`s; assert `snapshot()` — `total`, `class[2]`/`class[4]`/`class[5]`
  counts, `bytes_total`, `duration_sum_ns`, and per-bucket counts (e.g. a 3ms
  record lands in the 0.005s bucket, a 2s record in the 2.5s bucket, a 30s record
  in none/only the +Inf=total). `writePrometheus` into a buffer; assert key lines
  (`zax_requests_total{class="2xx"} 2`, cumulative `_bucket` monotonicity,
  `_count` == total, `_sum` == duration_sum_ns/1e9).
- **Integration (`src/server.zig` socket test):** register `metrics.observer()`
  via `app.observe` and a `/metrics` handler; make a couple of requests; `GET
  /metrics` returns 200 with a body containing `zax_requests_total` and a count
  reflecting the requests made.
- **Regression:** full `zig build test` green (143 + new observe + server tests).

## Files

- Modify: `src/observe.zig` (`Metrics`, `MetricsSnapshot`, tests).
- Modify: `src/root.zig` (export `Metrics`, `MetricsSnapshot`).
- Modify: `src/server.zig` (integration test only).
- Modify: `README.md`, `docs/getting-started.md` (metrics + `/metrics` example).

## Risks & edge cases

- **Atomic-array defaults:** `Metrics{}` must zero-init the atomic arrays
  (`@splat`/`**` repetition). Confirm the working form.
- **Non-cumulative bucket storage:** record increments one bucket; export
  accumulates. A duration above the largest bound increments no bucket but still
  bumps `total`, so `+Inf` (=total) ≥ last cumulative bucket — correct Prometheus
  semantics.
- **Snapshot consistency:** `snapshot()` reads counters one-by-one (not a single
  atomic transaction), so a concurrent update can make `total` and a bucket
  momentarily inconsistent. Acceptable for metrics (eventually consistent);
  documented.
- **Thread safety:** all updates are `.monotonic` atomics; exact totals
  guaranteed, ordering across counters irrelevant for monitoring.
- **`writePrometheus` allocation:** the handler renders into the request arena;
  the framework imposes no allocation itself.

## Out of scope

In-flight gauge (needs a request-start hook), request id (F3), per-route/per-path
metrics (cardinality risk), pull vs push exporters, a built-in `/metrics` route.
