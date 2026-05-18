[⬅️ Back to Index](todo.md)

# 🔍 Profiling Results (2026-05-15)

### TCP Echo (10k iterations) — Leviathan vs asyncio

| Metric | Leviathan | asyncio | Ratio |
|--------|-----------|---------|-------|
| **Time** | 8.39s | 1.16s | **7.2× slower** |
| **CPU cycles** | 39.6B | 4.0B | 9.8× more |
| **Instructions** | 38.0B | 7.2B | **5.3× more** |
| **IPC** | 1.0 | 1.8 | 1.8× worse |
| **Backend bound** | 70.4% | 10.6% | **6.6× worse** |
| **Retiring** | 5.4% | 19.7% | 3.6× less |
| **dTLB loads** | 11.9B | 2.2B | 5.5× more |

**Root Cause:** Leviathan executes 5.3× more instructions for the same work.
70% backend-bound (memory stalls), only 5.4% useful work retiring.

**Per I/O completion cost:**
1. CQE → copy 48-byte Callback into ring buffer
2. Ring buffer drain → `callback.func()` → `PyObject_Vectorcall`
3. Coroutine yields Future → `wakeup_task` → `_execute_task_send`:
   - `PyObject_Vectorcall(_enter_task)` → `PyContext_Enter` → `PyIter_Send` → `PyContext_Exit` → `PyObject_Vectorcall(_leave_task)`
4. Future completion → same path again

Each message (read+write) triggers multiple callback dispatches, each with
Callback copy + Python crossings.

**Conclusion:** P15 Phase 1 (CompletionRecord buffer) will reduce memory traffic
by eliminating the Callback copy. However, Python boundary crossings (`PyIter_Send`,
`PyObject_Vectorcall`) remain — those are inherent to the coroutine model.
Expect 1.0-1.3× after P15, not 3×. The remaining gap is a CPython architectural limit.

---

# 🔍 Codebase Audit (2026-05-13)

| Severity | Lesson | File:Line | Bug | Status |
|----------|--------|-----------|-----|:---:|
| Medium | 10. Coroutine Cleanup | `src/task/callbacks.zig:437` | `execute_task_throw` no `data.cancelled` check | ✅ Fixed |
| High | 3. Ghost Ref Cycles (now #11) | `src/future/callback.zig:164-177` | ZigGeneric ptr invisible to GC | ✅ Fixed |
| — | 2. EINTR / No Panics | `src/callback_manager.zig:90` | `@panic("RingBuffer overflow")` on dispatch | ⚠️ Intentional guardrail — fail-fast is better than silent error here |
| Low | 10. Coroutine Cleanup | `src/loop/python/control.zig:161` | `hook_callback` no `cancelled` check | ⚠️ False positive — hooks not in `release_ring_buffer` |
| Low | 7. tp_traverse Precision | `src/future/python/constructors.zig:85` | `@alignCast` on GC path | ⚠️ WON'T FIX — needs Future struct refactor |

2 real bugs fixed, 1 intentional guardrail, 2 false-positives / won't-fix.

---

