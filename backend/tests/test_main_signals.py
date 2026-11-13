"""install_stop_handlers: Ctrl-C ends run() in order, also where the loop has no signal handlers (Windows)."""
from __future__ import annotations

import asyncio
import os
import signal

from corexy_ufo_backend.main import build_parser, install_stop_handlers, stop_when_closed


class _NoSignalLoop:
    """Stands in for the Windows event loop: add_signal_handler is not implemented."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    def add_signal_handler(self, *_args) -> None:
        raise NotImplementedError

    def call_soon_threadsafe(self, cb) -> None:
        self._loop.call_soon_threadsafe(cb)


def test_falls_back_to_signal_module_without_loop_handlers():
    saved = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}

    async def scenario() -> None:
        stop = asyncio.Event()
        install_stop_handlers(_NoSignalLoop(asyncio.get_running_loop()), stop)
        handler = signal.getsignal(signal.SIGINT)
        assert callable(handler) and handler is not saved[signal.SIGINT]
        handler(signal.SIGINT, None)  # what Ctrl-C would call
        await asyncio.wait_for(stop.wait(), 1.0)

    try:
        asyncio.run(scenario())
    finally:
        for sig, h in saved.items():
            signal.signal(sig, h)


def test_stdin_close_sets_stop():
    """start.ps1 closes the backend's stdin to stop it cleanly (Windows has no SIGTERM to send)."""
    async def scenario() -> None:
        stop = asyncio.Event()
        r, w = os.pipe()
        try:
            stop_when_closed(asyncio.get_running_loop(), stop, r)
            os.write(w, b"anything written is ignored\n")
            await asyncio.sleep(0.05)
            assert not stop.is_set()
            os.close(w)  # what start.ps1 does when the game closes
            await asyncio.wait_for(stop.wait(), 2.0)
        finally:
            os.close(r)

    asyncio.run(scenario())


def test_no_stdin_is_ignored():
    """No stdin at all (e.g. pythonw): keep running, Ctrl-C still stops it."""
    async def scenario() -> None:
        stop = asyncio.Event()
        stop_when_closed(asyncio.get_running_loop(), stop, None)
        await asyncio.sleep(0.05)
        assert not stop.is_set()

    asyncio.run(scenario())


def test_parser_has_the_option():
    assert build_parser().parse_args(["--mock", "--stop-on-stdin-close"]).stop_on_stdin_close
    assert not build_parser().parse_args(["--mock"]).stop_on_stdin_close
