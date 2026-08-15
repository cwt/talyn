---
type: index
title: "Bug Tracker — talyn"
description: "Individual bug entries for talyn, one file per bug. 175 bugs discovered across 12 audit passes."
timestamp: "2026-08-16T00:45:00Z"
---

# Bugs — talyn

Sorted by bug number. See individual bug files for details.

[⬅️ Back to Main Index](../../index.md)

## Summary by Severity

| Severity | Count |
|---|---:|
| High | 51 |
| Low | 38 |
| Critical | 25 |
| Medium | 19 |
| Medium-High | 17 |
| Medium-Low | 14 |
| Medium-Mid | 11 |
| **Total** | **175** |

## Summary by Status

| Status | Count |
|---|---:|
| Fixed | 171 |
| Open | 1 |
| False Positive | 3 |
| **Total** | **175** |

## All Bugs

| # | Title | Severity | Status |
|---|---|---|---|
| [1](001.md) | BTree `split_nodes` hardcodes `nkeys=1` after non-root split | Critical | Fixed |
| [2](002.md) | SQE use-after-free on `link_timeout` failure | Critical | Fixed |
| [3](003.md) | `get_extra_info( | Critical | Fixed |
| [4](004.md) | Double-free of `data_buf` in datagram `sendto` error path | Critical | Fixed |
| [5](005.md) | Context leak on callback execution error | Critical | Fixed |
| [6](006.md) | DNS transaction IDs are predictable (not random) | High | Fixed |
| [7](007.md) | DNS response transaction ID is never validated | High | Fixed |
| [8](008.md) | Multiple DNS queries packed into single UDP datagram | High | Fixed |
| [9](009.md) | `parse_name` out-of-bounds read on compression pointer | High | Fixed |
| [10](010.md) | Evicting a pending DNS record causes use-after-free | High | Fixed |
| [11](011.md) | `get()` removes expired pending DNS records without cancellation | High | Fixed |
| [12](012.md) | Double incref in `set_exception` — reference leak | High | Fixed |
| [13](013.md) | Wrong Future data passed when cancelling awaited future | High | Fixed |
| [14](014.md) | Context leak in `_execute_task_throw` when `throw` lookup fails | High | Fixed |
| [15](015.md) | Partial write with error silently ignored | High | Fixed |
| [16](016.md) | `connection_lost` may never be called | High | Fixed |
| [17](017.md) | `RegisteredBufferPool.release()` has no overflow guard | High | Fixed |
| [18](018.md) | `dispatch_completion_batch` drops remaining records on Python error | High | Fixed |
| [19](019.md) | `_create_ssl_connection` drops all kwargs | High | Fixed |
| [20](020.md) | Datagram close doesn't cancel pending io_uring operations | High | Fixed |
| [21](021.md) | Reference leak in `get_result` when exception is set | High | Fixed |
| [22](022.md) | Reference leak in `future.cancel(msg=...)` on success path | High | Fixed |
| [23](023.md) | Reference leak in `task.set_name()` — old name not freed | High | Fixed |
| [24](024.md) | Resource leak on KeyboardInterrupt/SystemExit in `execute_ring_buffer` | High | Fixed |
| [25](025.md) | Reference leak in `cancel_future_waiter` for Future path | High | Fixed |
| [26](026.md) | Fixed file slot leak on `register_files_update` failure | Medium-Mid | Fixed |
| [27](027.md) | `unregister_fixed_file` silently drops slot on OOM | Medium-Low | Fixed |
| [28](028.md) | `get_blocking_tasks_set()` errdefer resets wrong set on OOM | Medium-Mid | Fixed |
| [29](029.md) | FDWatcher cleanup happens after `io.deinit()` — watchers can't cancel pending IO | Medium-High | Fixed |
| [30](030.md) | `perform_with_iovecs` stores caller's iovec pointer — lifetime not enforced | Medium-High | Fixed |
| [31](031.md) | `Handle.cancel()` TOCTOU race with thread_safe handles | Medium-High | Fixed |
| [32](032.md) | CompletionRecord stale pointers if dispatch ordering changes | Medium-High | Fixed |
| [33](033.md) | Accept loop continues on fatal errors | Medium-High | Fixed |
| [34](034.md) | Datagram `sendto` silently drops data when writing is paused | Medium-Mid | Fixed |
| [35](035.md) | fd 0 (stdin) rejected as invalid | Medium-Low | Fixed |
| [36](036.md) | Debug print left in production code | Medium-Mid | Fixed |
| [37](037.md) | Signal handler panics if callback removed concurrently | Medium-High | Fixed |
| [38](038.md) | `on_child_exit` re-arms on non-EINTR errors from `waitid` | Medium-Low | Fixed |
| [39](039.md) | Double-unlink corrupts linked list | Medium-Mid | Fixed |
| [40](040.md) | LRU `put()` with existing key leaks old value | Medium-Low | Fixed |
| [41](041.md) | Double-decref of type objects during module cleanup | Medium-High | Fixed |
| [42](042.md) | Static ring buffer consume ordering — GC can see stale entries | Medium-Mid | Fixed |
| [43](043.md) | Ring buffer traverse race in free-threading mode | Medium-Mid | Fixed |
| [44](044.md) | DNS response question section not validated | Medium-Mid | Fixed |
| [45](045.md) | UDP truncation (TC bit) not handled | Medium-Mid | Fixed |
| [46](046.md) | DNS response flags (QR, RCODE) not checked | Medium-Mid | Fixed |
| [47](047.md) | `parseIp6` accepts incomplete addresses without `::` | Medium-High | Fixed |
| [48](048.md) | `resolve_address` returns pointer to global mutable state | Medium-Low | Fixed |
| [49](049.md) | Write transport silent data loss on index overflow | Medium-High | Fixed |
| [50](050.md) | Recursive `submit_next_chunk` potential stack overflow | Medium-High | Fixed |
| [51](051.md) | Happy eyeballs delay sentinel comparison bug | Medium-Low | Fixed |
| [52](052.md) | Datagram close doesn't clean up fixed file/buffer resources | Medium-Mid | Fixed |
| [53](053.md) | Server socket fd leak when pre-existing socket provided | Medium-Low | Fixed |
| [54](054.md) | `_SSLTransportWrapper.write` doesn't handle SSL errors | Medium-Low | Fixed |
| [55](055.md) | `shutdown_default_executor` leaks daemon thread on timeout | Medium-Low | Fixed |
| [56](056.md) | `start_tls` doesn't handle pre-existing read buffer data | Medium-Low | Fixed |
| [57](057.md) | `unlink` for SIGINT doesn't restore default signal disposition | Medium-Low | Fixed |
| [58](058.md) | Missing null checks on `PyLong_FromLong` return values | Medium-High | Fixed |
| [59](059.md) | DNS `reverse_lookup` doesn't deduplicate pending queries | Medium-Low | Fixed |
| [60](060.md) | Debug print statements in hot blocking path | Low | Fixed |
| [61](061.md) | `BlockingTasksSet.pop()` assumes LIFO discard order | Low | Fixed |
| [62](062.md) | Hook list `clear()` doesn't invoke callback cleanup | Low | Fixed |
| [63](063.md) | `dispatch_completion_batch` ignores most CompletionOp variants | Low | Fixed |
| [64](064.md) | Cancel SQEs have no error feedback | Low | Fixed |
| [65](065.md) | `task_get_name` includes null terminator in string length | Low | Fixed |
| [66](066.md) | Missing cleanup on partial module init failure | Low | Fixed |
| [67](067.md) | `py_incref`/`py_decref` sentinel check is a fragile heuristic | Low | Fixed |
| [68](068.md) | `parse_resolv_configuration` doesn't handle tabs | Low | Fixed |
| [69](069.md) | `parseIp4` accepts leading zeros in octets | Low | Fixed |
| [70](070.md) | `parseIp6` doesn't reject addresses with too many groups when `::` is present | Low | Fixed |
| [71](071.md) | Hardcoded EADDRNOTAVAIL errno value | Low | Fixed |
| [72](072.md) | Address interleave reverses order within families | Low | Fixed |
| [73](073.md) | Missing error checks on `PyLong_AsLong` in socket ops | Low | Fixed |
| [74](074.md) | `_create_ssl_unix_connection` ignores `ssl_shutdown_timeout` | Low | Fixed |
| [75](075.md) | Exception swallowing in SSL protocol callbacks | Low | Fixed |
| [76](076.md) | Dead code in signal `unlink` | Low | Fixed |
| [77](077.md) | `on_child_exit` accesses handler after potential concurrent removal | Low | Fixed |
| [78](078.md) | LRU capacity 0 allows one entry before eviction | Low | Fixed |
| [79](079.md) | `zero_copy` hardcoded to false in write transport | Low | Fixed |
| [80](080.md) | `get_result` null pointer panic on exception | Low | Fixed |
| [81](081.md) | `test_eager_task_factory` timeout/hang | Low | Fixed |
| [82](082.md) | `test_subprocess` timeout/hang | Low | Fixed |
| [83](083.md) | `test_ssl` timeout/hang | Low | Fixed |
| [84](084.md) | `task.coro` use-after-free in exception handler | Low | Fixed |
| [85](085.md) | Use-after-free and memory corruption of context variables in generic python callbacks | Low | Fixed |
| [86](086.md) | `const` type specs cause LLVM const-folding in ReleaseFast | Critical | Fixed |
| [87](087.md) | `allocator.create` + field-by-field initialization leaves new fields uninitialized | High | Fixed |
| [88](088.md) | Hardcoded 5s DNS timeout — not configurable from Python API | Medium-Low | Fixed |
| [89](089.md) | `fixed_buffer_index: u16 = 0xffff` sentinel should be `?u16` | Low | Fixed |
| [90](090.md) | Missing `PyErr_Occurred` checks after `PyLong_As*` across 21 files (all variants) | Medium-High | Fixed |
| [91](091.md) | Context leak in `execute_python_callback` when callback returns null | Critical | Fixed |
| [92](092.md) | `allocator.create` + field-by-field in `create_new_node` — `prev`/`next` uninitialized | Critical | Fixed |
| [93](093.md) | `allocator.create` + field-by-field in BTree `create_node` — `keys`/`values` arrays uninitialized | Critical | Fixed |
| [94](094.md) | `allocator.create` + field-by-field leaves `SocketConnectionData.method` (tagged union) uninitialized | High | Fixed |
| [95](095.md) | Silent `return null` in `z_datagram_get_extra_info` swallows allocation failures | High | Fixed |
| [96](096.md) | 17 bare `else => {}` branches silently discard unhandled switch variants | High | Fixed |
| [98](098.md) | `args[n].?` unwrap without length guards in vectorcall methods | Medium | False Positive |
| [99](099.md) | 14 `except Exception: pass` silent exception swallows in production Python code | Medium | Fixed |
| [100](100.md) | `.?` on optional protocol callbacks and fields that could be null | Medium | Fixed |
| [101](101.md) | Debug print in io_uring error path | Low | Fixed |
| [102](102.md) | 5 `except Exception` silent swallows not covered by BUG-99 fix | Medium | Fixed |
| [103](103.md) | `else => return` without logging in eventfd write failure | Medium | Fixed |
| [104](104.md) | `PyObject_IsInstance` error silently returned as `true` | Medium | Fixed |
| [105](105.md) | `std.debug.panic` in future callback hot path | Low | Fixed |
| [106](106.md) | Module-level mutable state under free-threading | Low | Fixed |
| [107](107.md) | Field-by-field init after `allocator.create` in DNS test | Low | Fixed |
| [108](108.md) | Double-Free / Double-Decref in Callback Handlers | Critical | Fixed |
| [109](109.md) | Refcount Underflow in `WriteTransport` | High | Fixed |
| [110](110.md) | Ghost Reference Cycle in `StreamTransportObject` | Critical | Fixed |
| [111](111.md) | Broken `parseIp6` Logic | High | Fixed |
| [112](112.md) | Missing io_uring Cancellation in `StreamTransport` | High | Fixed |
| [113](113.md) | Pointer Alignment Risk in `tp_traverse` | Medium | Fixed |
| [114](114.md) | `WriteTransport` parent transport reference leak on successful write completion | High | Fixed |
| [115](115.md) | `StreamServerObject` potential use-after-free during in-flight accepts | Critical | Fixed |
| [116](116.md) | Unconditional `CancelByFd` overhead on socket teardown | High | Fixed |
| [117](117.md) | Swallowed error + premature `buffer_pool` teardown when io_uring buffer registration fails under memory pressure | Critical | Fixed |
| [118](118.md) | Double-free of `socket_data` in `submit_connect_for_address` error path | Critical | Fixed |
| [119](119.md) | Double-free of `connection_data` in `create_socket_connection` / `z_create_socket_connection` error path | Critical | Fixed |
| [120](120.md) | Use-after-free of `MultiConnectState` (`mcs`) in happy-eyeballs timer callback | Critical | Fixed |
| [121](121.md) | Loop init fails with `error.InvalidConfiguration` when `/etc/resolv.conf` contains `search .` | High | Fixed |
| [122](122.md) | 34 `catch {}` silent error suppressions across the codebase | Critical | Fixed |
| [123](123.md) | `@cImport` used in `src/loop/unix_signals.zig` | High | Fixed |
| [124](124.md) | Wrong format specifiers `{}` for errors and enums in log messages | High | Fixed |
| [125](125.md) | `std.Thread.yield()` usage in spinlock | High | Fixed |
| [126](126.md) | `std.AutoHashMap` (managed) instead of `std.AutoHashMapUnmanaged` in `child_watcher.zig` | High | Fixed |
| [127](127.md) | `appendAssumeCapacity` used in loop init path | Medium | Fixed |
| [128](128.md) | Unit tests fail to link — libpython symbols unresolved | Medium | Fixed |
| [129](129.md) | `py_xdecref` still has the `0xFFFF` heuristic (partial BUG-67 regression) | Medium | Fixed |
| [130](130.md) | `@constCast` on visit-proc pointer in GC traverse paths | Low | Fixed |
| [131](131.md) | DNS cache stores empty/failed lookup results with infinite TTL (cache poisoning) | High | Fixed |
| [132](132.md) | `py_warn` parameter type mismatch passes `PyObject*` instead of `const char*` | Critical | Fixed |
| [133](133.md) | Inverted `errdefer` in `Future.add_done_callback` pops empty exceptions queue | High | Fixed |
| [134](134.md) | NULL pointer passed to `PyObject_CallOneArg` in `cancel_future_waiter` | Critical | Fixed |
| [135](135.md) | Task cancellation request count skipped when task is awaiting a future | Medium-High | Fixed |
| [136](136.md) | `WriteTransport.queue_eof` silently drops EOF request when write buffer is non-empty | High | False Positive |
| [137](137.md) | Stream write raises `RuntimeError` on paused transport instead of buffering | Medium-High | Fixed |
| [138](138.md) | DNS `validate_hostname` erroneously rejects consecutive hyphens (IDN/Punycode rejection) | High | Fixed |
| [139](139.md) | Argument order mismatch in `create_unix_server` constructor call (`backlog` passed as `family`) | Medium-High | Fixed |
| [140](140.md) | Inverted condition in `Server._detach` causes `Server.wait_closed()` to hang indefinitely | High | Fixed |
| [141](141.md) | PEP 695 generic syntax in `task.py` and `runner.py` incompatible with Python 3.8–3.11 | Medium | Fixed |
| [142](142.md) | Double-add of `Loop` type object in `src/lib.zig` causes reference count underflow | Critical | Fixed |
| [143](143.md) | Parent transport reference leak on I/O read error in `ReadTransport` | High | Fixed |
| [144](144.md) | Reference leak of coroutine, context, and name in `create_task` with custom `task_factory` | High | Fixed |
| [145](145.md) | Double decref and use-after-free of `loop` in `create_server` with custom socket | Critical | Fixed |
| [146](146.md) | `OSError` reference leak on single connection failure in `create_connection` | Medium-High | Fixed |
| [147](147.md) | `FDWatcher` struct and `handle` PyObject leak on Loop release with active watchers | Medium-High | False Positive |
| [148](148.md) | Memory leak in `LRUCache.put` on `map.put` allocation failure | Medium-Low | Fixed |
| [149](149.md) | `PyObject` reference leak via `get_py_none()` default in task stack keyword argument parsing | Low | Fixed |
| [150](150.md) | Leaked `PyUnicode` strings in child watcher and FS watcher exception dictionaries | Low | Fixed |
| [151](151.md) | Broken / uncalled dead code `write_completed` in datagram transport | Low | Fixed |
| [152](152.md) | Unreachable dead code in `UnixSignals.unlink` | Low | Fixed |
| [153](153.md) | `Py_IncRef` called on native `*Loop` pointer in `signal_handler` on default SIGINT disposition | Critical | Fixed |
| [154](154.md) | Uninitialized atomic module pointer storage in `release_python_imports` triggers invalid pointer decref | Critical | Fixed |
| [155](155.md) | `TimerHandle` missing GC payload initialization and `Py_TPFLAGS_HAVE_GC` flag | High | Fixed |
| [156](156.md) | Use-after-free and double-free in `HookHandle.cancel()` | High | Fixed |
| [157](157.md) | `ChildWatcher.on_child_exit` leaks `pidfd`, heap handler, and Python callback on callback exception | High | Fixed |
| [158](158.md) | `BTree.get_min_value_ptr` returns `?Value` instead of `?*Value` | Medium | Fixed |
| [159](159.md) | `pseudosocket_dup` checks `new_fd == -1` instead of `< 0`, missing Linux negative errno syscall failures | Medium | Fixed |
| [160](160.md) | Tautological unsigned comparison and missing error check in `pseudosocket_setsockopt` | Low | Fixed |
| [161](161.md) | Prohibited `lambda` function in `talyn/loop.py` `_TransportWrapper.get_extra_info` | Low | Fixed |
| [162](162.md) | PyObject reference leak on every batch protocol read in `dispatch_completion_batch` | Critical | Fixed |
| [163](163.md) | Use-After-Free and refcount leak on OOM in `ChildWatcher.add_child_handler` | Critical | Fixed |
| [164](164.md) | Tautological `ret >= 0` comparison on unsigned `usize` in `IO.wakeup_eventfd` | High | Fixed |
| [165](165.md) | Unsafe `@as(i32, @intCast(syscall_ret)) < 0` errno check pattern in syscall return handling | High | Fixed |
| [166](166.md) | Heap memory leak on synchronous DNS lookups in `DNS.lookup` | High | Fixed |
| [167](167.md) | Socket file descriptor leak on Python object allocation failure in `sock_accept_callback` | High | Fixed |
| [168](168.md) | File descriptor leak on `tp_alloc` failure in `pseudosocket_dup` | High | Fixed |
| [169](169.md) | Leaked `parent_transport` Python reference on error in `write_operation_completed` | High | Fixed |
| [170](170.md) | Memory and Python handle leak on unhandled exception in `loop_watcher_python_wrapper_callback` | High | Fixed |
| [171](171.md) | Missing port bounds check causing integer overflow panic in `Address.fromPyAddr` | Medium | Fixed |
| [172](172.md) | Memory and reference leaks on failure paths in `z_loop_add_hook` and `z_loop_add_path_watcher` | Medium | Fixed |
| [173](173.md) | Nested GC traversal bug skipping `callback_ptr` when `module_ptr` is null in `UnixSignals` | Medium | Fixed |
| [174](174.md) | Leaked task Python reference on error in `py_wake_up` | Medium | Fixed |
| [175](175.md) | Missing `.cleanup` function pointer on IO queues leading to leaks during loop shutdown | Medium | Fixed |
| [176](176.md) | Infinite DNS TTL when `ttl == maxInt(u32)` in cache violating TTL capping mandate | Medium | Open |
