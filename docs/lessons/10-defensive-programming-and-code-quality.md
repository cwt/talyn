[⬅️ Back to Lessons Index](../lessons-learned.md)

# Defensive Programming & Code Quality

Lessons about error visibility, configuration discipline, API contracts, numeric correctness, and general code quality patterns.

---

### Error Handling Discipline

**Lesson 57 — Silent Failure is the Worst Kind of Failure**
*(Cross-reference: also in [Event Loop Lifecycle](03-event-loop-lifecycle.md))* An out-of-sync write state was silently returned, dropping bytes and spinning the upper layer in a tight loop.
- **Lesson:** For invariant violations: detect it, surface it loudly, make the failure recoverable. If you find `if (something_that_should_be_impossible) { return; }` — you're hiding a bug. Prove it's impossible (`unreachable`/`assert`) or handle it as a real error path.

**Lesson 97 — Never Silently Swallow Exceptions**
*(Cross-reference: also in [Python C API Correctness](05-python-c-api-correctness.md))* `except Exception: pass` drops exceptions with no record.
- **Lesson:** Always log before swallowing: `except Exception: logger.exception(...)`.

**Lesson 85 — Make `else` Branches Visible**
*(Cross-reference: also in [Event Loop Lifecycle](03-event-loop-lifecycle.md))* Bare `else => {}` silently dropped unhandled operation variants.
- **Lesson:** Make default branches **loud**: log the dropped case. This applies everywhere — switch statements, protocol handlers, syscall return codes.

**Lesson 86 — Distinguish Expected From Unexpected Outcomes**
Even fire-and-forget operations should distinguish expected results (SUCCESS, NOENT) from unexpected ones (EINVAL, EBADF).
- **Lesson:** Log unexpected outcomes even for fire-and-forget operations. "I don't know what result codes this can produce" is the sign you should add logging.

---

### Configuration & API Contracts

**Lesson 101 — Use Configuration Fields, Don't Hardcode**
`WriteTransport.writev` had `.zero_copy = false` hardcoded, ignoring the `zero_copying: bool` field that callers could set.
- **Lesson:** If you add a configuration field, it should be read somewhere. A field that's defined but never read is dead code or a bug waiting to happen when someone tries to use it.

**Lesson 96 — Make Every Timeout Configurable**
*(Cross-reference: also in [Security & Input Validation](09-security-and-input-validation.md))* Hardcoded 60s SSL handshake timeout.
- **Lesson:** For any timeout in async code, make it a parameter with a sensible default.

**Lesson 31 — SSL `create_connection` Silently Drops All Kwargs**
*(Cross-reference: also in [Network Protocols & I/O](06-network-protocols-and-io.md))* Internal wrapping calls discarded user-provided kwargs.
- **Lesson:** When wrapping an internal call that mirrors the public API, always forward all parameters explicitly.

---

### Numeric Correctness

**Lesson 75 — File Descriptors Can Be 0**
An fd validation check used `if (fd <= 0)`, rejecting fd 0 (stdin) as invalid. The correct check is `if (fd < 0)` — fd 0 is a perfectly valid file descriptor.
- **Lesson:** File descriptors start at 0. The standard fd table: `0=stdin, 1=stdout, 2=stderr, 3+=user`. Any check like `fd <= 0` or `fd == 0` will incorrectly reject valid fds. The correct validity check is `fd < 0`. Same principle: Unix PIDs (pid 0 is the idle process, not invalid), UIDs/GIDs (uid 0 is root, not invalid), array indices (0 is valid; check `i < len`).

**Lesson 76 — Float Approximate Equality Needs Symmetric Comparison**
A sentinel check for `-1.0` used `if ((delay + 1.0) < eps)` — asymmetric, catching values slightly less than -1.0 but not slightly greater.
- **Fix:** Use `@abs(delay + 1.0) < eps` for symmetric comparison.
- **Lesson:** When checking approximate equality, use `abs(a - b) < eps` — not `a - b < eps`. The latter is asymmetric. This applies to all float comparisons with tolerance, float sentinel detection, range checks, and cyclic comparisons.

**Lesson 94 — Indexes Go Forward, Not Backward**
*(Cross-reference: also in [Data Structures & Algorithms](07-data-structures-and-algorithms.md))* A backward-running counter was used for forward iteration.
- **Lesson:** For any "give me the next item" operation, the next item is at `index+1`, not at `count-1`.

---

### Code Quality & Maintenance

**Lesson 93 — Never Hardcode Numeric Constants**
An errno value `99` was hardcoded instead of using `@intFromEnum(std.os.linux.E.ADDRNOTAVAIL)`. Platform-specific constants are numbered differently on BSD/macOS/Windows.
- **Lesson:** For any numeric constant with a symbolic name, use the symbolic name. This applies to errno values (`EAGAIN`, `EINTR`), signal numbers (`SIGINT`), fd table conventions (`STDIN_FILENO`), and syscall numbers.

**Lesson 98 — Remove Unreachable Code**
A duplicate null check after an if/else that already handled the null case was unreachable and confusing.
- **Lesson:** Dead code is a maintenance burden — it confuses readers, gets modified alongside live code, and hides bugs (the live code might be wrong but the dead code "looks right"). Remove unreachable code or use `unreachable` to make the invariant explicit.

**Lesson 82 — Never Leave Debug Prints in Hot Paths**
*(Cross-reference: also in [Event Loop Lifecycle](03-event-loop-lifecycle.md))* Four `std.debug.print` calls in the main blocking wait path.
- **Lesson:** Any code running in a loop on a hot path should be O(1) and side-effect-free. "Temporary" debug prints inevitably end up in production.

**Lesson 89 — Don't Reinvent the Wheel — Use the Standard Library**
*(Cross-reference: also in [Memory & Reference Counting](01-memory-and-reference-counting.md))* A custom heuristic for skipping refcount on "singletons" was based on incorrect address assumptions.
- **Lesson:** Before writing a custom version of a standard library function, ask: "do I really know better?" The standard library has been tested by millions of users.

---

### Resource Lifecycle Patterns

**Lesson 77 — `errdefer` After Every Resource Acquisition**
*(Cross-reference: also in [Zig-Specific Patterns](08-zig-specific-patterns.md))*
- **Lesson:** For every "acquire" operation, the very next line should be the matching "cleanup on error" defer.

**Lesson 79 — Best-Effort Thread Join on Timeout**
`shutdown_default_executor` joined the executor thread only on success, not on timeout. The thread was left running and potentially accessing resources about to be freed.
- **Fix:** In the `except asyncio.TimeoutError` branch, call `thread.join(timeout)` as a best-effort join.
- **Lesson:** Always attempt to join a spawned thread, even on timeout:
  1. Spawn the thread.
  2. Wait for work to complete (with timeout if applicable).
  3. Always join — either in the success path or the timeout path.
  The "join only on success" anti-pattern leaks threads. Applies to subprocesses, async tasks with background threads, resource pool executors, and timer threads.

**Lesson 90 — Handle Multiple Whitespace Variants in Parsers**
`parse_resolv_configuration` used `tokenizeScalar(u8, line, ' ')` — only spaces as delimiters. Tabs in resolv.conf files (`nameserver\t8.8.8.8`) were silently skipped.
- **Fix:** Changed to `tokenizeAny(u8, line, " \t")`.
- **Lesson:** Handle all whitespace variants in parsers — space, tab (`\t`), carriage return (`\r`), form feed (`\f`). The "space is the only whitespace" anti-pattern is a common parser bug in config files, CSV, URLs, and shell commands.
