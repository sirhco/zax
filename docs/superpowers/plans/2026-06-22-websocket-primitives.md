# WebSocket Protocol Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `src/ws.zig` — a pure RFC 6455 protocol module exporting `acceptKey` (handshake accept value), `Opcode`, `Frame`, `parseFrame` (decode + unmask one client frame in place), and `writeFrame` (serialize one server frame) — re-exported from `src/root.zig`, with no changes to `server.zig` or the reactor.

**Architecture:** A single pure module with zero I/O and zero server coupling. `acceptKey` is SHA1+base64 of the client key plus the RFC GUID. `parseFrame` decodes one frame from a caller-owned `[]u8`, unmasks the payload in place, and returns a zero-copy slice into that buffer plus the byte count consumed. `writeFrame` serializes one unmasked server frame to a `*std.Io.Writer`. Correctness is proven entirely by in-file unit tests against RFC 6455 vectors — no e2e step (no server wiring exists yet).

**Tech Stack:** Zig 0.16.0; `std.crypto.hash.Sha1`, `std.base64.standard.Encoder`, `std.mem.readInt`/`writeInt`, `std.Io.Writer` (`.fixed` in tests).

## Global Constraints

- Zig `0.16.0` (`minimum_zig_version` in `build.zig.zon`); project version is already `0.13.0` — **do not bump again**.
- This slice is **purely additive**: one new file (`src/ws.zig`) + re-exports in `src/root.zig` + docs. **Zero changes** to `server.zig`, the reactor, or `error.zig`. No existing behavior changes.
- `ParseError` is **local to `ws.zig`** — do not add it to `error.zig` or the global error model.
- **Unmask in place:** `parseFrame` XOR-unmasks the payload inside the caller's buffer; `Frame.payload` is a zero-copy slice into that buffer (the buffer is mutated).
- **Single-frame scope:** exactly one frame per `parseFrame`/`writeFrame` call. No cross-frame reassembly, no control-frame interpretation (auto-pong/close), no configurable size caps — those are later sub-features. `parseFrame` validates control-frame *structure* only.
- Server→client frames (`writeFrame`) MUST NOT be masked. Client→server frames (`parseFrame`) MUST be masked.
- All length math is bounds-checked against `buf.len` (untrusted input); use `buf.len - off < len` form (never `off + len`) to avoid `usize` overflow on a hostile 64-bit length.
- Tests live **in-file** as `test "..."` blocks (the codebase convention; `src/root.zig`'s `refAllDecls` pulls them into `zig build test`).
- RFC 6455 accept value: `base64(sha1(key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`.

---

## File Structure

- **Create `src/ws.zig`** — the entire WebSocket primitive module (`magic`, `Opcode`, `acceptKey`, `Frame`, `ParseError`, `Parsed`, `parseFrame`, `writeFrame`) plus all unit tests. One file, one responsibility: RFC 6455 framing.
- **Modify `src/root.zig`** — add `pub const ws = @import("ws.zig")` and the `WsOpcode`/`WsFrame` aliases, matching the flat-export style of the existing public surface.
- **Modify `README.md`, `CHANGELOG.md`** — short "WebSocket (in progress)" note + `[Unreleased]` Added entry.

Task ordering builds the module bottom-up so every task compiles and tests on its own: handshake + opcode first (with the root `ws` import wired), then the parser, then the writer + round-trip, then docs.

---

### Task 1: `acceptKey` + `Opcode` + root wiring

Create `src/ws.zig` with the module doc comment, `magic`, the `Opcode` enum (with `isControl`), and `acceptKey`. Wire the `ws` namespace into `src/root.zig`. Deliverable: handshake accept value computes correctly and opcode classification works.

**Files:**
- Create: `src/ws.zig`
- Modify: `src/root.zig` (add after the Middleware block, before the Server block)
- Test: in `src/ws.zig` (in-file `test` blocks)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `pub const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"`
  - `pub const Opcode = enum(u4) { continuation=0x0, text=0x1, binary=0x2, close=0x8, ping=0x9, pong=0xA, _, pub fn isControl(op: Opcode) bool }`
  - `pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8`
  - In root: `pub const ws`, `pub const WsOpcode = ws.Opcode`

- [ ] **Step 1: Write `src/ws.zig` with the module header, `magic`, `Opcode`, and `acceptKey`**

```zig
//! WebSocket protocol primitives (RFC 6455) — pure, no server integration.
//! `acceptKey` computes the handshake accept value; `parseFrame` decodes and
//! unmasks one client frame (in place); `writeFrame` serializes one unmasked
//! server frame. Connection upgrade/takeover, fragmentation reassembly, and
//! control-frame semantics are later sub-features.

const std = @import("std");

/// RFC 6455 GUID appended to the client key before hashing.
pub const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) >= 0x8;
    }
};

/// Compute `Sec-WebSocket-Accept` for a client `Sec-WebSocket-Key`. Writes the
/// 28-byte base64 value into `out` and returns the slice. No allocation.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(magic);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}
```

- [ ] **Step 2: Add the handshake + opcode tests at the bottom of `src/ws.zig`**

```zig
test "ws: acceptKey RFC 6455 vector" {
    var out: [28]u8 = undefined;
    const got = acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "ws: Opcode.isControl classifies control opcodes" {
    try std.testing.expect(!Opcode.continuation.isControl());
    try std.testing.expect(!Opcode.text.isControl());
    try std.testing.expect(!Opcode.binary.isControl());
    try std.testing.expect(Opcode.close.isControl());
    try std.testing.expect(Opcode.ping.isControl());
    try std.testing.expect(Opcode.pong.isControl());
}
```

- [ ] **Step 3: Run the new tests, expect FAIL (module not yet pulled into the build)**

Because `src/ws.zig` is not yet imported anywhere, `zig build test` will not run its tests. Verify the file compiles standalone first:

Run: `zig test src/ws.zig`
Expected: PASS (2 tests). If `zig test` is unavailable in this setup, skip to Step 4 — the root wiring is what pulls it into `zig build test`.

- [ ] **Step 4: Wire `ws` into `src/root.zig`**

Add this block immediately after the `// --- Middleware ---` section (after the `compress` lines, before `// --- Server (Phase 4) ---`):

```zig
// --- WebSocket (Phase 5) ---
pub const ws = @import("ws.zig");
pub const WsOpcode = ws.Opcode;
```

- [ ] **Step 5: Run the full test suite, expect PASS**

Run: `zig build test --summary all`
Expected: baseline green + the 2 new `ws` tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/ws.zig src/root.zig
git commit -m "feat(ws): acceptKey handshake + Opcode (RFC 6455 primitives)"
```

---

### Task 2: `parseFrame` — decode + unmask one client frame

Add `Frame`, `ParseError`, `Parsed`, and `parseFrame` to `src/ws.zig`. Deliverable: a masked client frame of any length form (7/16/64-bit) decodes, unmasks in place, and is bounds-checked; malformed/short/oversized frames return the right error.

**Files:**
- Modify: `src/ws.zig` (append types + function + tests)
- Modify: `src/root.zig` (add `WsFrame` alias)
- Test: in `src/ws.zig`

**Interfaces:**
- Consumes: `Opcode` from Task 1.
- Produces:
  - `pub const Frame = struct { fin: bool, opcode: Opcode, payload: []const u8 }`
  - `pub const ParseError = error{ Incomplete, UnmaskedClientFrame, ControlFrameTooLong, FragmentedControlFrame }`
  - `pub const Parsed = struct { frame: Frame, consumed: usize }`
  - `pub fn parseFrame(buf: []u8) ParseError!Parsed`
  - In root: `pub const WsFrame = ws.Frame`

- [ ] **Step 1: Write the first failing test (masked text frame) — append to `src/ws.zig`**

This test needs a helper that constructs a masked client frame (the inverse of `parseFrame`; `writeFrame` only produces *unmasked* server frames, so the test must build the masked input itself). Add the helper and the test together:

```zig
// Test helper: build a masked client frame into `out`, return the used slice.
fn buildMaskedFrame(out: []u8, fin: bool, opcode: Opcode, key: [4]u8, payload: []const u8) []u8 {
    out[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    var i: usize = undefined;
    if (payload.len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload.len));
        i = 2;
    } else if (payload.len <= 0xFFFF) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        i = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        i = 10;
    }
    @memcpy(out[i..][0..4], &key);
    i += 4;
    for (payload, 0..) |b, j| out[i + j] = b ^ key[j % 4];
    return out[0 .. i + payload.len];
}

test "ws: parseFrame decodes a masked text frame" {
    var buf: [64]u8 = undefined;
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const frame = buildMaskedFrame(&buf, true, .text, key, "Hello");
    const parsed = try parseFrame(frame);
    try std.testing.expect(parsed.frame.fin);
    try std.testing.expectEqual(Opcode.text, parsed.frame.opcode);
    try std.testing.expectEqualStrings("Hello", parsed.frame.payload);
    try std.testing.expectEqual(frame.len, parsed.consumed);
}
```

- [ ] **Step 2: Run it, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — `parseFrame`, `Frame`, `Parsed`, `ParseError` are not defined.

- [ ] **Step 3: Implement `Frame`, `ParseError`, `Parsed`, `parseFrame`**

Insert these (in `src/ws.zig`, after `acceptKey` and before the test block):

```zig
/// One decoded WebSocket frame. `payload` is a zero-copy (unmasked) slice into
/// the buffer passed to `parseFrame`.
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

pub const ParseError = error{
    /// `buf` does not yet contain the whole frame — read more and retry.
    Incomplete,
    /// A client→server frame was not masked (RFC 6455 violation).
    UnmaskedClientFrame,
    /// A control frame (opcode ≥ 0x8) carried > 125 bytes.
    ControlFrameTooLong,
    /// A control frame had FIN = 0.
    FragmentedControlFrame,
};

pub const Parsed = struct { frame: Frame, consumed: usize };

/// Parse ONE client frame from `buf`, unmasking the payload IN PLACE. Returns
/// the frame and total bytes consumed, or `Incomplete` if `buf` lacks the full
/// frame. (Single-frame: no cross-frame reassembly.)
pub fn parseFrame(buf: []u8) ParseError!Parsed {
    if (buf.len < 2) return error.Incomplete;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    const len7: u7 = @truncate(b1 & 0x7F);

    var off: usize = 2;
    var len: usize = len7;
    if (len7 == 126) {
        if (buf.len < off + 2) return error.Incomplete;
        len = std.mem.readInt(u16, buf[off..][0..2], .big);
        off += 2;
    } else if (len7 == 127) {
        if (buf.len < off + 8) return error.Incomplete;
        len = std.mem.readInt(u64, buf[off..][0..8], .big);
        off += 8;
    }

    if (!masked) return error.UnmaskedClientFrame;
    if (buf.len < off + 4) return error.Incomplete;
    const key = buf[off..][0..4].*;
    off += 4;

    if (opcode.isControl()) {
        if (!fin) return error.FragmentedControlFrame;
        if (len > 125) return error.ControlFrameTooLong;
    }

    // `buf.len - off` is safe: off <= buf.len after the mask-key check above.
    // Using subtraction (not `off + len`) avoids usize overflow on a hostile length.
    if (buf.len - off < len) return error.Incomplete;
    const payload = buf[off..][0..len];
    for (payload, 0..) |*byte, i| {
        byte.* ^= key[i % 4];
    }
    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = payload }, .consumed = off + len };
}
```

- [ ] **Step 4: Run the masked-text test, expect PASS**

Run: `zig build test --summary all`
Expected: PASS (the masked text test + Task 1 tests).

- [ ] **Step 5: Add the remaining parser tests (length forms, incomplete, errors, opcodes)**

Append to the test section of `src/ws.zig`:

```zig
test "ws: parseFrame 16-bit length form" {
    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 256);
    var buf: [256]u8 = undefined;
    const key = [4]u8{ 1, 2, 3, 4 };
    const frame = buildMaskedFrame(&buf, true, .binary, key, &payload);
    const parsed = try parseFrame(frame);
    try std.testing.expectEqual(@as(usize, 200), parsed.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, parsed.frame.payload);
}

test "ws: parseFrame 64-bit length header" {
    const key = [4]u8{ 9, 8, 7, 6 };
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast((i * 7) % 256);
    var buf: [512]u8 = undefined;
    buf[0] = 0x82; // FIN + binary
    buf[1] = 0x80 | 127;
    std.mem.writeInt(u64, buf[2..10], @intCast(payload.len), .big);
    @memcpy(buf[10..14], &key);
    for (payload, 0..) |b, j| buf[14 + j] = b ^ key[j % 4];
    const frame = buf[0 .. 14 + payload.len];
    const parsed = try parseFrame(frame);
    try std.testing.expectEqual(@as(usize, 300), parsed.frame.payload.len);
    try std.testing.expectEqualSlices(u8, &payload, parsed.frame.payload);
}

test "ws: parseFrame reports Incomplete at each boundary" {
    const key = [4]u8{ 0x10, 0x20, 0x30, 0x40 };
    var buf: [64]u8 = undefined;
    const frame = buildMaskedFrame(&buf, true, .text, key, "abcdef"); // 6-byte header+key, +6 payload
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..1])); // < 2 bytes
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..2])); // header only, no mask key
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..4])); // partial mask key
    try std.testing.expectError(error.Incomplete, parseFrame(frame[0..9])); // 3 of 6 payload bytes
}

test "ws: parseFrame rejects an unmasked client frame" {
    var buf = [_]u8{ 0x81, 0x03, 'a', 'b', 'c' }; // FIN+text, mask bit 0, len 3
    try std.testing.expectError(error.UnmaskedClientFrame, parseFrame(&buf));
}

test "ws: parseFrame rejects an oversized control frame" {
    const key = [4]u8{ 1, 1, 1, 1 };
    var payload: [126]u8 = undefined;
    @memset(&payload, 0x55);
    var buf: [200]u8 = undefined;
    const frame = buildMaskedFrame(&buf, true, .ping, key, &payload); // 126 bytes → len7==126 form
    try std.testing.expectError(error.ControlFrameTooLong, parseFrame(frame));
}

test "ws: parseFrame rejects a fragmented control frame" {
    const key = [4]u8{ 2, 2, 2, 2 };
    var buf: [32]u8 = undefined;
    const frame = buildMaskedFrame(&buf, false, .close, key, "x"); // FIN = 0
    try std.testing.expectError(error.FragmentedControlFrame, parseFrame(frame));
}

test "ws: parseFrame decodes control opcodes" {
    const key = [4]u8{ 3, 3, 3, 3 };
    inline for (.{ Opcode.close, Opcode.ping, Opcode.pong }) |op| {
        var buf: [32]u8 = undefined;
        const frame = buildMaskedFrame(&buf, true, op, key, "hi");
        const parsed = try parseFrame(frame);
        try std.testing.expectEqual(op, parsed.frame.opcode);
    }
}
```

- [ ] **Step 6: Run all parser tests, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — all `ws` tests green, 0 failures.

- [ ] **Step 7: Add the `WsFrame` alias to `src/root.zig`**

In the `// --- WebSocket (Phase 5) ---` block, add under the existing `WsOpcode` line:

```zig
pub const WsFrame = ws.Frame;
```

- [ ] **Step 8: Run the suite again, expect PASS**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add src/ws.zig src/root.zig
git commit -m "feat(ws): parseFrame — decode + unmask one client frame"
```

---

### Task 3: `writeFrame` — serialize one server frame + round-trip

Add `writeFrame` to `src/ws.zig`. Deliverable: a server frame serializes with the minimal length form (7/16/64-bit) and no mask bit; a build→parse→write round-trip preserves the payload.

**Files:**
- Modify: `src/ws.zig` (append function + tests)
- Test: in `src/ws.zig`

**Interfaces:**
- Consumes: `Opcode` (Task 1); `parseFrame`, `buildMaskedFrame` helper (Task 2).
- Produces: `pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void`

- [ ] **Step 1: Write the failing exact-bytes test — append to `src/ws.zig` test section**

```zig
test "ws: writeFrame small payload emits exact bytes" {
    var out: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, .text, "Hi");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'H', 'i' }, w.buffered());
}
```

- [ ] **Step 2: Run it, expect FAIL**

Run: `zig build test --summary all`
Expected: FAIL — `writeFrame` is not defined.

- [ ] **Step 3: Implement `writeFrame`**

Insert in `src/ws.zig` after `parseFrame` (before the test block):

```zig
/// Serialize ONE server frame (FIN = 1, unmasked) to `w`: header (with the
/// minimal 7/16/64-bit length form) + `payload`.
pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try w.writeByte(@intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try w.writeByte(126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(127);
        try w.writeInt(u64, @intCast(payload.len), .big);
    }
    try w.writeAll(payload);
}
```

- [ ] **Step 4: Run the exact-bytes test, expect PASS**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Add the length-form and round-trip tests**

Append to the test section:

```zig
test "ws: writeFrame 16-bit length header" {
    var payload: [200]u8 = undefined;
    @memset(&payload, 0xAB);
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, .binary, &payload);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]); // FIN + binary
    try std.testing.expectEqual(@as(u8, 126), bytes[1]); // 16-bit form
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, bytes[2..4], .big));
    try std.testing.expectEqual(@as(usize, 4 + 200), bytes.len);
}

test "ws: writeFrame 64-bit length header" {
    const big = 70_000; // > 0xFFFF → 64-bit form
    const payload = try std.testing.allocator.alloc(u8, big);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0xCD);
    const out = try std.testing.allocator.alloc(u8, big + 16);
    defer std.testing.allocator.free(out);
    var w = std.Io.Writer.fixed(out);
    try writeFrame(&w, .binary, payload);
    const bytes = w.buffered();
    try std.testing.expectEqual(@as(u8, 127), bytes[1]); // 64-bit form
    try std.testing.expectEqual(@as(u64, big), std.mem.readInt(u64, bytes[2..10], .big));
    try std.testing.expectEqual(@as(usize, 10 + big), bytes.len);
}

test "ws: build → parseFrame → writeFrame round-trips the payload" {
    const original = "round-trip payload \x00\x01\x02 with bytes";
    const key = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };
    var inbuf: [128]u8 = undefined;
    const masked = buildMaskedFrame(&inbuf, true, .binary, key, original);
    const parsed = try parseFrame(masked);
    try std.testing.expectEqualStrings(original, parsed.frame.payload);

    var out: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writeFrame(&w, parsed.frame.opcode, parsed.frame.payload);
    const server_bytes = w.buffered();
    // server frame: byte0 = 0x80|binary, byte1 = len (unmasked, < 126), then payload
    try std.testing.expectEqual(@as(u8, 0x82), server_bytes[0]);
    try std.testing.expectEqual(@as(u8, @intCast(original.len)), server_bytes[1]);
    try std.testing.expectEqualStrings(original, server_bytes[2..]);
}
```

- [ ] **Step 6: Run all tests, expect PASS**

Run: `zig build test --summary all`
Expected: PASS — full `ws` suite green, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add src/ws.zig
git commit -m "feat(ws): writeFrame — serialize one server frame + round-trip"
```

---

### Task 4: Docs — README note + CHANGELOG entry

Document the shipped primitives. Deliverable: a short "WebSocket (in progress)" README note and a `[Unreleased]` changelog entry.

**Files:**
- Modify: `README.md` (add a short subsection near the end, before `## Status & limitations` at line ~713)
- Modify: `CHANGELOG.md` (add to the existing `## [Unreleased]` → `### Added` list)

**Interfaces:**
- Consumes: the public API from Tasks 1–3 (`zax.ws.acceptKey`, `zax.ws.parseFrame`, `zax.ws.writeFrame`).
- Produces: nothing (docs only).

- [ ] **Step 1: Add the README note**

Insert this section immediately before the `## Status & limitations` heading in `README.md`:

```markdown
## WebSocket (in progress)

WebSocket support is landing across several releases. This release ships the
protocol primitives only — a pure RFC 6455 codec in `zax.ws`, with no
connection upgrade or handler API yet:

- `zax.ws.acceptKey(key, &out)` — compute the `Sec-WebSocket-Accept` handshake value.
- `zax.ws.parseFrame(buf)` — decode and unmask one client frame in place.
- `zax.ws.writeFrame(w, opcode, payload)` — serialize one unmasked server frame.

The connection upgrade (101), socket takeover, and an echo/handler API arrive in
a following release.
```

- [ ] **Step 2: Add the CHANGELOG entry**

Add this as the first bullet under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- **WebSocket protocol primitives** (`zax.ws`) — first WebSocket slice: a pure RFC 6455 codec with no server integration yet. `acceptKey` computes the `Sec-WebSocket-Accept` handshake value; `parseFrame` decodes and unmasks one masked client frame in place (zero-copy payload slice), validating control-frame structure and reporting `Incomplete` for partial buffers; `writeFrame` serializes one unmasked server frame with the minimal 7/16/64-bit length form. Connection upgrade, takeover, fragmentation reassembly, and control-frame semantics follow in later releases.
```

- [ ] **Step 3: Verify the build is still green (docs don't affect tests, but confirm nothing broke)**

Run: `zig build test --summary all`
Expected: PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(ws): note WebSocket protocol primitives (first slice)"
```

---

## Self-Review

**Spec coverage:**
- `acceptKey` + handshake RFC vector → Task 1 (Step 2 test = spec test 1). ✓
- `Opcode` + `isControl` + opcode classification → Task 1 (spec test 8 classification) and Task 2 (control opcodes parse). ✓
- `parseFrame` decode/unmask, 7/16/64-bit lengths, Incomplete boundaries, UnmaskedClientFrame, control-frame rules → Task 2 (spec tests 2–8). ✓
- In-place unmask, zero-copy slice, bounds-checked length math (overflow-safe) → Task 2 implementation + Global Constraints. ✓
- `writeFrame` exact bytes + 16/64-bit headers → Task 3 (spec test 9). ✓
- Round-trip build→parse→write → Task 3 (spec test 10). ✓
- `src/root.zig` re-exports (`ws` namespace, `WsOpcode`, `WsFrame`) → Task 1 + Task 2. ✓
- No `error.zig`/`server.zig`/reactor change; purely additive → Global Constraints; no task touches them. ✓
- Docs (README in-progress note, CHANGELOG Unreleased) → Task 4. ✓
- Version stays 0.13.0 (already bumped) → Global Constraints. ✓
- Verification: `zig build test --summary all`, no e2e → each task's final step + Global Constraints. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows complete code; every test step shows the full test. ✓

**Type consistency:** `Opcode`, `Frame`, `ParseError`, `Parsed`, `parseFrame(buf: []u8) ParseError!Parsed`, `writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8)`, `acceptKey(key, *[28]u8)`, root aliases `WsOpcode`/`WsFrame` — names and signatures match across Tasks 1–4 and the spec. The `buildMaskedFrame` test helper is introduced in Task 2 Step 1 and reused in Task 3's round-trip. ✓

**Note on the `buildMaskedFrame` test helper:** it duplicates framing logic that `writeFrame` does not (writeFrame emits *unmasked server* frames; the parser tests need *masked client* input). This is necessary test scaffolding, not production duplication — a reviewer should treat it as the fixture it is.
