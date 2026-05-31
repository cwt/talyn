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
