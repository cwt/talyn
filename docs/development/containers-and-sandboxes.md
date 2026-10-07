---
type: runbook
title: "io_uring in Containers and Sandboxes"
description: "Compatibility guide, seccomp configuration, and platform support matrix for running Talyn inside container runtimes and sandboxed environments."
status: stable
sources:
  - src/loop/scheduling/io/main.zig
verified: human-reviewed
tags: [containers, docker, podman, kubernetes, seccomp, io-uring, sandboxes]
timestamp: "2026-10-07T00:00:00Z"
---

[⬅️ Back to Index](index.md)

# 🐳 io_uring in Containers and Sandboxes

Talyn needs working `io_uring` syscalls (`io_uring_setup`, `io_uring_enter`,
`io_uring_register`). A recent kernel alone is not enough: many container
runtimes and sandboxes filter these syscalls out. If Talyn fails at startup
with a permission error during ring creation, check which case you're in:

- `EPERM` from `io_uring_setup` — blocked by a seccomp filter **or** by the
  `kernel.io_uring_disabled` sysctl. Tell them apart with
  `sysctl kernel.io_uring_disabled`: `1` means the sysctl is the cause
  (io_uring then requires `CAP_SYS_ADMIN`), `0` means seccomp is the cause.
- `ENOSYS` — the kernel has no io_uring at all, or the sandbox doesn't
  emulate it. Talyn cannot run there; no workaround.

## Platform Compatibility Matrix

| Platform | Status | How to allow io_uring |
|---|---|---|
| Docker ≥ 25.0 | Blocked by default (seccomp) | `--security-opt seccomp=unconfined`, or a [custom seccomp profile](https://docs.docker.com/engine/security/seccomp/) allowlisting the three syscalls |
| Podman | Blocked by default (seccomp) | `--security-opt seccomp=unconfined`, or a custom profile |
| containerd ≥ 2.0 | Blocked by default (seccomp) | `--security-opt seccomp=unconfined` (nerdctl), or per-pod `securityContext` |
| Kubernetes | Follows the runtime's profile | `seccompProfile.type: Unconfined`, or a `Localhost` custom profile |
| GitHub Actions `container:` jobs | Blocked (Docker's default) | `container.options: --security-opt seccomp=unconfined` |
| gVisor (`runsc`) | Not supported (`ENOSYS`) | — |
| AWS Lambda | Not supported (`ENOSYS`; the syscall isn't in Lambda's kernel) | — |
| Cloud Run gen1 | Not supported (`ENOSYS`; gVisor) | Redeploy with `--execution-environment=gen2` |
| Cloud Run gen2, Fly.io, Kata, Firecracker, LXC/LXD/Incus, GHA native jobs | Works | — |

## Security Policy Background

A wave of io_uring kernel CVEs in 2023–2024 led Docker (v25.0) and containerd
(v2.0) to drop the io_uring syscalls from their default seccomp allowlists.
This is the runtime's security policy, not a Talyn defect — the same binary
runs fine on any normal VM or bare-metal host with a recent kernel.

See also [io_uring Security Hardening](hardening.md) for Talyn's kernel-side defense posture and CVE mitigation analysis.
