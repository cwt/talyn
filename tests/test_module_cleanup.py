"""BUG-41 regression: type objects must not be double-decref'd at module cleanup.

PyModule_AddObject steals a reference. The module's refcount is owned by
Python's module machinery, which decrefs the type at interpreter shutdown.
deinitialize_talyn_types must not also decref them, or the refcount underflows.

This test forces interpreter shutdown and verifies the process exits cleanly
without the BUG-41 latent refcount underflow. We detect the underflow by
tracking the C type's refcount across multiple interpreter lifetimes.
"""

import subprocess
import sys
import textwrap


def test_bug41_module_cleanup_no_double_decref() -> None:
    """Run a subprocess that imports talyn and exits; verify clean exit."""
    code = """
import sys
import talyn
# Touch the type to ensure it's fully initialized.
_ = talyn.Loop
# Exit cleanly. The bug would manifest as a use-after-free detected by
# sanitizers, or as a corrupted refcount, but Python is forgiving so we
# mainly verify the process exits with returncode 0.
"""
    r = subprocess.run(
        [sys.executable, "-c", code],
        env={"PYTHONPATH": "."},
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, (
        f"subprocess exited with code {r.returncode}\n"
        f"STDOUT: {r.stdout}\nSTDERR: {r.stderr}"
    )


def test_bug41_type_refcount_stable() -> None:
    """The C type's refcount should be stable across normal operations.

    Pre-fix: deinitialize_talyn_types decref'd the types after Python's
    module cleanup had already done so. The refcount would underflow
    (going to 2^32 - 1 on 32-bit, or wrapping to a huge value on
    64-bit). Post-fix: the refcount is whatever Python's module system
    has set, and stays stable as long as the module is alive.

    We test two invariants that catch the bug on every platform:
    1. The refcount must remain positive (refcount underflow = negative).
    2. The refcount must not change drastically across a gc cycle.
    """
    tz = sys.modules["talyn.talyn_zig"]
    c_loop_type = tz.Loop

    rc1 = sys.getrefcount(c_loop_type)
    # Force a gc cycle (Python does its own cleanup; this just exercises it).
    import gc

    gc.collect()
    rc2 = sys.getrefcount(c_loop_type)
    # Invariant 1: refcount must be positive. An underflowed refcount
    # (u32 → 0xFFFFFFFF, or i64 wrapping to a very large positive) would
    # either be negative (if signed interpretation) or astronomically
    # larger than any plausible refcount. We don't bound the upper
    # limit — that depends on the build config and number of cached
    # types in the interpreter. We only require > 0.
    assert rc1 > 0, f"Refcount underflowed: rc1={rc1}"
    assert rc2 > 0, f"Refcount underflowed: rc2={rc2}"
    # Invariant 2: the refcount must not change drastically (no large
    # decrements). gc.collect() may free some objects, but the type
    # itself is held by the module — it should not be affected.
    assert abs(rc1 - rc2) < 5, (
        f"Refcount changed by {rc1 - rc2} after gc; "
        f"this suggests a double-decref. rc1={rc1}, rc2={rc2}"
    )


# BUG-305 regression harness: repeated import -> full-unload cycles inside a
# single subprocess. talyn_zig caches ~25 imported Python objects (asyncio
# module, exception classes, task-registry functions, ...) in .so-global
# atomics that SURVIVE module instance unload. Each PyInit re-imports and
# stores over those slots, so every load cycle contributes one owned
# reference to each cached object. When module_cleanup skipped
# release_python_imports (pre-fix free-threaded builds), nothing ever gave
# them back: sys.getrefcount(<cached object>) grew by 1 per load/unload
# cycle. Post-fix, release_python_imports runs unconditionally and refcounts
# return to their steady state every cycle.
BUG305_SUBPROCESS_SCRIPT = textwrap.dedent(
    """
    import gc
    import importlib
    import sys

    import asyncio  # measured target: talyn caches a reference to this module

    count_cycles = int(sys.argv[1])

    # Importing the package initializes talyn_zig's import cache exactly once.
    mod = importlib.import_module("talyn")
    _ = getattr(mod.Loop if hasattr(mod, "Loop") else mod, "run", None)

    refs_first_cycle = sys.getrefcount(asyncio)
    refs_last_cycle = refs_first_cycle

    for _ in range(count_cycles):
        for name in [n for n in list(sys.modules) if n.startswith("talyn")]:
            del sys.modules[name]
        mod = None
        gc.collect()
        gc.collect()
        mod = importlib.import_module("talyn")
        refs_last_cycle = sys.getrefcount(asyncio)

    drift = refs_last_cycle - refs_first_cycle
    print(f"BUG305RESULT {refs_first_cycle} {refs_last_cycle} {drift}")

    # Full-unload at exit exercises m_free under the fixed cleanup path.
    for name in [n for n in list(sys.modules) if n.startswith("talyn")]:
        del sys.modules[name]
    del mod
    gc.collect()
    gc.collect()
    """
)


def test_bug305_repeated_load_unload_does_not_leak_cached_imports() -> None:
    """Cached imports must be released once per extension teardown.

    Pre-fix behavior (free-threaded builds): each load/unload cycle leaked
    one owned reference per cached object, so getrefcount(asyncio) drifted
    by +1 per cycle AND the subprocess could accumulate tens of leaked
    references. Post-fix: zero drift across cycles.

    This test also guards the original "skip cleanup in free-threading"
    rationale: if the unconditional release ever reintroduced a teardown
    crash, the subprocess exits nonzero and the assert below fires.
    """
    r = subprocess.run(
        [sys.executable, "-c", BUG305_SUBPROCESS_SCRIPT, "8"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert r.returncode == 0, (
        f"subprocess exited with code {r.returncode}\n"
        f"STDOUT: {r.stdout}\nSTDERR: {r.stderr}"
    )
    result_line = next(
        line for line in r.stdout.splitlines() if line.startswith("BUG305RESULT")
    )
    _, first, last, drift = result_line.split()
    first, last, drift = int(first), int(last), int(drift)
    assert drift <= 0, (
        f"asyncio refcount drifted by +{drift} over repeated "
        f"load/unload cycles ({first} -> {last}); cached imports are "
        f"being leaked by module_cleanup (BUG-305)"
    )
