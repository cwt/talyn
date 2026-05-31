import asyncio
import os

import talyn


def test_fork_safety():
    loop = talyn.Loop()
    asyncio.set_event_loop(loop)

    async def main():
        await asyncio.sleep(0.1)

        # Don't use pytest.warns context manager here because it can
        # interfere with child process state. We'll ignore the warning.
        import warnings

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            pid = os.fork()

        if pid == 0:
            # Child
            try:
                try:
                    # Any loop method should raise RuntimeError
                    loop.is_closed()
                    os._exit(1)  # Should have raised RuntimeError
                except RuntimeError as e:
                    if "fork" in str(e).lower():
                        os._exit(0)  # Success
                    else:
                        os._exit(2)
                except BaseException:
                    os._exit(3)
                os._exit(4)
            except:
                os._exit(5)
        else:
            # Parent
            _, status = os.waitpid(pid, 0)
            assert os.WIFEXITED(status)
            assert os.WEXITSTATUS(status) == 0

            # Parent should still be functional
            await asyncio.sleep(0.1)
            loop.stop()

    try:
        loop.run_until_complete(main())
    finally:
        loop.close()
        asyncio.set_event_loop(None)
