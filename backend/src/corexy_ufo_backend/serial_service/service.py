"""SerialService: request/response layer on top of SerialTransport.

Implements the firmware's "queue mode" handshake observed in
tools/serial_tool/serial_send.py:  send line -> wait `ACK QUEUED <CMD>`
(retry on `ERROR: CommandQueue full`) -> wait for the command's completion
line (ACK_XY / HOME complete / POS / SERVO_TURN id=.. result= ...).

The firmware executes commands strictly one at a time, so this service also
serialises callers with a lock. A command that is still executing on the
machine cannot be observed mid-way (no live position during a move).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field

from . import protocol as P
from .transport import SerialTransport, guess_port

log = logging.getLogger(__name__)


class SerialError(Exception):
    pass


class CommandTimeout(SerialError):
    pass


class CommandRejected(SerialError):
    def __init__(self, line: str) -> None:
        super().__init__(line)
        self.line = line


@dataclass
class CommandResult:
    command: str
    queued: bool
    completion: str | None
    lines: list[str] = field(default_factory=list)
    elapsed_s: float = 0.0

    @property
    def failed(self) -> bool:
        return any(P.is_failure_line(l) for l in self.lines)


class SerialService:
    def __init__(self, port: str | None = None, baudrate: int = 115200, *, log_size: int = 500,
                 transport_factory: Callable[..., SerialTransport] | None = None) -> None:
        self.port = port
        self.baudrate = baudrate
        self._transport_factory = transport_factory or SerialTransport
        self.transport: SerialTransport | None = None
        self.connected = False
        self.last_error: str = ""
        self.log_lines: deque[str] = deque(maxlen=log_size)
        self._lock = asyncio.Lock()
        self._listeners: list[Callable[[str], None]] = []
        self._disconnect_cb: Callable[[], None] | None = None
        self._pump_task: asyncio.Task | None = None
        self._waiters: list[tuple[Callable[[str], bool], asyncio.Future]] = []
        self.last_pos: P.PosReport | None = None

    # ------------------------------------------------------------- lifecycle
    def add_listener(self, cb: Callable[[str], None]) -> None:
        self._listeners.append(cb)

    def set_disconnect_callback(self, cb: Callable[[], None]) -> None:
        self._disconnect_cb = cb

    async def connect(self, *, startup_delay: float = 0.3, drain_s: float = 0.5) -> None:
        port = self.port or guess_port()
        if not port and self._transport_factory is SerialTransport:
            raise SerialError("no serial port found")
        self.port = port or "fake"
        t = self._transport_factory(self.port, self.baudrate, startup_delay=startup_delay, on_disconnect=self._on_transport_lost)
        t.tx_log = lambda l: self._log("TX " + l)
        await t.open()
        self.transport = t
        self.connected = True
        self._pump_task = asyncio.create_task(self._pump())
        # Drain whatever the firmware prints on open (boot banner etc).
        await asyncio.sleep(drain_s)

    async def disconnect(self) -> None:
        self.connected = False
        if self._pump_task:
            self._pump_task.cancel()
            self._pump_task = None
        if self.transport:
            await self.transport.close()
            self.transport = None
        self._fail_waiters(SerialError("disconnected"))

    def _on_transport_lost(self, err: Exception | None) -> None:
        self.last_error = f"serial lost: {err}"
        self.connected = False
        self._fail_waiters(SerialError(self.last_error))
        if self._disconnect_cb:
            self._disconnect_cb()

    def _fail_waiters(self, exc: Exception) -> None:
        for _, fut in self._waiters:
            if not fut.done():
                fut.set_exception(exc)
        self._waiters.clear()

    def _log(self, line: str) -> None:
        self.log_lines.append(f"{time.strftime('%H:%M:%S')} {line}")

    async def _pump(self) -> None:
        assert self.transport is not None
        q = self.transport.lines
        while True:
            line = await q.get()
            self._log("RX " + line)
            if line.startswith("POS "):
                pos = P.parse_pos_line(line)
                if pos:
                    self.last_pos = pos
            for cb in list(self._listeners):
                try:
                    cb(line)
                except Exception:  # pragma: no cover
                    log.exception("listener failed")
            for item in list(self._waiters):
                pred, fut = item
                if fut.done():
                    self._waiters.remove(item)
                    continue
                try:
                    if pred(line):
                        fut.set_result(line)
                        self._waiters.remove(item)
                except Exception as e:  # pragma: no cover
                    fut.set_exception(e)
                    self._waiters.remove(item)

    def _register(self, pred: Callable[[str], bool]) -> asyncio.Future:
        """Register a waiter BEFORE sending so a fast reply cannot be missed."""
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._waiters.append((pred, fut))
        return fut

    async def _await(self, fut: asyncio.Future, timeout: float) -> str:
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError as e:
            self._waiters = [(p, f) for (p, f) in self._waiters if f is not fut]
            raise CommandTimeout(f"timeout after {timeout}s") from e

    async def _wait_for(self, pred: Callable[[str], bool], timeout: float) -> str:
        return await self._await(self._register(pred), timeout)

    # ------------------------------------------------------------- commands
    def write_raw(self, line: str) -> None:
        """Fire-and-forget (used for ABORT where we must not wait on the lock)."""
        P.validate_line(line)
        if not self.transport or not self.connected:
            raise SerialError("not connected")
        self.transport.write_line(line)

    async def send(self, command: str, *, completion: re.Pattern[str] | None = None,
                   timeout: float = 10.0, queue_retries: int = 20) -> CommandResult:
        """Send one command and wait for queue ACK, then (optionally) completion."""
        P.validate_line(command)
        if not self.transport or not self.connected:
            raise SerialError("not connected")
        name = command.split()[0].upper()
        if completion is None:
            completion = P.COMPLETION_PATTERNS.get(name)
        t0 = time.monotonic()
        async with self._lock:
            collected: list[str] = []
            collector = collected.append
            self.add_listener(collector)
            try:
                queued = False
                ack_re = re.compile(rf"^ACK (QUEUED {re.escape(name)}\b|ABORT requested)|^ERROR: ")
                done_fut: asyncio.Future | None = None
                for _attempt in range(queue_retries):
                    ack_fut = self._register(lambda l: bool(ack_re.match(l)))
                    if completion is not None and done_fut is None:
                        done_fut = self._register(lambda l: bool(completion.match(l)))
                    self.transport.write_line(command)
                    line = await self._await(ack_fut, timeout=3.0)
                    if line == P.QUEUE_FULL:
                        await asyncio.sleep(0.1)
                        continue
                    if line.startswith("ERROR:"):
                        if done_fut is not None:
                            self._waiters = [(p, f) for (p, f) in self._waiters if f is not done_fut]
                        raise CommandRejected(line)
                    queued = True
                    break
                if not queued:
                    raise CommandRejected(P.QUEUE_FULL)
                done_line: str | None = None
                if done_fut is not None:
                    done_line = await self._await(done_fut, timeout=timeout)
                return CommandResult(command, queued, done_line, collected, time.monotonic() - t0)
            finally:
                self._listeners.remove(collector)

    # convenience wrappers ------------------------------------------------------
    async def query_pos(self, timeout: float = 5.0) -> P.PosReport:
        r = await self.send("POS", timeout=timeout)
        pos = P.parse_pos_line(r.completion or "")
        if not pos:
            raise SerialError("bad POS line")
        return pos

    async def servo_status(self, servo_id: int, timeout: float = 5.0) -> P.ServoStatus:
        r = await self.send(P.cmd_servo_status(servo_id), timeout=timeout)
        st = P.parse_servo_status(r.completion or "")
        if not st:
            raise SerialError("bad SERVO_STATUS line")
        return st

    async def abort(self) -> None:
        """Emergency stop. Sent outside the lock so it can interrupt a move."""
        self.write_raw("ABORT")
        try:
            await self._wait_for(lambda l: l.startswith("ABORT complete"), timeout=5.0)
        except CommandTimeout:
            log.warning("ABORT not confirmed")
