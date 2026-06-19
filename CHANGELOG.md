# Changelog

All notable changes to zax are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Evented reactor: `EventedOptions.stream_idle_timeout_ms` — opt-in whole-stream idle cap that hard-closes a pull stream (`streamPull`/`ssePull`) producing no data for N ms (default 0 = disabled).
- Inbound `Transfer-Encoding: chunked` request bodies are now decoded on both backends (previously rejected with 411). Bounded by `max_body_size`; chunk extensions and trailers tolerated; malformed framing → 400.

## [0.5.0] - 2026-06-18

### Added

- **Chunked transfer-encoding for streamed responses.** Streamed responses (`stream`, `sse`,
  `streamPull`, `ssePull`) now use `Transfer-Encoding: chunked` and keep the connection alive for
  HTTP/1.1 persistent clients, on both backends; connection-close framing remains the fallback
  for HTTP/1.0 / `Connection: close` / keep-alive-disabled.

## [0.4.0] - 2026-06-18

### Added

- **`Response.ssePull` — pull-model Server-Sent Events.** Emits SSE on **both** backends
  (the push `sse()` helper remains threaded-only). `nextFn(*Ctx) -> SsePull` returns
  `{ event, comment, not_ready, done }`; zax frames each event/comment via the SSE wire
  formatter. `not_ready` parks on the evented backend (no busy-spin); an event larger than the
  write buffer closes the connection.

## [0.3.0] - 2026-06-18

The headline is a second, opt-in server backend: an **evented reactor** that
runs natively on Linux (epoll) and macOS/BSD (kqueue). The default
thread-per-connection backend (`App.serve`) is unchanged.

### Added

- **Evented reactor backend (`App.serveEvented`):** N shared-nothing workers
  over `SO_REUSEPORT`, each owning a non-blocking per-connection state machine,
  an epoll (Linux) / kqueue (macOS/BSD) poller, and a coarse per-worker timer
  wheel. Opt-in and Linux+BSD/macOS only; the threaded backend remains the
  default. Worker count defaults to the CPU **affinity mask** (respects
  `taskset`/cgroup cpusets), `EventedOptions.workers` to override. Keep-alive
  and HTTP pipelining supported; transport-abstracted so the state machine is
  unit-tested via a fake transport.
- **True streaming on the evented backend:** `Response.streamPull()` with a
  `PullStreamer { nextFn(ctx, buf) -> PullResult }`, connection-close framing,
  backpressure-aware. Works on both backends.
- **Sparse-SSE readiness park:** when a pull producer returns `chunk(0)`
  (no data yet), the connection parks on the timer wheel instead of
  busy-spinning the poller. `EventedOptions.stream_repoll_ms` (default 5 ms;
  `0` = legacy behavior) tunes the re-poll backoff.
- **`request_id` parity** on the evented backend (matches the threaded path).
- **`Options.tcp_nodelay`** (default `true`): disable Nagle on accepted
  connections; opt out to restore Nagle.
- **`Options.max_in_flight`:** cap concurrent in-flight connections
  (`0` = unbounded, the default).
- **O(1) timer wheel** `nextDeadlineMs` via a lazily-cached min-deadline.

### Fixed

- Evented: arm a read deadline at accept time (no idle-connection fd leak) and
  fire observers on the evented path.
- Evented: arm a write-stall deadline so peers that stall mid-write are reaped.
- Evented: worker `EMFILE`/`ENFILE` backpressure (pause accept, recover).
- `serveEvented` spawn-failure cleanup is a single correct path (no
  double-deinit).
- Poller `wait` checks `errno` and never returns a sentinel count.

### Notes

- `std.Io.Evented` still cannot serve TCP in Zig 0.16 (Dispatch/Uring net ops
  are `*Unavailable` stubs), so the reactor is zax's own epoll/kqueue loop
  rather than the std evented backend. See
  `docs/superpowers/specs/2026-06-17-evented-io-decision.md`.
- Worst-case `max` latency under cloud-VM vCPU steal is an accepted
  characteristic of the shared-nothing model (p99.9 unaffected; throughput
  leader). Work-stealing was spiked and rejected as not-worth-it — see
  `docs/superpowers/specs/2026-06-18-work-stealing-spike.md`.

## [0.2.0] - 2026-06-17

Six themes landed since 0.1.0 — error handling, connection hardening,
extractor/response parity, routing parity, benchmarking, and observability.

### Added

- **Error handling:** a canonical `Error` set with `classify`; extractor and
  handler errors now map to real HTTP statuses; an `onError` hook for custom
  error rendering; 404/405 rendered through the hook with an `Allow` header on
  405; `429 Too Many Requests`.
- **Connection hardening:** `ConnReader` read path with header/body size limits
  (`413`/`431`) and read/idle timeouts (`408`).
- **Request extractors:** `Form`, `Cookies`, and `Bytes`; a shared `urlencoded`
  binder with percent-decoding; percent-decoded `Path` params.
- **Responses:** `Response.html` and typed `Response.json`; redirect constructors
  and `303`/`307`/`308`; streaming bodies (`Response.Streamer`, connection-close
  framing); Server-Sent Events (`Sse`, `Response.sse`).
- **Static files:** a `Files` extractor (`file`/`dir`) with traversal-safe
  `safeJoin`, content-type detection, and `PayloadTooLarge` handling.
- **Routing:** `App.fallback` (custom 404 / SPA index); `*name` wildcard /
  catch-all routes; per-route middleware (`getWith`/`routeWith`); route groups
  (`App.group` — shared prefix and middleware, nestable).
- **Observability:** a per-request observation hook (`App.observe`); a
  thread-safe `AccessLogger` (text or JSON); a `Metrics` collector with
  `snapshot()` and Prometheus exposition (`writePrometheus`); opt-in request-id /
  correlation (`Options.request_id`, the `RequestId` extractor, a validated
  incoming `x-request-id` or a generated id, echoed in the response and access
  log).
- **Benchmarking** (`zig build bench`): warmup + multi-sample median/stddev with
  CLI flags; allocation/memory metrics (bytes/req, peak RSS); coverage micros
  (middleware chain, extractors, wildcard/nested routing) plus e2e scenarios; a
  regression baseline (`--json` snapshot, `--check` gate against a committed
  baseline).

### Fixed

- `Path` parameters are now percent-decoded.
- `Files.safeJoin` rejects control bytes in the requested path.
- Benchmark micros no longer fold away under `ReleaseFast`; the bench rejects
  zero `--iters`/`--conns`/`--reqs`.

### Notes

- Requires Zig **0.16.0**.

## [0.1.0]

Initial release.

[0.5.0]: https://github.com/sirhco/zax/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sirhco/zax/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sirhco/zax/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sirhco/zax/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sirhco/zax/releases/tag/v0.1.0
