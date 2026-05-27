import asyncio
import talyn
import pytest
import os
import tempfile

def test_path_watcher():
    async def main():
        loop = asyncio.get_running_loop()
        
        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, 'test.txt')
            
            events = []
            def callback(mask, cookie, name):
                events.append((mask, name))
                
            # IN_MODIFY = 2, IN_CREATE = 256, IN_DELETE = 512
            mask = 2 | 256 | 512
            handle = loop._add_path_watcher(tmpdir, mask, callback)
            
            # Create file
            with open(file_path, 'w') as f:
                f.write('hello')
                
            # Yield to let inotify events process
            await asyncio.sleep(0.1)
            
            # Modify file
            with open(file_path, 'a') as f:
                f.write(' world')
                
            await asyncio.sleep(0.1)
            
            # Delete file
            os.remove(file_path)
            
            await asyncio.sleep(0.1)
            
            # Check events
            # We expect at least CREATE, MODIFY, DELETE
            # Note: inotify might send multiple MODIFY events
            masks = [e[0] for e in events]
            names = [e[1] for e in events]
            
            assert 256 in masks # IN_CREATE
            assert 2 in masks   # IN_MODIFY
            assert 512 in masks # IN_DELETE
            assert 'test.txt' in names
            
            handle.cancel()

    talyn.run(main())
