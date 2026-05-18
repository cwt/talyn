[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 14: Remove IOSQE_ASYNC from Data Ops — ✅ DONE (2026-05-15)

### Root Cause of 0.3-0.6× I/O Performance

Every IO operation set `sqe.flags |= IOSQE_ASYNC` (20 locations across 4 files).
This forces the kernel to offload ALL operations to workqueue threads, even
trivial read/write on sockets with data already buffered. Each offloaded op
adds a context switch (submit → workqueue → complete).

**Fix:** Removed `IOSQE_ASYNC` from `ring.read`, `ring.write`, `ring.writev`,
`ring.recvmsg`, `ring.sendmsg`. Kept on `POLL_ADD`, `Timer.wait`, `link_timeout`
(inherently async ops). `connect`, `accept`, `shutdown` also had `IOSQE_ASYNC` but
were removed separately in PRIORITY 16.

On non-blocking sockets, the kernel handles `-EAGAIN` gracefully:
it auto-installs a poll callback and completes when data arrives.
No workqueue needed — no context switch overhead.

### Actual Impact (M=65536)

| Benchmark | Before (464) | After (465) | Change |
|-----------|:-----------:|:----------:|:------:|
| **UDP Ping-Pong** | **0.45×** | **1.16×** | **+156%** 🔥 |
| **TCP Echo** | **0.38×** | **0.75×** | **+99%**  |
| Event Fiesta Factory | 0.65× | 0.91× | +40% |
| Socket Ops | 0.53× | 0.65× | +23% |
| Producer Consumer | 0.62× | 0.73× | +18% |
| Task Spawn | 0.67× | 0.75× | +11% |
| Chat | 0.96× | 1.00× | ~same |
| Subprocess | 1.00× | 1.00× | ~same |

**Impact:** UDP Ping-Pong now beats asyncio. All I/O benchmarks improved
significantly. The remaining gap (~0.7× on TCP/Unix Echo) is likely from
callback dispatch overhead (Zig→Python boundary per completion).

---
