# Design — WebSocket fragmentation + control-frame semantics + message cap (sub-feature 4 of WebSocket)

**Status:** approved 2026-06-22. Branch `v0.16.0` (off main `b54ec17` = `v0.15.0`).
Target release **v0.16.0**. This is the **final** WebSocket sub-feature.

## Context

WebSocket is decomposed into ~4 sub-features (see slice-1 spec "Context"):

1. Protocol primitives — **SHIPPED** `v0.13.0` (`acceptKey`, `Opcode`, `Frame`, `parseFrame`, `writeFrame`).
2. Threaded upgrade + takeover + echo — **SHIPPED** `v0.14.0`.
3. Evented (reactor) support + handler-API unification — **SHIPPED** `v0.15.0` (the shared `pump` frame loop; `WsConn` vtable handle; `WsHandler{on_open?, on_message, on_close?}`; runs on both `app.serve` and `app.serveEvented`).
4. **Fragmentation reassembly + control-frame semantics + message size cap (THIS spec).**

Slices 1–3 deliver one **frame** at a time to `on_message` and do **not** act on control
frames: a fragmented message arrives as multiple frames, ping/pong/close are delivered raw,
and there is no message-size bound beyond `read_buffer_size`. This slice completes RFC 6455's
message layer. The shared `pump` (`src/ws.zig`) is driven by **both** backends (threaded loop
in `server.zig`, evented `WsSession` in `reactor/ws_session.zig`), so the work lands once and
both backends get it.

## Goal

`on_message` receives **whole reassembled messages**; the framework auto-responds to control
frames (auto-pong, close-reply handshake) and bounds reassembly by `ws_max_message_size`:

```zig
fn onMessage(conn: *zax.WsConn, msg: zax.WsFrame) void {
    // msg.payload = the full message (continuation frames already joined);
    // msg.opcode = .text or .binary; msg.fin = true. Pings/pongs/close handled
    // by the framework — they never reach here.
    conn.send(msg.opcode, msg.payload) catch {};
}
```

Correctness proven by `pump`/`Reassembler` unit tests and fragmentation/ping/close e2e on
**both** backends.

### Decisions (confirmed with Chris)

- **`on_message` delivers whole messages, control frames auto-handled.** Continuation frames
  are joined; `on_message` gets a complete message (`fin = true`, `opcode = text/binary`).
  Ping → auto-pong (not delivered); pong → ignored; close → close-reply handshake (not
  delivered). Behavior change from slice 3 (which exposed raw frames), but the echo handler is
  unchanged. The `on_message` signature is unchanged.
- **One size knob: `ws_max_message_size`** (`Options`, default `1 << 20` = 1 MiB) — the cap on a
  reassembled message. Exceeding it → close with code `1009` (message too big). A single frame
  is already bounded by `read_buffer_size` (a frame must fit the read buffer to parse), so no
  separate frame knob.
- **Stateful `Reassembler`.** `pump` gains a `*Reassembler` parameter holding the reassembly
  state + cap + arena. The single-frame `fin = 1` message stays **zero-copy** (payload borrows
  the read buffer); only fragmented messages use a lazily-allocated accumulator.
- **Accumulator: lazy `arena.alloc(max_message_size)` on the first fragment, reused** for the
  connection's lifetime. ~1 MiB per connection that ever receives a fragmented message
  (single-frame connections never allocate). Grow-on-demand is a possible future optimization.
- **Close codes:** `1009` for over-cap; `1002` for protocol violations.
- **One cohesive slice**, both backends, one `Options` field. Ships `v0.16.0`. WebSocket is
  feature-complete after this (cross-connection broadcast remains a separate future feature).

## Background (verified against the current code)

- **Shared pump** (`src/ws.zig:174`): `pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn,
  handler: Handler) PumpResult` — loops `parseFrame` over `buf[start..end]`, calls
  `on_message(conn, frame)` per frame, advances `start`; returns `.closed` on a close frame or
  parse error, else `.need_more` (leftover compacted to front). This is the function the slice
  reworks.
- **Frame / Opcode** (`src/ws.zig`): `Frame{ fin: bool, opcode: Opcode, payload: []const u8 }`;
  `Opcode{ continuation=0x0, text=0x1, binary=0x2, close=0x8, ping=0x9, pong=0xA, _ }`;
  `Opcode.isControl()` true for ≥ 0x8. `parseFrame` already rejects fragmented control frames
  and control frames > 125 bytes.
- **`conn.send(opcode, payload)`** (`src/ws.zig` `WsConn` vtable) — threaded: blocking
  `writeFrame`+flush; evented: non-blocking buffered with backpressure. Auto-replies (pong,
  close) use this; it works on both backends.
- **Call sites:** threaded `server.zig:740` (`ws_mod.pump(read_buf, &start, &end, &conn, up.handler)`
  in the takeover loop); evented `reactor/ws_session.zig:67` and `:80`
  (`ws.pump(self.read_buf, &self.r_start, &self.r_end, &self.conn, self.handler)`).
- **Options** (`server.zig:127`): `read_buffer_size: usize = 16 * 1024`, `max_body_size`. Add
  `ws_max_message_size`.
- **Arenas:** threaded `handleConn` has a per-connection arena (persists for the connection);
  evented `WsSession.arena = slot.arena.allocator()` (the slot arena is not reset during a live
  WS session). Both suit a connection-lifetime accumulator.
- **Evented close path:** `WsSession.onReadable` returns `.done_close` → the worker closes the
  slot. `WsSession` has `out_buf` + `drainOut` for outbound bytes (backpressure). A close-reply
  queued via `conn.send` must be best-effort drained before the socket closes.

## Components

### Modified: `src/ws.zig` — `Reassembler` + stateful `pump`

```zig
/// Per-connection reassembly state + control-frame policy. Owned by each backend
/// (one per upgraded connection). The single-frame message path never touches the
/// accumulator (zero-copy); only fragmented messages allocate `msg_buf` (lazily,
/// once, sized to `max_message_size`, reused).
pub const Reassembler = struct {
    arena: std.mem.Allocator,
    max_message_size: usize,
    msg_buf: ?[]u8 = null,
    msg_len: usize = 0,
    msg_opcode: Opcode = .text,
    fragmenting: bool = false,
};

/// Parse complete client frames from `buf[start..end]`. Joins continuation frames
/// into whole messages (delivered to `on_message` with `fin = true`); auto-responds
/// to control frames (ping → pong, close → close-reply); enforces `r.max_message_size`.
/// Returns `.closed` on a close frame, protocol error, or over-cap (after sending the
/// appropriate close frame); else `.need_more` with leftover compacted to the front.
/// Single-frame `fin = 1` messages are delivered zero-copy (payload borrows `buf`).
pub fn pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler, r: *Reassembler) PumpResult { ... }
```

**`pump` per-frame algorithm:**
1. `parseFrame` → `Incomplete` breaks (need_more); other parse error → close `1002`.
2. **Control frame** (`opcode.isControl()`):
   - `.ping` → `conn.send(.pong, frame.payload)` (best-effort; ignore send error here — the
     connection will surface a write failure on the next data send); continue.
   - `.pong` → ignore; continue.
   - `.close` → `sendClose(conn, frame.payload)` (echo the received close payload, which carries
     the peer's code), return `.closed`.
3. **Data frame:**
   - `.continuation`: if `!r.fragmenting` → protocol error, close `1002`. Else append
     `frame.payload` to `r.msg_buf` (bounds-check `r.msg_len + payload.len <= r.max_message_size`,
     else close `1009`); if `frame.fin` → deliver `Frame{ .fin = true, .opcode = r.msg_opcode,
     .payload = r.msg_buf[0..r.msg_len] }`, reset (`fragmenting = false`, `msg_len = 0`).
   - `.text`/`.binary`: if `r.fragmenting` → protocol error (new data frame mid-message), close
     `1002`. Else if `frame.fin` → deliver directly (zero-copy: `payload` borrows `buf`). Else
     begin fragmenting: lazily alloc `r.msg_buf` (`arena.alloc(max_message_size)` if null),
     `r.msg_opcode = opcode`, copy `payload` into `msg_buf`, `msg_len = payload.len`,
     `fragmenting = true` (bounds-check against the cap).
4. Loop; on exit compact leftover to front (unchanged), return `.need_more`.

Helper `sendClose(conn, payload)`: if `payload.len >= 2`, echo it (peer's close code + reason);
else send an empty close frame. Internal helper `sendCloseCode(conn, code: u16)` builds a 2-byte
big-endian close payload for the framework-initiated `1009`/`1002` cases.

`on_message` is now only ever called with complete data messages.

### Modified: `src/server.zig` — threaded takeover + Options

- Add to `Options`: `ws_max_message_size: usize = 1 << 20`.
- In the takeover branch, construct `var reasm = ws_mod.Reassembler{ .arena = arena.allocator(),
  .max_message_size = self.opts.ws_max_message_size };` and pass `&reasm` to `pump`.

### Modified: `src/reactor/ws_session.zig` — Reassembler field + close-reply flush

- Add `reasm: ws.Reassembler` to `WsSession`; initialize it in `WsSession.init` (new param
  `max_message_size`); pass `&self.reasm` to both `pump` calls.
- After `pump` returns `.closed` (which may have queued a close-reply via `conn.send`), best-effort
  `drainOut(t)` before returning `.done_close`, so the close frame reaches the wire when possible.

### Modified: `src/reactor/worker.zig` — thread the cap through

- Pass `opts.ws_max_message_size` into `WsSession.init` at the `.upgraded` hand-off.

### Unchanged

`WsConn`, `Handler`, `Upgrade`, `acceptKey`, `parseFrame`, `writeFrame`, the extractor, the
upgrade/handshake path, root exports — all unchanged. No `error.zig` change.

## Data flow

```
frame → pump(buf, start, end, conn, handler, reassembler):
  ping            → conn.send(.pong, payload)               (not delivered)
  pong            → drop
  close           → sendClose(conn, payload) → .closed
  data fin=1      → on_message(message)                     (zero-copy)
  data fin=0      → start accumulator (copy into msg_buf)
  continuation    → append; if fin → on_message(message); reset
  over max_message_size → sendCloseCode(1009) → .closed
  protocol error  → sendCloseCode(1002) → .closed
```

## Error handling

- **Reassembly over `ws_max_message_size`** → send close `1009`, return `.closed`.
- **Protocol violations** (orphan continuation; new data frame mid-fragment; a fragmented
  control frame or oversize control frame — the latter two already rejected by `parseFrame`) →
  send close `1002`, return `.closed`.
- **Frame larger than `read_buffer_size`** → `.closed` (existing de-facto bound; the read buffer
  fills with an incomplete frame).
- **Close-reply is best-effort.** Threaded: `conn.send(.close, …)` blocks-flushes then the loop
  ends. Evented: the close frame is queued and `drainOut` is attempted before `done_close`; if the
  peer is already gone, the close proceeds without a clean flush.
- **No server-initiated pings** this slice (we only respond to client pings). Periodic keepalive
  pings can be a later addition.

## Behavior change & test impact

- **Behavior change:** `on_message` now receives whole messages (`fin = true`), never control or
  continuation frames. The slice-3 echo e2e (single-frame `hi`) still passes unchanged (a
  single-frame message is delivered as-is). Existing tests that relied on raw-frame delivery of
  control frames (there are none in the suite — slice 3 only tested single data frames) are
  unaffected.
- Additive otherwise: one `Options` field, one `pump` parameter, a `Reassembler`, a `WsSession`
  field. Non-WS traffic untouched.

## Testing

Unit (`src/ws.zig`, with a fake `WsConn` sink + the `buildMaskedFrame` helper):
1. **Single-frame message** (`fin = 1`) → one `on_message` with the payload (zero-copy path,
   accumulator never allocated).
2. **Two-frame fragmented text** (`text fin=0` + `continuation fin=1`) → one `on_message` whose
   payload is the concatenation; `fin = true`, `opcode = .text`.
3. **Three-frame fragmented** message reassembles in order.
4. **Ping between fragments** → a pong frame is sent (sink records it) AND the message still
   reassembles correctly.
5. **Standalone ping** → pong sent, no `on_message`.
6. **Pong** → dropped, no `on_message`, nothing sent.
7. **Close frame** → a close frame is sent back (echoing the payload) and `pump` returns `.closed`.
8. **Over-cap reassembly** (cap set small; fragments exceed it) → a close frame with code `1009`
   is sent and `pump` returns `.closed`; no over-long `on_message`.
9. **Orphan continuation** (continuation with no message in progress) → close `1002` + `.closed`.
10. **New data frame mid-fragment** → close `1002` + `.closed`.

E2e (both backends, loopback — extend the existing threaded + evented echo e2e):
11. Send a **fragmented** message as two masked frames (`text fin=0 "Hel"`, `continuation fin=1
    "lo"`) → assert the server echoes the whole `"Hello"` as one frame.
12. Send a **ping** (masked, opcode 0x9) → assert a **pong** (0x8A) comes back.
13. Send a **close** (masked, 0x88) → assert a **close** frame comes back, then EOF.

(Reuse the zero-mask-key trick so masked payloads equal plaintext.)

`zig build test --summary all` — mac kqueue locally; Linux epoll via CI. Both backends exercised
over real loopback.

## Docs

- `README.md`: update the WebSocket section — `on_message` now receives whole messages; the
  framework auto-handles ping/pong and the close handshake; note `ws_max_message_size` (default
  1 MiB). Mark WebSocket as feature-complete for the core protocol (broadcast still future).
- `CHANGELOG.md`: `[Unreleased]` → `### Added` (fragmentation reassembly, auto ping/pong, close
  handshake, `ws_max_message_size`) and a `### Changed` note (`on_message` now delivers whole
  messages, not raw frames).
- `docs/getting-started.md`: the echo example is unchanged (still correct), but add a one-line
  note that `on_message` receives complete messages.
- Version bump `build.zig.zon` → **0.16.0**.

## Out of scope (future, not this slice)

Server-initiated keepalive pings; cross-connection broadcast (registry + thread-safe sender);
permessage-deflate compression; grow-on-demand reassembly buffer.
