# Developer Agent Instructions

This repository uses the Open Knowledge Format (OKF v0.2) to document development rules, architectural mandates, and lessons learned.

## OKF Bundle Root
- **Master Documentation Bundle**: Located at [docs/](docs/)
  - **Master Root Index File**: [docs/index.md](docs/index.md) (contains master priorities, knowledge base, benchmarks, and history)
- **Development Documentation Bundle**: Located at [docs/development/](docs/development/)
  - **Development Index File**: [docs/development/index.md](docs/development/index.md) (contains priorities, bugs, and development history)
  - **Lessons Learned Index**: [docs/development/lessons/index.md](docs/development/lessons/index.md) (nested topic bundle index)

## Rules for Agents
Before implementing any changes, refactoring, or writing new code:
1. **Load and read** the root index [docs/index.md](docs/index.md).
2. **Review and adhere** to the [docs/development/architectural-mandates.md](docs/development/architectural-mandates.md) (e.g. panic prevention rules, event loop shutdown guard rules, thread safety requirements).
3. **Inspect** the specific lesson categories under [docs/development/lessons/](docs/development/lessons/) relevant to your active task to ensure past bugs are not reintroduced.
4. **Adhere to Dual-Toolchain Compatibility**: Talyn builds on both **Zig 0.16.0 and Zig 0.17.0** from a single source tree.

## Dual-Toolchain Compatibility (Zig 0.16.0 & 0.17.0)

1. **Prefer APIs present in both releases**: Do not introduce 0.17-only APIs that break 0.16.0, nor 0.16-only patterns that fail under 0.17.0.
2. **Confine version branches**: Keep compiler version branching strictly confined to `build.zig` (e.g. `@hasField(OptimizeMode, "debug")`) and AST parsing utilities in `tools/linter/`. Never scatter version checks through core domain logic.
3. **Python C API Headers**: Zig 0.17 removed `@cImport`. All C header imports must be processed via `b.addTranslateC` in `build.zig` through `src/c_python.h` and imported via `pub const _c = @import("c_python");`.
4. **Portable Spellings**:
   - `std.fmt.bufPrintZ(...)` → `std.fmt.bufPrintSentinel(..., 0)`
   - `std.meta.fields(T)[i].name` → `std.meta.fieldNames(T)[i]`
   - `.{v} ** N` array repetition → `@splat(v)` or `std.mem.zeroes`
   - `std.meta.Int` → `@Int` builtin
   - Non-packed struct `@bitCast` → explicit field initialization
5. **Verification**: Always verify changes against **both** compilers:
   - Zig 0.16.0: `zig build test`
   - Zig 0.17.0: `PATH=/opt/zig/0.17.0:$PATH zig build test`

