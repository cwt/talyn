import asyncio
import os
import tempfile

import talyn


def test_path_watcher():
    async def main():
        loop = asyncio.get_running_loop()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "test.txt")

            events = []

            def callback(mask, cookie, name):
                events.append((mask, name))

            # IN_MODIFY = 2, IN_CREATE = 256, IN_DELETE = 512
            mask = 2 | 256 | 512
            handle = loop._add_path_watcher(tmpdir, mask, callback)

            # Create file
            with open(file_path, "w") as f:
                f.write("hello")

            # Yield to let inotify events process
            await asyncio.sleep(0.1)

            # Modify file
            with open(file_path, "a") as f:
                f.write(" world")

            await asyncio.sleep(0.1)

            # Delete file
            os.remove(file_path)

            await asyncio.sleep(0.1)

            # Check events
            # We expect at least CREATE, MODIFY, DELETE
            # Note: inotify might send multiple MODIFY events
            masks = [e[0] for e in events]
            names = [e[1] for e in events]

            assert 256 in masks  # IN_CREATE
            assert 2 in masks  # IN_MODIFY
            assert 512 in masks  # IN_DELETE
            assert "test.txt" in names

            handle.cancel()

    talyn.run(main())


def test_watch_callback_may_add_watcher_mid_dispatch():
    """BUG-278: dispatch must not hold stale watcher-array pointers across
    Python re-entry - a callback calling _add_path_watcher reallocates the
    watcher storage that on_inotify_event was iterating (and remove_watch
    frees entries)."""
    import asyncio

    async def main():
        loop = asyncio.get_running_loop()

        with tempfile.TemporaryDirectory() as tmpdir:
            seen_a, seen_b = [], []
            mask = 256  # IN_CREATE
            state = {"b_handle": None}

            def cb_b(m, cookie, name):
                seen_b.append(name)

            def cb_a(m, cookie, name):
                seen_a.append(name)
                if state["b_handle"] is None:
                    # Re-enter the watcher registry from inside a dispatch.
                    state["b_handle"] = loop._add_path_watcher(tmpdir, mask, cb_b)

            handle_a = loop._add_path_watcher(tmpdir, mask, cb_a)

            for i in range(3):
                with open(os.path.join(tmpdir, f"f{i}.txt"), "w") as f:
                    f.write("x")
                await asyncio.sleep(0.1)

            assert len(seen_a) >= 1
            assert len(seen_b) >= 1  # registered mid-dispatch still receives events

            handle_a.cancel()
            if state["b_handle"] is not None:
                state["b_handle"].cancel()

    talyn.run(main())
