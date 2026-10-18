import os

import pytest

from talyn import Loop


def test_add_and_remove_reader() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_called = False

        def reader_callback() -> None:
            nonlocal callback_called
            callback_called = True
            loop.stop()

        # Add reader
        loop.add_reader(r, reader_callback)

        # Trigger the callback
        loop.call_soon(lambda: os.write(w, b"data"))
        loop.run_forever()

        assert callback_called, "Reader callback was not called"

        # Remove reader
        assert loop.remove_reader(r), "Failed to remove reader"

        # Try to remove again, should return False
        assert not loop.remove_reader(r), (
            "Removing non-existent reader should return False"
        )

    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_add_and_remove_writer() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_called = False

        def writer_callback() -> None:
            nonlocal callback_called
            callback_called = True
            loop.stop()

        # Add writer
        loop.add_writer(w, writer_callback)

        # Run the loop
        loop.call_later(0.1, loop.stop)
        loop.run_forever()

        assert callback_called, "Writer callback was not called"

        # Remove writer
        assert loop.remove_writer(w), "Failed to remove writer"

        # Try to remove again, should return False
        assert not loop.remove_writer(w), (
            "Removing non-existent writer should return False"
        )
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_add_reader_invalid_fd() -> None:
    loop = Loop()
    try:
        with pytest.raises(ValueError):
            loop.add_reader(-1, lambda: None)
    finally:
        loop.close()


def test_add_writer_invalid_fd() -> None:
    loop = Loop()
    try:
        with pytest.raises(ValueError):
            loop.add_writer(-1, lambda: None)
    finally:
        loop.close()


def test_remove_reader_not_registered() -> None:
    loop = Loop()
    try:
        assert not loop.remove_reader(10), (
            "Removing non-existent reader should return False"
        )
    finally:
        loop.close()


def test_remove_writer_not_registered() -> None:
    loop = Loop()
    try:
        assert not loop.remove_writer(10), (
            "Removing non-existent writer should return False"
        )
    finally:
        loop.close()


def test_rewrite_reader() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_count = 0

        def reader_callback1() -> None:
            nonlocal callback_count
            callback_count += 1
            if callback_count == 1:
                loop.stop()

        def reader_callback2() -> None:
            nonlocal callback_count
            callback_count += 10
            loop.stop()

        # Add first reader
        loop.add_reader(r, reader_callback1)

        # Overwrite with second reader
        loop.add_reader(r, reader_callback2)

        # Trigger the callback
        loop.call_soon(lambda: os.write(w, b"data"))
        loop.run_forever()

        assert callback_count == 10, (
            "Second reader callback was not called or old callback also fired"
        )
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_rewrite_reader_old_callback_not_called() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        old_called = False
        new_called = False

        def old_cb() -> None:
            nonlocal old_called
            old_called = True

        def new_cb() -> None:
            nonlocal new_called
            new_called = True
            loop.stop()

        loop.add_reader(r, old_cb)
        loop.add_reader(r, new_cb)

        loop.call_soon(lambda: os.write(w, b"data"))
        loop.run_forever()

        assert not old_called, "Old callback was called after replacement"
        assert new_called, "New callback was not called after replacement"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_rewrite_writer() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_count = 0

        def writer_callback1() -> None:
            nonlocal callback_count
            callback_count += 1
            if callback_count == 1:
                loop.stop()

        def writer_callback2() -> None:
            nonlocal callback_count
            callback_count += 10
            loop.stop()

        # Add first writer
        loop.add_writer(w, writer_callback1)

        # Overwrite with second writer
        loop.add_writer(w, writer_callback2)

        # Run the loop
        loop.call_later(0.1, loop.stop)
        loop.run_forever()

        assert callback_count == 10, "Second writer callback was not called"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_remove_reader_then_add() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_called = False

        def reader_callback() -> None:
            nonlocal callback_called
            callback_called = True
            loop.stop()

        # Add reader
        loop.add_reader(r, reader_callback)

        # Remove reader
        assert loop.remove_reader(r), "Failed to remove reader"

        # Add reader again
        loop.add_reader(r, reader_callback)

        # Trigger the callback
        loop.call_soon(lambda: os.write(w, b"data"))
        loop.run_forever()

        assert callback_called, "Reader callback was not called after re-adding"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_remove_writer_then_add() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_called = False

        def writer_callback() -> None:
            nonlocal callback_called
            callback_called = True
            loop.stop()

        # Add writer
        loop.add_writer(w, writer_callback)

        # Remove writer
        assert loop.remove_writer(w), "Failed to remove writer"

        # Flush the cancel completion before re-adding
        loop.call_soon(lambda: None)
        loop.call_later(0.01, loop.stop)
        loop.run_forever()

        # Add writer again
        loop.add_writer(w, writer_callback)

        # Run the loop
        loop.call_later(0.1, loop.stop)
        loop.run_forever()

        assert callback_called, "Writer callback was not called after re-adding"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_add_reader_remove_writer() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:

        def reader_callback() -> None:
            pass

        def writer_callback() -> None:
            pass

        # Add reader and writer
        loop.add_reader(r, reader_callback)
        loop.add_writer(w, writer_callback)

        # Remove writer
        assert loop.remove_writer(w), "Failed to remove writer"

        # Reader should still be present
        assert loop.remove_reader(r), "Reader was unexpectedly removed"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_level_triggered_only_once_per_tick() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        calls = []

        def reader_callback() -> None:
            calls.append(loop.time())
            # Read only 1 byte, leaving the rest
            os.read(r, 1)
            if len(calls) == 2:
                loop.stop()

        loop.add_reader(r, reader_callback)
        os.write(w, b"ab")  # Write 2 bytes

        loop.call_later(0.5, loop.stop)  # Timeout safety
        loop.run_forever()

        assert len(calls) == 2, f"Expected 2 calls, got {len(calls)}"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_remove_reader_while_callback_pending() -> None:
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        callback_called = False

        def reader_callback() -> None:
            nonlocal callback_called
            callback_called = True
            # Try removing the reader from inside the callback where blocking_task_id is 0
            assert loop.remove_reader(r) is True, (
                "Failed to remove reader from callback"
            )
            loop.stop()

        loop.add_reader(r, reader_callback)
        os.write(w, b"a")

        loop.call_later(0.5, loop.stop)  # Timeout safety
        loop.run_forever()
        assert callback_called, "Reader callback was not called"
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_bug346_reader_callback_exception_handled_and_rearmed() -> None:
    """Ensure exceptions in reader callbacks are passed to exception_handler and watcher rearms (BUG-346)."""
    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        handled_exceptions = []
        call_count = 0

        def custom_handler(target_loop: Loop, context: dict) -> None:
            handled_exceptions.append(context)

        loop.set_exception_handler(custom_handler)

        def reader_callback() -> None:
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                # Do not read data so FD stays readable, raise exception
                raise ValueError("reader_boom")
            else:
                os.read(r, 100)
                loop.stop()

        loop.add_reader(r, reader_callback)
        os.write(w, b"hello")

        loop.call_later(2.0, loop.stop)  # Timeout guard
        loop.run_forever()

        assert len(handled_exceptions) == 1, f"Expected 1 handled exception, got {len(handled_exceptions)}"
        assert isinstance(handled_exceptions[0].get("exception"), ValueError)
        assert handled_exceptions[0].get("message") == "Exception in callback"
        assert call_count >= 2, f"Expected watcher to rearm and fire again, got {call_count} calls"

        assert loop.remove_reader(r) is True
    finally:
        loop.close()
        os.close(w)
        os.close(r)


def test_bug346_reader_callback_exception_no_handle_leak() -> None:
    """Ensure handle reference is not leaked when reader raises or is removed (BUG-346)."""
    import gc

    gc.collect()
    initial_handles = set(id(obj) for obj in gc.get_objects() if type(obj).__name__ == "Handle")

    loop = Loop()
    r, w = os.pipe2(os.O_NONBLOCK)
    try:
        def quiet_handler(target_loop: Loop, context: dict) -> None:
            pass

        loop.set_exception_handler(quiet_handler)

        def failing_callback() -> None:
            os.read(r, 1)
            raise RuntimeError("callback failure")

        loop.add_reader(r, failing_callback)

        for _ in range(5):
            os.write(w, b"x")
            loop.call_soon(loop.stop)
            loop.run_forever()

        loop.remove_reader(r)
        loop.call_soon(loop.stop)
        loop.run_forever()
        gc.collect()

        leaked_handles = [
            obj for obj in gc.get_objects()
            if type(obj).__name__ == "Handle" and id(obj) not in initial_handles
        ]
        assert len(leaked_handles) == 0, f"Leaked {len(leaked_handles)} Handle objects"
    finally:
        loop.close()
        os.close(w)
        os.close(r)

