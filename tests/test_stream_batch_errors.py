"""BUG-363 regression tests.

``dispatch_completion_batch`` used to leave an exception raised by a
protocol's ``data_received()`` / ``buffer_updated()`` on the thread state
while still calling ``PyBytes_FromStringAndSize`` /
``PyObject_CallOneArg`` for the remaining records of the batch (state
corruption + earlier records' exceptions dropped), and returned
``error.PythonError`` to ``Runner.start`` — aborting
``loop.run_forever()`` before the ready queue could run
``ReadTransport.read_operation_completed`` (reads never re-armed, healthy
transports starved).

Per asyncio semantics the exception must instead be raised to
``loop.call_exception_handler`` immediately (clearing the thread state
for the rest of the batch), and the loop must keep running.
"""

import asyncio
import socket
import threading

import talyn


def _two_shot_server(ready: threading.Event, port: list) -> threading.Thread:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    port.append(srv.getsockname()[1])
    ready.set()

    def serve() -> None:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        with c:
            try:
                c.sendall(b"first")
                # Keep the two reads in separate completion ticks.
                threading.Event().wait(0.3)
                c.sendall(b"second")
                threading.Event().wait(0.2)
            except OSError:
                pass
        srv.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return thread


def test_bug363_data_received_exception_does_not_abort_run() -> None:
    """An exception raised by data_received() must reach the loop's
    exception handler (with the exception object preserved), must NOT
    abort run_forever, and the transport's re-armed read chain must keep
    delivering data after the failed dispatch."""
    ready = threading.Event()
    port: list = []
    server_thread = _two_shot_server(ready, port)
    assert ready.wait(5.0)

    received: list = []
    seen_exceptions: list = []

    async def main() -> None:
        loop = asyncio.get_running_loop()
        second_arrived = loop.create_future()

        def record_handler(loop, context):
            seen_exceptions.append(context.get("exception"))

        loop.set_exception_handler(record_handler)

        class ExceptionalProtocol(asyncio.Protocol):
            def connection_made(self, transport) -> None:
                self.transport = transport

            def data_received(self, data) -> None:
                received.append(bytes(data))
                if len(received) == 1:
                    raise ValueError("bad frame")
                if not second_arrived.done():
                    second_arrived.set_result(True)

            def connection_lost(self, exc) -> None:
                if not second_arrived.done():
                    second_arrived.set_result(True)

        await loop.create_connection(ExceptionalProtocol, "127.0.0.1", port[0])
        try:
            await asyncio.wait_for(second_arrived, 5.0)
        except asyncio.TimeoutError:
            pass
        await asyncio.sleep(0.05)

    try:
        talyn.run(main())

        # The transport survived the failed dispatch: the re-armed read
        # chain delivered the second message after the exception tick.
        assert received, "no data received at all"
        assert received[0] == b"first", f"first read lost: {received}"
        assert received[-1] == b"second", (
            f"run_forever aborted before the re-armed read delivered "
            f"the next message: {received}"
        )
        assert len(received) == 2, f"unexpected read count: {received}"

        # The exception was routed to the loop's exception handler.
        value_errors = [exc for exc in seen_exceptions if isinstance(exc, ValueError)]
        assert value_errors, (
            "data_received() exception never reached call_exception_handler: "
            f"{seen_exceptions}"
        )
    finally:
        server_thread.join(timeout=5.0)
