---
type: runbook
title: io_uring Security Hardening
description: Hardening guidelines and recommendations based on audit of io_uring CVE vulnerabilities, mapping out safe usage patterns for Talyn.
tags: [security, hardening, io-uring, linux]
timestamp: 2026-07-07T15:35:00Z
---

[⬅️ Back to Index](index.md)

# 🛡️ io_uring Security Hardening

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

### 🟢 HARD-01: Minimum Kernel Version Guard

**Status:** ✅ Implemented

Added a runtime version check at ring init time that rejects kernels below
a baseline we know to be safe. The current minimum is effectively 6.0
(for `IORING_SETUP_SINGLE_ISSUER`), but 6.6 is the realistic floor for
receiving io_uring fixes in any maintained distro.

**Relevant CVEs:** CVE-2024-35827 (recvmsg overflow, fixed in 6.9)

**Implementation:**
- Evaluated during ring init in [main.zig](../src/loop/scheduling/io/main.zig#L437).
- Rejects kernels older than 6.0 outright since Talyn requires single-issuer features.
- Emits a loud `PySys_WriteStderr` warning recommending upgrade on kernels 6.0–6.5.

---

### ❌ HARD-02: seccomp Syscall Filter on Ring FD

**Status:** ❌ Rejected (Low Priority / Superseded)

We evaluated applying a `seccomp` filter restricting `io_uring_enter(fd, ...)` to only the main loop thread. However, since Talyn successfully configures `IORING_SETUP_SINGLE_ISSUER` on supported kernels ($\ge$ 6.0), the Linux kernel itself enforces that only the creating/submitting thread can enter the ring, making seccomp filters redundant. 

Instead, we double-down on private ring descriptor management and strict CLOEXEC compliance (HARD-03).

---

### 🟢 HARD-03: Ring FD `CLOEXEC` Audit

**Status:** ✅ Audited & Fixed

We audited all descriptor creation sites to ensure no leaks to subprocesses:
- **Ring fd:** Verified `O_CLOEXEC` is set via `fcntl` in [main.zig](../src/loop/scheduling/io/main.zig#L479).
- **Eventfd:** Created with `EFD_CLOEXEC` in [main.zig](../src/loop/scheduling/io/main.zig#L481).
- **Inotify fd:** Created with `IN_CLOEXEC` in [fs_watcher.zig](../src/loop/fs_watcher.zig#L45).
- **signalfd:** ⚠️ **Fixed.** Changed flag argument in [unix_signals.zig](../src/loop/unix_signals.zig#L224) from `0` to `std.os.linux.SFD.CLOEXEC`.
- **pidfd:** ⚠️ **Fixed.** Passing `O_CLOEXEC` to the `pidfd_open` syscall is rejected with `EINVAL` by the kernel (which only accepts `PIDFD_NONBLOCK`). We fixed this by opening the pidfd with `0` flags and immediately applying `fcntl(fd, F_SETFD, FD_CLOEXEC)` in [child_watcher.zig](../src/loop/child_watcher.zig#L53) and [transport.zig](../src/transports/subprocess/transport.zig#L377).

---

### 🟢 HARD-04: Registered Buffer Pool Lifetime Hardening

**Status:** ✅ Implemented

The 16×64KB buffer pool registered via `IORING_REGISTER_BUFFERS` is a persistent kernel mapping into userspace memory. To guarantee safety and prevent use-after-free conditions:
- We call `self.ring.unregister_buffers()` in `IO.deinit()` before releasing the pool memory.
- We added a `@atomicStore` sentinel setting `buffer_memory.ptr` to `0xDEADBEEF` after deinit in [main.zig](../src/loop/scheduling/io/main.zig#L658) so any stale references trap immediately.

---

### 🟢 HARD-05: Fixed File Slot Bounds Hardening

**Status:** ✅ Implemented

Added bounds assertions in `register_fixed_file` and `unregister_fixed_file` in [main.zig](../src/loop/scheduling/io/main.zig#L539) to check the slot index against `fixed_file_table.len` (1024 slots) before calling `register_files_update`. This prevents undefined behavior (UB) in `ReleaseFast` builds in case of free-list corruption.

---

### 🔵 HARD-06: Kernel io_uring Bug Monitor

**Status:** ✅ Implemented & Automated

We maintain active awareness of new io_uring kernel CVEs as they are published, filtering for the subset of features Talyn actually uses (Read, Write, Poll, Sockets).
- **Automation:** Created [monitor_io_uring_cves.py](../scripts/monitor_io_uring_cves.py) which queries the live NVD CVE API, parses descriptions, filters out CVEs based on unused io_uring features, and prints a formatted markdown table.

---

### 🟢 HARD-07: `CancelByFd` Completeness Audit

**Status:** ✅ Audited & Fixed

We audited all socket/file closings to prevent the fd-reuse bug class (Lesson 48):
- **DNS Resolver:** ⚠️ **Fixed.** Modified [resolv.zig](../src/loop/dns/resolv.zig#L114) to queue `CancelByFd` on the active socket before closing it. Also fixed a memory leak on queue error in `resolv.zig:L795` by slicing `queries_data` to `queries_sent`.
- **FSWatcher:** ⚠️ **Fixed.** Modified `deinit()` in [fs_watcher.zig](../src/loop/fs_watcher.zig#L28) to explicitly cancel `inotify_task_id` before closing the inotify fd.
- **Datagram & Stream Transports:** Confirmed safe.
- **Subprocess Transport:** Confirmed safe (cancels pidfd exit watcher task prior to closing pidfd).

---

## Summary

| Item | Status | Priority | Effort |
|------|--------|----------|--------|
| HARD-01: Min kernel version guard | ✅ Implemented | Medium | Small |
| HARD-02: seccomp filter | ❌ Rejected | Low | Medium |
| HARD-03: CLOEXEC audit | ✅ Fixed | High | Small |
| HARD-04: Buffer pool lifetime | ✅ Implemented | Medium | Small |
| HARD-05: Fixed file slot bounds | ✅ Implemented | Low | Tiny |
| HARD-06: Kernel CVE monitor | ✅ Implemented & Automated | High | Medium |
| HARD-07: CancelByFd audit | ✅ Fixed | High | Medium |

**Key Takeaway:** Talyn's io_uring feature set is conservative and mature. All the novel io_uring CVEs are in features Talyn doesn't use.
