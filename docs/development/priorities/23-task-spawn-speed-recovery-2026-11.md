---
type: project_priority
title: "PRIORITY 23: Task Spawn Speed Recovery (2026-11-03)"
description: "P23 tracks the recovery of the v0.9.0-era task-spawn throughput that regressed 1.74x -> 0.95x vs asyncio across the BUG-268..304 hardening band (revs 992..1002); most of the loss is attributed to the per-task _asyncio registry bookkeeping (BUG-268/279 machinery), with the remaining residual in the constructor ownership fixes. The recovery must preserve every fixed invariant (validated by experiments + the BUG-414 leak gate)."
tags: [priority, performance, task-spawn, registry, bisect]
timestamp: "2026-11-03T00:00:00Z"
---

[⬅️ Back to Index](../index.md)

# 🎯 PRIORITY 23: Task Spawn Speed Recovery (2026-11-03)

> **Status: IN PROGRESS — root cause identified by bisect (revs 992..1002), attribution mapped (registry bookkeeping ≈ 75% of the loss).**

## Executive Summary

The v0.11.0-era task path regressed **Task Spawn from 1.74× to 0.95× vs asyncio** on the Core
Ultra 7-265 bench (py3.14 & py3.15 GIL, verified wheels archived per era). The era bisect
localized the cliff to **revs 992..1002** (the BUG-268..BUG-304 hardening band between
v0.9.0 and v0.9.6). A surgical re-measure with the BUG-268/BUG-279 **registry bookkeeping
disabled** on a v0.9.6 tree restored **talyn to 0.0813 s (1.57×)**, attributing ≈75% of the
loss to the per-task Python-side `_asyncio._register_task_impl` call + weakref + discard
churn, and the remaining ~10% to ownership/constructor churn (BUG-271/273/292/293/303/304).

Verified so far:
- raw soaks: rev 991 talyn 0.0711 s (1.76×) vs rev 1002 talyn 0.1274 s (0.96×) on the same
  host, same interpreter, 12 interleaved repeats — era-locked.
- `all-five backout` (rev 992, 999, 1001, 1002, 1008 on a v0.9.6 tree): 0.95× — **false
  negative, because hg backout conflict leftovers in later re-plumbed code kept the
  mechanism**: the tree still carried `register_asyncio_task` and
  `discard_from_asyncio_tasks_set`. That attempt is recorded as a negative-control, not a real
  exclusion.
- **Surgical removal** (delete `register_asyncio_task` calls + make
  `discard_from_asyncio_tasks_set` a no-op *comment* at call sites, via direct file edits):
  talyn recovered to **0.0813 s (1.57×)**. The remaining ~10% gap (0.0813 vs 0.0730) is
  constructor/ownership fix churn within same window.
- **BUG-414 linkage claim rejected**: at 25 s/482 rounds both the registry-on wheel
  (rev 1002) and the registry-off surgical build show **~42.6–44.0 MB RSS** under the same
  job. So the task-churn footprint high-water of BUG-414 is a *separate* defect
  (probably a per-round arena/queue high-water), not registry bookkeeping.

## Registered In-Progress Status (2026-11-03, stage 1)

**Measured scope narrowing (rev 1219 frontier):** with the *pure-Python* second registrar
call disabled (C accelerator-only), Task Spawn moved v0.10-era **0.95× → 1.25×** (py3.14
0.1053 s; py3.15 0.1072 s): ≈45% of the era-loss, from one full Python frame + weakref-set
insert per task. The remaining ~55% (the 1.25× → 1.74× distance) maps to the same band's
remaining work — and the *surgical-disable* result (1.57× on the v0.9.6 tree with BOTH the
py-registrar *and* the BUG-279 discard disabled) implies the **BUG-279 completions-side
`PySet_Discard` stops** carry ~2/3 of what remains. The discard is native but is executed
up to three times per task (set_result paths) against `loop_obj.asyncio_tasks_set`.

**Contract kept:** the dual-call *semantics* is required — `tests/test_task_registry.py::
test_default_task_visible_in_all_tasks` asserts tasks appear in **both** the `_asyncio` C
registry *and* `asyncio.tasks._py_all_tasks(loop)` on 3.14+/3.15 — so the "call only the C
registrar" narrowing was **reverted** (stage 1 keeps the dual call).
**Stage 2 (v0.11.2 implementation route)**: keep both contracts *and* remove the Python-frame
cost — register the pure registry **natively from Zig** by replicating
`_py_register_task`'s bookkeeping with direct C-API calls (weakref creation + registry-set
add) instead of `PyObject_CallOneArg`; validation unchanged (BUG-268/398/279 semantics +
registry tests + BUG-414 footprint gate + era bench).

**Attribution note:** native `_asyncio._register_task(task)` costs **27 ns/call** on this
3.15 (micro-bench); the pure-Python alias `_py_register_task` costs **91 ns** (frame + dict
lookup). The remaining 1.25×→1.74× distance must therefore come from the *combination* of
(1) the *completion-side* discards and task-frame allocations (dict/weakref churn measured
by dhat at ~1.4 bytes of arena/tick), plus (2) the *runner/start* atomic-count increase
(`std/atomic.zig` in `loop.runner.start`: **+531 M Ir (+14%) in the slow band**), visible in
the cachegrind era diff — both are open work items under P23 (runner-loop atomic trimming
needs its own measured iteration before the BUG-117/BUG-283's invariants provide the safety
net).

**Status: IN PROGRESS. Stage 2 SHIPPED (2026-11-03): accelerator-only registration +
`asyncio.tasks._py_all_tasks` rebound to the accelerator's all_tasks view → 1.25× on
py3.14/py3.15 with the dual-registry contract intact (verified). The remaining lever is
stage 3: trim the runner-loop atomic churn (std/atomic.zig +531 M Ir in the slow band;
candidates: `ring_has_submitted` write pattern, per-completion lock sessions) and the
remaining interpreter-side churn measured by BUG-414's plateau.**
2. **SBO inline capacity** (SHIPPED in rev 1219 — bench-neutral, keeps for churn reduction).
3. **Validate** with: `zig build test` (both toolchains), `pytest tests/test_task_registry.py
   tests/test_task*.py tests/test_future*.py tests/test_review_regressions.py`, the
   **BUG-414 footprint gate** (`tests/test_longrun_leak_gate.py`), and the **era bench
   matrix** on this same host (py3.14 & py3.15 GIL; free-threaded target to be re-measured).
4. Ship as **v0.11.2** after v0.11.1 (BUG-414) per the release sequencing rule
   (`v0.11.1 = footprint fix; v0.11.2 = speed recovery`).

## Baseline data (Core Ultra 7-265, M=65536, avg of 12 repeats)

| Build | era | Task Spawn | talyn/asyncio |
|---|---|---|---|
| talyn 0_7_-era (published) | tag 750 | 0.0735 | **1.75×** |
| **rev 975 (v0.9.0)** | tag 975 | 0.0730 | **1.74x** |
| **rev 991** | post-BUG-267 | 0.0711 | **1.76x** |
| **rev 1002** | post-BUG-303/304 | 0.1274 | 0.96× |
| rev 1032 (v0.9.6) | post BUG-288..293 | 0.1285 | 0.95× |
| rev 1094 (v0.9.12) | v0.9.12 wheels | 0.1293 | 0.95× |
| current v0.11.0 wheel | published | 0.1270 (GIL) | 0.96× |
| **surgical: registry disabled on rev 1032** | experiment | **0.0813** | **1.57×** |

## Notes

- The earlier "all-five backout" is a **negative-control** to teach a bisect lesson: when a
  later changeset re-plumbs code, a naive `hg backout` is not a clean mechanism exclusion —
  validate by inspecting the post-backout source (grep for the mechanism call sites),
  otherwise experiments report false negatives.
- The era bisect script and results live outside the repo (session temp), and are compressed
  into the summary in this file to keep the repo clean; reruns are cheap (5 clones ×
  `setup.py bdist_wheel` + the 12-repeat `erasbench.py`).

## Related

- [BUG-268](../bugs/268.md) (registry registration), [BUG-279](../bugs/279.md),
  [BUG-398](../bugs/398.md) (pure-Python fallback), [BUG-414](../bugs/414.md) footprint gate,
  [Lesson 24](../lessons/24-split-commit-hygiene-2026-11.md) (verification matrix).
