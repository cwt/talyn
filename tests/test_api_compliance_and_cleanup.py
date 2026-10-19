import asyncio
import collections
import os
import socket
import sys

import pytest

import talyn

talyn.install()

pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning")


class EchoServerProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)

    def connection_lost(self, exc):
        pass


class SubprocessOutputProtocol(asyncio.SubprocessProtocol):
    def __init__(self):
        loop = asyncio.get_running_loop()
        self.connected = loop.create_future()
        self.exited = loop.create_future()
        self.closed = loop.create_future()
        self.output = bytearray()
        self.exit_code = None

    def connection_made(self, transport):
        self.transport = transport
        self.connected.set_result(None)

    def pipe_data_received(self, fd, data):
        if fd == 1:
            self.output.extend(data)

    def process_exited(self):
        self.exit_code = self.transport.get_returncode()
        self.exited.set_result(None)

    def connection_lost(self, exc):
        self.closed.set_result(None)


def test_create_server_start_serving_flag():
    async def run_test():
        loop = asyncio.get_running_loop()
        server = await loop.create_server(
            EchoServerProtocol,
            "127.0.0.1",
            0,
            start_serving=False,
        )
        assert not server.is_serving()

        await server.start_serving()
        assert server.is_serving()

        server.close()
        assert not server.is_serving()
        await server.wait_closed()

    talyn.run(run_test())


def test_subprocess_exec_kwargs_forwarding():
    async def run_test():
        loop = asyncio.get_running_loop()
        custom_env = dict(os.environ)
        custom_env["TEST_TALYN_ENV_VAR"] = "talyn_kwargs_ok"

        transport, protocol = await loop.subprocess_exec(
            SubprocessOutputProtocol,
            sys.executable,
            "-c",
            "import os; print(os.environ.get('TEST_TALYN_ENV_VAR', ''))",
            env=custom_env,
        )
        await protocol.exited
        assert protocol.exit_code == 0
        await protocol.closed
        assert b"talyn_kwargs_ok" in protocol.output

    talyn.run(run_test())


def test_unstarted_coroutine_cleanup_on_loop_close():
    executed = []

    async def unstarted_coro():
        executed.append("ran")

    loop = talyn.Loop()
    task = loop.create_task(unstarted_coro())
    loop.close()

    assert executed == []
    assert task.cancelled() or task.done()


def test_ipv6_malformed_address_resolution():
    async def run_test():
        loop = asyncio.get_running_loop()
        with pytest.raises((socket.gaierror, OSError, RuntimeError)):
            await loop.getaddrinfo(":::1", 80)

    talyn.run(run_test())


def test_ssl_transport_wrapper_write_buffer_deque():
    from talyn.loop import _SSLTransportWrapper

    class DummyRawTransport:
        def get_write_buffer_size(self):
            return 0

        def get_write_buffer_limits(self):
            return (0, 0)

        def set_write_buffer_limits(self, high=None, low=None):
            pass

    wrapper = _SSLTransportWrapper(None, DummyRawTransport(), None)
    assert isinstance(wrapper._write_buffer, collections.deque)
