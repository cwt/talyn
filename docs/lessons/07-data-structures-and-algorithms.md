[⬅️ Back to Lessons Index](../lessons-learned.md)

# Data Structures & Algorithms

Lessons about BTree correctness, LRU cache semantics, recursion depth, and robust data structure operations.

---

### Correctness Bugs

**Lesson 23 — BTree Split Key Count During Non-Root Splits**
The BTree implementation used hardcoded `current_node.nkeys = 1` unconditionally inside `split_nodes`. This is correct for a root-node split but completely wrong for a non-root split (which leaves `middle_index` keys in `current_node`). For `Degree = 3`, `middle_index = 1` — the bug was hidden. For `Degree = 11` (used by `WatchersBTree`), it discarded 4 keys, silently corrupting the tree under heavy fd watcher load.
- **Fix:** Set `current_node.nkeys = (Degree - 1) / 2` when the split node has a parent; only `1` on root split.
- **Lesson:** Never use hardcoded constants for data structure counts that depend on parameter/degree configurations. Always write unit tests with diverse parameters (e.g., larger degrees) to ensure algorithms scale correctly.

**Lesson 72 — Replace Operations Must Fire Eviction Callbacks**
`LRUCache.put()` overwrote existing values with `node.value = value` directly. The `evict_callback` was only called on capacity-overflow eviction or explicit removal — never on a value replacement. Resources tied to overwritten values (buffers, refcounts) leaked on every `put()` that overwrote an existing entry.
- **Fix:** Before overwriting, call the `evict_callback` with the OLD value.
- **Lesson:** A "replace" operation is a "remove + insert" in disguise — both must fire eviction callbacks. The old value is just as gone as if it had been evicted. The same applies to HashMap/TreeMap update, ArrayList index assignment, database UPDATE with foreign keys, and reference-counted smart pointer assignment.

**Lesson 100 — Off-By-One Edge Cases at Capacity Boundaries**
`LRUCache.put` with `capacity=0` evaluated `0 >= 0 = true` for the eviction check but then added the entry — a "capacity 0" cache could hold 1 entry.
- **Fix:** Added early return: `if (self.capacity == 0) return;`.
- **Lesson:** Edge cases at capacity boundaries are a common source of off-by-one bugs. Always test the degenerate case (`capacity=0`). For any "capacity" or "limit" parameter, add an explicit boundary check. A 1-line boundary check is worth more than 1000 lines of test coverage.

**Lesson 94 — Indexes Go Forward, Not Backward**
`interleave_address_list` used `ipv4_addresses -= 1` to pick the next IPv4 address. Since `ipv4_addresses` started at the count and decremented, the *first* address picked was the *last* one — addresses were tried in reverse order within each family.
- **Fix:** Replaced backward-running counter with a forward-running index (`ipv4_index += 1`).
- **Lesson:** The "backward-running counter for forward iteration" anti-pattern is surprisingly common. **For any "give me the next item" operation, the next item is at `index+1`, not at `count-1`.** When you find yourself decrementing a counter to "advance", stop and think.

---

### Stack Overflow & Recursion

**Lesson 53 — Replace Recursion With a Loop to Avoid Stack Overflow**
In `submit_next_chunk`, when a queued `iovec` had `len == 0`, the function called `return self.submit_next_chunk();` — a textbook tail call. But Zig does NOT perform tail-call optimization in Debug or ReleaseSafe. Enqueueing many zero-length `iovec` entries (e.g., `writelines([b"", b"", ...])`) would overflow the 8 MB stack.
- **Fix:** Replaced the recursion with a `while (true)` loop. O(N) time, O(1) stack depth.
- **Lesson:** **Tail calls are not tail calls in Zig.** `return self.foo()` is just a regular call — no TCO. The rule: **any time you write `return self.recursive_helper(...)`, ask "can this recurse more than ~1000 times?"** If yes, convert to a loop. Same warning for Rust, C, C++. Also watch for: error-propagation chains, state-machine transitions as mutual recursion, and parsers that recurse on nested structures.

---

### Defensive Data Structure Operations

**Lesson 83 — Make Data-Structure Operations Robust to Assumed Invariants**
`BlockingTasksSet.pop()` decremented counters without clearing the slot being "released". Fine as long as `pop()` is only called on the most recently pushed task (LIFO assumption), but any future code path calling it on a non-last task would read stale data.
- **Fix:** Clear the slot's fields before decrementing. `pop()` is now safe regardless of which task it pops.
- **Lesson:** Don't rely on assumed invariants that the function's signature doesn't enforce. Make the function safe even when the invariant is broken. Ask: "what state am I leaving behind? Is that state safe to read?" If the answer is "it depends on caller behavior", make the function self-sufficient.
