# Design — WebSocket protocol primitives (sub-feature 1 of WebSocket)

**Status:** approved 2026-06-22. Branch `v0.13.0` (off main `34f6def`).

## Context

zax has no WebSocket support — only the `switching_protocols` (101) / `upgrade_required`
(426) status enum values exist. WebSocket is the largest remaining capability gap.
It is too big for one spec, so it is **decomposed** (each sub-feature its own
spec→plan→build):

1. **Protocol primitives (THIS spec):** a pure `src/ws.zig` — handshake
   accept-key + single-frame codec. No server integration, no connection hijack.
2. Threaded connection upgrade + takeover + an echo/handler API.
3. Evented-backend (reactor) support.
4. Fragmentation reassembly, control-frame semantics (auto ping/pong, close
   handshake), frame/message size caps.

This first slice is the protocol foundation: pure, exhaustively unit-testable
against RFC 6455 vectors, with **zero changes to `server.zig`** or the reactor.

## Goal

`src/ws.zig` exporting: `acceptKey` (compute `Sec-WebSocket-Accept`), `Opcode`,
`Frame`, `parseFrame` (decode + unmask a client frame), and `writeFrame`
(serialize a server frame). Re-exported from `src/root.zig`. Correctness proven
by unit tests including the RFC 6455 handshake vector.

Non-goals (deferred to later sub-features): detecting the upgrade request /
sending the 101 (that's the server-integration slice); connection hijack;
fragmentation/continuation reassembly across frames; acting on control frames
(auto-pong, close handshake); configurable max frame/message size; any handler
API. `parseFrame` validates control-frame *structure* but does not interpret it.

### Decisions (confirmed with Chris)
- **Unmask in place** — `parseFrame` XOR-unmasks the payload inside the caller's
  buffer and returns a zero-copy slice into it (the buffer is mutated).
- **`writeFrame` targets `*std.Io.Writer`** — composes with the connection writer
  in the later takeover slice; tests drive it with `std.Io.Writer.fixed`.
- **Single-frame scope** — one frame per `parseFrame`/`writeFrame` call; no
  cross-frame reassembly.
- Version bump to **0.13.0** (WebSocket ships across several minor versions).

## Background (verified against installed Zig 0.16)

- `std.crypto.hash.Sha1`: `Sha1.init(.{})`, `.update(bytes)`, `.final(&out)`
  where `out: *[20]u8` (`digest_length = 20`).
- `std.base64.standard.Encoder.encode(dest: []u8, source: []const u8) []const u8`
  — asserts `dest.len >= calcSize(source.len)`; for 20 bytes that is 28.
- `std.Io.Writer` with `.fixed(buf)` for tests; `writeFrame` uses the standard
  writer write methods (`writeAll`, `writeByte`/`writeInt`).

RFC 6455: the server's accept value is
`base64(sha1(Sec-WebSocket-Key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`.
Client→server frames MUST be masked (4-byte key XORed over the payload,
`payload[i] ^ key[i % 4]`); server→client frames MUST NOT be masked. Frame
header: byte0 = `FIN(1) | RSV(3) | opcode(4)`; byte1 = `MASK(1) | len7(7)`;
`len7 == 126` → next `u16` big-endian length; `len7 == 127` → next `u64`
big-endian length; then (if masked) the 4-byte mask key; then the payload.
Control frames (opcodes ≥ 0x8) MUST have `FIN = 1` and payload ≤ 125.

## Components

### Added: `src/ws.zig`

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
pub fn parseFrame(buf: []u8) ParseError!Parsed { ... }

/// Serialize ONE server frame (FIN = 1, unmasked) to `w`: header (with the
/// minimal 7/16/64-bit length form) + `payload`.
pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void { ... }
```

**`parseFrame` algorithm:**
1. Need ≥ 2 bytes else `Incomplete`. Read `fin`, `opcode`, `masked`, `len7`.
2. Resolve payload length: `len7 < 126` → `len7`; `126` → next `u16` BE (need 2
   more bytes); `127` → next `u64` BE (need 8 more bytes). `Incomplete` if short.
3. Require `masked` (client frames) else `UnmaskedClientFrame`; read the 4-byte
   mask key (need 4 bytes).
4. Control-frame checks: if `opcode.isControl()` then `fin` must be true
   (`FragmentedControlFrame`) and `len <= 125` (`ControlFrameTooLong`).
5. Need `len` payload bytes available else `Incomplete`. Unmask in place:
   `payload[i] ^= key[i % 4]`. Return `.{ .frame = .{ fin, opcode, payload },
   .consumed = header_len + len }`.

All length math bounds-checked against `buf.len` (untrusted input; a fuzz target
is a reasonable later follow-up). `len` is `usize`; on 64-bit platforms a `u64`
length is representable, but the caller (later slice) enforces a max — this pure
parser only needs `buf` to actually contain the bytes.

**`writeFrame` algorithm:** byte0 = `0x80 | @intFromEnum(opcode)`. If
`payload.len < 126`: byte1 = `len`. Else if `<= 0xFFFF`: byte1 = `126` + `u16`
BE. Else: byte1 = `127` + `u64` BE. No mask bit / key. Then `payload`.

### Modified: `src/root.zig`

```zig
pub const ws = @import("ws.zig");
pub const WsOpcode = ws.Opcode;
pub const WsFrame = ws.Frame;
```
(Expose the `ws` namespace; `acceptKey`/`parseFrame`/`writeFrame` are reached as
`zax.ws.*`. The `WsOpcode`/`WsFrame` aliases match the flat-export style of other
types — adjust to whatever the existing root convention prefers.)

### No `error.zig` / `server.zig` change

This slice is pure. `ParseError` is local to `ws.zig`; the server-integration
slice will decide how parse errors map to a close.

## Data flow (within this slice)

```
handshake:  client key ──acceptKey──▶ 28-byte accept value (for a future 101)
inbound:    masked client bytes ──parseFrame(buf)──▶ Frame{fin,opcode,payload (unmasked, borrows buf)} + consumed
outbound:   (opcode,payload) ──writeFrame(w)──▶ unmasked server frame bytes
```
The wiring (read bytes off the socket, loop `parseFrame`, dispatch, `writeFrame`
back) belongs to the later takeover slice.

## Error handling

- Short buffer → `Incomplete` (caller reads more). Unmasked client frame →
  `UnmaskedClientFrame`. Oversized/fragmented control frame →
  `ControlFrameTooLong` / `FragmentedControlFrame`. All slicing bounds-checked.
- `writeFrame` only propagates the `*std.Io.Writer` write error.

## Behavior change & test impact

Purely additive: one new file + root re-exports. No existing behavior changes; no
server/reactor code touched; existing tests unaffected.

## Testing

Unit (`src/ws.zig`):
1. **Handshake RFC vector:** `acceptKey("dGhlIHNhbXBsZSBub25jZQ==")` ==
   `"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="`.
2. **parseFrame masked text:** a hand-built masked text frame → `opcode == .text`,
   `fin == true`, unmasked `payload` equals expected, `consumed` correct.
3. **16-bit length:** a 200-byte masked payload (`len7 == 126`) parses with the
   right length.
4. **64-bit length:** a `len7 == 127` frame (use a modest payload, e.g. a few
   hundred bytes encoded in the 8-byte length field) parses correctly.
5. **Incomplete:** truncated buffers at each boundary (1 byte; header-only;
   missing mask key; short payload) → `error.Incomplete`.
6. **Unmasked client frame** (MASK bit 0) → `error.UnmaskedClientFrame`.
7. **Control-frame rules:** a `ping` with 126-byte payload →
   `error.ControlFrameTooLong`; a `close` with `FIN == 0` →
   `error.FragmentedControlFrame`.
8. **Opcode classification:** `close`/`ping`/`pong` parse with the right opcode;
   `Opcode.isControl` true for ≥ 0x8.
9. **writeFrame exact bytes:** small payload → `0x81, len, payload...` (FIN+text,
   no mask bit); a 200-byte payload → `0x7e` (126) + `u16` BE header; a large
   payload → `0x7f` (127) + `u64` BE header.
10. **Round-trip:** build a masked client frame for a payload, `parseFrame` it,
    `writeFrame` the same payload+opcode (unmasked) and confirm the parsed
    payload equals the original (a small mask helper in the test constructs the
    masked input).

## Verification

- `zig build test --summary all` — baseline green + new `ws` unit tests, 0
  failures (mac kqueue + Linux epoll). Pure logic, no timing → single run.
- No manual/e2e step this slice (no server wiring yet); the echo end-to-end check
  arrives with the takeover sub-feature.

## Docs

- `README.md`: a brief "WebSocket (in progress)" note — the protocol primitives
  (`zax.ws.acceptKey`/`parseFrame`/`writeFrame`) are shipped; the connection
  upgrade/handler API is a following release. Keep it short; full docs land with
  the takeover slice.
- `CHANGELOG.md`: entry under `[Unreleased]` → `### Added` (note it's the first
  WebSocket slice — protocol primitives only).
- `docs/getting-started.md`: no change this slice (nothing user-runnable yet).
