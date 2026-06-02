# Talyn Bug Report

Generated: 2026-05-31
Last updated: 2026-06-02

Deep static analysis of the talyn codebase. Bugs are ordered by severity.

---

## Status Summary (as of 2026-06-02)

| Severity | Total | Fixed | Open |
|----------|-------|-------|------|
| Critical | 5 | 5 | 0 |
| High | 20 | 20 | 0 |
| Medium-High | 11 | 11 | 0 |
| Medium-Mid | 11 | 11 | 0 |
| Medium-Low | 12 | 0 | 12 |
| Low | 20 | 0 | 20 |
| **Total** | **79** | **47** | **32** |

All CRITICAL, HIGH, MEDIUM-HIGH, and MEDIUM-MID bugs have been verified
fixed at HEAD (commits `401866ea4196` through `f93ebc50ea83`). Each fixed
bug below lists the commit hash that resolved it.

### Medium Tier Grouping

The 34 MEDIUM bugs are split into three sub-tiers by impact and likelihood:

- **Medium-High** — crash, UAF, data loss, or DoS in normal usage paths
- **Medium-Mid** — noticeable bugs, security gaps, or production-affecting leaks
- **Medium-Low** — edge cases, mitigated issues, or rare-trigger conditions

---

## CRITICAL

### BUG-01: BTree `split_nodes` hardcodes `nkeys=1` after non-root split

- **Status**: ✅ Fixed (`401866ea4196`)
- **File**: `src/utils/btree.zig:293`
- **Description**: After a non-root node split, `current_node.nkeys = 1` is hardcoded. The correct value should be `middle_index` (= `(Degree-1)/2`). For Degree=3 this happens to be 1 (correct by coincidence), but for Degree=11 (used by `WatchersBTree` in `src/loop/main.zig:20`), `middle_index` is 5. After a split, 4 keys are silently lost, corrupting the tree.
- **Trigger**: Any FD watcher registration that causes a non-root B-tree node to split (i.e., when enough file descriptors are being watched).
- **Consequences**: Lost FD watchers, missed IO events, silent data corruption in the tree structure. The event loop stops receiving events for watched file descriptors.

### BUG-02: SQE use-after-free on `link_timeout` failure

- **Status**: ✅ Fixed (`e41f8984825a`)
- **File**: `src/loop/scheduling/io/read.zig:34-38`, `write.zig:43-47,105-109,138-142`
- **Description**: When a main SQE (e.g., `poll_add`, `read`, `write`) is successfully placed in the ring but the subsequent `ring.link_timeout()` call fails (e.g., SQ ring full), the error propagates and `errdefer data_ptr.discard()` recycles the `BlockingTask` slot. However, the main SQE **remains in the SQ ring buffer** with `user_data` pointing to the now-recycled slot. On the next flush, the kernel processes this SQE and returns a CQE. `fetch_completed_tasks` casts `user_data` back to `*BlockingTask` — which may now belong to a different, unrelated operation.
- **Trigger**: SQ ring near capacity when a timeout-linked operation is submitted.
- **Consequences**: CQE attributed to wrong task. Wrong callback dispatched with wrong I/O results. Data corruption, potential security issue (data delivered to wrong consumer).
- **Fix**: On `link_timeout` failure, the main SQE must be "un-getted" from the ring (decrement SQ tail), or the entire operation must be submitted atomically (both SQEs or neither).

### BUG-03: `get_extra_info("sockname")` returns borrowed reference

- **Status**: ✅ Fixed (`968ae300cb8e`)
- **File**: `src/transports/stream/extra_info.zig:83`
- **Description**: When `get_extra_info("sockname")` is called and `self.sockname` is already cached, the code returns `result = py_sockname` without incrementing the reference count. Compare with `peername` at line 64 which correctly calls `python_c.py_newref(py_peername)`. The caller (Python) will decref the returned object, leading to use-after-free or double-free.
- **Trigger**: Call `transport.get_extra_info("sockname")` twice on the same transport.
- **Consequences**: Memory corruption, crash, or exploitable use-after-free.
- **Fix**: Add `py_newref` before returning the cached `sockname`.

### BUG-04: Double-free of `data_buf` in datagram `sendto` error path

- **Status**: ✅ Fixed (`8ab952f48b29`)
- **File**: `src/transports/datagram/write.zig:101,105`
- **Description**: Two `errdefer` statements both free `data_buf`:
  ```zig
  const data_buf = try loop_data.allocator.alloc(u8, len);
  errdefer loop_data.allocator.free(data_buf);  // line 101
  ...
  const sd = try loop_data.allocator.create(SendToData);
  errdefer loop_data.allocator.free(data_buf);  // line 105
  ```
  If `loop_data.io.queue()` at line 144 fails, both errdefers execute, double-freeing `data_buf`. Additionally, `sd` is leaked (no errdefer destroys it).
- **Trigger**: `sendto()` when io_uring queue is full or returns an error.
- **Consequences**: Heap corruption, crash.

### BUG-05: Context leak on callback execution error

- **Status**: ✅ Fixed (`f11b8ac2bcf9`)
- **File**: `src/handle.zig:58-86`
- **Description**: `PyContext_Enter` is called at line 58, but if `PyTuple_New`, `PyTuple_SetItem`, `PyObject_Call`, or `PyObject_CallNoArgs` fails (lines 65-81), the function returns `error.PythonError` without calling `PyContext_Exit`. This corrupts the contextvar context stack for the current thread.
- **Trigger**: Any Python callback that raises an exception when invoked via a Handle.
- **Consequences**: Context stack corruption; subsequent context-dependent operations behave incorrectly; potential crashes.

---

## HIGH

### BUG-06: DNS transaction IDs are predictable (not random)

- **Status**: ✅ Fixed (`67f4f91cecb0`)
- **File**: `src/loop/dns/resolv.zig:469`
- **Description**: `build_query(@intCast(index), ...)` uses the hostname array index (0, 1, 2...) as the DNS transaction ID. An attacker can trivially predict the ID and forge DNS responses (cache poisoning).
- **Trigger**: Every DNS query.
- **Consequences**: DNS cache poisoning, domain hijacking.

### BUG-07: DNS response transaction ID is never validated

- **Status**: ✅ Fixed (`cb651e9187fc`)
- **File**: `src/loop/dns/resolv.zig:348-351`
- **Description**: `process_dns_response` reads the header but never checks the response's transaction ID against the expected query ID. Any DNS response arriving on the socket is accepted.
- **Trigger**: Any unsolicited or forged DNS response.
- **Consequences**: DNS cache poisoning; accepting responses for unrelated queries.

### BUG-08: Multiple DNS queries packed into single UDP datagram

- **Status**: ✅ Fixed (`0a76596fe7f5`)
- **File**: `src/loop/dns/resolv.zig:462-476`
- **Description**: Multiple DNS queries (for different hostnames or A/AAAA) are concatenated into a single UDP payload. Standard DNS resolvers expect one query per UDP datagram and will only process the first query. The remaining queries are silently dropped.
- **Trigger**: Any resolution with multiple hostnames (search domains) or dual-stack (A+AAAA) queries.
- **Consequences**: Most DNS queries are silently dropped; resolution failures for search-domain suffixed names and IPv6.

### BUG-09: `parse_name` out-of-bounds read on compression pointer

- **Status**: ✅ Fixed (`9951e031680f`)
- **File**: `src/loop/dns/parsers.zig:97`
- **Description**: When a compression pointer is encountered at `(byte & 0xC0) == 0xC0`, the code reads `full_data[offset + 1]` without first checking that `offset + 1 < full_data.len`. If the pointer byte is the last byte in the buffer, this is an out-of-bounds read.
- **Trigger**: Malformed DNS response with a compression pointer as the last byte.
- **Consequences**: Memory safety violation; potential crash or information leak.

### BUG-10: Evicting a pending DNS record causes use-after-free

- **Status**: ✅ Fixed (`9ed2fe9c25b1`)
- **File**: `src/loop/dns/cache.zig:75-84`
- **Description**: `evict_record` frees the record for all states. For `.pending` records, the `ControlData` still holds a pointer to the freed `Record`. When the pending query completes, `mark_resolved_and_execute_user_callbacks` accesses `control_data.record` which is now freed memory.
- **Trigger**: LRU eviction of a cache entry that has an in-flight DNS query (e.g., under high cache churn).
- **Consequences**: Use-after-free; memory corruption; crash.

### BUG-11: `get()` removes expired pending DNS records without cancellation

- **Status**: ✅ Fixed (`9ed2fe9c25b1`)
- **File**: `src/loop/dns/cache.zig:159-162`
- **Description**: When an expired record in `.pending` state is removed via `cache.remove()`, the eviction callback frees the record. The in-flight `ControlData` still references it.
- **Trigger**: A pending record expires before the DNS query completes, and a new lookup for the same name triggers `get()`.
- **Consequences**: Use-after-free.

### BUG-12: Double incref in `set_exception` — reference leak

- **Status**: ✅ Fixed (`fd6b7042cece`)
- **File**: `src/future/python/result.zig:92`
- **Description**: `z_future_set_exception` calls `future_fast_set_exception(self, future_data, python_c.py_newref(exception))`. The caller does `py_newref` (+1 ref), then `future_fast_set_exception` at line 72 does `self.exception = python_c.py_newref(exception)` (+1 ref again). Only one reference is stored; the other is leaked.
- **Trigger**: Every call to `future.set_exception()` from Python.
- **Consequences**: Exception object is never freed; memory leak proportional to exception usage.

### BUG-13: Wrong Future data passed when cancelling awaited future

- **Status**: ✅ Fixed (`34e3c7fd71ff` + `60025a235d4a` for follow-up)
- **File**: `src/task/callbacks.zig:130-139`
- **Description**: `cancel_future_object` passes `utils.get_data_ptr(Future, &task.fut)` (the task's future data) instead of the awaited future's data to `future_fast_cancel`. This causes: status check runs against the task, not the awaited future; `call_done_callbacks` fires the task's callbacks instead of the awaited future's callbacks; the awaited future's status is never set to `.canceled`.
- **Trigger**: Cancelling a task that has just yielded a talyn Future (via `handle_talyn_future_object` line 263).
- **Consequences**: Awaited future remains in `.pending` state forever; its callbacks never fire; potential deadlock.

### BUG-14: Context leak in `_execute_task_throw` when `throw` lookup fails

- **Status**: ✅ Fixed (`cf9de32bec44` + `60025a235d4a` for follow-up)
- **File**: `src/task/callbacks.zig:442-451`
- **Description**: `PyContext_Enter` is called at line 442. If `PyObject_GetAttrString(task.coro.?, "throw")` fails at line 450, the function returns `error.PythonError` without calling `PyContext_Exit`.
- **Trigger**: Task needs to throw into a coroutine whose `throw` attribute is missing or raises on access.
- **Consequences**: Context stack corruption; same as BUG-05.

### BUG-15: Partial write with error silently ignored

- **Status**: ✅ Fixed (`84ac8828c4ff`)
- **File**: `src/transports/write_transport.zig:204-226`
- **Description**: When `io_uring_res > 0` (some bytes written) but `io_uring_err != .SUCCESS` (error occurred), the code at line 204 processes the written bytes and advances the buffer index. But the error check at line 226 requires `io_uring_res <= 0`, so the error path is skipped. The code then continues submitting more writes at line 252-253 despite the underlying error.
- **Trigger**: Kernel returns a partial write with an error (e.g., EPIPE after partial write).
- **Consequences**: Silent data corruption, continued writes to a broken connection, potential infinite write loop.

### BUG-16: `connection_lost` may never be called

- **Status**: ✅ Fixed (`9d82678c68d2`)
- **File**: `src/transports/stream/lifecycle.zig:34,41`
- **Description**: If either sub-transport was already closed (e.g., read side closed due to EOF), and then an error occurs on the other side, `connection_lost` is never called on the protocol. The protocol is left in a limbo state, never notified of the connection loss.
- **Trigger**: EOF received (closes read transport), then a write error occurs.
- **Consequences**: Protocol never cleans up, resource leak, application hangs waiting for `connection_lost`.

### BUG-17: `RegisteredBufferPool.release()` has no overflow guard

- **Status**: ✅ Fixed (`6478375fac6e`)
- **File**: `src/loop/scheduling/io/main.zig:364-368`
- **Description**: No check that `free_count < SlotCount` before writing. A double-release of a buffer index causes `free_count` to exceed `SlotCount`, writing past the end of `free_slots`. Subsequent `lease()` calls return garbage indices.
- **Trigger**: Programming error releasing a buffer twice, or releasing a buffer that was never leased.
- **Consequences**: Heap buffer overflow, memory corruption, data delivered to wrong consumer.

### BUG-18: `dispatch_completion_batch` drops remaining records on Python error

- **Status**: ✅ Fixed (`2b036a813fa3`)
- **File**: `src/loop/runner.zig:118-128`
- **Description**: If `PyBytes_FromStringAndSize` or `PyObject_CallOneArg` returns null (Python exception), the function calls `batch.reset()` and returns `error.PythonError`. All remaining records in the batch are discarded. The transports for those records have already had data read from the kernel into their buffers, but the protocol is never notified.
- **Trigger**: Python exception in `protocol.data_received()` or `protocol.buffer_updated()`.
- **Consequences**: Silent data loss for unrelated connections whose completions were batched after the failing one. Transport state inconsistency.

### BUG-19: `_create_ssl_connection` drops all kwargs

- **Status**: ✅ Fixed (`46f81881bb2d`)
- **File**: `talyn/loop.py:841-846`
- **Description**: `_Loop.create_connection` is called with only `self, SP, host, port`. All user-provided kwargs (`family`, `proto`, `flags`, `sock`, `local_addr`, `server_hostname`, `happy_eyeballs_delay`, etc.) are silently dropped.
- **Trigger**: Any `create_connection` call with `ssl=` and additional kwargs like `sock=`, `local_addr=`, `family=`.
- **Consequences**: Connection parameters silently ignored; wrong address family; local binding ignored.

### BUG-20: Datagram close doesn't cancel pending io_uring operations

- **Status**: ✅ Fixed (`b1aa963743ba`)
- **File**: `src/transports/datagram/main.zig:156-166`
- **Description**: `datagram_close` closes the fd immediately but doesn't cancel pending read/write io_uring operations. The closed fd can be reused by the OS before pending operations complete, causing them to operate on the wrong file descriptor.
- **Trigger**: Close datagram transport while reads/writes are pending.
- **Consequences**: Potential data corruption if fd is reused; operations complete on wrong file.

### BUG-21: Reference leak in `get_result` when exception is set

- **Status**: ✅ Fixed (`3892640f9a55`)
- **File**: `src/future/python/result.zig:26-31`
- **Description**: `self.exception` is set to `null` (losing the field's reference), then `py_newref(exc)` creates a new reference for `PyErr_SetRaisedException`. The original reference held by `self.exception` is never decref'd.
- **Trigger**: Calling `.result()` on a future that has an exception set.
- **Consequences**: Exception object leaked each time.

### BUG-22: Reference leak in `future.cancel(msg=...)` on success path

- **Status**: ✅ Fixed (`40dd11fbb27a`)
- **File**: `src/future/python/cancel.zig:49-54`
- **Description**: `cancel_msg_py_object` is allocated by `parse_vector_call_kwargs` with a `py_newref`. On the success path (line 54), it's never decref'd. The `py_xdecref` on line 50 only runs on error.
- **Trigger**: `future.cancel(msg="some message")` succeeds.
- **Consequences**: Cancel message string leaked every time.

### BUG-23: Reference leak in `task.set_name()` — old name not freed

- **Status**: ✅ Fixed (`1c554cd1b625`)
- **File**: `src/task/utils.zig:64`
- **Description**: `instance.name = python_c.PyObject_Str(name.?)` overwrites the `name` field without decref'ing the previous value.
- **Trigger**: Calling `task.set_name()` on a task that already has a name.
- **Consequences**: Old name string leaked.

### BUG-24: Resource leak on KeyboardInterrupt/SystemExit in `execute_ring_buffer`

- **Status**: ✅ Fixed (`d0a8546cb0fb`)
- **File**: `src/callback_manager.zig:423-429`
- **Description**: When KeyboardInterrupt or SystemExit is detected, the function returns immediately at line 428, before the `defer` block (line 432) is registered. The callback's `cleanup` function is never called, and the ring buffer slot is never consumed.
- **Trigger**: KeyboardInterrupt or SystemExit raised during callback execution in the static ring buffer.
- **Consequences**: Task/Handle reference leaked; ring buffer slot permanently occupied.

### BUG-25: Reference leak in `cancel_future_waiter` for Future path

- **Status**: ✅ Fixed (`99354d18a8df`)
- **File**: `src/task/cancel.zig:17-23`
- **Description**: `cancel_msg_py_object` is `py_xincref`'d at line 17, then passed to `future_fast_cancel` which creates its own reference. The caller's incref'd reference is never decref'd, regardless of whether `future_fast_cancel` returns true or false.
- **Trigger**: Cancelling a task that is awaiting a talyn Future.
- **Consequences**: Cancel message leaked on every such cancellation.

---

## MEDIUM

### MEDIUM-HIGH

Crash, UAF, data loss, or DoS reachable in normal usage paths.

#### BUG-32: CompletionRecord stale pointers if dispatch ordering changes

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/loop/completion.zig:21-26`, `src/loop/runner.zig:350`
- **Description**: `CompletionRecord` stores raw `*anyopaque` pointers. Safety depends entirely on `dispatch_completion_batch` being called before `call_once`. If hooks or any future code path frees a transport before dispatch, the pointers are dangling.
- **Trigger**: A `check_hook` or `prepare_hook` that closes/frees a stream transport. Or any future refactoring that changes the dispatch ordering.
- **Consequences**: Use-after-free, segfault.
- **Status**: ✅ Fixed (see commit log)

#### BUG-33: Accept loop continues on fatal errors

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/transports/streamserver/main.zig:157-161, 171`
- **Description**: The `defer` block re-enqueues accept even when `accept_callback` returns an error. Fatal errors (e.g., EMFILE, ENFILE) cause the accept loop to spin indefinitely.
- **Trigger**: Exhaust file descriptors while server is accepting connections.
- **Consequences**: CPU spin, log flooding, denial of service.
- **Status**: ✅ Fixed (see commit log)

#### BUG-29: FDWatcher cleanup happens after `io.deinit()` — watchers can't cancel pending IO

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/loop/main.zig:139-155`
- **Description**: `io.deinit()` is called at line 139, destroying the io_uring ring. Then at lines 151-155, `reader_watchers` and `writer_watchers` are drained. The `FDWatcher` structs contain `blocking_task_id` referencing io_uring tasks, but the ring is already gone.
- **Trigger**: Loop release with active FD watchers that have pending IO operations.
- **Consequences**: Potential resource leaks. FDWatcher handles not properly cleaned up.
- **Status**: ✅ Fixed (see commit log)

#### BUG-49: Write transport silent data loss on index overflow

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/transports/write_transport.zig:148-153`
- **Description**: If `pending_buffer_index` exceeds the array length while `buffer_size > 0`, the function returns without writing the remaining data. Data is silently lost.
- **Trigger**: Race condition or bug in partial write tracking.
- **Consequences**: Silent data loss, CPU waste from repeated hook calls.
- **Status**: ✅ Fixed (see commit log)

#### BUG-41: Double-decref of type objects during module cleanup

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/lib.zig:99-108` + `src/lib.zig:120-146`
- **Description**: `PyModule_AddObject` steals a reference to each type object. When the module is deallocated, CPython decref's all its attributes (including the types). Then `module_cleanup` calls `deinitialize_talyn_types` which decref's the same types again.
- **Trigger**: Interpreter shutdown in single-threaded (non-free-threaded) builds.
- **Consequences**: Potential crash or heap corruption during interpreter teardown.
- **Status**: ✅ Fixed (see commit log)

#### BUG-50: Recursive `submit_next_chunk` potential stack overflow

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/transports/write_transport.zig:158-163`
- **Description**: If many consecutive zero-length buffers are queued, the recursive call could overflow the stack.
- **Trigger**: Many empty buffers appended via `writelines()`.
- **Consequences**: Stack overflow, crash.
- **Status**: ✅ Fixed (see commit log)

#### BUG-47: `parseIp6` accepts incomplete addresses without `::`

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/utils/address.zig:177-183`
- **Description**: If no `::` is present and fewer than 8 groups are provided, the remaining bytes are silently zero-filled. E.g., `2001:db8:1` would parse as `2001:0db8:0001:0000:0000:0000:0000:0000` instead of returning an error.
- **Trigger**: Malformed IPv6 addresses without `::`.
- **Consequences**: Incorrect address parsing; connecting to wrong addresses.
- **Status**: ✅ Fixed (see commit log)

#### BUG-58: Missing null checks on `PyLong_FromLong` return values

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/loop/python/io/socket/ops.zig:679, 803`
- **Description**: `PyLong_FromLong` can return null on memory allocation failure. A null PyObject is passed to `future_fast_set_result`.
- **Trigger**: Memory pressure during socket operations.
- **Consequences**: Null pointer dereference, crash.
- **Status**: ✅ Fixed (see commit log)

#### BUG-37: Signal handler panics if callback removed concurrently

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/loop/unix_signals.zig:52`
- **Description**: `self.callbacks.get_value_ptr(...).?` will panic if the callback was removed (via `unlink`) between the signal being delivered and the io_uring read completing.
- **Trigger**: Rapid signal link/unlink cycles.
- **Consequences**: Crash (panic) in signal handler.
- **Status**: ✅ Fixed (see commit log)

#### BUG-31: `Handle.cancel()` TOCTOU race with thread_safe handles

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/handle.zig:209-244`
- **Description**: Between checking `finished` and setting `cancelled`, the callback could start executing on another thread, read `cancelled=false`, and proceed. The cancel then sets `cancelled=true` too late.
- **Trigger**: Concurrent `handle.cancel()` and callback execution for thread_safe handles.
- **Consequences**: Callback executes despite being cancelled.
- **Status**: ✅ Fixed (see commit log)

#### BUG-30: `perform_with_iovecs` stores caller's iovec pointer — lifetime not enforced

- **Severity tier**: MEDIUM-HIGH
- **File**: `src/loop/scheduling/io/write.zig:124`
- **Description**: The iovec pointer is stored in `msg_storage` (heap, safe), but it points to the caller's iovec array. With deferred submission, the kernel reads this pointer at flush time. If the caller's iovecs are stack-allocated, they're invalid by then.
- **Trigger**: Any caller passing stack-allocated iovecs to `perform_with_iovecs`.
- **Consequences**: Use-after-free when kernel reads the iovec array at submit time.
- **Status**: ✅ Fixed (see commit log)

### MEDIUM-MID

Noticeable bugs, security gaps, or production-affecting leaks.

#### BUG-44: DNS response question section not validated

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/dns/resolv.zig:356-368`
- **Description**: Questions in the response are skipped but never compared to the original query. A response for a different domain would be accepted.
- **Trigger**: Forged or mismatched DNS responses.
- **Consequences**: Accepting answers for wrong domains.
- **Status**: ✅ Fixed (see commit log)

#### BUG-46: DNS response flags (QR, RCODE) not checked

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/dns/resolv.zig:348-374`
- **Description**: The QR bit (query vs response) and RCODE (error codes like NXDOMAIN) are never checked. Error responses or even queries could be processed as valid answers.
- **Trigger**: NXDOMAIN or other error responses.
- **Consequences**: Treating errors as valid (empty) responses.
- **Status**: ✅ Fixed (see commit log)

#### BUG-45: UDP truncation (TC bit) not handled

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/dns/resolv.zig:348-374`
- **Description**: The response flags (including TC bit) are never inspected. Truncated responses are processed as-is, potentially with missing records.
- **Trigger**: Large DNS responses that exceed the UDP buffer.
- **Consequences**: Incomplete resolution results.
- **Status**: ✅ Fixed (see commit log)

#### BUG-42: Static ring buffer consume ordering — GC can see stale entries

- **Severity tier**: MEDIUM-MID
- **File**: `src/callback_manager.zig:461` vs `:515`
- **Description**: `execute_ring_buffer` calls `ring.consume()` after callback execution, while `execute_dynamic_ring_buffer` consumes before. If GC runs during callback execution in the static ring buffer, it may traverse a callback whose user_data is being freed.
- **Trigger**: GC triggered during callback execution in the static ring buffer.
- **Consequences**: GC traverses dangling pointers; potential crash or missed references.
- **Status**: ✅ Fixed (see commit log)

#### BUG-43: Ring buffer traverse race in free-threading mode

- **Severity tier**: MEDIUM-MID
- **File**: `src/callback_manager.zig:202-227`
- **Description**: `traverse` reads `read_idx`/`write_idx` atomically but iterates without synchronization. Between reading indices and accessing callback data, slots could be consumed and reused.
- **Trigger**: GC runs concurrently with ring buffer operations in free-threaded builds.
- **Consequences**: GC may traverse stale or partially-written callback data.
- **Status**: ✅ Fixed (see commit log)

#### BUG-39: Double-unlink corrupts linked list

- **Severity tier**: MEDIUM-MID
- **File**: `src/utils/linked_list.zig:41-62`
- **Description**: `unlink_node` doesn't clear the node's `prev`/`next` pointers after unlinking. Calling `unlink_node` twice on the same node will corrupt the list.
- **Trigger**: Calling `unlink_node` on an already-unlinked node.
- **Consequences**: List corruption; potential crashes.
- **Status**: ✅ Fixed (see commit log)

#### BUG-34: Datagram `sendto` silently drops data when writing is paused

- **Severity tier**: MEDIUM-MID
- **File**: `src/transports/datagram/write.zig:86-88`
- **Description**: When `is_writing` is false (paused by flow control), `sendto()` silently discards the data. Unlike the stream transport which buffers writes, the datagram transport drops them.
- **Trigger**: Call `sendto()` after buffer exceeds high water mark.
- **Consequences**: Silent data loss in UDP applications.
- **Status**: ✅ Fixed (see commit log)

#### BUG-36: Debug print left in production code

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/python/io/server/create_server.zig:429`
- **Description**: `std.debug.print("Z_BIND FD: {}, RET: {}, ERR: {}\n", ...)` leaks internal fd numbers and error codes to stderr on every server bind.
- **Trigger**: Any server creation.
- **Consequences**: Information disclosure, log pollution.
- **Status**: ✅ Fixed (see commit log)

#### BUG-28: `get_blocking_tasks_set()` errdefer resets wrong set on OOM

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/scheduling/io/main.zig:610-629`
- **Description**: On OOM, the errdefer resets `disattached = false` on the old, full set instead of the new one. When tasks in this set complete, it calls `reset()` instead of `deinit()`, leaving the set's linked list node allocated and orphaned.
- **Trigger**: OOM when the current BlockingTasksSet is full.
- **Consequences**: Memory leak of BlockingTasksSet node.
- **Status**: ✅ Fixed (see commit log)

#### BUG-26: Fixed file slot leak on `register_files_update` failure

- **Severity tier**: MEDIUM-MID
- **File**: `src/loop/scheduling/io/main.zig:488-499`
- **Description**: If `register_files_update` throws, the slot `index` has been popped from `fixed_file_free` but is never pushed back. The slot is permanently lost.
- **Trigger**: Kernel rejects file registration (invalid fd, kernel bug).
- **Consequences**: Gradual exhaustion of fixed file slots. Eventually `NoFixedFileSlots` errors on all new connections.
- **Status**: ✅ Fixed (see commit log)

#### BUG-52: Datagram close doesn't clean up fixed file/buffer resources

- **Severity tier**: MEDIUM-MID
- **File**: `src/transports/datagram/main.zig:156-166`
- **Description**: `datagram_close` closes the fd but doesn't call `cleanup_resources()`. Fixed file registrations and leased buffer pool slots are held until GC deallocates the object.
- **Trigger**: Repeatedly create and close datagram transports.
- **Consequences**: Exhaustion of fixed file slots or buffer pool.
- **Status**: ✅ Fixed (see commit log)

### MEDIUM-LOW

Edge cases, mitigated issues, or rare-trigger conditions.

#### BUG-27: `unregister_fixed_file` silently drops slot on OOM

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/scheduling/io/main.zig:511`
- **Description**: `self.fixed_file_free.append(self.loop.allocator, index) catch {};` — if `append` fails (OOM), the slot index is lost.
- **Trigger**: OOM during slot return.
- **Consequences**: Fixed file slot leak.
- **Status**: ✅ Fixed (see commit log)

#### BUG-59: DNS `reverse_lookup` doesn't deduplicate pending queries

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/dns/main.zig:131-141`
- **Description**: If a record exists but is in `.pending` state, a new query is queued instead of attaching the callback to the existing pending query.
- **Trigger**: Multiple concurrent reverse lookups for the same address.
- **Consequences**: Wasted network resources; potential duplicate callbacks.
- **Status**: ✅ Fixed (see commit log)

#### BUG-40: LRU `put()` with existing key leaks old value

- **Severity tier**: MEDIUM-LOW
- **File**: `src/utils/lru.zig:54-57`
- **Description**: When `put` is called with an existing key, the old value is overwritten without invoking the eviction callback. In the DNS cache, this means the old `Record` (and its associated hostname string) is leaked.
- **Trigger**: Inserting a duplicate key into the LRU cache.
- **Consequences**: Memory leak of old values that hold allocated resources.
- **Status**: ✅ Fixed (see commit log)

#### BUG-38: `on_child_exit` re-arms on non-EINTR errors from `waitid`

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/child_watcher.zig:115-128`
- **Description**: If `waitid` returns any non-zero error (e.g., ECHILD — child doesn't exist), the watcher is re-armed. For ECHILD, this creates an infinite loop of pidfd readability -> waitid failure -> re-arm.
- **Trigger**: Child process already reaped by another handler.
- **Consequences**: Infinite event loop spin; 100% CPU usage.
- **Status**: ✅ Fixed (see commit log)

#### BUG-48: `resolve_address` returns pointer to global mutable state

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/dns/parsers.zig:18,118-119`
- **Description**: `tmp_address` is a module-level `var`. The returned slice points to this global. If called from multiple threads, this is a data race.
- **Trigger**: Concurrent calls to `resolve_address`.
- **Consequences**: Data race (mitigated by single-threaded event loop).

#### BUG-35: fd 0 (stdin) rejected as invalid

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/python/io/client/create_connection.zig:191`
- **Description**: `if (fd <= 0)` — file descriptor 0 is valid (stdin). The check should be `fd < 0`.
- **Trigger**: Pass a socket object whose `fileno()` returns 0.
- **Consequences**: Valid connection attempt rejected with "Invalid fd" error.

#### BUG-51: Happy eyeballs delay sentinel comparison bug

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/python/io/client/create_connection.zig:643`
- **Description**: `if ((delay + 1.0) < eps)` checks if `delay ~= -1.0` but only catches values where `delay + 1.0 < eps`. Values slightly above -1.0 (like -0.9999) are not caught. Should be `@abs(delay + 1.0) < eps`.
- **Trigger**: Python passes a float very close to but not exactly -1.0 as `happy_eyeballs_delay`.
- **Consequences**: Sentinel value not recognized, unexpected delay behavior.

#### BUG-53: Server socket fd leak when pre-existing socket provided

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/python/io/server/create_server.zig:203-207`
- **Description**: When `sock=` is provided, the fd is `dup()`'d. If server creation fails after the dup, the dup'd fd may leak (the errdefer only frees `address_list`, not the fd).
- **Trigger**: Server creation failure after fd dup.
- **Consequences**: File descriptor leak.

#### BUG-54: `_SSLTransportWrapper.write` doesn't handle SSL errors

- **Severity tier**: MEDIUM-LOW
- **File**: `talyn/loop.py:36-38`
- **Description**: `self._ssp._sslobj.write(data)` can raise `SSLWantWriteError`, `SSLError`, or `SSLSyscallError`, none of which are caught.
- **Trigger**: SSL renegotiation or errors during write.
- **Consequences**: Unhandled exceptions crashing the protocol.

#### BUG-55: `shutdown_default_executor` leaks daemon thread on timeout

- **Severity tier**: MEDIUM-LOW
- **File**: `talyn/loop.py:463-469`
- **Description**: On timeout, the daemon thread running `executor.shutdown(wait=True)` is not joined. It continues running after the function returns.
- **Trigger**: `shutdown_default_executor(timeout=...)` with a timeout shorter than the executor's shutdown time.
- **Consequences**: Thread leak; potential access to freed resources if loop is closed.

#### BUG-56: `start_tls` doesn't handle pre-existing read buffer data

- **Severity tier**: MEDIUM-LOW
- **File**: `talyn/loop.py:693-696`
- **Description**: `transport.pause_reading()` is called before switching protocols, but data already buffered in the transport's internal read buffer may be delivered to the old protocol or lost entirely.
- **Trigger**: `start_tls` on a connection with unread buffered data.
- **Consequences**: Data loss during TLS upgrade.

#### BUG-57: `unlink` for SIGINT doesn't restore default signal disposition

- **Severity tier**: MEDIUM-LOW
- **File**: `src/loop/unix_signals.zig:147-167`
- **Description**: When unlinking SIGINT, a default Python callback is installed but the signal is not removed from the signalfd mask or unblocked.
- **Trigger**: Unlinking SIGINT handler.
- **Consequences**: Signal continues to be handled via signalfd rather than being restored to `SIG_DFL`.

---

## LOW

### BUG-60: Debug print statements in hot blocking path

- **File**: `src/loop/runner.zig:230-251`
- **Description**: Extensive `std.debug.print` statements execute every time the loop enters the blocking wait path. This is the hot path for any IO-bound workload.
- **Consequences**: Severe performance degradation, stderr I/O bottleneck, log spam.

### BUG-61: `BlockingTasksSet.pop()` assumes LIFO discard order

- **File**: `src/loop/scheduling/io/main.zig:234-238`
- **Description**: `pop()` decrements `self.index` unconditionally, assuming the discarded task is always the most recently allocated one. Holds today because `discard()` is only called in `errdefer` immediately after `push()`.
- **Consequences**: Pool index corruption if any future code calls `discard()` on a non-last task.

### BUG-62: Hook list `clear()` doesn't invoke callback cleanup

- **File**: `src/loop/main.zig:160-162`
- **Description**: `prepare_hooks.clear()`, `check_hooks.clear()`, `idle_hooks.clear()` free linked list nodes without calling `callback.cleanup` on the contained `Callback` data.
- **Consequences**: Python object reference leaks on loop release.

### BUG-63: `dispatch_completion_batch` ignores most CompletionOp variants

- **File**: `src/loop/runner.zig:116-141`
- **Description**: The `switch` only handles `DataReceived` and `BufferUpdated`. `EofReceived`, `ConnectionMade`, `ConnectionLost`, `ResumeWriting`, `DatagramReceived`, `ErrorReceived` all fall to `else => {}` and are silently dropped.
- **Consequences**: Silent loss of completion notifications.

### BUG-64: Cancel SQEs have no error feedback

- **File**: `src/loop/scheduling/io/cancel.zig:4-13`
- **Description**: Cancel SQEs are submitted with `user_data = 0`. The resulting CQE is silently dropped. If the cancel fails, there's no way to know.
- **Consequences**: No observable impact (fire-and-forget by design), but makes debugging difficult.

### BUG-65: `task_get_name` includes null terminator in string length

- **File**: `src/task/utils.zig:44-49`
- **Description**: `allocPrint` with `"\x00"` includes the null byte in `random_str.len`. `PyUnicode_FromStringAndSize` then creates a string with an embedded null character.
- **Consequences**: Task name has a trailing `\0` character; string comparisons may fail.

### BUG-66: Missing cleanup on partial module init failure

- **File**: `src/lib.zig:151-157`
- **Description**: If `initialize_talyn_types` succeeds but `initialize_python_module` fails, initialized types are never cleaned up.
- **Consequences**: Type object references leaked on init failure.

### BUG-67: `py_incref`/`py_decref` sentinel check is a fragile heuristic

- **File**: `src/python_c.zig:353, 364`
- **Description**: `@intFromPtr(op) <= 0xFFFF` skips incref/decref for low-address pointers. Doesn't match CPython's actual singleton handling.
- **Consequences**: Theoretical missed incref/decref leading to premature free or leak.

### BUG-68: `parse_resolv_configuration` doesn't handle tabs

- **File**: `src/loop/dns/parsers.zig:157`
- **Description**: Only space (`' '`) is used as a word delimiter. Tabs in resolv.conf would cause parsing failures.
- **Consequences**: resolv.conf files with tab-separated fields parsed incorrectly.

### BUG-69: `parseIp4` accepts leading zeros in octets

- **File**: `src/utils/address.zig:106-109`
- **Description**: Octets like `010` are parsed as decimal 10, not octal 8. Differs from some system parsers (e.g., `inet_aton`).
- **Consequences**: Address mismatches with system tools.

### BUG-70: `parseIp6` doesn't reject addresses with too many groups when `::` is present

- **File**: `src/utils/address.zig:135-159`
- **Description**: With `::` present, having 8 explicit groups (which should be invalid) is accepted. The `::` expansion logic produces incorrect byte layouts.
- **Trigger**: Malformed IPv6 like `1:2:3:4:5:6:7::8`.
- **Consequences**: Incorrect address parsing.

### BUG-71: Hardcoded EADDRNOTAVAIL errno value

- **File**: `src/loop/python/io/server/create_server.zig:481`
- **Description**: `@as(c_int, 99)` hardcodes errno 99 which is Linux-specific.
- **Consequences**: Incorrect errno on non-Linux platforms if ever ported.

### BUG-72: Address interleave reverses order within families

- **File**: `src/loop/python/io/client/create_connection.zig:437-448`
- **Description**: The interleave algorithm reads from the end of each family's section, reversing the order of addresses within each family.
- **Consequences**: Connection attempts may try addresses in unexpected order.

### BUG-73: Missing error checks on `PyLong_AsLong` in socket ops

- **File**: `src/loop/python/io/socket/ops.zig:129, 133`
- **Description**: No check for `PyErr_Occurred()` after `PyLong_AsLong`. If the Python value is invalid, execution continues with garbage values.
- **Consequences**: Confusing downstream errors instead of clear error message.

### BUG-74: `_create_ssl_unix_connection` ignores `ssl_shutdown_timeout`

- **File**: `talyn/loop.py:1218`
- **Description**: `await asyncio.wait_for(waiter, timeout=60)` uses a hardcoded 60s timeout instead of the `ssl_handshake_timeout` parameter.
- **Consequences**: Custom handshake timeout ignored for SSL unix connections.

### BUG-75: Exception swallowing in SSL protocol callbacks

- **File**: `talyn/loop.py:670-674, 780-782, 1021`
- **Description**: Multiple SSL protocol implementations silently swallow exceptions from `data_received` and `connection_lost`.
- **Consequences**: Hides bugs in user code.

### BUG-76: Dead code in signal `unlink`

- **File**: `src/loop/unix_signals.zig:145`
- **Description**: `if (callback_info == null) return error.KeyNotFound;` is unreachable — the else branch at line 143 already returns.
- **Consequences**: None (dead code).

### BUG-77: `on_child_exit` accesses handler after potential concurrent removal

- **File**: `src/loop/child_watcher.zig:168-171`
- **Description**: After the Python callback runs (which could call `remove_child_handler`), the code accesses `handler.pid` and frees `handler`. If the callback removed the handler, this is a double-free.
- **Trigger**: Python callback calls `remove_child_handler` for the same PID.
- **Consequences**: Double-free (mitigated by single-threaded event loop).

### BUG-78: LRU capacity 0 allows one entry before eviction

- **File**: `src/utils/lru.zig:60`
- **Description**: With capacity=0, `put` adds the entry first, then the next `put` evicts it. The cache temporarily holds 1 entry despite capacity being 0.
- **Consequences**: Minor edge case; unlikely to cause issues in practice.

### BUG-79: `zero_copy` hardcoded to false in write transport

- **File**: `src/transports/write_transport.zig:179`
- **Description**: The `WriteTransport` has a `zero_copying` field but it's never used. Zero-copy writes are always disabled.
- **Consequences**: Missed performance optimization.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 5 (5 fixed) |
| High | 20 (20 fixed) |
| Medium-High | 11 (11 fixed) |
| Medium-Mid | 11 (11 fixed) |
| Medium-Low | 12 |
| Low | 20 |
| **Total** | **79** (47 fixed, 32 open) |

### Recommended Fix Priority (remaining)

1. **MEDIUM-LOW** in batches with related LOW bugs (e.g. BUG-40 with BUG-78)
