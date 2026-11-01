"""Regression tests for the 2026-11-01 audit fixes (BUG-400..413)."""

from __future__ import annotations

import asyncio
import gc
import os
import socket
import struct
import subprocess
import sys
import tempfile

import pytest

import talyn


def test_future_reinit_does_not_steal_loop_reference() -> None:
    """BUG-401: future.__init__ must not double-decref py_loop."""
    loop = talyn.Loop()
    try:
        fut = loop.create_future()
        before = sys.getrefcount(loop)
        fut.__init__(loop=loop)
        after = sys.getrefcount(loop)
        assert after == before
        assert loop.create_future() is not None
    finally:
        loop.close()


def test_huge_ready_queue_capacity_is_a_clean_memory_error() -> None:
    """BUG-404: 2**63 + 1 used to wrap ceilPowerOfTwo to 0 and SIGSEGV."""
    with pytest.raises(MemoryError):
        talyn.Loop(2**63 + 1)


def test_getaddrinfo_ai_numerichost_rejects_hostname() -> None:
    """BUG-406: AI_NUMERICHOST must not resolve a non-numeric name."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(ValueError):
            await loop.getaddrinfo(
                "localhost", 80, flags=socket.AI_NUMERICHOST
            )

    talyn.run(main())


def test_getnameinfo_ni_numerichost_skips_reverse_dns() -> None:
    """BUG-406: NI_NUMERICHOST must return the literal address immediately."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        result = await loop.getnameinfo(
            ("192.0.2.1", 80), socket.NI_NUMERICHOST
        )
        assert result == ("192.0.2.1", 80)

    talyn.run(main())


def test_datagram_close_releases_write_buffer() -> None:
    """BUG-408: close() must release the pending datagram byte count."""

    class Proto(asyncio.DatagramProtocol):
        def connection_made(self, transport) -> None:
            pass

        def datagram_received(self, data, addr) -> None:
            pass

        def error_received(self, exc) -> None:
            pass

    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(
            Proto, local_addr=("127.0.0.1", 0)
        )
        try:
            transport.sendto(b"x" * 512, ("127.0.0.1", 9))
            assert transport.get_write_buffer_size() == 512
            transport.close()
            await asyncio.sleep(0.3)
            assert transport.get_write_buffer_size() == 0
        finally:
            transport.close()

    talyn.run(main())


def test_custom_task_factory_typeerror_called_once() -> None:
    """BUG-409: a genuine TypeError must not trigger the legacy retry."""
    calls: list[dict] = []

    def factory(loop, coro, **kwargs):
        calls.append(dict(kwargs))
        raise TypeError("factory exploded for a real reason")

    async def probe():
        return 1

    async def main() -> None:
        loop = asyncio.get_running_loop()
        coro = probe()
        loop.set_task_factory(factory)
        try:
            with pytest.raises(TypeError, match="factory exploded"):
                loop.create_task(coro, name="probe")
            assert len(calls) == 1
        finally:
            loop.set_task_factory(None)
            coro.close()

    talyn.run(main())


def test_datagram_huge_fileno_is_rejected() -> None:
    """BUG-407: fileno() values that do not fit fd_t must raise, not truncate."""

    class EvilSock:
        def fileno(self):
            return 2**40

    class Proto(asyncio.DatagramProtocol):
        def connection_made(self, transport) -> None:
            pass

        def datagram_received(self, data, addr) -> None:
            pass

    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(ValueError):
            await loop.create_datagram_endpoint(Proto, sock=EvilSock())

    talyn.run(main())


def test_fs_watcher_rearms_after_last_watch_removed() -> None:
    """BUG-403: adding a watch after the list was empty must re-arm inotify."""
    events: list[str] = []

    def callback(mask, cookie, name) -> None:
        events.append(name)

    async def main() -> None:
        loop = asyncio.get_running_loop()
        with tempfile.TemporaryDirectory() as tmpdir:
            first = loop._add_path_watcher(tmpdir, 2 | 256, callback)
            with open(os.path.join(tmpdir, "one.txt"), "w") as handle:
                handle.write("x")
            await asyncio.sleep(0.25)
            assert events

            first.cancel()
            await asyncio.sleep(0.25)
            with open(os.path.join(tmpdir, "drain.txt"), "w") as handle:
                handle.write("x")
            await asyncio.sleep(0.25)

            events.clear()
            second = loop._add_path_watcher(tmpdir, 2 | 256, callback)
            try:
                with open(os.path.join(tmpdir, "two.txt"), "w") as handle:
                    handle.write("x")
                await asyncio.sleep(0.5)
                assert events, "FS watcher was not re-armed"
            finally:
                second.cancel()

    talyn.run(main())


def test_loop_clear_with_armed_fs_watcher_does_not_deadlock() -> None:
    """BUG-400: GC teardown of a loop with an armed watcher must complete."""
    code = "\n".join(
        [
            "import gc",
            "import tempfile",
            "import talyn",
            "loop = talyn.Loop()",
            "with tempfile.TemporaryDirectory() as d:",
            "    h = loop._add_path_watcher(d, 2, lambda *a: None)",
            "    del h",
            "    gc.collect()",
            "del loop",
            "gc.collect()",
            "print('ok')",
        ]
    )
    proc = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
        timeout=20,
        env={**os.environ, "PYTHONPATH": os.getcwd()},
    )
    assert proc.returncode == 0, proc.stderr
    assert "ok" in proc.stdout


def test_connection_lost_receives_error_on_reset() -> None:
    """BUG-402: an I/O error must reach connection_lost as an exception."""
    lost: list[BaseException | None] = []

    class Client(asyncio.Protocol):
        def __init__(self) -> None:
            self.lost = asyncio.get_running_loop().create_future()

        def connection_made(self, transport) -> None:
            pass

        def connection_lost(self, exc) -> None:
            lost.append(exc)
            if not self.lost.done():
                self.lost.set_result(None)

    class Server(asyncio.Protocol):
        def connection_made(self, transport) -> None:
            sock = transport.get_extra_info("socket")
            sock.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
            transport.abort()

    async def main() -> None:
        loop = asyncio.get_running_loop()
        server = await loop.create_server(Server, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        proto = Client()
        transport, _ = await loop.create_connection(
            lambda: proto, "127.0.0.1", port
        )
        try:
            await asyncio.wait_for(proto.lost, 3)
            assert lost
            assert isinstance(lost[0], OSError)
        finally:
            transport.close()
            server.close()
            await server.wait_closed()

    talyn.run(main())
