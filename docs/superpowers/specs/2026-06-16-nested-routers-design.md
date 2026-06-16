# Zax — nested routers / route groups (D4) design

Date: 2026-06-16. Status: accepted. Scope: sub-project D4 of theme D (routing
parity) — the final one. Route groups with a shared path prefix and shared
middleware, nestable. Fallback (D1), wildcard (D2), and per-route middleware
(D3) are done.

## Context

Routes are registered flat on `App`: `app.get("/api/users", h)`,
`app.get("/api/orders", h)`. Repeating a prefix and re-listing shared middleware
on every route is noisy and error-prone. D3 gave per-route middleware
(`routeWith`/`getWith`); D4 adds **route groups**: register a set of routes under
a common prefix with common middleware, and nest groups.

Key constraint discovered: the radix tree borrows pattern slices — static
segment keys go through `node.static.getOrPut(gpa, seg)` (no key copy) and param
names are slices into the pattern (`src/router/radix.zig`). So **patterns must
have program lifetime**. Today users pass string literals (static). A group's
combined `prefix ++ pattern` must therefore be built at **comptime** to stay
static — no per-registration allocation, no lifetime bookkeeping.

## Decision (from brainstorming)

1. **Prefix-group facade.** `app.group(prefix, mwTuple)` returns a lightweight
   `Group` value holding `*App`. It prepends the comptime `prefix` and the
   group's shared middleware to every route registered through it, registering
   into the app's single radix tree. No separate router instance, no tree merge.

2. **Reuse D3.** Group registration delegates to `App.routeWith`:
   `app.routeWith(method, prefix ++ pattern, group_mws ++ route_mws, handler)`.
   Composition, ordering, static storage, and zero-allocation all come from D3.

3. **Comptime prefix + comptime middleware tuple.** `prefix` and the middleware
   tuple are comptime so `prefix ++ pattern` (string concat) and
   `group_mws ++ route_mws` (tuple concat) are comptime-known → static. Group
   route methods take a `comptime pattern` (string literals, like handlers).

4. **Nesting composes at comptime.** `group.group(sub, moreMws)` returns
   `Group(prefix ++ sub, group_mws ++ moreMws)` — prefixes concatenate, middleware
   tuples concatenate outer-to-inner.

5. **Ordering: global → group(s) → route → handler.** Outer group middleware
   before inner before per-route before the handler; falls out of the tuple
   concatenation order and D3's wrapper.

6. **Purely additive.** New `Group` type + `App.group` method only. No changes to
   `router.zig`, `radix.zig`, `middleware.zig`, `dispatch`, or the extract layer.

## Architecture

```
const api = app.group("/api", .{ &auth });     // Group("/api", .{&auth})
const v1  = api.group("/v1", .{ &log });        // Group("/api/v1", .{&auth,&log})
try v1.getWith("/items", .{ &cache }, list);    // see below

==> app.routeWith(.GET, "/api/v1/items", .{ &auth, &log, &cache }, list)
    request order: global mws -> auth -> log -> cache -> list
```

`Group` is generic over the comptime prefix and middleware tuple; it carries only
a `*App` pointer at runtime. Every method forwards to `App.route`/`App.routeWith`
with the concatenated prefix and middleware.

## Components (all in `src/server.zig`, inside `App(AppState)`)

### 1. The `Group` facade type

```zig
/// A route group: a shared comptime `prefix` and shared `group_mws` (a comptime
/// middleware tuple) applied to every route registered through it. Created by
/// `App.group`; nestable via `Group.group`.
pub fn Group(comptime prefix: []const u8, comptime group_mws: anytype) type {
    return struct {
        const G = @This();
        app: *Self,

        pub fn route(self: G, method: request.Method, comptime pattern: []const u8, comptime handler: anytype) !void {
            return self.app.routeWith(method, prefix ++ pattern, group_mws, handler);
        }
        pub fn routeWith(self: G, method: request.Method, comptime pattern: []const u8, comptime mws: anytype, comptime handler: anytype) !void {
            return self.app.routeWith(method, prefix ++ pattern, group_mws ++ mws, handler);
        }

        pub fn get(self: G, comptime p: []const u8, comptime h: anytype) !void { return self.route(.GET, p, h); }
        pub fn post(self: G, comptime p: []const u8, comptime h: anytype) !void { return self.route(.POST, p, h); }
        pub fn put(self: G, comptime p: []const u8, comptime h: anytype) !void { return self.route(.PUT, p, h); }
        pub fn delete(self: G, comptime p: []const u8, comptime h: anytype) !void { return self.route(.DELETE, p, h); }

        pub fn getWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void { return self.routeWith(.GET, p, mws, h); }
        pub fn postWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void { return self.routeWith(.POST, p, mws, h); }
        pub fn putWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void { return self.routeWith(.PUT, p, mws, h); }
        pub fn deleteWith(self: G, comptime p: []const u8, comptime mws: anytype, comptime h: anytype) !void { return self.routeWith(.DELETE, p, mws, h); }

        /// Nest a sub-group: prefixes concatenate, middleware tuples concatenate
        /// (outer group middleware run before inner).
        pub fn group(self: G, comptime sub: []const u8, comptime more_mws: anytype) Group(prefix ++ sub, group_mws ++ more_mws) {
            return .{ .app = self.app };
        }
    };
}
```

### 2. `App.group` entry point

```zig
/// Open a route group with a shared comptime `prefix` and shared middleware
/// `mws` (a comptime tuple). Routes registered through the returned `Group` are
/// registered on this app at `prefix ++ pattern` with `mws` prepended to their
/// chain. Pass `.{}` for a prefix-only group.
pub fn group(self: *Self, comptime prefix: []const u8, comptime mws: anytype) Group(prefix, mws) {
    return .{ .app = self };
}
```

## Data flow / error handling

- A group route reduces to a single `App.routeWith` call; dispatch, matching,
  404/405, and error rendering are exactly as for any other route.
- Ordering global → group(s) → route → handler is produced by D3's wrapper over
  the concatenated middleware tuple; nothing new in `dispatch`.
- A group middleware that short-circuits (returns without `next.run()`) skips the
  rest of the group/route chain and the handler, like any middleware.

## Testing (integration in `src/server.zig`)

- **Prefixing:** `api = group("/api", .{})`; `api.get("/users", ping)` → `GET
  /api/users` is 200; `GET /users` is 404.
- **Group middleware applies + ordering:** body-wrapping mws — global `wrapG`,
  group `.{ &wrapGrp }`, route `getWith(.{ &wrapR }, H)` → body `G(Grp(R(H)))`;
  a non-group route does not get `wrapGrp`.
- **Nesting:** `api.group("/v1", .{ &wrapV1 })`; `v1.get("/items", H)` → `GET
  /api/v1/items`, body `G(Grp(V1(H)))` (global → group → subgroup → handler).
- **Short-circuit scoping:** group with `requireAuth` → every group route 401
  without auth, 200 with; a route registered directly on `app` is unaffected.
- **Group root route:** `api.get("", ping)` (or `"/"`) registers `/api`.
- **Flakiness:** real-socket tests run 3×.

## Files

- Modify: `src/server.zig` (`Group` type + `group` method; integration tests).
- Modify: `README.md`, `docs/getting-started.md` (route groups note).
- No changes to `src/router/*`, `src/middleware.zig`, or the extract layer.

## Risks & edge cases

- **Tuple `++`:** relies on comptime tuple concatenation for `group_mws ++ mws`.
  If a Zig version rejects it, build the combined tuple via an `inline for` into a
  comptime value (still static, still zero-alloc) — never fall back to runtime
  allocation.
- **Slash hygiene:** `prefix ++ pattern` is a literal concatenation. Convention:
  prefix has a leading `/` and no trailing `/`; route patterns have a leading
  `/` (or `""` for the group root). `group("/api") + get("/users")` →
  `/api/users`. Mis-paired slashes (e.g. `/api/` + `/users` → `/api//users`) are
  caller error; the radix splitter skips empty segments so most slips still
  resolve, but the convention is documented.
- **Comptime patterns only:** group route patterns must be comptime (string
  literals) to keep concatenated patterns static. Runtime-built group paths are
  not supported (and would reintroduce the lifetime problem). Out of scope.
- **No per-group fallback/onError:** groups share the app's `fallback`/`onError`.
  Out of scope.

## Out of scope

Mountable independently-built sub-routers (tree merge / runtime mount),
runtime-built group prefixes, per-group fallback/error handlers. Theme D
(routing parity) is complete after D4.
