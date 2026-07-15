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
