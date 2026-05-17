from leviathan import Loop
from leviathan.loop import PseudoSocket, _SSLTransportWrapper

from unittest.mock import MagicMock
from concurrent.futures import ThreadPoolExecutor

import pytest, asyncio, socket, os


def test_pseudo_socket_basic() -> None:
    loop = Loop()
    try:
        ps = PseudoSocket(0, socket.AF_INET, socket.SOCK_STREAM)
        assert ps.fileno() == 0
        assert ps.family == socket.AF_INET
        assert ps.type == socket.SOCK_STREAM
        assert ps.proto == 0

        ps.setblocking(True)
        ps.close()
        assert "PseudoSocket" in repr(ps)
    finally:
        loop.close()


def test_pseudo_socket_getsockname() -> None:
    loop = Loop()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.listen(1)
        fd = s.detach()

        ps = PseudoSocket(fd, socket.AF_INET, socket.SOCK_STREAM)
        name = ps.getsockname()
        assert name[1] == port
        os.close(fd)
    finally:
        loop.close()


def test_pseudo_socket_getpeername() -> None:
    loop = Loop()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.listen(1)
        fd = s.detach()

        ps = PseudoSocket(fd, socket.AF_INET, socket.SOCK_STREAM)
        with pytest.raises(OSError):
            ps.getpeername()
        os.close(fd)
    finally:
        loop.close()


def test_event_loop_policy() -> None:
    from leviathan.loop import EventLoopPolicy
    import asyncio, warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        old_policy = asyncio.get_event_loop_policy()
    try:
        policy = EventLoopPolicy()
        new_loop = policy.new_event_loop()
        try:
            assert isinstance(new_loop, Loop)
        finally:
            new_loop.close()
    finally:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            asyncio.set_event_loop_policy(old_policy)


def test_install() -> None:
    import leviathan
    import asyncio, warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        old_policy = asyncio.get_event_loop_policy()
    try:
        leviathan.install()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            assert isinstance(asyncio.get_event_loop_policy(), leviathan.loop.EventLoopPolicy)
    finally:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            asyncio.set_event_loop_policy(old_policy)


def test_loop_close_with_executor() -> None:
    loop = Loop()
    executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="test")
    loop.set_default_executor(executor)
    loop.close()
    assert executor._shutdown


def test_set_default_executor_typecheck() -> None:
    loop = Loop()
    try:
        with pytest.raises(TypeError, match="executor must be"):
            loop.set_default_executor("not an executor")
    finally:
        loop.close()


def test_set_default_executor() -> None:
    loop = Loop()
    try:
        executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="test")
        loop.set_default_executor(executor)
        assert loop._default_executor is executor
    finally:
        loop.close()
        if not executor._shutdown:
            executor.shutdown(wait=False)


def test_run_in_executor_custom() -> None:
    loop = Loop()
    try:
        def blocking_func(x: int) -> int:
            return x * 2

        executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="test")
        result = loop.run_until_complete(
            loop.run_in_executor(executor, blocking_func, 21)
        )
        assert result == 42
        executor.shutdown(wait=False)
    finally:
        loop.close()


def test_run_in_executor_default_closed() -> None:
    loop = Loop()
    loop.close()
    with pytest.raises((RuntimeError, SystemError)):
        loop.run_until_complete(
            loop.run_in_executor(None, lambda: 42)
        )


def test_exception_handler_default() -> None:
    loop = Loop()
    try:
        ctx = {"message": "test error", "exception": ValueError("test")}
        loop.default_exception_handler(ctx)
    finally:
        loop.close()


def test_exception_handler_custom() -> None:
    loop = Loop()
    try:
        handled = []
        def handler(ctx):
            handled.append(ctx)
            loop.stop()

        loop._exception_handler = handler
        ctx = {"message": "test", "exception": ValueError("x")}
        loop.call_exception_handler(ctx)
        assert len(handled) == 1
        assert handled[0] is ctx
    finally:
        loop.close()


def test_call_exception_handler_with_all_fields() -> None:
    loop = Loop()
    try:
        handled = []
        def handler(ctx):
            handled.append(ctx)

        loop._exception_handler = handler
        loop._call_exception_handler(
            ValueError("x"), message="msg",
            callback=lambda: None,
            socket=socket.socket(),
        )
        assert len(handled) == 1
        ctx = handled[0]
        assert ctx["message"] == "msg"
        assert ctx["callback"] is not None
        ctx["socket"].close()
    finally:
        loop.close()


def test_run_until_complete_not_done() -> None:
    loop = Loop()
    try:
        async def never_complete():
            await asyncio.Event().wait()

        task = asyncio.ensure_future(never_complete(), loop=loop)
        loop.call_soon(loop.stop)
        with pytest.raises(RuntimeError, match="stopped before Future"):
            loop.run_until_complete(task)
    finally:
        loop.close()


def test_run_until_complete_exception() -> None:
    loop = Loop()
    try:
        async def will_raise():
            raise ValueError("boom")

        with pytest.raises(ValueError, match="boom"):
            loop.run_until_complete(will_raise())
    finally:
        loop.close()


def test_connect_accepted_socket() -> None:
    loop = Loop()
    try:
        class Proto(asyncio.Protocol):
            pass

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with pytest.raises((ValueError, OSError, RuntimeError)):
            loop.run_until_complete(
                loop.connect_accepted_socket(Proto, s)
            )
        s.close()
    finally:
        loop.close()


def test_run_until_complete_coro() -> None:
    loop = Loop()
    try:
        async def foo():
            return 1
        assert loop.run_until_complete(foo()) == 1
    finally:
        loop.close()


def test_shutdown_default_executor_noop() -> None:
    loop = Loop()
    try:
        loop.run_until_complete(loop.shutdown_default_executor())
    finally:
        loop.close()


def test_shutdown_default_executor_with_timeout() -> None:
    loop = Loop()
    try:
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="test")
        loop.set_default_executor(executor)

        def slow():
            import time
            time.sleep(0.05)
            return 1

        fut = executor.submit(slow)
        loop.run_until_complete(loop.shutdown_default_executor(timeout=5))
        assert fut.done()
    finally:
        loop.close()


def test_shutdown_default_executor_negative_timeout() -> None:
    loop = Loop()
    try:
        with pytest.raises(ValueError, match="Invalid timeout"):
            loop.run_until_complete(loop.shutdown_default_executor(timeout=-1))
    finally:
        loop.close()


def test_create_connection_with_kwargs() -> None:
    loop = Loop()
    try:
        class Proto(asyncio.Protocol):
            pass

        with pytest.raises((ValueError, TypeError, OSError, RuntimeError)):
            loop.run_until_complete(
                loop.create_connection(Proto, sock=socket.socket())
            )
    finally:
        loop.close()


def test_ssl_transport_wrapper() -> None:
    raw = MagicMock()
    sslmod = MagicMock()
    wrapper = _SSLTransportWrapper(None, raw, sslmod)
    assert wrapper.get_extra_info("test") == raw.get_extra_info.return_value
    assert wrapper.is_closing() == raw.is_closing.return_value
    assert wrapper.can_write_eof() == raw.can_write_eof.return_value
    wrapper.write_eof()
    raw.write_eof.assert_called_once()
    wrapper.abort()
    raw.abort.assert_called_once()
    assert wrapper.get_write_buffer_size() == raw.get_write_buffer_size.return_value


def test_close_twice() -> None:
    loop = Loop()
    loop.close()
    loop.close()


def test_subprocess_exec_cleanup_on_failure() -> None:
    loop = Loop()
    try:
        async def test():
            with pytest.raises((RuntimeError, FileNotFoundError)):
                await loop.subprocess_exec(
                    asyncio.SubprocessProtocol,
                    "/nonexistent/binary"
                )

        loop.run_until_complete(test())
    finally:
        loop.close()


def test_ssl_transport_wrapper_close_with_errors() -> None:
    import ssl
    for exc_type in (ssl.SSLSyscallError, ssl.SSLWantReadError,
                     ssl.SSLWantWriteError, ssl.SSLError):
        raw = MagicMock()
        ssp = MagicMock()
        wrapper = _SSLTransportWrapper(ssp, raw, ssl)
        sslobj = MagicMock()
        sslobj.unwrap.side_effect = exc_type(1, "test")
        ssp._sslobj = sslobj
        wrapper.close()
        raw.close.assert_called_once()


def test_ssl_transport_wrapper_close_success() -> None:
    raw = MagicMock()
    ssp = MagicMock()
    sslmod = MagicMock()
    wrapper = _SSLTransportWrapper(ssp, raw, sslmod)
    sslobj = MagicMock()
    ssp._sslobj = sslobj
    wrapper.close()
    sslobj.unwrap.assert_called_once()
    raw.close.assert_called_once()


def test_ssl_transport_wrapper_write() -> None:
    raw = MagicMock()
    ssp = MagicMock()
    sslmod = MagicMock()
    wrapper = _SSLTransportWrapper(ssp, raw, sslmod)
    sslobj = MagicMock()
    ssp._sslobj = sslobj
    wrapper.write(b"data")
    sslobj.write.assert_called_with(b"data")
    ssp._f.assert_called_once()


def test_default_exception_handler_no_message() -> None:
    loop = Loop()
    try:
        ctx = {"exception": RuntimeError("boom")}
        loop.default_exception_handler(ctx)
    finally:
        loop.close()


def test_call_exception_handler_future_and_task() -> None:
    loop = Loop()
    try:
        handled = []
        def handler(ctx):
            handled.append(ctx)

        loop._exception_handler = handler
        loop._call_exception_handler(
            ValueError("x"),
            future=loop.create_future(),
            task=asyncio.ensure_future(asyncio.sleep(0), loop=loop),
            handle=MagicMock(),
            protocol=MagicMock(),
            transport=MagicMock(),
            asyncgenerator=MagicMock(),
        )
        assert len(handled) == 1
        ctx = handled[0]
        assert "future" in ctx
        assert "task" in ctx
        assert "handle" in ctx
        assert "protocol" in ctx
        assert "transport" in ctx
        assert "asyncgen" in ctx
    finally:
        loop.close()


def test_shutdown_asyncgens() -> None:
    loop = Loop()
    try:
        async def agen():
            try:
                yield 1
                yield 2
            finally:
                pass

        a = agen()
        loop.run_until_complete(a.__anext__())
        loop.run_until_complete(loop.shutdown_asyncgens())
    finally:
        loop.close()


def test_run_until_complete_exception_inside_callback() -> None:
    loop = Loop()
    try:
        async def will_fail():
            raise ValueError("explosion")

        with pytest.raises(ValueError, match="explosion"):
            loop.run_until_complete(will_fail())
    finally:
        loop.close()


def test_run_in_executor_after_shutdown() -> None:
    loop = Loop()
    try:
        loop._default_executor = None
        loop._shutdown_executor_called = True
        with pytest.raises(RuntimeError, match="Default executor shut down"):
            loop.run_in_executor(None, lambda: 42)
    finally:
        loop.close()


def test_do_shutdown_executor_is_none() -> None:
    loop = Loop()
    try:
        loop._default_executor = None
        loop._shutdown_executor_called = True
        with pytest.raises(RuntimeError, match="Default executor is None"):
            loop._do_shutdown(loop.create_future())
    finally:
        loop.close()


def test_shutdown_default_executor_timeout() -> None:
    loop = Loop()
    try:
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="test")
        loop.set_default_executor(executor)

        def very_slow():
            import time
            time.sleep(10)
            return 1

        executor.submit(very_slow)
        loop.run_until_complete(loop.shutdown_default_executor(timeout=0.01))
    finally:
        loop.close()


def test_create_connection_with_all_kwargs() -> None:
    loop = Loop()
    try:
        class Proto(asyncio.Protocol):
            pass

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with pytest.raises((ValueError, TypeError, OSError, RuntimeError)):
            loop.run_until_complete(
                loop.create_connection(
                    Proto, host="127.0.0.1", port=0,
                    family=socket.AF_INET, proto=6,
                    sock=s,
                    local_addr=("127.0.0.1", 0),
                    server_hostname="localhost",
                    happy_eyeballs_delay=0.25,
                    interleave=0,
                    all_errors=True,
                )
            )
        s.close()
    finally:
        loop.close()


@pytest.mark.skipif(not hasattr(os, 'fork'), reason="fork not available")
def test_subprocess_exec_cleanup_finally() -> None:
    loop = Loop()
    try:
        async def test():
            with pytest.raises((RuntimeError, OSError)):
                await loop.subprocess_exec(
                    asyncio.SubprocessProtocol,
                    "/nonexistent/binary_xyz"
                )

        loop.run_until_complete(test())
    finally:
        loop.close()


def test_create_unix_connection_no_ssl() -> None:
    import tempfile
    loop = Loop()
    try:
        sock_path = tempfile.mktemp(suffix=".sock")

        class Proto(asyncio.Protocol):
            def connection_made(self, transport):
                pass

        async def client():
            with pytest.raises((ConnectionRefusedError, FileNotFoundError, OSError)):
                await loop.create_unix_connection(Proto, sock_path)

        loop.run_until_complete(client())
        if os.path.exists(sock_path):
            os.unlink(sock_path)
    finally:
        loop.close()


def test_create_unix_server_no_ssl() -> None:
    import tempfile
    loop = Loop()
    try:
        sock_path = tempfile.mktemp(suffix=".sock")

        class Proto(asyncio.Protocol):
            def connection_made(self, transport):
                pass

        async def server():
            srv = await loop.create_unix_server(Proto, sock_path)
            try:
                assert srv is not None
            finally:
                srv.close()
                await srv.wait_closed()

        loop.run_until_complete(server())
        if os.path.exists(sock_path):
            os.unlink(sock_path)
    finally:
        loop.close()


def test_default_exception_handler_with_extra_keys() -> None:
    loop = Loop()
    try:
        ctx = {
            "exception": RuntimeError("boom"),
            "extra_info": "some_value",
        }
        loop.default_exception_handler(ctx)
    finally:
        loop.close()


def test_shutdown_asyncgens_error() -> None:
    import warnings
    loop = Loop()
    try:
        async def bad_agen():
            try:
                yield 1
            finally:
                raise ValueError("agen close error")

        a = bad_agen()
        loop.run_until_complete(a.__anext__())
        loop.run_until_complete(loop.shutdown_asyncgens())
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            try:
                loop.run_until_complete(a.aclose())
            except ValueError:
                pass
    finally:
        loop.close()


def test_run_until_complete_keyboard_interrupt() -> None:
    loop = Loop()
    try:
        async def will_never_stop():
            await asyncio.Event().wait()

        def raise_interrupt():
            raise KeyboardInterrupt()

        loop.call_soon(raise_interrupt)
        with pytest.raises(KeyboardInterrupt):
            loop.run_until_complete(will_never_stop())
    finally:
        loop.close()


def test_loop_close_handles_cancelled_throw() -> None:
    """loop.close() handles execute_task_throw with cancelled=true.

    When a task has exception set and execute_task_throw is dispatched
    to the ready queue, but the loop stops before it runs,
    release_ring_buffer replays the callback with cancelled=true.
    The handler must set the future's exception from the task's stored
    exception without trying to throw into the coroutine on a
    torn-down loop.
    """
    loop = Loop()
    try:
        async def await_future():
            await loop.create_future()

        task = loop.create_task(await_future())
        task.cancel()
        loop.call_later(0.0, loop.stop)
        try:
            loop.run_until_complete(task)
        except (RuntimeError, asyncio.CancelledError):
            pass
    finally:
        loop.close()


def test_do_shutdown_exception() -> None:
    loop = Loop()
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="test")
    try:
        real_shutdown = executor.shutdown
        def failing_shutdown(wait=True):
            real_shutdown(wait=False)
            raise RuntimeError("shutdown failed")
        executor.shutdown = failing_shutdown
        loop.set_default_executor(executor)

        def slow():
            import time
            time.sleep(0.05)
            return 1

        executor.submit(slow)
        with pytest.raises(RuntimeError, match="shutdown failed"):
            loop.run_until_complete(loop.shutdown_default_executor(timeout=5))
    finally:
        executor.shutdown = real_shutdown
        loop._default_executor = None
        loop.close()


def test_create_connection_with_ssl_timeout_kwargs() -> None:
    loop = Loop()
    try:
        class Proto(asyncio.Protocol):
            pass

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with pytest.raises((ValueError, TypeError, OSError, RuntimeError)):
            loop.run_until_complete(
                loop.create_connection(
                    Proto, sock=s,
                    ssl_handshake_timeout=10,
                    ssl_shutdown_timeout=10,
                )
            )
        s.close()
    finally:
        loop.close()


@pytest.mark.filterwarnings("ignore::pytest.PytestUnraisableExceptionWarning")
def test_ssl_server_and_connection() -> None:
    import ssl as sslmod
    CERT = "/tmp/test_cert.pem"
    KEY = "/tmp/test_key.pem"
    if not os.path.exists(CERT):
        pytest.skip("test cert not found")

    loop = Loop()
    try:
        ssl_ctx = sslmod.create_default_context(sslmod.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(CERT, KEY)

        client_ctx = sslmod.create_default_context(sslmod.Purpose.SERVER_AUTH)
        client_ctx.load_verify_locations(CERT)
        client_ctx.check_hostname = False

        server_data = []
        class ServerProto(asyncio.Protocol):
            def connection_made(self, transport):
                self.transport = transport
            def data_received(self, data):
                server_data.append(data)
                self.transport.write(data.upper())

        client_data = []
        class ClientProto(asyncio.Protocol):
            def connection_made(self, transport):
                self.transport = transport
            def data_received(self, data):
                client_data.append(data)

        async def run_test():
            srv = await loop.create_server(
                ServerProto, "127.0.0.1", 0, ssl=ssl_ctx,
            )
            server_sock = srv.sockets[0]
            addr = server_sock.getsockname()

            transport, proto = await loop.create_connection(
                ClientProto, "127.0.0.1", addr[1], ssl=client_ctx,
            )
            proto.transport.write(b"hello")
            await asyncio.sleep(0.2)
            assert b"HELLO" in b"".join(client_data), f"got {client_data}"

            proto.transport.close()
            srv.close()
            await srv.wait_closed()

        loop.run_until_complete(run_test())
    finally:
        loop.close()


@pytest.mark.filterwarnings("ignore::pytest.PytestUnraisableExceptionWarning")
def test_ssl_handshake_failure() -> None:
    import ssl as sslmod
    CERT = "/tmp/test_cert.pem"
    KEY = "/tmp/test_key.pem"
    if not os.path.exists(CERT):
        pytest.skip("test cert not found")

    loop = Loop()
    try:
        ssl_ctx = sslmod.create_default_context(sslmod.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(CERT, KEY)

        client_ctx = sslmod.create_default_context(sslmod.Purpose.SERVER_AUTH)
        client_ctx.verify_mode = sslmod.CERT_REQUIRED

        class Proto(asyncio.Protocol):
            pass

        async def run_test():
            srv = await loop.create_server(
                Proto, "127.0.0.1", 0, ssl=ssl_ctx,
            )
            server_sock = srv.sockets[0]
            addr = server_sock.getsockname()

            with pytest.raises((sslmod.SSLError, ConnectionError, OSError)):
                await loop.create_connection(
                    Proto, "127.0.0.1", addr[1], ssl=client_ctx,
                )

            srv.close()
            await srv.wait_closed()

        loop.run_until_complete(run_test())
    finally:
        loop.close()


def test_ssl_server_and_connection_unix() -> None:
    import ssl as sslmod
    import tempfile
    CERT = "/tmp/test_cert.pem"
    KEY = "/tmp/test_key.pem"
    if not os.path.exists(CERT):
        pytest.skip("test cert not found")

    loop = Loop()
    try:
        ssl_ctx = sslmod.create_default_context(sslmod.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(CERT, KEY)

        client_ctx = sslmod.create_default_context(sslmod.Purpose.SERVER_AUTH)
        client_ctx.load_verify_locations(CERT)
        client_ctx.check_hostname = False

        sock_path = tempfile.mktemp(suffix=".sock")
        server_data = []
        class ServerProto(asyncio.Protocol):
            def connection_made(self, transport):
                self.transport = transport
            def data_received(self, data):
                server_data.append(data)

        async def run_test():
            srv = await loop.create_unix_server(
                ServerProto, sock_path, ssl=ssl_ctx,
            )
            class ClientProto(asyncio.Protocol):
                def connection_made(self, transport):
                    self.transport = transport
                def data_received(self, data):
                    pass

            transport, proto = await loop.create_unix_connection(
                ClientProto, sock_path, ssl=client_ctx,
            )
            proto.transport.write(b"hello")
            await asyncio.sleep(0.2)
            assert b"hello" in b"".join(server_data), f"got {server_data}"

            proto.transport.close()
            srv.close()
            await srv.wait_closed()

        loop.run_until_complete(run_test())
        if os.path.exists(sock_path):
            os.unlink(sock_path)
    finally:
        loop.close()
