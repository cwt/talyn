import _ctypes
import asyncio
import ctypes
import socket
import struct
import threading
from concurrent.futures import ThreadPoolExecutor
from logging import getLogger
from typing import Any, AsyncGenerator, Awaitable, Callable, NotRequired, TypedDict

from .server import Server
from .talyn_zig import Loop as _Loop

logger = getLogger(__package__)

# Keep Popen objects alive to prevent __del__ from reaping processes before our exit watcher
_subprocess_popens: dict[int, Any] = {}


class _SSLTransportWrapper:
    """Wraps a raw transport to encrypt writes through an SSL object."""

    _start_tls_compatible = True

    def __init__(
        self, ssp, raw_transport, ssl_module, shutdown_timeout=None, loop=None
    ):
        self._ssp = ssp
        self._raw_t = raw_transport
        self._sslmod = ssl_module
        self._ssl_shutdown_timeout = shutdown_timeout
        self._closing = False
        self._shutdown_timeout_handle = None
        self._loop = loop

    def write(self, data):
        # BUG-54: Handle SSLWantWriteError (renegotiation), SSLWantReadError
        # (need to read more before writing), and SSLError (fatal). The
        # previous code let these exceptions propagate uncaught, crashing
        # the protocol. The stdlib's asyncio.sslproto.SSL_Protocol._write_want_write
        # sets _read_wants_read / _write_wants_write flags and re-arms the
        # appropriate waiter. We mirror that here: on WantRead or WantWrite,
        # mark the state and let the transport's pause/resume handle re-arming.
        try:
            self._ssp._sslobj.write(data)
        except self._sslmod.SSLWantReadError:
            # Need to read more data from the peer before we can write.
            # Set the flag so the read side knows to re-arm.
            self._ssp._write_wants_read = True
        except self._sslmod.SSLWantWriteError:
            # Need to wait for the write side to drain before writing.
            # Set the flag so the write side knows to re-arm.
            self._ssp._write_wants_write = True
        except (self._sslmod.SSLError, self._sslmod.SSLSyscallError) as exc:
            # Fatal SSL error — close the transport.
            self._ssp._f()
            if self._loop is not None and not self._loop.is_closed():
                self._loop.call_soon(self._fatal_error, exc)
            return
        self._ssp._f()

    def _fatal_error(self, exc):
        # Called via call_soon to break out of the current write context
        # before re-raising the SSL error to the protocol.
        raise exc

    def close(self):
        if self._closing:
            return
        self._closing = True
        self._start_shutdown()

    def _start_shutdown(self):
        try:
            self._ssp._sslobj.unwrap()
        except self._sslmod.SSLWantReadError:
            self._ssp._f()
            if (
                self._shutdown_timeout_handle is None
                and self._loop is not None
                and not self._loop.is_closed()
            ):
                timeout = self._ssl_shutdown_timeout or 30.0
                self._shutdown_timeout_handle = self._loop.call_later(
                    timeout, self._force_close
                )
                return
            self._force_close()
            return
        except self._sslmod.SSLWantWriteError:
            self._ssp._f()
            if (
                self._shutdown_timeout_handle is None
                and self._loop is not None
                and not self._loop.is_closed()
            ):
                timeout = self._ssl_shutdown_timeout or 30.0
                self._shutdown_timeout_handle = self._loop.call_later(
                    timeout, self._force_close
                )
                return
            self._force_close()
            return
        except Exception:
            logger.exception("Unhandled exception in event loop callback")

        self._ssp._f()
        self._force_close()

    def _force_close(self):
        if self._shutdown_timeout_handle is not None:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None
        self._raw_t.close()

    def get_extra_info(self, name, default=None):
        match name:
            case "sslcontext":
                return self._ssp._sslobj.context
            case "ssl_object":
                return self._ssp._sslobj
            case _:
                return self._raw_t.get_extra_info(name, default)

    def is_closing(self):
        return self._raw_t.is_closing()

    def can_write_eof(self):
        return self._raw_t.can_write_eof()

    def write_eof(self):
        self._raw_t.write_eof()

    def abort(self):
        self._raw_t.abort()

    def get_write_buffer_size(self):
        return self._raw_t.get_write_buffer_size()

    def get_write_buffer_limits(self):
        return self._raw_t.get_write_buffer_limits()

    def set_write_buffer_limits(self, high=None, low=None):
        self._raw_t.set_write_buffer_limits(high, low)

    def pause_reading(self):
        self._raw_t.pause_reading()

    def resume_reading(self):
        self._raw_t.resume_reading()

    def is_reading(self):
        return self._raw_t.is_reading()

    def set_protocol(self, protocol):
        self._raw_t.set_protocol(protocol)


class ExceptionContext(TypedDict):
    message: NotRequired[str]
    exception: Exception
    callback: NotRequired[object]
    future: NotRequired[asyncio.Future[Any]]
    task: NotRequired[asyncio.Task[Any]]
    handle: NotRequired[asyncio.Handle]
    protocol: NotRequired[asyncio.BaseProtocol]
    transport: NotRequired[asyncio.BaseTransport]
    socket: NotRequired[socket.socket]
    asyncgen: NotRequired[AsyncGenerator[Any]]


class Loop(_Loop):
    def __init__(self, ready_tasks_queue_capacity: int = 1048576) -> None:
        self._asyncio_tasks: set[asyncio.Task[Any]] = set()
        _Loop.__init__(self, ready_tasks_queue_capacity, self.call_exception_handler)

        self._exception_handler: Callable[[ExceptionContext], None] = (
            self.default_exception_handler
        )

        self._default_executor: ThreadPoolExecutor | None = None
        self._shutdown_executor_called: bool = False

    def close(self) -> None:
        if self._default_executor is not None:
            self._default_executor.shutdown(wait=False)
            self._default_executor = None
            self._shutdown_executor_called = True
        _Loop.close(self)

    def _call_exception_handler(
        self,
        exception: Exception,
        *,
        message: str | None = None,
        callback: object | None = None,
        future: asyncio.Future[Any] | None = None,
        task: asyncio.Task[Any] | None = None,
        handle: asyncio.Handle | None = None,
        protocol: asyncio.BaseProtocol | None = None,
        transport: asyncio.BaseTransport | None = None,
        socket: socket.socket | None = None,
        asyncgenerator: AsyncGenerator[Any] | None = None,
    ) -> None:
        context: ExceptionContext = {"exception": exception}
        if message is not None:
            context["message"] = message
        if callback is not None:
            context["callback"] = callback
        if future is not None:
            context["future"] = future
        if task is not None:
            context["task"] = task
        if handle is not None:
            context["handle"] = handle
        if protocol is not None:
            context["protocol"] = protocol
        if transport is not None:
            context["transport"] = transport
        if socket is not None:
            context["socket"] = socket
        if asyncgenerator is not None:
            context["asyncgen"] = asyncgenerator

        self._exception_handler(context)

    def default_exception_handler(self, context: ExceptionContext) -> None:  # type: ignore
        message = context.get("message")
        if not message:
            message = "Unhandled exception in event loop"

        log_lines = [message]
        for key, value in context.items():
            if key in {"message", "exception"}:
                continue
            log_lines.append(f"{key}: {value!r}")

        exception = context.get("exception")
        logger.error("\n".join(log_lines), exc_info=exception)

    def call_exception_handler(self, context: ExceptionContext) -> None:  # type: ignore
        if self._exception_handler == self.default_exception_handler:
            self.default_exception_handler(context)
        else:
            try:
                self._exception_handler(self, context)
            except TypeError as e:
                # Support both handler(loop, context) and handler(context) signatures
                if "positional argument" in str(e) or "takes 1" in str(e):
                    try:
                        self._exception_handler(context)
                    except Exception:
                        self.default_exception_handler(context)
                else:
                    self.default_exception_handler(context)
            except Exception:
                # Fallback or log if custom handler fails
                self.default_exception_handler(context)

    def set_exception_handler(
        self, handler: Callable[[Any, ExceptionContext], None] | None
    ) -> None:
        if handler is None:
            self._exception_handler = self.default_exception_handler
        else:
            self._exception_handler = handler

    # --------------------------------------------------------------------------------------------------------
    # P15 Phase 1: Completion batch dispatch infrastructure.
    # Called from Zig after poll_blocking_events to dispatch IO completions
    # in a tight Python loop. Currently unused (batch always empty) —
    # infrastructure in place for future optimization.
    # --------------------------------------------------------------------------------------------------------

    def _dispatch_completions(self, records_ptr: int, count: int) -> None:
        """Dispatch IO completions from Zig's batch buffer.

        Args:
            records_ptr: Pointer to array of CompletionRecord (32 bytes each).
            count: Number of records in the batch.
        """
        if count == 0:
            return

        # CompletionRecord layout (extern struct, 32 bytes):
        #   op: u8          (offset 0)
        #   transport: ptr  (offset 8)
        #   data: ptr       (offset 16)
        #   nbytes: i64     (offset 24)
        record_size = 32
        for i in range(count):
            offset = i * record_size
            raw = ctypes.string_at(records_ptr + offset, record_size)
            op = raw[0]
            transport_ptr = struct.unpack_from("Q", raw, 8)[0]
            data_ptr = struct.unpack_from("Q", raw, 16)[0]
            nbytes = struct.unpack_from("q", raw, 24)[0]

            match op:
                case 0:  # DataReceived
                    self._dispatch_data_received(transport_ptr, data_ptr, nbytes)
                case 1:  # EofReceived
                    self._dispatch_eof_received(transport_ptr)
                case 2:  # BufferUpdated
                    self._dispatch_buffer_updated(transport_ptr, nbytes)
                case 3:  # ConnectionLost
                    self._dispatch_connection_lost(transport_ptr, data_ptr)

    def _test_batch_dispatch(self, count: int) -> None:
        """Test: just receive count, do nothing."""
        pass

    def _dispatch_completions_with_list(self, records: list) -> None:
        """Dispatch IO completions from a list of (op, protocol_ptr, data, nbytes) tuples.

        protocol_ptr is a raw pointer to the protocol object.
        """
        for op, protocol_ptr, data, nbytes in records:
            if protocol_ptr is None:
                continue
            protocol = _ctypes.PyObj_FromPtr(protocol_ptr)
            match op:
                case 0:  # DataReceived
                    self._dispatch_data_received(protocol, data, nbytes)
                case 1:  # EofReceived
                    self._dispatch_eof_received(protocol)
                case 2:  # BufferUpdated
                    self._dispatch_buffer_updated(protocol, nbytes)
                case 3:  # ConnectionLost
                    self._dispatch_connection_lost(protocol, data)

    def _dispatch_data_received(self, protocol, data, nbytes: int) -> None:
        """Call protocol.data_received."""
        try:
            protocol.data_received(data)
        except Exception:
            self.call_exception_handler(
                {
                    "message": "Exception in data_received callback",
                    "exception": Exception("data_received failed"),
                    "protocol": protocol,
                }
            )

    def _dispatch_eof_received(self, protocol) -> None:
        """Call protocol.eof_received."""
        try:
            protocol.eof_received()
        except Exception:
            self.call_exception_handler(
                {
                    "message": "Exception in eof_received callback",
                    "exception": Exception("eof_received failed"),
                    "protocol": protocol,
                }
            )

    def _dispatch_buffer_updated(self, protocol, nbytes: int) -> None:
        """Call protocol.buffer_updated on a BufferedProtocol."""
        try:
            protocol.buffer_updated(nbytes)
        except Exception:
            self.call_exception_handler(
                {
                    "message": "Exception in buffer_updated callback",
                    "exception": Exception("buffer_updated failed"),
                    "protocol": protocol,
                }
            )

    def _dispatch_connection_lost(self, protocol, exc) -> None:
        """Call protocol.connection_lost on a transport."""
        try:
            protocol.connection_lost(exc)
        except Exception:
            self.call_exception_handler(
                {
                    "message": "Exception in connection_lost callback",
                    "exception": Exception("connection_lost failed"),
                    "protocol": protocol,
                }
            )

    # --------------------------------------------------------------------------------------------------------

    async def shutdown_asyncgens(self) -> None:
        asyncgens = self._asyncgens
        closing_agens = list(asyncgens)
        asyncgens.clear()

        results = await asyncio.gather(
            *[agen.aclose() for agen in closing_agens], return_exceptions=True
        )

        for result, agen in zip(results, closing_agens, strict=True):
            if isinstance(result, Exception):
                self._exception_handler(
                    {
                        "message": f"an error occurred during closing of "
                        f"asynchronous generator {agen!r}",
                        "exception": result,
                        "asyncgen": agen,
                    }
                )

    def __run_until_complete_cb(self, future: asyncio.Future[Any]) -> None:
        loop = future.get_loop()
        loop.stop()

    def run_until_complete[T](self, future: Awaitable[T]) -> T:
        if self.is_closed() or self.is_running():
            raise RuntimeError("Event loop is closed or already running")

        new_task = not asyncio.isfuture(future)
        new_future = asyncio.ensure_future(future, loop=self)
        new_future.add_done_callback(self.__run_until_complete_cb)
        try:
            self.run_forever()
        except BaseException:
            if new_task and new_future.done() and not new_future.cancelled():
                new_future.exception()
            raise
        finally:
            new_future.remove_done_callback(self.__run_until_complete_cb)

        if not new_future.done():
            raise RuntimeError("Event loop stopped before Future completed.")

        return new_future.result()

    def run_in_executor[T, *Ts](
        self, executor: Any, func: Callable[[*Ts], T], *args: *Ts
    ) -> asyncio.Future[T]:
        if self.is_closed():
            raise RuntimeError("Event loop is closed")
        if executor is None and (executor := self._default_executor) is None:
            if self._shutdown_executor_called:
                raise RuntimeError("Default executor shut down")

            executor = ThreadPoolExecutor(thread_name_prefix="talyn")
            self._default_executor = executor

        concurrent_future = executor.submit(func, *args)
        return asyncio.wrap_future(concurrent_future, loop=self)  # type: ignore

    def set_default_executor(self, executor: Any) -> None:
        if not isinstance(executor, ThreadPoolExecutor):
            raise TypeError("executor must be ThreadPoolExecutor")

        self._default_executor = executor

    def _do_shutdown(self, future: asyncio.Future[None], executor: Any = None) -> None:
        is_closed: Callable[[], bool] = self.is_closed  # type: ignore
        call_soon_threadsafe: Callable[..., asyncio.Handle] = self.call_soon_threadsafe  # type: ignore

        if executor is None:
            executor = self._default_executor

        if executor is None:
            raise RuntimeError("Default executor is None")

        try:
            executor.shutdown(wait=True)
            if not is_closed():
                call_soon_threadsafe(
                    asyncio.futures._set_result_unless_cancelled,  # type: ignore
                    future,
                    None,
                )
        except Exception as ex:
            if not is_closed() and not future.cancelled():
                call_soon_threadsafe(future.set_exception, ex)

    async def shutdown_default_executor(self, timeout: float | None = None) -> None:
        if timeout is not None and timeout < 0:
            raise ValueError("Invalid timeout")

        self._shutdown_executor_called = True
        executor = self._default_executor
        if executor is None:
            return

        self._default_executor = None

        future: asyncio.Future[None] = self.create_future()  # type: ignore
        thread = threading.Thread(
            target=self._do_shutdown, args=(future, executor), daemon=True
        )
        thread.start()
        try:
            async with asyncio.timeouts.timeout(timeout):
                await future
        except asyncio.TimeoutError:
            # BUG-55: Don't leak the daemon thread. Best-effort
            # join with the same timeout; if it doesn't return,
            # the thread is daemon so it will be cleaned up on
            # process exit, but at least we tried.
            thread.join(timeout)
        else:
            thread.join()

    async def create_connection(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str | None = None,
        port: int | None = None,
        *,
        ssl: Any = None,
        family: int = 0,
        proto: int = 0,
        flags: int = 0,
        sock: Any = None,
        local_addr: tuple[str, int] | None = None,
        server_hostname: str | None = None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
        happy_eyeballs_delay: float | None = None,
        interleave: int | None = None,
        all_errors: bool = False,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        if ssl is not None:
            return await self._create_ssl_connection(
                protocol_factory,
                host,
                port,
                ssl=ssl,
                family=family,
                proto=proto,
                flags=flags,
                sock=sock,
                local_addr=local_addr,
                server_hostname=server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
                happy_eyeballs_delay=happy_eyeballs_delay,
                interleave=interleave,
                all_errors=all_errors,
            )
        # Only pass non-None/non-default kwargs
        kwargs = {}
        if family:
            kwargs["family"] = family
        if proto:
            kwargs["proto"] = proto
        if sock is not None:
            kwargs["sock"] = sock
        if local_addr is not None:
            kwargs["local_addr"] = local_addr
        if server_hostname is not None:
            kwargs["server_hostname"] = server_hostname
        if ssl_handshake_timeout is not None:
            kwargs["ssl_handshake_timeout"] = ssl_handshake_timeout
        if ssl_shutdown_timeout is not None:
            kwargs["ssl_shutdown_timeout"] = ssl_shutdown_timeout
        if happy_eyeballs_delay is not None:
            kwargs["happy_eyeballs_delay"] = happy_eyeballs_delay
        if interleave is not None:
            kwargs["interleave"] = interleave
        if all_errors:
            kwargs["all_errors"] = all_errors

        return await _Loop.create_connection(
            self,
            protocol_factory,
            *((host, port) if host is not None and port is not None else ()),
            **kwargs,
        )

    async def start_tls(
        self,
        transport,
        protocol,
        sslcontext,
        *,
        server_side=False,
        server_hostname=None,
        ssl_handshake_timeout=None,
        ssl_shutdown_timeout=None,
    ):
        self_loop = self
        import ssl as ssl_module

        if not isinstance(sslcontext, ssl_module.SSLContext):
            raise TypeError(
                f"sslcontext is expected to be an instance of ssl.SSLContext, "
                f"got {sslcontext!r}"
            )

        incoming = ssl_module.MemoryBIO()
        outgoing = ssl_module.MemoryBIO()
        sslobj_temp = sslcontext.wrap_bio(
            incoming,
            outgoing,
            server_side=server_side,
            server_hostname=server_hostname,
        )

        waiter = self.create_future()
        wrapper_holder = [None]

        class _SP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                self._sslobj = sslobj_temp
                self._incoming = incoming
                self._outgoing = outgoing
                self._ap = protocol
                self._running = True
                self._raw_t = None

            def get_buffer(self, n):
                return self._view[:n]

            def buffer_updated(self, n):
                try:
                    self._incoming.write(self._buf[:n])
                    if hasattr(self, "_wrapper") and self._wrapper._closing:
                        self._wrapper._start_shutdown()
                    elif not self._hs:
                        self._h()
                    else:
                        self._r()
                except Exception:
                    self._running = False
                    self._raw_t.close()

            def connection_made(self, t):
                self._raw_t = t
                self._wrapper = _SSLTransportWrapper(
                    self,
                    t,
                    ssl_module,
                    shutdown_timeout=ssl_shutdown_timeout,
                    loop=self_loop,
                )
                wrapper_holder[0] = self._wrapper
                self._h()

            def connection_lost(self, e):
                self._running = False
                try:
                    self._ap.connection_lost(e)
                except Exception:
                    logger.exception("Unhandled exception in event loop callback")
                if not waiter.done():
                    waiter.set_exception(e or ConnectionResetError())

            def eof_received(self):
                try:
                    return self._ap.eof_received()
                except Exception:
                    return False

            def pause_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "pause_writing"):
                    try:
                        self._ap.pause_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def resume_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "resume_writing"):
                    try:
                        self._ap.resume_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception as exc:
                    self._running = False
                    if not waiter.done():
                        waiter.set_exception(exc)
                    self._raw_t.close()
                else:
                    self._hs = True
                    if not waiter.done():
                        waiter.set_result(None)
                    self._f()

            def _r(self):
                chunks = []
                while self._running:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    chunks.append(d)
                if chunks:
                    try:
                        self._ap.data_received(b"".join(chunks))
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def _f(self):
                d = self._outgoing.read()
                if d and self._raw_t is not None:
                    self._raw_t.write(d)

        ssl_protocol = _SP()

        from asyncio.streams import StreamReaderProtocol

        if isinstance(protocol, StreamReaderProtocol):
            stream_reader = getattr(protocol, "_stream_reader", None)
            if stream_reader is not None:
                buffer = stream_reader._buffer
                if buffer:
                    incoming.write(buffer)
                    buffer.clear()

        # BUG-56: Drain any data already in the raw transport's
        # read buffer before switching protocols. Without this,
        # data that's already been read from the socket but not
        # yet delivered to the application could be:
        # 1. Delivered to the OLD (cleartext) protocol, leaking
        #    it to the application before TLS is established.
        # 2. Lost entirely if pause_reading() doesn't synchronously
        #    stop the data flow.
        # We drain via the raw transport's internal buffer (if
        # accessible) and feed it into the SSL handshake via
        # the incoming MemoryBIO.
        raw_buffer = getattr(transport, "_buffer", None) or getattr(
            transport, "buffer", None
        )
        if raw_buffer and len(raw_buffer) > 0:
            try:
                data = bytes(raw_buffer)
                raw_buffer.clear()
                incoming.write(data)
            except Exception:
                logger.exception("Unhandled exception in event loop callback")

        transport.pause_reading()
        transport.set_protocol(ssl_protocol)
        self.call_soon(ssl_protocol.connection_made, transport)
        self.call_soon(transport.resume_reading)

        try:
            await asyncio.wait_for(waiter, timeout=ssl_handshake_timeout or 60)
        except BaseException:
            transport.close()
            raise

        return wrapper_holder[0] or transport

    async def _create_ssl_connection(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str | None,
        port: int | None,
        *,
        ssl: Any,
        family: int,
        proto: int,
        flags: int,
        sock: Any,
        local_addr: Any,
        server_hostname: str | None,
        ssl_handshake_timeout: float | None,
        ssl_shutdown_timeout: float | None,
        happy_eyeballs_delay: float | None,
        interleave: int | None,
        all_errors: bool,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        self_loop = self
        import ssl as ssl_module

        sslcontext = ssl
        sni = server_hostname or host

        if sslcontext is True:
            sslcontext = ssl_module.create_default_context()
            if host:
                sslcontext.check_hostname = True
                sslcontext.verify_mode = ssl_module.CERT_REQUIRED

        incoming = ssl_module.MemoryBIO()
        outgoing = ssl_module.MemoryBIO()
        sslobj = sslcontext.wrap_bio(
            incoming,
            outgoing,
            server_side=False,
            server_hostname=sni,
        )

        waiter = self.create_future()
        app_protocol = protocol_factory()
        wrapper_holder: list[Any] = [None]

        class SP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                self._sslobj = sslobj
                self._incoming = incoming
                self._outgoing = outgoing
                self._ap = app_protocol

            def get_buffer(self, n):
                return self._view[:n]

            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if hasattr(self, "_wrapper") and self._wrapper._closing:
                    self._wrapper._start_shutdown()
                elif not self._hs:
                    self._h()
                else:
                    self._r()

            def connection_made(self, t):
                self._raw_t = t
                self._wrapper = _SSLTransportWrapper(
                    self,
                    t,
                    ssl_module,
                    shutdown_timeout=ssl_shutdown_timeout,
                    loop=self_loop,
                )
                wrapper_holder[0] = self._wrapper
                self._h()

            def connection_lost(self, e):
                try:
                    self._ap.connection_lost(e)
                except Exception:
                    logger.exception("Unhandled exception in event loop callback")

            def eof_received(self):
                try:
                    return self._ap.eof_received()
                except Exception:
                    return False

            def pause_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "pause_writing"):
                    try:
                        self._ap.pause_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def resume_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "resume_writing"):
                    try:
                        self._ap.resume_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception as exc:
                    if not waiter.done():
                        waiter.set_exception(exc)
                else:
                    self._hs = True
                    if not waiter.done():
                        waiter.set_result(None)
                    self._f()
                    app_protocol.connection_made(self._wrapper)

            def _r(self):
                chunks = []
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    chunks.append(d)
                if chunks:
                    app_protocol.data_received(b"".join(chunks))

            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        kwargs: dict[str, Any] = {}
        if family:
            kwargs["family"] = family
        if proto:
            kwargs["proto"] = proto
        if flags:
            kwargs["flags"] = flags
        if sock is not None:
            kwargs["sock"] = sock
        if local_addr is not None:
            kwargs["local_addr"] = local_addr
        if happy_eyeballs_delay is not None:
            kwargs["happy_eyeballs_delay"] = happy_eyeballs_delay
        if interleave is not None:
            kwargs["interleave"] = interleave
        if all_errors:
            kwargs["all_errors"] = all_errors

        transport, _ = await _Loop.create_connection(
            self,
            SP,
            host,
            port,
            **kwargs,
        )

        try:
            await asyncio.wait_for(waiter, timeout=ssl_handshake_timeout or 60)
        except BaseException:
            transport.close()
            raise

        return wrapper_holder[0] or transport, app_protocol

    async def create_server(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str | None = None,
        port: int | None = None,
        *,
        family: int = 0,
        flags: int = 0,
        sock: Any = None,
        backlog: int = 100,
        ssl: Any = None,
        reuse_address: bool | None = None,
        reuse_port: bool | None = None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
        start_serving: bool = True,
    ) -> "Server":
        if ssl is not None:
            return await self._create_ssl_server(
                protocol_factory,
                host,
                port,
                family=family,
                flags=flags,
                sock=sock,
                backlog=backlog,
                ssl=ssl,
                reuse_address=reuse_address,
                reuse_port=reuse_port,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
                start_serving=start_serving,
            )
        if host is None:
            host = ""
        kwargs = {}
        if family:
            kwargs["family"] = family
        if flags:
            kwargs["flags"] = flags
        if sock is not None:
            kwargs["sock"] = sock
        if reuse_address is not None:
            kwargs["reuse_address"] = reuse_address
        if reuse_port is not None:
            kwargs["reuse_port"] = reuse_port
        srvs = await _Loop.create_server(
            self,
            protocol_factory,
            host,
            port,
            backlog=backlog,
            **kwargs,
        )
        return Server(self, srvs)

    async def _create_ssl_server(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        host: str | None,
        port: int | None,
        *,
        family: int,
        flags: int,
        sock: Any,
        backlog: int,
        ssl: Any,
        reuse_address: bool | None,
        reuse_port: bool | None,
        ssl_handshake_timeout: float | None,
        ssl_shutdown_timeout: float | None,
        start_serving: bool,
    ) -> "Server":
        self_loop = self
        import ssl as ssl_module

        sslcontext = ssl

        class SSP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                incoming = ssl_module.MemoryBIO()
                outgoing = ssl_module.MemoryBIO()
                self._sslobj = sslcontext.wrap_bio(
                    incoming,
                    outgoing,
                    server_side=True,
                )
                self._incoming = incoming
                self._outgoing = outgoing

            def get_buffer(self, n):
                return self._view[:n]

            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if hasattr(self, "_wrapper") and self._wrapper._closing:
                    self._wrapper._start_shutdown()
                elif not self._hs:
                    self._h()
                else:
                    self._r()

            def connection_made(self, t):
                self._raw_t = t
                self._ap = protocol_factory()
                self._wrapper = _SSLTransportWrapper(
                    self,
                    self._raw_t,
                    ssl_module,
                    shutdown_timeout=ssl_shutdown_timeout,
                    loop=self_loop,
                )
                self._h()

            def connection_lost(self, e):
                self._ap.connection_lost(e)

            def eof_received(self):
                self._ap.eof_received()
                return False

            def pause_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "pause_writing"):
                    try:
                        self._ap.pause_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def resume_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "resume_writing"):
                    try:
                        self._ap.resume_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception:
                    self._raw_t.close()
                else:
                    self._hs = True
                    self._f()
                    self._ap.connection_made(self._wrapper)

            def _r(self):
                chunks = []
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    chunks.append(d)
                if chunks:
                    self._ap.data_received(b"".join(chunks))

            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        kwargs = {}
        if family:
            kwargs["family"] = family
        if flags:
            kwargs["flags"] = flags
        if sock is not None:
            kwargs["sock"] = sock
        if reuse_address is not None:
            kwargs["reuse_address"] = reuse_address
        if reuse_port is not None:
            kwargs["reuse_port"] = reuse_port
        srvs = await _Loop.create_server(
            self,
            SSP,
            host,
            port,
            backlog=backlog,
            **kwargs,
        )
        return Server(self, srvs)

    async def connect_accepted_socket(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        sock: Any,
        *,
        ssl: Any = None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        return await self.create_connection(
            protocol_factory,
            sock=sock,
            ssl=ssl,
            ssl_handshake_timeout=ssl_handshake_timeout,
            ssl_shutdown_timeout=ssl_shutdown_timeout,
        )

    async def create_unix_connection(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str,
        *,
        ssl: Any = None,
        server_hostname: str | None = None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        if ssl is not None:
            return await self._create_ssl_unix_connection(
                protocol_factory,
                path,
                ssl=ssl,
                server_hostname=server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
            )
        return await _Loop.create_unix_connection(self, protocol_factory, path, ssl=ssl)

    async def _create_ssl_unix_connection(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str,
        *,
        ssl: Any,
        server_hostname: str | None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
    ) -> tuple[asyncio.Transport, asyncio.BaseProtocol]:
        self_loop = self
        import ssl as ssl_module

        sslcontext = ssl
        sni = server_hostname or None

        incoming = ssl_module.MemoryBIO()
        outgoing = ssl_module.MemoryBIO()
        sslobj = sslcontext.wrap_bio(
            incoming,
            outgoing,
            server_side=False,
            server_hostname=sni,
        )

        waiter = self.create_future()
        app_protocol = protocol_factory()
        wrapper_holder: list[Any] = [None]

        class SP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                self._sslobj = sslobj
                self._incoming = incoming
                self._outgoing = outgoing
                self._ap = app_protocol

            def get_buffer(self, n):
                return self._view[:n]

            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if hasattr(self, "_wrapper") and self._wrapper._closing:
                    self._wrapper._start_shutdown()
                elif not self._hs:
                    self._h()
                else:
                    self._r()

            def connection_made(self, t):
                self._raw_t = t
                self._wrapper = _SSLTransportWrapper(
                    self,
                    t,
                    ssl_module,
                    shutdown_timeout=ssl_shutdown_timeout,
                    loop=self_loop,
                )
                wrapper_holder[0] = self._wrapper
                self._h()

            def connection_lost(self, e):
                try:
                    self._ap.connection_lost(e)
                except Exception:
                    logger.exception("Unhandled exception in event loop callback")

            def eof_received(self):
                try:
                    return self._ap.eof_received()
                except Exception:
                    return False

            def pause_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "pause_writing"):
                    try:
                        self._ap.pause_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def resume_writing(self):
                if hasattr(self, "_ap") and hasattr(self._ap, "resume_writing"):
                    try:
                        self._ap.resume_writing()
                    except Exception:
                        logger.exception("Unhandled exception in event loop callback")

            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception as exc:
                    if not waiter.done():
                        waiter.set_exception(exc)
                else:
                    self._hs = True
                    if not waiter.done():
                        waiter.set_result(None)
                    self._f()
                    app_protocol.connection_made(self._wrapper)

            def _r(self):
                chunks = []
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    chunks.append(d)
                if chunks:
                    app_protocol.data_received(b"".join(chunks))

            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        transport, _ = await _Loop.create_unix_connection(
            self,
            SP,
            path,
        )

        try:
            # BUG-74: Use the configurable ssl_handshake_timeout
            # instead of hardcoded 60s. Default to 60s if None.
            await asyncio.wait_for(waiter, timeout=ssl_handshake_timeout or 60)
        except BaseException:
            transport.close()
            raise

        return wrapper_holder[0] or transport, app_protocol

    async def create_unix_server(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str,
        *,
        backlog: int = 100,
        ssl: Any = None,
        ssl_handshake_timeout: float | None = None,
        ssl_shutdown_timeout: float | None = None,
        start_serving: bool = True,
    ) -> "Server":
        if ssl is not None:
            return await self._create_ssl_unix_server(
                protocol_factory,
                path,
                backlog=backlog,
                ssl=ssl,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
            )
        srv = await _Loop.create_unix_server(
            self,
            protocol_factory,
            path,
            backlog=backlog,
        )
        server = Server(self, [srv])
        if hasattr(srv, "server_ref"):
            srv.server_ref = server
        return server

    async def _create_ssl_unix_server(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        path: str,
        *,
        backlog: int,
        ssl: Any,
        ssl_shutdown_timeout: float | None = None,
    ) -> "Server":
        self_loop = self
        import ssl as ssl_module

        sslcontext = ssl

        class SSP(asyncio.BufferedProtocol):
            def __init__(self):
                self._buf = bytearray(65536)
                self._view = memoryview(self._buf)
                self._hs = False
                incoming = ssl_module.MemoryBIO()
                outgoing = ssl_module.MemoryBIO()
                self._sslobj = sslcontext.wrap_bio(
                    incoming,
                    outgoing,
                    server_side=True,
                )
                self._incoming = incoming
                self._outgoing = outgoing

            def get_buffer(self, n):
                return self._view[:n]

            def buffer_updated(self, n):
                self._incoming.write(self._buf[:n])
                if not self._hs:
                    self._h()
                else:
                    self._r()

            def connection_made(self, t):
                self._raw_t = t
                self._ap = protocol_factory()
                self._wrapper = _SSLTransportWrapper(
                    self,
                    self._raw_t,
                    ssl_module,
                    shutdown_timeout=ssl_shutdown_timeout,
                    loop=self_loop,
                )
                self._h()

            def connection_lost(self, e):
                self._ap.connection_lost(e)

            def eof_received(self):
                self._ap.eof_received()
                return False

            def _h(self):
                try:
                    self._sslobj.do_handshake()
                except ssl_module.SSLWantReadError:
                    self._f()
                except ssl_module.SSLWantWriteError:
                    self._f()
                except Exception:
                    self._raw_t.close()
                else:
                    self._hs = True
                    self._f()
                    self._ap.connection_made(self._wrapper)

            def _r(self):
                while True:
                    try:
                        d = self._sslobj.read(65536)
                    except ssl_module.SSLWantReadError:
                        break
                    except (ssl_module.SSLSyscallError, ssl_module.SSLError):
                        break
                    if not d:
                        break
                    self._ap.data_received(d)

            def _f(self):
                d = self._outgoing.read()
                if d:
                    self._raw_t.write(d)

        srv = await _Loop.create_unix_server(
            self,
            SSP,
            path,
            backlog=backlog,
        )
        server = Server(self, [srv])
        if hasattr(srv, "server_ref"):
            srv.server_ref = server
        return server

    async def subprocess_exec(
        self,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        program: Any,
        *args: Any,
        stdin: Any = None,
        stdout: Any = None,
        stderr: Any = None,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        pass_fds: Any = None,
        **kwargs: Any,
    ) -> tuple[Any, Any]:
        import subprocess

        cmd = (program, *args)
        popen = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL if stdin is None else stdin,
            stdout=subprocess.DEVNULL if stdout is None else stdout,
            stderr=subprocess.DEVNULL if stderr is None else stderr,
            cwd=cwd,
            env=env,
            pass_fds=pass_fds if pass_fds is not None else (),
        )
        _subprocess_popens[popen.pid] = popen
        try:
            exit_waiters: list = []
            outer_self = self

            orig_factory = protocol_factory

            class _TransportWrapper:
                def __init__(self, transport):
                    self._transport = transport
                    self._popen = popen

                def __getattr__(self, name):
                    return getattr(self._transport, name)

                def get_extra_info(self, name, default=None):
                    if name == "subprocess":
                        return popen
                    return getattr(self._transport, "get_extra_info", lambda *a, **k: default)(name, default)

                def get_pipe_transport(self, fd):
                    return None

                def is_closing(self):
                    return self._transport.is_closing()

                def close(self):
                    self._transport.close()

                def get_pid(self):
                    return self._transport.get_pid()

                def get_returncode(self):
                    return self._transport.get_returncode()

                def kill(self):
                    self._transport.kill()

                def terminate(self):
                    self._transport.terminate()

                def send_signal(self, sig):
                    self._transport.send_signal(sig)

                @property
                def _popen(self):
                    return popen

                @_popen.setter
                def _popen(self, val):
                    nonlocal popen
                    popen = val

                async def _wait(self):
                    rc = self.get_returncode()
                    if rc is not None:
                        return rc
                    waiter = outer_self.create_future()
                    exit_waiters.append(waiter)
                    return await waiter

            def _wrapped_factory():
                protocol = orig_factory()
                orig_cm = protocol.connection_made
                orig_cl = protocol.connection_lost

                class _ProtocolWrapper:
                    __slots__ = ("_proto", "_transport_holder")

                    def __init__(self):
                        self._proto = protocol
                        self._transport_holder = [None]

                    def __getattr__(self, name):
                        return getattr(self._proto, name)

                    def connection_made(self, transport):
                        wrapper = _TransportWrapper(transport)
                        self._transport_holder[0] = wrapper
                        orig_cm(wrapper)

                    def connection_lost(self, exc):
                        try:
                            orig_cl(exc)
                        finally:
                            held = self._transport_holder[0]
                            rc = None
                            if held is not None:
                                try:
                                    rc = held.get_returncode()
                                except BaseException:
                                    rc = None
                            if rc is None:
                                rc = -1
                            for waiter in exit_waiters:
                                if not waiter.done():
                                    waiter.set_result(rc)

                return _ProtocolWrapper()

            transport, protocol = await _Loop.subprocess_exec(
                self,
                _wrapped_factory,
                pid=popen.pid,
            )
            wrapper = _TransportWrapper(transport)
            return wrapper, protocol
        except BaseException:
            if popen.poll() is None:
                popen.kill()
                popen.wait()
            raise
        finally:
            _subprocess_popens.pop(popen.pid, None)


import warnings

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)

    class EventLoopPolicy(asyncio.DefaultEventLoopPolicy):
        """Event loop policy for Talyn."""

        def new_event_loop(self) -> Loop:
            """Create and return a new Talyn event loop."""
            return Loop()


class PseudoSocket:
    def __init__(self, fd, family, type, proto=0):
        self._fd = fd
        self._family = family
        self._type = type
        self._proto = proto

    def fileno(self):
        return self._fd

    @property
    def family(self):
        return self._family

    @property
    def type(self):
        return self._type

    @property
    def proto(self):
        return self._proto

    def getsockname(self):
        tmp = socket.fromfd(self._fd, self._family, self._type)
        try:
            return tmp.getsockname()
        finally:
            tmp.close()

    def getpeername(self):
        tmp = socket.fromfd(self._fd, self._family, self._type)
        try:
            return tmp.getpeername()
        finally:
            tmp.close()

    def setblocking(self, blocking):
        pass

    def close(self):
        pass

    def __repr__(self):
        return f"<PseudoSocket fd={self._fd}, family={self._family}, type={self._type}>"
