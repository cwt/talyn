[⬅️ Back to Index](../todo.md)

# ✅ PRIORITY 1: Zig 0.16.0 Compatibility — DONE (2026-05-14)

Project now targets Zig 0.16.0 (was 0.15.2).

### 1.1–1.10: Summary

| Issue | Resolution |
|-------|-----------|
| `builtin.mode` → `.optimize` | NO CHANGE — reverted to `.mode` in 0.15.x |
| `usingnamespace` removed | Replaced with `pub const` re-exports (4 files) |
| `std.Thread.Mutex` → `std.Mutex` | NO CHANGE — still `std.Thread.Mutex` in 0.15 |
| `refAllDeclsRecursive` removed | Changed to `_ = Loop;` |
| `callconv(.C)` → `callconv(.c)` | 102 instances across 21 files |
| `addSharedLibrary` / `addTest` | Migrated to `addLibrary` + `createModule` |
| `std.ArrayList` unmanaged | 6 files: `.append(gpa, item)`, `.deinit(gpa)` |
| `empty_sigset` → `sigemptyset()` | Function instead of value |
| `sigaddset` type mismatch | Switched to `std.posix.sigaddset` |
| `.metadata()` → `.stat()` | API rename, `.size` field not method |
| `PyExc_*` C globals | `pub const` → `pub extern var` |
| jdz_allocator removed | Replaced with `std.heap.c_allocator` |
| `@cImport` no `usingnamespace` | ~100 symbols manually re-exported in `python_c.zig` |

---
