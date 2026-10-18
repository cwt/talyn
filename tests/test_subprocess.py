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
        assert pid not in _subprocess_popens, (
            f"Popen for pid {pid} leaked in _subprocess_popens"
        )
        # Must be kept alive on the transport so Popen.__del__ doesn't
        # reap the child before the transport does
        assert hasattr(transport, "_popen"), "Popen not attached to transport"
        assert transport._popen.pid == pid, "Wrong Popen attached to transport"
        await protocol.exited
        assert protocol.exit_code == 0
        transport.close()

    talyn.run(main())


def test_subprocess_get_extra_info_default() -> None:
    """BUG-320: get_extra_info must return the caller-provided default
    (keyword or second positional) for unknown keys instead of an
    unconditional None, and still serve the known keys."""

    async def main() -> None:
        loop = asyncio.get_running_loop()
        transport, protocol = await loop.subprocess_exec(
            SubprocessProtocolStub, "/usr/bin/true"
        )
        try:
            assert transport.get_extra_info("unknown-key") is None
            assert transport.get_extra_info("unknown-key", 42) == 42
            assert transport.get_extra_info("unknown-key", default=42) == 42
            assert transport.get_extra_info("pid", default=0) == transport.get_pid()
        finally:
            transport.close()

    talyn.run(main())


def test_subprocess_exec_pid_out_of_range_raises() -> None:
    """BUG-324: an out-of-range or non-positive pid must raise ValueError
    instead of panicking (Debug/ReleaseSafe) or silently truncating
    (ReleaseFast). Exercised against the native method directly - the
    Python wrapper always passes a real popen.pid."""
    from talyn.loop import _Loop

    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(ValueError, match="out of range"):
            await _Loop.subprocess_exec(
                loop, SubprocessProtocolStub, "/bin/true", pid=2**40
            )
        with pytest.raises(ValueError, match="positive"):
            await _Loop.subprocess_exec(
                loop, SubprocessProtocolStub, "/bin/true", pid=-1
            )

    talyn.run(main())


def test_bug366_pidfd_closed_on_loop_close() -> None:
    """BUG-366: spawning a subprocess and letting the loop close before
    the child exits must not leak the exit watcher's pidfd.

    The teardown cancels the pending WatchReadable op; pre-fix,
    ``pidfd_exit_callback`` took the cancelled branch and returned
    without closing the pidfd, ``cleanup_pidfd`` only decref'd the
    transport, and ``subprocess_dealloc`` never closed it either — six
    spawns left six stray descriptors in the process table.

    The count is taken over ``anon_inode:[pidfd]`` descriptors directly
    (a plain fd count would also pick up the abandoned transport's
    child pipes, which are outside this bug's scope).
    """
    import os

    def pidfd_count() -> int:
        count = 0
        with os.scandir("/proc/self/fd") as entries:
            for entry in entries:
                try:
                    if "pidfd" in os.readlink(entry.path):
                        count += 1
                except OSError:
                    pass
        return count

    for _ in range(6):
        async def main() -> SubprocessProtocolStub:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.subprocess_exec(
                SubprocessProtocolStub, "/usr/bin/sleep", "5"
            )
            # Abandon the transport: the child never exits inside the
            # run, so the exit watcher is torn down with the loop.
            _ = protocol
            return transport

        talyn.run(main())

    leaked = pidfd_count()
    assert leaked == 0, (
        f"subprocess pidfds leaked on loop close: {leaked} stray descriptors"
    )
