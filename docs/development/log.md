# Chronological Update Log — Talyn Documentation Bundle

This log tracks modifications to the Talyn Documentation OKF bundle.

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
- Fixed **BUG-121** (High): `/etc/resolv.conf` with a lone `search .` entry (systemd-resolved stub output when no search domains are configured) crashed loop init with `RuntimeError: InvalidConfiguration`. The search-directive parser now skips a `.` root-domain entry instead of failing hostname validation. See [development/bugs/121.md](development/bugs/121.md).
- Added **native multi-architecture wheel building on x86_64**: Zig's cross-compiler now produces `aarch64` and `riscv64` wheels at full host speed (`scripts/linux/build_all_wheels.sh`, 12 wheels total). `setup.py` detects cross-compilation (skips linking the host's `libpython`, rewrites the extension SOABI suffix for the target arch), and `build.zig` defines `__riscv_float_abi_double` for riscv64 (Zig 0.16 translate-c omission).
- Added **foreign-architecture VM testing**: `scripts/linux/run_tests.sh` boots real Fedora 44 aarch64/riscv64 QEMU VMs and runs the full pytest suite against each installed wheel; `scripts/linux/run_test_all.sh` cross-compiles the extension natively and runs `test_all.sh --no-build` in the VM (~2.4x faster than an in-VM build). QEMU user-mode/containers cannot run Talyn (io_uring is `ENOSYS` under user-mode emulation).
- Improved `scripts/test_all.sh`: per-test timeouts are overridable (`TALYN_TEST_TIMEOUT`, `TALYN_STDLIB_TIMEOUT`) and a failing build no longer silently aborts the suite under `set -e`.
- Documented the full workflow in `README.md` (Fedora 44 prerequisites, build/cross-compile/test, measured timings) and [development/development-journey.md](development/development-journey.md) (v0.8.5 section).
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
- Fixed **BUG-117** (Critical): io_uring registered (fixed) buffer registration failure under `RLIMIT_MEMLOCK` pressure was previously swallowed and tore down `buffer_pool` prematurely. Replaced with a behavior-preserving graceful fallback (`buffers_registered` flag; `lease_buffer()` returns null; consumers fall back to heap buffers; `IO.deinit` keeps a single `buffer_pool.deinit`). See [development/lessons/23-bug-117-registered-buffer-fallback-2026.md](development/lessons/23-bug-117-registered-buffer-fallback-2026.md) and [development/bugs/117.md](development/bugs/117.md).
- Hardened `RegisteredBufferPool.release` with an `index >= SlotCount` bounds guard and documented the `!buffers_registered ⇒ pool-full ⇒ release is a safe no-op` invariant on `IO.release_buffer`.
- Fixed the BUG-117 regression test (`tests/test_buffer_fallback.py`): it failed in the full `test_all.sh` suite because clamping `RLIMIT_MEMLOCK` in the shared pytest process also broke io_uring **ring setup** (per-process pinned-memory budget not yet reclaimed after prior loop teardowns). The scenario now runs in an isolated subprocess for a clean per-process MEMLOCK budget.
- Bumped version to **0.8.1** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — Connection-Creation Memory-Safety Fixes (BUG-118/119/120), Memory-Safety CI, & v0.8.2
- Fixed **BUG-118** (Critical, double-free): `submit_connect_for_address` freed `socket_data` twice on the connect-submit error path — a redundant explicit `allocator.destroy(socket_data)` in the `catch` alongside the top-of-function `errdefer`. Removed the duplicate free; `socket_data` is now freed exactly once, with ownership transferred to the io_uring callback chain on success. Same error class as BUG-04. See [development/bugs/118.md](development/bugs/118.md).
- Fixed **BUG-119** (Critical, double-free): `connection_data` was double-freed when `z_create_socket_connection` failed after `MultiConnectState.init` but before any successful submit (the outer `errdefer` in `create_socket_connection` plus `mcs.deinit`). Made ownership single-owner — `create_socket_connection` owns `connection_data` until `mcs` takes over; a guard `errdefer` frees it only pre-handoff. Removed the outer `errdefer` double-free and captured the future handle up front. See [development/bugs/119.md](development/bugs/119.md).
- Fixed **BUG-120** (Critical, use-after-free): with happy-eyeballs, the first connect freed `mcs` while the `WaitTimer` callback (`schedule_remaining_connects_callback`, `user_data == mcs`) was still pending — cancelling a `WaitTimer` still enqueues the callback (it runs on fire *or* cancel). Made the timer callback the sole teardown owner of `mcs` whenever a timer is scheduled; connect callbacks defer via a `!(timer_scheduled and !timer_fired)` guard. Mirrors BUG-115. See [development/bugs/120.md](development/bugs/120.md).
- Added memory-safety regression coverage: `tests/test_connection_memory_safety.py` (subprocess-based, asserts a clean exit — no SIGSEGV/SIGABRT) for the BUG-118/119 double-free and BUG-120 UAF failure modes, plus repro drivers `tests/resources/repro_submit_fail.py` and `tests/resources/repro_uaf.py`.
- Added `scripts/memcheck.sh` ("ASAN" CI target) and `-Ddebug-alloc` (swaps `utils.gpa` for `std.heap.DebugAllocator(.{ .safety = true })`, the Zig-native double-free/leak checker — Zig 0.16 has no true AddressSanitizer) and `-Dasan` (Zig 0.16 `-fsanitize-c` / UBSan) build options, forwarded through `setup.py` (`TALYN_DEBUG_ALLOC` / `TALYN_ASAN`).
- Properly tore down the `debug_gpa` global in `utils.gpa.deinit()` under `-Ddebug-alloc` via `debug_gpa.deinitWithoutLeakChecks()` (wired through the module `m_free` path), so it is no longer leaked at process exit; no-op for production (`c_allocator`) builds.
- Bumped version to **0.8.2** in `pyproject.toml` and `build.zig.zon`.

## [2026-07-15] — OKF Bundle Cleanup
- Removed 16 zero-byte `docs/priorities/*.orig` backup files left over from the 2026-07-07 OKF conversion. These were empty artifacts and not valid OKF documents.
