[⬅️ Back to Index](../todo.md)

# PRIORITY 12: Callback Struct Slimming (2026-05-14) ✅ DONE

### Root Cause of 0.4-0.5× Performance

Every dispatch copied a 112-byte `Callback` struct into the ring buffer.
The `exception_context` field (56 bytes inline) was the biggest contributor —
it included two 16-byte slices (`module_name`, `exc_message`) that are constant
per callback function type and only used in error/cold paths.

| Size | Before | After | Saving |
|------|:------:|:-----:|:------:|
| `CallbackExceptionContext` | 48 bytes | removed | 100% |
| `CallbackData` | 88 bytes | 40 bytes | 55% |
| `Callback` | 112 bytes | 48 bytes | **57%** |

**Fix:** Replaced inline `exception_context: ?CallbackExceptionContext` (56 bytes)
with two optional pointers: `module_ptr: ?*PyObject` (8) + `callback_ptr: ?PyObject` (8).
Exception handler now receives `module_ptr` and `callback_ptr` directly instead
of a nested context struct.

**Impact:** TCP Echo recovered from 0.29× → 0.56× (+93%). Chat 0.79→0.84× (+6%).
Task-intensive benchmarks gained 5-10%. The smaller dispatch struct means less
cache pressure and fewer memory bandwidth cycles per dispatch.

### UDP Ping-Pong Timeout — ✅ FIXED (2026-05-14)

The UDP Ping-Pong benchmark was failing with a timeout or entering a busy loop of 0-byte `recvmsg` completions. 

**Root Cause:** 
1. **Dangling Stack Pointers:** `DatagramTransport.sendto` (connected path) used a stack-allocated `iovec`. When `PerformWriteV` was deferred (Priority 11 Phase 1), the pointer became invalid before submission.
2. **Zero-Copy Stack MSGHdr:** `Read.perform` and `Write.perform` used stack-allocated `msghdr` structs for the `zero_copy` path. As these operations were deferred, they also used dangling pointers.
3. **Circular Dependency:** UDP Ping-Pong involves immediate request-response. Deferring the first `sendto` (the ping) until the end of the tick created a deadlock if the loop blocked waiting for a completion that couldn't happen until the ping was sent.

**The Fix:**
1. **Unified SendTo Path:** Refactored `z_datagram_sendto` to use heap-allocated `SendToData` and `.PerformSendMsg` for both connected and unconnected paths. `.PerformSendMsg` uses immediate submission, ensuring pointers are valid and breaking the circular dependency.
2. **Immediate Zero-Copy Submit:** Added `IO.submit_guaranteed()` to `Read.perform` and `Write.perform` when `zero_copy` is enabled. This ensures the stack-allocated `msghdr` is consumed by the kernel before the function returns.
3. **Busy-Loop Prevention:** While not the primary cause, ensured that `read_completed` doesn't just blindly re-arm on 0-byte datagrams if they persist (though this is standard for UDP).

**Impact:** UDP Ping-Pong benchmark now passes for all $M$ values, matching or slightly beating `asyncio` performance.

### Safety Checklist

- [x] **Lesson 1 (Atomic Sleep):** `should_wait` is evaluated AFTER flush, inside the mutex — safe
- [x] **Lesson 2 (EINTR):** `flush_pending_sqes()` uses `submit_guaranteed()` — already EINTR-safe
- [x] **Lesson 9 (EventFD):** `register_eventfd_callback()` still calls `submit_guaranteed()` immediately — no change
- [x] **Cancellation correctness:** `queue()` flushes SQ before dispatching Cancel — target visible to kernel
- [x] **No indefinite deferral:** `poll_blocking_events()` forces flush on every iteration — max deferral is 1 tick
- [x] **No deadlock on idle loop:** `should_wait=false` when flush submits 0 and `reserved_slots==0`

---
