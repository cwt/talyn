# Chronological Update Log — Talyn Documentation Bundle

This log tracks modifications to the Talyn Documentation OKF bundle.

## [2026-08-11] — v0.8.8 Release: DNS Cache Poisoning Fix (BUG-131)

This patch release fixes a high-severity DNS cache poisoning bug that caused long-running asyncio web proxies to fail DNS resolution after extended operation.

- Fixed **BUG-131** (High): `mark_resolved_and_execute_user_callbacks` in `src/loop/dns/resolv.zig` previously cached empty address results (`&[]`) with infinite TTL (`maxInt(i64)`) when a DNS query returned 0 addresses (e.g. transient UDP packet loss or DNS timeout). Failed/empty lookups now call `control_data.record.discard()` to be evicted immediately. Additionally, capped default TTLs in `src/loop/dns/cache.zig` to 60 seconds instead of setting `expire_at` to infinity.
- Added regression test `test_getaddrinfo_nonexistent_domain_does_not_poison_cache` in `tests/test_getaddrinfo.py`.
- Added **Lesson 112** (*Never Cache Empty/Failed DNS Results with Infinite TTL*) to `docs/development/lessons/06-network-protocols-and-io.md`.
- Bumped version to **0.8.8** in `pyproject.toml` and `build.zig.zon`.

## [2026-08-10] — v0.8.7 Release: Zig 0.16.0 Compliance Audit Fixes & Cross-Compile Fix

This release fixes 9 bugs (BUG-122 through BUG-130) discovered by a Zig 0.16.0 compliance audit, plus restructures the entire documentation under the OKF bundle.

- Fixed **BUG-122** (Critical, 34 sites): replaced every silent `catch {}` in the codebase with `catch |err| std.log.warn(...)` (or `std.log.err` for critical callback-release paths). 14 files updated — 2 in release_ring_buffer / release_dynamic_ring_buffer (critical), 32 in teardown/cleanup paths (should have been logged).
- Fixed **BUG-123** (High): removed `@cImport` from `src/loop/unix_signals.zig`; signal() and siginterrupt() are now declared as inline `extern "c"` with SIG_DFL/SigHandler constants — no separate c_imports/ module or build.zig wiring needed.
- Fixed **BUG-124** (High): replaced 5 wrong `{}` format specifiers for error/enum values with `{t}` / `{s}` across 4 files (io/main.zig, resolv.zig, address.zig).
- Fixed **BUG-125** (High): `std.Thread.yield()` in spinlock now handles `YieldError` properly via `catch |err| std.log.warn(...)` instead of `catch {}`.
- Fixed **BUG-126** (High): replaced managed `std.AutoHashMap` with `AutoHashMapUnmanaged` + `.empty` in `child_watcher.zig` (3 call sites), matching Zig 0.16 unmanaged-container style.
- Fixed **BUG-127** (Medium): replaced `appendAssumeCapacity` with `try append(gpa, ...)` in the fixed_file_free initialization loop in `io/main.zig`.
- Fixed **BUG-128** (Medium): added default value for `-Dpython-lib` in `build.zig` so `zig build test` links against libpython without requiring explicit options. Also fixed a `{t}`→`{d}` format-specifier mismatch in `address.zig` for the `u16` family field. Subsequently removed the architecture-specific `orelse "/usr/lib64/libpython3.14.so"` default (x86_64-only path broke cross-compiles for aarch64/riscv64), restoring the pre-BUG-128 behaviour where `python_lib` is optional and passed by `setup.py` only for native builds.
- Fixed **BUG-129** (Medium): removed the `0xFFFF` heuristic guard from `py_xdecref` in `python_c.zig` — now matches `py_decref`'s unconditional `Py_DecRef` call, fixing a refcount leak for singleton objects (None, True, False).
- Fixed **BUG-130** (Low): replaced `@constCast(@ptrCast(visit))` with `@ptrCast(visit)` in 4 GC traverse paths to avoid a false const-correctness guarantee under ReleaseFast.
- **Documentation restructuring**: split monolithic `docs/BUGS.md` into 129 individual OKF-compliant bug files under `docs/development/bugs/` (001.md–130.md, skipping BUG-097). Restructured all development docs under `docs/development/` (lessons/, priorities/, architectural-mandates.md, audits-and-profiling.md, development-journey.md, hardening.md, log.md, reference-and-misc.md, talyn-migration.md, talyn-naming.md). Added OKF bundle roots with index.md + README.md symlinks. Updated all internal cross-references in docs/index.md, AGENTS.md, README.md, and all affected bug files.
- Bumped version to **0.8.7** in `pyproject.toml` and `build.zig.zon`.

## [2026-08-06] — v0.8.5 Release: Multi-Arch Linux Build/Test on x86_64, BUG-121 Fix
- Fixed **BUG-121** (High): `/etc/resolv.conf` with a lone `search .` entry (systemd-resolved stub output when no search domains are configured) crashed loop init with `RuntimeError: InvalidConfiguration`. The search-directive parser now skips a `.` root-domain entry instead of failing hostname validation. See [development/bugs/121.md](development/bugs/121.md).
- Added **native multi-architecture wheel building on x86_64**: Zig's cross-compiler now produces `aarch64` and `riscv64` wheels at full host speed (`scripts/linux/build_all_wheels.sh`, 12 wheels total). `setup.py` detects cross-compilation (skips linking the host's `libpython`, rewrites the extension SOABI suffix for the target arch), and `build.zig` defines `__riscv_float_abi_double` for riscv64 (Zig 0.16 translate-c omission).
- Added **foreign-architecture VM testing**: `scripts/linux/run_tests.sh` boots real Fedora 44 aarch64/riscv64 QEMU VMs and runs the full pytest suite against each installed wheel; `scripts/linux/run_test_all.sh` cross-compiles the extension natively and runs `test_all.sh --no-build` in the VM (~2.4x faster than an in-VM build). QEMU user-mode/containers cannot run Talyn (io_uring is `ENOSYS` under user-mode emulation).
- Improved `scripts/test_all.sh`: per-test timeouts are overridable (`TALYN_TEST_TIMEOUT`, `TALYN_STDLIB_TIMEOUT`) and a failing build no longer silently aborts the suite under `set -e`.
- Documented the full workflow in `README.md` (Fedora 44 prerequisites, build/cross-compile/test, measured timings) and [development/development-journey.md](development/development-journey.md) (v0.8.5 section).
- Bumped version to **0.8.5** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-07] — Bundle Initialization & OKF Conversion
- Converted the entire `docs/` folder into a unified OKF Bundle (Option B).
- Renamed `docs/todo.md` to `docs/index.md` to serve as the bundle's root index.
- Renamed `docs/lessons-learned.md` to `docs/lessons/index.md` to serve as the nested lessons index.
- Added OKF YAML frontmatter block to all 10 topic files in `docs/lessons/` and updated their backlink paths.
- Added OKF YAML frontmatter block to all major documentation files: `BUGS.md`, `architectural-mandates.md`, `audits-and-profiling.md`, `development-journey.md`, `hardening.md`, `reference-and-misc.md`, `talyn-migration.md`, and `talyn-naming.md`.
- Remediated all external and internal documentation link references pointing to `todo.md` and `lessons-learned.md`.
- Created `AGENTS.md` at the project root to enable AI auto-discovery of the OKF bundle.

## [2026-07-15] — BUG-117 Fix & v0.8.1 Release
- Fixed **BUG-117** (Critical): io_uring registered (fixed) buffer registration failure under `RLIMIT_MEMLOCK` pressure was previously swallowed and tore down `buffer_pool` prematurely. Replaced with a behavior-preserving graceful fallback (`buffers_registered` flag; `lease_buffer()` returns null; consumers fall back to heap buffers; `IO.deinit` keeps a single `buffer_pool.deinit`). See [development/lessons/23-bug-117-registered-buffer-fallback-2026.md](development/lessons/23-bug-117-registered-buffer-fallback-2026.md) and [development/bugs/117.md](development/bugs/117.md).
- Hardened `RegisteredBufferPool.release` with an `index >= SlotCount` bounds guard and documented the `!buffers_registered ⇒ pool-full ⇒ release is a safe no-op` invariant on `IO.release_buffer`.
- Fixed the BUG-117 regression test (`tests/test_buffer_fallback.py`): it failed in the full `test_all.sh` suite because clamping `RLIMIT_MEMLOCK` in the shared pytest process also broke io_uring **ring setup** (per-process pinned-memory budget not yet reclaimed after prior loop teardowns). The scenario now runs in an isolated subprocess for a clean per-process MEMLOCK budget.
- Bumped version to **0.8.1** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — Connection-Creation Memory-Safety Fixes (BUG-118/119/120), Memory-Safety CI, & v0.8.2
- Fixed **BUG-118** (Critical, double-free): `submit_connect_for_address` freed `socket_data` twice on the connect-submit error path — a redundant explicit `allocator.destroy(socket_data)` in the `catch` alongside the top-of-function `errdefer`. Removed the duplicate free; `socket_data` is now freed exactly once, with ownership transferred to the io_uring callback chain on success. Same error class as BUG-04. See [development/bugs/118.md](development/bugs/118.md).
- Fixed **BUG-119** (Critical, double-free): `connection_data` was double-freed when `z_create_socket_connection` failed after `MultiConnectState.init` but before any successful submit (the outer `errdefer` in `create_socket_connection` plus `mcs.deinit`). Made ownership single-owner — `create_socket_connection` owns `connection_data` until `mcs` takes over; a guard `errdefer` frees it only pre-handoff. Removed the outer `errdefer` double-free and captured the future handle up front. See [development/bugs/119.md](development/bugs/119.md).
- Fixed **BUG-120** (Critical, use-after-free): with happy-eyeballs, the first connect freed `mcs` while the `WaitTimer` callback (`schedule_remaining_connects_callback`, `user_data == mcs`) was still pending — cancelling a `WaitTimer` still enqueues the callback (it runs on fire *or* cancel). Made the timer callback the sole teardown owner of `mcs` whenever a timer is scheduled; connect callbacks defer via a `!(timer_scheduled and !timer_fired)` guard. Mirrors BUG-115. See [development/bugs/120.md](development/bugs/120.md).
- Added memory-safety regression coverage: `tests/test_connection_memory_safety.py` (subprocess-based, asserts a clean exit — no SIGSEGV/SIGABRT) for the BUG-118/119 double-free and BUG-120 UAF failure modes, plus repro drivers `tests/resources/repro_submit_fail.py` and `tests/resources/repro_uaf.py`.
- Added `scripts/memcheck.sh` ("ASAN" CI target) and `-Ddebug-alloc` (swaps `utils.gpa` for `std.heap.DebugAllocator(.{ .safety = true })`, the Zig-native double-free/leak checker — Zig 0.16 has no true AddressSanitizer) and `-Dasan` (Zig 0.16 `-fsanitize-c` / UBSan) build options, forwarded through `setup.py` (`TALYN_DEBUG_ALLOC` / `TALYN_ASAN`).
- Properly tore down the `debug_gpa` global in `utils.gpa.deinit()` under `-Ddebug-alloc` via `debug_gpa.deinitWithoutLeakChecks()` (wired through the module `m_free` path), so it is no longer leaked at process exit; no-op for production (`c_allocator`) builds.
- Bumped version to **0.8.2** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — OKF Bundle Cleanup
- Removed 16 zero-byte `docs/priorities/*.orig` backup files left over from the 2026-07-07 OKF conversion. These were empty artifacts and not valid OKF documents.
