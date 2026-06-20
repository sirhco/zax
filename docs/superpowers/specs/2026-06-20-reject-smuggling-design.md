# Design — reject request-smuggling framing (Content-Length + Transfer-Encoding)

**Status:** approved 2026-06-20. Branch `feat/reject-smuggling` (off main `05c5059`).

## Problem

zax does not reject ambiguous request framing. A request with **both** `Content-Length`
and `Transfer-Encoding: chunked`, or with **duplicate** `Content-Length` / multiple
`Transfer-Encoding` headers, is processed (the inbound chunked decoder, shipped 2026-06-19,
runs whenever `isChunked()` is true regardless of a co-present `Content-Length`). RFC 7230
§3.3.3 makes these ambiguous, and the disagreement between a front proxy and zax over which
framing wins is exactly the **HTTP request smuggling** exploit. Confirmed absent: no CL+TE,
duplicate-CL, or multi-TE check anywhere (`src/http/parser.zig`, `src/http/request.zig`,
both backends' `readBody`).

`Request.header()` returns only the FIRST match, so duplicates are currently invisible.

## Goal

Reject (400 Bad Request) any request whose framing headers are ambiguous, on both backends,
before the body is read. Hardened-default behavior.

Non-goals: TE-precedence ("strip CL, honor TE") — rejected (see below); supporting
`Transfer-Encoding` codings other than `chunked`; obs-fold handling (already unsupported).

### Decisions (confirmed with Chris)
- **Reject with 400** (not TE-wins+strip-CL). RFC permits TE-precedence, but a front
  intermediary may resolve the ambiguity differently → smuggling. Mainstream hardened
  servers reject. Reuses the existing `error.Malformed` → 400 path (no new status/error).
- **Strict on duplicates:** reject >1 `Content-Length` (even identical values) and >1
  `Transfer-Encoding` header.
- **Both backends**, identical behavior, via one shared `Request` method.

## Key facts

- Headers: `Request.headers: []const Header` (`request.zig:43`); `header()` (`:49-54`)
  case-insensitive, first match only.
- `contentLength()` (`:56-59`) parses the first CL; `isChunked()` (`:74-77`) →
  `hasToken(transfer-encoding, "chunked")` over a comma list.
- Threaded `readBody` (`server.zig:963`): branches `isChunked()` then `contentLength()`.
  400 path = `return error.Malformed;` (→ `terminalResponse` `.bad_request`).
- Evented `readBody` (`conn.zig:303`): same branch order. 400 path =
  `return .{ .failed = error.Malformed };` (→ `step` maps `error.Malformed` → `.bad_request`).
- No parser change needed; both backends already call `readBody(parsed)` right after parse.

## Components

### Added: `src/http/request.zig` — `Request.hasFramingConflict`

```zig
/// True when the request's framing headers are ambiguous (RFC 7230 §3.3.3) — a
/// request-smuggling vector — and the request must be rejected with 400:
///   - both Transfer-Encoding and Content-Length present, or
///   - more than one Content-Length header, or
///   - more than one Transfer-Encoding header.
/// Scans all headers (header() only sees the first of a duplicate).
pub fn hasFramingConflict(self: *const Request) bool {
    var n_cl: usize = 0;
    var n_te: usize = 0;
    for (self.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) n_cl += 1
        else if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) n_te += 1;
    }
    if (n_cl > 1) return true;          // duplicate Content-Length
    if (n_te > 1) return true;          // multiple Transfer-Encoding
    if (n_cl >= 1 and n_te >= 1) return true; // CL + TE
    return false;
}
```
(Single pass; case-insensitive names. Note: a single `Transfer-Encoding: gzip, chunked` is
one header → `n_te == 1`, not flagged here; only *multiple TE header lines* are flagged. The
CL+TE rule covers the CL co-presence case regardless of the TE value.)

### Modified: `src/server.zig` (threaded `readBody`)

At the very top of `readBody` (`:963`), before the `isChunked()` branch:
```zig
    if (parsed.request.hasFramingConflict()) return error.Malformed;
```

### Modified: `src/reactor/conn.zig` (evented `readBody`)

At the very top of `readBody` (`:303`), before the `isChunked()` branch:
```zig
    if (p.request.hasFramingConflict()) return .{ .failed = error.Malformed };
```

Both reuse the existing `error.Malformed` → **400 Bad Request** mapping. The connection then
closes after the 400 (existing close-after-error behavior) — correct, since a smuggling-shaped
request must not be processed and the stream framing can no longer be trusted.

## Data flow

```
parse head → readBody
  → hasFramingConflict()?  yes → error.Malformed → 400 + close   (NEW)
                           no  → existing isChunked / Content-Length framing
```

## Error handling

- Conflict → 400 + connection close (the request stream framing is untrustworthy; do not
  attempt to find the next request on the connection).
- All existing single-framing requests (CL-only, TE-chunked-only, no-body) are unaffected —
  the check returns false for them.

## Behavior change & test impact

- New rejections only for genuinely ambiguous requests (CL+TE, dup CL, multi-TE). No legit
  single-framing request is affected. The inbound-chunked path (TE-only) and Content-Length
  path keep working.

## Testing

Unit (`src/http/request.zig` test block): `hasFramingConflict()` over crafted header arrays —
- CL+TE → true; two `content-length` → true; two `transfer-encoding` → true;
- CL-only → false; TE-chunked-only → false; `transfer-encoding: gzip, chunked` single header
  + no CL → false; no body headers → false; case-insensitive names (`Content-Length` /
  `TRANSFER-ENCODING`) detected.

Threaded e2e (`src/server.zig`, loopback; mirror the existing chunked-request tests): a
request with `Content-Length: 5` **and** `Transfer-Encoding: chunked` → `400`; a request with
two `Content-Length` headers → `400`; a normal `Content-Length` POST and a normal chunked POST
still succeed (200).

Evented integration (`src/reactor/conn.zig`, fake transport; mirror the chunked-decode tests):
CL+TE request → `400` (step yields `.bad_request`, closes); normal chunked + normal CL
requests still parse + dispatch.

## Verification

- `zig build test --summary all` — baseline 265/268 mac (3 Linux-epoll skips); after this
  feature, baseline + new tests, 0 failures.
- Manual: `printf 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n' | nc 127.0.0.1 <port>` → `HTTP/1.1 400`.

## Docs

- `docs/evented-backend.md` (or a security note in README): zax rejects ambiguous framing
  (CL+TE, duplicate CL, multiple TE) with 400 to prevent request smuggling.
- `CHANGELOG.md`: entry under `[Unreleased]` — `### Security` (or `### Fixed`).
