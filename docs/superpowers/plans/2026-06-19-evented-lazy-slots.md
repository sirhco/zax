# Lazy evented slot buffers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allocate evented-reactor per-connection buffers lazily on first accept (retained thereafter) instead of preallocating the full pool, cutting idle RSS from ~478 MB to a few MB.

**Architecture:** `Slot` records its target buffer sizes and starts with empty `read_buf`/`write_buf`; `Slot.init` allocates nothing (the arena is already lazy). A new `Slot.ensureBuffers(gpa)` allocates the two buffers on the first accept into that slot; `freeSlot` already retains them, so steady state stays allocation-free. All changes are in `src/reactor/worker.zig`.

**Tech Stack:** Zig 0.16, zax evented reactor (epoll/kqueue), fake-transport unit tests.

## Global Constraints

- Zig 0.16. Evented backend only (`src/reactor/worker.zig`) — do NOT touch the threaded backend or `conn.zig` logic.
- Lazy + RETAIN (high-water-mark): allocate buffers on first accept into a slot; keep them on close (free-list reuse). Steady state allocation-free.
- Default-on, no new `EventedOptions`. `max_connections` (default 1024) stays the cap, not an upfront commitment.
- `Slot.init` becomes infallible (no allocation); the pool-init loop drops its `try`.
- On `ensureBuffers` OOM at accept, shed the connection (close fd + `freeSlot` + continue) — never crash.
- `Slot.deinit` must guard `gpa.free` (never free an empty/never-allocated slice).
- `Conn.init` is unchanged — it stores the slices/arena pointer by reference; it must receive valid buffers, hence `ensureBuffers` runs BEFORE `Conn.init`.
- Test baseline: **255/258 mac** (3 Linux-epoll skips). Run `zig build test --summary all`.

---

### Task 1: Lazy slot buffers in worker.zig

**Files:**
- Modify: `src/reactor/worker.zig` — `Slot` struct (~:605-630), pool-init loop (~:143-152), accept path (~:474-475)
- Test: `src/reactor/worker.zig` (test block — mirror existing Worker/fake-transport tests)

**Interfaces:**
- Produces: `Slot` with `read_size`/`write_size` fields + lazy `read_buf`/`write_buf` (default `&.{}`); `Slot.init(gpa, read_buf_size, write_buf_size) Slot` (infallible); `Slot.ensureBuffers(self: *Slot, gpa) !void`.

- [ ] **Step 1: Write failing unit tests**

In the `src/reactor/worker.zig` test block, mirror the existing Worker construction tests (search the test block for `Worker.init` / a fake-transport accept test). Add:

```zig
test "evented slot buffers are lazy: none allocated at Worker.init" {
    // Build a Worker with a fake dispatcher/poller exactly as the existing
    // Worker tests do (reuse that harness). Then:
    for (w.slots) |s| {
        try std.testing.expectEqual(@as(usize, 0), s.read_buf.len);
        try std.testing.expectEqual(@as(usize, 0), s.write_buf.len);
    }
}

test "evented slot ensureBuffers allocates once and is idempotent" {
    // With a slot from a Worker (or a standalone Slot.init):
    var slot = Slot.init(std.testing.allocator, 16 * 1024, 8 * 1024);
    defer slot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), slot.read_buf.len);
    try slot.ensureBuffers(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16 * 1024), slot.read_buf.len);
    try std.testing.expectEqual(@as(usize, 8 * 1024), slot.write_buf.len);
    const rptr = slot.read_buf.ptr;
    const wptr = slot.write_buf.ptr;
    try slot.ensureBuffers(std.testing.allocator); // idempotent — no realloc
    try std.testing.expectEqual(rptr, slot.read_buf.ptr);
    try std.testing.expectEqual(wptr, slot.write_buf.ptr);
}
```

(Adjust the Worker-construction test to the exact existing harness — if the test block builds a Worker via a helper, reuse it; the standalone `Slot.init` test needs no harness.)

- [ ] **Step 2: Run — verify fail**

Run: `zig build test --summary all`
Expected: FAIL — `read_size`/`ensureBuffers` not defined, or buffers non-empty at init.

- [ ] **Step 3: Rewrite the `Slot` struct**

Replace the `Slot` struct (`src/reactor/worker.zig:605-630`) with:

```zig
/// Owns the memory for one connection: buffers, arena, and the Conn state machine.
/// Buffers are allocated lazily on first accept (`ensureBuffers`) and retained across
/// reuse, so idle workers commit no per-connection buffer memory.
const Slot = struct {
    read_buf: []u8 = &.{},
    write_buf: []u8 = &.{},
    read_size: usize,
    write_size: usize,
    arena: std.heap.ArenaAllocator,
    conn: Conn = undefined, // valid only when active
    fd: i32 = -1,
    active: bool = false,
    free_idx: usize = 0, // index back into Worker.slots (set at alloc time)

    // No allocation here — record sizes + init the (lazy) arena. Infallible.
    fn init(gpa: std.mem.Allocator, read_buf_size: usize, write_buf_size: usize) Slot {
        return .{
            .read_size = read_buf_size,
            .write_size = write_buf_size,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    // Allocate the read/write buffers on first use; idempotent (retained across reuse).
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

- [ ] **Step 4: Drop `try` in the pool-init loop**

In `src/reactor/worker.zig` (~:145-147), change the slot construction (now infallible):

```zig
    for (slots, 0..) |*s, i| {
        s.* = Slot.init(gpa, opts.read_buffer_size, opts.write_buffer_size);
        s.free_idx = i;
    }
```

- [ ] **Step 5: ensureBuffers before Conn.init in the accept path**

In the accept path (`src/reactor/worker.zig`, immediately before the `slot.conn = Conn.init(...)` line ~:475), insert:

```zig
            // Allocate this slot's buffers on first use; shed the connection on OOM.
            slot.ensureBuffers(self.gpa) catch {
                closeFd(conn_fd);
                self.freeSlot(slot_idx);
                continue;
            };
            slot.conn = Conn.init(slot.read_buf, slot.write_buf, &slot.arena);
```

(Confirm the worker field for the backing allocator is `self.gpa` — it is used by `deinit` at ~:255-256. If it is named differently, match that name.)

- [ ] **Step 6: Run — verify pass**

Run: `zig build test --summary all`
Expected: PASS — the two new lazy-buffer tests green; all existing reactor integration tests (accept→serve→close on mac kqueue) still pass; baseline 255 + new tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add src/reactor/worker.zig
git commit -m "feat(reactor): lazy + retained slot buffers (cut evented idle RSS)"
```

---

### Task 2: Docs — evented-backend.md, results.md note, CHANGELOG

**Files:**
- Modify: `docs/evented-backend.md`
- Modify: `benchmarks/cross/results.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: evented-backend.md note**

In `docs/evented-backend.md`, in the section describing workers / connection pool /
`max_connections`, add a short note:

> **Lazy connection buffers.** Each worker's per-connection read/write buffers are
> allocated on the first accept into a slot and retained for reuse, so an idle worker
> commits almost no per-connection memory. The footprint grows with the peak number of
> concurrent connections (high-water-mark) rather than `max_connections × buffer size`.
> `max_connections` is the cap, not an upfront commitment.

- [ ] **Step 2: results.md note**

In `benchmarks/cross/results.md`, under the Memory (RSS) section, add one line noting the
~478 MB `zax-ev` figure predates the lazy-buffer change and should be refreshed by a re-run:

```markdown
> Note: the `zax-ev` ~478 MB above predates the lazy-slot-buffer change
> (`docs/superpowers/specs/2026-06-19-evented-lazy-slots-design.md`); re-run to refresh —
> evented idle RSS is now small and grows with concurrent connections.
```

Do NOT edit the existing numbers (they are a historical record of that run).

- [ ] **Step 3: CHANGELOG entry**

Under `## [Unreleased]` in `CHANGELOG.md` (create the section + a `### Changed` subsection
if absent, matching the changelog's convention; v0.7.0 is the latest released):

```markdown
- Evented reactor: per-connection buffers are now allocated lazily on first use and retained, instead of preallocated for the whole pool — idle RSS drops dramatically (footprint tracks peak concurrent connections; `max_connections` stays the cap).
```

- [ ] **Step 4: Verify + commit**

Run: `zig build test --summary all` (expect green, no count change from docs)

```bash
git add docs/evented-backend.md benchmarks/cross/results.md CHANGELOG.md
git commit -m "docs(reactor): document lazy evented slot buffers"
```

---

## Final verification

- `zig build test --summary all` → 0 failures; baseline 255 + the two lazy-buffer unit tests; existing reactor integration tests still pass.
- Spec coverage: T1 = Slot lazy fields + ensureBuffers + pool-loop + accept wiring + deinit guard + 2 unit tests; T2 = evented-backend.md + results.md note + CHANGELOG. All spec sections covered.
- Regression: existing reactor accept→serve→close tests pass (buffers now lazy, Conn unchanged).
- Real bench (Chris): `cd benchmarks/cross && BACKEND=both ./run.sh` → `zax-ev` idle RSS now a few MB; refresh results.md.
