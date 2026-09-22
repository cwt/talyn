"""Regression test for BUG-332: cancelling a getnameinfo future must not
abort the process at loop close.

During teardown `dns.deinit()` released the query's ControlData while its
io_uring ops were still in flight; the cancel completions dispatched during
`io.deinit()` then ran on freed memory, re-entered `ControlData.release()`
and re-dispatched the already-consumed user callback - a second invocation
of ``getnameinfo_callback`` dereferenced the freed ``GetNameInfoData`` and
panicked (SIGABRT, core dumped).

The scenario runs in a subprocess so a regression aborts the child instead
of taking down the whole pytest run.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _run_repro_in_subprocess(script: str) -> subprocess.CompletedProcess[str]:
    """Write ``script`` to a temp file and run it under the current interpreter."""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script)
        script_path = f.name
    try:
        env = dict(os.environ)
        existing = env.get("PYTHONPATH", "")
        env["PYTHONPATH"] = (
            f"{REPO_ROOT}{os.pathsep}{existing}" if existing else str(REPO_ROOT)
        )
        return subprocess.run(
            [sys.executable, script_path],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
    finally:
        os.unlink(script_path)


_REPRO = textwrap.dedent(
    """\
    import asyncio

    import talyn


    async def main() -> None:
        loop = asyncio.get_running_loop()
        fut = loop.getnameinfo(("127.0.0.1", 443), 0)
        fut.cancel()
        try:
            await fut
        except asyncio.CancelledError:
            pass

        # The loop must remain usable after the cancellation.
        info = await loop.getaddrinfo("127.0.0.1", 80)
        assert info

        print("DONE")


    talyn.run(main())
    """
)


def test_cancelled_getnameinfo_does_not_abort_at_loop_close() -> None:
    result = _run_repro_in_subprocess(_REPRO)
    if result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-25:])
        pytest.fail(f"repro crashed (returncode={result.returncode}).\n{tail}")
    assert "DONE" in result.stdout
    assert "queue cancel failed" not in result.stderr
