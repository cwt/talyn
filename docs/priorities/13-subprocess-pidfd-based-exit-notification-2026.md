[⬅️ Back to Index](../todo.md)

# 🔴 PRIORITY 13: Subprocess — pidfd-Based Exit Notification — ✅ DONE (2026-05-15)

### Root Cause of 0.23× Subprocess Performance

Subprocess benchmark (0.23×, 4× slower than asyncio) was the worst-performing benchmark.

**Old design:** `src/transports/subprocess/transport.zig` used **timer-based polling** to detect child exit:

```
start_exit_watcher → queue WaitTimer(1ms)
1ms later: wait4(pid, NOHANG) → process still starting (Python init ~10-30ms)
5ms later: wait4 → still starting
25ms later: wait4 → process exited → callback
Total latency per process: ~31ms (polling overhead)
```

**asyncio approach:** Uses SIGCHLD signal handler. Kernel delivers the signal immediately when the child exits. Latency: microseconds.

**Existing correct infrastructure:** `src/loop/child_watcher.zig:42-60` already implements the right approach:

```
pidfd_open(pid, 0) → queue WaitReadable(pidfd)
pidfd becomes readable → kernel wakes io_uring → callback → waitid(.PIDFD)
```

The `child_watcher` was a separate mechanism from the subprocess transport and was NOT used by it.

### Fix: Port subprocess transport to pidfd + WaitReadable

Replaced `WaitTimer`+`wait4` polling with `pidfd_open`+`WaitReadable`+`waitid(.PIDFD)` — same as child_watcher.

| # | Task | Status |
|---|------|:---:|
| 13.1 | Open pidfd in `start_exit_watcher` via `pidfd_open` syscall | ✅ DONE |
| 13.2 | Queue `WaitReadable` on pidfd instead of `WaitTimer` | ✅ DONE |
| 13.3 | Use `waitid(.PIDFD)` instead of `wait4` in callback | ✅ DONE |
| 13.4 | Close pidfd in `subprocess_close` | ✅ DONE |
| 13.5 | Removed `poll_count` and `pidfd_timer_duration` | ✅ DONE |
| 13.6 | All 263 tests + 5 std modules pass on 4 Pythons | ✅ DONE |

### Actual Impact

| Benchmark | Before (461) | After (462) | Change |
|-----------|:-----------:|:----------:|:------:|
| **Subprocess** | **0.23×** | **~1.0×** | **+335%** 🔥 |
| All others | unchanged | unchanged | within noise |

---
