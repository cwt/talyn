[⬅️ Back to Index](todo.md)

# 🛡 io_uring Security Hardening

Hardening recommendations derived from the July 2026 CVE audit of all
`io_uring`-related Linux kernel vulnerabilities (149 total).
Only items that apply to Talyn's actual io_uring feature set are listed.

> **Audit context:** Talyn uses only the mature, stable subset of io_uring:
> read, write, poll_add, connect, accept, shutdown, cancel, timeout,
> recvmsg, sendmsg, read_fixed. No zcrx, NAPI, WAITID, futex, PBUF_RING,
> SQE128/SQE_MIXED, or MSG_RING. See `docs/lessons/04-io-uring-and-kernel.md`
> for existing defensive measures already in place.

---

## Defensive Items

### 🟡 HARD-01: Minimum Kernel Version Guard

**Status:** Not implemented

Add a runtime version check at ring init time that rejects kernels below
a baseline we know to be safe. The current minimum is effectively 6.0
(for `IORING_SETUP_SINGLE_ISSUER`), but 6.6 is the realistic floor for
receiving io_uring fixes in any maintained distro.

**Relevant CVEs:** CVE-2024-35827 (recvmsg overflow, fixed in 6.9)

**Implementation:**

```zig
// In src/loop/scheduling/io/main.zig, during ring init:
pub const MinKernelVersion = std.SemanticVersion{ .major = 6, .minor = 6, .patch = 0 };
```

- Warn at startup if the kernel is older than `MinKernelVersion`.
- On kernels older than 6.0 (no `IORING_SETUP_SINGLE_ISSUER`), reject
  outright since Talyn already requires it.
- Do not block startup for 6.0–6.5 (Talyn will work), but emit a
  loud `PySys_WriteStderr` warning recommending upgrade.

**Rationale:** Fedora 43-44 ships 7.0.x, so this is a no-op for the
primary target. The guard exists for people running Talyn on older
enterprise kernels where io_uring fixes may not have been backported.

---

### 🟡 HARD-02: seccomp Syscall Filter on Ring FD

**Status:** Not implemented

Apply a `seccomp` filter restricting `io_uring_enter(fd, ...)` so
only the main event loop thread can issue SQEs or harvest CQEs.
This is defense-in-depth: Talyn already uses `IORING_SETUP_SINGLE_ISSUER`,
which tells the kernel to skip some locking. If another thread somehow
obtains the ring fd and calls `io_uring_enter`, the kernel may not
apply the correct locking.

**Approach (low-priority, good-first-issue):**

```python
# Python-side, right after ring creation:
import prctl
prctl.set_seccomp(prctl.FILTER_FLAG_TSYNC, ...)
```

Alternatively, use `memfd_create` + `seccomp_notify` to intercept
`io_uring_enter` calls. This is heavy; the pragmatic move is to ensure
the ring fd never leaks to child processes or other threads.

**Relevant CVEs:** CVE-2026-23275 (task_work race on ring teardown),
generic single-issuer bypass concerns.

---

### 🟡 HARD-03: Ring FD `CLOEXEC` Audit

**Status:** Verify

Confirm the ring fd is created with `O_CLOEXEC` so child processes
from `subprocess_exec()` cannot inherit and abuse it. Zig's
`std.os.linux.IoUring.init()` may or may not set this by default.

**Checklist:**
- [ ] Ring fd: verify `O_CLOEXEC` is set by `IoUring.init()` in Zig 0.16.0 stdlib.
- [ ] Eventfd: `src/loop/scheduling/io/main.zig` already creates it with
      `EFD_CLOEXEC` (confirmed: line ~580 uses `std.os.linux.EFD.CLOEXEC`).
- [ ] signalfd: verify `SFD_CLOEXEC` is set during `signalfd()` creation.
- [ ] pidfd: verify `PIDFD_NONBLOCK` fd is `O_CLOEXEC`.

**Implementation:** If ring fd does not get `O_CLOEXEC`, add an `fcntl(fd, F_SETFD, FD_CLOEXEC)` immediately after `IoUring.init()`.

---

### 🟡 HARD-04: Registered Buffer Pool Lifetime Hardening

**Status:** Not implemented

The 16×64KB buffer pool registered via `IORING_REGISTER_BUFFERS` is
a persistent kernel mapping into userspace memory. If the backing
heap memory is freed while still registered, the kernel will write
completion data into freed memory.

**Current state:** Pool is allocated once during `IO.init()` and freed
only during `IO.deinit()`, which is called from `Loop.deinit()`.
This is correct as-is, but:
- No guard exists to prevent accidental `allocator.free()` on the pool
  buffer while the ring is still active.
- If `IO.deinit()` is skipped (e.g., due to a panic path), the kernel
  retains the registered buffer mapping into freed userspace memory.

**Relevant CVEs:** CVE-2024-35835 (kbuf hold over mmap), CVE-2026-43006
(zero-length fixed buffer import).

**Mitigation:**

```zig
// In IO.deinit():
pub fn deinit(self: *IO) void {
    if (self.ring.fd >= 0) {
        _ = self.ring.unregister_buffers(); // MUST be called before freeing pool
    }
    self.buffer_pool.deinit(self.allocator);
    // ...
}
```

Add a `@atomicStore` sentinel on the pool pointer after deinit so any
stale references trap deterministically.

---

### 🟡 HARD-05: Fixed File Slot Bounds Hardening

**Status:** Not implemented

The sparse fixed file table has 1024 slots (indices 0–1023). Slots are
allocated from a free-list (`fixed_file_free`). Add assertions in
`register_fixed_file()` and `unregister_fixed_file()` that the index
is within bounds before calling `ring.register_files_update()`.

**Current risk:** A logic error in the free-list management could
produce an out-of-bounds index, which `register_files_update` would
pass to the kernel. The kernel may reject it (`-EINVAL`), but better
to catch it in userspace where the error is debuggable.

**Implementation:**

```zig
fn register_fixed_file(self: *IO, fd: std.posix.fd_t) !u31 {
    const index = self.fixed_file_free.pop() orelse return error.FixedFileTableFull;
    std.debug.assert(index < FixedFileTableSize); // HARD-05
    // ...
}
```

---

### 🔵 HARD-06: Kernel io_uring Bug Monitor

**Status:** Ongoing

Maintain awareness of new io_uring kernel CVEs as they are published,
filtering for the subset of features Talyn actually uses.

**Subscription list:**
- [linux-cve-announce](https://lore.kernel.org/linux-cve-announce/) mailing list
- [Ubuntu CVE tracker](https://ubuntu.com/security/cves?q=io_uring) (149 CVEs as of July 2026)
- [Debian security tracker](https://security-tracker.debian.org/tracker/?q=io_uring)

**Triage checklist for each new CVE:**

| Check | Action |
|-------|--------|
| Does the CVE affect an opcode Talyn uses? | Read/write/poll_add/connect/accept/sendmsg/recvmsg only. Ignore zcrx, NAPI, futex, WAITID, MSG_RING, PBUF_RING. |
| Is the CVE in ring setup/teardown? | Always relevant regardless of opcodes. |
| Is the CVE tagged for a kernel version Talyn targets? | Fedora 43-44 = 7.0.x; lowest supported = 6.6. |
| Does Talyn have an existing lesson or mandate covering the bug class? | Cross-reference `docs/lessons/`. |
| Can the CVE be mitigated in userspace? | If yes, add to this hardening list. |

---

### 🔵 HARD-07: `CancelByFd` Completeness Audit

**Status:** Audit needed

Talyn already cancels pending ops before closing fd (Lessons 48, 105),
but verify every transport type calls `CancelByFd` before `close()`:

- [x] `DatagramTransport.close()` — Lesson 48, confirmed in
      `src/transports/datagram/` (cancels by task_id + CancelByFd)
- [x] `StreamTransport.close()` — Lesson 105, conditional on pending task
- [ ] `SubprocessTransport.close()` — verify pidfd cancellation
- [ ] `DnsResolver` transport — verify ephemeral UDP socket cancellation
- [ ] `UnixSignals` — signalfd cancellation on loop close

**Relevant CVEs:** Generic fd-reuse class, Lesson 48 (Datagram),
Lesson 105 (Stream).

---

## Not Applicable (Confirmed During Audit)

These CVEs target io_uring features Talyn does not use. Listed here to
avoid re-auditing in the future.

| CVE | Feature | Why Not Applicable |
|-----|---------|--------------------|
| CVE-2026-53321 | NAPI busy polling | Talyn does not use `IORING_SETUP_NAPI` |
| CVE-2026-53191 | PBUF_RING incremental | Talyn uses `IORING_REGISTER_BUFFERS`, not `IOU_PBUF_RING` |
| CVE-2026-46315 | IORING_OP_WAITID | Talyn uses pidfd + `waitid()` syscall directly, not the io_uring op |
| CVE-2026-45995 | zcrx / ZC_RX | Talyn does not use `IORING_SETUP_ZC_RX` |
| CVE-2026-43224 | zcrx sgtable leak | Same as above |
| CVE-2026-43174 | zcrx error handling | Same as above |
| CVE-2026-43121 | zcrx user_ref race | Same as above |
| CVE-2026-43442 | SQE128 / SQE_MIXED | Talyn uses standard 64-byte SQE |
| CVE-2026-45962 | ublk SQE128 bounds | Not applicable (ublk driver, not io_uring consumer) |
| CVE-2025-39698 | IORING_OP_FUTEX | Talyn does not use io_uring futex operations |
| CVE-2022-50295 | MSG_RING null deref | Talyn does not use `IORING_OP_MSG_RING` |
| CVE-2024-35877 | x86 PAT COW | Not io_uring; included in search by accident |
| CVE-2023-52656 | SCM_RIGHTS dead code | Talyn does not pass fds via io_uring |
| CVE-2023-52654 | AF_UNIX io_uring send | Disabled by kernel; not relevant |
| CVE-2026-33179/33150 | libfuse io_uring | Not kernel-level; Talyn is not a FUSE daemon |

---

## Summary

| Item | Status | Priority | Effort |
|------|--------|----------|--------|
| HARD-01: Min kernel version guard | 🟡 TODO | Medium | Small |
| HARD-02: seccomp filter | 🟡 TODO | Low | Medium |
| HARD-03: CLOEXEC audit | 🟡 Verify | Medium | Small |
| HARD-04: Buffer pool lifetime | 🟡 TODO | Medium | Small |
| HARD-05: Fixed file slot bounds | 🟡 TODO | Low | Tiny |
| HARD-06: Kernel CVE monitor | 🔵 Ongoing | High | — |
| HARD-07: CancelByFd audit | 🔵 Audit | Medium | Medium |

**Key takeaway:** Talyn's io_uring feature set is conservative and mature.
The highest-value hardening is keeping the kernel up to date (Fedora 7.0.x)
and adding the minimum version guard so no one accidentally runs on an
ancient vulnerable kernel. All the novel io_uring CVEs are in features
Talyn doesn't use.
