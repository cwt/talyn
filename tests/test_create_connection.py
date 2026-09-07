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
    import ssl
    from unittest.mock import patch

    from talyn.loop import Loop as TalynLoop

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
                    flags=socket.AI_ADDRCONFIG,
                    local_addr=("0.0.0.0", 0),
                    happy_eyeballs_delay=0.1,
                    interleave=1,
                    all_errors=False,
                )

        assert "family" in captured_kwargs, (
            f"family kwarg was dropped! captured_kwargs={captured_kwargs}"
        )
        assert captured_kwargs.get("family") == socket.AF_INET
        assert captured_kwargs.get("flags") == socket.AI_ADDRCONFIG
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


def test_create_connection_nan_inf_safety() -> None:
    host, port, stop = _start_echo_server()
    try:
        async def main() -> None:
            loop = asyncio.get_running_loop()
            for val in (float("nan"), float("inf"), float("-inf"), -1.0):
                t, p = await loop.create_connection(
                    EchoProtocol, host, port, happy_eyeballs_delay=val
                )
                t.close()
                await p.disconnected

            # NaN/Inf map to the default timeout (float cast safety).
            for val in (float("nan"), float("inf")):
                info = await loop.getaddrinfo(host, port, dns_timeout=val)
                assert len(info) > 0

            # Negative dns_timeout values must raise ValueError.
            for val in (float("-inf"), -1.0, -0.5):
                with pytest.raises(ValueError):
                    await loop.getaddrinfo(host, port, dns_timeout=val)

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_invalid_dns_timeout() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(TypeError):
            await loop.create_connection(
                EchoProtocol, "127.0.0.1", 80, dns_timeout="invalid"
            )
        with pytest.raises(ValueError):
            await loop.create_connection(
                EchoProtocol, "127.0.0.1", 80, dns_timeout=-1.0
            )

    talyn.run(main())


def test_getnameinfo_negative_dns_timeout() -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        with pytest.raises(ValueError):
            await loop.getnameinfo(("127.0.0.1", 80), 0, -1.0)

    talyn.run(main())




def test_create_connection_sock_protocol_factory_refcount() -> None:
    """BUG-309: the sock= path must hand the protocol factory to the
    dispatched transport creation with an OWNED reference - the callback's
    cleanup decref previously dropped the caller's reference (refcount
    underflow / premature deallocation).

    Both paths share an identical unrelated background retention, so the
    invariant under test is that the sock path's net reference delta equals
    the host/port path's delta over N cycles: the bug made the sock path
    come out exactly one reference lower per connection.

    A minimal accept-and-close listener is used instead of the threaded
    echo server - rapid sequential close cycles against a busy recv-loop
    thread trigger an unrelated pre-existing hang in the host path
    (reproduced on the pre-fix build too)."""
    import sys

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    addr = listener.getsockname()
    stop = threading.Event()

    def _accept_and_close() -> None:
        listener.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = listener.accept()
            except (socket.timeout, OSError):
                # OSError covers the listener being closed during shutdown.
                continue
            conn.close()  # immediate EOF; the client transport sees connection_lost
        listener.close()

    acceptor = threading.Thread(target=_accept_and_close, daemon=True)
    acceptor.start()

    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()
            factory: type[EchoProtocol] = EchoProtocol

            async def sock_cycle() -> None:
                client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                client.connect(addr)
                transport, protocol = await loop.create_connection(factory, sock=client)
                transport.close()
                await asyncio.wait_for(protocol.disconnected, timeout=2.0)
                # Caller owns the fd: only release it once the transport
                # has fully completed its teardown.
                client.close()
                del transport, protocol, client

            async def host_cycle() -> None:
                transport, protocol = await loop.create_connection(factory, addr[0], addr[1])
                transport.close()
                await asyncio.wait_for(protocol.disconnected, timeout=2.0)
                del transport, protocol

            # Warm-up so lazy caches settle before measuring.
            await sock_cycle()
            await asyncio.sleep(0.05)

            base = sys.getrefcount(factory)
            for _ in range(4):
                await sock_cycle()
            await asyncio.sleep(0.05)
            sock_delta = sys.getrefcount(factory) - base

            base = sys.getrefcount(factory)
            for _ in range(4):
                await host_cycle()
            await asyncio.sleep(0.05)
            host_delta = sys.getrefcount(factory) - base

            assert sock_delta == host_delta, (
                f"sock path leaked a factory reference: sock delta {sock_delta} "
                f"!= host delta {host_delta}"
            )

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_sock_factory_survives_gc() -> None:
    """BUG-309 follow-up: with the owned reference in place, dropping all
    Python references to the factory class while the transport is alive
    must not deallocate it out from under the transport's connection_made
    machinery (previously the borrowed-reference decref freed it)."""
    import gc

    host, port, stop = _start_echo_server()
    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()

            client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client.connect((host, port))

            class LocalProto(asyncio.Protocol):
                def __init__(self) -> None:
                    self.connected = loop.create_future()

                def connection_made(self, transport: asyncio.Transport) -> None:
                    self.transport = transport
                    self.connected.set_result(None)

                def data_received(self, data: bytes) -> None:
                    pass

                def connection_lost(self, exc: BaseException | None) -> None:
                    pass

            transport, _protocol = await loop.create_connection(LocalProto, sock=client)  # type: ignore[arg-type]
            assert _protocol.connected.done()

            # Drop the class reference; the transport machinery must keep
            # whatever it needs alive via its own references.
            del LocalProto
            gc.collect()

            transport.write(b"ping")
            await asyncio.sleep(0.05)
            transport.close()

        talyn.run(main())
    finally:
        stop.set()


def test_create_connection_sock_close_eof_reaches_peer() -> None:
    """BUG-328: transport.close() on a sock= connection must close the
    ADOPTED fd (CPython's _SelectorTransport._call_connection_lost closes
    the wrapped socket). A peer server that waits for EOF must never be
    wedged by a closed-but-still-open socket: this is the dynamic behind
    the 'threaded-echo rapid connect/close hang' - the stale fd kept the
    server's recv loop alive forever, its accept() never ran again, the
    listen backlog filled, and subsequent connects sat in SYN-SENT with
    no connect timeout."""
    import socket as sock_mod
    import threading

    state = {"accepted": 0, "eof": 0}
    listener = sock_mod.socket(sock_mod.AF_INET, sock_mod.SOCK_STREAM)
    listener.setsockopt(sock_mod.SOL_SOCKET, sock_mod.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(5)
    addr = listener.getsockname()
    stop = threading.Event()

    def _server() -> None:
        listener.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = listener.accept()
            except (sock_mod.timeout, OSError):
                # OSError covers the listener being closed during shutdown.
                continue
            state["accepted"] += 1
            try:
                while not stop.is_set():
                    conn.settimeout(0.1)
                    try:
                        data = conn.recv(1024)
                    except sock_mod.timeout:
                        continue
                    except OSError:
                        break  # connection reset - treat as EOF
                    if not data:
                        state["eof"] += 1
                        break
            finally:
                conn.close()

    acceptor = threading.Thread(target=_server, daemon=True)
    acceptor.start()

    try:

        async def main() -> None:
            loop = asyncio.get_running_loop()

            # Sock-path connection: the caller-provided socket is adopted;
            # closing the transport must deliver EOF to the peer without
            # the caller touching the socket again.
            client = sock_mod.socket(sock_mod.AF_INET, sock_mod.SOCK_STREAM)
            client.connect(addr)
            transport, protocol = await loop.create_connection(
                EchoProtocol, sock=client
            )
            transport.close()
            await asyncio.wait_for(protocol.disconnected, timeout=2.0)

            async def wait_eof() -> None:
                for _ in range(100):
                    if state["eof"] >= 1:
                        return
                    await asyncio.sleep(0.02)
                raise AssertionError(
                    "peer never saw EOF after transport close "
                    "(adopted fd was left open - BUG-328)"
                )

            await asyncio.wait_for(wait_eof(), timeout=3.0)

            # The server must not be wedged: a fresh host-path connection
            # must still be accepted and torn down cleanly.
            transport2, protocol2 = await loop.create_connection(
                EchoProtocol, addr[0], addr[1]
            )
            transport2.close()
            await asyncio.wait_for(protocol2.disconnected, timeout=2.0)

        talyn.run(main())
    finally:
        stop.set()
        listener.close()
