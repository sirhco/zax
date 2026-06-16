# Zax — benchmark allocation/memory metrics (E2) design

Date: 2026-06-16. Status: accepted. Scope: sub-project E2 of theme E
(benchmarking, self-relative only). E1 (harness rigor) is done; E3 (coverage) and
E4 (regression baseline) remain, out of scope here.

## Context

The bench harness (`zig build bench`, post-E1) reports time: micro `median ns/op
± stddev` and an e2e loopback load with median throughput + latency percentiles.
It says nothing about **memory** — yet zax markets a "no hidden allocations"
posture. There is no number for "how many bytes does the allocator see per
request" or "what is the process's peak RSS under load". E2 adds both.

## Decision (from brainstorming)

1. **A separate `memoryMetrics` section.** It runs its own load with the app's
   allocator wrapped in a counting allocator, so the E1 throughput/latency
   numbers stay free of per-alloc counting overhead. Called from `main` after
   `endToEnd`.
2. **Thread-safe counting allocator.** A `CountingAllocator` wraps a child
   allocator and tracks cumulative bytes via an atomic counter (the server
   handles connections on multiple threads via `Io.Threaded`, so counting must be
   atomic). Lives in a new pure `src/bench/counting.zig`, unit-tested.
3. **bytes/req = measured-load delta ÷ requests.** Snapshot the counter, run one
   measured load (`cfg.conns × cfg.reqs`), snapshot again; divide the delta by
   the request count. Allocation for a static handler is deterministic, so no
   sampling is needed. The number includes amortized per-connection read/write
   buffers (small over many keep-alive requests) — documented.
4. **Peak RSS via `getrusage`.** `std.posix.getrusage(SELF).maxrss`, unit-
   normalized (darwin reports bytes, linux reports KiB) to MB, reported as the
   whole-process high-water mark.
5. **Client allocations are not counted.** Only the app's allocator is wrapped;
   the loopback client connects with the raw `gpa`, and the per-load latency
   buffer is allocated from the raw `gpa` too.

## Architecture

```
main -> microBenchmarks (E1) -> endToEnd (E1, raw gpa) -> memoryMetrics (E2)
                                                              |
   var counting = CountingAllocator{ .child = gpa }
   app = Api.init(counting.allocator(), ...)          // server allocs counted
   warmup load(s) (raw-gpa client)
   before = counting.bytesAllocated()
   measured load: cfg.conns x cfg.reqs                // runLoad, client on gpa
   after  = counting.bytesAllocated()
   report: bytes/req = (after-before)/reqs ; peak RSS = getrusage(SELF).maxrss
```

## Components

### 1. `src/bench/counting.zig` (new, pure + tested)

```zig
const std = @import("std");

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    bytes: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator { ... } // vtable -> alloc/resize/remap/free
    pub fn bytesAllocated(self: *const CountingAllocator) usize { return self.bytes.load(.monotonic); }
    pub fn reset(self: *CountingAllocator) void { self.bytes.store(0, .monotonic); }
    // vtable fns delegate to child; alloc counts `len`; resize/remap count a positive
    // size delta; free does not decrement (counter is cumulative bytes requested).
};
```

Vtable functions match the std `Allocator.VTable` shape for this Zig version
(`alloc`/`resize`/`remap`/`free`), delegating to `self.child` and updating the
atomic counter with `.fetchAdd(.monotonic)`.

### 2. `src/bench.zig` — `memoryMetrics(io, gpa, out, cfg)`

- Wrap `gpa` in a `CountingAllocator`; `Api.init` with the wrapped allocator.
- Bind + spawn the accept loop (same pattern as `endToEnd`).
- Run `cfg.warmup` discarded loads (client on raw `gpa`).
- Snapshot counter, run one measured load (`runLoad`, `cfg.conns × cfg.reqs`,
  latency buffer from raw `gpa`), snapshot counter.
- `bytes_per_req = (after - before) / (cfg.conns * cfg.reqs)`.
- Peak RSS: `std.posix.getrusage(...).maxrss`, normalized to MB by OS.
- Print a `-- memory (loopback) --` section: `bytes/req` and `peak RSS (process)`.
- Called from `main` after `endToEnd`.

## Testing

- **Unit (`zig build test`, via the bench test target):** `CountingAllocator`
  wrapping `std.testing.allocator` — `alloc` of N bytes increments
  `bytesAllocated()` by N; multiple allocs accumulate; `free` does NOT decrement
  (cumulative); a grow `resize`/`remap` counts the positive delta; `reset` zeroes.
  Add `_ = @import("bench/counting.zig");` to the existing `test {}` discovery
  block in `bench.zig`.
- **Manual (`zig build bench`):** the `-- memory --` section prints a small,
  stable `bytes/req` (a static handler should be near-zero per request beyond
  amortized buffers) and a plausible `peak RSS` in MB; honored by `--conns`/
  `--reqs`. Self-relative only.
- **Regression:** full `zig build test` stays green (132 + new counting tests).

## Files

- Add: `src/bench/counting.zig`.
- Modify: `src/bench.zig` (`memoryMetrics` section + `main` call; import counting;
  add it to the test discovery block).
- Modify: `README.md`, `docs/getting-started.md` (bench now reports memory).

## Risks & edge cases

- **Counter semantics:** cumulative bytes *requested* (not live/peak heap). This
  is the meaningful "allocator pressure per request" number; documented as such.
- **Amortized connection buffers:** each measured load opens fresh connections,
  so the per-connection read/write buffers are in the delta. Over `conns × reqs`
  keep-alive requests this is a few bytes/req; documented, not specially excluded.
- **`maxrss` units:** darwin = bytes, linux = KiB. Normalize by
  `builtin.os.tag`. Other OSes: best-effort, labeled approximate.
- **Thread safety:** the atomic counter uses `.monotonic`; exact total is
  guaranteed, ordering relative to other work is irrelevant (we snapshot at
  load boundaries, not concurrently with allocation).
- **Counting overhead:** confined to the `memoryMetrics` load; E1's throughput
  numbers use the raw `gpa` and are unaffected.

## Out of scope

Per-scenario memory once multiple scenarios exist (E3 adds scenarios; each can
reuse `memoryMetrics`), live/peak heap tracking beyond cumulative bytes,
regression baselines (E4), cross-framework comparison (whole theme E).
