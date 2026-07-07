---
type: project_priority
title: PRIORITY 17: SQPOLL Hang After ~16000 Total SQEs — ⛔ REVERTED (2026-05-17)
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# 🔴 PRIORITY 17: SQPOLL Hang After ~16000 Total SQEs — ⛔ REVERTED (2026-05-17)

### Root Cause

After ~16000–16400 total SQEs (~2 wraps of 8192-entry SQ ring), `run_until_complete` on a single `Loop` object hangs in `enter(0, 1, GETEVENTS | SQ_WAKEUP)` — blocks forever waiting for a CQE that never arrives.

### Investigation Timeline

| Attempt | Finding |
|---------|---------|
| Check `/proc/<tid>/status` | **SQPOLL thread is `R (running)`** during the hang — NOT sleeping. `SQ_WAKEUP` is useless because the thread is already awake. |
| Replace eventfd READ with POLL_ADD | Hang still at exactly same iteration count. Eventfd SQE type was irrelevant. |
| Always call `enter(0, 0, SQ_WAKEUP)` unconditionally in `submit_guaranteed` | NO effect — same iteration count hang. Thread doesn't need waking. |
| Larger batches (m=128, m=256) hit hang earlier | Hang correlates with **total SQE count**, not iteration count. ~16000–16400 total SQEs triggers the hang regardless of batch size. |
| Single-connect loops (m=1, ~2 SQEs/iter) run 500+ iterations fine | Below the threshold. |

### Key Discoveries

1. **`flush_sq()` returns `sq_ready()` = `sqe_tail − kernel_sq_head`** — the **total backlog** of SQEs the kernel hasn't yet consumed since the beginning, NOT the count of SQEs just flushed. After 17001 submitted and kernel consumed 16400, `flush_sq()` returns 601.

2. **`submit_guaranteed` over-submits stale SQEs**: `ring.submit()` returns `sq_ready()` (601), then calls `enter(601, 0, SQ_WAKEUP)`. The kernel may try to re-process SQEs already consumed by the SQPOLL thread — corrupting its internal SQE tracking.

3. **No CQE production guarantee**: With SQPOLL thread running but ignoring SQ_WAKEUP, and no socket operations producing CQEs, `enter(0, 1, GETEVENTS | SQ_WAKEUP)` has **no mechanism to produce a CQE** — the eventfd POLL_ADD won't fire because nobody wrote to the eventfd.

### The Fix (tried — reverted with SQPOLL)

In `poll_blocking_events`'s blocking path, **write to eventfd before every blocking `enter()`**:

```zig
_ = try self.io.wakeup_eventfd();
```

This guarantees the eventfd POLL_ADD produces a CQE, so `enter()` returns immediately.

**Why it's insufficient:** The P17 fix works around the hang but adds 1 eventfd write + 1 eventfd read + 1 POLL_ADD re-registration per loop iteration. When combined with `SQ_WAKEUP` on every `submit_guaranteed()`, the total syscall overhead **increases** vs non-SQPOLL mode. UDP Ping-Pong dropped from 1.16× to 0.57× — a 50% regression.

### Results

- P17 fix itself works: all 269 tests pass on all 4 Pythons
- **BUT benchmark regressions make SQPOLL net-negative:** UDP Ping-Pong −50%, Socket Ops −23%, TCP/Unix Echo −16-21%
- **Conclusion: SQPOLL reverted.** The kernel bug on 7.0.6 cannot be worked around without unacceptable overhead. Revisit on kernel ≥ 7.10.

### Lesson

Never assume `SQ_WAKEUP` works on all kernel versions. The eventfd is the **only guaranteed CQE source** — always prime it before blocking if you need to wake. And more importantly: **benchmark before shipping** — SQPOLL's theoretical zero-syscall benefit is wiped out by the workarounds needed for kernel bugs.

---
