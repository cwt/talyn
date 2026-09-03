---
type: index
title: "Development Documentation — talyn"
description: "Master index for the development bundle: priorities, lessons learned, bugs, architectural mandates, and project history."
status: stable
verified: human-reviewed
timestamp: "2026-08-14T00:00:00Z"
---

# Development Documentation — talyn

This is the development bundle for Talyn. It covers project priorities, lessons learned, bugs discovered and fixed, architectural mandates, and the project's history.

[⬅️ Back to Main Index](../index.md)

## Priorities

| # | Title | Status |
|---|---|---|
| [1](priorities/1-zig-0-16-0-compatibility-2026.md) | Zig 0.15.2 & 0.16.0 Compatibility | ✅ DONE |
| [2](priorities/2-network-transport-all-7-7.md) | Network & Transport | ✅ DONE (7/7) |
| [4](priorities/4-standard-compatibility-gc-stability-2026-05.md) | Standard Compatibility & GC Stability | ✅ DONE |
| [9](priorities/9-callback-dispatch-rewrite-flat-ring-buffer.md) | Callback Dispatch Rewrite — Flat Ring Buffer | ✅ DONE |
| [10](priorities/10-python-zig-boundary-overhead-elimination-2026.md) | Python/Zig Boundary Overhead Elimination | ✅ DONE |
| [11](priorities/11-sqe-batch-submission-io-uring-batching.md) | SQE Batch Submission — io_uring Batching | ✅ DONE |
| [12](priorities/12-callback-struct-slimming-2026-05-14.md) | Callback Struct Slimming | ✅ DONE |
| [13](priorities/13-subprocess-pidfd-based-exit-notification-2026.md) | Subprocess — pidfd-Based Exit Notification | ✅ DONE |
| [14](priorities/14-remove-iosqe-async-from-data-ops.md) | Remove IOSQE_ASYNC from Data Ops | ✅ DONE |
| [15](priorities/15-batch-dispatch-engine-full-io-uring.md) | Batch Dispatch Engine + Full io_uring | ✅ DONE |
| [16](priorities/16-socket-ops-stability-investigation-won-t.md) | Socket Ops Stability Investigation | ⚠️ WON'T FIX |
| [17](priorities/17-sqpoll-hang-after-16000-total-sqes.md) | SQPOLL Hang After ~16000 Total SQEs | ⛔ REVERTED |
| [18](priorities/18-deep-audit-lessons-learned-scan-2026.md) | Deep Audit — Lessons-Learned Scan | ✅ DONE |
| [19](priorities/19-remaining-pre-existing-issues-2026-05.md) | Remaining Pre-Existing Issues | ✅ DONE |
| [20](priorities/20-tls-ssl-completion-2026-05.md) | TLS/SSL Completion | ✅ DONE |
| [21](priorities/21-advanced-event-loop-optimization-2026.md) | Advanced Event Loop Optimization | ✅ DONE |
| [22](priorities/22-fused-user-space-socket-state-machine-2026.md) | Fused User-Space Socket State Machine | ✅ DONE |

## Knowledge Base

- [Lessons Learned](lessons/index.md)
- [Bugs](bugs/index.md)
- [Architectural Mandates](architectural-mandates.md)
- [Offline AST Linter & Bug Hunter](ast-linter.md)
- [Reference & Misc](reference-and-misc.md)
- [Audits and Profiling](audits-and-profiling.md)
- [io_uring Security Hardening](hardening.md)

## Project History

- [Development Journey](development-journey.md)
- [Talyn Migration](talyn-migration.md)
- [Why Talyn?](talyn-naming.md)

## Change Log

- [Update Log](log.md)
