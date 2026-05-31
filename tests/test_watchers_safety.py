
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
