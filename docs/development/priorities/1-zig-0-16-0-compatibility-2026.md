---
type: project_priority
title: "PRIORITY 1: Zig 0.15.2 & 0.16.0 Compatibility — DONE"
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# ✅ PRIORITY 1: Zig 0.15.2 & 0.16.0 Compatibility — DONE

This document details the migrations of the Talyn codebase first from Zig 0.14.x to Zig 0.15.2, and subsequently to Zig 0.16.0 in two distinct modernization phases.

---

## 1.1: Zig 0.15.2 Migration — DONE (2026-05-08)

The project first migrated from Zig 0.14.x to Zig 0.15.2 to adapt to breaking compiler changes, standard library deprecations, and type modifications.

### Summary of Changes (0.15.2)

| Issue | Resolution |
|-------|-----------|
| `usingnamespace` removed | Replaced with `pub const` re-exports (4 files) |
| `callconv(.C)` → `callconv(.c)` | 102 instances across 21 files |
| `addSharedLibrary` / `addTest` | Migrated to `addLibrary` + `createModule` |
| `std.ArrayList` unmanaged | 6 files: `.append(gpa, item)`, `.deinit(gpa)` |
| `empty_sigset` → `sigemptyset()` | Function instead of value |
| `sigaddset` type mismatch | Switched to `std.posix.sigaddset` |
| `.metadata()` → `.stat()` | API rename, `.size` field not method |
| `PyExc_*` C globals | `pub const` → `pub extern var` |
| jdz_allocator removed | Replaced with `std.heap.c_allocator` |
| `@cImport` no `usingnamespace` | ~100 symbols manually re-exported in `python_c.zig` |
| `refAllDeclsRecursive` removed | Changed to `_ = Loop;` |

---

## 1.2: Zig 0.16.0 Migration — DONE

The migration to Zig 0.16.0 was completed in two distinct steps to ensure stability followed by idiomatic refactoring.

### Phase 1: Compiler & Syscall Migration — DONE (2026-05-14)

Initial migration focused on compiler support and basic API transitions.

| Issue | Resolution |
|-------|-----------|
| `std.posix.*` raw wrappers | Replaced with raw `std.os.linux.*` syscall wrappers |
| `std.net.Address` change | Replaced with custom `utils.Address` extern union |
| `std.atomic.Mutex` | Replaced with SpinMutex wrapper |
| `std.crypto.random` deprecation | Switched to `std.Random.DefaultPrng` and `std.os.linux.getrandom` |
| ArrayList/ArrayListUnmanaged init | Fixed syntax to fit 0.16.0 specifications |
| BTree key type | Fixed key type from SIG enum to `u6` |
| Syscall API signatures | Adjusted `clock_gettime`, `waitid`, `getsockopt` parameters |
| Optional-capture if-expressions | Replaced block-as-expression with `blk:` labeled blocks |

### Phase 2: ArrayList & Modernization Best Practices — DONE (2026-07-06)

Subsequent cleanup for modern, idiomatic Zig 0.16.0 patterns.

| Issue | Resolution |
|-------|-----------|
| `ArrayListUnmanaged` refactor | Refactored to `ArrayList` to simplify allocator routing |
| `.empty` initialization | Transitioned to modern `.empty` initializers for best practices |
