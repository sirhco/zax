# Benchmark Allocation/Memory Metrics (E2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `zig build bench` reports a new `-- memory --` section: **bytes/req** (allocator pressure per request) and **peak RSS** (process high-water in MB), self-relative.

**Architecture:** A new pure `src/bench/counting.zig` provides a thread-safe `CountingAllocator` (wraps a child allocator, atomic cumulative byte counter), unit-tested under `zig build test`. A new `memoryMetrics` section in `src/bench.zig` inits its own app with the counting allocator, runs `cfg.warmup` discarded loads, then snapshots the counter around one measured load (`cfg.conns × cfg.reqs`) → `bytes/req = delta / reqs`; reads peak RSS via `getrusage(SELF).maxrss` (unit-normalized to MB). Kept separate from `endToEnd` so E1's throughput/latency numbers stay free of counting overhead. The loopback client uses the raw `gpa`, so only server allocations are counted.

**Tech Stack:** Zig 0.16.0. Spec: `docs/superpowers/specs/2026-06-16-bench-alloc-metrics-design.md`. Branch: `feat/bench-alloc-metrics`.

**Conventions:** Tests via `zig build test --summary all`. TDD for the counting allocator. The memory section is verified by running `zig build bench`. Baseline = **132 tests** (after E1). Self-relative only.

---

## File Structure

- **Add** `src/bench/counting.zig` — `CountingAllocator` + unit tests.
- **Modify** `src/bench.zig` — `memoryMetrics` section; call from `main`; import counting; add to the `test {}` discovery block.
- **Modify** `README.md`, `docs/getting-started.md` — bench memory metrics note.

---

## Task 1: `src/bench/counting.zig` — thread-safe counting allocator + tests

**Files:** Add `src/bench/counting.zig`; modify `src/bench.zig` (discovery block)

- [ ] **Step 1: Write the failing unit tests** — create `src/bench/counting.zig` with the API surface and a test block (red until implemented):

```zig
const std = @import("std");

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    bytes: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator { ... }       // Step 3
    pub fn bytesAllocated(self: *const CountingAllocator) usize { return self.bytes.load(.monotonic); }
    pub fn reset(self: *CountingAllocator) void { self.bytes.store(0, .monotonic); }
    // vtable fns in Step 3
};

const testing = std.testing;

test "counts cumulative bytes on alloc; free does not decrement" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const p = try a.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 64), c.bytesAllocated());
    const q = try a.alloc(u8, 100);
    try testing.expectEqual(@as(usize, 164), c.bytesAllocated());
    a.free(p);
    a.free(q);
    try testing.expectEqual(@as(usize, 164), c.bytesAllocated()); // cumulative, free doesn't decrement
}

test "reset zeroes the counter" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const p = try a.alloc(u8, 32);
    defer a.free(p);
    c.reset();
    try testing.expectEqual(@as(usize, 0), c.bytesAllocated());
}

test "delegates correctly (allocations are usable)" {
    var c = CountingAllocator{ .child = testing.allocator };
    const a = c.allocator();
    const buf = try a.alloc(u8, 8);
    defer a.free(buf);
    @memset(buf, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[7]);
}
```

- [ ] **Step 2: Wire discovery** — in `src/bench.zig`, add `_ = @import("bench/counting.zig");` inside the existing `test { ... }` block (next to the metrics import) so the bench test target runs counting's tests.

- [ ] **Step 3: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "error|FAIL|expected" | head`
Expected: failures — `allocator`/vtable not implemented.

- [ ] **Step 4: Implement `CountingAllocator`** — `allocator()` returns `.{ .ptr = self, .vtable = &vtable }` where `vtable` is a `std.mem.Allocator.VTable` with `alloc`/`resize`/`remap`/`free` matching this Zig version's signatures. Each fn casts `ctx` back to `*CountingAllocator` and delegates to `self.child` (via `self.child.rawAlloc`/`rawResize`/`rawRemap`/`rawFree` or `self.child.vtable.*`). Counting rules:
  - `alloc`: on success, `bytes.fetchAdd(len, .monotonic)`.
  - `resize`: delegate; if it succeeds and `new_len > old_len`, add the delta.
  - `remap`: delegate; if non-null and `new_len > old_len`, add the delta.
  - `free`: delegate; do not change the counter.
  (Confirm the exact `Allocator.VTable` field signatures against the std lib for Zig 0.16; adapt if they differ. Use `Alignment` type as std declares it.)

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass — new counting tests + existing 132. Report the actual count.

- [ ] **Step 6: Commit**

```bash
git add src/bench/counting.zig src/bench.zig
git commit -m "test(bench): thread-safe counting allocator wired into test step"
```

---

## Task 2: `memoryMetrics` section in `bench.zig`

**Files:** Modify `src/bench.zig`

- [ ] **Step 1: Add the section** — add `const counting = @import("bench/counting.zig");` near the other imports. Add a `memoryMetrics(io, gpa, out, cfg)` fn after `endToEnd`, reusing the existing `runLoad` helper and the `Db`/`Api`/`benchHandler` setup:

```zig
fn memoryMetrics(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, cfg: Config) !void {
    try out.print("-- memory (loopback, {d} conns x {d} reqs) --\n", .{ cfg.conns, cfg.reqs });

    var ca = counting.CountingAllocator{ .child = gpa };
    const cgpa = ca.allocator();

    var db = Db{};
    var app = try Api.init(cgpa, &db, .{}); // server allocations counted
    defer app.deinit();
    try app.get("/bench", benchHandler);

    const port: u16 = 18098;
    try app.bind(io, .{ .ip4 = .loopback(port) });
    var loop_fut = io.async(Api.acceptLoop, .{ &app, io });
    defer {
        app.requestShutdown(io);
        loop_fut.await(io);
    }

    const total = cfg.conns * cfg.reqs;
    // Warmup load(s): client uses the raw gpa (not counted).
    var w: usize = 0;
    while (w < cfg.warmup) : (w += 1) {
        const scratch = try gpa.alloc(i96, total);
        defer gpa.free(scratch);
        _ = runLoad(io, gpa, port, cfg.conns, cfg.reqs, scratch);
    }

    const lat = try gpa.alloc(i96, total);
    defer gpa.free(lat);
    const before = ca.bytesAllocated();
    _ = runLoad(io, gpa, port, cfg.conns, cfg.reqs, lat);
    const after = ca.bytesAllocated();

    const per_req: f64 = @as(f64, @floatFromInt(after - before)) / @as(f64, @floatFromInt(total));
    try out.print("  bytes/req       {d:.1}\n", .{per_req});
    try out.print("  peak RSS        {d:.1} MB (process)\n", .{peakRssMb()});
}
```

(Adapt `runLoad`'s exact signature/return to what exists in the file — it fills the latency buffer and returns req/sec; the return is ignored here. Match the `bind`/`acceptLoop`/shutdown idiom used by `endToEnd`.)

- [ ] **Step 2: Add `peakRssMb`** — a small helper using `std.posix.getrusage`:

```zig
fn peakRssMb() f64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: f64 = @floatFromInt(ru.maxrss);
    // darwin reports bytes; linux reports KiB.
    const bytes = if (@import("builtin").os.tag == .macos or @import("builtin").os.tag == .ios)
        maxrss
    else
        maxrss * 1024.0;
    return bytes / (1024.0 * 1024.0);
}
```

(Confirm `std.posix.getrusage` / `rusage.SELF` / the `maxrss` field name for Zig 0.16; adapt if the API differs. If `getrusage` is unavailable on the target, fall back to printing `n/a` rather than failing the build.)

- [ ] **Step 3: Call it from `main`** — after `try endToEnd(io, gpa, out, cfg);` add `try out.writeAll("\n"); try memoryMetrics(io, gpa, out, cfg);`.

- [ ] **Step 4: Verify it runs**

Run: `zig build bench -- --samples 1 --conns 2 --reqs 500 --warmup 1 2>&1 | tail -8`
Expected: a `-- memory --` section with a small `bytes/req` and a plausible `peak RSS  X.X MB`.

Run: `zig build bench 2>&1 | tail -6`
Expected: default run prints the memory section.

- [ ] **Step 5: Confirm tests still green**

Run: `zig build test --summary all 2>&1 | grep -E "tests passed|error"`
Expected: all pass (132 + counting tests).

- [ ] **Step 6: Commit**

```bash
git add src/bench.zig
git commit -m "feat(bench): memory section reporting bytes/req and peak RSS"
```

---

## Task 3: Documentation

**Files:** Modify `README.md`, `docs/getting-started.md`

- [ ] **Step 1: README** — in the benchmarking/performance area, note that `zig build bench` now also reports a memory section: `bytes/req` (cumulative allocator bytes per request, including amortized per-connection buffers) and process `peak RSS`. Keep the self-relative caveat.

- [ ] **Step 2: getting-started** — extend the `zig build bench` note to mention the memory metrics briefly.

- [ ] **Step 3: Verify nothing regressed**

Run: `zig build test --summary all 2>&1 | grep "tests passed"`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/getting-started.md
git commit -m "docs: document bench memory metrics"
```

---

## Final verification

- [ ] Tests 3×: `for i in 1 2 3; do zig build test --summary all 2>&1 | grep "tests passed"; done` — three identical pass lines (132 + counting tests).
- [ ] Bench smoke: `zig build bench -- --samples 1 --conns 2 --reqs 500` shows the `-- memory --` section with `bytes/req` and `peak RSS`.

---

## Self-review notes

- **Spec coverage:** counting allocator + tests + discovery wiring (Task 1); `memoryMetrics` section + `peakRssMb` + `main` call (Task 2); docs (Task 3). All E2 spec components covered.
- **Isolation:** counting confined to the `memoryMetrics` load; E1's throughput/latency numbers use the raw `gpa` and are unchanged.
- **Honest metric:** `bytes/req` is cumulative bytes *requested* from the app allocator over a measured load ÷ requests — allocator pressure per request, including amortized per-connection buffers (documented). Client allocations are not counted (client uses raw `gpa`).
- **Thread safety:** atomic counter (`.monotonic`); snapshots taken at load boundaries, not concurrently with allocation.
- **Portability:** `maxrss` normalized by OS (darwin bytes / linux KiB → MB); `getrusage` adapted to the Zig 0.16 API, with an `n/a` fallback if unavailable.
- **Regression safety:** bench excluded from default build; the only test-suite change is additive (counting tests via the existing bench test target). Library + existing 132 tests untouched.
