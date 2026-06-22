# Design — Evented WebSocket + handler-API unification (sub-feature 3 of WebSocket)

**Status:** approved 2026-06-22. Branch `v0.15.0` (off main `1130558` = `v0.14.0`).
Target release **v0.15.0**.

## Context

WebSocket is decomposed into ~4 sub-features (see slice-1 spec "Context"):

1. Protocol primitives — **SHIPPED** `v0.13.0` (`src/ws.zig`: `acceptKey`, `Opcode`, `Frame`, `parseFrame`, `writeFrame`).
2. Threaded connection upgrade + takeover + echo/handler API — **SHIPPED** `v0.14.0` (`WebSocket` extractor, `WsConn` with a blocking `read()` loop, `handleConn` takeover).
3. **Evented-backend (reactor) support + handler-API unification (THIS spec).**
4. Fragmentation reassembly, control-frame semantics (auto ping/pong, RFC close-reply), configurable size caps, cross-connection broadcast.

The slice-2 handler API is a **blocking** read loop (`while (conn.read()) |f|`) run inside a per-connection thread. The reactor (`src/reactor/*`) is a single-thread-per-worker epoll/kqueue event loop: `conn.step()` runs synchronously inside `Worker.run`, so a blocking `read()` would **freeze every connection on that worker**. Evented WS therefore requires a non-blocking, callback-driven handler model. To keep one user-facing API, this slice **unifies both backends** on a message callback — a breaking change to the v0.14.0 blocking API, acceptable pre-1.0 (zax has no external users yet, and changing it now is cheapest).

## Goal

One WebSocket handler that runs identically on the threaded (`app.serve`) and evented (`app.serveEvented`) backends:

```zig
fn echo(conn: *zax.WsConn, frame: zax.WsFrame) void {
    conn.send(frame.opcode, frame.payload) catch {};
}

fn handler(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(.{ .on_message = echo }); // on_open / on_close optional
}
// app.get("/echo", handler);  -> works under app.serve AND app.serveEvented
```

Correctness proven by `pump`/`WsConn`/`WsSession` unit tests and a loopback echo e2e on **both** backends.

### Decisions (confirmed with Chris)

- **Unify the handler API on a message callback.** Replace slice-2's blocking
  `WsConn.read()` loop with a `WsHandler` struct the framework drives. Threaded:
  the framework runs the read loop, calling `on_message` per frame. Evented: the
  worker calls `on_message` per frame as bytes arrive. **`WsConn.read()` is removed**
  (breaking change to v0.14.0).
- **Handler hooks:** `on_message` required; `on_open(conn)` and `on_close(conn)`
  optional (nullable). `on_open` fires after the 101 (greeting/registration);
  `on_close` fires on close frame, EOF, or error (cleanup/unregister).
- **`WsConn` is a vtable handle** — one type for both backends. It carries a
  backend `ctx` + a `{send, close}` vtable, plus `state_ptr`/`arena`. `send` and
  `close` dispatch through the vtable; the threaded and evented backends supply
  different implementations. Keeps `on_message: *const fn(*WsConn, Frame) void` a
  single, portable signature.
- **Shared frame-pump.** A `pump(buf, *start, *end, conn, handler)` core does the
  parse-and-dispatch loop once; both backends feed it bytes. Single-frame
  semantics unchanged (slice 1); `on_message` receives one frame at a time;
  ping/pong delivered to `on_message`; **no auto-pong, no RFC close-reply** (slice 4).
- **Evented send backpressure:** non-blocking write; a partial write buffers the
  remainder in a per-slot outbound buffer and arms write interest; the next
  writable event drains it before resuming reads; **outbound-buffer overflow → close**
  (slow-client bound).
- **Both backends, this slice.** Reactor changes confined to `reactor/conn.zig`,
  `reactor/worker.zig`, and a new `reactor/ws_session.zig`. Ships `v0.15.0`.

## Background (verified against the reactor, file:line from exploration)

- **Worker loop** (`reactor/worker.zig:275–358`): one thread per worker, level-triggered
  `poller.wait` over all its connections; per readable/writable event it calls
  `slot.conn.step(t, dispatcher)` (`worker.zig:343`) and re-arms via `handleStepResult`
  (`worker.zig:517–567`: `.want_read`/`.want_write`/`.want_stream_repoll`/`.done_close`).
- **Conn state machine** (`reactor/conn.zig:46–67`): `State{reading_head, reading_body,
  dispatching, writing, streaming, keep_alive_idle, closing}`; `StepResult{want_read,
  want_write, want_stream_repoll, done_close}`. `Conn.step` (`conn.zig:522–851`) is a
  `while(true)` switch. Dispatch is called at `conn.zig:573`
  (`var resp = d.dispatch(&p.request, self.arena)`), then `serializeResponse` →
  `writing` → `pumpWrite`. **No `resp.upgrade` check exists in the reactor today.**
- **Shared dispatch:** the reactor uses the SAME `App.dispatch`/middleware/`callHandler`/
  extractor path as threaded (`conn.zig:573` → `server.zig` `DispatchFn.dispatch` →
  `App.dispatch`), so the `WebSocket` extractor and `resp.upgrade` already flow through.
- **Transport** (`reactor/transport.zig:33–45`): `{context, readFn, writeFn}` returning
  an `IoResult` (`.ok(n)`/`.would_block`/`.closed`); non-blocking. The raw fd lives on
  `Slot.fd` (`worker.zig:621`).
- **Slot** (`worker.zig:614–645`): pool-allocated `{read_buf, write_buf, arena, conn, fd,
  active, free_idx}`; buffers lazily allocated once and retained. No user/WS field today.
- **Timer wheel** (`reactor/timer.zig`): `insert(slot_idx, deadline_ns)` / `remove` /
  `advance(now, cb)` — reusable for WS idle timeout.
- **Tests:** reactor state machine via `FakeTransport` (`conn.zig:906+`); worker loopback
  integration (`worker.zig:974+`); `serveEvented` e2e over loopback (`server.zig:2946+`);
  threaded WS echo e2e (`server.zig:3515`).

## Components

### Modified: `src/ws.zig` — unify on the callback model

```zig
/// Lifecycle + message callbacks. `on_message` required; `on_open`/`on_close`
/// optional. All run on the connection's owning context (threaded: its thread;
/// evented: the worker — must NOT block).
pub const Handler = struct {
    on_open: ?*const fn (conn: *WsConn) void = null,
    on_message: *const fn (conn: *WsConn, frame: Frame) void,
    on_close: ?*const fn (conn: *WsConn) void = null,
};

/// Carried on a Response to signal takeover; consumed by each backend.
pub const Upgrade = struct { accept: [28]u8, handler: Handler };

pub const SendError = error{WriteFailed};

/// Backend-agnostic connection handle. One type, two backends: the vtable
/// supplies threaded (blocking writeFrame+flush) or evented (non-blocking
/// buffered) send/close.
pub const WsConn = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    state_ptr: *anyopaque,
    arena: std.mem.Allocator,

    pub const VTable = struct {
        send: *const fn (ctx: *anyopaque, opcode: Opcode, payload: []const u8) SendError!void,
        close: *const fn (ctx: *anyopaque) void,
    };
    pub fn send(self: *WsConn, opcode: Opcode, payload: []const u8) SendError!void {
        return self.vtable.send(self.ctx, opcode, payload);
    }
    pub fn close(self: *WsConn) void { self.vtable.close(self.ctx); }
    pub fn state(self: *WsConn, comptime T: type) T {
        return @as(*T, @ptrCast(@alignCast(self.state_ptr))).*;
    }
};

pub const PumpResult = enum { need_more, closed };

/// Shared frame loop. Parse complete frames from buf[start..end]; call
/// handler.on_message per data frame; advance `start`. Returns `.closed` on a
/// close-frame or any parse error; `.need_more` otherwise, with leftover bytes
/// compacted to the front (start=0, end=leftover.len). Unmask is in place.
pub fn pump(buf: []u8, start: *usize, end: *usize, conn: *WsConn, handler: Handler) PumpResult { ... }
```

`pump` algorithm: loop — if `end-start >= 2`, `parseFrame(buf[start..end])`:
`Incomplete` → break to compact + return `need_more`; other error → return `closed`;
ok → `start += consumed`; if `opcode == .close` return `closed`; else
`handler.on_message(conn, frame)`. Then compact `[start,end)` to front and return
`need_more`. (`WsConn.read` removed.)

### Modified: `src/extract/websocket.zig`

`onUpgrade(self, handler: ws.Handler) Response` — compute `acceptKey`, return
`Response.fromStatus(.switching_protocols)` with `r.upgrade = .{ .accept, .handler }`.

### Modified: `src/server.zig` — threaded takeover, framework-driven

Replace the slice-2 `up.cb(&conn)` call. Build a threaded `WsConn` whose vtable
`send` does blocking `writeFrame(w,...) + w.flush()` and whose `close` sets a flag;
then:
```
if (up.handler.on_open) |f| f(&conn);
while (true) {
    // blocking read into read_buf[end..]; end += n; (EOF/err -> break)
    if (pump(read_buf, &start, &end, &conn, up.handler) == .closed) break;
    if (conn closed flag) break;
}
if (up.handler.on_close) |f| f(&conn);
break; // -> defer stream.close
```
(Seed `start/end` with the pipelined leftover, exactly as v0.14.0 did.) Same wire
behavior as the v0.14.0 echo; only the handler shape changed.

### Added: `src/reactor/ws_session.zig` — evented WS per-connection driver

```zig
/// Drives one upgraded WebSocket connection in the reactor's non-blocking loop.
/// Owned by a Slot after upgrade. Holds the read window, the bounded outbound
/// buffer, the Handler, and the evented WsConn (whose vtable points back here).
pub const WsSession = struct {
    read_buf: []u8, r_start: usize, r_end: usize, // frame staging (seeded w/ leftover)
    out_buf: []u8, o_start: usize, o_end: usize,   // pending outbound bytes (backpressure)
    handler: Handler,
    conn: WsConn,
    closing: bool,
    // ... fd/transport supplied per call by the worker

    /// Readable event: non-blocking read -> pump -> on_message. Returns the
    /// StepResult-equivalent the worker re-arms on (want_read / want_write when
    /// the outbound buffer is non-empty / done_close on close/EOF/error).
    pub fn onReadable(self: *WsSession, t: Transport) Outcome { ... }
    /// Writable event: drain out_buf; when empty, resume reading. Returns
    /// want_read / want_write / done_close.
    pub fn onWritable(self: *WsSession, t: Transport) Outcome { ... }
};
```
Evented `send` (the `WsConn` vtable target): serialize the frame with `writeFrame`
into a small scratch, attempt `t.write`; on partial/`would_block`, append the
remainder to `out_buf` (overflow → mark `closing`, return error) and signal
want_write. `onWritable` drains `out_buf` via `t.write`; when empty, returns
want_read. `close` sets `closing`.

### Modified: `src/reactor/conn.zig`

In `step`, after dispatch (`conn.zig:573`), if `resp.upgrade != null`: serialize the
101 handshake by hand into `write_buf` (status line + `Upgrade`/`Connection`/
`Sec-WebSocket-Accept`, no content-length/connection-close), drive `writing` until
`wrote_all`, then return a **new `StepResult.upgraded`**. The leftover read bytes
(`read_buf[r_start..r_end]`) are handed to the worker to seed the `WsSession`.

### Modified: `src/reactor/worker.zig`

- `StepResult` gains `.upgraded`. `Slot` gains `ws: ?WsSession`.
- `handleStepResult` on `.upgraded`: initialize `slot.ws` (seed its read buffer with
  the conn leftover bytes, store the `Handler`, build the evented `WsConn` whose
  vtable points at the session), call `on_open`, arm read.
- `Worker.run`: for a slot with `slot.ws != null`, route readable/writable events to
  `slot.ws.?.onReadable(t)` / `onWritable(t)` instead of `conn.step`; re-arm per the
  returned outcome; on `done_close` call `on_close` then `closeSlot`.
- Idle timeout: `timer.insert(slot_idx, deadline)`; on expiry for a ws slot, close
  (call `on_close`). Reuses the existing wheel + `expiredCb` (extended to recognize
  ws slots).

### Modified: `src/root.zig`

`pub const WsHandler = ws.Handler;` (keep `WebSocket`, `WsConn`, `ws`).

## Data flow (evented)

```
GET+Upgrade → conn.step → dispatch → WebSocket.fromContext → onUpgrade(handler)
  resp.upgrade set → step serializes 101, drains write_buf → StepResult.upgraded(leftover)
  worker: init Slot.ws = WsSession(seed leftover), on_open(conn), arm read
  readable → session.onReadable: t.read -> pump -> on_message(conn, frame)
       conn.send -> writeFrame -> t.write; partial -> out_buf + want_write
  writable → session.onWritable: drain out_buf -> resume read
  close frame / EOF / error / out-buf overflow -> on_close(conn) -> closeSlot
```
(Threaded flow unchanged except the read loop is framework-driven and calls the
same `on_open`/`on_message`/`on_close`.)

## Error handling

- Non-upgrade request on a WS route → `426` (extractor reject; both backends).
- Parse error / unmasked / oversize frame (> read buffer) → `pump` returns `closed`
  → `on_close` → close.
- Evented send backpressure → buffer + drain on writable; **out_buf overflow → close**.
- No auto-pong / RFC close-reply (slice 4) — raw close after close-frame/EOF.
- A blocking call inside `on_message` stalls a reactor worker — documented constraint
  (true of any reactor handler; `worker.zig:38–41` already warns).

## Behavior change & test impact

- **Breaking:** `WsConn.read()` removed; `onUpgrade` takes a `WsHandler` (was a bare
  `fn(*WsConn) void`). The v0.14.0 threaded echo handler must be rewritten to the
  callback form (its e2e is updated in this slice).
- Additive on the reactor: new `StepResult.upgraded`, `Slot.ws` field, new
  `reactor/ws_session.zig`, a `resp.upgrade` branch in `conn.step`. Non-WS reactor
  traffic is unaffected (the new branch is gated on `resp.upgrade != null`; the new
  event routing is gated on `slot.ws != null`).
- No change to `src/error.zig` (426 mapping already shipped in slice 2).

## Testing

Unit:
1. `pump` over seeded buffers: single masked frame → `on_message` once + `need_more`;
   two pipelined frames → `on_message` twice; partial frame → `need_more` with leftover
   preserved; close frame → `closed`; protocol error (unmasked) → `closed`.
2. `WsConn` vtable: a fake sink records `send`/`close`; `state(T)` round-trips the
   app-state pointer.
3. `WsSession.onReadable`/`onWritable` with the reactor's `FakeTransport`: a frame
   arriving in two reads is reassembled and echoed; a forced partial `t.write`
   buffers the remainder and a subsequent `onWritable` drains it; out_buf overflow
   → close outcome.
4. `reactor/conn.zig`: a dispatch returning `resp.upgrade` serializes a 101 and
   returns `StepResult.upgraded` (FakeTransport).

E2e (loopback):
5. **Evented** echo via `app.serveEvented` (mirror the threaded WS e2e + the existing
   `serveEvented` e2e): handshake → assert `101` + `Sec-WebSocket-Accept:
   s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` → masked text frame (zero mask key) → assert echoed
   `0x81,0x02,'h','i'` → masked close → assert EOF.
6. **Threaded** echo e2e updated to the new `WsHandler` API (still green).

`zig build test --summary all` — mac kqueue locally; Linux epoll via CI. Both backends
exercised over real loopback.

## Docs

- `README.md`: update the WebSocket section — the echo/handler API now runs on **both**
  backends (`app.serve` and `app.serveEvented`); show the unified `WsHandler` example;
  note the v0.15.0 API change (callback handler replaces the read loop).
- `CHANGELOG.md`: `[Unreleased]` → `### Added` (evented WebSocket) and a `### Changed`
  note for the breaking handler-API unification.
- `docs/getting-started.md`: update the echo example to the callback form.
- Version bump `build.zig.zon` → **0.15.0**.

## Carry-over to slice 4 (unchanged)

Fragmentation reassembly (`on_message` over whole messages), auto ping/pong, RFC
close-reply handshake, configurable frame/message size caps (Options knob; current
de-facto cap = read buffer), `parseFrame` fuzz target, cross-connection broadcast
(needs a registry + a thread-safe sender — bigger), `WsConn.state(T)` comptime
size-match assert.
