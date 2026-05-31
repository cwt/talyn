import asyncio

import pytest

import talyn
from talyn.loop import _subprocess_popens


class SubprocessProtocolStub(asyncio.SubprocessProtocol):
    def __init__(self) -> None:
        loop = asyncio.get_running_loop()
        self.connected = loop.create_future()
        self.exited = loop.create_future()
        self.closed = loop.create_future()
        self.exit_code: int | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport
        self.connected.set_result(None)

    def pipe_data_received(self, fd: int, data: bytes) -> None:
        pass

    def process_exited(self) -> None:
        self.exit_code = self.transport.get_returncode()
        self.exited.set_result(None)

    def connection_lost(self, exc: BaseException | None) -> None:
        self.closed.set_result(None)


def test_subprocess_exec_basic() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/true"
        )
        assert transport.get_pid() > 0
        await protocol.exited
        assert protocol.exit_code == 0
        await protocol.closed

    talyn.run(main())


def test_subprocess_exec_sleep() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/sleep", "0.1"
        )
        await protocol.exited
        assert protocol.exit_code == 0
        transport.close()

    talyn.run(main())


def test_subprocess_get_pid() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/true"
        )
        pid = transport.get_pid()
        assert isinstance(pid, int)
        assert pid > 0
        transport.close()

    talyn.run(main())


def test_subprocess_kill() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/sleep", "10"
        )
        transport.kill()
        await protocol.exited
        assert protocol.exit_code is not None
        assert protocol.exit_code < 0  # negative = killed by signal
        transport.close()

    talyn.run(main())


def test_subprocess_terminate() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/sleep", "10"
        )
        transport.terminate()
        await protocol.exited
        assert protocol.exit_code is not None
        transport.close()

    talyn.run(main())


def test_subprocess_send_signal() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/sleep", "10"
        )
        import signal
        transport.send_signal(signal.SIGTERM)
        await protocol.exited
        assert protocol.exit_code is not None
        transport.close()

    talyn.run(main())


def test_subprocess_returncode_none_before_exit() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/sleep", "5"
        )
        assert transport.get_returncode() is None
        transport.kill()
        await protocol.exited
        transport.close()

    talyn.run(main())


def test_subprocess_missing_factory() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises((ValueError, TypeError)):
            await loop.subprocess_exec(None, "/usr/bin/true")

    talyn.run(main())


def test_subprocess_popen_cleaned_on_success() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/true"
        )
        pid = transport.get_pid()
        # Must be cleaned from global dict immediately
        assert pid not in _subprocess_popens, \
            f"Popen for pid {pid} leaked in _subprocess_popens"
        # Must be kept alive on the transport so Popen.__del__ doesn't
        # reap the child before the transport does
        assert hasattr(transport, '_popen'), \
            "Popen not attached to transport"
        assert transport._popen.pid == pid, \
            "Wrong Popen attached to transport"
        await protocol.exited
        assert protocol.exit_code == 0
        transport.close()

    talyn.run(main())



