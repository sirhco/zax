# Disable Nagle (TCP_NODELAY) on accepted connections

> Small, focused fix. TDD: failing helper test → implement → wire into the accept path → verify.

## Context

A cross-framework load benchmark (`benchmarks/cross/`) showed zax with a bimodal
latency tail: ~95% of requests sub-0.13ms, but a cluster at **24–44ms** (p99.9
~35ms) — while axum (hyper) and Go `net/http` stayed flat (~0.5ms p99.9) on the
same box. Investigation (systematic-debugging) found:

- zax's request hot path is sub-µs (in-process bench max ~62µs); no app-code
  defect, no per-request allocation on the static path.
- zax runs an 18-thread (= ncpu) evented pool, not thread-per-connection.
- **zax sets `TCP_NODELAY` nowhere** — accepted sockets keep Nagle's algorithm
  on. The 24–44ms cluster is the classic **Nagle + delayed-ACK ~40ms** signature.
  axum (hyper) and Go `net/http` both set `TCP_NODELAY` by default.

Disabling Nagle is standard for any HTTP server (nginx, hyper, Go, Node all do
it): with small request/response messages, Nagle can hold a response waiting for
an ACK that the peer delays ~40ms. This is the prime fixable cause of the tail.

(A secondary contributor — CPU oversubscription on the single-box benchmark — is a
methodology issue, addressed separately by running the client off-box.)

## Goal

Set `TCP_NODELAY` on every accepted connection socket, always-on (correct default
for an HTTP server; no option needed), best-effort (a failure must never break
serving).

## Design

- A file-scope helper in `src/server.zig`:
  ```zig
  fn setNoDelay(handle: net.Stream.Handle) void { // or @TypeOf(stream.socket.handle)
      std.posix.setsockopt(
          handle,
          std.posix.IPPROTO.TCP,
          std.posix.TCP.NODELAY, // or std.c.TCP.NODELAY (= 10) — use whichever this std exposes
          &std.mem.toBytes(@as(c_int, 1)),
      ) catch {}; // best-effort: never break a connection over a socket-option failure
  }
  ```
  (Confirm the exact names: `stream.socket.handle` is the fd; `std.posix.setsockopt`
  exists; `IPPROTO.TCP` and `TCP.NODELAY`/`= 10` are reachable — verified during
  investigation.)
- Call it once per connection at the top of `handleConn`, right after
  `var stream = stream_in;`:
  ```zig
  setNoDelay(stream.socket.handle);
  ```

## Files

- Modify `src/server.zig` — `setNoDelay` helper + call in `handleConn` + a unit test.
- Modify `README.md` — one line under connection handling / observability that zax
  disables Nagle (TCP_NODELAY) on connections.

## Task 1: TDD the helper + wire it in

- [ ] **Step 1: Failing unit test** in `src/server.zig` test section: create a TCP
  socket, call `setNoDelay`, then `getsockopt(fd, IPPROTO.TCP, TCP.NODELAY)` and
  assert the option reads back enabled (non-zero). Close the socket.
  ```zig
  test "setNoDelay enables TCP_NODELAY on a socket" {
      const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
      defer std.posix.close(fd);
      setNoDelay(fd);
      var val: c_int = 0;
      var len: std.posix.socklen_t = @sizeOf(c_int);
      try std.posix.getsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&val)[0..], &len);
      try testing.expect(val != 0);
  }
  ```
  (Adapt to this std's exact `getsockopt` signature — it may differ; if `getsockopt`
  isn't ergonomic, assert via a round-trip the way the std tests do, or skip the
  read-back and at least assert `setNoDelay` doesn't error on a valid fd while a
  no-op on a bad fd. Prefer the real getsockopt assertion.)
- [ ] **Step 2: Run → fails** (`setNoDelay` undefined). `zig build test 2>&1 | grep -E "error|setNoDelay"`.
- [ ] **Step 3: Implement** `setNoDelay` + call it at the top of `handleConn`.
- [ ] **Step 4: Run → passes.** `zig build test --summary all 2>&1 | grep "tests passed"` (151 + 1 = 152).
- [ ] **Step 5: Flakiness** `for i in 1 2 3; do zig build test >/dev/null 2>&1 && echo ok; done` → 3 ok (the existing socket integration tests still pass with NODELAY on).
- [ ] **Step 6: Commit** `git commit -m "feat(server): set TCP_NODELAY on accepted connections (disable Nagle)"`.

## Task 2: Docs

- [ ] README one-liner: zax disables Nagle (sets `TCP_NODELAY`) on every connection
  so small responses aren't held by the delayed-ACK ~40ms penalty.
- [ ] Commit `docs: note TCP_NODELAY on connections`.

## Verification

- Full suite green (152); existing real-socket integration tests still pass (proves
  NODELAY doesn't break the request/response path).
- **Latency confirmation is the off-box benchmark re-run**: with NODELAY, the
  24–44ms cluster should disappear (can't be measured in this sandbox; do it on the
  bench box with the client off-host or core-pinned).

## Notes

- Always-on, best-effort: a `setsockopt` failure is swallowed — a connection must
  never die over a socket-option tweak.
- Portability: `stream.socket.handle` is the POSIX fd on the supported targets
  (darwin/linux). If a non-POSIX target is ever added, guard accordingly.
