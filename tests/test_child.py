import asyncio
import signal
import subprocess
import time

import talyn


def test_child_handler():
    async def main():
        loop = asyncio.get_running_loop()
        
        # Create a child process that exits after a short delay
        proc = subprocess.Popen(['sleep', '0.1'])
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
        proc.wait() # Just to be clean

    talyn.run(main())

def test_child_handler_killed():
    async def main():
        loop = asyncio.get_running_loop()
        
        proc = subprocess.Popen(['sleep', '10'])
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
