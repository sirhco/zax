# `std.Io.Dispatch.deinit` frees a single-item pointer where `Allocator.free` requires a slice

## Zig version
`0.16.0`

## Summary

`std.Io.Dispatch.deinit` (the macOS `Io.Evented` backend) passes an array pointer, not a
slice, to `Allocator.free`. Because `main_loop_stack_size` is a comptime constant, slicing the
`[*]align(N) u8` field with two comptime-known bounds produces a `*align(N) [N]u8`
(single-item pointer, `ptr_info.size == .one`), but `Allocator.free` requires
`size == .slice`. `deinit` therefore cannot be called — referencing it is a type error.

## Location

`lib/std/Io/Dispatch.zig`:

Field (~L47):
```zig
main_loop_stack: [*]align(builtin.target.stackAlignment()) u8,
```
Constant (~L39):
```zig
const main_loop_stack_size = 8 * 1024;
```
`deinit` (~L584):
```zig
pub fn deinit(ev: *Evented) void {
    // ...
    ev.backing_allocator.free(ev.main_loop_stack[0..main_loop_stack_size]);
    // ...
}
```

`ev.main_loop_stack` is a many-item pointer (`[*]`), and `[0..main_loop_stack_size]` with both
bounds comptime-known yields `*align(N) [main_loop_stack_size]u8` — a pointer-to-array, not a
slice. `Allocator.free`'s `Slice` handling asserts the argument's `size == .slice`, which fails
for `.one`.

## Reproduction

Any program that constructs and tears down the macOS evented backend:
```zig
var ev: std.Io.Dispatch = undefined;     // std.Io.Evented on macOS
try ev.init(std.heap.page_allocator, .{});
ev.deinit();                              // type error referencing free()
```

## Expected vs actual

- **Expected:** `deinit` frees the `main_loop_stack` allocation cleanly.
- **Actual:** the `free` call's argument is a pointer-to-array, not a slice, so `deinit` is
  uncompilable as written. (It went unnoticed because long-lived programs never call `deinit`
  and let the OS reclaim on exit.)

## Suggested fix

Force a slice — e.g. give the length a runtime binding:
```zig
const len: usize = main_loop_stack_size;
ev.backing_allocator.free(ev.main_loop_stack[0..len]);
```
or reconstruct the original slice type returned by `alignedAlloc` in `init`. Either yields a
`[]align(N) u8`. (Note `init` at ~L497 allocates via `alignedAlloc` and stores `.ptr`; storing
the slice instead, or freeing with a runtime length, both resolve it.)

## Context

Found while building an evented backend prototype (blocked by the separate, larger issue that
`Io.Evented` TCP ops are unimplemented on Uring/Dispatch). This `deinit` bug is independent and
small.
