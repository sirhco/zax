# Design — lazy evented slot buffers (cut idle RSS)

**Status:** approved 2026-06-19. Branch `feat/evented-lazy-slots` (off main `38300af`).

## Problem

The cross-framework memory benchmark (added 2026-06-19) surfaced that the **evented**
backend uses ~478 MB resident at rest — heaviest of all five servers — while the
**threaded** backend (and httpz/axum) sit at single-digit MB. Cause confirmed in
`src/reactor/worker.zig`: each worker preallocates its full connection pool at
`Worker.init` — `max_connections` (default 1024) `Slot`s, each `Slot.init`
(`worker.zig:614`) eagerly allocating `read_buf` (16 KB) + `write_buf` (8 KB). Across
`workers × 1024` slots that is ~`workers × 24 KB × 1024` ≈ 478 MB committed up front,
independent of load (idle ≈ peak).

The per-slot `std.heap.ArenaAllocator` is **already lazy** (it allocates nothing until
its first `alloc`), so the two fixed buffers are the entire eager footprint.

## Goal

Allocate each slot's `read_buf`/`write_buf` lazily — on the first accept into that slot —
and retain them across reuse, so the evented backend's idle RSS drops from ~478 MB to a
few MB while the steady-state hot path stays allocation-free.

Non-goals: changing the threaded backend; changing `max_connections` defaults (it stays
the capacity cap); shrinking buffers back on close (we retain — high-water-mark); any new
public option.

### Decisions (confirmed with Chris)
- **Lazy + retain (high-water-mark).** Allocate on first accept into a slot; KEEP buffers
  on close (the existing free-list already retains the slot). Steady state stays
  alloc-free; footprint = peak concurrent connections ever seen, and does not shrink back.
- **Default-on, no knob.** Strictly better; same `max_connections` cap, hot path unchanged
  after warmup. No `EventedOptions` surface added.

## Key facts (current code)

- `Slot` (`worker.zig:605-630`): `read_buf: []u8`, `write_buf: []u8`,
  `arena: std.heap.ArenaAllocator`, `conn`, `fd`, `active`, `free_idx`.
- `Slot.init(gpa, read_buf_size, write_buf_size) !Slot` (`:614`): allocs `rb`, `wb`,
  `ArenaAllocator.init(gpa)`.
- Pool init (`:143-152`): `slots = gpa.alloc(Slot, max_connections)`; loop
  `s.* = try Slot.init(...)`; build the free-list.
- Accept (`:470-485`): pop `slot_idx` from free-list; `slot.conn = Conn.init(slot.read_buf,
  slot.write_buf, &slot.arena)` (Conn stores slice references, does not own/copy); poller
  add (on failure → `closeFd` + `freeSlot` + continue).
- `freeSlot` (`:575-581`): `active=false`, `fd=-1`, `arena.reset(.retain_capacity)`, push
  `slot_idx` back to free-list. **Buffers already retained** (never freed on close).
- `Slot.deinit` (`:625-629`): frees `read_buf`, `write_buf`, `arena.deinit()`.
- `Worker` holds `self.gpa` (used by `deinit` at `:255-256`).
- `Conn.init` (`conn.zig:220-226`) only stores the slices/arena pointer; it never resizes
  or reallocates them.

## Components

### Modified: `src/reactor/worker.zig` — `Slot`

```zig
const Slot = struct {
    read_buf: []u8 = &.{},   // lazily allocated on first accept; retained across reuse
    write_buf: []u8 = &.{},
    read_size: usize,        // target buffer sizes, captured at init
    write_size: usize,
    arena: std.heap.ArenaAllocator,
    conn: Conn = undefined,
    fd: i32 = -1,
    active: bool = false,
    free_idx: usize = 0,

    // No allocation here — only records sizes + inits the (lazy) arena.
    fn init(gpa: std.mem.Allocator, read_buf_size: usize, write_buf_size: usize) Slot {
        return .{
            .read_size = read_buf_size,
            .write_size = write_buf_size,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    // Allocate the buffers on first use; idempotent (retained across slot reuse).
    fn ensureBuffers(self: *Slot, gpa: std.mem.Allocator) !void {
        if (self.read_buf.len == 0) self.read_buf = try gpa.alloc(u8, self.read_size);
        if (self.write_buf.len == 0) self.write_buf = try gpa.alloc(u8, self.write_size);
    }

    fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
        if (self.read_buf.len != 0) gpa.free(self.read_buf);
        if (self.write_buf.len != 0) gpa.free(self.write_buf);
        self.arena.deinit();
    }
};
```

`Slot.init` is now infallible (returns `Slot`, not `!Slot`) — no allocation can fail.
Partial `ensureBuffers` (read succeeds, write fails) is safe: `read_buf` is retained
(len>0), so a later call only allocates `write_buf`; nothing leaks.

### Modified: `src/reactor/worker.zig` — pool init (`:143-152`)

Drop the `try` on the now-infallible `Slot.init`:
```zig
for (slots, 0..) |*s, i| {
    s.* = Slot.init(gpa, opts.read_buffer_size, opts.write_buffer_size);
    s.free_idx = i;
}
```
(The `slots = try gpa.alloc(Slot, …)` and free-list allocation are unchanged — the Slot
array itself is small: ~`max_connections × sizeof(Slot)`, negligible.)

### Modified: `src/reactor/worker.zig` — accept (`:474-475`)

Ensure buffers before handing them to `Conn.init`; shed the connection on alloc failure:
```zig
slot.ensureBuffers(self.gpa) catch {
    closeFd(conn_fd);
    self.freeSlot(slot_idx);   // return the popped slot to the free-list
    continue;
};
slot.conn = Conn.init(slot.read_buf, slot.write_buf, &slot.arena);
```
`freeSlot` is safe here (the slot was popped but not yet activated: `active` already false,
`fd` already -1; `arena.reset` is harmless).

## Data flow (accept, lazy)

```
accept → pop slot from free-list
  → ensureBuffers(gpa)            // allocs read/write buf ONLY if this slot never had them
       └ alloc fails → closeFd + freeSlot + continue (shed)
  → Conn.init(read_buf, write_buf, &arena)  → serve
close → freeSlot: arena.reset(retain) + push to free-list  // buffers RETAINED
reuse → ensureBuffers no-ops (len>0) → no allocation
```

## Error handling

- `ensureBuffers` OOM on accept → shed the connection (close fd, return slot), mirroring
  the existing `free_len == 0` and poller-add-failure shed paths. The server stays up.
- `Slot.deinit` guards `gpa.free` so never-touched slots (empty slices) are not freed.

## Behavior change & test impact

- Idle RSS: ~478 MB → a few MB (only the Slot array + lazy arenas). Footprint now grows
  with actual concurrent connections (peak = high-water-mark), retained thereafter.
- Hot path: one extra `len == 0` check per accept; an allocation only the first time a slot
  is used (then retained) — steady state unchanged.
- No API/option change. `max_connections` still caps concurrency.
- Existing reactor integration tests (accept → serve → close, on mac kqueue) must still
  pass unchanged — buffers are simply allocated on first use rather than upfront.

## Testing

Unit (`src/reactor/worker.zig` test block; mirror the existing Worker/fake-transport tests):
1. **Lazy at init:** after `Worker.init`, every slot has `read_buf.len == 0` and
   `write_buf.len == 0` (no buffers committed) — proves the idle footprint is gone.
2. **Allocated on accept:** after driving one connection through the accept path (or calling
   `ensureBuffers` directly on a slot), that slot's `read_buf.len == read_buffer_size` and
   `write_buf.len == write_buffer_size`.
3. **Retained + idempotent on reuse:** after `freeSlot` and a second `ensureBuffers`, the
   buffer pointers are unchanged (no realloc) and lengths still correct.
4. Existing reactor integration tests (serve a request end-to-end via fake transport) still
   pass — confirms Conn still receives valid buffers.

## Verification

- `zig build test --summary all` — baseline 255/258 mac (3 Linux-epoll skips); after this
  feature, baseline + new unit tests, 0 failures, on mac (kqueue) and Linux (epoll/Docker).
- Real bench (Chris): `cd benchmarks/cross && BACKEND=both ./run.sh` → the MEMORY table's
  `zax-ev` idle drops from ~478 MB to a few MB; peak scales with the 64-conn load (≈
  workers × concurrent-slots × 24 KB), not the full pool. Refresh `results.md`.

## Docs

- `docs/evented-backend.md`: note slot buffers are allocated lazily on first use and
  retained (high-water-mark); idle footprint is small, growing with concurrent connections;
  `max_connections` is the cap, not an upfront commitment.
- `benchmarks/cross/results.md`: the ~478 MB figure is pre-fix — to be refreshed by a
  re-run; add a one-line note pointing at this change. No CHANGELOG entry unless a release
  bundles it (internal perf improvement to an opt-in backend — include in the next
  release's notes).
