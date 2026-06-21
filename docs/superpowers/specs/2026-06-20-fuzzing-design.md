# Design — fuzzing harness for the HTTP parsers

**Status:** approved 2026-06-20. Branch `feat/fuzzing` (off main `2a1a29b`).

## Problem

zax's untrusted-input parsers — the request-head parser (`parseHead`) and the inbound
chunked-body decoder (`decodeInPlace`) — have unit tests but no fuzzing. Both consume raw
attacker-controlled bytes; a missed edge (index OOB, integer overflow, unreachable) would be
a crash/DoS. We already fixed one such overflow in `decodeInPlace` by inspection — fuzzing
would have found it. No fuzz harness exists (`grep fuzz` over `src/` is empty).

## Goal

Add Zig-native fuzz tests for `parseHead` and `decodeInPlace` that assert arbitrary input
never panics/UB (only returns an error or a valid result), runnable via `zig build test --fuzz`
locally, with an in-suite smoke pass over a seed corpus so existing CI exercises the harness.

Non-goals: fuzzing the full server IO path / reactor (the byte-level parsers are the
high-value surface); a long-running CI fuzz job (Zig fuzzing is interactive/until-stopped);
external fuzzers (afl/libfuzzer) — Zig native is zero-dep.

### Decisions (confirmed with Chris)
- **Targets:** `parseHead` + `decodeInPlace`.
- **Integration:** fuzz tests live in the module test blocks → plain `zig build test` runs a
  bounded smoke over the seed corpus (CI covers it); `zig build test --fuzz` runs the real
  fuzzer. No new CI job.

## Key facts

- Zig 0.16 fuzzing: `std.testing.fuzz(context, testOne, options)` where
  `testOne: fn(context, smith: *std.testing.Smith) anyerror!void` and
  `options: std.testing.FuzzInputOptions = .{ .corpus = &.{...} }`. Run via
  `zig build test --fuzz`; outside `--fuzz` it runs `testOne` over the corpus (smoke).
- `Smith` exposes only `*WithHash` draws in this version. Fill a scratch buffer with fuzz
  bytes via `smith.sliceWithHash(&buf, hash) u32` (returns the filled length; `buf.len` must
  fit u32). Use a distinct `hash` constant per call site.
- `parseHead(buffer: []const u8, headers_storage: *[request.max_headers]Header) ParseError!Parsed`
  (`parser.zig:42`). parser.zig already imports `std`, `request`, `Header`, `max_headers`.
- `decodeInPlace(buf: []u8, max: usize) DecodeResult` (`chunked.zig:92`) — mutates `buf` in
  place; chunked.zig imports `std`.
- A fuzz test panics under ReleaseSafe/Debug on any OOB/overflow/unreachable → that is the
  failure signal.

## Components

### Modified: `src/http/parser.zig` — fuzz `parseHead`

Add to the test block:
```zig
test "fuzz: parseHead never panics on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const n = smith.sliceWithHash(&buf, 0x9001);
            var hs: [request.max_headers]Header = undefined;
            // Any ParseError is acceptable; the contract is: no panic / no UB.
            _ = parseHead(buf[0..n], &hs) catch {};
        }
    }.one, .{ .corpus = &.{
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        "POST /e HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello",
        "POST /e HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "BADLINE",
        "GET / HTTP/1.1\r\n" ++ ("X: y\r\n" ** 80) ++ "\r\n", // exceeds max_headers
        "",
    } });
}
```

### Modified: `src/http/chunked.zig` — fuzz `decodeInPlace`

Add to the test block (mutable buffer; `decodeInPlace` decodes in place):
```zig
test "fuzz: decodeInPlace never panics on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8192]u8 = undefined;
            const n = smith.sliceWithHash(&buf, 0x9002);
            // Any DecodeResult variant is acceptable; the contract is: no panic / no UB.
            // Exercise both bounded and unbounded max.
            _ = decodeInPlace(buf[0..n], 4096);
            _ = decodeInPlace(buf[0..n], 0);
        }
    }.one, .{ .corpus = &.{
        "5\r\nhello\r\n0\r\n\r\n",
        "5;ext=1\r\nhello\r\n0\r\nX-T: 1\r\n\r\n",
        "0\r\n\r\n",
        "zz\r\nbad\r\n",
        "fffffffffffffffe\r\nhi\r\n0\r\n\r\n", // huge size — overflow guard
        "",
    } });
}
```
(`buf` is re-sliced `[0..n]`; the second `decodeInPlace` call sees the buffer as left by the
first — fine, both must not panic. If a clean second pass on the original bytes is preferred,
copy into a second scratch; the no-panic contract holds either way.)

## Error handling / contract

- The fuzz contract is **no panic / no UB**: any `ParseError` or `DecodeResult` is a pass.
- A crash on the curated seed corpus would indicate a real bug (those inputs are all
  expected-handled) → fix via systematic-debugging (out of scope for this harness; the
  corpus is curated-safe so the smoke is expected green).

## Behavior change & test impact

- Purely additive test code. Plain `zig build test` gains two fuzz tests that run a bounded
  smoke over their corpora (each corpus input + a few generated cases) — small, deterministic,
  CI-friendly. No library/`src` behavior change.

## Testing / verification

1. `zig build test --summary all` — green; the two fuzz tests run their corpus smoke and pass
   (baseline grows by 2). Confirms the harness compiles + the corpus is crash-free.
2. `zig build test --fuzz` — enters fuzzing mode (starts the fuzzer / web UI). Confirm it
   STARTS without erroring; do not run it long. (If a quick run surfaces a crash, that's a
   real parser bug — log it as a follow-up, do not block the harness landing unless trivial.)
3. The harness ships green regardless of deep-fuzz findings; ongoing `--fuzz` runs are the
   continuing activity.

## Docs

- `README.md`: a short "Fuzzing" note — `zig build test --fuzz` fuzzes the request-head parser
  and the inbound chunked decoder (Zig-native, no deps); the same tests run as a corpus smoke
  under plain `zig build test`.
- No CHANGELOG entry — test tooling, not a library change.
