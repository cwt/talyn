"""Regression tests for BUG-266: empty DNS hostnames_array OOB crash.

An over-long hostname (hostname + search-suffix + '.' > 255 bytes, or a
255-char FQDN) makes ``get_hostname_array()`` yield zero candidates;
``prepare_data()`` then built an empty ``queries`` slice and ``queue()``
indexed ``server_data.queries[0]`` on it — an out-of-bounds read that
panics (aborts the process) in Debug/ReleaseSafe.

The fix rejects the lookup with ``error.InvalidHostname`` (surfaced as
``RuntimeError``, consistent with the pre-existing ``>255`` check in
``DNS.lookup``). Tests run in a subprocess so a regression would abort
the child instead of taking down the whole pytest run.
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


    class Proto(asyncio.Protocol):
        pass


    async def main() -> None:
        loop = asyncio.get_running_loop()

        # Boundary hostnames where get_hostname_array() yields zero
        # candidates (hostname + search-suffix + '.' > 255 bytes).
        host_254_no_dot = "a" * 254
        host_255_no_dot = "a" * 255
        host_255_fqdn = "a" * 254 + "."

        for name in (host_254_no_dot, host_255_no_dot, host_255_fqdn):
            try:
                await loop.getaddrinfo(name, 80)
            except RuntimeError:
                pass
            else:
                raise AssertionError(
                    f"getaddrinfo({len(name)}-char hostname) did not raise"
                )

        try:
            await loop.create_connection(Proto, host_255_fqdn, 80)
        except RuntimeError:
            pass
        else:
            raise AssertionError("create_connection did not raise")

        try:
            await loop.create_server(Proto, host_255_fqdn, 0)
        except RuntimeError:
            pass
        else:
            raise AssertionError("create_server did not raise")

        # The loop must remain fully usable after the rejections.
        info = await loop.getaddrinfo("127.0.0.1", 80)
        assert info

        print("DONE")


    talyn.run(main())
    """
)


def test_overlong_hostname_rejected_without_crash() -> None:
    result = _run_repro_in_subprocess(_REPRO)
    if result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-25:])
        pytest.fail(f"repro crashed (returncode={result.returncode}).\n{tail}")
    assert "DONE" in result.stdout
