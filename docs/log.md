# Chronological Update Log — Talyn Documentation Bundle

This log tracks modifications to the Talyn Documentation OKF bundle.

## [2026-07-07] — Bundle Initialization & OKF Conversion
- Converted the entire `docs/` folder into a unified OKF Bundle (Option B).
- Renamed `docs/todo.md` to `docs/index.md` to serve as the bundle's root index.
- Renamed `docs/lessons-learned.md` to `docs/lessons/index.md` to serve as the nested lessons index.
- Added OKF YAML frontmatter block to all 10 topic files in `docs/lessons/` and updated their backlink paths.
- Added OKF YAML frontmatter block to all major documentation files: `BUGS.md`, `architectural-mandates.md`, `audits-and-profiling.md`, `development-journey.md`, `hardening.md`, `reference-and-misc.md`, `talyn-migration.md`, and `talyn-naming.md`.
- Remediated all external and internal documentation link references pointing to `todo.md` and `lessons-learned.md`.
- Created `AGENTS.md` at the project root to enable AI auto-discovery of the OKF bundle.

## [2026-07-15] — BUG-117 Fix & v0.8.1 Release
- Fixed **BUG-117** (Critical): io_uring registered (fixed) buffer registration failure under `RLIMIT_MEMLOCK` pressure was previously swallowed and tore down `buffer_pool` prematurely. Replaced with a behavior-preserving graceful fallback (`buffers_registered` flag; `lease_buffer()` returns null; consumers fall back to heap buffers; `IO.deinit` keeps a single `buffer_pool.deinit`). See `docs/lessons/23-bug-117-registered-buffer-fallback-2026.md` and `docs/BUGS.md`.
- Hardened `RegisteredBufferPool.release` with an `index >= SlotCount` bounds guard and documented the `!buffers_registered ⇒ pool-full ⇒ release is a safe no-op` invariant on `IO.release_buffer`.
- Fixed the BUG-117 regression test (`tests/test_buffer_fallback.py`): it failed in the full `test_all.sh` suite because clamping `RLIMIT_MEMLOCK` in the shared pytest process also broke io_uring **ring setup** (per-process pinned-memory budget not yet reclaimed after prior loop teardowns). The scenario now runs in an isolated subprocess for a clean per-process MEMLOCK budget.
- Bumped version to **0.8.1** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — Connection-Creation Memory-Safety Fixes (BUG-118/119/120), Memory-Safety CI, & v0.8.2
- Fixed **BUG-118** (Critical, double-free): `submit_connect_for_address` freed `socket_data` twice on the connect-submit error path — a redundant explicit `allocator.destroy(socket_data)` in the `catch` alongside the top-of-function `errdefer`. Removed the duplicate free; `socket_data` is now freed exactly once, with ownership transferred to the io_uring callback chain on success. Same error class as BUG-04. See `docs/BUGS.md`.
- Fixed **BUG-119** (Critical, double-free): `connection_data` was double-freed when `z_create_socket_connection` failed after `MultiConnectState.init` but before any successful submit (the outer `errdefer` in `create_socket_connection` plus `mcs.deinit`). Made ownership single-owner — `create_socket_connection` owns `connection_data` until `mcs` takes over; a guard `errdefer` frees it only pre-handoff. Removed the outer `errdefer` double-free and captured the future handle up front. See `docs/BUGS.md`.
- Fixed **BUG-120** (Critical, use-after-free): with happy-eyeballs, the first connect freed `mcs` while the `WaitTimer` callback (`schedule_remaining_connects_callback`, `user_data == mcs`) was still pending — cancelling a `WaitTimer` still enqueues the callback (it runs on fire *or* cancel). Made the timer callback the sole teardown owner of `mcs` whenever a timer is scheduled; connect callbacks defer via a `!(timer_scheduled and !timer_fired)` guard. Mirrors BUG-115. See `docs/BUGS.md`.
- Added memory-safety regression coverage: `tests/test_connection_memory_safety.py` (subprocess-based, asserts a clean exit — no SIGSEGV/SIGABRT) for the BUG-118/119 double-free and BUG-120 UAF failure modes, plus repro drivers `tests/resources/repro_submit_fail.py` and `tests/resources/repro_uaf.py`.
- Added `scripts/memcheck.sh` ("ASAN" CI target) and `-Ddebug-alloc` (swaps `utils.gpa` for `std.heap.DebugAllocator(.{ .safety = true })`, the Zig-native double-free/leak checker — Zig 0.16 has no true AddressSanitizer) and `-Dasan` (Zig 0.16 `-fsanitize-c` / UBSan) build options, forwarded through `setup.py` (`TALYN_DEBUG_ALLOC` / `TALYN_ASAN`).
- Properly tore down the `debug_gpa` global in `utils.gpa.deinit()` under `-Ddebug-alloc` via `debug_gpa.deinitWithoutLeakChecks()` (wired through the module `m_free` path), so it is no longer leaked at process exit; no-op for production (`c_allocator`) builds.
- Bumped version to **0.8.2** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — OKF Bundle Cleanup
- Removed 16 zero-byte `docs/priorities/*.orig` backup files left over from the 2026-07-07 OKF conversion. These were empty artifacts and not valid OKF documents.
