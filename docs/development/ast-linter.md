---
type: reference
title: Offline AST Linter & Bug Hunter
description: Architecture, rule catalog, and usage instructions for the native offline Zig/Python AST static analyzer.
status: stable
sources:
  - build.zig
verified: machine-confirmed
tags: [static-analysis, ast, linter, bug-prevention, zig-ast]
timestamp: "2026-08-16T14:10:00Z"
---

[⬅️ Back to Development Index](index.md)

# 🛡️ Talyn Offline Bug Hunter & AST Linter

The **Talyn AST Linter** (`zig build lint`) is a native, offline static analysis tool designed to proactively detect anti-patterns, architectural mandate violations, and regression risks across all Zig and Python source files before compilation or commit.

Because domain-specific bugs (such as unhandled completion operations, panics in the IO loop, unchecked syscall return values, and unmanaged container regressions) are 100% syntactically valid to standard compilers, this tool hooks directly into **`std.zig.Ast`** and Python's standard **`ast`** module to enforce project invariants in **under 100ms** without any external dependencies or AI/LLMs.

---

## 🚀 Running the Linter

Run the full linter across the entire codebase via the Zig build system:

```bash
zig build lint
```

Or run the linter directly:

```bash
zig run tools/linter/main.zig
```

To run only the Python AST rules:

```bash
python3 tools/linter/rules/python_rules.py
```

---

## 📋 Rule Catalog

### Zig AST Rules

| Rule ID | Name | Bug Reference | Mandate / Risk |
|---|---|---|---|
| `TALYN-001` | `NO_CIMPORT` | [BUG-123](bugs/123.md) | `@cImport` is prohibited in source modules (must use `addTranslateC` or pure externs). |
| `TALYN-002` | `NO_PANIC_IN_IO` | [Mandate 1](architectural-mandates.md), [BUG-105](bugs/105.md), [BUG-188](bugs/188.md) | `@panic` or `panic()` calls inside IO and loop paths unconditionally crash the host Python process instead of propagating Python exceptions. |
| `TALYN-003` | `NO_EMPTY_CATCH` | [BUG-122](bugs/122.md), Zig 0.16 Rule 6 | Empty `catch {}` blocks silently suppress errors without logging or resource cleanup. |
| `TALYN-004` | `UNMANAGED_CONTAINERS` | [BUG-126](bugs/126.md), Zig 0.16 Rule 4 | Prohibits managed `std.AutoHashMap` / `std.StringHashMap`, enforcing unmanaged containers with explicit allocator passing. |
| `TALYN-005` | `NO_BARE_SWITCH_ELSE` | [BUG-096](bugs/096.md) | Bare `else => {}` in switch statements silently drops unhandled enum or completion variants. |
| `TALYN-006` | `DISCARDED_SYSCALL_RETURN` | [BUG-190](bugs/190.md), [BUG-199](bugs/199.md) | Discarding syscall returns (e.g. `_ = getsockname(...)`) leads to reading uninitialized stack memory on failure. |
| `TALYN-007` | `NO_SPINLOCK_YIELD` | [BUG-125](bugs/125.md) | `std.Thread.yield()` in spinlocks can fail or perform inefficiently in high-contention paths. |
| `TALYN-008` | `GC_TYPE_REQUIRES_TP_CLEAR` | [BUG-155](bugs/155.md), [BUG-193](bugs/193.md) | Types declaring `Py_TPFLAGS_HAVE_GC` must implement `.tp_clear` to prevent permanent cyclic garbage leaks. |
| `TALYN-009` | `MISSING_ERRDEFER_AFTER_FAST_NEW_FUTURE` | [BUG-187](bugs/187.md), [BUG-203](bugs/203.md) | `fast_new_future` returns a new Python reference that must have an `errdefer py_decref` to prevent leaks on error paths. |
| `TALYN-010` | `UNINITIALIZED_PYOBJECT_FIELD_AFTER_TP_ALLOC` | [BUG-204](bugs/204.md), [BUG-087](bugs/087.md) | Optional `?PyObject` struct fields must be explicitly set to `null` after `tp_alloc` to prevent GC traversal of garbage pointers. |
| `TALYN-011` | `UNPARSED_PYOBJECT_KWARG` | [BUG-189](bugs/189.md), [BUG-205](bugs/205.md) | Struct fields of type `?PyObject` must be covered by a `parse_vector_call_kwargs` call, or the corresponding Python keyword argument is silently ignored. |

### Python AST Rules

| Rule ID | Name | Bug Reference | Mandate / Risk |
|---|---|---|---|
| `TALYN-PY01` | `NO_LAMBDA` | [BUG-161](bugs/161.md), Project Style | `lambda` expressions are strictly prohibited; explicit named `def` functions must be used for inspectable stack traces. |
| `TALYN-PY02` | `NO_SILENT_EXCEPT` | [BUG-099](bugs/099.md), [BUG-102](bugs/102.md) | Broad `except:` or `except Exception: pass` without logging or re-raising hides critical errors. |

---

## 📁 Architecture & File Layout

```
tools/linter/
├── main.zig                  # CLI entrypoint: AST parsing, timing, and multi-language orchestration
├── diagnostic.zig            # Rich ANSI diagnostic reporting with file:line, risk, and remediation
└── rules/
    ├── no_cimport.zig        # Rule TALYN-001
    ├── no_panic_in_io.zig    # Rule TALYN-002
    ├── no_empty_catch.zig    # Rule TALYN-003
    ├── unmanaged_containers.zig # Rule TALYN-004
    ├── no_bare_switch_else.zig  # Rule TALYN-005
    ├── syscall_safety.zig    # Rule TALYN-006
    ├── no_spinlock_yield.zig # Rule TALYN-007
    ├── gc_type_clear.zig              # Rule TALYN-008
    ├── missing_errdefer_after_future.zig  # Rule TALYN-009
    ├── missing_tp_alloc_pyobject_init.zig # Rule TALYN-010
    └── unparsed_pyobject_kwarg.zig    # Rule TALYN-011
    └── python_rules.py       # Python AST rules (TALYN-PY01, TALYN-PY02)
```

---

## ➕ Adding a New AST Rule

To add a new check for a newly discovered bug pattern:

1. Create `tools/linter/rules/your_rule.zig` exposing `pub fn check(ast: *const std.zig.Ast, file_path: []const u8, gpa: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) !void`.
2. Inspect AST node tags (`.builtin_call`, `.call`, `.switch_stmt`, `.@"catch"`, etc.) or token streams.
3. Register the rule in `tools/linter/main.zig`.
4. Run `zig build lint` to verify.
