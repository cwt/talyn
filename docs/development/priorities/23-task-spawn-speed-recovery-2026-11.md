---
type: project_priority
title: "PRIORITY 23: Task Spawn Speed Recovery (2026-11-03)"
description: "P23 tracks the recovery of the v0.9.0-era task-spawn throughput that regressed 1.74x -> 0.95x vs asyncio across the BUG-268..304 hardening band (revs 992..1002). Stages 2-3b(ii) SHIPPED (revs 1224/1226/1228/1229) recovered Task Spawn to 1.34x py3.14 / 1.31x py3.15 with every BUG-268/279/398/397 contract verified; the remaining distance decomposes into the registry floor (semantics-gated) and CPython-side per-task object churn (BUG-414's plateau)."
tags: [priority, performance, task-spawn, registry, bisect, veril]
timestamp: "2026-11-03T00:00:00Z"
---

[⬅️ Back to Index](../index.md)

# 🎯 PRIORITY 23: Task Spawn Speed Recovery (2026-11-03)

> **Status: LANDED (2026-11-03) — recovery plateau reached: 1.34× py3.14 / 1.31× py3.15 (v0.11.1-era 0.96×).** The remaining distance is the documented floor (registry semantics + CPython-side per-task churn), not talyn-addressable work.

## Executive Summary

The v0.10-era task path regressed **Task Spawn from 1.74× to 0.95× vs asyncio** on the Core
Ultra 7-265 bench (same host: py3.14 & py3.15 GIL, wheels archived per era). The era bisect
localized the cliff to **revs 992..1002** (the BUG-268..BUG-304 hardening band between
v0.9.0 and v0.9.6), and stage-2/3 levers recovered most of the gap *with every fixed
invariant verified*:

| stage | rev | py3.14 Task Spawn | talyn/asyncio |
|---|---|---|---|
| v0.11.1 published baseline | 1221 | 0.1270 s | 0.96× |
| stage-2: accelerator-only registration + `asyncio.tasks._py_all_tasks` rebound to the accel `all_tasks` view | 1224 | 0.1029 s | 1.25× |
| stage-3a: per-step `_py_current_task` probe removal (the C and pure dicts are separate by design — the probe always triggered the update while paying 2 pure-Python frames per task-step) | 1226 | 0.1009 s | 1.27× |
| stage-3b(i): native pure-registry sync (capture `asyncio.tasks._current_tasks` at init; dict write/delete from Zig instead of the `_py_enter_task`/`_py_leave_task` Python frames) | 1228 | 0.0960 s | 1.32× |
| stage-3b(ii): `ring_blocked` seq_cst → release/acquire (the runner mutex pair already orders the critical section) | 1229 | **0.0957 s** | **1.34×** |
| v0.9.0-era reference | 975 | 0.0730 s | 1.74× |

py3.15 tracks the same curve (1.21× → 1.26× → 1.32× at 3b(i); 1.31× at 3b(ii)).

## Stage history & validated-measurement discipline

- Stage-2's narrow variant ("C registrar only") was **briefly rejected by its own history**:
  `tests/test_task_registry.py::test_default_task_visible_in_all_tasks` asserts visibility
  in BOTH the `_asyncio` C registry and `asyncio.tasks._py_all_tasks(loop)` — resolved by
  *rebinding* `_py_all_tasks` to the accelerator's all_tasks (see stage-2), a
  zero-per-task-cost design that keeps the dual-registry contract exactly.
- The bisect lesson (recorded from the era analysis): a naive `hg backout` exclusion of
  revs 992/999/1001/1002/1008 measured **false** — later changesets re-plumb the mechanism;
  validate any exclusion by grepping the *post-backout* source for the mechanism call sites
  before trusting the number. The surgical exclusion (direct file edits) did produce the
  real number (1.57× on a rev-1032 tree with registry bookkeeping disabled).
- Stage-3b(iii) sweep: a loop-carried `pure_current_task_cache` on the LoopObject
  (removing both per-step dict lookups) measured **below the bench resolution** and was
  **reverted** — the GC-invisible borrowed-pointer field and its corner invalidation cases
  were not worth a sub-noise win. Recorded as the honest close.

## The remaining distance — the documented floor

v0.9.0-era − current ≈ **350 ns/task** (0.0957 − 0.0730 over 65536 tasks):

1. **Registry floor (~150-200 ns/task)**: the C `_register_task` (weakref creation inside
   CPython's C impl + `PyObject_CallOneArg` dispatch) plus BUG-279's completion-side
   `PySet_Discard` and the native `_current_tasks` dict pair — every piece is
   **semantics-gated** by BUG-268/BUG-398/BUG-279/BUG-397.
2. **CPython-side per-task object churn (BUG-414's plateau)**: the `create_task`
   interpreter path (Task object, context, C-registry weakref, intern churn) — not
   talyn-addressable; BUG-414's `tests/test_longrun_leak_gate.py` footprint gate keeps the
   plateau measured as future CPython releases change it.

## Validation matrix (used per stage)

- `zig build test` 82/82 on **both** toolchains (0.16.0 and 0.17.0), `zig fmt --check`,
  `zig build lint` 0 violations.
- pytest clean-venv: `test_task_registry.py` 2/2, `test_task*.py`, `test_future*.py`,
  `test_review_regressions.py` (88 passed at stage-3a; the 6 repro-subprocess filesystem
  artifacts are pre-existing and identical across wheels), `test_longrun_leak_gate.py`
  (1 xfail by design until BUG-414's plateau meets its control).
- The 12-repeat anchored era bench (`erasbench.py`, async-in-process asyncio anchor) for
  Task Spawn on both interpreters.

## Release notes

- **v0.11.2** should carry revs 1224..1229 (P23 stages 2-3b(ii)) and the watch items above.
- BUG-414 remains Open (shared lever); the gate tracks its plateau.

## Related

- [BUG-268](../bugs/268.md) (registry registration), [BUG-279](../bugs/279.md),
  [BUG-398](../bugs/398.md) (pure-Python fallback), [BUG-414](../bugs/414.md) footprint gate,
  [Lesson 24](../lessons/24-split-commit-hygiene-2026-11.md) (verification matrix).
