[⬅️ Back to Lessons Index](../lessons-learned.md)

# Network Protocols & I/O

Lessons about TCP, SSL/TLS, DNS, datagrams, transport lifecycle, and protocol state machines.

---

### TCP Transport & Connection Lifecycle

**Lesson 40 — `connection_lost` May Never Be Called on Half-Closed Connections**
`close_transports` checked `read_transport.closed OR write_transport.closed` and returned early if either was true. If EOF closed the read side, then a write error occurred on the write side, `connection_lost` was never called — the protocol was left in limbo.
- **Fix:** Changed the check to `transport.closed` (only set when **both** sides are closed and `connection_lost` has been called).
- **Lesson:** When managing bidirectional resources (read/write transports), track overall state separately from individual component states. The protocol's `connection_lost` should be called exactly once when the connection is fully closed. Use a flag on the parent object to track whether the protocol has been notified, rather than checking component states with OR logic.

**Lesson 45 — Partial Write with Error Silently Ignored**
In `write_operation_completed`, when io_uring returned both a partial write (`res > 0`) and an error (`err != .SUCCESS`), the error check required `res <= 0` — so the error was skipped. The code continued submitting more writes despite the broken connection.
- **Fix:** Changed error check from `if (err != .SUCCESS and err != .CANCELED and res <= 0)` to `if (err != .SUCCESS and err != .CANCELED)`.
- **Lesson:** When handling I/O completion callbacks, check errors **independently** of the byte count. A partial write with an error is still an error. Don't assume `res > 0` means success — always check the error code. In io_uring, `res` and `err` can both be set simultaneously.

**Lesson 51 — Pause, Don't Spin, on EMFILE/ENFILE in Accept Loops**
The accept callback unconditionally re-enqueued `accept` while the server was open. When `accept4` returned `EMFILE` or `ENFILE`, the loop spun at 100% CPU flooding logs with errors.
- **Fix:** Added `accept_paused: bool` flag. Error path sets `accept_paused = true` on EMFILE/ENFILE; the defer skips re-enqueue when paused. The flag is cleared by `start_serving`.
- **Lesson:** When a callback encounters a "transient but recurring" error, the response must be **back off**, not **retry immediately**. A boolean pause flag is the minimum viable fix. For production: also add a timer-based recovery loop, notify the protocol's `connection_lost`, and expose `is_paused()` to Python. Ask: "what's the worst case if this error is permanent?" — the answer is almost always "pause, log, require explicit resume."

---

### SSL/TLS

**Lesson 16 — TLS/SSL: Protocol-Layer Approach Over Native Crypto**
uvloop's SSL analysis: **zero** SSL happens in C/libuv — all encryption/decryption happens in a Cython protocol layer using Python's `ssl.MemoryBIO`. The native transport handles only raw encrypted bytes.
- **Key findings:**
  1. `ssl.MemoryBIO` decouples crypto from socket I/O — the protocol reads/writes to in-memory buffers; the transport is crypto-agnostic.
  2. `start_tls` flow: pause reading → `set_protocol` → `connection_made` → resume reading. All at the protocol layer.
  3. 5 explicit states: `UNWRAPPED → DO_HANDSHAKE → WRAPPED → FLUSHING → SHUTDOWN`.
  4. uvloop's Cython code bypasses `get_buffer()`/`buffer_updated()` calls when SSL is active, writing directly to the SSL protocol's internal buffer.

**Lesson 31 — SSL `create_connection` Silently Drops All Kwargs**
`_create_ssl_connection` called `_Loop.create_connection(self, SP, host, port)` without passing any user-provided kwargs (`family`, `proto`, `flags`, `sock`, `local_addr`, etc.). Every connection parameter except host and port was silently discarded.
- **Fix:** Build a kwargs dict from non-None/non-zero parameters and pass via `**kwargs`.
- **Lesson:** When wrapping an internal call that mirrors the public API, always forward **all** parameters explicitly. Silent kwargs dropping is invisible to callers who don't verify their extra parameters take effect.

**Lesson 78 — SSL I/O Functions Can Raise WantRead/WantWrite/Error**
`self._ssp._sslobj.write(data)` can raise `SSLWantWriteError`, `SSLWantReadError`, `SSLError`, or `SSLSyscallError`. None were caught — they propagated and crashed the protocol.
- **Fix:** Added try/except for all four cases. For "want" states, set the corresponding `_write_wants_read` / `_write_wants_write` flag. For errors, schedule fatal teardown via `call_soon`.
- **Lesson:** SSL I/O functions can return a "want" status instead of completing synchronously:
  - **WantRead**: SSL needs more data from the peer. Re-arm the read side.
  - **WantWrite**: SSL needs to write more to the peer. Re-arm the write side.
  - **Error**: connection broken. Close transport and notify protocol.

**Lesson 80 — Drain Buffers Before Protocol Switch**
In `start_tls`, for non-`StreamReaderProtocol` protocols, calling `transport.pause_reading()` is async — data already in the transport's internal read buffer could be delivered to the OLD cleartext protocol before TLS was established.
- **Fix:** Before `pause_reading()`, drain any internal buffer on the raw transport into the SSL incoming MemoryBIO.
- **Lesson:** When switching protocols or upgrading a connection:
  1. Pause reading.
  2. Drain existing buffers to the new protocol.
  3. Switch protocols.
  4. Resume reading with the new protocol.
  "Switch and pray" leads to data loss or security vulnerabilities. This applies to TLS upgrade, HTTP/1→HTTP/2 upgrade, WebSocket upgrade, and connection migration.

---

### DNS

**Lesson 41 — DNS Query Packing: Multiple Queries in Single UDP Datagram (DEFERRED)**
Multiple DNS queries were concatenated into a single UDP payload. Standard DNS resolvers expect one query per UDP datagram and process only the first, silently dropping the rest.
- **Why deferred:** Fixing requires significant architectural changes (~200-300 lines): array of payloads, separate UDP sends, multi-query state machine, partial failure handling, result aggregation.
- **Mitigation:** Lesson 34 (transaction ID validation) prevents cache poisoning even if queries are dropped.
- **Lesson:** Follow the protocol standard — one query per UDP datagram for DNS. Fixing architectural issues in core subsystems requires careful planning and comprehensive testing. Sometimes it's better to defer and add mitigations rather than risk introducing regressions.

**Lesson 42 — DNS Cache Eviction Use-After-Free**
When a pending DNS record was evicted from the cache (LRU or expiration), the record was freed immediately, but `ControlData` still held a pointer to it. When the DNS query completed, it accessed the freed record.
- **Fix:** Added `record_evicted: bool` field to `ControlData`. Set it in `evict_record`. Check before accessing the record in `mark_resolved_and_execute_user_callbacks`.
- **Lesson:** When managing cached resources with async operations, track the lifecycle of both the cache entry and the operation that references it. If a cache entry can be evicted while an operation is in-flight, the operation must check validity before using its reference. Use explicit flags (like `record_evicted`) to track eviction state.

**Lesson 43 — DNS Cache `get()` Removes Pending Records Without Cancellation**
Same root cause as Lesson 42 — `Cache.get` triggered eviction of pending records on expiry, causing the same use-after-free.
- **Lesson:** When removing cache entries, consider whether there are in-flight operations that reference them. Simply freeing is not enough — either cancel the operations or mark the entry invalid so operations can detect the eviction. The fix for Lesson 42 automatically fixed this by checking `record_evicted` in both code paths.

**Lesson 44 — Wrong Future Data Passed When Cancelling Awaited Future**
`cancel_future_object` called `future_fast_cancel(future, utils.get_data_ptr(Future, &task.fut), cancel_msg)`. The second parameter was supposed to be the awaited future's data, but instead passed `&task.fut` — the task's own future data.
- **Fix:** Changed to `utils.get_data_ptr(Future, future)`.
- **Lesson:** When working with multiple futures in a task (the task's own future and futures it's awaiting), be careful about which future's data you pass. Always verify you're passing the correct object, not just any future that happens to be in scope.

---

### Signal Handling

**Lesson 81 — Signal Unregistration Must Reverse Signal Registration**
`unlink` for SIGINT only installed a `default_sigint_signal_callback` but did NOT unblock the signal from the process mask or remove it from the signalfd. After unlinking SIGINT: the signal was still blocked, still in the signalfd mask, but the signalfd no longer had SIGINT in its mask — so Ctrl+C was lost.
- **Fix:** For SIGINT, perform the same cleanup as the else branch: unblock the signal, remove it from signalfd, restore SIG_DFL.
- **Lesson:** Signal unregistration must reverse **every step** of signal registration:
  1. **Register**: block signal, add to signalfd, install handler.
  2. **Unregister**: unblock signal, remove from signalfd, restore SIG_DFL.
  A callback that's unreachable due to a blocked signal is worse than no callback — the user thinks they have signal handling when they don't.

**Lesson 55 — Always Check `get_value_ptr` Returns — Don't `.?` Force-Unwrap**
In `signal_handler`, `callbacks.get_value_ptr(sig, null).?` would panic if the callback for that signal was removed between signal delivery and io_uring read completion.
- **Fix:** Replaced `.?` with explicit `orelse` that re-queues the signalfd read and returns gracefully.
- **Lesson:** Zig's `.?` operator (unwrap-else-panic) is **almost never what you want** in event-loop / signal-handler / hot-path code. It is appropriate for truly impossible states but for concurrent state lookups, it's a crash waiting to happen. **Any time you write `.?` on a `?T` returned by a lookup function (BTree, HashMap, container), ask: "can this lookup fail at runtime?"** If yes, use `orelse` to handle the failure.
