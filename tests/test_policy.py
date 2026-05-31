import asyncio
import warnings

import talyn


def test_install():
    # Save original policy
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        old_policy = asyncio.get_event_loop_policy()
    try:
        talyn.install()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            policy = asyncio.get_event_loop_policy()
        assert isinstance(policy, talyn.EventLoopPolicy)
        
        loop = asyncio.new_event_loop()
        try:
            assert isinstance(loop, talyn.Loop)
        finally:
            loop.close()
    finally:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            asyncio.set_event_loop_policy(old_policy)

def test_policy_new_event_loop():
    policy = talyn.EventLoopPolicy()
    loop = policy.new_event_loop()
    try:
        assert isinstance(loop, talyn.Loop)
    finally:
        loop.close()
