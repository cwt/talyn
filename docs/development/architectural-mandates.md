---
type: architecture_guideline
title: Architectural Mandates
description: Critical rules for development including panic handling, thread safety, and GC initialization constraints.
tags: [architecture, constraints, zig, python-c-api, thread-safety]
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Index](index.md)

# 🏗 Architectural Mandates (Rules for the Future)

1.  **NO PANICS in the IO Path:** Use `handle_zig_function_error` to convert Zig errors to Python exceptions. Never use `@panic` or `unreachable` in code that runs during the normal loop cycle.
2.  **EINTR Safety:** All `io_uring` submissions must use `IO.submit_guaranteed()`.
3.  **Thread-Safe Dispatches:** Any function that can be called from a background thread (like `call_soon_threadsafe`) must trigger the `eventfd` wakeup *only if* the loop is actually blocked.
4.  **Null Discovery:** In free-threading, GC can null out fields concurrently. Always use `?PyObject` and handle `null` gracefully in callbacks.
5.  **Initialization Order (GC Safety):** When adding items to a collection traversed by Python's GC, **ALWAYS fully initialize the data before advancing the index or linking the node.** Use `@atomicStore` with release semantics to ensure initialization is visible to GC threads.
6.  **Ring FD Guard Before Kernel Calls:** Any function touching `ring.fd`, `ring.register_files_update()`, or any io_uring registration API MUST check `ring.fd >= 0` first. During `loop.close()`, callbacks can fire after `ring.deinit()` has set fd = -1. Asserting `fd >= 0` without a guard will `SIGABRT`.
7.  **Complete Feature Fallback Paths:** When a kernel-dependent feature has a graceful-degradation flag (e.g., `fixed_files_enabled`), EVERY code path that uses the feature MUST branch on that flag. A single path that hardcodes the feature-on code (e.g., `fixed_file_index = 0` without checking `fixed_files_enabled`) will silently break when the fallback is active. Test fallback paths explicitly with `ulimit -n 1024` or `env -i`.

