# Talyn Migration Plan

This document outlines the strategic migration, refactoring, and modernization plan to spin off the **Leviathan** event loop into a distinct, production-hardened project named **Talyn**. 

---

## 1. Vision & Identity

* **Name**: **Talyn** (derived from the biomechanical starship in sci-fi lore, representing speed, adaptive systems, and low-level control).
* **Positioning**: A robust, exceptionally stable, and realistically fast `asyncio` event loop drop-in replacement powered by **Zig** and **io_uring**. Talyn prioritizes correctness, system resilience, and high usability over artificial micro-benchmark superiority.
* **Ethical Open Source Stewardship**:
  * The original project owner (**Enrique Mora**) is fully credited for the original vision, architecture, and pioneering concepts.
  * The original `README.md` and `BENCHMARK.md` will be preserved as historical artifacts to honor the origin and early aspirations of the project.

---

## 2. Refactoring Phase: Renaming References

We will perform a complete codebase search-and-replace to migrate all occurrences of the brand from `leviathan` to `talyn`:

### A. Python Package Renaming
* Rename the directory `leviathan` ➔ `talyn`.
* Update all Python module imports (e.g., `import leviathan` ➔ `import talyn`).
* Rename loop registration and setup calls inside source modules.

### B. Zig Module & Native API Renaming
* Update Zig `@import` statements and module declarations.
* Rename native C/Zig functions, symbols, and type definitions (e.g., `libleviathan` ➔ `libtalyn`, `leviathan_task_step_trampoline` ➔ `talyn_task_step_trampoline`).
* Update Python C-extension initialization functions (e.g., `PyInit_leviathan` ➔ `PyInit_talyn`).

### C. Build Configuration Renaming
* Modify `build.zig` and `build.zig.zon` to output `libtalyn` instead of `libleviathan`.

---

## 3. Packaging Modernization: `pyproject.toml`

We will retire the legacy, deprecated `setup.py` build configuration and replace it with a modern, standard-compliant `pyproject.toml` build system (PEP 517/518):

* **Build Backend**: Use `setuptools.build_meta` paired with custom native extension compilation hooks (calling Zig under the hood to build native assets).
* **Metadata**: Declaratively specify project metadata, Python requirements (>=3.13), dependencies, and event loop policies.

---

## 4. Documentation Strategy

* **New `README.md`**:
  * Written to showcase the hardened, production-grade state of **Talyn**.
  * Fully credit the original developer, **Enrique Mora**, for starting the project and laying the foundations.
  * Links to historical files for context.
* **Historical Preservation**:
  * Rename the current `README.md` to `docs/historical/leviathan-readme.md`.
  * Rename `BENCHMARK.md` to `docs/historical/leviathan-benchmark.md`.

---

## 5. Verification & Testing

To ensure the migration introduces zero functional regressions, we will perform the following validation steps:
1. **Compilation Check**: Run `zig build` to verify the native library builds successfully as `libtalyn`.
2. **Local Package Build**: Execute `pip install -e .` (or equivalent modern pip invocation) to verify standard wheels and source distributions compile properly using the new `pyproject.toml` backend.
3. **Comprehensive Test Suite**: Execute `./scripts/test_all.sh` to guarantee that all 270 standard asyncio, subprocess, child, and transport tests pass flawlessly on all 4 target Python interpreters.
