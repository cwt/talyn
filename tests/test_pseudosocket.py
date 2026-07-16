import asyncio
import socket

import talyn


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
