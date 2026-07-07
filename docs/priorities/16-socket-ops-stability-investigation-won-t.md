---
type: project_priority
title: PRIORITY 16: Socket Ops Stability Investigation — ⚠️ WON'T FIX (2026-05-15)
description: Project priority tracking document.
tags: [priority, historical]
timestamp: 2026-07-07T16:30:00Z
---

[⬅️ Back to Index](../index.md)

# 🔴 PRIORITY 16: Socket Ops Stability Investigation — ⚠️ WON'T FIX (2026-05-15)

### Root Cause Analysis of 0.63× Socket Ops Performance (24% Stdev)

Socket Ops benchmark (0.63×, 512 sequential one-shot connections) had high variability.
Hypothesis: `IOSQE_ASYNC` on `connect`/`accept`/`shutdown` forced workqueue offloading,
causing scheduling jitter.

**Attempted fix:** Removed `IOSQE_ASYNC` from `socket.zig` connect/accept/shutdown.

**Result:** Socket Ops benchmark **TIMEOUT** at M=1024. Root cause: io_uring's inline
`IORING_OP_CONNECT` without `IOSQE_ASYNC` returns `-EINPROGRESS` for non-blocking sockets
without properly installing a poll callback. The workqueue is **required** for correct
TCP handshake handling in io_uring.

**Conclusion:** `IOSQE_ASYNC` cannot be removed from connect/accept for io_uring.
The 24% stdev is inherent to workqueue scheduling and cannot be eliminated without
changing the io_uring submission model (SQPOLL was tried in P15 Phase 2 and reverted —
see PRIORITY 17).

### Tests Added (kept as regression tests)

| File | Tests |
|------|-------|
| `tests/test_socket_ops.py` | 5 new tests: many_sequential_connections, raw_socket_connect_accept, shutdown_variants, concurrent_connect_accept_stress, unix_socket_connect_accept |

---
