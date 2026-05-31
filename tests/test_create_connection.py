import asyncio
import socket
import threading
from collections.abc import Callable
from typing import Any

import pytest

import talyn


def _run_echo_server(
    sock: socket.socket, ready: threading.Event, stop: threading.Event
) -> None:
    sock.listen(1)
    ready.set()
    sock.settimeout(0.5)
    try:
        while not stop.is_set():
            try:
                conn, _ = sock.accept()
            except socket.timeout:
                continue
            try:
                while not stop.is_set():
                    try:
                        conn.settimeout(0.1)
                        data = conn.recv(1024)
                        if not data:
                            break
                        conn.sendall(data)
                    except socket.timeout:
                        continue
            finally:
                conn.close()
    finally:
        sock.close()


def _start_echo_server() -> tuple[str, int, threading.Event]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    addr = sock.getsockname()
    ready = threading.Event()
    stop = threading.Event()
    t = threading.Thread(target=_run_echo_server, args=(sock, ready, stop), daemon=True)
    t.start()
    ready.wait()
    return addr[0], addr[1], stop


class EchoProtocol(asyncio.Protocol):
    def __init__(self) -> None:
        loop = asyncio.get_running_loop()
        self.connected = loop.create_future()
        self.received = loop.create_future()
        self.disconnected = loop.create_future()
        self.received_data: list[bytes] = []
        self.error: BaseException | None = None

    def connection_made(self, transport: asyncio.Transport) -> None:
        self.transport = transport
        self.connected.set_result(None)

    def data_received(self, data: bytes) -> None:
        self.received_data.append(data)
        old = self.received
        self.received = asyncio.get_running_loop().create_future()
        old.set_result(data)

    def connection_lost(self, exc: BaseException | None) -> None:
        self.error = exc
        self.received.cancel()
        self.disconnected.set_result(None)


# --- Happy path ---


def test_create_connection_basic() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(EchoProtocol, host, port)
            assert isinstance(transport, asyncio.Transport)
            assert isinstance(protocol, EchoProtocol)
            assert protocol.connected.done()
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_send_recv() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(EchoProtocol, host, port)
            transport.write(b"hello")
            data = await protocol.received
            assert data == b"hello"
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_close() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(EchoProtocol, host, port)
            transport.close()
            await protocol.disconnected

        talyn.run(main())
    finally:
        stop.set()


# --- Error paths ---


def test_create_connection_refused() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]

        with pytest.raises(ConnectionRefusedError):
            await loop.create_connection(EchoProtocol, "127.0.0.1", port)

    talyn.run(main())


def test_create_connection_missing_args() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(TypeError):
            await loop.create_connection()  # type: ignore

    talyn.run(main())


def test_create_connection_invalid_protocol_factory() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(ValueError, match="Invalid protocol_factory"):
            await loop.create_connection("not a callable", "127.0.0.1", 12345)  # type: ignore

    talyn.run(main())


def test_create_connection_lambda_factory() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(
                lambda: EchoProtocol(), host, port
            )
            assert isinstance(protocol, EchoProtocol)
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_multiple_messages() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(EchoProtocol, host, port)
            for i in range(5):
                msg = f"msg{i}".encode()
                transport.write(msg)
                data = await protocol.received
                assert data == msg
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_extra_info() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, protocol = await loop.create_connection(EchoProtocol, host, port)
            peername = transport.get_extra_info("peername")
            assert peername is not None
            assert peername[0] == "127.0.0.1"
            sockname = transport.get_extra_info("sockname")
            assert sockname is not None
            sock = transport.get_extra_info("socket")
            assert sock is not None
            assert hasattr(sock, "fileno")
            assert sock.fileno() > 0
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_write_eof() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, _ = await loop.create_connection(EchoProtocol, host, port)
            assert transport.can_write_eof()
            transport.write_eof()
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_is_closing() -> None:
    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            transport, _ = await loop.create_connection(EchoProtocol, host, port)
            assert not transport.is_closing()
            transport.close()
            assert transport.is_closing()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_all_errors() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        # Find a port that is definitely refused
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]

        # Trigger connection failure with all_errors=True
        # Note: ExceptionGroup is only available in Python 3.11+
        try:
            from builtins import ExceptionGroup
        except ImportError:
            # Fallback for older versions if any, though we target 3.13+
            return

        with pytest.raises(ExceptionGroup, match="Multiple connection failures"):
            await loop.create_connection(
                EchoProtocol, "127.0.0.1", port, all_errors=True
            )

    talyn.run(main())


def test_create_connection_ssl_passes_kwargs() -> None:
    """BUG-19: _create_ssl_connection must forward connection kwargs."""
    from talyn.loop import Loop as TalynLoop
    from unittest.mock import patch
    import ssl

    captured_kwargs: dict[str, object] = {}

    async def patched_create_connection(
        self: TalynLoop,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str | None = None,
        port: int | None = None,
        **kwargs: Any,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        nonlocal captured_kwargs
        captured_kwargs = kwargs
        raise OSError("intentional stop")

    async def test() -> None:
        loop = asyncio.get_running_loop()
        ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        with patch.object(TalynLoop, "create_connection", patched_create_connection):
            with pytest.raises(OSError, match="intentional stop"):
                await loop.create_connection(
                    asyncio.Protocol,
                    "127.0.0.1",
                    12345,
                    ssl=ctx,
                    family=socket.AF_INET,
                    local_addr=("0.0.0.0", 0),
                    happy_eyeballs_delay=0.1,
                    interleave=1,
                    all_errors=False,
                )

        assert "family" in captured_kwargs, (
            f"family kwarg was dropped! captured_kwargs={captured_kwargs}"
        )
        assert captured_kwargs.get("family") == socket.AF_INET
        assert captured_kwargs.get("local_addr") == ("0.0.0.0", 0)
        assert captured_kwargs.get("happy_eyeballs_delay") == 0.1
        assert captured_kwargs.get("interleave") == 1
        assert captured_kwargs.get("all_errors") == False

    from talyn import Loop
    loop = Loop()
    try:
        loop.run_until_complete(test())
    finally:
        loop.close()
