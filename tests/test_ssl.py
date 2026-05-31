import os
import ssl
import subprocess
import tempfile

import pytest

import talyn

talyn.install()
import asyncio

pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning")


@pytest.fixture(scope="module")
def ssl_certs():
    keyf = tempfile.NamedTemporaryFile(suffix=".key", delete=False)
    certf = tempfile.NamedTemporaryFile(suffix=".crt", delete=False)
    keyf.close()
    certf.close()
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
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=certf.name, keyfile=keyf.name)
    yield ctx, keyf.name, certf.name
    os.unlink(keyf.name)
    os.unlink(certf.name)


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
        pass


@pytest.mark.asyncio
async def test_ssl_create_connection_handshake(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    # Use threading raw SSL server (blocking)
    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    result_data = []

    def server_thread():
        try:
            conn, _ = server_sock.accept()
            sconn = server_ctx.wrap_socket(conn, server_side=True)
            data = sconn.recv(1024)
            sconn.sendall(data)
            sconn.close()
            server_sock.close()
            result_data.append(data)
        except Exception as e:
            result_data.append(e)

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()

    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient,
        addr[0],
        addr[1],
        ssl=client_ctx,
    )

    transport.write(b"hello")
    data = await protocol.data_future
    assert data == b"hello"
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_server_hostname(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        sconn = server_ctx.wrap_socket(conn, server_side=True)
        data = sconn.recv(1024)
        sconn.sendall(data)
        sconn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient,
        addr[0],
        addr[1],
        ssl=client_ctx,
        server_hostname="localhost",
    )

    transport.write(b"hello")
    data = await protocol.data_future
    assert data == b"hello"
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_echo_large(ssl_certs):
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        sconn = server_ctx.wrap_socket(conn, server_side=True)
        total = b""
        while True:
            chunk = sconn.recv(4096)
            if not chunk:
                break
            sconn.sendall(chunk)
            total += chunk
            if len(total) >= 10000:
                break
        sconn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_connection(
        EchoClient,
        addr[0],
        addr[1],
        ssl=client_ctx,
    )

    data = b"x" * 10000
    transport.write(data)
    received = b""
    while len(received) < len(data):
        chunk = await protocol.data_future
        received += chunk
        if len(received) < len(data):
            protocol.data_future = loop.create_future()

    assert received == data
    transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_connection_wrong_context():
    """SSL connection to plain TCP server should fail cleanly"""
    import socket
    import threading

    server_sock = socket.socket()
    server_sock.bind(("127.0.0.1", 0))
    server_sock.listen(1)
    addr = server_sock.getsockname()

    def server_thread():
        conn, _ = server_sock.accept()
        conn.recv(1024)  # consume ClientHello
        conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n")  # not SSL
        conn.close()
        server_sock.close()

    t = threading.Thread(target=server_thread, daemon=True)
    t.start()
    await asyncio.sleep(0.1)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    loop = asyncio.get_running_loop()

    with pytest.raises((ConnectionError, ssl.SSLError)):
        transport, protocol = await loop.create_connection(
            EchoClient,
            addr[0],
            addr[1],
            ssl=client_ctx,
        )
        transport.close()

    t.join(timeout=5)


@pytest.mark.asyncio
async def test_ssl_create_server_handshake(ssl_certs):
    """SSL server can perform handshake with a threaded SSL client."""
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    class EchoServer(asyncio.Protocol):
        def __init__(self):
            self.transport = None
            self.received = []

        def connection_made(self, transport):
            self.transport = transport

        def data_received(self, data):
            self.received.append(data)
            self.transport.write(data)

        def connection_lost(self, exc):
            pass

    loop = asyncio.get_running_loop()
    srv = await loop.create_server(EchoServer, "127.0.0.1", 0, ssl=server_ctx)
    addr = srv.sockets[0].getsockname()

    result = {}

    def client():
        try:
            client_ctx = ssl.create_default_context()
            client_ctx.check_hostname = False
            client_ctx.verify_mode = ssl.CERT_NONE
            s = socket.socket()
            s.settimeout(5)
            s.connect(addr)
            ss = client_ctx.wrap_socket(s)
            ss.sendall(b"hello")
            data = ss.recv(1024)
            result["got"] = data
            ss.close()
        except Exception as e:
            result["err"] = e

    t = threading.Thread(target=client, daemon=True)
    t.start()

    await asyncio.sleep(1)
    srv.close()
    await asyncio.sleep(0.2)

    t.join(timeout=5)
    assert result.get("got") == b"hello"


@pytest.mark.asyncio
async def test_ssl_create_server_echo_ssl_client(ssl_certs):
    """SSL server + talyn SSL client echo."""
    server_ctx, key_path, cert_path = ssl_certs

    class EchoServer(asyncio.Protocol):
        def __init__(self):
            self.transport = None

        def connection_made(self, transport):
            self.transport = transport

        def data_received(self, data):
            self.transport.write(data)

        def connection_lost(self, exc):
            pass

    loop = asyncio.get_running_loop()
    srv = await loop.create_server(EchoServer, "127.0.0.1", 0, ssl=server_ctx)
    addr = srv.sockets[0].getsockname()

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    transport, protocol = await loop.create_connection(
        EchoClient,
        addr[0],
        addr[1],
        ssl=client_ctx,
    )

    transport.write(b"hello")
    data = await protocol.data_future
    assert data == b"hello"
    transport.close()

    srv.close()
    await asyncio.sleep(0.1)


@pytest.mark.asyncio
async def test_ssl_create_server_multiple_connections(ssl_certs):
    """SSL server handles multiple sequential connections."""
    server_ctx, key_path, cert_path = ssl_certs

    import socket
    import threading

    class EchoServer(asyncio.Protocol):
        def connection_made(self, t):
            self.t = t

        def data_received(self, d):
            self.t.write(d)

        def connection_lost(self, e):
            pass

    loop = asyncio.get_running_loop()
    srv = await loop.create_server(EchoServer, "127.0.0.1", 0, ssl=server_ctx)
    addr = srv.sockets[0].getsockname()

    def make_client(msg):
        result = {}

        def client():
            try:
                client_ctx = ssl.create_default_context()
                client_ctx.check_hostname = False
                client_ctx.verify_mode = ssl.CERT_NONE
                s = socket.socket()
                s.settimeout(5)
                s.connect(addr)
                ss = client_ctx.wrap_socket(s)
                ss.sendall(msg)
                data = ss.recv(1024)
                result["got"] = data
                ss.close()
            except Exception as e:
                result["err"] = e

        return client, result

    for i, msg in enumerate([b"ping", b"pong", b"test"]):
        client_fn, result = make_client(msg)
        t = threading.Thread(target=client_fn, daemon=True)
        t.start()
        await asyncio.sleep(0.3)
        t.join(timeout=5)
        assert result.get("got") == msg, f"Connection {i}: expected {msg}, got {result}"

    srv.close()
    await asyncio.sleep(0.1)


@pytest.mark.asyncio
async def test_start_tls_buffered_data(ssl_certs):
    """Verify start_tls works even when there is buffered data in the StreamReader."""
    server_ctx, key_path, cert_path = ssl_certs

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    async def handle_client(reader, writer):
        # Wait for TLS ClientHello to be buffered before start_tls().
        await reader._wait_for_data("test_start_tls_buffered_data")
        assert reader._buffer

        await writer.start_tls(server_ctx)

        line = await reader.readline()
        assert line == b"ping\n"
        writer.write(b"pong\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    srv = await asyncio.start_server(handle_client, "127.0.0.1", 0)
    addr = srv.sockets[0].getsockname()

    # Client connection
    reader, writer = await asyncio.open_connection(addr[0], addr[1])
    await writer.start_tls(client_ctx)

    writer.write(b"ping\n")
    await writer.drain()

    # Read the secure message
    secure_resp = await reader.readline()
    assert secure_resp == b"pong\n"

    writer.close()
    await writer.wait_closed()
    srv.close()
    await srv.wait_closed()


@pytest.mark.asyncio
async def test_ssl_graceful_shutdown(ssl_certs):
    """Verify that SSL transport wrapper close performs a graceful shutdown sequence."""
    server_ctx, key_path, cert_path = ssl_certs

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    async def handle_client(reader, writer):
        await reader.readline()
        writer.write(b"ok\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    srv = await asyncio.start_server(handle_client, "127.0.0.1", 0, ssl=server_ctx)
    addr = srv.sockets[0].getsockname()

    reader, writer = await asyncio.open_connection(addr[0], addr[1], ssl=client_ctx)
    writer.write(b"ping\n")
    await writer.drain()

    resp = await reader.readline()
    assert resp == b"ok\n"

    # Close and wait for graceful SSL shutdown handshake to complete
    writer.close()
    await writer.wait_closed()

    srv.close()
    await srv.wait_closed()


@pytest.mark.asyncio
async def test_ssl_flow_control(ssl_certs):
    """Verify that pause_writing and resume_writing propagate correctly in SSL protocols."""
    server_ctx, key_path, cert_path = ssl_certs

    loop = asyncio.get_running_loop()
    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    events = []

    class FlowControlClient(asyncio.Protocol):
        def connection_made(self, transport):
            self.transport = transport

        def data_received(self, data):
            pass

        def pause_writing(self):
            events.append("paused")

        def resume_writing(self):
            events.append("resumed")

    async def handle_client(reader, writer):
        await reader.readline()
        writer.write(b"ok\n")
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    srv = await asyncio.start_server(handle_client, "127.0.0.1", 0, ssl=server_ctx)
    addr = srv.sockets[0].getsockname()

    transport, protocol = await loop.create_connection(
        FlowControlClient, addr[0], addr[1], ssl=client_ctx
    )

    # Let's verify we can get/set buffer limits
    limits = transport.get_write_buffer_limits()
    assert isinstance(limits, tuple)
    transport.set_write_buffer_limits(4096, 1024)
    assert transport.get_write_buffer_limits() == (1024, 4096)

    # Manually trigger pause_writing and resume_writing on the wrapper's SSP/SP protocol
    # to simulate backpressure from the native transport layer.
    ssl_protocol = transport._ssp
    ssl_protocol.pause_writing()
    ssl_protocol.resume_writing()

    assert events == ["paused", "resumed"]

    transport.close()
    srv.close()
    await srv.wait_closed()
