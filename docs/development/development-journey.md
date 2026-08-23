---
type: article
title: Talyn Development Journey
description: The complete historical narrative and timeline of developing Talyn, sorted chronologically from the latest release back to the project's inception.
tags: [history, documentation, journey, roadmap]
timestamp: 2026-08-23T00:00:00Z
---

# Talyn Development Journey

Talyn is a production-grade, crash-resistant, and realistically fast `asyncio` event loop drop-in replacement for Python, powered by **Zig** and **io_uring**. 

This document chronicles the engineering narrative and technical milestones of Talyn in **reverse chronological order**—starting with our latest release and architectural breakthroughs, and stepping back through performance optimizations, cross-platform builds, and deep audits to the project's original genesis.

---

## v0.9.3 — Full-Codebase Audit (BUG-269..302), Task Constructor Contract Rewrite & Zero Open Bugs

**v0.9.3** is the "drive it to zero" release: a fresh full-codebase audit produced 34 new findings (BUG-269 through BUG-302), every one of them fixed and regression-tested one commit at a time, plus two more bugs (**BUG-303**, **BUG-304**) discovered *by* those fixes while running CPython's `test_base_events` directly. The tracker now stands at **303 bugs (290 Fixed, 0 Open, 13 False Positive)**, with the full suite green on all four runtime targets (3.13, 3.14, 3.13t, 3.14t) and benchmarks confirming no performance regressions.

### 1. Eliminating Deterministic Heap Corruption

The audit's critical findings were all ownership-lifecycle defects, and they fell to a consistent toolkit:

- **Dual-errdefer double-free in DNS `prepare_data`** ([BUG-269](bugs/269.md)): an early `errdefer allocator.destroy(control_data)` stayed armed alongside a later `errdefer control_data.release()` whose final statement destroys the struct — any error path freed `ControlData` twice, deterministically reachable via hostnames whose search candidates exceed the 255-byte DNS wire limit. Fixed with single-owner cleanup.
- **Ownership-transfer vs. armed errdefers**: datagram `sendto` ([BUG-270](bugs/270.md)) and `perform_with_iovecs` ([BUG-272](bugs/272.md)) both transferred buffer ownership into pending io_uring operations while local `errdefer free(...)` calls stayed armed — a failing `pause_writing` callback or SQ-full submission then freed buffers the kernel was still reading, and `BlockingTask.discard()` freed them again. Both now use an explicit ownership-transfer flag so errdefers stand down exactly when ownership moves.
- **Fatal-signal exception freed under the interpreter** ([BUG-271](bugs/271.md)): `failed_execution`'s SystemExit/KeyboardInterrupt branch decref'd the raised exception twice (manual + errdefer), freeing it while installed as the thread state's current exception — Ctrl+C in any task hit this. Replaced scattered manual releases with one unconditional scope-exit defer, which also closed the arm-level leaks ([BUG-292](bugs/292.md)).
- **Task executor contract violations** ([BUG-273](bugs/273.md), [BUG-293](bugs/293.md)): the send/throw wrappers released their dispatch-owned task reference on error exits even though the executor's cleanup already does — and the trampolines' unconditional exception-restore could clear the error indicator entirely, steering execution into exactly those paths.
- **WriteTransport resurrecting cancelled writes** ([BUG-275](bugs/275.md)): per-op `.CANCELED` completions fall through to resubmission because the CallbackData `cancelled()` bit is only set by shutdown; after `force_close` that meant writing via a stale fd or a recycled fixed-file slot. Also fixed the flush-ordering duplicate-write window ([BUG-281](bugs/281.md)).

### 2. The `test_base_events` Breakthrough — BUG-303 & BUG-304

Running CPython's excluded `test_base_events` module directly surfaced a hard segfault: `create_task` on a **closed loop** pushed its start callback into a deinitialized ready ring ([BUG-303](bugs/303.md)). Adding the missing `loop_data.initialized` guard then exposed something bigger — **BUG-304**, an implicit "consume-on-success" ownership contract in `fast_new_task`: `task_init_configuration` stores coro/context/name as borrowed pointers while instance dealloc decrefs every PyObject field, so *any* failure after the store made callers' errdefers and the dealloc double-free all three. The fix establishes explicit borrow semantics (internal increfs + caller-side success releases) across `fast_new_task`, `z_loop_create_task`, and the asyncgen hook path — eliminating an entire class of latent constructor double-frees.

### 3. Lifecycle, Registry & Protocol Correctness

- **Loop teardown ordering**: cancelled watcher completions dispatched after B-tree deinit no longer traverse freed trees ([BUG-274](bugs/274.md)); the ready ring now grows instead of dropping whole completion batches with skewed accounting ([BUG-282](bugs/282.md)).
- **Watcher safety under re-entry**: inotify dispatch snapshots and re-validates watchers around arbitrary Python callbacks that may add/remove watches mid-batch ([BUG-278](bugs/278.md)); static ring-buffer publish order now matches the dynamic variant so concurrent GC cannot skip live callbacks ([BUG-289](bugs/289.md)); `Cancel.perform` reads poisoned (not undefined) operation fields for stale ids ([BUG-290](bugs/290.md)).
- **Child watcher lifecycle**: duplicate-pid registration fully tears down the replaced handler ([BUG-277](bugs/277.md)) and removal defers destruction to the handler's own queued invocation instead of freeing it out from under it ([BUG-280](bugs/280.md)).
- **Registry hygiene**: tasks completing by exception or cancellation are now discarded from `_asyncio_tasks` like result-completed ones — ending a strong-ref accumulation on long-running servers ([BUG-279](bugs/279.md)) — which incidentally un-confounded exact refcount assertions elsewhere.
- **Protocol strictness**: IPv6 literals with more than eight groups (or a swallowed trailing colon) are rejected instead of silently parsing as a different address ([BUG-288](bugs/288.md)), matching `inet_pton`.
- **Constructor resource leaks** closed across datagram ([BUG-283](bugs/283.md)), stream ([BUG-284](bugs/284.md)), and subprocess ([BUG-285](bugs/285.md))) transports, plus an idempotent `PseudoSocket.close()` ([BUG-291](bugs/291.md)).

### 4. Abstract UNIX Sockets, End to End

[BUG-287](bugs/287.md) turned out to be three defects in one subsystem: AF_UNIX conversions spanned `sun_path` as a NUL-terminated C string (out-of-bounds on fully-filled paths, empty string for abstract sockets); `Address.toPyAddr` lacked bounds entirely; and — fatally for abstract namespaces — `getOsSockLen()` returned `sizeof(sockaddr_un)`, so connect appended trailing NULs where the kernel compares exactly `addrlen` bytes. With CPython-compatible length computation wired through the unix connect SQE, abstract-namespace sockets (`"\0name"`) now work end-to-end, verified by a new round-trip test.

### 5. Validation

Every fix landed with its own regression test (Zig unit tests or Python crash-guard subprocesses, per failure mode) behind the full gate: `./scripts/test_all.sh --starburst --verbose` passes on **python3.13, python3.14, python3.13t, and python3.14t** (337 pytest cases each + stdlib asyncio subset + 61 Zig unit tests). Post-fix benchmarks show no regressions — Talyn still leads uvloop on TCP Echo (up to 2.74x), Unix Echo (3.08x), UDP Ping-Pong (3.72x), and Socket Ops (3.33x) versus stock asyncio, with Chat scaling to 1.44x at high load.

## v0.9.2 — BUG-261..268 Fixes & CPython 3.14.7 free-threading Compatibility

**v0.9.2** fixes all six renumbered real bugs from the BUG-261..272 validation pass and restores full compatibility with the CPython 3.14.7 stdlib test suite. The highlight is deep work on **threading semantics**: a fresh io_uring ring can now be handed to a different thread, so `loop.run_forever()` in a background thread — a documented asyncio pattern newly exercised by the gh-152020 stdlib test — works instead of failing with `EEXIST → error.InvalidThread` and hanging `run_coroutine_threadsafe().result()` callers (BUG-267). Talyn tasks are also now visible to `asyncio.all_tasks()`/`current_task()` by registering in both the C and pure-Python task registries and keeping both current-task registries in sync across Python 3.13's shared-dict and 3.14's separate-registry designs (BUG-268).

This release also closes the fd leak in the DNS `queue` error path (BUG-261), the negative `dns_timeout` sentinel ambiguity (BUG-263), the `getsockopt` stale-exception leak (BUG-264), and the `queries[0]` out-of-bounds panic on over-long hostnames (BUG-266), plus two maintainability cleanups (BUG-262, BUG-265). The tracker stands at **267 bugs (250 Fixed, 4 Open, 13 False Positive)** with the full suite passing on all four Python runtime targets (3.13, 3.14, 3.13t, 3.14t), including `test.test_asyncio.test_free_threading`.

## v0.9.0 — Native Offline AST Linter, Audit Passes 15–19 (BUG-200..259) & Complete Production Hardening

With the release of **v0.9.0**, Talyn introduces an advanced, zero-dependency **Native Offline AST Linter & Bug Hunter** directly integrated into the build pipeline, along with resolving 60 bugs across audit passes 15 through 19 (BUG-200 through BUG-259). This milestone brings the total tracked bug count to **258 bugs (245 Fixed, 13 False Positive, 0 Open)** with 100% test suite passing across all four Python runtime targets (3.13, 3.14, 3.13t, 3.14t).

### 1. Native Offline AST Linter & Bug Hunter (`zig build lint`)

After analyzing hundreds of bugs fixed throughout the project's evolution, we recognized that domain-specific bugs—such as uninitialized `?PyObject` fields after `tp_alloc`, missing `errdefer py_decref` handlers on error paths, panics in the I/O event loop, discarded syscall return values, and unhandled switch variants—are **100% syntactically valid code** to standard Zig and C compilers.

To permanently eradicate these classes of bugs without relying on runtime crashes or expensive AI review loops, we created a custom, native static analysis tool:
- **Direct AST Hooking**: Operates directly on the native Zig AST via **`std.zig.Ast`** and Python's standard **`ast`** module (`tools/linter/`).
- **Blazing Performance**: Scans over 100 Zig files (76,000+ AST nodes) and Python files in **under 15 milliseconds** with zero external dependencies.
- **Enforced Invariant Rules**:
  - **Zig AST Rules (`TALYN-001`–`TALYN-011`)**: Prohibits `@cImport` ([BUG-123](bugs/123.md)), bans `@panic` in I/O loop paths ([BUG-105](bugs/105.md), [BUG-188](bugs/188.md)), forbids empty `catch {}` blocks ([BUG-122](bugs/122.md)), enforces unmanaged container conventions ([BUG-126](bugs/126.md)), catches bare `else => {}` in switch statements ([BUG-096](bugs/096.md)), guards against discarded syscall return values ([BUG-190](bugs/190.md)), verifies `tp_clear` on all GC types ([BUG-155](bugs/155.md)), requires explicit `errdefer py_decref` after `fast_new_future` ([BUG-187](bugs/187.md), [BUG-203](bugs/203.md)), mandates explicit field initialization on struct allocation ([BUG-204](bugs/204.md), [BUG-253](bugs/253.md)), and validates complete keyword argument parsing ([BUG-189](bugs/189.md), [BUG-205](bugs/205.md)).
  - **Python AST Rules (`TALYN-PY01`–`TALYN-PY02`)**: Enforces explicit named `def` functions over `lambda` expressions for clean stack traces and prevents silent bare `except: pass` blocks.
- **Continuous Integration Guard**: Hooked automatically into `./scripts/test_all.sh` and `zig build lint` as a mandatory pre-commit check.

For the full catalog of rules and architecture, see [docs/development/ast-linter.md](ast-linter.md).

### 2. Audit Passes 15–19 & Hardening Fixes (BUG-200..259)

A comprehensive series of five deep audit passes scrutinized the codebase for subtle memory management, lifecycle, and network safety edge cases:

1. **PyObject Lifecycle & Reference Counting Hardening**:
   - Guaranteed owned references when throwing into generator tasks via `_execute_task_throw` ([BUG-254](bugs/254.md)) and decref'd owned exception references on generic failure paths in `failed_execution` ([BUG-255](bugs/255.md)).
   - Fixed missing `errdefer py_decref` on future creation failure branches ([BUG-203](bugs/203.md), [BUG-209](bugs/209.md)) and ensured all `?PyObject` fields are explicitly initialized after `tp_alloc` ([BUG-204](bugs/204.md), [BUG-253](bugs/253.md)).
2. **Garbage Collection Correctness & Cycle Elimination**:
   - Resolved the loop hook GC traversal gap by attaching `python_payload` to `HookHandle` and registering hooks via `CallbackData.init_python`, ensuring hook callbacks participate in GC traversal and cycle collection ([BUG-259](bugs/259.md)).
   - Implemented proper `tp_clear` and GC un-tracking sequences across handle types ([BUG-208](bugs/208.md)).
3. **Transport & Buffer Pool Safety**:
   - Deferred datagram receive buffer cleanup to object deallocation (`datagram_dealloc`/`datagram_clear`), preventing use-after-free and buffer pool corruption while `io_uring` read completions are in-flight ([BUG-256](bugs/256.md)).
   - Fixed unparsed keyword arguments in stream server constructors ([BUG-205](bugs/205.md)) and write transport buffer lifecycle transitions.
4. **Syscall & Network Protocol Correctness**:
   - Added in-loop octet range checks in `parseIp4` to prevent `u16` accumulator overflow and enforce rejection of octets > 255 across all build modes ([BUG-257](bugs/257.md)).
   - Capped DNS cache TTL to `MAX_DNS_TTL` (7 days) for near-max and overflowing TTL records ([BUG-258](bugs/258.md)).

---

## v0.8.9 — Codebase Hardening, Audit Passes 9–14 & Comprehensive Stability Fixes

With the release of **v0.8.9**, a comprehensive series of deep codebase audits across passes 9 through 14 surfaced and resolved 68 bugs (BUG-132 through BUG-199). This milestone brought the total tracked bug count to **198 bugs (195 Fixed, 3 False Positive, 0 Open)** with 100% test suite passing.

Key hardening and stability accomplishments include:

1. **Complete PyObject & Memory Leak Elimination**:
   - Fixed PyObject reference leaks during batch protocol reads ([BUG-162](bugs/162.md)), task waking and cancellations ([BUG-144](bugs/144.md), [BUG-174](bugs/174.md), [BUG-198](bugs/198.md)), write/read transport error paths ([BUG-143](bugs/143.md), [BUG-169](bugs/169.md)), and loop keyword argument parsing ([BUG-189](bugs/189.md)).
   - Fixed memory leaks in synchronous DNS lookups ([BUG-166](bugs/166.md)) and LRU cache insertion errors ([BUG-148](bugs/148.md)).

2. **Subprocess, File Descriptor & IO Safety**:
   - Guaranteed `pidfd` descriptor closure and transport decref on protocol callback failures ([BUG-196](bugs/196.md)).
   - Prevented socket double-close hazards on `connection_made` exceptions across stream and datagram transports ([BUG-186](bugs/186.md)).
   - Connected missing `.cleanup` function pointers on IO queues to guarantee resource drainage during loop shutdown ([BUG-175](bugs/175.md)).

3. **Task & Future Concurrency Hardening**:
   - Implemented task throw trampolines guaranteeing `leave_task_func` is always executed whenever `enter_task_func` succeeds, preserving `asyncio.current_task(loop)` invariants even on throw errors ([BUG-197](bugs/197.md)).
   - Prevented `remove_done_callback` from recounting already-cancelled or executed callbacks ([BUG-195](bugs/195.md)).
   - Normalized nanoseconds in `call_later` to eliminate kernel `-EINVAL` timer submission errors ([BUG-185](bugs/185.md)).

4. **Linux Syscall & Defensive Hardening**:
   - Verified `std.posix.errno` on `getsockname` syscall returns across datagram transports and pseudo-sockets to prevent reading uninitialized stack memory ([BUG-190](bugs/190.md), [BUG-199](bugs/199.md)).
   - Implemented `tp_clear` for `HookHandleType` and `PathWatcherHandleType` ([BUG-193](bugs/193.md)) and fixed nested GC traversals in Unix signals and DNS resolver ([BUG-173](bugs/173.md), [BUG-192](bugs/192.md)).

---

## v0.8.7 — Zig 0.16.0 Compliance Audit Fixes & Cross-Compile Fix

With the release of **v0.8.7**, a full Zig 0.16.0 compliance audit surfaced 9 bugs (BUG-122 through BUG-130) that were all fixed in this patch release. The audit focused on Rule 6 (no silent `catch {}`), Rule 7 (no `@cImport`), Rule 9 (proper format specifiers), and Rule 4 (unmanaged containers). Additionally, the entire documentation was restructured under the Open Knowledge Format (OKF v0.1) as `docs/development/`, with all 129 bugs split into individual well-formed files.

This release also fixed a cross-compilation breakage introduced during the BUG-128 fix: the hardcoded default `orelse "/usr/lib64/libpython3.14.so"` for the `-Dpython-lib` option caused `ld.lld` to reject the x86_64-only library when cross-compiling for aarch64/riscv64 ("incompatible with aarch64linux"). The fix removed the default so `python_lib` is `null` on cross-compiles, where Linux CPython extensions resolve the C API at runtime without linking libpython.

1. **BUG-122 — 34 silent `catch {}` replaced with logging** (Critical): The two most dangerous were in `release_ring_buffer` and `release_dynamic_ring_buffer` where callback errors were swallowed. The remaining 32 were in teardown paths where at minimum `std.log.warn` makes them visible at runtime.
2. **BUG-123 — `@cImport` removed from unix_signals.zig** (High): `signal()` and `siginterrupt()` are now declared as inline `extern "c"` with `SIG_DFL`/`SigHandler` constants — no separate c_imports/ module needed.
3. **BUG-124 — 5 wrong format specifiers fixed** (High): `{}` → `{t}` for errors/enums, `{}` → `{s}` for `@tagName()` strings across 4 files.
4. **BUG-125 — `std.Thread.yield()` error handled** (High): spinlock now logs yield failures instead of silently swallowing them.
5. **BUG-126 — `AutoHashMap` → `AutoHashMapUnmanaged`** (High): `child_watcher.zig` now uses the 0.16 unmanaged container style (`.empty` + explicit gpa).
6. **BUG-127 — `appendAssumeCapacity` → `try append`** (Medium): `fixed_file_free` init loop now matches unmanaged container conventions.
7. **BUG-128 — test linking fixed** (Medium): `build.zig` now defaults `-Dpython-lib` so `zig build test` links libpython without explicit options. The architecture-specific `orelse` default was later removed to fix a cross-compile breakage.
8. **BUG-129 — `py_xdecref` heuristic removed** (Medium): singleton objects (`None`/`True`/`False`) no longer leak refcounts through the optional decref path.
9. **BUG-130 — `@constCast` removed from GC traverse paths** (Low): 4 traverse methods now use plain `@ptrCast` to avoid false const-correctness under `ReleaseFast`.
10. **OKF documentation restructure**: 129 individual bug files under `docs/development/bugs/`, lessons and priorities organized as OKF bundles with `index.md` + symlinks.

---

## v0.8.5 — Native Multi-Arch Builds, Foreign-Arch VM Testing & A Portability Fix

With the release of **v0.8.5**, we removed the last dependency on Apple Silicon for publishing and expanded verified platform coverage to three CPU architectures, all from the x86_64 development PC:

1. **Native Multi-Architecture Wheel Building (Zig Cross-Compiler)**:
   Previously, building `aarch64` (and emulated `x86_64`) wheels required Podman on a Mac. Because Talyn's native extension is built by Zig — a native cross-compiler — v0.8.5 builds **x86_64, aarch64 and riscv64** wheels directly on the Intel PC at full host speed, with no QEMU involved (`scripts/linux/build_all_wheels.sh`, 12 wheels: 4 Python variants × 3 architectures). This required:
   - `setup.py` cross-build detection: when the Zig target differs from the running host, the host's `libpython` (wrong ELF architecture) is not linked — Linux CPython extension modules resolve the C API at import time — and the extension SOABI suffix is rewritten to the *guest* architecture so the wheel imports on the target machine.
   - `build.zig`: define `__riscv_float_abi_double` for riscv64, working around a Zig 0.16 translate-c omission that otherwise breaks glibc's riscv `bits/setjmp.h` (`unsupported FLEN`). riscv64 wheels are pinned to the `rv64gc` baseline (`generic_rv64+m+a+f+d+c` = RV64IMAFDC), the de facto minimum for RISC-V Linux userspace.
2. **Foreign-Architecture VM Testing (Full-System QEMU)**:
   QEMU **user-mode** emulation (e.g. `podman run --platform linux/arm64`) cannot run Talyn: `io_uring_setup` returns `ENOSYS` under user-mode emulation and Talyn requires `io_uring` with no fallback. So v0.8.5 boots real **full-system Fedora 44 VMs** per architecture, whose guest kernel passes `io_uring` through to the host. `scripts/linux/run_tests.sh` runs the full pytest suite against each wheel; `scripts/linux/run_test_all.sh` cross-compiles the extension natively and runs the entire `test_all.sh` suite with `--no-build` (about **2.4x faster** than compiling in the VM). The full `--starburst` suite passes on all three architectures.
3. **Portability Bug Fix (BUG-121)**:
   Foreign-arch VM validation surfaced a latent bug: a `/etc/resolv.conf` containing a lone `search .` (the systemd-resolved stub output when no search domains are configured) crashed loop init with `error.InvalidConfiguration`. The DNS parser now treats `.` as the root domain (no search suffix) instead of rejecting it.
4. **Test Infrastructure Hardening**:
   `test_all.sh` per-test timeouts are now overridable (`TALYN_TEST_TIMEOUT`, `TALYN_STDLIB_TIMEOUT`) for slow emulated environments, and a failing Zig build no longer silently aborts the whole suite under `set -e`.

---

## v0.8.0 — Security Hardening & 100% Pure Zig (C Elimination)

With the release of **v0.8.0**, we transitioned the runtime into a production-grade, hardened environment, while achieving a major codebase milestone: **eliminating all C source code** to make Talyn a 100% pure Zig project.

1. **Security Hardening Mitigations (HARD Plan)**:
   Operating directly on `io_uring` kernel queues requires strict defense-in-depth parameters. We implemented several critical security mitigations:
   - **Kernel Version Guard (HARD-01)**: Enforced runtime checks on startup requiring Linux Kernel `>= 5.11`, blocking execution on older, vulnerable kernels.
   - **Buffer Pool Overflow Protection (HARD-04)**: Integrated buffer boundary sentinel validation to detect and prevent kernel-to-user memory corruption.
   - **Fixed File Descriptor Boundary Checks (HARD-05)**: Added strict validation boundaries to ensure user-space requests never exceed allocated descriptor limits.
   - **Automated CVE Monitoring (HARD-06)**: Integrated automated tracking for kernel-level `io_uring` CVE reports.
2. **100% Pure Zig Architecture (C Code Elimination)**:
   Historically, the codebase linked external C helper objects (`pyatomic_stubs.c` and `trampoline.c`) to satisfy atomic definitions and coordinate the scheduler context. In v0.8.0, we rewrote these helpers in pure Zig:
   - Atomic stubs were replaced by native Zig `@atomicLoad` wrappers utilizing the `.monotonic` C-ABI standard calling convention.
   - The fused trampoline sequence was implemented natively in [`callbacks.zig`](../../src/task/callbacks.zig), employing block-level `defer` for context exit safety and safe optional capture syntax (`if (optional) |x|`) to completely eliminate the risk of panics in the hot path.
   - Removing the C files decoupled the compilation pipeline from C source dependencies, enabling clean native compilation and inlining optimizations across modules.
3. **Critical Stability & Leak Fixes**:
   Additionally, we resolved major resource leaks and correctness bugs: plugging descriptor leaks in `signalfd`/`pidfd`, correcting DNS queue and memory allocations, and fixing poll storms in level-triggered watchers.

---

## v0.7.0 — macOS Apple Silicon Dev Suite, AARCH64 Alignment & Link-Time Optimization (LTO)

With the release of **v0.7.0**, we focused on broadening developer access, making the codebase cross-platform compile-friendly, and adopting advanced link-time optimizations:

1. **macOS Apple Silicon & Podman Dev Suite**:
   Because Talyn relies on Linux-specific `io_uring` kernel primitives, it cannot run directly on the macOS/XNU kernel or BSD-based stack. To support developers on Apple Silicon, we reorganized containerized tooling into `scripts/macos/`. This suite leverages Podman/Podman-machine and Apple's Hypervisor.framework to run a full Linux kernel (Fedora 44) virtualized on macOS.
2. **Multi-Architecture Wheel Compilation**:
   We added `build_all_wheels.sh` (macOS), which compiled both native `aarch64` and emulated `x86_64` wheels in a single command on Apple Silicon using Podman.
3. **Strict AARCH64 Alignment & Compiler Fixes**:
   Compiling for `aarch64` Linux exposed strict memory alignment constraints that do not exist on `x86_64`. We resolved compiler faults by introducing `@alignCast` to pointer casts across all core Zig modules and pinned `aarch64` targets to a `generic` CPU configuration.
4. **Link-Time Optimization (ThinLTO)**:
   To squeeze out extra performance, we configured ThinLTO (`lib.lto = .thin`) and section garbage collection (`lib.link_gc_sections = true`) for all release builds.

These improvements yielded impressive outcomes across three targeted hardware profiles:
* **Intel Core Ultra 7 265**: Socket Ops reached a peak speedup of **3.47x** over standard `asyncio`, outpacing `uvloop` (**3.05x**). Free-threaded (Python 3.14t) task spawning also saw a clean **2.10x** improvement.
* **Macbook Neo (ARM64)**: Socket Ops ran **2.57x** faster than asyncio under the GIL, and **2.66x** faster in free-threaded mode.
* **Intel Celeron N6000**: Edge scaling remained solid, delivering a **2.62x** Socket Ops speedup and dropping coroutine execution times by up to 55%.

For the complete breakdown of results, see [BENCHMARKS-v0.7.0.md](../benchmarks/BENCHMARKS-v0.7.0.md).

---

## v0.6.4 — Deep Audit, Model Swarms & The Socket Ops Leap

After the release of **v0.6.3**, we instructed our coding agents to conduct a deep, comprehensive audit of the entire codebase to identify and fix any patterns that violated our accumulated [lessons/index.md](lessons/index.md). 

During this phase, we established a highly effective multi-model workflow:
1. **Bug Hunting**: We deployed expensive, high-reasoning models (with large thinking quotas) to scrutinize the code, identify subtle bugs, and document their findings in meticulous detail in the bug tracker.
2. **Bug Fixing**: We then passed these detailed specifications to cheaper, faster models to execute the fixes quickly and precisely.

This audit successfully resolved several critical reference-counting issues, double-frees, ghost reference cycles, and potential use-after-free bugs (including BUG-108 through BUG-115).

However, this rigorous application of defensive programming introduced a severe regression on the **Socket Ops** benchmark. We traced the slowdown to a defensive cancellation mechanism (BUG-116)—unconditional `CancelByFd` calls and queue flushes executing on every socket close. By optimizing the teardown sequence to bypass `CancelByFd` when no reads or writes are pending, we removed the system call overhead entirely. 

The result was a stunning breakthrough: Socket Ops performance didn't just recover—it leaped to its highest benchmark scores yet, proving that correctness and extreme performance can go hand-in-hand. Detailed benchmark logs: [Intel Core Ultra 7 265 (Python 3.14 Starburst)](../benchmarks/core-ultra-7-265/benchmarks-v0.6.4-3.14-starburst.txt).

---

## v0.6.1 — Starburst Mode for Binary Packages

With the release of **v0.6.1**, we decided, based on our benchmark outcomes and comprehensive testing (including passing 100% of the standard `asyncio` test suite across four distinct Python interpreters), that it was safe to publish official binary packages (wheels) with **Starburst mode** (Zig code built with `ReleaseFast`) enabled by default.

Through meticulous optimization of struct layouts and memory boundaries, we resolved the alignment and race-condition concerns that previously made aggressive compile-time optimizations unstable. We could now deliver maximum throughput safely to all end-users.

---

## v0.6.0 — Performance & Stability: Unlocking ReleaseFast

With **v0.5.0** fully stable in `ReleaseSafe` mode, we turned our attention to the final barrier: **`ReleaseFast`** optimizations. For a long time, the project suffered from regressions when compiled with `ReleaseFast`—specifically failing standard Python AsyncIO test suites (`test_streams`). 

Through rigorous investigation, we uncovered three core compiler and optimization-related issues that only surfaced under the aggressive code reordering of `ReleaseFast`:
1. **Strict C-Struct Memory Alignment**: The LLVM optimizer vectorized memory operations aggressively. Structs matching Python C-mappings (such as `FutureObject.data`) lacked explicit alignment declarations, causing memory faults during vectorized operations.
2. **Aggressive Const-Folding**: Essential type descriptors (like `loop_spec`) were folded away as compile-time constants by the optimizer, losing runtime type check guarantees.
3. **Shutdown Re-Arming Races**: By removing asynchronous queuing (`IOSQE_ASYNC`) to maximize speed, active event watchers (like test readers) registered synchronously and re-armed themselves instantly, creating an infinite loop during stopping iterations.

By correcting alignments, declaring type specs as mutable `var` instances to prevent folding, and adhering to strict Python AsyncIO stop semantics (exiting at the end of the iteration), we fully resolved all `ReleaseFast` stability bugs. 

Consequently, we updated **Starburst mode (`--starburst`) to point to `ReleaseFast` by default** and added a `--safe` flag for `ReleaseSafe`. The results spoke for themselves, delivering massive performance gains—such as doubling throughput on **TCP Echo** and turning a **Socket Ops** deficit into a victory over standard `asyncio`—all while maintaining 100% test suite passing.

Benchmark logs:
- **Intel Core Ultra 7 265**: Python 3.14 [Debug](../benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-debug.txt) | [Safe](../benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-safe.txt) | [Starburst (ReleaseFast)](../benchmarks/core-ultra-7-265/benchmarks-v0.6.0-3.14-starburst.txt)
- **Intel N6000**: Python 3.14 [Debug](../benchmarks/n6000/benchmarks-v0.6.0-3.14-debug.txt) | [Safe](../benchmarks/n6000/benchmarks-v0.6.0-3.14-safe.txt) | [Starburst (ReleaseFast)](../benchmarks/n6000/benchmarks-v0.6.0-3.14-starburst.txt)

---

## v0.5.0 — The N6000 Stress Testing Breakthrough & ReleaseSafe Hardening

As of changeset 566, our preliminary benchmark results on Python [3.14](../benchmarks/core-ultra-7-265/benchmarks-566-3.14.txt) and [3.14t](../benchmarks/core-ultra-7-265/benchmarks-566-3.14t.txt) were promising. But there was a massive catch: those benchmarks were run on a **Debug** build!

When compiling a **ReleaseSafe** build, everything broke. The optimized build exposed severe, hidden concurrency bugs, especially under free-threading. We tried to isolate the bugs by compiling only the `io` module in `Debug` mode while keeping the rest of the modules in `ReleaseSafe`. While this hybrid approach worked for a time, it was not 100% stable under high stress. 

At that point, we suspected that our primary development machine (an Intel Core Ultra 7 265) was simply too fast—its quick core switching effectively masked real, subtle race conditions and timing-dependent deadlocks. 

To flush these bugs out, we switched development to a mini PC powered by a much slower Intel N6000 CPU. The resource-constrained processor immediately exposed the race conditions, deadlocks, and scheduling issues. Days of debugging and iterating on this mini PC resolved every single crash, hang, and deadlock, finally delivering a rock-solid **v0.5.0**.

Key benchmark findings for v0.5.0 ([Python 3.14](../benchmarks/n6000/benchmarks-v0.5.0-3.14.txt) | [Python 3.14t](../benchmarks/n6000/benchmarks-v0.5.0-3.14t.txt)):
- Talyn performed very close to standard `asyncio` across real-world workloads (Chat, Food Delivery, Subprocess).
- Exceptional scaling and stability on free-threaded Python (3.14t) under high concurrency.
- Maintained solid ground behind `uvloop` while providing a viable, stable alternative for free-threading.

---

## Genesis & Origins — From Leviathan Fork to Production Reality

I have been obsessed with Python's AsyncIO for many years, building projects like [ananta](https://github.com/cwt/ananta), [aiosyslogd](https://github.com/cwt/aiosyslogd), and [wormhole](https://github.com/cwt/wormhole).

One day, I asked Gemini to research AsyncIO equivalents in other languages. The report highlighted how promising Zig + `io_uring` could be. When I asked why no one had built an event loop using Zig and `io_uring` similar to `uvloop`, Gemini pointed me to the [original Leviathan project](https://github.com/kython28/leviathan).

Leviathan was incomplete and had been inactive for about a year. That’s when the idea formed: *“We’re in the AI coding era — why don’t I try to complete it myself?”*

And so the fork began:
1. **The Feature Mapping Phase**: We cloned the [uvloop repository](https://github.com/MagicStack/uvloop) and had AI agents analyze missing features to build the initial TODO list.
2. **The Golden Rule**: To prevent hallucinations and enforce quality, we established `scripts/test_all.sh` targeting 4 Python interpreters (3.13, 3.14, 3.13t, 3.14t) with a strict mandate: **zero errors and zero warnings**.
3. **The Brutal Reality of the Standard Test Suite**: When we hooked up the official Python AsyncIO test suite, everything broke. We spent weeks debugging deep edge cases, creating the foundation of [docs/development/lessons/index.md](lessons/index.md).
4. **The TLS/SSL Perma-Bug Breakthrough**: We hit a stubborn bug in `test_streams` ([Priority 20](priorities/20-tls-ssl-completion-2026-05.md)) that caused repeated crashes and hangs for weeks. Refusing to skip tests, we switched to `antigravity-cli` with Gemini 3.5 flash (max thinking quota) running overnight. The breakthrough finally arrived, and all tests passed.
5. **The Philosophy Shift**: Early benchmarks revealed that chasing artificial micro-benchmark records at the cost of stability was a dead end. Talyn pivoted to become a **realistic fast and stable** alternative—prioritizing correctness, memory safety, and production readiness above all else.

---

This project has been a long, humbling, and incredibly rewarding journey. From an inactive, crash-prone prototype to a stable, fully test-suite-passing event loop backed by native AST static analysis and a swarm of AI agents.

And that’s how Talyn came to life.
