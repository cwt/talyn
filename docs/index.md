---
type: index
title: Talyn Documentation Index
description: Master index for priorities, lessons learned, and architectural mandates.
timestamp: 2026-07-07T15:35:00Z
---

# Talyn Documentation Index

Welcome to the Talyn TODO and project tracking documentation. This serves as the master index for all priorities, lessons learned, and architectural mandates.

[⬅️ Back to Main README](../README.md)

## Priorities

- [✅ PRIORITY 1: Zig 0.15.2 & 0.16.0 Compatibility — DONE](priorities/1-zig-0-16-0-compatibility-2026.md)
- [🟡 PRIORITY 2: Network & Transport — ALL DONE (7/7)](priorities/2-network-transport-all-7-7.md)
- [🔵 PRIORITY 4: Standard Compatibility & GC Stability — ✅ DONE (2026-05-10)](priorities/4-standard-compatibility-gc-stability-2026-05.md)
- [✅ PRIORITY 9: Callback Dispatch Rewrite — Flat Ring Buffer — ✅ DONE (2026-05-11)](development/priorities/9-callback-dispatch-rewrite-flat-ring-buffer.md)
- [✅ PRIORITY 10: Python/Zig Boundary Overhead Elimination — ✅ DONE (2026-05-27)](development/priorities/10-python-zig-boundary-overhead-elimination-2026.md)
- [✅ PRIORITY 11: SQE Batch Submission — io_uring Batching — ✅ DONE (2026-05-13)](development/priorities/11-sqe-batch-submission-io-uring-batching.md)
- [PRIORITY 12: Callback Struct Slimming (2026-05-14) ✅ DONE](development/priorities/12-callback-struct-slimming-2026-05-14.md)
- [✅ PRIORITY 13: Subprocess — pidfd-Based Exit Notification — ✅ DONE (2026-05-15)](development/priorities/13-subprocess-pidfd-based-exit-notification-2026.md)
- [✅ PRIORITY 14: Remove IOSQE_ASYNC from Data Ops — ✅ DONE (2026-05-15)](development/priorities/14-remove-iosqe-async-from-data-ops.md)
- [✅ PRIORITY 15: Batch Dispatch Engine + Full io_uring — Architectural Redesign — ✅ DONE (2026-05-26)](development/priorities/15-batch-dispatch-engine-full-io-uring.md)
- [🔴 PRIORITY 16: Socket Ops Stability Investigation — ⚠️ WON'T FIX (2026-05-15)](development/priorities/16-socket-ops-stability-investigation-won-t.md)
- [🔴 PRIORITY 17: SQPOLL Hang After ~16000 Total SQEs — ⛔ REVERTED (2026-05-17)](development/priorities/17-sqpoll-hang-after-16000-total-sqes.md)
- [✅ PRIORITY 18: Deep Audit — Lessons-Learned Scan — ✅ DONE (2026-05-17)](development/priorities/18-deep-audit-lessons-learned-scan-2026.md)
- [✅ PRIORITY 19: Remaining Pre-Existing Issues — ✅ DONE (2026-05-27)](development/priorities/19-remaining-pre-existing-issues-2026-05.md)
- [✅ PRIORITY 20: TLS/SSL Completion — DONE (2026-05-25)](development/priorities/20-tls-ssl-completion-2026-05.md)
- [✅ PRIORITY 21: Advanced Event Loop Optimization — ✅ DONE (2026-05-28)](development/priorities/21-advanced-event-loop-optimization-2026.md)

## Knowledge Base

- [Lessons Learned](development/lessons/index.md)
- [Bugs](development/bugs/index.md)
- [Architectural Mandates](development/architectural-mandates.md)
- [Offline AST Linter & Bug Hunter](development/ast-linter.md)
- [Development Journey](development/development-journey.md)
- [Reference & Misc](development/reference-and-misc.md)
- [Audits and Profiling](development/audits-and-profiling.md)
- [io_uring Security Hardening](development/hardening.md)
