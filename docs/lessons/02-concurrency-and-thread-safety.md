[⬅️ Back to Lessons Index](../lessons-learned.md)

# Concurrency & Thread Safety

Lessons about race conditions, atomic operations, mutexes, free-threading, and safe concurrent state management.

---

### The Deadly "Atomic Sleep" Window

**Lesson 1 — Free-Threading & The "Atomic Sleep"**
In free-threading (`3.13t`/`3.14t`), the window between "checking for work" and "going to sleep" is a deadly trap.
- **Bug:** The loop checks the queue, sees it empty, then blocks in `io_uring`. A background thread adds a task *after* the check but *before* the block — the task silently sleeps until the next wakeup.
- **Lesson:** The decision to sleep must be **atomic**. Always check the ready queue while holding the loop mutex immediately before dropping the GIL and calling into the kernel.

---

### Recursive Mutex Deadlocks

**Lesson 17 — Recursive SpinMutex Deadlock at Loop Exit**
During `loop.release()`, deinitializers for `unix_signals` and `BlockingTasksSet` called `Soon.dispatch_guaranteed`, which re-acquired the already-held `loop.mutex` — infinite spin deadlock.
- **Lesson:** Deinitializers and cleanup handlers running during loop teardown must assume the loop's mutex is already held. Use non-threadsafe scheduling variants (e.g., `Soon.dispatch_guaranteed_nonthreadsafe`) for scheduling inside teardown. Never attempt to lock a non-recursive mutex recursively.

**Lesson 21 — Recursive SpinMutex Deadlock Under Free-Threading**
Native wrapper functions (`z_loop_delayed_call`, `z_loop_add_watcher`, etc.) held `loop.mutex` and then called `IO.queue(...)`, which also locked `loop.mutex` — immediate self-deadlock.
- **Fix:** Split `IO.queue` into a thread-safe `queue(...)` wrapper (acquires the lock) and a non-locking `queue_unlocked(...)` helper. All native functions running under the loop mutex use `queue_unlocked`.
- **Lesson:** Never acquire a non-recursive mutex recursively. When building locking APIs, always provide unlocked internal helpers (e.g., `_unlocked`, `_nonthreadsafe`) for safe use from paths that already hold the lock.

---

### Check-Then-Act (TOCTOU) Races

**Lesson 59 — Close TOCTOU Races with Atomic CAS, Not Locks**
`fast_handle_cancel` and its callback both used a check-then-set pattern on the `cancelled` flag — between the check and the set, the other side could also proceed.
- **Fix:** Replaced both patterns with `@cmpxchgStrong(bool, &self.cancelled, false, true, .acq_rel, .acquire)`. First to win the CAS acts; the second skips.
- **Lesson:**
  - **"Claim and proceed" patterns** (cancel vs callback): use CAS on a single shared flag.
  - **"Protect a critical section"** (multiple reads/writes to related state): use a lock.
  - **"Publish a value"** (one writer, many readers): use release-store / acquire-load.
  - CAS is lock-free — no priority inversion, no deadlock risk. Trade-off: harder to reason about, but ideal for simple flag-style ownership races.

**Lesson 99 — Atomic Check-and-Remove for Concurrent State**
In `on_child_exit`, after the Python callback ran, cleanup called `handlers.remove(pid)`, `close(pidfd)`, etc. unconditionally. If the callback had called `remove_child_handler(pid)`, the handler was already freed — double-free and double-close.
- **Fix:** Replaced unconditional cleanup with `fetchRemove` (atomic check-and-remove). If still in the map, we own the lifecycle. If already removed, we don't touch it.
- **Lesson:** Use atomic fetch-remove for state that can be concurrently mutated by callbacks. Pattern:
  1. `if (map.contains(k)) { map.remove(k); free(v); }` — TOCTOU race.
  2. `if (map.fetchRemove(k)) |entry| { free(entry.value); }` — safe.

---

### Thread-Unsafe Global State

**Lesson 74 — Never Return References to Module-Level Mutable State**
`resolve_address` returned a slice into `var tmp_address: utils.Address` — a module-level mutable variable. Two concurrent callers shared the same memory; the first caller's result was clobbered by the second.
- **Fix:** Changed API to take an output buffer parameter: `fn resolve_address(hostname, allow_ipv6, out: []utils.Address) !usize`. No more global mutable state.
- **Lesson:** Never return references to module-level mutable state from functions that may be called concurrently. Safe patterns:
  1. Caller-owned output buffer parameter.
  2. Heap-allocate and return an owned slice.
  The same applies to C `static` variables, Python module-level mutable defaults, and singleton patterns.

---

### Syscall Error Handling

**Lesson 22 — Level-Triggered Socket Deadlocks via Incorrect Direct Syscall Error Check**
In `accept_callback`, the code checked `if (client_fd_ret == std.math.maxInt(usize))` and queried `std.os.linux.errno(0)`. Raw Linux syscalls return **negative `-errno`** values — they do NOT set thread-local `errno`. When `accept4` failed with `-EAGAIN` or `-EINTR`, the failure was missed and the negative error code was treated as a valid fd.
- **Fix:** Cast the result to `isize` and check `if (client_fd_signed < 0)`. Retrieve error via `const errno_val = -client_fd_signed`.
- **Lesson:** Raw assembly syscalls in Zig (`std.os.linux`) differ fundamentally from C stdlib functions. They return negative error codes directly; they do NOT populate `errno`. Failing to handle this correctly corrupts resource tracking and produces mysterious, load-dependent deadlocks.

**Lesson 73 — Distinguish Transient vs Fatal Syscall Errors**
After `waitid` returned non-zero, the code re-armed the watcher unconditionally. For fatal errors (`ECHILD`, `EINVAL`), this caused an infinite re-arm loop.
- **Fix:** Only re-arm on transient errors (`EINTR`, `EAGAIN`). Log and return for all other errors.
- **Lesson:** Syscalls can fail with both transient errors (worth retrying) and fatal errors (worth giving up). Pattern:
  1. Retry transient errors in a tight loop (`EINTR`, `EAGAIN`).
  2. Log fatal errors and propagate up.
  3. **Never** blindly re-arm a watcher on a non-recoverable error.
