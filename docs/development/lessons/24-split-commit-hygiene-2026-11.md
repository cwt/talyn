---
type: lessons_learned
title: Split Commit Hygiene — Verified Refactoring (Lessons 114 & 115)
description: The 1205..1209 file-split refactoring series shipped a non-bisectable changeset and a broken default `zig build` (lib graph); what still passed, what failed, and the verification checklist that prevents both.
tags: [refactoring, split-commits, bisectability, zig-build, build-verification, hg-git, lessons-114, lessons-115]
timestamp: "2026-11-03T00:00:00Z"
---

[⬅️ Back to Lessons Index](./index.md)

# Split Commit Hygiene — Verified Refactoring (Lessons 114 & 115)

Lessons from commits **1205..1209** (2026-11-02) — the file-split refactoring of `resolv.zig`
(1499 lines), `ops.zig` (1207 lines), `create_connection.zig` (1299 lines), and
`scheduling/io/main.zig` (1058 lines) into directory submodules, plus the repair commit.
The moves themselves were **behavior-preserving** (verified by a declaration-level audit),
but two verification gaps shipped broken intermediate changesets.

---

### What the audit established (the refactoring was sound)

| Split | Decl-level audit (old → new set) | Result |
|-------|---------------------------------|--------|
| `dns/resolv.zig` → `resolv/{types,parse,response,queue}.zig` | 61/61 decls byte-identical | pure move; only import-path deltas |
| `io/socket/ops.zig` → `ops/*.zig` | 43/43 decls identical | pure move |
| `io/client/create_connection.zig` → `create_connection/*.zig` | 37/38 identical; 1 "dropped" = dead `set_future_exception` alias in `entry.zig` (never called) | pure move + legit prune |
| `scheduling/io/main.zig` → `io/types.zig` | 42/42 decls identical | pure move |

- No logic drift, no lost code, no duplicated struct fields; moved BUG-402/405/408/412 guard
  comments survived the moves intact.
- `zig build test` roster is **identical pre/post split** (82 tests, verified by building and
  running the pre-split 1204 binary and the tip binary on Zig 0.16.0 and 0.17.0).

---

### Lesson 114 — Split commits must be self-contained (bisectable)

**What happened.** Commit **1205** rewrote `resolv.zig` and `ops.zig` into aggregators that
`@import("resolv/types.zig")` etc., but the submodule files themselves were only added in the
next commit, **1206** (`chore: add split submodule files …`). A clean checkout of 1205 cannot
compile:

```text
$ hg clone -r 1205 talyn-clone && cd talyn-clone && zig build
src/loop/dns/resolv/parse.zig:1:1: error: unable to load 'parse.zig': FileNotFound
src/loop/dns/resolv.zig:2:27: note: file imported here
... (11 FileNotFound errors total; untracked files do not exist in the changeset)
```

**Why it matters.**

- `hg bisect` (and any per-commit CI) is broken for the whole range until 1206.
- The 1205 message describes **only** the resolv split, while the same commit also guts
  `ops.zig` (~1200 lines) — the changeset is under-described and cannot be trusted as-is.

**Rule.** A changeset is atomic iff `hg clone -r REV <clone> && <clone>: zig build` passes on
it. Move-style refactors must land the *file addition* (tracked submodule) and the *importer
rewrite* (aggregator) **in the same changeset**. If the commit message cannot be trusted to
describe the diff shape, the diff shape is too big for one message.

---

### Lesson 115 — `zig build test` + `zig build lint` do not compile the install (lib) graph

**What happened.** Commit **1207** defined the moved `interleave_address_list` without `pub`.
The default `zig build` target (`install` step → `src/lib.zig`) then fails — reproduced on a
clone of **1208**:

```text
src/loop/python/io/client/create_connection/connect.zig:26:47:
error: 'interleave_address_list' is not marked 'pub'
src/loop/python/io/client/create_connection/interleave.zig:21:1:
note: declared here  (fn interleave_address_list(...))
```

Both 1207 and 1208 shipped while claiming *"Verified: zig build test (82/82) + zig build lint"* —
which is true but **incomplete**: the test roots (`src/main.zig`, `utils`, `callback_manager`,
`python_c`, linter) never analyze the broken edge, because top-level
`const connect_mod = @import(...)` bindings are **lazily analyzed**; a file that no reachable
path semantically uses is simply not compiled, and its (already non-running) tests stay
invisible. The latent bug surfaced only when **1209** ran the default target.

**Rule.** For any change under `src/**`, the verification matrix is:

1. `zig fmt --check .`
2. `zig build` — the **default** target (compile `src/lib.zig`, not just test roots)
3. `zig build test`
4. `zig build lint`
5. Steps 2–4 on **both** toolchains (Zig 0.16.0 and 0.17.0), per the Dual-Toolchain
   Compatibility rule in `AGENTS.md`.

Do not summarize as "build passes" from test+lint alone; the lib graph is a distinct target.

---

### Invariants to preserve (checklist for future file splits)

1. **Same-changeset move:** tracked submodule files in the same commit as (or before) any
   importer that references them. Before finishing, run the bare-clone build of the new rev.
2. **Verbatim-move audit:** a pure refactor must show zero dropped declarations. The
   AST linter + a decl-level name/body diff (import-path deltas only) is the bar.
3. **Dead-import sweep before committing:** Zig silently permits unused **top-level** imports
   (they are not locals); introduced dead `const X = ...` aliases must be pruned in the split
   commit itself (1209 did it afterwards — acceptable, but the split should not create them).
4. **Aggregator shape:** thin re-exports only (`pub const X = mod.X;`), no logic, trailing
   newline, `zig fmt` clean; re-exports must re-create the pre-split public API exactly
   (`IO.Client.create_connection.loop_create_connection`, `Resolv.queue`, …).
5. **Test roster is unknown-but-fixed:** split files under split roots that no test root
   reaches transitively (e.g. `connect.zig`, `interleave.zig`) do **not** add their tests to
   `zig build test`; do not count on a split to widen or shift coverage. Compare rosters
   pre/post if coverage matters.
6. **Commit message scope:** one message per structural family; never fold an unmentioned
   second file-split into the same changeset (the 1205 trap).

---

### Cross-references

- Repair commit: **1209 — `fix: repair 1205..1208 split regressions — pub visibility, dedup, dead imports`**.
- Dual-Toolchain Compatibility rules: `AGENTS.md` (repository root).
- Zig-side patterns and linter: [_Offline AST Linter & Bug Hunter](../ast-linter.md).
- Related defect class (dead code from moves): [Defensive Programming §dead code](10-defensive-programming-and-code-quality.md).
- Related architectural rules: [Architectural Mandates](../architectural-mandates.md).
