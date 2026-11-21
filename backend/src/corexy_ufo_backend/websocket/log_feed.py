"""GameServer's log feed: the serial lines and the backend's own log lines, sent to the game
as {"type": "log"} messages."""

from __future__ import annotations

import asyncio
import logging

from .wire import now_ms

log = logging.getLogger(__package__ + ".server")

# Serial lines not forwarded to the game's log (periodic position reports).
SERIAL_LOG_SKIP = ("TX POS", "RX POS ", "RX JOG_POS ")
LOG_QUEUE_MAX = 500


class LogFeedMixin:
    # ------------------------------------------------------------ log feed
    def _start_log_feed(self) -> None:
        self._log_loop_ref = asyncio.get_running_loop()
        self._log_queue = asyncio.Queue(maxsize=LOG_QUEUE_MAX)
        server = self

        class _Forward(logging.Handler):
            def emit(self, record: logging.LogRecord) -> None:
                # may come from a vision thread: hand it to the event loop
                server._queue_log_threadsafe(f"[backend] {record.levelname} {record.getMessage()}")

        self._log_handler = _Forward(level=logging.INFO)
        logging.getLogger("corexy_ufo_backend").addHandler(self._log_handler)
        serial = getattr(self.robot, "serial", None)
        if serial is not None and hasattr(serial, "log_listeners"):
            serial.log_listeners.append(self._on_serial_log)
        self._tasks.append(asyncio.create_task(self._log_loop()))

    def _stop_log_feed(self) -> None:
        if self._log_handler is not None:
            logging.getLogger("corexy_ufo_backend").removeHandler(self._log_handler)
            self._log_handler = None
        serial = getattr(self.robot, "serial", None)
        if serial is not None and self._on_serial_log in getattr(serial, "log_listeners", []):
            serial.log_listeners.remove(self._on_serial_log)

    def _on_serial_log(self, line: str) -> None:
        # POS / JOG_POS come many times a second and say nothing new; a held key
        # resends the same JOG line at 20 Hz: show a JOG only when it changes
        if line.startswith(SERIAL_LOG_SKIP):
            return
        if line.startswith("TX JOG "):
            if line == self._last_tx_jog:
                return
            self._last_tx_jog = line
        self._queue_log_threadsafe("[serial] " + line)

    def _queue_log(self, line: str) -> None:
        if self._log_queue is not None and not self._log_queue.full():
            self._log_queue.put_nowait(line)

    def _queue_log_threadsafe(self, line: str) -> None:
        try:
            self._log_loop_ref.call_soon_threadsafe(self._queue_log, line)
        except RuntimeError:  # pragma: no cover - loop closed
            pass

    async def _log_loop(self) -> None:
        assert self._log_queue is not None
        while True:
            line = await self._log_queue.get()
            await self.broadcast({"type": "log", "timestamp": now_ms(), "data": {"line": line}})
