import asyncio
import logging
import threading
import time
import weakref

import talyn


def test_debug_mode_basic():
    loop = talyn.Loop()
    try:
        assert loop.get_debug() is False
        loop.set_debug(True)
        assert loop.get_debug() is True
        loop.set_debug(False)
        assert loop.get_debug() is False
    finally:
        loop.close()


def test_debug_mode_slow_callback(caplog):
    loop = talyn.Loop()
    loop.set_debug(True)

    def slow_callback():
        time.sleep(0.15)

    async def main():
        loop.call_soon(slow_callback)
        await asyncio.sleep(0.2)

    try:
        with caplog.at_level(logging.ERROR, logger="talyn"):
            loop.run_until_complete(main())

        found = False
        for record in caplog.records:
            if "Executing callback took" in record.message:
                found = True
                break
        assert found, f"Slow callback warning not found in logs: {caplog.text}"
    finally:
        loop.close()


def test_debug_mode_thread_safety():
    loop = talyn.Loop()
    loop.set_debug(True)

    errors = []

    def target():
        try:
            loop.call_soon(lambda: None)
        except RuntimeError as e:
            errors.append(e)

    t = threading.Thread(target=target)
    t.start()
    t.join()

    try:
        assert len(errors) == 1
        assert "different thread" in str(errors[0])

        # call_soon_threadsafe should still work
        loop.call_soon_threadsafe(lambda: None)
    finally:
        loop.close()


def test_loop_weakref():
    loop = talyn.Loop()
    try:
        ref = weakref.ref(loop)
        assert ref() is loop
    finally:
        loop.close()


if __name__ == "__main__":
    talyn.run(test_debug_mode_basic())
