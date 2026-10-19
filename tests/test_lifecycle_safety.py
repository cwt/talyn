"""Regression tests for core lifecycle safety: callback dispatch, signal handling, thread handoff, and constructor re-init."""

import asyncio
import gc
import os
import signal
import socket
import sys
import threading
import pytest

from talyn import Loop


def dummy_callback() -> None:
    pass


def failing_callback() -> None:
    raise ValueError("intentional callback failure")


async def dummy_coro() -> str:
    return "completed"


def test_callback_exception_handling_debug_false() -> None:
    """Verify callback exception handling works without double-decref or UAF when debug=False (BUG-381)."""
    loop = Loop()
    try:
        loop.set_debug(False)
        handled_exceptions = []

        def custom_handler(target_loop, context):
            handled_exceptions.append(context)

        loop.set_exception_handler(custom_handler)

        loop.call_soon(failing_callback)
        loop.call_soon(loop.stop)
        loop.run_forever()

        assert len(handled_exceptions) == 1
        assert "exception" in handled_exceptions[0]
        assert isinstance(handled_exceptions[0]["exception"], ValueError)
    finally:
        loop.close()


def test_callback_exception_handling_debug_true() -> None:
    """Verify callback exception handling works cleanly when debug=True (BUG-381)."""
    loop = Loop()
    try:
        loop.set_debug(True)
        handled_exceptions = []

        def custom_handler(target_loop, context):
            handled_exceptions.append(context)

        loop.set_exception_handler(custom_handler)

        loop.call_soon(failing_callback)
        loop.call_soon(loop.stop)
        loop.run_forever()

        assert len(handled_exceptions) == 1
        assert "exception" in handled_exceptions[0]
        assert isinstance(handled_exceptions[0]["exception"], ValueError)
    finally:
        loop.close()


def test_signal_restoration_after_remove_and_close() -> None:
    """Verify that removing a signal handler restores the previous handler instead of no-op (BUG-382)."""
    loop = Loop()
    initial_sigint = signal.getsignal(signal.SIGINT)
    try:
        def on_sigint():
            pass

        loop.add_signal_handler(signal.SIGINT, on_sigint)
        assert loop.remove_signal_handler(signal.SIGINT) is True

        current_sigint = signal.getsignal(signal.SIGINT)
        # Should match initial handler (e.g. Python default_int_handler or SIG_DFL)
        assert current_sigint == initial_sigint
    finally:
        loop.close()

    # After loop.close(), SIGINT should still be restored
    final_sigint = signal.getsignal(signal.SIGINT)
    assert final_sigint == initial_sigint


def test_signal_rtmax_support() -> None:
    """Verify that real-time signal 64 (SIGRTMAX) does not panic @intCast (BUG-382)."""
    rtmax = signal.SIGRTMAX
    if rtmax < 34:
        pytest.skip("SIGRTMAX not available or < 34")

    loop = Loop()
    try:
        def on_rtmax():
            pass

        loop.add_signal_handler(rtmax, on_rtmax)
        assert loop.remove_signal_handler(rtmax) is True
    finally:
        loop.close()


def test_thread_handoff_with_fixed_files() -> None:
    """Verify thread handoff preserves fixed file table so connections work on the new thread (BUG-383)."""
    loop = Loop()
    server_sock, client_sock = socket.socketpair()

    thread_errors = []

    def run_in_thread():
        try:
            # Running loop on another thread triggers ensure_ring_for_current_thread
            async def run_test():
                transport, protocol = await loop.create_connection(
                    asyncio.Protocol, sock=client_sock
                )
                transport.write(b"ping")
                await asyncio.sleep(0.05)
                transport.close()

            loop.run_until_complete(run_test())
        except Exception as exc:
            thread_errors.append(exc)
        finally:
            loop.close()

    t = threading.Thread(target=run_in_thread)
    t.start()
    t.join(timeout=5.0)

    server_sock.close()
    assert not t.is_alive(), "Worker thread hung"
    assert len(thread_errors) == 0, f"Thread failed with errors: {thread_errors}"


def test_handle_clear_null_safety() -> None:
    """Verify handle_clear does not crash with null unwrap panics under GC (BUG-386)."""
    loop = Loop()
    try:
        h = loop.call_soon(dummy_callback)
        # Cancel and clear
        h.cancel()
        assert h.cancelled() is True

        # Call get_context on handle
        ctx = h.get_context()
        assert ctx is not None
    finally:
        loop.close()


def test_timer_handle_cancellation_clears_task_id() -> None:
    """Verify cancelled timer handles drop blocking_task_id so cancel() is idempotent and safe (BUG-386)."""
    loop = Loop()
    try:
        th = loop.call_later(10.0, dummy_callback)
        assert th.cancelled() is False
        th.cancel()
        assert th.cancelled() is True

        # Repeated cancel on cancelled timer should be a safe no-op
        th.cancel()
        assert th.cancelled() is True
    finally:
        loop.close()


def test_repeated_loop_init_raises_runtime_error() -> None:
    """Verify repeated loop.__init__ raises RuntimeError without memory corruption (BUG-386)."""
    loop = Loop()
    try:
        with pytest.raises(RuntimeError, match="already initialized"):
            loop.__init__()
    finally:
        loop.close()


def test_repeated_future_init_resets_safely() -> None:
    """Verify repeated future.__init__ does not leak references or panic (BUG-386)."""
    loop = Loop()
    try:
        fut = loop.create_future()
        fut.__init__(loop=loop)
        assert not fut.done()
        fut.set_result(42)
        assert fut.result() == 42
    finally:
        loop.close()


def test_repeated_task_init_raises_runtime_error() -> None:
    """Verify repeated task.__init__ raises RuntimeError to protect active coroutine state (BUG-386)."""
    loop = Loop()
    try:
        coro = dummy_coro()
        task = loop.create_task(coro)
        extra_coro = dummy_coro()
        try:
            with pytest.raises(RuntimeError, match="already initialized"):
                task.__init__(extra_coro, loop=loop)
        finally:
            extra_coro.close()
        loop.run_until_complete(task)
        assert task.result() == "completed"
    finally:
        loop.close()


def test_repeated_handle_init_resets_safely() -> None:
    """Verify repeated handle.__init__ does not leak context references (BUG-386)."""
    loop = Loop()
    try:
        h = loop.call_soon(dummy_callback)
        ctx = h.get_context()
        h.__init__(context=ctx)
        assert h.get_context() is not None
    finally:
        loop.close()
