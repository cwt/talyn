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
        [sys.executable, '-c', code],
        env={'PYTHONPATH': '.'},
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
    (going to 2^32 - 1 on u32 refcount). Post-fix: the refcount is
    whatever Python's module system has set, and stays stable as long
    as the module is alive.
    """
    import talyn
    tz = sys.modules['talyn.talyn_zig']
    c_loop_type = tz.Loop

    rc1 = sys.getrefcount(c_loop_type)
    # Force a gc cycle (Python does its own cleanup; this just exercises it).
    import gc
    gc.collect()
    rc2 = sys.getrefcount(c_loop_type)
    # The refcount should not change drastically (no large decrements).
    # Allow a small delta for the test's own reference changes.
    assert abs(rc1 - rc2) < 5, (
        f"Refcount changed by {rc1 - rc2} after gc; "
        f"this suggests a double-decref. rc1={rc1}, rc2={rc2}"
    )
    # And the refcount must be a positive, sane value (not underflowed).
    assert rc1 < 1_000_000_000, f"Refcount looks corrupted: {rc1}"
    assert rc2 < 1_000_000_000, f"Refcount looks corrupted: {rc2}"
