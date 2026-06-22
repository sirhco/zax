# Design — WebSocket connection upgrade + takeover (sub-feature 2 of WebSocket)

**Status:** approved 2026-06-22. New branch off main (`545e9c6`, which is `v0.13.0`).
Target release **v0.14.0**.

## Context

Sub-feature 1 shipped `src/ws.zig` — a pure RFC 6455 codec (`acceptKey`, `Opcode`,
`Frame`, `parseFrame`, `writeFrame`) with **zero** server integration (tagged `v0.13.0`).
WebSocket is decomposed into ~4 sub-features (see the slice-1 spec "Context"):

1. Protocol primitives — **SHIPPED** (`v0.13.0`).
2. **Threaded connection upgrade + takeover + echo/handler API (THIS spec).**
3. Evented-backend (reactor) support.
4. Fragmentation reassembly, control-frame semantics (auto ping/pong, RFC close-reply
   handshake), configurable frame/message size caps.

This slice wires the slice-1 codec into the **threaded** server backend: detect a
WebSocket upgrade request, perform the handshake (send `101`), take over the socket,
and run a user-supplied message callback. It does **not** touch the reactor
(`src/reactor/*`) — that is slice 3.

## Goal

An Axum-style WebSocket endpoint:

```zig
fn echo(ws: zax.WebSocket) zax.Response {
    return ws.onUpgrade(struct {
        fn run(conn: *zax.WsConn) void {
            const db = conn.state(*Db); // app state, type-erased
            _ = db;
            while (conn.read()) |f| // f: zax.WsFrame { fin, opcode, payload }
                conn.send(f.opcode, f.payload) catch break;
        }
    }.run);
}
// app.get("/echo", echo);
```

Correctness proven by `WsConn`/extractor unit tests **and** a loopback echo e2e
(the end-to-end check deferred from slice 1).

### Decisions (confirmed with Chris)

- **API shape — extractor (Axum-style).** A `WebSocket` extractor used in a normal
  handler; `fromContext` validates the handshake headers, `onUpgrade(cb)` returns a
  `Response` carrying the callback. Reuses `Path`/`Query`/`State`/`Headers` extractors
  for routing/auth **before** the upgrade.
- **Callback state — `WsConn` accessors only.** Bare `cb: *const fn(*WsConn) void`.
  `conn.state(T)` exposes app State; `conn.arena` exposes the per-connection arena.
  No path-param capture into the callback this slice (Zig has no closures; a later
  enhancement can add it).
- **`conn.read()` returns single FRAMES**, not reassembled messages. Returns `null`
  on a close frame, EOF, or any parse/read error, so `while (conn.read()) |f|` exits
  cleanly. **No auto-pong, no RFC close-reply** — those are slice 4. On loop end the
  framework does a raw TCP close (no close frame sent).
- **Single-threaded per connection.** `conn.send()` is valid only from inside the
  callback (the thread that owns the socket). No connection registry, no cross-thread
  send, no broadcast/fan-out — those are a later slice.
- **Upgrade-signal mechanism — additive `Response.upgrade` field.** `onUpgrade` returns
  `Response{ status = .switching_protocols, upgrade = .{accept, cb} }`. `handleConn`
  checks `resp.upgrade` after `dispatch` and branches into takeover. No new dispatch
  path; middleware chain is untouched.
- **Threaded backend only.** Reactor support is slice 3.

## Background (verified against the codebase)

- **Connection lifecycle** (`src/server.zig`): `acceptLoop` (399) spawns `handleConn`
  (626–718) per connection on the `Io.Threaded` pool. `handleConn` owns the
  `net.Stream` (local frame; `defer stream.close(io)` at 629), a `ConnReader`
  (`cr`, 641; `socket`/`io`/`buf`, with `buffered()`/`consume()`/`fill(timeout)`),
  and a buffered writer `sw`/`w: *std.Io.Writer` (643). Keep-alive loop at 649–717:
  after `writeResponse` it decides persist vs `break`.
- **Dispatch** (752–794): `dispatch` → `router.match` → `Chn.run(mws, handler, &ctx)`
  → `callHandler` (`extract.zig:79`). Handler params are extractor types
  (`zax_is_extractor`); return goes through `intoResponse`.
- **Context** (`extract.zig`): `{ req, params, state: AppState, arena, io,
  trust_forwarded, request_id }`. The socket/stream is **NOT** in `Context` — a handler
  cannot reach it. Takeover must happen in `handleConn`.
- **State** (`extract/state.zig`): `ctx.state` is the app-state value (the router is
  parameterized by one concrete `AppState`, typically a pointer like `*Db`).
- **Headers** (`extract/headers.zig`): `Headers.get(name)` / `.has(name)` —
  case-insensitive. Also `ctx.req.header(name)`.
- **Status** (`http/response.zig`): `switching_protocols = 101` and
  `upgrade_required = 426` both exist.
- **101 caveat:** the generic `Response.write` path always emits `content-length: 0`
  and (for a non-keep-alive response) `connection: close` — both wrong for a `101`.
  `handleConn` therefore writes the handshake bytes by hand, bypassing `Response.write`.
- **Codec** (`src/ws.zig`): `acceptKey(key, *[28]u8) []const u8`,
  `parseFrame(buf: []u8) ParseError!Parsed` (unmasks in place; `payload` borrows `buf`),
  `writeFrame(w: *std.Io.Writer, opcode, payload) !void`.
- **E2E pattern** (`server.zig` tests ~1029+): loopback raw TCP, hardcoded port,
  `startTestApp` + `requestShutdown`; `doRequest`/`readResp` helpers.

## Components

### Modified: `src/ws.zig` — add `WsConn`, `Upgrade`, callback type

Append to the existing slice-1 module (it gains `std.net`/`std.Io` usage; it still does
**not** import `response.zig` or `server.zig`, so no import cycle):

```zig
/// The server-side callback invoked after a successful upgrade. Runs on the
/// connection's own thread and owns the socket for its lifetime.
pub const Handler = *const fn (conn: *WsConn) void;

/// Carried on a `Response` to signal "take over this connection". Built by
/// `WebSocket.onUpgrade`; consumed by the server's `handleConn`.
pub const Upgrade = struct {
    accept: [28]u8, // precomputed Sec-WebSocket-Accept (by value — no borrow)
    cb: Handler,
};

/// A live, taken-over WebSocket connection. Single-threaded: only the callback's
/// thread touches it. Does its own socket recv (decoupled from the server's
/// private ConnReader) over a caller-provided buffer.
pub const WsConn = struct {
    io: std.Io,
    socket: std.net.Stream, // or std.net.Socket — match handleConn's `stream`
    w: *std.Io.Writer,      // the connection's buffered writer
    buf: []u8,              // frame staging buffer; max frame size == buf.len
    start: usize = 0,       // unconsumed window [start, end) within buf
    end: usize = 0,
    state_ptr: *anyopaque,  // app state (type-erased; see `state`)
    arena: std.mem.Allocator,
    idle_timeout: std.Io.Timeout, // reuse Options.idle_timeout_ms

    /// Next frame, or null on close-frame / EOF / parse-or-read error. The
    /// returned `payload` borrows `buf` and is valid only until the next read().
    pub fn read(self: *WsConn) ?Frame {
        // 1. Try parseFrame over buf[start..end]; on Incomplete, compact + recv
        //    more from the socket (idle_timeout). EOF/timeout/read-error -> null.
        // 2. A frame larger than buf.len can never complete -> treat as error
        //    -> null (de-facto size cap == buf.len; configurable cap is slice 4).
        // 3. On a `.close` opcode -> null (loop ends; raw TCP close follows).
        //    No auto-pong, no close-reply (slice 4): ping/pong frames are
        //    returned to the caller like any other frame.
        // 4. Otherwise advance `start` by `consumed` and return the frame.
    }

    /// Serialize one unmasked server frame and flush.
    pub fn send(self: *WsConn, opcode: Opcode, payload: []const u8) std.Io.Writer.Error!void {
        try writeFrame(self.w, opcode, payload);
        try self.w.flush();
    }

    /// App state, type-erased. `T` MUST be the app-state pointer type the router
    /// is parameterized by (typically `*Something`).
    pub fn state(self: *WsConn, comptime T: type) T {
        return @ptrCast(@alignCast(self.state_ptr));
    }
};
```

### Added: `src/extract/websocket.zig` — the `WebSocket` extractor

```zig
pub const WebSocket = struct {
    key: []const u8, // Sec-WebSocket-Key (borrows request memory; used only in onUpgrade)
    arena: std.mem.Allocator,

    pub const zax_is_extractor = true;
    pub const zax_is_body = false;

    /// Validate the RFC 6455 handshake request. Rejects -> 426 Upgrade Required.
    pub fn fromContext(ctx: anytype) error{NotWebSocketUpgrade}!@This() {
        // Require (case-insensitive): Upgrade contains "websocket";
        // Connection contains the "upgrade" token; Sec-WebSocket-Version == "13";
        // Sec-WebSocket-Key present. Else error.NotWebSocketUpgrade.
        // Capture key + ctx.arena.
    }

    /// Build the upgrade Response: compute accept = acceptKey(key) and attach the
    /// callback. handleConn does the actual 101 + takeover.
    pub fn onUpgrade(self: @This(), cb: ws.Handler) Response {
        var accept: [28]u8 = undefined;
        _ = ws.acceptKey(self.key, &accept);
        var r = Response.fromStatus(.switching_protocols);
        r.upgrade = .{ .accept = accept, .cb = cb };
        return r;
    }
};
```

`error.NotWebSocketUpgrade` is added to `error.zig`'s classification so `classify`
maps it to `426` (mirroring how other extractor tags map to 4xx). This is the one
allowed `error.zig` touch this slice (the extractor rejection needs a status mapping;
unlike slice 1's pure codec, this slice integrates with the request pipeline).

### Modified: `src/http/response.zig` — optional `upgrade` field

```zig
const ws = @import("../ws.zig"); // one-way: response -> ws (ws never imports response)
// ... in the Response struct:
upgrade: ?ws.Upgrade = null,
```

Purely additive; existing serialization ignores it (handleConn intercepts before any
write when it is set).

### Modified: `src/server.zig` — `handleConn` takeover branch

After `const resp = self.dispatch(...)`, before the normal `writeResponse`/keep-alive
logic:

```zig
if (resp.upgrade) |up| {
    // 1. Write the 101 handshake by hand (bypass Response.write's content-length/
    //    connection:close). Exact bytes:
    //    "HTTP/1.1 101 Switching Protocols\r\n"
    //    "Upgrade: websocket\r\n"
    //    "Connection: Upgrade\r\n"
    //    "Sec-WebSocket-Accept: " ++ up.accept ++ "\r\n\r\n"
    try w.writeAll(...); try w.flush();

    // 2. Build WsConn. Seed its buffer with any bytes the client already pipelined
    //    after the handshake (cr.buffered() leftover) by copying them into ws_buf.
    var ws_buf = ...; // reuse read_buf or allocate; size == max frame
    const leftover = cr.buffered();
    @memcpy(ws_buf[0..leftover.len], leftover);
    var conn = ws.WsConn{ .io = io, .socket = stream, .w = w, .buf = ws_buf,
        .start = 0, .end = leftover.len, .state_ptr = @ptrCast(self.<state>),
        .arena = arena.allocator(), .idle_timeout = ... };

    // 3. Run the user callback (owns the socket until it returns).
    up.cb(&conn);

    // 4. Done — break the keep-alive loop; `defer stream.close(io)` closes the socket.
    break;
}
```

(Access log / observability records the request as status `101`; the takeover loop is
not separately logged this slice.)

### Modified: `src/root.zig` — exports

```zig
pub const WebSocket = @import("extract/websocket.zig").WebSocket;
pub const WsConn = ws.WsConn;
```

(`ws` namespace already exported from slice 1; `WsFrame`/`WsOpcode` already present.)

## Data flow

```
client: GET /echo + Upgrade/Connection/Sec-WebSocket-Key/Version headers
  handleConn → readHead → dispatch → middleware chain → handler
    WebSocket.fromContext: validate handshake headers, capture key + arena
    handler: return ws.onUpgrade(cb)  →  Response{101, upgrade={accept, cb}}
  handleConn: resp.upgrade set
    → write 101 handshake bytes (acceptKey already computed)
    → build WsConn (seed buf with cr leftover bytes) → cb(&conn)
        cb: while (conn.read()) |f|            // read: parseFrame, unmask in place
              conn.send(f.opcode, f.payload)   // send: writeFrame + flush
        close-frame / EOF / error → read() == null → cb returns
    → break keep-alive loop → stream.close (raw TCP)
```

## Error handling

- **Not a valid upgrade request** on a WS route → `WebSocket.fromContext` →
  `error.NotWebSocketUpgrade` → `classify` → **426 Upgrade Required** (normal response
  path; no takeover).
- **Frame parse error / unmasked client frame / oversize frame** (exceeds `buf.len`) →
  `read()` returns `null` → callback loop ends → raw TCP close. Configurable max-frame
  cap is **slice 4**; this slice's de-facto cap is the staging-buffer size.
- **`send()` write error** → returned to the callback (it `break`s).
- **No RFC close-reply frame, no auto-pong** — slice 4. A client `close` just ends the
  loop; the socket is closed at TCP level.
- **Idle/dead connection:** `read()` recv honors the existing `idle_timeout_ms`; a stalled
  peer times out → `read()` null → loop ends (thread freed).

## Behavior change & test impact

Additive: one new file (`extract/websocket.zig`), `WsConn`/`Upgrade` added to `ws.zig`,
one optional `Response` field, a `handleConn` branch, one `error.zig` classification
entry, and root exports. No existing route/handler behavior changes; non-upgrade traffic
is unaffected (the `handleConn` branch is gated on `resp.upgrade != null`). Reactor
untouched. Existing tests unaffected.

## Testing

Unit:
1. **`WebSocket.fromContext` accept/reject:** a valid upgrade Context → ok with the key;
   each of {missing Upgrade, missing Connection token, wrong/absent Version, missing Key}
   → `error.NotWebSocketUpgrade`.
2. **`classify(error.NotWebSocketUpgrade) == .upgrade_required` (426).**
3. **`onUpgrade`** sets `Response.status == .switching_protocols` and a non-null
   `upgrade` whose `accept` equals `acceptKey(key)` (reuse the RFC vector).
4. **`WsConn.read` over seeded buffers:** a masked text frame → returns the frame with
   the right opcode/payload; a `close` frame → `null`; a frame longer than `buf.len` →
   `null`; two frames back-to-back in the seed buffer → two successive reads then `null`
   on EOF (drive recv with a closed/empty socket or an injectable reader).
5. **`WsConn.send`** writes the expected unmasked server bytes (drive with
   `std.Io.Writer.fixed`, assert via the writer's buffered bytes).

E2E (`server.zig`, loopback, the echo end-to-end deferred from slice 1):
6. Register `app.get("/echo", echoHandler)`; `startTestApp`; raw TCP connect; send the
   HTTP upgrade request with `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==`; assert the
   `101` status line and `Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`; send a
   masked text frame (`"hello"`); read the echoed unmasked frame and assert
   `opcode == .text`, payload `"hello"`; send a masked `close` frame and confirm the
   connection closes. (A small masked-frame builder in the test constructs client frames.)

## Verification

- `zig build test --summary all` — baseline green + new unit/e2e tests, 0 failures
  (mac kqueue locally; Linux epoll via CI). The e2e drives real loopback I/O on the
  threaded backend.
- Reactor path not exercised/changed.

## Docs

- `README.md`: update the "WebSocket (in progress)" section — primitives **plus** a
  threaded upgrade/echo handler now ship (`zax.WebSocket` + `WsConn`); show the echo
  example. Evented support + fragmentation/control-frame semantics remain following
  releases.
- `CHANGELOG.md`: `[Unreleased]` → `### Added` (second WebSocket slice — threaded
  upgrade + takeover + echo/handler API).
- `docs/getting-started.md`: optional short WebSocket echo example (now user-runnable on
  the threaded backend).
- Version bump `build.zig.zon` → **0.14.0** (its own task in the plan).

## Carry-over for slice 4 (from slice-1 review)

- Range-check frame length against a **configurable max** before buffering/allocating
  (this slice's bound is the staging-buffer size; make it an `Options` knob).
- Add a `parseFrame` fuzz target (zax already has a fuzz harness — see CHANGELOG v0.8.2).
- Auto-pong, RFC close-reply handshake, and fragmentation reassembly (`conn.read`
  returning whole messages) all land in slice 4.
