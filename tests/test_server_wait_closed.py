"""BUG-376 regression tests.

``Server.__init__`` never wired ``srv.server_ref = self`` for the
TCP (``loop.create_server``) and SSL (``_create_ssl_server``) paths —
only the unix-server path did it explicitly. Without the wiring the
Zig ``StreamServer`` never called ``Server._attach()`` on accept nor
``Server._detach()`` on client disconnect, so ``_active_count``
stayed 0 forever and ``await server.wait_closed()`` resolved
immediately while client connections were still active (breaking the
Python 3.12+/3.13+ ``Server.wait_closed()`` semantics).

The fix wires ``srv.server_ref`` for every stream server inside
``Server.__init__`` itself.
"""

import ssl

import pytest

import talyn

talyn.install()

import asyncio

import socket
import threading
import tempfile
import subprocess
import os

pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning")


class EchoProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)

    def connection_lost(self, exc):
        pass


class EchoClient(asyncio.Protocol):
    def __init__(self):
        self.data_future = asyncio.get_running_loop().create_future()
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        if not self.data_future.done():
            self.data_future.set_result(data)

    def connection_lost(self, exc):
        if not self.data_future.done():
            self.data_future.set_exception(exc or ConnectionResetError())


@pytest.mark.asyncio
async def test_bug376_tcp_wait_closed_tracks_active_connection():
    loop = asyncio.get_running_loop()
    server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
    addr = server.sockets[0].getsockname()

    reader, writer = await asyncio.open_connection(addr[0], addr[1])
    writer.write(b"ping")
    assert await reader.read(4) == b"ping"  # echo round trip: accepted

    # Pre-fix _active_count stayed 0 forever.
    assert server._active_count == 1, (
        "accepted client connection did not bump Server._active_count "
        "(srv.server_ref is not wired)"
    )

    server.close()
    wait_task = asyncio.ensure_future(server.wait_closed())
    await asyncio.sleep(0.05)
    # Pre-fix wait_closed resolved immediately here.
    assert not wait_task.done(), (
        "Server.wait_closed() resolved while a client connection was "
        "still active"
    )

    writer.close()
    await asyncio.wait_for(wait_task, timeout=2.0)


@pytest.fixture(scope="module")
def ssl_cert_file():
    certf = tempfile.NamedTemporaryFile(suffix=".pem", delete=False)
    certf.close()
    keyf = tempfile.NamedTemporaryFile(suffix=".pem", delete=False)
    keyf.close()
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            keyf.name,
            "-out",
            certf.name,
            "-days",
            "1",
            "-nodes",
            "-subj",
            "/CN=localhost",
        ],
        capture_output=True,
        check=True,
    )
    yield certf.name, keyf.name
    os.unlink(certf.name)
    os.unlink(keyf.name)


@pytest.mark.asyncio
async def test_bug376_ssl_wait_closed_tracks_active_connection(ssl_cert_file):
    cert_path, key_path = ssl_cert_file
    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)

    loop = asyncio.get_running_loop()
    server = await loop.create_server(
        EchoProtocol, "127.0.0.1", 0, ssl=server_ctx
    )
    addr = server.sockets[0].getsockname()

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    transport, protocol = await loop.create_connection(
        EchoClient,
        addr[0],
        addr[1],
        ssl=client_ctx,
        server_hostname="localhost",
    )
    transport.write(b"ping")
    assert await protocol.data_future == b"ping"  # TLS echo round trip

    assert server._active_count == 1, (
        "accepted SSL client connection did not bump "
        "Server._active_count (srv.server_ref is not wired)"
    )

    server.close()
    wait_task = asyncio.ensure_future(server.wait_closed())
    await asyncio.sleep(0.05)
    assert not wait_task.done(), (
        "SSL Server.wait_closed() resolved while a client connection "
        "was still active"
    )

    transport.close()
    await asyncio.wait_for(wait_task, timeout=2.0)
