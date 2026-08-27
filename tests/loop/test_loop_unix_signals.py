import os
import signal
from typing import Callable

import pytest

from talyn import Loop


def test_add_and_remove_signal_handler() -> None:
    loop = Loop()

    try:
        callback_called = False

        def signal_handler() -> None:
            nonlocal callback_called
            callback_called = True
            loop.stop()

        # Add signal handler
        loop.add_signal_handler(signal.SIGUSR1, signal_handler)

        # Schedule sending the signal
        loop.call_later(0.1, os.kill, os.getpid(), signal.SIGUSR1)

        # Run the loop
        loop.run_forever()

        assert callback_called, "Signal handler was not called"

        # Remove signal handler
        loop.remove_signal_handler(signal.SIGUSR1)

        # Try to remove again, should return False
        assert not loop.remove_signal_handler(signal.SIGUSR1), (
            "Removing non-existent handler should return False"
        )

    finally:
        loop.close()


def test_remove_signal_handler_not_registered() -> None:
    loop = Loop()

    try:
        # Try to remove a signal handler that was never added
        assert not loop.remove_signal_handler(signal.SIGUSR2), (
            "Removing non-existent handler should return False"
        )

    finally:
        loop.close()


def test_sigint_does_not_stop_loop() -> None:
    loop = Loop()

    try:
        interrupt_received = False
        loop_iterations = 0

        def sigint_handler() -> None:
            nonlocal interrupt_received
            interrupt_received = True

        def periodic_task() -> None:
            nonlocal loop_iterations
            loop_iterations += 1
            if loop_iterations >= 3:
                loop.stop()
                return
            loop.call_soon(periodic_task)

        # Add SIGINT handler that doesn't stop the loop
        loop.add_signal_handler(signal.SIGINT, sigint_handler)

        # Schedule periodic task and signal
        loop.call_later(0.1, os.kill, os.getpid(), signal.SIGINT)
        loop.call_later(0.2, periodic_task)

        # Run the loop
        loop.run_forever()

        assert interrupt_received, "SIGINT was not received"
        assert loop_iterations == 3, "Loop was unexpectedly stopped by SIGINT"

        # Remove signal handler
        assert loop.remove_signal_handler(signal.SIGINT), (
            "Failed to remove SIGINT handler"
        )

    finally:
        loop.close()


def test_add_signal_handler_invalid_signal() -> None:
    loop = Loop()

    try:
        with pytest.raises(ValueError):
            loop.add_signal_handler(-1, lambda: None)

    finally:
        loop.close()


def test_multiple_signal_handlers() -> None:
    loop = Loop()

    try:
        handlers_called = set()

        def make_handler(sig: signal.Signals) -> Callable[[], None]:
            def handler() -> None:
                handlers_called.add(sig)
                if len(handlers_called) == 2:
                    loop.stop()

            return handler

        # Add signal handlers
        loop.add_signal_handler(signal.SIGUSR1, make_handler(signal.SIGUSR1))
        loop.add_signal_handler(signal.SIGUSR2, make_handler(signal.SIGUSR2))

        # Schedule sending the signals
        loop.call_later(0.1, os.kill, os.getpid(), signal.SIGUSR1)
        loop.call_later(0.2, os.kill, os.getpid(), signal.SIGUSR2)

        # Run the loop
        loop.run_forever()

        assert handlers_called == {signal.SIGUSR1, signal.SIGUSR2}, (
            "Not all signal handlers were called"
        )

        # Remove signal handlers
        assert loop.remove_signal_handler(signal.SIGUSR1), (
            "Failed to remove SIGUSR1 handler"
        )
        assert loop.remove_signal_handler(signal.SIGUSR2), (
            "Failed to remove SIGUSR2 handler"
        )

    finally:
        loop.close()


class _Bug306Machine:
    """Single-session driver for the BUG-306 regression suite.

    Runs entirely inside one run_forever via chained call_soon steps so
    every send/deliver round-trip is deterministic (one outstanding
    standard signal at a time — no coalescing ambiguity).
    """

    CYCLES = 9

    def __init__(self, loop: Loop) -> None:
        self.loop = loop
        self.delivered = 0
        self.cycle = 0
        self.failed = False

    # ---- entry / watchdog -------------------------------------------------

    def start(self) -> None:
        self.loop.call_later(10.0, self._watchdog)
        self.loop.call_soon(self._register)

    def _watchdog(self) -> None:
        self.failed = True
        self.loop.stop()

    def _handler(self) -> None:
        self.delivered += 1

    # ---- cycle steps (chained via call_soon) ------------------------------

    def _register(self) -> None:
        """Phase A: register handler, then kill synchronously right after."""
        self.loop.add_signal_handler(signal.SIGUSR1, self._handler)
        os.kill(os.getpid(), signal.SIGUSR1)
        self.loop.call_soon(self._settle_after_kill)
        # Second idle tick guarantees the signalfd read + dispatch drained.
        self.loop.call_later(0.001, self._check_delivered)

    def _settle_after_kill(self) -> None:
        pass  # pure wait step; logic lives in _check_delivered

    def _check_delivered(self) -> None:
        expected = self._cycles_with_delivery()
        assert self.delivered == expected, (
            f"cycle {self.cycle}: delivered {self.delivered}, "
            f"expected {expected}; signals were lost across register "
            f"cycles (BUG-306)"
        )
        if self.cycle % 3 == 2:
            self._remove_and_send()
        else:
            self._next_cycle()

    def _remove_and_send(self) -> None:
        """Phase B: remove handler, send while disarmed, expect silence."""
        assert self.loop.remove_signal_handler(signal.SIGUSR1)
        baseline = self.delivered
        os.kill(os.getpid(), signal.SIGUSR1)

        def check_silent() -> None:
            assert self.delivered == baseline, (
                f"removed-signal handler fired anyway "
                f"({self.delivered} > {baseline})"
            )
            self._next_cycle()

        self.loop.call_later(0.001, check_silent)

    def _cycles_with_delivery(self) -> int:
        return self.cycle + 1

    def _next_cycle(self) -> None:
        self.cycle += 1
        if self.cycle >= self.CYCLES:
            self.loop.stop()
            return
        self.loop.call_soon(self._register)


def test_bug306_no_signal_loss_across_register_send_deliver_cycles() -> None:
    """BUG-306 integration guard: register/send/deliver churn stays lossless.

    Drives repeated add->kill->deliver->(remove|re-add) cycles inside a
    single run_forever session. Every delivery-capable cycle must deliver
    exactly once; disarmed-cycle sends must stay silent. A reintroduced
    lost-signal window or broken relink surfaces as a delivery shortfall;
    any crash inside the reordered teardown surfaces as nonzero exit.
    """
    loop = Loop()
    try:
        machine = _Bug306Machine(loop)
        machine.start()
        loop.run_forever()
        assert not machine.failed, "BUG-306 watchdog tripped (stalled loop)"
        # Every cycle contributes exactly one active-handler delivery; the
        # per-cycle silent-check inside _remove_and_send independently proves
        # disarmed sends fire nothing.
        assert machine.delivered == _Bug306Machine.CYCLES, (
            f"delivered {machine.delivered}, expected exactly "
            f"{_Bug306Machine.CYCLES} across {_Bug306Machine.CYCLES} "
            f"cycles"
        )
    finally:
        loop.close()


def test_bug306_kill_immediately_after_add_is_never_lost() -> None:
    """The tightest external approximation of the link-window race.

    Raises the signal synchronously right after add_signal_handler returns,
    across several fresh loops. Under the fixed ordering every occurrence is
    either already-blocked-and-pending (drained via signalfd once armed) or
    fully covered — none may vanish. Also guards that the reordered link()
    leaves a fully functional delivery pipeline on every variant build,
    including free-threaded ones.
    """
    for attempt in range(5):
        loop = Loop()
        try:
            got = []

            def handler() -> None:
                got.append(1)
                loop.stop()

            loop.add_signal_handler(signal.SIGUSR2, handler)
            os.kill(os.getpid(), signal.SIGUSR2)
            # Guard rail so a regression cannot hang the runner forever.
            loop.call_later(5.0, loop.stop)
            loop.run_forever()
            assert len(got) == 1, (
                f"attempt {attempt}: handler fired {len(got)} times "
                f"(expected exactly 1); BUG-306 relink path regressed"
            )
        finally:
            loop.close()
