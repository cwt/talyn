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


def test_replace_child_handler_cancelled_cqe_is_safe():
    """BUG-307: replacing a live child handler must not free the old
    handler while its cancellation CQE is still in flight. The old handler
    is torn down by its own (cancelled) on_child_exit invocation; the
    replacement receives the exit; the loop stays healthy afterwards."""
    import os
    import subprocess

    loop = talyn.Loop()
    fired = []
    child = None
    try:
        # Deterministic half: our own pid never exits, so the replaced
        # handler's op is always ended by an ECANCELED dispatch.
        loop.add_child_handler(os.getpid(), lambda pid, rc: fired.append(("old-self", pid, rc)))
        loop.add_child_handler(os.getpid(), lambda pid, rc: fired.append(("new-self", pid, rc)))
        assert loop.remove_child_handler(os.getpid()) is True

        # Racy half: child exits after replacement. The replacement must be
        # the one notified, and processing the old handler's cancelled CQE
        # must not corrupt anything.
        child = subprocess.Popen(["sleep", "10"])
        loop.add_child_handler(child.pid, lambda pid, rc: fired.append(("old-child", pid, rc)))
        loop.add_child_handler(child.pid, lambda pid, rc: fired.append(("new-child", pid, rc)))
        child.terminate()

        async def pump():
            for _ in range(100):
                if any(entry[0] == "new-child" for entry in fired):
                    return
                await asyncio.sleep(0.02)

        loop.run_until_complete(pump())
        child.wait()
        assert ("new-child", child.pid, -signal.SIGTERM) in fired

        # Loop stays healthy after the cancelled replacement CQEs were
        # processed (previously a use-after-free read on the freed handler).
        async def ok():
            return 7

        assert loop.run_until_complete(ok()) == 7
        assert loop.remove_child_handler(os.getpid()) is False
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        loop.close()


def test_re_register_inside_exit_callback_stays_consistent():
    """BUG-313: re-registering the same pid from inside the exit callback
    must not corrupt the handler map. After the reap the pid is gone, so
    the re-register raises 'No such process' (routed to the exception
    handler); the exiting handler still tears itself down, the map ends
    up empty, and the loop stays healthy."""
    import subprocess

    loop = talyn.Loop()
    fired = []
    errors = []
    child = None
    try:
        loop.set_exception_handler(lambda lp, ctx: errors.append(ctx))
        child = subprocess.Popen(["true"])

        def reRegisteringCallback(pid, rc):
            fired.append(("old", pid, rc))
            # Re-register the same pid from inside the exit callback: the
            # child has already been reaped by the native waitid, so this
            # raises 'No such process' - the exact window BUG-313 guards.
            loop.add_child_handler(pid, lambda p, c: fired.append(("new", p, c)))

        loop.add_child_handler(child.pid, reRegisteringCallback)

        async def pump():
            for _ in range(100):
                if fired:
                    return
                await asyncio.sleep(0.02)

        loop.run_until_complete(pump())
        child.wait()
        assert ("old", child.pid, 0) in fired
        assert len(errors) == 1
        assert "No such process" in str(errors[0]["exception"])

        # The failed re-register must not have left a mapped handler.
        assert loop.remove_child_handler(child.pid) is False

        async def ok():
            return 6

        assert loop.run_until_complete(ok()) == 6
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        loop.close()


def test_add_child_handler_on_reaped_pid_raises():
    """BUG-326: pidfd_open on a reaped pid returns -ESRCH; the libc-style
    std.posix.errno decoder mis-read it as SUCCESS and truncated -errno
    into a bogus pidfd (whose waitid then failed with EINVAL, stranding
    the handler). Registering a watcher for a dead pid must raise
    'No such process'."""
    import subprocess
    import time

    import pytest

    loop = talyn.Loop()
    try:
        child = subprocess.Popen(["true"])
        child.wait()
        time.sleep(0.05)  # let the kernel fully release the pid
        with pytest.raises(RuntimeError, match="No such process"):
            loop.add_child_handler(child.pid, lambda pid, rc: None)
    finally:
        loop.close()


def test_child_handler_external_reap_teardown():
    """BUG-314: a non-transient waitid failure (ECHILD - the child was
    reaped externally) must tear the handler down instead of stranding it
    mapped with an open pidfd and a leaked struct. The callback cannot
    fire (no exit status is available) but the map must end clean."""
    import os as os_mod
    import subprocess
    import time

    loop = talyn.Loop()
    fired = []
    child = None
    try:
        child = subprocess.Popen(["true"])
        loop.add_child_handler(child.pid, lambda pid, rc: fired.append((pid, rc)))
        time.sleep(0.05)  # let the child exit (its POLLIN completes)
        os_mod.waitpid(child.pid, 0)  # external reap -> our waitid gets ECHILD

        async def pump():
            await asyncio.sleep(0.1)

        loop.run_until_complete(pump())
        assert fired == []  # no exit status available for the callback
        # The handler must have been torn down (unmapped) - previously it
        # stayed mapped forever with an open pidfd.
        assert loop.remove_child_handler(child.pid) is False

        async def ok():
            return 8

        assert loop.run_until_complete(ok()) == 8
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        loop.close()
