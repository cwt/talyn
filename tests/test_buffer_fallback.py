"""End-to-end test for BUG-117: the registered(fixed)-buffer fallback.

When io_uring buffer registration fails (e.g. RLIMIT_MEMLOCK exhaustion),
talyn must transparently fall back to heap buffers and keep serving I/O
correctly. This test forces that fallback and then actually *runs the event
loop* to perform a real read through the ReadTransport -> lease_buffer() ->
heap-buffer (ring.read) path, proving the fallback is functionally correct
and not just a non-crashing no-op.

Why this runs in a subprocess
------------------------------
io_uring accounts the memory it pins (the SQ/CQ rings *and* any registered
buffers) against the per-process RLIMIT_MEMLOCK budget. When the full pytest
suite runs, many prior tests create and tear down io_uring loops; the kernel
releases the registered-buffer pins *asynchronously*, so by the time this test
executes the parent process's pinned-memory budget is still elevated (in
practice ~1-2 MiB). Clamping RLIMIT_MEMLOCK in that shared process therefore
breaks io_uring *ring setup* itself -- not just buffer registration. Ring
setup failure is an *unguarded* error path (only register_buffers is caught by
the BUG-117 fix) that surfaces as ``OSError: SystemResources`` from
``Loop.__init__``, which prevents us from ever exercising the fallback we want
to test. In a fresh process the same clamp only affects buffer registration,
which is the intended path. Running the scenario in a child process gives us a
clean pinned-memory budget, so the test is deterministic regardless of test
order.
"""

import asyncio
import resource
import subprocess
import sys

import pytest

from talyn import Loop

# io_uring registered buffers need ~1 MiB of locked (pinned) memory per loop.
# This is deliberately below that need but comfortably above the ~100 KiB the
# ring itself pins, so register_buffers fails (engaging the BUG-117 fallback)
# while ring setup still succeeds -- *provided the per-process MEMLOCK budget
# is clean* (hence the subprocess, see module docstring).
_FORCE_MEMLOCK = 1024 * 1024 - 65536


def _exercise_fallback() -> None:
    """Run the buffer-registration fallback scenario in the current process.

    Must be invoked from a *fresh* process (see the test below) so the
    per-process RLIMIT_MEMLOCK budget is clean.
    """
    soft, hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    if hard < _FORCE_MEMLOCK:
        # Cannot safely force the fallback; it is already the default path in
        # such environments (and is exercised by other tests).
        print("SKIP: RLIMIT_MEMLOCK too low to force the fallback")
        return
    # Keep `max` untouched so we can restore the limit afterwards.
    resource.setrlimit(resource.RLIMIT_MEMLOCK, (_FORCE_MEMLOCK, hard))
    try:
        loop = Loop()
        try:

            async def main() -> bytes:
                # Echo server: both ends use a ReadTransport, so both engage
                # lease_buffer() (and thus the fallback) on this constrained loop.
                async def echo(
                    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
                ) -> None:
                    data = await reader.read(1024)
                    writer.write(data)
                    await writer.drain()

                server = await asyncio.start_server(echo, "127.0.0.1", 0)
                try:
                    port = server.sockets[0].getsockname()[1]
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    try:
                        payload = b"hello talyn fallback path"
                        writer.write(payload)
                        await writer.drain()
                        return await reader.read(64)
                    finally:
                        writer.close()
                        await writer.wait_closed()
                finally:
                    server.close()
                    await server.wait_closed()

            got = loop.run_until_complete(main())
            assert got == b"hello talyn fallback path"
        finally:
            loop.close()
    finally:
        resource.setrlimit(resource.RLIMIT_MEMLOCK, (soft, hard))


def test_registered_buffer_fallback_allows_io() -> None:
    # Run the scenario in an isolated subprocess so the per-process
    # RLIMIT_MEMLOCK budget is clean (see module docstring). cwd/PYTHONPATH are
    # inherited, so `import talyn` and the repo root resolve correctly. The
    # child loads this module by file path (tests/ is not a package) and calls
    # _exercise_fallback().
    bootstrap = (
        "import importlib.util, sys; "
        "spec = importlib.util.spec_from_file_location('bf', sys.argv[1]); "
        "mod = importlib.util.module_from_spec(spec); "
        "spec.loader.exec_module(mod); "
        "mod._exercise_fallback()"
    )
    proc = subprocess.run(
        [sys.executable, "-c", bootstrap, __file__],
        capture_output=True,
        text=True,
    )
    if "SKIP" in proc.stdout:
        pytest.skip(
            "RLIMIT_MEMLOCK too low to safely force the fallback; "
            "the fallback is already the default path in this environment."
        )
    assert proc.returncode == 0, (
        f"fallback subprocess failed (rc={proc.returncode}):\n{proc.stderr}"
    )
