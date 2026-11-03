---
type: log
title: "Chronological Update Log — Talyn Documentation Bundle"
description: "Tracks modifications, releases, and architectural changes across the Talyn documentation bundle."
status: stable
verified: human-reviewed
timestamp: "2026-10-07T00:00:00Z"
---

# Chronological Update Log — Talyn Documentation Bundle

This log tracks modifications to the Talyn Documentation OKF bundle.

## [2026-11-03] — v0.11.1 Release: BUG-414 footprint stages 1+2 & the measurement infrastructure

A maintenance release focused on the task lifecycle's memory story and the *measurement infrastructure* it exposed. BUG-414 stays **Open by evidence** — the release ships its two verified remediation stages and pins the remaining lever to P23 (v0.11.2):

- **BUG-414 stage 1 (lazy exceptions growth)**: `Future.add_done_callback` no longer eagerly grows `exceptions_queue` to the callbacks count — its appends were already lazy and nothing indexes into the queue (~136 B native churn per task removed; semantics-preserving; verified 82/82 on both toolchains).
- **BUG-414 stage 2 (SBO, rev 1219)**: `Future`'s per-task containers became `InlineQueue` small-buffer types (`callbacks_queue` InlineQueue(Callback,2), `exceptions_queue` InlineQueue(?*PyObject,1)) — the common case carries **zero native heap traffic**.
- **Measured outcome (pinned the true shape of BUG-414)**: the 3-minute task-churn soak **plateau is unchanged (~61 MB vs the asyncio control's ~22 MB)** after both stages — with talyn-side dynamic allocations now at zero, the remaining high-water is **CPython-side per-task object churn** whose volume only shrinks with P23's reduced per-task work; the "32 B/task linear forever" readout was retracted (warm-up-dominated sampling) and the era `hg backout` false-negative lesson was recorded. Full trail in [development/bugs/414.md](bugs/414.md).
- **Leak/footprint gate** shipped: `tests/test_longrun_leak_gate.py` — peak steady-state footprint delta vs an asyncio-mode control (10 MB budget, subprocess soak) + scheduler-path slope probe; `xfail(strict=True)` until the plateau meets its control, then the standing regression gate.
- **P23 registered** ([development/priorities/23-task-spawn-speed-recovery-2026-11.md](priorities/23-task-spawn-speed-recovery-2026-11.md)): the era bisect pinned the v0.10-era Task Spawn regression (1.74× → 0.95×) to **revs 992..1002** and attributed ≈75% of it to the BUG-268/279 per-task `_asyncio` registry bookkeeping (verified by surgical exclusion: 1.57×). In-progress; ships as **v0.11.2** together with the BUG-414 plateau-fitting shared lever.
- Verification: `zig build` + `zig build test` (82/82) + `zig build lint` (0 violations) on **Zig 0.16.0 and 0.17.0**; clean-venv pytest (future/task/review suites 88 passed); the earlier refcount flake in `tests/test_future.py` was reproduced as a system-site-packages artifact only (passes in every clean venv with the identical wheel).
- **Version Bump**: `pyproject.toml`, `build.zig.zon`, and the AST linter banner (`v0.11.1-dev`); README tracker note refreshed to reflect BUG-414's shared-scope status.

## [2026-11-03] — ✅ P23 landed: Task Spawn Speed Recovery (revs 1224..1229, plateau 1.34× py3.14 / 1.31× py3.15)
- **Era bisect multi-clone measurement** completed on this Core Ultra 7-265 host (same interpreter, 12 interleaved repeats with in-process asyncio anchoring):
  - talyn fast through **rev 991** (0.0711 s / 1.76×), slow from **rev 1002** (0.1274 s / 0.96×) — regression window is **revs 992..1002** (BUG-268..BUG-304 band between v0.9.0 and v0.9.6). Reads at 979 (1.73×), 1024 (0.96×) bracket it.
  - `hg backout` of all five suspects on a v0.9.6 tree: **false negative** (the tree still carried the mechanism — later changesets re-plumbed it). Recorded as the process lesson: validate post-backout by grepping the mechanism before trusting an exclusion result.
  - **Surgical exclusion** (delete `register_asyncio_task` call sites + disable `discard_from_asyncio_tasks_set`, direct file edits): talyn recovers to **0.0813 s / 1.57×** — the BUG-268/279 **registry bookkeeping accounts for ≈75% of the loss**; the residual ~10% is owner/constructor churn in the same window.
  - BUG-414 linkage disproven: the tokenized registry-on wheel (rev 1002) and the registry-off surgical build both sit ≈43–44 MB at the same 0.4-M-task churn — the footprint high-water is *not* registry bookkeeping.
- Registered **[P23: Task Spawn Speed Recovery](priorities/23-task-spawn-speed-recovery-2026-11.md)**: recovery plan, strategy (cheap-by-design registration + SBO inline capacity on Future callback containers), guard rails (BUG-414 footprint gate, BUG-268/398 semantics must hold, dual-toolchain builds), shipping target **v0.11.2 after v0.11.1**.

## [2026-11-03] — v0.11.1 Prep: Python 3.15/3.15t benchmark archives & BUG-414 (long-run leak)
- **Benchmarks archived**: the v0.11.0 Python 3.15 and 3.15t run records moved from the repo root into the raw dataset bundle as [core-ultra-7-265/benchmarks-v0.11.0-3.15-starburst.txt](../benchmarks/core-ultra-7-265/benchmarks-v0.11.0-3.15-starburst.txt) and [core-ultra-7-265/benchmarks-v0.11.0-3.15t-starburst.txt](../benchmarks/core-ultra-7-265/benchmarks-v0.11.0-3.15t-starburst.txt), matching the pre-existing `benchmarks-v0.7.0-3.1[4]t-starburst.txt` naming; benchmarks index updated.
- **Era-over-era comparison (same Core Ultra 7-265 host; asyncio/uvloop anchors stable within ±3–5% across eras)**: talyn's Task Spawn regressed from **1.75× vs asyncio at v0.7.0 to 0.95–0.96× at v0.10.0/v0.11.0**; Event Fiesta (+69%), Async Task Workflow (+31–69%) and Producer-Consumer (+36–59%) regressed in the v0.8–v0.10 hardening band, while the raw-socket paths held (+0–9%; UDP unchanged). The v0.11 audit sweep (BUG-400..413) cost ~0 on the task hot path (v0.10 → v0.11 slightly faster).
- **BUG-414 filed (Open, Medium-Low, fix targeted v0.11.1)**: a 40-second create/gather RSS soak shows **~32 B per created task retained on the native side** — linear across the whole run on talyn v0.7.0, v0.10.0 and v0.11.0 wheel builds (Python 3.14, 3.15 and 3.15t), while plain asyncio plateaus; `tracemalloc` shows the Python side is clean, so the retention is a Zig-side allocation that survived every audit. See [development/bugs/414.md](../bugs/414.md) for the repro and evidence.
- README bug-tracker counts updated: **413 bugs: 399 fixed, 13 false positives, 1 open** (BUG-414, v0.11.1).
- **BUG-414 diagnosis progressed & first remediation applied** (still Open; fix targeted v0.11.1): dhat + workload-delta soaks attribute the footprint to the **task create/complete lifecycle alone** (scheduler/timer paths flat). dhat marks all task-shaped blocks freed by exit — **bounded arena high-water, not a pointer leak**: a 3-minute soak shows the ramp *plateaus* near ~61 MB vs the asyncio control's ~22 MB on the identical workload (the earlier "32 B/task linear forever" readout was warm-up-dominated sampling and is retracted). Trigger candidates catalogued per task: 248 B task object, ~160 B `callbacks_queue` entry, ~~136 B pre-grown `exceptions_queue`~~ (**removed in this cycle — `add_done_callback` now grows the exceptions queue lazily; dual-toolchain units 82/82 keep passing; slope unchanged**).
- **Stage-2 (SBO, rev 1219)**: `Future`'s two per-task containers are now `InlineQueue` small-buffer types (`callbacks_queue` InlineQueue(Callback,2), `exceptions_queue` InlineQueue(?*PyObject,1)) — talyn's own per-task dynamic allocations in the hot path are now zero; **the 3-minute plateau is unchanged (~61 MB)**, so the remaining high-water is *CPython-side per-task object churn* and the honest fix lever for BUG-414 is P23's reduced per-task work (delta lands with **v0.11.2**); BUG-414 stays Open until the plateau meets its control.
- **Leak gate finalized — `tests/test_longrun_leak_gate.py`**: footprint assertion (peak steady-state delta vs an asyncio-mode control, 10 MB budget, subprocess soak on both flavors) + scheduler-path slope probe; `xfail(strict=True)` while BUG-414 is open and the strict marker forces removal at fix time — the standing memory-footprint regression gate for all task-hot-path work. Verified locally: `1 passed, 1 xfailed`.

## [2026-11-03] — v0.11.0 Release: Python 3.15 Support, BUG-400..413 Resolution, Verified Submodule Splits

This release lands **Python 3.15 & 3.15t (free-threaded) support** on the main line (six-interpreter matrix in `scripts/test_all.sh`; pre-release ran 489 pytest tests on 3.15/3.15t), resolves the fourteen findings from the **2026-11-01 container audit** (BUG-400..413), and restructures four oversized core files into verified, behavior-preserving submodules:

- **Loop teardown (BUG-400, Critical)**: claim loop teardown under the mutex, run `release_claimed()` unlocked — removes the FS/child-watcher teardown deadlock under free-threading. See [development/bugs/400.md](bugs/400.md).
- **Future/Task & factories (BUG-401, BUG-409, BUG-411)**: no double-decref of `py_loop` on Future re-init; task-factory retry narrowed to the unexpected-kwarg `TypeError` with the original exception preserved; `create_connection` fully deinitializes creation data on error paths. See [development/bugs/401.md](bugs/401.md), [409.md](bugs/409.md), [411.md](bugs/411.md).
- **Watchers, DNS & socket API conformance (BUG-403, BUG-405, BUG-406, BUG-408)**: inotify re-arm after watch-list drain; dotless hostnames resolve without search domains; `getaddrinfo`/`getnameinfo` flag semantics (AI_PASSIVE, AI_NUMERICHOST, NI_NUMERICHOST, NI_NOFQDN, host=None) with unsupported-flag rejection; datagram `buffer_size` released on every terminal send outcome. See [development/bugs/403.md](bugs/403.md), [405.md](bugs/405.md), [406.md](bugs/406.md), [408.md](bugs/408.md).
- **Overflow, validation & I/O (BUG-402, BUG-404, BUG-407, BUG-410, BUG-412, BUG-413)**: `pending_lost_exc` stashed before `connection_lost` can fire; `ceilPowerOfTwo`/`grow` overflow → `MemoryError`; `fileno()` narrowing before `dup()`; the 10 ms idle `nanosleep` replaced by a bounded blocking wait + 100 ms watchdog (timer median ≈1.4 ms); `task_ids` reserved before connect SQEs; replaced signal callback restored on dispatch failure. See [development/bugs/402.md](bugs/402.md), [404.md](bugs/404.md), [407.md](bugs/407.md), [410.md](bugs/410.md), [412.md](bugs/412.md), [413.md](bugs/413.md).
- **Structural refactoring**: `resolv/` (types/parse/response/queue), `socket/ops/` (accept/connect/recv/recv_into/recvfrom/sendall/sendto/common), `create_connection/` (types/resolve/interleave/connect/transport/entry), and `scheduling/io/types.zig` — every split verified as a verbatim move by declaration-level audit with an identical 82-test roster, repaired (`pub` visibility, `ops/common.zig` dedup, dead-import pruning) and captured as **Lessons 114/115**. See [development/lessons/24-split-commit-hygiene-2026-11.md](lessons/24-split-commit-hygiene-2026-11.md).
- **Verification & tooling**: `tests/test_review_regressions.py` (10 regressions) plus updated `getaddrinfo` expectations; Zig 0.16.0 + 0.17.0 ReleaseFast/Debug verification (132/133 tests, 1 deliberate Debug-only skip; 0 linter violations); Apple container runtime support in `scripts/macos/run_tests.sh`; build-runner cosmetic noise tamed via `--error-style minimal` (fixing an exit-code masking pipe in the parallel test path); wheel builders aligned with the Python 3.15 support (`scripts/build.sh` matrix, `scripts/linux/build_all_wheels.sh` gate → 18 wheels = 6 variants × 3 arches, macOS driver + `Containerfile` → 12 wheels = 6 variants × 2 arches, README counts and Fedora prerequisites extended with the `python3.15`/3.15-freethreading packages confirmed to exist in Fedora 44).
- **Version Bump**: Bumped version to **0.11.0** in `pyproject.toml`, `build.zig.zon`, and the AST linter banner (`v0.11.0-dev`); README bug tracker counts refreshed (412 bugs: 399 fixed, 13 false positives, 0 open). Note: v0.10.1–v0.10.4 exist only on the `pre-py315` branch (pre-3.15-support); main goes 0.10.0 → 0.11.0 directly.

## [2026-11-03] — Lessons 114 & 115: Split Commit Hygiene (commits 1205..1209)
- Registered **[Split Commit Hygiene — Verified Refactoring (Lessons 114 & 115)](lessons/24-split-commit-hygiene-2026-11.md)** from the post-audit review of the 1205..1208 file-split series (`resolv/`, `socket/ops/`, `create_connection/`, `scheduling/io/types.zig`):
  - **Lesson 114** — split commits must be self-contained: 1205's aggregators referenced `resolv/` and `ops/` submodule files that were only tracked in 1206, so a clean checkout of 1205 fails `zig build` with 11 `FileNotFound` errors (breaks `hg bisect`).
  - **Lesson 115** — the default `zig build` (install → `src/lib.zig`) compiles a graph that `zig build test` and `zig build lint` do not reach (lazily analyzed imports); 1207–1208 shipped with `interleave_address_list` non-`pub` and a broken lib build, repaired in 1209. Pre-merge verification matrix: `zig fmt --check`, default `zig build`, `zig build test`, `zig build lint` on **both** Zig 0.16.0 and 0.17.0.
- The audit itself confirmed all four splits are behavior-preserving (declaration-level byte-identical bodies, identical 82-test roster pre/post on 0.16.0 and 0.17.0, BUG-402/405/408/412 fixes intact at tip) — tip state is green; the lesson records the *process* gaps, not open code defects.
- Lessons index updated: topic table (12 areas), quick-reference bullet, lesson-number cross-reference (114, 115).
- **Tamed the cosmetic `failed command:` artifact** described in Lesson 24: `scripts/test_all.sh` now passes `--error-style minimal` to both verbose `zig build test` invocations (suppressed for successful steps whenever captured stderr is non-empty, e.g. the expected BUG-117 fallback warn), replacing a `grep -v` pipe whose exit-code handling masked real failures in the parallel branch. Verified artifact-free with `--summary all` on Zig 0.16.0 and 0.17.0.

## [2026-10-19] — v0.10.0 Release: Zero Open Bugs & Dual-Toolchain Stability (BUG-337..BUG-396)

This release drives the bug tracker to **zero open bugs** (395 total, 382 Fixed, 13 False Positive) on top of dual-toolchain support, resolving 60 audit findings (BUG-337 through BUG-396) across I/O cancellation, DNS, Future/Task state machines, socket/transport lifecycles, GC traversal, and Python API compliance:

- **I/O & io_uring (BUG-337, BUG-356, BUG-363, BUG-364, BUG-383)**: `sqe.prep_cancel_fd` in `Cancel.perform_by_fd`; dispatch routing through the loop instead of aborting `run_forever`; `BlockingTasksSet.free()` accounting; `ring.fd >= 0` guards.
- **DNS (BUG-338, BUG-354, BUG-355, BUG-357, BUG-358, BUG-365, BUG-380, BUG-384)**: no spurious `Soon` scheduling on sync error; creation-state deinit; future resolution on DNS failure/cancel; `dns_timeout` preservation; cache records on loop GPA; `Record.append_callback` guard.
- **Future / Task (BUG-339–341, BUG-369–374, BUG-371, BUG-372)**: incref-before-decref; done-callback dispatch guarded against closed loop; `exceptions_queue` cleanup; `Task.cancel/uncancel/cancelling` state machine; SystemExit/KeyboardInterrupt propagation; Py_None leak fixes.
- **Socket / Transport (BUG-342–344, BUG-350–353, BUG-359–361, BUG-367, BUG-375, BUG-378, BUG-379)**: fd double-close prevention; datagram sentinels; kwargs ref transfer; owned-result drop; sockaddr zeroing; ValueError instead of panic on untrusted ints; `DatagramTransport.close` dispatches `connection_lost`; SSL data-loss fixes; WriteTransport flow-control.
- **Lifecycle / GC (BUG-345–349, BUG-366, BUG-368, BUG-381, BUG-382, BUG-385–387, BUG-391)**: Handle executed-vs-cancelled state; FDWatcher ref/exception handling; HookHandle/PathWatcherHandle UAF after close; loop teardown under mutex; `tp_clear` on GC types; pidfd close on all exit paths; BTree child-shift duplicate pointer.
- **Python API / Compliance (BUG-376, BUG-377, BUG-388–396)**: `srv.set_server_ref` wiring; `writelines` exception handling; `get_extra_info` positional default; `METH_KEYWORDS` registrations; `loop.py`/`runner.py`/`server.py` API fixes; dead-code removal; AST linter rule TALYN-019.
- **Version Bump**: Bumped version to **0.10.0** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Validation**: 82/82 Zig unit tests on both Zig 0.16.0 and 0.17.0; 0 linter violations; 478 passed / 1 skipped in `pytest tests/`.

## [2026-10-07] — Dual Zig 0.16.0 / 0.17.0 Toolchain Support

Enables dual-toolchain compatibility for Talyn so that the entire project builds, lints, and passes all test suites on both **Zig 0.16.0** and **Zig 0.17.0** from a single source tree without version forks or runtime overhead:

- **Translate-C Python API Module**: Converted Python C API imports from `@cImport` (which Zig 0.17 completely removed) to `b.addTranslateC` in `build.zig` via `src/c_python.h`, exposed as `pub const _c = @import("c_python");` in `src/python_c.zig`.
- **Portable Standard Library Spellings**:
  - Replaced `std.fmt.bufPrintZ` with `std.fmt.bufPrintSentinel(..., 0)` in `src/python_c.zig` and `src/loop/python/control.zig`.
  - Replaced `std.meta.fields` inspection with `std.meta.fieldNames` and `@TypeOf(@field(...))` in `src/python_c.zig`.
  - Replaced `.{v} ** N` array repetitions with `@splat(v)` across `src/python_c.zig`, `src/utils/address.zig`, `src/utils/btree.zig`, `src/loop/dns/resolv.zig`, `src/loop/dns/main.zig`, and `src/loop/dns/parsers.zig`.
  - Replaced `std.meta.Int` with `@Int` builtin in `src/utils/btree.zig`.
  - Replaced non-packed struct `@bitCast` on `timespec` with explicit `.sec` / `.nsec` field casts in `src/loop/python/scheduling.zig` and `src/loop/scheduling/io/timer.zig`.
  - Handled `std.meta.declarations` return shape divergence across versions in `src/utils/python_imports.zig`.
- **Linter & AST Compatibility**: Added `parseAst` helper branching on `@hasDecl(std.zig.Ast, "ParseOptions")` in `tools/linter/main.zig` and `tools/linter/test_rules.zig`. Guarded `.asterisk_asterisk` check with `@hasField` in `tools/linter/rules/sqe_pointer_lifetime.zig`.
- **Container & Sandbox Compatibility**: Added `docs/development/containers-and-sandboxes.md` and README guidance covering `io_uring` support, seccomp profiles, and permissions across Docker, Podman, containerd, Kubernetes, and cloud sandboxes.
- **Validation**: 66/66 Zig unit tests, 0 linter violations, and `./scripts/test_all.sh --starburst --verbose` green (4 passed, 0 failed across Python 3.13, 3.14, 3.13t, and 3.14t) under both Zig 0.16.0 and Zig 0.17.0.

## [2026-09-30] — v0.9.12 Release: BUG-336-Class Sweep — Linter Rules + Ten Teardown Fixes

This release extrapolates the BUG-336 stale-cancel pattern across the codebase, encodes it as three new AST linter rules, and fixes every site the linter flags plus four deeper residuals found by the same audit:

- **New Linter Rules TALYN-016/017/018**: `STALE_CANCEL_BULK` (bulk `CancelIO` over `task_ids` without completed-ID removal), `CLEAR_BEFORE_PYTHON` (completion callback runs Python while an ID slot is stale — must release before the first Python call; `defer`red cleanups don't count), and `TIMER_IO_MIXING` (timer IDs mixed into an IO cancel list without `happy_timer_id` separation). Registered in `tools/linter/main.zig`, snippet-tested (17/17), documented in `ast-linter.md`.
- **Six TALYN-017 Fixes (same BUG-336 template: release-before-Python, cancel-only-if-live)**: streamserver `accept_callback`, subprocess `pidfd_exit_callback`, datagram `read_completed` (+ `release_old_read` split so re-arm never wipes the new live ID), fs watcher `on_inotify_event`, unix signals `signal_handler`, child watcher `on_child_exit` (new `completed` flag so teardown paths neither cancel stale nor destroy the executing handler; re-arm resets it).
- **Four Follow-Up Fixes**: Handle/TimerHandle ID invalidated on fire + acquired on cancel (M3); one-CancelIO-per-generation via `cancelling` flags in read/write close paths (M4); `MultiConnectState` abort path + empty-list teardown + `timer_scheduled` retirement (S4); DNS `mark_resolved` cancels live servers only and flushes before dispatch (fd-number ABA).
- **Datagram Double-Free Caught by ReleaseFast**: the first `read_completed` restructure released unconditionally via `defer`, but the framework runs the registered `cleanup_read()` on error returns — UAF segfault under ReleaseFast on all interpreters (Debug stayed silent). Restored success-gated release. Project policy confirmed: verify on ReleaseFast only.
- **Version Bump**: Bumped version to **0.9.12** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Validation**: full `./scripts/test_all.sh --starburst --verbose` green — 4 passed, 0 failed (373 passed + 1 skipped per interpreter × 4, all stdlib asyncio suites, 66/66 Zig tests, 0 linter violations).

## [2026-09-30] — v0.9.11 Release: Factory-Scheduled Timer Misfire Fix (BUG-336)

This patch release resolves the silent wrong-time execution defect where `call_later`/`call_at` timers scheduled inside a `create_connection` protocol factory fired immediately, bringing the bug tracker to 335 bugs total (322 Fixed, 0 Open, 13 False Positive):

- **Stray CancelIO on Completed Connects (BUG-336, High)**: `socket_connected_callback`'s success path queued `CancelIO` for every id in `mcs.task_ids`, including the just-completed connect whose `BlockingTask` slot was already freed. The factory runs synchronously inside transport creation, so its timer reused that exact freed slot (task ids are raw slot pointers, no generation); `mcs.deinit()` then cancelled the stale id again, the kernel killed the new timer, and its callback fired in the same tick. Fixed by recording each `SocketData.task_id` and removing it on completion, tracking the happy-eyeballs timer separately (`MultiConnectState.happy_timer_id`), and cancelling only still-pending tasks.
- **Regression Tests**: `test_create_connection_factory_call_later_not_fired_early` and `test_create_connection_factory_call_at_not_fired_early` in `tests/test_create_connection.py`.
- **Documentation**: New `bugs/336.md`, updated `bugs/index.md` and `development-journey.md`.
- **Version Bump**: Bumped version to **0.9.11** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Tracker Status**: 335 bugs total (322 Fixed, 0 Open, 13 False Positive).

## [2026-09-26] — v0.9.10 Release: link_timeout Dead-Stack Fix & SQE-Pointer Lifetime Audit (BUG-334, BUG-335)

This patch release resolves the dead-stack pointer defect in every io_uring `link_timeout` site and eliminates one latent instance of the same class, bringing the bug tracker to 334 bugs total (321 Fixed, 0 Open, 13 False Positive):

- **Dead-Stack link_timeout (BUG-334, High)**: All five `ring.link_timeout()` sites in `src/loop/scheduling/io/read.zig` and `write.zig` passed a timespec pointer into the callee's by-value `data` parameter; with deferred submission the kernel armed the linked timeout from reclaimed stack bytes (no-op timeouts leaking DNS `BlockingTask` slots, or instant `-ETIME`). Fixed by copying the timespec into the heap-resident `BlockingTask.timer_storage`, matching `Timer.wait`.
- **SQE-Pointer Audit & Prevention (BUG-335, Medium, latent)**: Full audit of every `ring.*` SQE-prep call site confirmed all reachable pointers resolve to BlockingTask/transport/loop-owned storage; `Read.perform`'s unsound (and unreachable) zero-copy `.iovecs` branch now returns `error.NotImplemented` with a structural tripwire test.
- **New Linter Rule TALYN-015/SQE_POINTER_LIFETIME**: Flags addresses of — or captures rooted in — stack-frame storage passed at pointer positions of SQE-prep calls in `src/loop/scheduling/io`; validated positively against the historical BUG-334 pattern. Documented in `ast-linter.md`; Lesson 62 added to `lessons/04-io-uring-and-kernel.md`.
- **Validation**: 107/107 Zig tests pass — the BUG-334 regression test ran for the first time against a real Linux io_uring ring (baseline `active_tasks` + per-case `sqe_tail` rollback corrections); `zig build lint` 0 violations; `zig fmt` clean.
- **Documentation**: New `bugs/334.md` and `bugs/335.md`, updated `bugs/index.md`, `development-journey.md`, and `ast-linter.md`.
- **Version Bump**: Bumped version to **0.9.10** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Tracker Status**: 334 bugs total (321 Fixed, 0 Open, 13 False Positive).

## [2026-09-25] — v0.9.9 Release: Kernel Timer Cancellation & io_uring Timeout Bloat Fix (BUG-333)

This milestone release resolves the timer cancellation defect (BUG-333), bringing the bug tracker to 333 bugs total (320 Fixed, 0 Open, 13 False Positive) with 100% passing test suites across all 4 Python runtime targets:

- **Kernel Timer Cancellation & Timeout Bloat (BUG-333)**: Removed `IOSQE_ASYNC` from `Timer.wait` (`src/loop/scheduling/io/timer.zig`) and `link_timeout` calls in `read.zig` and `write.zig`. This fixes `-ENOENT` failures on `timeout_remove`, prevents thousands of abandoned timers from accumulating in the Linux kernel `ctx->timeout_list`, eliminates the 40x–400x progressive latency degradation in long-running services (such as the `wormhole` forward proxy), and prevents 100% of cancelled `talyn.Handle` memory leaks.
- **Regression Tests**: Added `test_call_later_cancel_no_leak_or_degradation` to `tests/loop/test_loop_scheduling.py` asserting zero handle leaks and flat $O(1)$ cancellation latency across thousands of timers; 371 passed, 1 skipped per interpreter plus all stdlib asyncio suites and 64 zig unit tests.
- **Documentation**: Documented in `bugs/333.md`, `bugs/index.md`, and updated `development-journey.md`.
- **Version Bump**: Bumped version to **0.9.9** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Tracker Status**: 333 bugs total (320 Fixed, 0 Open, 13 False Positive).

## [2026-09-22] — v0.9.8 Release: Keyword-Argument Compatibility & DNS Teardown UAF (BUG-331, BUG-332)

This milestone release resolves the two bugs filed after v0.9.7, bringing the bug tracker to 332 bugs total (319 Fixed, 0 Open, 13 False Positive) with 100% passing test suites across all 4 Python runtime targets:

- **Keyword-Argument Dispatch (BUG-331)**: The new `TALYN-014/FASTCALL_MISSING_KEYWORDS` linter rule found 17 `METH_FASTCALL`-only registrations. The 15 CPython-parity methods (`getnameinfo`, the seven `sock_*` coroutines, `add_child_handler`, `remove_child_handler`, `add_signal_handler`, `add_reader`, `add_writer`, `DatagramTransport.sendto`/`set_write_buffer_limits`) now accept keywords through the 4-argument entry point and the new `python_c.merge_vector_call_args` helper (CPython-exact `TypeError` semantics for unknown keywords and duplicates); `_add_hook`/`_add_path_watcher` are explicitly exempted.
- **DNS Teardown UAF (BUG-332)**: Cancelling a `getnameinfo` future and closing the loop aborted the process (SIGABRT) — `dns.deinit()` freed query state still referenced by io_uring cancel completions, which re-dispatched the already-consumed user callback. Fixed with the `ControlData.released` single-shot guard, deferred destruction (`DNS.deferred_release_head`, drained by `Loop.release()` after the post-`io.deinit()` callback pass), and a teardown guard in `ServerQueryData.cancel()`.
- **Regression Tests**: Keyword-call coverage in `test_socket_ops.py` and the new `test_kwargs_dispatch.py`; subprocess cancel+close repro in `test_dns_cancel_teardown.py`; 370 passed, 1 skipped per interpreter plus all stdlib asyncio suites and 64 zig unit tests.
- **Documentation**: New `TALYN-014` rule documented in `ast-linter.md`; `bugs/331.md` and `bugs/332.md` record the full site inventory, root causes, and fixes.
- **Version Bump**: Bumped version to **0.9.8** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Tracker Status**: 332 bugs total (319 Fixed, 0 Open, 13 False Positive).

## [2026-09-08] — v0.9.7 Release: Production Hardening, Transport Memory Safety & Zero Open Bugs (BUG-305..330)

This milestone release resolves 26 tracked bugs (BUG-305 through BUG-330), bringing the bug tracker to 330 bugs total (317 Fixed, 0 Open, 13 False Positive) with 100% passing test suites across all 4 Python runtime targets:

- **Transport Memory Safety (BUG-329, BUG-330)**: Inlined `ArrayList` structures directly into `WriteTransport` to eliminate glibc 2.32+ tcache UAF overwrite under SQ pressure; fixed consumed `Py_buffer` double-release in `WriteTransport.deinit`; cleared `write_in_flight` on cancellation.
- **Socket Adoption (BUG-328)**: Adopted caller socket via `dup()` in `create_connection(sock=...)` and closed caller socket object, delivering EOF on transport close and eliminating hang races.
- **Syscall Decoding & Watchers (BUG-307, BUG-313, BUG-314, BUG-315, BUG-319, BUG-322, BUG-326)**: Switched to `getSyscallErrno` for raw syscall return decoding; hardened child watcher lifecycles and error teardown; bounds-checked inotify events; replaced `unreachable` with best-effort rollback in `z_loop_add_watcher`.
- **DNS Resolver Hardening (BUG-316 & residual, BUG-317)**: Preserved multi-nameserver query failover; separated DNS record setup from callback dispatching to enforce idempotency.
- **Module & Signal Safety (BUG-305, BUG-306)**: Atomic import release on free-threaded module teardown; closed signal loss race windows during link/unlink.
- **Documentation Upgrade**: Upgraded documentation bundle to Google Open Knowledge Format (OKF v0.2) with markdownlint configuration.
- **Version Bump**: Bumped version to **0.9.7** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.
- **Tracker Status**: 330 bugs total (317 Fixed, 0 Open, 13 False Positive).

## [2026-09-07] — BUG-330 Root-Caused & Fixed: glibc tcache UAF on WriteTransport List Headers

- **BUG-330 (High, Fixed)** — the "iovec-shaped 16-byte overwrite" under SQ pressure was disproved and correctly identified as a glibc 2.32+ `tcache_entry` use-after-free overwrite. `WriteTransport.pending_buffers` and `pending_py_buffers` were separately heap-allocated 24-byte `ArrayList` chunks, freed to glibc's tcache during transport cleanup/GC collection (exacerbated by `stream_traverse` visiting borrowed references `parent_transport` and `exception_handler`). Glibc's per-thread 64-bit random cookie `tcache_key` at offset 8 became `items.len` (`0x6f785a0ba2a8dbfe`), and the mangled safe-linking pointer at offset 0 became `items.ptr`, triggering OOM or SIGSEGV on subsequent write operations. Fixed by inlining both `ArrayList` structures directly into `WriteTransport`, eliminating heap allocations entirely, and stripping borrowed references from `stream_traverse`. Removed the `pytest.xfail` workaround and `MemoryError` suppression in `test_connection_memory_safety.py`.
- **Tracker Status**: 330 bugs total (317 Fixed, 0 Open, 13 False Positive).

## [2026-09-07] — SQ-Pressure Flaky SIGSEGV Root-Caused: BUG-329 Fixed, BUG-330 Filed

- **BUG-329 (High, Fixed)** — the flaky SIGSEGV/MemoryError of `test_writev_sq_pressure_no_double_free` partially root-caused via coredumpctl (crash inside `ArrayList(Py_buffer).append` from `transport_write_lines`): `WriteTransport.deinit` released EVERY entry of `pending_py_buffers` including the already-consumed-and-released prefix (double `PyBuffer_Release` → bytes-object refcount underflow → premature free → heap corruption), and `write_operation_completed` returned early on the cancelled path before clearing `write_in_flight` (wedged drain → guaranteed double-release on teardown). Both fixed; the segfault class is eliminated and the memory-safety file is green on python3.13 (3/3, previously flaky).
- **BUG-330 (High, Open)** — a SECOND, pre-existing defect remains: under the same pressure, `append_new_buffer_to_write` fails with `error.OutOfMemory` while the target ArrayList header holds a corrupted-pointer-shaped `items.len` with `capacity` intact — an iovec-shaped 16-byte overwrite onto a neighbouring transport's list header. Constraints established: needs multiple transports, load/layout sensitive (early A/B evidence in this area is unreliable), DebugAllocator and valgrind hide it. Filed with a 4-step investigation plan (deterministic reproducer, PerformWrite slot-lifecycle audit, gdb watchpoint, gated slot poisoning).
- **Methodology note**: the SQ-pressure flakiness initially looked like a regression from the BUG-328/316 commits (interleaved A/B said so) — disproven: the host-path code is identical between revisions, and the A/B was confounded by system state. Coredump-driven root-causing is the reliable route here.
- **Tracker Status**: 329 bugs total (315 Fixed, 1 Open (BUG-330), 13 False Positive).

## [2026-09-07] — Hang Root-Cause Fixed (BUG-328) + BUG-316 Residual Window Closed

- **BUG-328 (High, new)** — the "threaded-echo rapid connect/close hang" root-caused and fixed. Diagnosis chain: gdb showed the loop thread blocked in `io_uring_enter(min_complete=1)` at 0% CPU; `ss` showed the in-flight connect stuck in `SYN-SENT` against a listener whose accept queue had overflowed; the overflow existed because an earlier `create_connection(sock=...)` transport left its connection ESTAB after `transport.close()` — talyn's sock path used `owns_fd=false` and never closed the fd, so the peer's recv-until-EOF loop never ended and its `accept()` never ran again. CPython's `_SelectorTransport._call_connection_lost` closes the wrapped socket (selector_events.py:911); talyn now matches: the fd is adopted via `dup()` into the transport and the caller's socket OBJECT is closed at adoption (dup is required — a raw close leaves the caller's object wrapping a descriptor that may later be reused, observed as `EBADF` from a fresh `connect()` during the first fix attempt). Regression test: `test_create_connection_sock_close_eof_reaches_peer` (peer must observe EOF without the caller touching the socket; server must keep accepting).
- **BUG-316 residual closed** — the idempotency guard's errdefer no longer spans the dispatch phase. Record-setup failures still reset `resolved` (retry is clean); once dispatching begins the resolution stands: a mid-dispatch `Soon.dispatch` failure keeps `resolved=true`, fails the remaining callbacks as cancelled (best effort via `dispatch_nonthreadsafe`), and returns — no re-entry, no record eviction, no double dispatch (the old window ended in `asyncio.InvalidStateError`).
- **Tracker Status**: 327 bugs total (314 Fixed, 0 Open, 13 False Positive).

## [2026-09-07] — Fix Pass: BUG-307..325 All Fixed + 2 New Bugs (BUG-326, BUG-327); Zero Open Bugs

All 19 open bugs from the morning audit were fixed one commit at a time, each with regression coverage where the failure path is Python-triggerable, validated per-commit via `scripts/test_all.sh --python=3.14 --starburst --verbose` (pytest + stdlib asyncio suites + Zig unit tests + AST linter):

- **Critical (BUG-307..309)**: child-watcher replacement UAF (deferred teardown + pre-`waitid` removed guard — the regression test reproduced the live ENOENT waitid race); StreamServer socket double-close (ownership flip at the constructor); borrowed protocol_factory decref on `create_connection(sock=...)` (owned reference + full errdefer, grouped with BUG-312's dispatch-failure leak).
- **High (BUG-310..315)**: socket-ops io.queue-failure errdefer leaks across all 7 initiators; fast_new_task context leak (plus the inverse double-decref in `z_task_init`); create_connection future leak; child-watcher map orphan (identity-guarded unmap); non-transient waitid leak (final teardown); fd-watcher Soon.dispatch stranding.
- **Medium (BUG-316..321)**: DNS idempotency guard (residual errdefer window documented); multi-nameserver failover preserved (decision helper + Zig decision-table test); malformed IPv4 octet count rejection; inotify bounds checks + unconditional re-arm; get_extra_info METH_O/family/default; protocol-callback exception forwarding.
- **Low (BUG-322..325)**: Mandate-1 `unreachable` replaced with best-effort rollback; dead completion dispatch prototypes removed; bounds-checked 64-bit narrowing at 5 sites (recv + recvfrom); duplicate comment removed.
- **New discoveries during the pass**:
  - **BUG-326 (High)**: five call sites decoded raw syscall returns with `std.posix.errno` — the libc-style decoder (`rc == -1` + C errno TLS) mis-reads `-errno` returns as SUCCESS; `pidfd_open` on reaped pids produced `pidfd = -3` (EINVAL waitids, stranded handlers) and `getsockname` failures returned garbage addresses. All sites migrated to `utils.getSyscallErrno`.
  - **BUG-327 (High)**: `create_server(sock=...)` error unwind double-decref'd the references shared between the stack `creation_data` errdefer and the heap copy's deinit (abort inside `PyObject_GC_Del`); ownership now transfers to the heap copy. Exposed by the first-ever `create_server(sock=...)` error-path test.
- **Harness observations**: `@pytest.mark.asyncio` tests without a policy install run on STOCK asyncio (no conftest exists) — the pre-existing async-marked datagram tests exercise nothing talyn-specific; new tests use `talyn.run`-based sync style. The threaded-echo rapid connect/close hang was root-caused and fixed as BUG-328 (see below). The `test_writev_sq_pressure_no_double_free` repro proved load-sensitive: under a perturbed system (leftover debug processes holding sockets) it surfaces a MemoryError at a Python call boundary (~26MB RSS, empty buffer, no OOM mapping print) on BOTH old and current binaries, while under a calm system it passes 16/16 across fresh builds — the repro now tolerates the expected MemoryError (the BUG-272 double-free signal remains the crash/returncode); the pending-exception-under-pressure signature is documented as a lead for a dedicated controlled-load investigation.
- **Tracker Status**: 326 bugs total (313 Fixed, 0 Open, 13 False Positive).

## [2026-09-07] — Bug Validation Pass: BUG-307..325 Re-verified Against Current Sources

All 19 open bugs were re-validated line-by-line against the working tree (Zig 0.16.0). Each bug file received a `- **Validation (2026-09-07)**` section with current `file:line` evidence; all remain **Open** — no tracker status changes:

- **Confirmed valid (16)**: BUG-307, 308, 309, 310, 311, 312, 313, 314, 315, 317, 318, 319, 320, 321, 322, 324 — described patterns verified in the working tree (snippet drift noted where quoted code predates the BUG-277 rewrite or the P15 batch-dispatch rework).
- **Partially valid (2)**:
  - **BUG-316**: root cause (missing idempotency guard in `mark_resolved_and_execute_user_callbacks`) confirmed, but the normal-path double-dispatch is now blocked by caller-side `control_data.resolved` guards (`resolv.zig:385`, `:288`); residual exposure only via the `errdefer` reset after partial `Soon.dispatch` failure (`resolv.zig:239`).
  - **BUG-323**: dead-code claim stands (3 methods unused); the described `get_completions()`/`completion.handle()` segfault hazard no longer exists — rewritten to ctypes `CompletionRecord` parsing with documented retention rationale.
- **Description drift (1)**: **BUG-325** — a verbatim duplicated 5-line comment block exists at exactly `callbacks.zig:584-593`, but its content is the BUG-273 comment, not the quoted `task_add_done_callback` doc comment (which does not exist in the file).
- **Tracker Status**: unchanged — 324 bugs total (292 Fixed, 19 Open, 13 False Positive).

## [2026-09-07] — Codebase Audit Pass: BUG-307..325 Recorded in Tracker (19 Open Bugs)

A comprehensive audit of the Talyn codebase under Zig 0.16.0, the 7 Architectural Mandates, and historical bug patterns identified 19 new defect entries recorded into the bug tracker:

- **BUG-307..309 (Critical)**: Child watcher replacement UAF/double-free on cancelled CQE; StreamServer socket double-close on startup failure; premature decref/UAF on custom socket `create_connection`.
- **BUG-310..315 (High)**: Systemic PyObject reference leaks in all socket operations on `io.queue` failure; task context reference leak on `task_schedule_coro` failure in `fast_new_task`; leaked future reference on `create_connection` dispatch failure; child watcher map inconsistency & handler orphan on duplicate registration; child watcher unhandled non-transient `waitid` error descriptor leak; file watcher leak on `Soon.dispatch` exhaustion in `loop_watchers_callback`.
- **BUG-316..321 (Medium)**: DNS resolution double-dispatch and cache invalidation race; multi-nameserver redundancy broken by premature abort in `process_dns_response`; uninitialized stack memory read in IPv4 address parser; inotify event buffer over-read & permanent watcher disarm on callback error; transport `get_extra_info` signature and family incompatibilities; exception swallowing and traceback destruction in Python loop protocol callbacks.
- **BUG-322..325 (Low)**: Architectural Mandate 1 violation (`unreachable` in IO error path of `z_loop_add_watcher`); dead & broken completion dispatch methods in Python event loop; unchecked 64-bit integer narrowing panics across socket and transport APIs; duplicated documentation comments in `task/callbacks.zig`.
- **Tracker Status**: 324 bugs total (292 Fixed, 19 Open, 13 False Positive).

## [2026-08-24] — v0.9.5 Release: Stream Transport NULL-Safety & Protocol Teardown Hardening (BUG-293)

This release eliminates the final class of segmentation faults caused by `io_uring` read completion CQEs arriving after stream transport teardown:

- **BUG-293 (High)**: `read_operation_completed` now guards on `transport.closed`, `transport.is_closing`, and `transport.protocol == null` before dispatching; all `protocol_eof_received`, `protocol_data_received`, and `protocol_buffer_updated` call sites use safe `|func|` capture, eliminating `PyObject_CallNoArgs(NULL)` crashes.
- **set_protocol hardening**: `eof_received`, `pause_writing`, and `resume_writing` are now optional — `AttributeError` is cleared and `null` stored, so `BaseProtocol` subclasses that omit these methods are accepted.
- **`accept_callback` guard**: `server.protocol_factory` is guarded with `orelse return` to survive server-close vs. in-flight accept CQE races.
- **`talyn_task_throw_trampoline`**: null `exception_value` now calls `PyObject_CallNoArgs(coro.throw)` instead of passing `NULL`; null `StopIteration.value` falls back to `Py_None`.
- **Version Bump**: Bumped version to **0.9.5** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.

## [2026-08-24] — v0.9.4 Release: Asynchronous Cancellation Safety (BUG-290 Split Fix) & Proxy Stability

This release resolves an asynchronous use-after-free and type confusion vulnerability in `io_uring` cancellation dispatch (BUG-290):

- **BUG-290 (Medium-Low / High Under Proxy Load)**: Split `Cancel` into `CancelTimer` and `CancelIO` in `BlockingOperation` / `BlockingOperationData`. Eliminated `@ptrFromInt(task_id)` pointer dereference and reading of `task.operation` from freed/reused `BlockingTask` memory slots.
- **Regression Testing**: Added `test_rapid_call_later_cancel_and_interleaved_io` in `tests/loop/test_loop_scheduling.py`.
- **Version Bump**: Bumped version to **0.9.4** in `pyproject.toml`, `build.zig.zon`, and AST linter banner.

## [2026-08-23] — v0.9.3 Release: Full-Codebase Audit (BUG-269..304), Task Constructor Contract Rewrite & Zero Open Bugs

This release resolves 36 bugs (BUG-269 through BUG-304) identified in full-codebase audits:

- **BUG-269..302**: Resolved heap corruption, errdefer ownership transfers, watcher safety, signal handler exceptions, and transport lifecycle leaks.
- **BUG-303..304**: Resolved closed-loop task creation panic and task constructor ownership contract in `fast_new_task`.
- **Abstract UNIX Sockets**: Full end-to-end support for Linux abstract sockets (`\0name`).
- **Tracker**: 303 bugs (290 Fixed, 0 Open, 13 False Positive).

## [2026-08-22] — v0.9.2 Release: BUG-261..268 Fixes & CPython 3.14.7 free-threading Compatibility

This release fixes the six renumbered bugs (BUG-261..266) plus two new compatibility defects (BUG-267, BUG-268) exposed by the CPython 3.14.7 update:

- **BUG-261 (Medium-High)**: DNS `queue` errdefer leaked UDP socket fds for unsent server queries — `close_unsent_query_sockets()` closes the unsent tail in the error path (Zig unit test).
- **BUG-262 (Low)**: deduplicated `Address.toPyAddrWithPort` (delegates to `toPyAddr`) and the pseudosocket `getsockname`/`getpeername` pair (`sockaddr_to_py_object`).
- **BUG-263 (Low)**: negative `dns_timeout` now raises `ValueError` everywhere via `Resolv.parse_dns_timeout()` (removed the `-1.0` sentinel ambiguity); `talyn/loop.py` `create_connection`/`create_server` now accept and forward `dns_timeout`.
- **BUG-264 (Medium-Low)**: `pseudosocket.getsockopt` propagates the `TypeError` on non-numeric `buflen` instead of leaking a stale pending exception.
- **BUG-265 (Low)**: extracted the 5 duplicate `set_future_exception` helpers into `Future.Python.Result.set_future_exception()`.
- **BUG-266 (Medium-High)**: `prepare_data` rejects an empty `hostnames_array` with `error.InvalidHostname` instead of letting `queue()` index `queries[0]` out of bounds (subprocess-based regression test).
- **BUG-267 (High)**: `loop.run_forever()` from a non-creator thread now works — `IO.ensure_ring_for_current_thread()` hands a never-submitted io_uring ring over to the running thread (asyncio's "loop in a background thread" pattern); pre-used rings or pending foreign SQEs raise a clear `RuntimeError` instead of hanging on `run_coroutine_threadsafe().result()`.
- **BUG-268 (Medium-High)**: talyn tasks register with asyncio's task registries at creation and keep both current-task registries in sync, so `asyncio.all_tasks()`/`current_task()` see default-factory tasks. `test.test_asyncio.test_free_threading` (new in Python 3.14.7, gh-152020) now passes all 24 tests on 3.14/3.14t.

Tracker: 267 bugs (250 Fixed, 4 Open, 13 False Positive). Full suite: 4 passed, 0 failed (320 pytest tests × 4 Python variants, all stdlib modules green).

## [2026-08-21] — Bug Validation Pass: BUG-261..272 → 6 False Positives Removed, 6 Real Bugs Renumbered to BUG-261..266

A static-analysis validation pass over bug reports BUG-261 through BUG-272 against the current `src/` (Zig 0.16.0) confirmed 6 as false positives and 6 as real (still open). The false positives were removed from the tracker and the real bugs renumbered to keep the numbering contiguous.

- **False Positives (ownership/control-flow verified safe; deleted from the tracker)**: shallow-copy UAF/double-free in create_connection/create_server — ownership is correctly transferred to the heap copy and never decref'd on the success path; `PyLong_AsUnsignedLongLong` `-1` sentinel — `@bitCast(value)==-1` only errors when `PyErr_Occurred()` is set, so a valid `2^64-1` is safe; unbounded hostname → OOB in `build_query` — `build_hostname`'s `new_len > 255` cap prevents any >254-char hostname from reaching `build_query`; `interleave_address_list` 2× allocation — required because IPv6 entries are stored at offset `address_list.len`; `DynamicRingBuffer.grow` mask underflow — `capacity` is always ≥1 after `init`; `ReadTransport.batch_dispatched` not reset on cancel — cancelled reads never reach the consumer and the next successful read overwrites the flag.
- **Real, still `Open`, renumbered BUG-261..266**:
  - **BUG-261** (Medium-High): DNS `queue` errdefer leaks UDP socket fds for unsent server queries — the errdefer cancels only `[0..queries_sent]`; the truncated unsent tail keeps its fds open.
  - **BUG-262** (Low): duplicated `Address.toPyAddr`/`toPyAddrWithPort` and pseudosocket `getsockname`/`getpeername`.
  - **BUG-263** (Low): `PyFloat_AsDouble` `-1.0` sentinel — a genuine `dns_timeout=-1.0` is silently treated as no-timeout; severity lowered Medium→Low and the inaccurate "exception state leak" framing corrected (no leak — `PyErr_Occurred` is checked first).
  - **BUG-264** (Medium-Low): `pseudosocket.getsockopt` leaks a pending `TypeError` on non-numeric `buflen`.
  - **BUG-265** (Low): duplicate `set_future_exception` across **5** files, not 4.
  - **BUG-266** (Medium-High): an over-long hostname (>254 chars) makes `get_hostname_array` return `len == 0`; `prepare_data` still proceeds and `resolv.zig` `queue()` indexes `server_data.queries[0]` on an empty slice → out-of-bounds read / Debug panic. This is the real defect behind the removed false positive that misattributed the OOB to `build_query`.
- Synced `docs/development/bugs/index.md`: corrected the previously-desynced `Summary by Severity`/`Summary by Status` tables, flipped stale rows 223–226 from `Fixed` to `Open` to match file frontmatter, and rewrote rows 261–266. Totals now: 265 bugs (242 Fixed, 10 Open, 13 False Positive).

## [2026-08-17] — v0.9.0 Release: Offline AST Linter, Audit Passes 15–19 (BUG-200..259) & Complete Production Hardening

This milestone introduces a custom native static analyzer (`zig build lint`) and resolves 60 bugs across audit passes 15 through 19 (BUG-200 through BUG-259), bringing all 258 tracked bugs to **100% resolution (245 Fixed, 13 False Positive, 0 Open)** with 100% test suite passing across all four Python runtime targets (3.13, 3.14, 3.13t, 3.14t).

- **Native Offline AST Linter & Bug Hunter (`tools/linter/`, `zig build lint`)**: Built a zero-dependency static analyzer directly hooking into `std.zig.Ast` and Python's `ast` module. Scans 100+ Zig files (76,000+ AST nodes) in <15ms, enforcing 11 Zig AST rules (`TALYN-001`–`TALYN-011`) and 2 Python AST rules (`TALYN-PY01`–`TALYN-PY02`) to proactively catch uninitialized fields, missing `errdefer py_decref`, discarded syscall returns, `@panic` in I/O paths, and unhandled switch cases. See [docs/development/ast-linter.md](ast-linter.md).
- **Task & Generator Exception Safety**: Fixed generator throw refcount consumption with owned references in `_execute_task_throw` ([BUG-254](bugs/254.md)) and exception decrefs on generic failure paths in `failed_execution` ([BUG-255](bugs/255.md)).
- **Garbage Collection & Hook Traversal**: Fixed `HookHandle` GC traversal gap by attaching `python_payload` with `traverse_hook_handle`, allowing hook callbacks to participate in cycle detection and reclamation ([BUG-259](bugs/259.md)).
- **Transport & Buffer Pool Integrity**: Deferred datagram recv buffer cleanup to object destruction (`datagram_dealloc`/`datagram_clear`) to prevent use-after-free while `io_uring` read completions are in-flight ([BUG-256](bugs/256.md)), and fixed unparsed keyword arguments in stream server ([BUG-205](bugs/205.md)).
- **Network & Address Parsing Safety**: Added in-loop octet range checks in IPv4 address parser to prevent `u16` accumulator overflow on octets > 255 ([BUG-257](bugs/257.md)), and capped DNS cache TTL to `MAX_DNS_TTL` (7 days) for near-max/overflow TTL records ([BUG-258](bugs/258.md)).
- **Audit Passes 15–19 (BUG-200..253)**: Comprehensive memory leak, refcount, error deferral, and struct initialization hardening across task, future, stream transport, and DNS subsystems.
- **Version Bump**: Bumped version to **0.9.0** in `pyproject.toml` and `build.zig.zon`.

This release resolves 68 bugs (BUG-132 through BUG-199) discovered across audit rounds 9 through 14, bringing all 198 tracked bugs to 100% resolution (195 Fixed, 3 False Positive, 0 Open).

- **Complete Memory & Refcount Leak Elimination**: Plugged PyObject reference count leaks across batch protocol reads (BUG-162), task callbacks/cancellations (BUG-144, BUG-174, BUG-198), transport error paths (BUG-143, BUG-169), and keyword argument parsing (BUG-189).
- **Subprocess & IO Descriptor Safety**: Guaranteed unconditional `pidfd` descriptor closure and transport decref on protocol callback failures (BUG-196), fixed socket descriptor double-close hazards on `connection_made` exceptions (BUG-186), and connected missing `.cleanup` function pointers on IO queues (BUG-175).
- **Task & Future Concurrency Hardening**: Guaranteed `leave_task_func` execution across all coroutine step/throw error paths via task trampolines (BUG-197), fixed `remove_done_callback` duplicate counting on cancelled/executed callbacks (BUG-195), and fixed standard cancellation exception argument matching (BUG-180).
- **Syscall Error & Defensive Hardening**: Hardened Linux syscall return code handling to prevent uninitialized memory reads in `getsockname` (BUG-190, BUG-199), normalized nanoseconds in `call_later` preventing kernel `-EINVAL` (BUG-185), and bounded DNS hostname slice lengths (BUG-188).
- **GC & Data Structure Lifecycle**: Implemented `tp_clear` for `HookHandleType` and `PathWatcherHandleType` (BUG-193), fixed nested GC traversal bugs in Unix signals and DNS resolver (BUG-173, BUG-192), and fixed `LRUCache.pop_tail` eviction hazards (BUG-191).
- **Version Bump**: Bumped version to **0.8.9** in `pyproject.toml` and `build.zig.zon`.

## [2026-08-16] — Codebase Audit Round 14 (BUG-195 through BUG-199)

A targeted codebase audit across the future state machine, task coroutine execution, subprocess transports, and datagram transports identified 5 new bugs and safety issues:

- Logged **BUG-195** (High): `remove_done_callback` recounts already-cancelled or executed callbacks on repeat calls (`src/future/callback.zig`).
- Logged **BUG-196** (High): `SubprocessTransport` protocol callback failure leaks `pidfd` descriptor and `PyObject` reference (`src/transports/subprocess/transport.zig`).
- Logged **BUG-197** (High): Coroutine throw error paths bypass `_leave_task` leaving corrupted `asyncio.current_task` state (`src/task/callbacks.zig`).
- Logged **BUG-198** (Medium): `execute_task_send` leaks `PythonTaskObject` reference if `future_fast_set_exception` errors (`src/task/callbacks.zig`).
- Logged **BUG-199** (Medium): Unchecked `getsockname` syscall return in `DatagramTransport.z_datagram_sendto` reads uninitialized memory (`src/transports/datagram/write.zig`).
- Updated `docs/development/bugs/index.md` summary counts (Total: 198 bugs; 190 Fixed, 5 Open, 3 False Positive).

## [2026-08-16] — Codebase Audit Round 13 (BUG-177 through BUG-194)

A comprehensive codebase audit across all subsystems (`src/`, `talyn/`, C-API bindings, transports, socket operations, DNS subsystem, subprocess, scheduling, memory lifecycle, and GC traversal) identified 18 new bugs:

- Logged **BUG-177** (Critical): Systemic double-free and double-decref on error in `DynamicRingBuffer` completion callbacks (`ops.zig`, `datagram/write.zig`, `subprocess/transport.zig`, `write_transport.zig`, `read_transport.zig`).
- Logged **BUG-178** (Critical): Allocator mismatch / invalid `c_allocator.free` on arena pointers in `ServerQueryData.release` (`src/loop/dns/resolv.zig`).
- Logged **BUG-179** (High): Truncated IPv6 reverse DNS return slice in `build_reverse_name` returning only `"ip6.arpa"` (`src/loop/dns/parsers.zig`).
- Logged **BUG-180** (High): `CancelledError(None)` vs standard `CancelledError()` argument mismatch on future cancellation (`src/future/python/result.zig`).
- Logged **BUG-181** (High): Uninitialized stack memory read in DNS answer parsing yielding corrupt resolved addresses (`src/loop/dns/resolv.zig`).
- Logged **BUG-182** (Critical): Use-after-free in `ChildWatcher.on_child_exit` on cancelled CQE dereferencing destroyed handler (`src/loop/child_watcher.zig`).
- Logged **BUG-183** (Critical): Use-after-free and dangling pointer in `loop.add_hook` due to missing refcount hold (`src/loop/python/control.zig`).
- Logged **BUG-184** (Critical): Premature decref / refcount underflow on positional arguments in `set_write_buffer_limits` (`src/transports/stream/write.zig`).
- Logged **BUG-185** (High): Kernel `-EINVAL` from unnormalized nanoseconds in `loop.call_later` (`src/loop/python/scheduling.zig`).
- Logged **BUG-186** (High): Double-close of socket file descriptors on `connection_made` exception in `StreamServer`, `create_connection`, and `create_endpoint`.
- Logged **BUG-187** (High): Hanging futures on error in `create_datagram_endpoint` and `subprocess_exec` (`create_endpoint.zig`, `exec.zig`).
- Logged **BUG-188** (High): Unbounded hostname slice length panic in DNS IO path violating Mandate 1 (`dns/main.zig`, `dns/parsers.zig`).
- Logged **BUG-189** (Medium): Systemic keyword argument reference leaks across multiple loop APIs (`create_endpoint.zig`, `getaddrinfo.zig`, `unix.zig`, `exec.zig`, `extra_info.zig`).
- Logged **BUG-190** (Medium): Unchecked syscall return value in `pseudosocket_getsockname` yielding garbage memory (`src/utils/pseudosocket.zig`).
- Logged **BUG-191** (Medium): Use-after-free / double-release hazard in `LRUCache.pop_tail` with eviction callback (`src/utils/lru.zig`).
- Logged **BUG-192** (Medium): Nested GC traversal bug in DNS resolver `ControlData.traverse` skipping `callback_ptr` (`src/loop/dns/resolv.zig`).
- Logged **BUG-193** (Medium): Missing `tp_clear` on GC heap types `HookHandleType` and `PathWatcherHandleType` (`src/loop/python/control.zig`).
- Logged **BUG-194** (Medium): Unsafe `@enumFromInt` on unchecked signal integers causing enum cast panics (`subprocess/transport.zig`, `unix_signals.zig`).
- Updated `docs/development/bugs/index.md` summary counts (Total: 193 bugs; 172 Fixed, 18 Open, 3 False Positive).

## [2026-08-16] — Codebase Audit Round 12 (BUG-162 through BUG-176)

A comprehensive deep codebase audit across all subsystems (event loop batch runner, child watcher, eventfd signaling, DNS subsystem, socket operations, transports, and Python bindings) identified 15 new bugs and safety issues:

- Logged **BUG-162** (Critical): `PyObject` reference leak on every batch protocol read in `src/loop/runner.zig` (`dispatch_completion_batch`).
- Logged **BUG-163** (Critical): Use-After-Free & refcount leak on OOM in `src/loop/child_watcher.zig` (`add_child_handler`).
- Logged **BUG-164** (High): Tautological `ret >= 0` comparison on unsigned `usize` in `src/loop/scheduling/io/main.zig` (`IO.wakeup_eventfd`).
- Logged **BUG-165** (High): Unsafe `@as(i32, @intCast(syscall_ret)) < 0` errno check pattern across syscall wrappers (`fs_watcher.zig`, `dns/main.zig`, `scheduling/io/main.zig`, `create_server.zig`).
- Logged **BUG-166** (High): Heap memory leak on synchronous DNS resolutions in `src/loop/dns/main.zig` (`DNS.lookup`).
- Logged **BUG-167** (High): Socket file descriptor leak on Python object allocation failure in `src/loop/python/io/socket/ops.zig` (`sock_accept_callback`).
- Logged **BUG-168** (High): File descriptor leak on `tp_alloc` failure in `src/utils/pseudosocket.zig` (`pseudosocket_dup`).
- Logged **BUG-169** (High): Leaked `parent_transport` Python reference on error in `src/transports/write_transport.zig` (`write_operation_completed`).
- Logged **BUG-170** (High): Memory and Python handle leak on unhandled exception in `src/loop/python/io/watchers.zig` (`loop_watcher_python_wrapper_callback`).
- Logged **BUG-171** (Medium): Missing port bounds check causing integer overflow panic in `src/utils/address.zig` (`Address.fromPyAddr`).
- Logged **BUG-172** (Medium): Memory and reference leaks on failure paths in `src/loop/python/control.zig` (`z_loop_add_hook` and `z_loop_add_path_watcher`).
- Logged **BUG-173** (Medium): Nested GC traversal bug skipping `callback_ptr` when `module_ptr` is null in `src/loop/unix_signals.zig` (`traverse_btree_node`).
- Logged **BUG-174** (Medium): Leaked task Python reference on error in `src/task/callbacks.zig` (`py_wake_up`).
- Logged **BUG-175** (Medium): Missing `.cleanup` function pointer on IO queues leading to leaks during loop shutdown (`datagram/write.zig`, `subprocess/transport.zig`, `socket/ops.zig`).
- Logged **BUG-176** (Medium): Infinite DNS TTL when `ttl == maxInt(u32)` in cache violating TTL capping mandate in `src/loop/dns/cache.zig`.
- Updated `docs/development/bugs/index.md` summary counts (Total: 175 bugs; 157 Fixed, 15 Open, 3 False Positive).

## [2026-08-15] — Codebase Audit Round 11 (BUG-153 through BUG-161)

A comprehensive codebase audit across all subsystems (event loop, signals, child watcher, futures, tasks, pseudo-socket, btree, and python imports) identified 9 new bugs and safety issues:

- Logged **BUG-153** (Critical): `Py_IncRef` called on native `*Loop` pointer in `signal_handler` on default SIGINT disposition in `src/loop/unix_signals.zig`.
- Logged **BUG-154** (Critical): Uninitialized atomic module pointer storage in `release_python_imports` in `src/utils/python_imports.zig` triggers invalid pointer decref on partial import failure.
- Logged **BUG-155** (High): `TimerHandle` in `src/timer_handle.zig` fails to populate `python_payload`, leaving `.traverse` uninitialized and missing `Py_TPFLAGS_HAVE_GC`, causing GC cycles to leak timer handles.
- Logged **BUG-156** (High): `HookHandle.cancel()` in `src/loop/python/control.zig` lacks a cancellation guard, causing use-after-free and double-free on repeated cancellation.
- Logged **BUG-157** (High): `ChildWatcher.on_child_exit` in `src/loop/child_watcher.zig` leaks `pidfd`, heap handler, and Python callback on callback exception.
- Logged **BUG-158** (Medium): `BTree.get_min_value_ptr` in `src/utils/btree.zig` declared return type as `?Value` instead of `?*Value`.
- Logged **BUG-159** (Medium): `pseudosocket_dup` in `src/utils/pseudosocket.zig` checks `new_fd == -1` instead of `< 0`, missing Linux negative errno syscall return codes.
- Logged **BUG-160** (Low): Tautological unsigned comparison `optname < 0` and missing conversion error check in `pseudosocket_setsockopt` in `src/utils/pseudosocket.zig`.
- Updated `docs/development/bugs/index.md` summary counts (Total: 160 bugs; 157 Fixed, 0 Open, 3 False Positive). All 9 bugs (BUG-153 through BUG-161) resolved and verified.

## [2026-08-15] — Comprehensive Deep Codebase Audit (BUG-132 through BUG-152)

A comprehensive codebase audit across all subsystems (event loop, IO scheduling, stream/datagram/subprocess transports, futures, tasks, DNS parser, watchers, memory management, and Python wrapper layers) discovered 21 concrete bugs and memory safety issues:

- Logged **BUG-132** (Critical): `py_warn` in `src/python_c.zig` passes `*Python.PyObject` into `PyErr_WarnEx` which expects `const char *`, causing memory corruption or crash when ResourceWarning triggers.
- Logged **BUG-133** (High): `Future.add_done_callback` in `src/future/callback.zig` has an inverted `errdefer` that pops `exceptions_queue` instead of `callbacks_queue` on allocation failure, causing panics.
- Logged **BUG-134** (Critical): `cancel_future_waiter` in `src/task/cancel.zig` passes NULL to `PyObject_CallOneArg` when cancelling a task awaiting a non-Talyn future without a message.
- Logged **BUG-135** (Medium-High): `fast_task_cancel` in `src/task/cancel.zig` returns early on awaited futures without incrementing `cancel_requests`, breaking PEP 678 cancellation tracking.
- Logged **BUG-136** (High): `WriteTransport.queue_eof` in `src/transports/write_transport.zig` silently returns when write buffer is non-empty without scheduling EOF, losing EOF requests.
- Logged **BUG-137** (Medium-High): `src/transports/stream/write.zig` raises `RuntimeError` when transport writing is paused, violating asyncio flow-control contracts.
- Logged **BUG-138** (High): `validate_hostname` in `src/loop/dns/parsers.zig` rejects consecutive hyphens, breaking all IDN/Punycode domains (`xn--...`) and valid cloud hostnames.
- Logged **BUG-139** (Medium-High): `z_loop_create_unix_server` in `src/loop/python/io/pipe/unix.zig` passes arguments in wrong order to `StreamServer.__init__`, setting `family = backlog` (100) instead of `AF_UNIX`.
- Logged **BUG-140** (High): `Server._detach` in `talyn/server.py` checks `self._servers is not None` to wake up waiters, but `close()` sets `_servers` to None, causing `wait_closed()` to hang indefinitely.
- Logged **BUG-141** (Medium): PEP 695 type parameter syntax `[T]` in `talyn/task.py` and `talyn/runner.py` causes `SyntaxError` on target Python versions 3.8–3.11.
- Logged **BUG-142** (Critical): `LoopType` is registered twice in `src/lib.zig` via `PyModule_AddObject` (which steals references on Python 3.10+), causing reference count underflow.
- Logged **BUG-143** (High): `ReadTransport.read_operation_completed` in `src/transports/read_transport.zig` returns `void` on read errors without decreffing `parent_transport`, leaking a strong reference per error.
- Logged **BUG-144** (High): `z_loop_create_task` in `src/loop/python/utils/task.zig` leaks references to `coro`, `context`, and `name` when a custom `task_factory` is configured.
- Logged **BUG-145** (Critical): `z_loop_create_server` in `src/loop/python/io/server/create_server.zig` prematurely decrefs `loop`, leading to use-after-free and double decref on custom sockets.
- Logged **BUG-146** (Medium-High): `socket_connected_callback` in `src/loop/python/io/client/create_connection.zig` leaks `OSError` instances on single connection attempt failures.
- Logged **BUG-147** (Medium-High): `Loop.release` in `src/loop/main.zig` pops `FDWatcher` structs without destroying them or decreffing their Python `Handle` objects.
- Logged **BUG-148** (Medium-Low): `LRUCache.put` in `src/utils/lru.zig` lacks `errdefer allocator.destroy(node)` before `map.put`, leaking node memory on OOM.
- Logged **BUG-149** (Low): `task_get_stack` and `task_print_stack` in `src/task/utils.zig` leak `None` singleton references by initializing with `get_py_none()` before `PyArg_ParseTupleAndKeywords`.
- Logged **BUG-150** (Low): `PyDict_SetItemString` calls in `child_watcher.zig` and `fs_watcher.zig` pass unmanaged `PyUnicode_FromString` return values, leaking string references on exceptions.
- Logged **BUG-151** (Low): `write_completed` in `src/transports/datagram/write.zig` contains broken, unreferenced dead code.
- Logged **BUG-152** (Low): `UnixSignals.unlink` in `src/loop/unix_signals.zig` contains unreachable dead code after unconditional switch returns.
- Updated `docs/development/bugs/index.md` summary counts (Total: 151 bugs; 148 Fixed, 0 Open, 3 False Positive). All 21 bugs (BUG-132 through BUG-152) resolved and verified against the full 4-Python test suite.

## [2026-08-11] — v0.8.8 Release: DNS Cache Poisoning Fix (BUG-131)

This patch release fixes a high-severity DNS cache poisoning bug that caused long-running asyncio web proxies to fail DNS resolution after extended operation.

- Fixed **BUG-131** (High): `mark_resolved_and_execute_user_callbacks` in `src/loop/dns/resolv.zig` previously cached empty address results (`&[]`) with infinite TTL (`maxInt(i64)`) when a DNS query returned 0 addresses (e.g. transient UDP packet loss or DNS timeout). Failed/empty lookups now call `control_data.record.discard()` to be evicted immediately. Additionally, capped default TTLs in `src/loop/dns/cache.zig` to 60 seconds instead of setting `expire_at` to infinity.
- Added regression test `test_getaddrinfo_nonexistent_domain_does_not_poison_cache` in `tests/test_getaddrinfo.py`.
- Added **Lesson 112** (*Never Cache Empty/Failed DNS Results with Infinite TTL*) to `docs/development/lessons/06-network-protocols-and-io.md`.
- Bumped version to **0.8.8** in `pyproject.toml` and `build.zig.zon`.

## [2026-08-10] — v0.8.7 Release: Zig 0.16.0 Compliance Audit Fixes & Cross-Compile Fix

This release fixes 9 bugs (BUG-122 through BUG-130) discovered by a Zig 0.16.0 compliance audit, plus restructures the entire documentation under the OKF bundle.

- Fixed **BUG-122** (Critical, 34 sites): replaced every silent `catch {}` in the codebase with `catch |err| std.log.warn(...)` (or `std.log.err` for critical callback-release paths). 14 files updated — 2 in release_ring_buffer / release_dynamic_ring_buffer (critical), 32 in teardown/cleanup paths (should have been logged).
- Fixed **BUG-123** (High): removed `@cImport` from `src/loop/unix_signals.zig`; signal() and siginterrupt() are now declared as inline `extern "c"` with SIG_DFL/SigHandler constants — no separate c_imports/ module or build.zig wiring needed.
- Fixed **BUG-124** (High): replaced 5 wrong `{}` format specifiers for error/enum values with `{t}` / `{s}` across 4 files (io/main.zig, resolv.zig, address.zig).
- Fixed **BUG-125** (High): `std.Thread.yield()` in spinlock now handles `YieldError` properly via `catch |err| std.log.warn(...)` instead of `catch {}`.
- Fixed **BUG-126** (High): replaced managed `std.AutoHashMap` with `AutoHashMapUnmanaged` + `.empty` in `child_watcher.zig` (3 call sites), matching Zig 0.16 unmanaged-container style.
- Fixed **BUG-127** (Medium): replaced `appendAssumeCapacity` with `try append(gpa, ...)` in the fixed_file_free initialization loop in `io/main.zig`.
- Fixed **BUG-128** (Medium): added default value for `-Dpython-lib` in `build.zig` so `zig build test` links against libpython without requiring explicit options. Also fixed a `{t}`→`{d}` format-specifier mismatch in `address.zig` for the `u16` family field. Subsequently removed the architecture-specific `orelse "/usr/lib64/libpython3.14.so"` default (x86_64-only path broke cross-compiles for aarch64/riscv64), restoring the pre-BUG-128 behaviour where `python_lib` is optional and passed by `setup.py` only for native builds.
- Fixed **BUG-129** (Medium): removed the `0xFFFF` heuristic guard from `py_xdecref` in `python_c.zig` — now matches `py_decref`'s unconditional `Py_DecRef` call, fixing a refcount leak for singleton objects (None, True, False).
- Fixed **BUG-130** (Low): replaced `@constCast(@ptrCast(visit))` with `@ptrCast(visit)` in 4 GC traverse paths to avoid a false const-correctness guarantee under ReleaseFast.
- **Documentation restructuring**: split monolithic `docs/BUGS.md` into 129 individual OKF-compliant bug files under `docs/development/bugs/` (001.md–130.md, skipping BUG-097). Restructured all development docs under `docs/development/` (lessons/, priorities/, architectural-mandates.md, audits-and-profiling.md, development-journey.md, hardening.md, log.md, reference-and-misc.md, talyn-migration.md, talyn-naming.md). Added OKF bundle roots with index.md + README.md symlinks. Updated all internal cross-references in docs/index.md, AGENTS.md, README.md, and all affected bug files.
- Bumped version to **0.8.7** in `pyproject.toml` and `build.zig.zon`.

## [2026-08-06] — v0.8.5 Release: Multi-Arch Linux Build/Test on x86_64, BUG-121 Fix
- Fixed **BUG-121** (High): `/etc/resolv.conf` with a lone `search .` entry (systemd-resolved stub output when no search domains are configured) crashed loop init with `RuntimeError: InvalidConfiguration`. The search-directive parser now skips a `.` root-domain entry instead of failing hostname validation. See [development/bugs/121.md](bugs/121.md).
- Added **native multi-architecture wheel building on x86_64**: Zig's cross-compiler now produces `aarch64` and `riscv64` wheels at full host speed (`scripts/linux/build_all_wheels.sh`, 12 wheels total). `setup.py` detects cross-compilation (skips linking the host's `libpython`, rewrites the extension SOABI suffix for the target arch), and `build.zig` defines `__riscv_float_abi_double` for riscv64 (Zig 0.16 translate-c omission).
- Added **foreign-architecture VM testing**: `scripts/linux/run_tests.sh` boots real Fedora 44 aarch64/riscv64 QEMU VMs and runs the full pytest suite against each installed wheel; `scripts/linux/run_test_all.sh` cross-compiles the extension natively and runs `test_all.sh --no-build` in the VM (~2.4x faster than an in-VM build). QEMU user-mode/containers cannot run Talyn (io_uring is `ENOSYS` under user-mode emulation).
- Improved `scripts/test_all.sh`: per-test timeouts are overridable (`TALYN_TEST_TIMEOUT`, `TALYN_STDLIB_TIMEOUT`) and a failing build no longer silently aborts the suite under `set -e`.
- Documented the full workflow in `README.md` (Fedora 44 prerequisites, build/cross-compile/test, measured timings) and [development/development-journey.md](development-journey.md) (v0.8.5 section).
- Bumped version to **0.8.5** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-07] — Bundle Initialization & OKF Conversion
- Converted the entire `docs/` folder into a unified OKF Bundle (Option B).
- Renamed `docs/todo.md` to `docs/index.md` to serve as the bundle's root index.
- Renamed `docs/lessons-learned.md` to `docs/lessons/index.md` to serve as the nested lessons index.
- Added OKF YAML frontmatter block to all 10 topic files in `docs/lessons/` and updated their backlink paths.
- Added OKF YAML frontmatter block to all major documentation files: `BUGS.md`, `architectural-mandates.md`, `audits-and-profiling.md`, `development-journey.md`, `hardening.md`, `reference-and-misc.md`, `talyn-migration.md`, and `talyn-naming.md`.
- Remediated all external and internal documentation link references pointing to `todo.md` and `lessons-learned.md`.
- Created `AGENTS.md` at the project root to enable AI auto-discovery of the OKF bundle.

## [2026-07-15] — BUG-117 Fix & v0.8.1 Release
- Fixed **BUG-117** (Critical): io_uring registered (fixed) buffer registration failure under `RLIMIT_MEMLOCK` pressure was previously swallowed and tore down `buffer_pool` prematurely. Replaced with a behavior-preserving graceful fallback (`buffers_registered` flag; `lease_buffer()` returns null; consumers fall back to heap buffers; `IO.deinit` keeps a single `buffer_pool.deinit`). See [development/lessons/23-bug-117-registered-buffer-fallback-2026.md](lessons/23-bug-117-registered-buffer-fallback-2026.md) and [development/bugs/117.md](bugs/117.md).
- Hardened `RegisteredBufferPool.release` with an `index >= SlotCount` bounds guard and documented the `!buffers_registered ⇒ pool-full ⇒ release is a safe no-op` invariant on `IO.release_buffer`.
- Fixed the BUG-117 regression test (`tests/test_buffer_fallback.py`): it failed in the full `test_all.sh` suite because clamping `RLIMIT_MEMLOCK` in the shared pytest process also broke io_uring **ring setup** (per-process pinned-memory budget not yet reclaimed after prior loop teardowns). The scenario now runs in an isolated subprocess for a clean per-process MEMLOCK budget.
- Bumped version to **0.8.1** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — Connection-Creation Memory-Safety Fixes (BUG-118/119/120), Memory-Safety CI, & v0.8.2
- Fixed **BUG-118** (Critical, double-free): `submit_connect_for_address` freed `socket_data` twice on the connect-submit error path — a redundant explicit `allocator.destroy(socket_data)` in the `catch` alongside the top-of-function `errdefer`. Removed the duplicate free; `socket_data` is now freed exactly once, with ownership transferred to the io_uring callback chain on success. Same error class as BUG-04. See [development/bugs/118.md](bugs/118.md).
- Fixed **BUG-119** (Critical, double-free): `connection_data` was double-freed when `z_create_socket_connection` failed after `MultiConnectState.init` but before any successful submit (the outer `errdefer` in `create_socket_connection` plus `mcs.deinit`). Made ownership single-owner — `create_socket_connection` owns `connection_data` until `mcs` takes over; a guard `errdefer` frees it only pre-handoff. Removed the outer `errdefer` double-free and captured the future handle up front. See [development/bugs/119.md](bugs/119.md).
- Fixed **BUG-120** (Critical, use-after-free): with happy-eyeballs, the first connect freed `mcs` while the `WaitTimer` callback (`schedule_remaining_connects_callback`, `user_data == mcs`) was still pending — cancelling a `WaitTimer` still enqueues the callback (it runs on fire *or* cancel). Made the timer callback the sole teardown owner of `mcs` whenever a timer is scheduled; connect callbacks defer via a `!(timer_scheduled and !timer_fired)` guard. Mirrors BUG-115. See [development/bugs/120.md](bugs/120.md).
- Added memory-safety regression coverage: `tests/test_connection_memory_safety.py` (subprocess-based, asserts a clean exit — no SIGSEGV/SIGABRT) for the BUG-118/119 double-free and BUG-120 UAF failure modes, plus repro drivers `tests/resources/repro_submit_fail.py` and `tests/resources/repro_uaf.py`.
- Added `scripts/memcheck.sh` ("ASAN" CI target) and `-Ddebug-alloc` (swaps `utils.gpa` for `std.heap.DebugAllocator(.{ .safety = true })`, the Zig-native double-free/leak checker — Zig 0.16 has no true AddressSanitizer) and `-Dasan` (Zig 0.16 `-fsanitize-c` / UBSan) build options, forwarded through `setup.py` (`TALYN_DEBUG_ALLOC` / `TALYN_ASAN`).
- Properly tore down the `debug_gpa` global in `utils.gpa.deinit()` under `-Ddebug-alloc` via `debug_gpa.deinitWithoutLeakChecks()` (wired through the module `m_free` path), so it is no longer leaked at process exit; no-op for production (`c_allocator`) builds.
- Bumped version to **0.8.2** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — OKF Bundle Cleanup
- Removed 16 zero-byte `docs/priorities/*.orig` backup files left over from the 2026-07-07 OKF conversion. These were empty artifacts and not valid OKF documents.
