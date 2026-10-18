"""BUG-351 regression tests.

During P15 batch dispatch, a stream read's BlockingTask slot is freed at
harvest (fetch_completed_tasks) while ``ReadTransport.blocking_task_id``
stayed non-zero until ``read_operation_completed`` ran in ``call_once``
— i.e. during the entire ``protocol.data_received()`` /
``protocol.buffer_updated()`` call the transport carried a stale task id.

Any ``pause_reading()`` / ``close()`` / ``abort()`` inside the protocol
callback queued ``CancelIO`` on the freed — and possibly already reused —
slot, cancelling whatever unrelated timer or IO operation reused it
(BUG-336 class). ``ReadTransport.close()`` additionally queued a second
CancelIO after ``pause_reading()`` had already cancelled the generation.
"""

import asyncio
import socket
import threading
import time

import pytest

import talyn


def _echo_server(ready: threading.Event, port: list) -> threading.Thread:
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
                c.sendall(b"one")
                threading.Event().wait(0.4)
                c.sendall(b"two")
                threading.Event().wait(0.2)
            except OSError:
                pass
        srv.close()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    return t


def test_bug351_pause_during_dispatch_does_not_cancel_timer() -> None:
    """pause_reading() inside data_received() must be a no-op (the read
    already completed at harvest), and must not cancel a timer scheduled
    moments earlier in the same callback (pre-fix: the reused BlockingTask
    slot was cancelled, so the timer fired immediately)."""
    ready = threading.Event()
    port: list = []
    server_thread = _echo_server(ready, port)
    assert ready.wait(5.0)

    received: list = []

    async def main() -> None:
        loop = asyncio.get_running_loop()
        timer_fired_at: list = []
        timer_started_at: list = []
        got_push = asyncio.Event()

        class Proto(asyncio.Protocol):
            def connection_made(self, transport) -> None:
                self.transport = transport

            def data_received(self, data) -> None:
                received.append(bytes(data))
                if received[0] == b"one" and len(received) == 1:
                    # The read CQE was already harvested: no read op is in
                    # flight here. Schedule a timer (its BlockingTask may
                    # reuse the read's just-freed slot) and then pause.
                    timer_started_at.append(loop.time())
                    loop.call_later(0.2, lambda: timer_fired_at.append(loop.time()))
                    self.transport.pause_reading()
                    # BUG-351: pre-fix this resume was also skipped (stale
                    # id made the transport look busy) while the completing
                    # callback re-armed; both paths must deliver "two".
                    self.transport.resume_reading()
                if b"two" in data:
                    got_push.set()

            def connection_lost(self, exc) -> None:
                got_push.set()

        await loop.create_connection(Proto, "127.0.0.1", port[0])

        # Keep the loop running until the re-armed read chain delivers the
        # second message (and give the timer its 0.2s).
        try:
            await asyncio.wait_for(got_push.wait(), 5.0)
        except asyncio.TimeoutError:
            pass
        await asyncio.sleep(max(0.0, 0.3 - (loop.time() - timer_started_at[0])))

        # Timer must fire, and not immediately (pre-fix the CancelIO on
        # the reused slot killed the timer and it fired at ~0s).
        assert timer_fired_at, "timer scheduled before pause_reading() never fired"
        elapsed = timer_fired_at[0] - timer_started_at[0]
        assert elapsed >= 0.15, f"timer fired early ({elapsed=:.3f}s)"

        # The post-pause message must have arrived through the re-armed
        # read chain (and exactly once — no double re-arm).
        assert received[-1] == b"two", f"second message not received: {received}"
        assert len(received) == 2, f"unexpected read count: {received}"

    try:
        talyn.run(main())
    finally:
        server_thread.join(timeout=5.0)


def test_bug351_close_after_pause_queues_single_cancel() -> None:
    """close() right after pause_reading() inside data_received() must not
    queue a second CancelIO for the same op generation (pre-fix the second
    cancel hit the freed/reused slot and killed a freshly scheduled
    timer)."""
    ready = threading.Event()
    port: list = []
    server_thread = _echo_server(ready, port)
    assert ready.wait(5.0)

    async def main() -> None:
        loop = asyncio.get_running_loop()
        timer_fired_at: list = []
        timer_started_at: list = []
        lost = asyncio.Event()

        class Proto(asyncio.Protocol):
            def connection_made(self, transport) -> None:
                self.transport = transport

            def data_received(self, data) -> None:
                timer_started_at.append(loop.time())
                loop.call_later(0.1, lambda: timer_fired_at.append(loop.time()))
                # pause_reading() cancels the (already completed) read op.
                self.transport.pause_reading()
                # BUG-351: close() used to queue a SECOND CancelIO for the
                # same task id — killing the timer scheduled above once the
                # slot got reused.
                self.transport.close()

            def connection_lost(self, exc) -> None:
                lost.set()

        await loop.create_connection(Proto, "127.0.0.1", port[0])
        # connection_lost must arrive; give the 0.1s timer its slot too.
        try:
            await asyncio.wait_for(lost.wait(), 5.0)
        except asyncio.TimeoutError:
            pass
        await asyncio.sleep(max(0.0, 0.2 - (loop.time() - timer_started_at[0])))

        assert timer_fired_at, "timer after close() was cancelled — second CancelIO hit the reused slot"
        elapsed = timer_fired_at[0] - timer_started_at[0]
        assert elapsed >= 0.05, f"timer fired early ({elapsed=:.3f}s)"

    try:
        talyn.run(main())
    finally:
        server_thread.join(timeout=5.0)
