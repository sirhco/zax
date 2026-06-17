# Changelog

All notable changes to zax are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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

[0.2.0]: https://github.com/sirhco/zax/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sirhco/zax/releases/tag/v0.1.0
