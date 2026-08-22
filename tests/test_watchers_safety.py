import pytest

import talyn


def test_remove_non_existent_reader():
    loop = talyn.Loop()
    try:
        # Removing a non-existent reader should return False, not crash.
        assert loop.remove_reader(100) is False
    finally:
        loop.close()


def test_remove_invalid_fd():
    loop = talyn.Loop()
    try:
        with pytest.raises(ValueError, match="Invalid file descriptor"):
            loop.remove_reader(-1)
    finally:
        loop.close()


def test_add_reader_invalid_callback():
    loop = talyn.Loop()
    try:
        with pytest.raises(RuntimeError, match="Invalid callback"):
            loop.add_reader(100, None)
    finally:
        loop.close()


def test_add_reader_then_immediate_close_no_uaf():
    """BUG-274: closing a loop with an armed add_reader watcher dispatches
    the cancelled poll AFTER the watcher B-trees are deinit'd; the cleanup
    must not delete(fd) against the freed tree. Runs in a subprocess so a
    UAF aborts loudly instead of silently corrupting the pytest process."""
    import subprocess
    import sys
    import textwrap

    script = textwrap.dedent(
        """\
        import socket, talyn

        for _ in range(50):
            loop = talyn.Loop()
            s = socket.socket()
            s.setblocking(False)
            loop.add_reader(s.fileno(), lambda: None)
            loop.close()   # cancels the armed poll; completions run post-deinit
            s.close()
        print("DONE")
        """
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=".",
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, f"crashed: rc={result.returncode}\n{result.stderr[-2000:]}"
    assert "DONE" in result.stdout
