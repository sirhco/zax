# Zax — wildcard/catch-all routing (D2) design

Date: 2026-06-16
Status: approved, ready for implementation planning
Scope: sub-project D2 of theme D (routing parity). A single `*name` catch-all
segment that captures the remainder of the request path. Fallback handler (D1),
per-route middleware (D3), and nested routers (D4) are separate sub-projects,
out of scope.

## Context

The radix router (`src/router/radix.zig`) supports static segments and `:name`
parameter segments. There is no way to match a prefix and capture everything
after it as a single value. This blocks the idiomatic pattern of mounting a
directory of static files under a route prefix (e.g. `/assets/*path` → served
by `Files.dir`), and more generally any handler that needs the raw remainder of
the path. Axum's router has `/*path` for this purpose; Zax has no equivalent.

## Decision (from brainstorming)

1. **Syntax `*name`** — a segment beginning with `*` is a catch-all. It captures
   the rest of the request path (from that segment onward, slashes included) into
   a single named param, consistent with how `:name` names a single-segment
   capture. Accessible via `Path(struct { path: []const u8 })` with no changes to
   the extractor layer.

2. **Empty tail NOT matched** — `/assets/*path` matches `/assets/x` and
   `/assets/a/b` but not bare `/assets` or `/assets/`. If a handler for the bare
   prefix is needed, register it as an explicit separate route.

3. **Precedence: static > param > wildcard, with fallback.** At each node the
   matcher tries a static child first, then a param child, then the wildcard
   child. If a higher-precedence subtree dead-ends (no slot and no onward match),
   the matcher backtracks and tries the next kind, so a catch-all still captures
   a path that a sibling `:param` could not complete (with both `/a/:id` and
   `/a/*rest`, the path `/a/x/y` falls through to `*rest`). Matching is therefore
   recursive (depth = number of path segments).

4. **Catch-all is terminal** — `*name` must be the last segment in a pattern.
   The slot lives on the wildcard node, and `match` reads it only there, so any
   segments registered after `*name` (`/a/*tail/b`) produce an unreachable route.
   This is treated as a caller error (a future hardening could assert/reject it).

## Architecture

```
request path: /assets/img/logo.png

tree walk: "assets" → static child
           "img"    → no static, no param → wildcard_child present?
                        yes → capture path[offset..] = "img/logo.png"
                              return wildcard node's slot (terminal)
```

The wildcard child is a pointer on each `Node`, parallel to `param_child`.
`getOrPutSlot` recognises a `*name` segment and routes to/creates
`wildcard_child`, storing the capture name in `param_name` (the existing field,
reused). `match` is recursive (`matchNode`): at each node it tries static, then
param, then `wildcard_child`, in that order, and backtracks to the next kind if a
chosen subtree dead-ends. When the wildcard is taken, the remainder of the path
string (from the start of the current segment to the end of `path`) is captured
in one zero-copy slice and that branch returns.

No changes are needed to `router.zig`, `path.zig`, `server.zig`, or the extract
layer. The wildcard is registered and dispatched as an ordinary named param; the
`Path` extractor finds it by name in the params slice.

## Components (all in `src/router/radix.zig`, inside `Tree(T).Node`)

### 1. The `wildcard_child` field

```zig
wildcard_child: ?*Node = null,
```

Added alongside `param_child` in the `Node` struct. The wildcard node's
`param_name` holds the capture name (e.g. `"path"` for `*path`); its `slot`
holds the terminal payload.

### 2. `getOrPutSlot` — wildcard branch

```zig
} else if (seg[0] == '*') {
    const name = seg[1..];
    if (node.wildcard_child == null) {
        const child = try self.gpa.create(Node);
        child.* = .{ .param_name = name };
        node.wildcard_child = child;
    }
    node = node.wildcard_child.?;
}
```

Inserted as an `else if` between the `:name` branch and the static `else`
branch. There is no early `break`: terminality is a convention (the slot lives on
the wildcard node and `match` only reads it there), so segments after `*name`
just build an unreachable subtree (caller error).

### 3. `match` — recursive, with backtracking and offset tracking

`match` delegates to a recursive `matchNode` that resolves the next non-empty
segment and tries children in precedence order, returning on the first non-null
result and falling through otherwise. The segment iterator is passed by value so
each branch resumes independently. The wildcard capture is a zero-copy slice of
the tail, computed by pointer arithmetic (`seg` is always a subslice of `path`):

```zig
fn matchNode(node, path, segs, params_buf, n) MatchError!?Match {
    var it = segs;
    const seg = while (it.next()) |s| { if (s.len != 0) break s; } else {
        const value = node.slot orelse return null;       // no more segments
        return .{ .value = value, .params = params_buf[0..n] };
    };

    if (node.static.get(seg)) |child| {                   // 1. static
        if (try matchNode(child, path, it, params_buf, n)) |m| return m;
    }
    if (node.param_child) |child| {                       // 2. param
        if (n == params_buf.len) return error.TooManyParams;
        params_buf[n] = .{ .name = child.param_name, .value = seg };
        if (try matchNode(child, path, it, params_buf, n + 1)) |m| return m;
    }
    if (node.wildcard_child) |child| {                    // 3. wildcard (terminal)
        if (child.slot) |value| {
            if (n == params_buf.len) return error.TooManyParams;
            const offset = @intFromPtr(seg.ptr) - @intFromPtr(path.ptr);
            params_buf[n] = .{ .name = child.param_name, .value = path[offset..] };
            return .{ .value = value, .params = params_buf[0 .. n + 1] };
        }
    }
    return null;
}
```

An abandoned param branch leaves a stale write at `params_buf[n]`, but a later
wildcard overwrites that same index and returns `params_buf[0 .. n + 1]`, so no
stale param leaks. Behaviour for existing static/param routes is unchanged.

### 4. `deinit` — recurse into wildcard child

```zig
if (node.wildcard_child) |child| child.deinit(gpa);
```

Added alongside the existing `param_child` cleanup.

## Data flow / error handling

- **Normal wildcard match:** walker reaches a node with `wildcard_child` when no
  static or param child matches. The tail `path[offset..]` is captured zero-copy
  (a slice into the caller's `path` string). The wildcard node's slot value is
  returned immediately; no further segments are consumed.
- **Empty tail (bare prefix):** `/assets/*path` registered; request is
  `/assets`. The walk ends at the `assets` static node; its `slot` is null
  (only the wildcard child has a slot). `match` returns null → 404. Correct.
- **Precedence with fallback:** static child wins first, then param child, then
  wildcard child. If a chosen subtree dead-ends, the matcher backtracks and tries
  the next kind — so a param that grabs a segment but later dead-ends falls
  through to the sibling wildcard (`/a/:id` + `/a/*rest`, path `/a/x/y` → `*rest`).
- **`TooManyParams`:** wildcard consumes one param slot, same budget as `:name`.
  With `max_params = 16` in the server, a route with 15 `:name` segments and one
  `*tail` at the end is the limit.

## Testing (in `src/router/radix.zig`)

- **Multi-segment tail:** `/assets/*path` registered; `/assets/img/logo.png` →
  param `path = "img/logo.png"` (zero-copy into the path string).
- **Single-segment tail:** `/assets/*path`; `/assets/style.css` → `path =
  "style.css"`.
- **Bare prefix not matched:** `/assets/*path`; `/assets` → null.
- **Static beats wildcard:** `/assets/index.html` and `/assets/*path` both
  registered; `/assets/index.html` → static route (no wildcard param).
- **Param beats wildcard:** `/users/:id` and `/users/*rest` both registered;
  `/users/42` → param route, `id = "42"`.
- **Zero-copy:** the captured tail slice's pointer falls within the original path
  string (same pointer arithmetic test as the existing param zero-copy test).
- **Server socket integration:** `app.route("GET", "/assets/*path", handler)`
  where `handler` extracts `Path(struct { path: []const u8 })` and calls
  `files.dir("static", path.value)`; a GET to `/assets/index.html` returns the
  file body.

## Files

- Modify: `src/router/radix.zig` (`Node` struct, `getOrPutSlot`, `match`,
  `deinit`, new unit tests).
- No other files change. `router.zig`, `path.zig`, `files.zig`, and
  `server.zig` are unaffected.

## Risks & edge cases

- **Trailing slash in tail:** a request to `/assets/a/b/` yields tail `"a/b/"`.
  `safeJoin` splits on `/` and rejects empty segments (trailing slash produces
  an empty final segment) — `Files.dir` returns `error.NotFound` → 404.
  Correct; no special handling needed.
- **Recursive matching:** the matcher backtracks across sibling node kinds, so it
  is recursive. Recursion only descends into a child that exists in the tree, so
  depth is bounded by the **registered route tree depth** (developer-controlled),
  not by attacker-supplied path length — a deep junk path reaches a node with no
  matching child and returns null at once. Param chains are further capped by
  `max_params = 16`. The request head is also bounded by `read_buffer_size`
  (16 KiB). Depth is therefore small in practice; no explicit depth limit is
  imposed.
- **Param budget:** the wildcard capture consumes one slot of the `max_params`
  budget (16 in the server). A pattern with 16 prior `:name` segments and a
  `*tail` would overflow `TooManyParams`. In practice this is not a concern for
  real routes.
- **Wildcard not terminal:** registering `/a/*mid/b` is logically ill-formed.
  The `break` in `getOrPutSlot` silently drops the `/b` segment. The plan phase
  should decide whether to assert or silently truncate; this spec treats it as
  caller error.
- **Conflicting wildcard names:** two routes with the same prefix but different
  catch-all names (e.g. `/a/*x` then `/a/*y`) share the same `wildcard_child`
  node; the second registration overwrites `param_name`. Treat as a duplicate
  route registration error (same as two static routes at the same path).

## Out of scope

Per-route middleware (D3), nested routers (D4). SPA index fallback (serve
`index.html` for any unknown path) uses the `fallback` handler (D1), not a
wildcard route.
