# Zax — observation hook + access logger (F1) design

Date: 2026-06-17. Status: accepted. Scope: sub-project F1 of theme F
(observability) — the final theme of the post-v0.1.0 roadmap (A–F). A per-request
observation hook + a built-in access logger. F2 (metrics) and F3 (request id) are
separate sub-projects, out of scope here.

**Theme F decomposition:**
- **F1 (this spec): observation hook + access logger** — an `Observer` list fired
  per request in `handleConn`, plus a thread-safe `AccessLogger` (text/JSON).
- **F2: metrics collector** — a thread-safe `Metrics` (atomic counters, in-flight
  gauge, latency) implementing the `Observer` interface; snapshot + Prometheus
  exposition.
- **F3: request id / correlation** — a `request_id` on `Context` (read incoming
  `x-request-id` or generate), echoed in the response and included in logs.

F2/F3 build on F1's hook and are out of scope here.

## Context

zax is silent: no access logs, no per-request timing, no hook for observability.
Middleware can post-process matched responses, but it runs only after routing, so
it never sees 404/405 or parse-error responses, and it can't measure socket write
time. The natural single place that sees *every* dispatched response — with
timing and response size — is `handleConn`, around the `dispatch` →
`writeResponse` pair (src/server.zig:330–333). F1 adds an observation hook there
and a ready-to-use access logger.

## Decision (from brainstorming)

1. **Observer list, not a single hook.** `App.observe(obs)` appends to an
   `observers` list (mirrors `use` for middleware), so multiple observers (F1
   logger + F2 metrics + F3 …) can all fire without a combiner. Each `Observer`
   is a type-erased `{ context: *anyopaque, func }` pair — the same shape as the
   existing `Response.Streamer`.
2. **Fire in `handleConn`, after the response is written.** Capture a monotonic
   `t0` before `dispatch` (only when observers exist — zero overhead otherwise),
   and after a successful `writeResponse` build an `AccessRecord` and call each
   observer. This covers matched, 404, 405, and handler-error responses (all flow
   through `dispatch`→`writeResponse`), including streamed responses. Malformed-
   request *terminal* responses (parse/read errors, before `dispatch`) are not
   observed — there is no valid parsed request; documented.
3. **`AccessRecord`** carries `method`, `path`, `status` (u16), `duration_ns`
   (dispatch + write), and `bytes` (buffered response body length; 0 for
   streamed responses — documented).
4. **Built-in `AccessLogger`** writes one line per record to a caller-provided
   `*std.Io.Writer`, guarded by a `std.Thread.Mutex` (observers fire from the
   `Io.Threaded` pool). A `format` enum selects **text** (default, dev-friendly)
   or **JSON** (structured). Writes are best-effort (errors ignored — logging
   must never break request serving).
5. **Pure, testable formatting.** `AccessLogger`'s formatting lives in
   `src/observe.zig` and is unit-tested by logging to an in-memory writer; the
   `handleConn` wiring is verified by a server integration test.

## Architecture

```
handleConn loop:
  t0 = observers? nowNs(io) : 0
  resp = dispatch(...)            // matched / 404 / 405 / error
  writeResponse(w, resp)
  if observers:
     rec = AccessRecord{ method, path, status=resp.status.code(),
                         duration_ns = nowNs(io)-t0, bytes = resp.body.len }
     for (observers) |o| o.func(o.context, rec)
```

`AccessLogger` is one such observer:
`logger.observer()` → `Observer{ .context = logger, .func = AccessLogger.log }`.

## Components

### 1. `src/observe.zig` (new; exported from root)

```zig
const std = @import("std");
const request = @import("http/request.zig");

pub const AccessRecord = struct {
    method: request.Method,
    path: []const u8,
    status: u16,
    duration_ns: u64,
    bytes: usize,
};

pub const Observer = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque, record: AccessRecord) void,
};

pub const AccessLogger = struct {
    writer: *std.Io.Writer,
    format: Format = .text,
    mutex: std.Thread.Mutex = .{},

    pub const Format = enum { text, json };

    pub fn observer(self: *AccessLogger) Observer {
        return .{ .context = self, .func = log };
    }

    fn log(ctx: *anyopaque, rec: AccessRecord) void {
        const self: *AccessLogger = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writeRecord(rec) catch {}; // best-effort
    }

    fn writeRecord(self: *AccessLogger, rec: AccessRecord) !void {
        const w = self.writer;
        switch (self.format) {
            .text => {
                const ms = @as(f64, @floatFromInt(rec.duration_ns)) / 1_000_000.0;
                try w.print("{s} {s} {d} {d:.3}ms {d}b\n", .{ @tagName(rec.method), rec.path, rec.status, ms, rec.bytes });
            },
            .json => {
                try w.writeAll("{\"method\":\"");
                try w.writeAll(@tagName(rec.method));
                try w.writeAll("\",\"path\":");
                try std.json.Stringify.encodeJsonString(rec.path, .{}, w);
                try w.print(",\"status\":{d},\"dur_us\":{d},\"bytes\":{d}}}\n", .{ rec.status, rec.duration_ns / 1000, rec.bytes });
            },
        }
        try w.flush(); // best-effort; caught by `log`
    }
};
```

Root exports: `pub const observe = @import("observe.zig");` plus
`pub const Observer = observe.Observer;`, `pub const AccessRecord =
observe.AccessRecord;`, `pub const AccessLogger = observe.AccessLogger;`.

### 2. `src/server.zig` integration

- Field: `observers: std.ArrayListUnmanaged(observe.Observer) = .empty,` (import `observe`).
- Setter: `pub fn observe(self: *Self, obs: observe.Observer) std.mem.Allocator.Error!void { try self.observers.append(self.gpa, obs); }`.
- `deinit`: `self.observers.deinit(self.gpa);`.
- A `fn nowNs(io: Io) i96` helper (mirrors bench's: `Io.Timestamp.now(io, .awake).toNanoseconds()`).
- In `handleConn`, around dispatch/writeResponse: capture `t0` if observers present; after `writeResponse` succeeds and before the `if (streamed) break;`, build the `AccessRecord` and loop observers.

## Testing

- **Unit (`zig build test`):** `AccessLogger` text format produces
  `GET /users/42 200 0.412ms 18b\n`; JSON format produces
  `{"method":"POST","path":"/a\"b","status":404,"dur_us":1500,"bytes":0}\n`
  (path with a `"` is JSON-escaped). Logged to a `std.Io.Writer.fixed` buffer;
  assert `w.buffered()`. (Flush errors on a fixed writer are swallowed by `log`;
  the formatted bytes are in the buffer before flush.)
- **Integration (`src/server.zig` socket test):** a capturing test observer
  (copies the record's path into a fixed buffer in its context) is registered via
  `app.observe(...)`. `GET /ping` → the observer sees `method=.GET`,
  `path="/ping"`, `status=200`. `GET /nope` → the observer sees `status=404`
  (proves it covers non-matched responses). Use existing test helpers.
- **Regression:** full `zig build test` stays green (140 + new observe + server tests).

## Files

- Add: `src/observe.zig`.
- Modify: `src/root.zig` (exports), `src/server.zig` (observers field, `observe`
  setter, `deinit`, `nowNs`, `handleConn` hook, integration test).
- Modify: `README.md`, `docs/getting-started.md` (observability/access-log note).

## Risks & edge cases

- **Thread safety:** observers fire from the `Io.Threaded` pool; `AccessLogger`
  serializes writes with a mutex. F2's metrics will use atomics. The `observers`
  list is built before serving and only read during requests (no concurrent
  mutation).
- **Streamed responses:** `bytes` is the buffered body length (0 for streamed);
  `duration_ns` still covers the stream write. Documented.
- **Best-effort logging:** write/flush errors are ignored so a broken log sink
  never breaks request serving.
- **Zero overhead when unused:** the timing read + record build happen only when
  `observers.items.len > 0`.
- **Pre-dispatch terminal responses** (malformed request) are not observed — no
  parsed request to report. Documented.

## Out of scope

Metrics (F2), request id / correlation (F3), distributed tracing / span
propagation, per-route observation, log sampling/rotation.
