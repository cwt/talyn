"""BUG-416 regression gates: the exception-handler API quartet must be concrete.

Python 3.14+/3.15 turned every method of ``asyncio.events.AbstractEventLoop``
into an abstract stub raising ``NotImplementedError`` (the concrete-helpers
era is over). talyn's ``Loop`` implemented ``set``/``default``/``call``
exception handler but omitted ``get_exception_handler``, so every consumer
that snapshots the previous handler before installing its own —
``prompt_toolkit.set_exception_handler_ctx`` (application.py:827), used by
every TUI built on it — crashed at boot with ``NotImplementedError``.
"""

from __future__ import annotations

import pytest

import talyn
from talyn.loop import Loop

_HANDLER_METHODS = (
    "get_exception_handler",
    "set_exception_handler",
    "default_exception_handler",
    "call_exception_handler",
)


def test_exception_handler_quartet_is_concrete() -> None:
    """BUG-416: none of the four accessor methods may fall through to the
    AbstractEventLoop abstract stub (NotImplementedError). The definitive
    check is dynamic — invoke each one, do not scan text (a docstring that
    *mentions* NotImplementedError would false-positive a static scan)."""
    loop = Loop()
    try:
        stub_raises = []
        probes = {
            "get_exception_handler": lambda: loop.get_exception_handler(),
            "set_exception_handler": lambda: loop.set_exception_handler(None),
            "default_exception_handler": lambda: loop.default_exception_handler(
                {"message": "BUG-416 probe", "exception": RuntimeError("probe")}
            ),
            "call_exception_handler": lambda: loop.call_exception_handler(
                {"message": "BUG-416 probe", "exception": RuntimeError("probe")}
            ),
        }
        for name, invoke in probes.items():
            setattr(loop, "_user_exception_handler", None)
            try:
                invoke()
            except NotImplementedError:
                stub_raises.append(name)
        assert stub_raises == [], (
            f"{stub_raises} still raise the abstract stub (BUG-416 shape)"
        )
    finally:
        loop.close()


def test_get_exception_handler_returns_none_by_default() -> None:
    """asyncio.BaseEventLoop semantics: None while the default handler is
    in use (talyn keeps the default pre-bound internally for the Zig layer
    dispatch, but the getter must report the USER handler state)."""
    loop = Loop()
    try:
        assert loop.get_exception_handler() is None
    finally:
        loop.close()


def test_set_then_get_roundtrip_and_none_reset() -> None:
    calls: list[dict] = []

    def handler(loop, context: dict) -> None:  # type: ignore[no-untyped-def]
        calls.append(context)

    loop = Loop()
    try:
        loop.set_exception_handler(handler)
        assert loop.get_exception_handler() is handler
        loop.set_exception_handler(None)
        assert loop.get_exception_handler() is None
        # The default handler must still be dispatched (no raise, no call
        # into the reset user handler).
        loop.call_exception_handler({"message": "after-reset", "exception": RuntimeError("x")})
        assert calls == []
        with pytest.raises(TypeError):
            loop.set_exception_handler(object())  # type: ignore[arg-type]
    finally:
        loop.close()


def test_prompt_toolkit_snapshot_shape() -> None:
    """The PTK shape: get → (None ⇒ set own handler) → finally restore.
    Every branch must work without NotImplementedError."""
    loop = Loop()
    try:
        previous = loop.get_exception_handler()
        assert previous is None  # default in use → snapshot is None

        def ptk_handler(loop, context: dict) -> None:  # type: ignore[no-untyped-def]
            loop.default_exception_handler(context)

        loop.set_exception_handler(ptk_handler)
        try:
            assert loop.get_exception_handler() is ptk_handler
        finally:
            loop.set_exception_handler(previous)
        assert loop.get_exception_handler() is None
    finally:
        loop.close()


def test_exception_handler_sees_custom_context() -> None:
    contexts: list[dict] = []

    def handler(loop, context: dict) -> None:  # type: ignore[no-untyped-def]
        contexts.append(context)

    loop = Loop()
    try:
        loop.set_exception_handler(handler)
        loop.call_exception_handler(
            {"message": "BUG-416 custom dispatch", "exception": ValueError("boom")}
        )
        assert len(contexts) == 1
        assert contexts[0]["message"] == "BUG-416 custom dispatch"
        assert isinstance(contexts[0]["exception"], ValueError)
    finally:
        loop.close()
