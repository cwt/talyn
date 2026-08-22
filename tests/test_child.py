import asyncio
import signal
import subprocess
import time

import talyn


def test_child_handler():
    async def main():
        loop = asyncio.get_running_loop()

        # Create a child process that exits after a short delay
        proc = subprocess.Popen(["sleep", "0.1"])
        pid = proc.pid

        result = []

        def callback(p, returncode):
            result.append((p, returncode))

        loop.add_child_handler(pid, callback)

        # Wait for child to exit
        start_time = time.time()
        while not result and time.time() - start_time < 2.0:
            await asyncio.sleep(0.01)

        assert result == [(pid, 0)]
        proc.wait()  # Just to be clean

    talyn.run(main())


def test_child_handler_killed():
    async def main():
        loop = asyncio.get_running_loop()

        proc = subprocess.Popen(["sleep", "10"])
        pid = proc.pid

        result = []

        def callback(p, returncode):
            result.append((p, returncode))

        loop.add_child_handler(pid, callback)

        # Kill the child
        proc.terminate()

        # Wait for child to exit
        start_time = time.time()
        while not result and time.time() - start_time < 2.0:
            await asyncio.sleep(0.01)

        assert result[0][0] == pid
        # returncode for SIGTERM should be -15
        assert result[0][1] == -signal.SIGTERM
        proc.wait()

    talyn.run(main())


def test_child_handler_exception_cleanup():
    async def main():
        loop = asyncio.get_running_loop()

        errors = []

        def custom_exception_handler(l, context):
            errors.append(context)

        loop.set_exception_handler(custom_exception_handler)

        proc = subprocess.Popen(["sleep", "0.05"])
        pid = proc.pid

        def failing_callback(p, returncode):
            raise ValueError("boom in child handler")

        loop.add_child_handler(pid, failing_callback)

        start_time = time.time()
        while not errors and time.time() - start_time < 2.0:
            await asyncio.sleep(0.01)

        assert len(errors) == 1
        assert "boom in child handler" in str(errors[0]["exception"])
        proc.wait()

    talyn.run(main())



def test_duplicate_add_child_handler_replaces_cleanly():
    """BUG-277: re-registering a pid must fully tear down the previous
    handler (pidfd, callback ref, struct, armed op) instead of silently
    orphaning it via map overwrite."""
    import os

    import pytest

    from talyn import Loop

    loop = Loop()
    try:
        loop.add_child_handler(os.getpid(), lambda pid, rc: None)
        loop.add_child_handler(os.getpid(), lambda pid, rc: None)

        assert loop.remove_child_handler(os.getpid()) is True
        assert loop.remove_child_handler(os.getpid()) is False

        # Loop must remain operational afterwards.
        async def ok():
            return 1

        assert loop.run_until_complete(ok()) == 1
    finally:
        loop.close()


def test_remove_child_handler_while_exit_pending_is_safe():
    """BUG-280: removing a handler whose exit CQE was already reaped must
    not free the handler out from under the queued on_child_exit. The
    marked handler is torn down by its own invocation instead."""
    import subprocess
    import time

    loop = talyn.Loop()
    fired = []
    try:
        child = subprocess.Popen(["sleep", "0"])
        time.sleep(0.05)  # let it exit; CQE may be reaped on next poll

        loop.add_child_handler(child.pid, lambda pid, rc: fired.append((pid, rc)))

        # Remove while the completion may already be queued.
        assert loop.remove_child_handler(child.pid) in (True, False)

        async def pump():
            await asyncio.sleep(0.1)

        loop.run_until_complete(pump())
        loop.run_until_complete(pump())

        child.wait()

        async def ok():
            return 9

        assert loop.run_until_complete(ok()) == 9
    finally:
        loop.close()


def test_child_handler_fires_and_cleans_up():
    """Companion regression for BUG-280 teardown paths: normal exit fires
    the callback exactly once and leaves the loop healthy."""
    import asyncio
    import subprocess

    loop = talyn.Loop()
    fired = []
    child = None
    try:
        child = subprocess.Popen(["true"])
        loop.add_child_handler(child.pid, lambda pid, rc: fired.append(rc))

        async def pump():
            for _ in range(50):
                if fired:
                    return
                await asyncio.sleep(0.02)

        loop.run_until_complete(pump())
        child.wait()
        assert fired, "child-exit callback never fired"

        async def ok():
            return 3

        assert loop.run_until_complete(ok()) == 3
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        loop.close()
