import asyncio
import socket

import pytest

import talyn


def test_bug427_socket_keeps_own_fd_across_transport_close():
    """BUG-427: the pseudo-socket owns a dup of the transport fd — closing
    the transport must not invalidate it, and closing it afterwards must
    not target a reused descriptor number."""
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            try:
                client.settimeout(1.0)
                client.sendall(b"hello")
                try:
                    client.recv(1024)
                except Exception:
                    pass
            finally:
                client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        assert await reader.read(5) == b"hello"

        sock = writer.transport.get_extra_info("socket")
        assert sock is not None
        fileno = sock.fileno()
        assert fileno > 0
        # BUG-427: the fd is a dup of the transport fd (same open file
        # description), not the transport fd itself.

        # Close the transport; the pseudo-socket is invalidated with it
        # (stdlib semantics: the transport closes its socket, so
        # BUG-326's getsockname-after-close still raises EBADF).
        writer.close()
        await writer.wait_closed()
        assert sock.fileno() == -1
        # A later close() is an idempotent no-op (BUG-291) and can never
        # target a reused descriptor number.
        sock.close()
        assert sock.fileno() == -1
        sock.close()
        assert sock.fileno() == -1

        # A freshly opened socket gets a sane descriptor (no double-close
        # shrapnel landing on reused numbers).
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            assert probe.fileno() > 0
        finally:
            probe.close()

        await server_task
        server_sock.close()

    talyn.run(main())


def test_bug447_transport_survives_app_socket_close():
    """BUG-447: closing get_extra_info('socket') must not close the
    transport's descriptor. Pre-fix the pseudo-socket aliased the transport
    fd, so the app close + the later transport teardown closed the same
    (possibly reused) number twice."""
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            try:
                client.settimeout(2.0)
                client.sendall(b"ping")
                # Blocks until the client's side fully closes (FIN) or the
                # echo arrives.
                client.recv(1024)
            except Exception:
                pass
            finally:
                client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        assert await reader.read(4) == b"ping"

        sock = writer.transport.get_extra_info("socket")
        assert sock is not None
        sock.close()
        assert sock.fileno() == -1

        # The transport must still be fully functional after the app closed
        # the pseudo-socket.
        writer.write(b"pong")
        await writer.drain()
        writer.close()
        await writer.wait_closed()

        await server_task
        server_sock.close()

    talyn.run(main())


def test_pseudosocket():
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.sendall(b"hello")
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        transport = writer.transport

        sock = transport.get_extra_info("socket")
        assert sock is not None
        # In our implementation it should be talyn.talyn_zig.PseudoSocket
        # (or just look like a socket)
        assert hasattr(sock, "fileno")
        assert hasattr(sock, "getsockname")
        assert hasattr(sock, "getpeername")
        assert hasattr(sock, "family")
        assert hasattr(sock, "type")

        assert sock.fileno() > 0
        assert sock.getsockname()[0] == "127.0.0.1"
        assert sock.getpeername()[0] == "127.0.0.1"
        assert sock.family == socket.AF_INET
        assert sock.type == socket.SOCK_STREAM

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_pseudosocket_sockopts():
    """PseudoSocket must behave like a real socket for socket-option calls.

    Libraries such as aiohttp call sock.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
    during connection setup; previously this raised AttributeError because
    PseudoSocket lacked the method. This guards against that regression.
    """
    import socket

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.sendall(b"hello")
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        data = await reader.read(5)
        assert data == b"hello"
        sock = writer.transport.get_extra_info("socket")
        assert sock is not None
        assert hasattr(sock, "setsockopt")
        assert hasattr(sock, "getsockopt")
        assert hasattr(sock, "settimeout")
        assert hasattr(sock, "gettimeout")
        assert hasattr(sock, "getblocking")
        assert hasattr(sock, "dup")

        # Round-trip an integer socket option (TCP_NODELAY).
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        assert sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY) == 1

        # Round-trip a bytes buffer option (SO_LINGER) when supported.
        try:
            import struct

            linger_on = struct.pack("ii", 1, 0)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger_on)
            raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_LINGER, 8)
            assert raw[:4] == linger_on[:4]
        except (AttributeError, OSError):
            pass

        assert sock.getblocking() is True
        assert sock.gettimeout() is None

        dup_sock = sock.dup()
        assert dup_sock.fileno() > 0
        dup_sock.close()

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_pseudosocket_getsockopt_invalid_buflen():
    """A non-numeric buflen must raise TypeError and not leak exception state.

    Previously PyLong_AsLong's TypeError was left pending (no PyErr_Occurred
    check), so getsockopt returned a result with a stale exception that
    poisoned the next Python C API call.
    """
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        sock = writer.transport.get_extra_info("socket")
        assert sock is not None

        with pytest.raises(TypeError):
            sock.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE, "not-an-int")

        # No stale exception state: subsequent option calls must still work.
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        assert sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY) == 1

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_pseudosocket_getsockopt_buflen_returns_bytes():
    """BUG-437: getsockopt(level, optname, buflen) must return bytes even
    when the option is exactly 4 bytes wide.

    The old code keyed the int-vs-bytes decision off the post-call option
    size, so an explicit buflen == 4 returned an int instead of the bytes
    object CPython returns for a supplied length argument.
    """
    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        sock = writer.transport.get_extra_info("socket")
        assert sock is not None

        # No buflen: a 4-byte option (SO_TYPE) is returned as an int.
        assert isinstance(sock.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE), int)

        # Explicit buflen for the same option: CPython returns a bytes object.
        raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE, 4)
        assert isinstance(raw, bytes)
        assert len(raw) == 4

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())


def test_pseudosocket_close_is_idempotent():
    """BUG-291: a second close() must be a no-op instead of closing
    whatever fd number now occupies the slot (stdlib socket semantics)."""
    import asyncio
    import errno
    import os

    async def main():
        loop = asyncio.get_running_loop()

        class Proto(asyncio.Protocol):
            def connection_made(self, transport):
                self.transport = transport

        srv_sock, client_sock = socket.socketpair()
        try:
            t, p = await loop.create_connection(
                Proto, sock=client_sock
            )
            sock = t.get_extra_info("socket")
            fd = sock.fileno()

            sock.close()
            assert sock.fileno() == -1
            sock.close()  # second close: no-op, must not raise or touch others

            try:
                os.fstat(fd)
                raise AssertionError("fd still open after close()")
            except OSError as e:
                assert e.errno == errno.EBADF

            t.close()
        finally:
            srv_sock.close()

    talyn.run(main())


def test_pseudosocket_getsockname_after_close_raises():
    """BUG-326 (pseudosocket site): getsockname on a torn-down transport's
    fd must raise instead of returning a garbage address tuple (the
    libc-style errno decoder used to mis-read the getsockname failure)."""

    async def main():
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        reader, writer = await asyncio.open_connection(*addr)
        sock = writer.transport.get_extra_info("socket")
        writer.close()
        await writer.wait_closed()

        # The transport released the fd; the errno failure must surface.
        with pytest.raises(Exception):
            sock.getsockname()
        server_sock.close()

    talyn.run(main())


def test_pseudosocket_setsockopt_out_of_range_raises():
    """BUG-324: out-of-range level/optname/value integers must raise
    ValueError instead of panicking (Debug/ReleaseSafe) or silently
    truncating (ReleaseFast)."""

    async def main():
        loop = asyncio.get_running_loop()
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.sendall(b"hello")
            client.close()

        server_task = loop.run_in_executor(None, run_server)
        reader, writer = await asyncio.open_connection(*addr)
        sock = writer.transport.get_extra_info("socket")
        try:
            with pytest.raises(ValueError):
                sock.setsockopt(2**40, 1, 1)
            with pytest.raises(ValueError):
                sock.setsockopt(socket.IPPROTO_TCP, 2**40, 1)
            with pytest.raises(ValueError):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 2**40)
        finally:
            writer.close()
            await server_task
            server_sock.close()

    talyn.run(main())


def test_bug361_getsockopt_bounds():
    """BUG-361: getsockopt narrowed level/optname with unchecked @intCast —
    out-of-range values panicked (Debug/ReleaseSafe) or silently truncated
    (ReleaseFast). Must raise ValueError instead, like setsockopt
    already does since BUG-324."""
    import pytest

    async def main():
        loop = asyncio.get_running_loop()

        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.bind(("127.0.0.1", 0))
        server_sock.listen(1)
        addr = server_sock.getsockname()

        def run_server():
            client, _ = server_sock.accept()
            client.close()

        server_task = loop.run_in_executor(None, run_server)

        reader, writer = await asyncio.open_connection(*addr)
        sock = writer.transport.get_extra_info("socket")
        assert sock is not None

        with pytest.raises(ValueError):
            sock.getsockopt(2**45, 1)
        with pytest.raises(ValueError):
            sock.getsockopt(socket.SOL_SOCKET, 2**45)

        # The socket stays usable after the rejected calls.
        assert sock.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) > 0

        writer.close()
        await writer.wait_closed()
        await server_task
        server_sock.close()

    talyn.run(main())
