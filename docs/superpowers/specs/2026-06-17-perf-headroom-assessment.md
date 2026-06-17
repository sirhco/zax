# Performance headroom assessment — zax server

Status: **assessment / roadmap only** — nothing here is implemented in this change.
The point is to answer "have we done as much as the language supports, or is there
more?" honestly, and to rank what's left so we optimize a *measured* gap rather than
a guessed one.

## TL;DR

zax is already close to the ceiling **for a thread-per-connection HTTP/1.1 server**.
The remaining real lever is architectural (evented IO); the rest is marginal.

**Measured 2026-06-17** (`benchmarks/cross/results.md`, loopback, 64 conns): zax has
the **best median (~0.086ms, ~4× axum) and competitive throughput (~160k req/s,
beats go)** — but a **p99.9/max tail ~50× worse** (zax ~36ms/51ms vs axum ~0.65ms/5ms,
go ~1.5ms/8ms). The A/B confirmed `TCP_NODELAY` helps **p99** (~10.5→7.4ms) but does
**nothing** for the p99.9/max cluster → the tail is the **thread-per-connection model
under oversubscription**, not a socket option. This is direct evidence for lever #1.

## Already done (near the thread-per-conn ceiling)

Hot path: `src/server.zig` `acceptLoop` → `handleConn` → `readHead`/`readBody`
(`src/http/parser.zig`) → `router.match` (`src/router/radix.zig`) → handler →
`writeResponse` (`src/http/response.zig`).

- **TCP_NODELAY** per accepted connection (`server.zig`, now opt-out via
  `Options.tcp_nodelay`). Matches axum/hyper + Go net/http.
- **HTTP keep-alive** + **pipelining** (`ConnReader.compact`), capped by
  `max_keep_alive_requests`.
- **Per-connection arena**, `reset(.retain_capacity)` each request → no per-request
  arena churn. Measured **~5 bytes/req** (`src/bench/baseline.json` mem.* metrics).
- **Zero-copy parser**: method/path/query/header slices point into the read buffer;
  headers in a stack array (`max_headers = 64`), no map, no alloc.
- **Radix-tree routing** (O(path-depth), static > param > wildcard), zero-copy params
  in a stack buffer (`max_params = 16`).
- **Per-connection read/write buffers** allocated once (16 KiB / 8 KiB), reused.
- **Single flush** per response via the buffered writer (status line + headers + body
  coalesce into one write syscall).
- **`smp_allocator`** backing in ReleaseFast.
- Zero-overhead-when-off **request_id** and **observer/metrics** hooks.

## UPDATE 2026-06-17 (#2) — worker-pool cap benchmarked, tail NOT fixed

The promoted lever (bound the worker pool) was implemented + measured: it **does not
flatten the tail**. Cap sweep 8→48 leaves p99.9 ~35ms; at 8 threads on 18 cores
(undersubscribed) the cluster persists → **oversubscription refuted**. The ~35ms tail is
a fixed stall in zax's per-conn read path on `std.Io.Threaded`, independent of thread
count. Real next step: **trace where the 35ms goes** (keep-alive `receiveTimeout` wakeup /
thread park granularity), not more concurrency levers. Data: `benchmarks/cross/results.md`.

## UPDATE 2026-06-17 — spike result reranks the levers

A spike + research round (`2026-06-17-evented-io-decision.md`) found that **evented IO
via `std.Io.Evented` is a dead end on macOS + Linux in Zig 0.16** — the Dispatch and
Uring backends stub their TCP socket ops (`*Unavailable`); only BSD Kqueue implements
them. So lever #1 below as originally written is **blocked upstream**, not actionable now.

**Revised priority:** the real, available tail fix is **bounding the worker pool** within
the existing thread-per-conn model (httpz's pattern: workers ~cores + backpressure) —
formerly lever #2, now the **top lever**. zax spawns an unbounded thread per accept; that
is the oversubscription producing the ~50× p99.9/max tail. Cheap, additive, testable on
mac today. See the decision doc for the full plan. The ranking below is kept for record;
read it through the decision doc's reversal.

## Remaining levers, ranked

### 1. Evented IO reactor — BIG, architectural — BLOCKED on Zig 0.16 std (see update above)

Today each connection is a thread via `std.Io.Threaded` (`conn_group.async`). The
code comment already names the goal as a future single-thread `Io.Evented`. Moving to
an evented reactor (kqueue / epoll / io_uring) is **the** lever for C10k+ concurrency
and tail latency under many idle/slow connections.

**Measured motivation:** in the 2026-06-17 cross-framework run, zax's median and
throughput matched/beat axum and go, but its p99.9/max tail was ~50× worse on the
same box — the thread-per-conn signature. axum (tokio) and go (goroutines) stayed
flat *because* of their M:N/evented schedulers. The tail gap is the model, and this
is the lever that closes it.

- **Gated on** Zig 0.16 `std.Io.Evented` maturity — verify it exists/works before
  committing. zax's pluggable `Io` design means handlers shouldn't need rewriting,
  but the accept/serve loop and timeout model would.
- **Blast radius**: large (accept loop, per-conn lifecycle, timeouts). Deserves a
  dedicated spike + spec, not a drive-by.
- **Expected gain**: high for high-connection-count / slow-client workloads; little
  for the current 64-conn loopback micro (already CPU-bound there).

### 2. Tunables + baseline hygiene — MEDIUM, additive

- Expose the `Io.Threaded` **thread-pool size** as an `Options` field (today it's the
  std default). Lets users match worker count to cores / `GOMAXPROCS` for fair bench
  and production tuning. Purely additive.
- Separate **ReleaseFast vs default** baselines in `src/bench/baseline.json` (current
  baseline doesn't record the build profile).
- Buffer sizes (`read_buffer_size` / `write_buffer_size`) are *already* tunable.

### 3. Marginal — note and decline

- **`writev` / vectored IO** for headers+body: the buffered writer already coalesces
  into one flush syscall, so vectored IO saves little. Low ROI.
- **Header map / hashing**: linear scan over ≤64 stack headers is faster than a map
  at this cardinality. Don't.
- **Object pools** beyond the per-conn arena: arena reset already gives reuse; extra
  pooling adds complexity for negligible gain at ~5 bytes/req.

## Conclusion / next step

Cross-framework numbers are now in (`results.md`) and they show a real, large tail gap
driven by the thread-per-conn model — so **lever #1 (evented IO) is the priority**, no
longer speculative. Next steps, in order:

1. **Confirm the model is the cause, not just the box.** Re-run from a **separate
   machine** (or Linux `PIN=1`) — if zax's p99.9/max stays ~50× axum/go off-box, the
   model is confirmed beyond same-host oversubscription.
2. **Spike `std.Io.Evented` on Zig 0.16** — verify it exists and works; prototype the
   accept/serve loop on it behind zax's pluggable `Io`. Gate the theme on this.
3. If viable, write a dedicated spec/plan (evented reactor: accept loop, per-conn
   lifecycle, timeout model) — this is its own roadmap theme, not a drive-by.

Lever #2 (thread-pool size Option) is a cheap, additive interim that also lets us tune
worker count to match cores for fairer benches in the meantime.
