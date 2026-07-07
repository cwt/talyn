---
type: index
title: Lessons Learned Index
description: Master index of development lessons learned during Talyn/Leviathan development.
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Index](../index.md)

# 🧠 Lessons Learned

This is the master index for all lessons learned during Leviathan/Talyn development.
Lessons have been grouped by topic for maximum readability. Each section links to a dedicated file.

> **110 lessons** documented across **10 topic areas**.

---

## Topics

| # | Topic | What's Inside |
|---|-------|---------------|
| 1 | [Memory & Reference Counting](01-memory-and-reference-counting.md) | GC traversal, `tp_traverse`, ghost cycles, use-after-free, double-free, `py_newref`/`py_decref` ownership, `allocator.create` vs struct literals |
| 2 | [Concurrency & Thread Safety](02-concurrency-and-thread-safety.md) | Atomic sleep races, recursive mutex deadlocks, TOCTOU, CAS patterns, thread-unsafe global state, syscall error handling |
| 3 | [Event Loop Lifecycle](03-event-loop-lifecycle.md) | Shutdown ordering, teardown, coroutine cleanup, EINTR resilience, fatal vs catchable exceptions, callback batching, silent failure |
| 4 | [io_uring & Kernel Interaction](04-io-uring-and-kernel.md) | Immediate vs deferred SQE submission, heap-owned buffers, `link_timeout` rollback, kernel feature gating, fd cancellation |
| 5 | [Python C API Correctness](05-python-c-api-correctness.md) | NULL return checks, `PyErr_Occurred`, context enter/exit discipline, `defer` ordering, reference stealing APIs, silent exception swallowing |
| 6 | [Network Protocols & I/O](06-network-protocols-and-io.md) | TCP lifecycle, partial writes, EMFILE backoff, SSL/TLS architecture, DNS cache races, signal handling, `connection_lost` semantics |
| 7 | [Data Structures & Algorithms](07-data-structures-and-algorithms.md) | BTree split correctness, LRU eviction callbacks, capacity edge cases, forward indexing, stack overflow from tail calls |
| 8 | [Zig-Specific Patterns](08-zig-specific-patterns.md) | Struct literals for heap types, `errdefer` discipline, LIFO defer ordering, `?T` vs `error{T}!T`, `.?` panic risk, alignment for C-struct mappings, const-folding |
| 9 | [Security & Input Validation](09-security-and-input-validation.md) | DNS transaction ID randomness & validation, DNS compression pointer bounds, IP parser strictness, ambiguous numeric format rejection |
| 10 | [Defensive Programming & Code Quality](10-defensive-programming-and-code-quality.md) | Configuration fields, hardcoded constants, float approximate equality, off-by-one fd checks, dead code, debug prints in hot paths, timeout configurability |

---

## Quick-Reference: Most Impactful Lessons

These lessons have the highest ROI — apply them on every new feature:

### 🔴 Critical (Silent Bugs, Memory Corruption)

- **GC Traversal**: Every native structure holding a `PyObject*` must appear in `tp_traverse`. Skipping even one arm causes OOM. → [Memory §Ghost References](01-memory-and-reference-counting.md)
- **In-Flight Lifecycles**: Keep Python owner objects alive via incref when queuing async tasks to prevent UAF on GC. → [Memory §Use-After-Free & Double-Free](01-memory-and-reference-counting.md)
- **Struct Init**: `allocator.create(T)` returns uninitialized memory. Field defaults are only applied by struct literals. → [Zig §Struct Initialization](08-zig-specific-patterns.md)
- **Deferred I/O Buffers**: io_uring reads input buffers at *submit time*, not queue time. Stack-allocated inputs are use-after-free. → [io_uring §Deferred Submission](04-io-uring-and-kernel.md)
- **`errdefer` Immediately**: Add `errdefer cleanup(R)` immediately after every resource acquisition. → [Zig §errdefer](08-zig-specific-patterns.md)

### 🟠 High (Races, Hangs, Deadlocks)

- **Atomic Sleep**: Check the ready queue while holding the loop mutex immediately before blocking. → [Concurrency §Atomic Sleep](02-concurrency-and-thread-safety.md)
- **Recursive Mutex**: Deinitializers and teardown code must assume the loop mutex is already held. → [Concurrency §Recursive Mutex](02-concurrency-and-thread-safety.md)
- **Teardown Order**: Drain live resources before destroying the resource they observe. → [Event Loop §Teardown Order](03-event-loop-lifecycle.md)
- **Feature Gate Completeness**: Every kernel-dependent feature gate must have a COMPLETE fallback at all call sites. → [io_uring §Kernel Feature Gating](04-io-uring-and-kernel.md)
- **Defensive Cancellation**: Condition teardown cancellation on active resource state to avoid massive syscall overhead. → [io_uring §Kernel Feature Gating](04-io-uring-and-kernel.md)

### 🟡 Medium (Correctness, Security)

- **`PyErr_Occurred`**: Check after every C API call that returns a sentinel (`PyLong_AsLong`, etc.). → [Python C API §NULL Checks](05-python-c-api-correctness.md)
- **DNS Security**: Use `getrandom` for DNS transaction IDs; validate responses against stored query IDs. → [Security §DNS](09-security-and-input-validation.md)
- **Parser Strictness**: Reject malformed input rather than zero-padding or silently accepting ambiguous formats. → [Security §Parser Strictness](09-security-and-input-validation.md)
- **Reference Ownership**: When a callee internally `py_newref`s, pass the raw borrowed reference — do not pre-incref. → [Memory §Reference Count Discipline](01-memory-and-reference-counting.md)
- **Balanced Refcounts**: Deferred decrements ensure references are balanced exactly once across all async outcomes. → [Memory §Reference Count Discipline](01-memory-and-reference-counting.md)

### 🟢 Quality (Maintainability, Observability)

- **Silent Failure**: If you detect an invariant violation, surface it loudly — never silently return. → [Defensive §Error Handling](10-defensive-programming-and-code-quality.md)
- **`else => {}`**: Bare default branches are silent bugs. Log dropped cases explicitly. → [Event Loop §Callback Semantics](03-event-loop-lifecycle.md)
- **Use Config Fields**: If a configuration field exists, use it. A field that's never read is dead code or a bug. → [Defensive §Configuration](10-defensive-programming-and-code-quality.md)
- **No Debug Prints in Hot Paths**: Any `std.debug.print` in a loop that runs millions of times/sec is a performance disaster. → [Defensive §Code Quality](10-defensive-programming-and-code-quality.md)

---

## Lesson Number Cross-Reference

For historical references to lesson numbers in commit messages or bug reports:

| Lessons | Topic File |
|---------|-----------|
| 3, 4, 7, 11, 14, 18, 25, 26, 30, 36–39, 46, 49, 50, 52, 89, 106, 107 | [Memory & Reference Counting](01-memory-and-reference-counting.md) |
| 1, 17, 21, 22, 59, 73, 74, 99 | [Concurrency & Thread Safety](02-concurrency-and-thread-safety.md) |
| 2, 5, 8, 10, 12, 19, 20, 47, 56, 57, 82, 84, 85, 86, 104 | [Event Loop Lifecycle](03-event-loop-lifecycle.md) |
| 9, 13, 24, 48, 60, 105, 108, 109, 110 | [io_uring & Kernel Interaction](04-io-uring-and-kernel.md) |
| 27, 28, 32, 35, 54, 55, 95, 97 | [Python C API Correctness](05-python-c-api-correctness.md) |
| 16, 31, 40, 41, 42, 43, 44, 45, 51, 78, 80, 81 | [Network Protocols & I/O](06-network-protocols-and-io.md) |
| 23, 53, 72, 83, 94, 100 | [Data Structures & Algorithms](07-data-structures-and-algorithms.md) |
| 6, 32, 49, 50, 54, 55, 77, 87, 88, 102, 103 | [Zig-Specific Patterns](08-zig-specific-patterns.md) |
| 29, 33, 34, 58, 91, 92, 96 | [Security & Input Validation](09-security-and-input-validation.md) |
| 57, 75, 76, 79, 82, 85, 86, 89, 90, 93, 97, 98, 101 | [Defensive Programming & Code Quality](10-defensive-programming-and-code-quality.md) |
