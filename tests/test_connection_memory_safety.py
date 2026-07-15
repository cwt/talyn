"""Memory-safety regression tests for ``loop.create_connection``.

These cover the connection-creation heap-corruption regressions found while
debugging the ``wormhole`` proxy crash under load:

* BUG-118 / BUG-119 — double-free of ``socket_data`` / ``connection_data`` in
  ``submit_connect_for_address`` / ``create_socket_connection`` error path when
  a connect submit fails (fd / io_uring SQ-ring exhaustion).
* BUG-120 — use-after-free of ``MultiConnectState`` (``mcs``) in the happy
  eyebrows timer callback (``schedule_remaining_connects_callback``) when a
  connect wins before the happy-eyeballs timer fires and the success path
  frees ``mcs`` while the pending timer callback still references it.

Each test drives the failure mode in a *subprocess* and asserts a clean exit
(no SIGSEGV / SIGABRT). A crash would abort the subprocess (non-zero exit),
failing the test — this is the primary, build-agnostic regression guard.
For an even stronger guard, build talyn with ``-Ddebug-alloc`` (DebugAllocator,
catches double-free) or ``-Dasan`` (UBSan) and run ``scripts/memcheck.sh``.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _run_repro_in_subprocess(script: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    """Write ``script`` to a temp file and run it under the current interpreter.

    The subprocess inherits ``PYTHONPATH=.`` so the in-tree ``talyn`` package
    (and its freshly built extension) is importable. Returns the CompletedProcess.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script)
        script_path = f.name
    try:
        env = dict(os.environ)
        existing = env.get("PYTHONPATH", "")
        env["PYTHONPATH"] = f"{REPO_ROOT}{os.pathsep}{existing}" if existing else str(REPO_ROOT)
        return subprocess.run(
            [sys.executable, script_path],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    finally:
        os.unlink(script_path)


def _assert_clean(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        # A crash (SIGSEGV=139, SIGABRT=134) or any non-zero exit means the
        # regression is present. Surface the tail of the output for debugging.
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-25:])
        pytest.fail(
            f"{label} crashed (returncode={result.returncode}).\n{tail}"
        )
    assert "DONE" in result.stdout, f"{label}: repro did not complete cleanly"


_SUBMIT_FAILURE_SCRIPT = textwrap.dedent(
    """\
    import asyncio, resource, socket, threading, talyn

    # Force submit_connect_for_address failures (fd exhaustion) under load so the
    # BUG-118/119 double-free error path is exercised.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(256)
    port = srv.getsockname()[1]

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                break
            try:
                while True:
                    c.settimeout(0.2)
                    d = c.recv(1024)
                    if not d:
                        break
                    c.sendall(d)
            except Exception:
                pass
            finally:
                c.close()

    threading.Thread(target=serve, daemon=True).start()

    async def main():
        loop = asyncio.get_running_loop()
        tasks = [
            loop.create_connection(asyncio.Protocol, "127.0.0.1", port)
            for _ in range(2000)
        ]
        await asyncio.gather(*tasks, return_exceptions=True)

    talyn.run(main())
    print("DONE")
    """
)


def test_submit_failure_double_free_regression() -> None:
    """BUG-118/119: fd-exhaustion submit failures must not double-free.

    Lowers RLIMIT_NOFILE so many concurrent connects fail at submit time,
    driving ``submit_connect_for_address`` errors through the error path that
    used to free ``connection_data`` twice.
    """
    result = _run_repro_in_subprocess(_SUBMIT_FAILURE_SCRIPT)
    _assert_clean(result, "submit-failure double-free regression")


_HAPPY_EYEBALLS_SCRIPT = textwrap.dedent(
    """\
    import asyncio, socket, threading, talyn

    # Dual-stack server so "localhost" resolves to multiple addresses (::1 and
    # 127.0.0.1) and the happy-eyeballs timer is scheduled. The first connect
    # wins well before the 250ms timer fires; with the BUG-120 UAF, the success
    # path frees mcs while the pending timer callback still references it.
    try:
        srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        srv.bind(("::", 0))
        srv.listen(256)
    except OSError:
        # No IPv6 loopback available; fall back to an IPv4 server and connect
        # to "localhost" anyway (resolves to 127.0.0.1; timer may not fire, but
        # the cancellation path below still stresses the lifecycle).
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(256)
    port = srv.getsockname()[1]

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                break
            try:
                while True:
                    c.settimeout(0.2)
                    d = c.recv(1024)
                    if not d:
                        break
                    c.sendall(d)
            except Exception:
                pass
            finally:
                c.close()

    threading.Thread(target=serve, daemon=True).start()

    async def main():
        loop = asyncio.get_running_loop()
        for _ in range(60):
            tasks = []
            for i in range(80):
                # happy_eyeballs_delay schedules the timer; interleave reorders
                # so an address is attempted immediately. Wrap in a task so we
                # can cancel ~half right away to stress mid-flight cancellation
                # of in-flight connects.
                t = asyncio.ensure_future(
                    loop.create_connection(
                        asyncio.Protocol, "localhost", port,
                        happy_eyeballs_delay=0.25, interleave=1,
                    )
                )
                if i % 2 == 0:
                    loop.call_soon(t.cancel)
                tasks.append(t)
            await asyncio.gather(*tasks, return_exceptions=True)

    talyn.run(main())
    print("DONE")
    """
)


def test_midflight_cancel_happy_eyeballs_uaf_regression() -> None:
    """BUG-120: happy-eyeballs timer callback must not use a freed ``mcs``.

    Many concurrent connects to a multi-address target with the timer active
    and immediate cancellation; the first connect wins before the timer fires,
    exercising the freed-``mcs`` use-after-free that used to crash.
    """
    result = _run_repro_in_subprocess(_HAPPY_EYEBALLS_SCRIPT)
    _assert_clean(result, "happy-eyeballs mid-flight cancel UAF regression")
