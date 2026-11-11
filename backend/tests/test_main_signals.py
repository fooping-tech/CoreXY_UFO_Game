"""install_stop_handlers: Ctrl-C ends run() in order, also where the loop has no signal handlers (Windows)."""
from __future__ import annotations

import asyncio
import signal

from corexy_ufo_backend.main import install_stop_handlers


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
