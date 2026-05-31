import asyncio

import talyn


def test_lru_cache():
    async def main():
        loop = asyncio.get_running_loop()
        # This calls the Zig internal test logic
        loop._test_lru()

    talyn.run(main())
