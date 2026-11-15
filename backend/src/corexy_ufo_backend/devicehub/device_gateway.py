"""DeviceGateway - PC client for the UFO device hub (USB serial, JSON Lines).

The gateway is a *communication layer only*: it has no game logic. It

* opens the hub's serial port (auto-detect / auto-reconnect),
* establishes a fresh session (random session id) on every (re)connection,
* sends commands and resolves their ACKs (ACCEPTED / BUSY / TIMEOUT ...),
* receives events, ACKs them to the hub, removes duplicates (by event id)
  and drops events from older sessions,
* reports link changes (DEVICE_ONLINE / DEVICE_OFFLINE / ...).

While the hub is not connected, commands are rejected immediately
(``GatewayNotConnected``) - motion commands are never queued for later.

Threads: one I/O thread (serial read + heartbeat + reconnect) and one
dispatcher thread that calls subscriber callbacks, so a slow callback never
blocks the serial link.

Example::

    gw = DeviceGateway(port="auto")
    gw.subscribe(lambda ev: print(ev), names={"BALL_RECEIVED"})
    gw.connect()
    gw.set_light_mode("GAME_PLAY", brightness=180)
    gw.set_mode(DeviceId.M5DIAL_1, "GAME")
    gw.arm_receiver(DeviceId.M5DIAL_1)
"""

from __future__ import annotations

import asyncio
import logging
import queue
import random
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable
from concurrent.futures import Future
from typing import Protocol

from . import protocol as P
from .protocol import CommandResult, DeviceEvent, DeviceId, ProtocolError

log = logging.getLogger("ufo.gateway")


class GatewayError(RuntimeError):
    pass


class GatewayNotConnected(GatewayError):
    """No hub session: the command was NOT sent."""


class TransportError(IOError):
    """The serial link is gone (unplugged / port error)."""


class LineTransport(Protocol):
    """Line oriented byte transport. ``read_line`` returns None on timeout and
    raises TransportError when the link is lost."""

    def open(self) -> None: ...
    def close(self) -> None: ...
    def write_line(self, line: str) -> None: ...
    def read_line(self, timeout: float) -> str | None: ...


_PORT_HINTS = ("usbserial", "usbmodem", "SLAB", "wchusb", "ttyUSB", "ttyACM")


def guess_ports() -> list[str]:
    """Candidate hub ports, most likely first."""
    try:
        from serial.tools import list_ports
    except ImportError:  # pragma: no cover
        return []
    ports = [p.device for p in list_ports.comports()]
    usable = [d for d in ports if "Bluetooth" not in d and not d.startswith("/dev/tty.")]
    return [d for d in usable if any(h in d for h in _PORT_HINTS)] + [
        d for d in usable if not any(h in d for h in _PORT_HINTS)
    ]


def guess_port(exclude: Iterable[str] = ()) -> str | None:
    ex = set(exclude)
    for dev in guess_ports():
        if dev not in ex:
            return dev
    return None


class SerialLineTransport:
    """pyserial based transport with framing and a maximum line length."""

    def __init__(self, port: str = "auto", baudrate: int = 115200, max_line: int = 4096) -> None:
        self.port = port
        self.baudrate = baudrate
        self.max_line = max_line  # hub -> PC lines (DIAG can be ~1.5 kB)
        self._ser = None
        self._buf = bytearray()
        self._discarding = False
        self.oversize_lines = 0
        self.current_port: str | None = None
        self._rejected: set[str] = set()  # auto mode: hubs of another UFO system

    def reject_current(self) -> None:
        """Auto mode: the open port is the hub of another system - try the others."""
        if self.port == "auto" and self.current_port:
            self._rejected.add(self.current_port)

    def open(self) -> None:
        try:
            import serial
        except ImportError as e:  # pragma: no cover
            raise TransportError("pyserial is not installed (pip install -r pc/requirements.txt)") from e
        if self.port == "auto":
            port = guess_port(self._rejected)
            if not port and self._rejected:
                self._rejected.clear()  # every hub refused: start over (a hub may have been re-flashed)
                port = guess_port()
        else:
            port = self.port
        if not port:
            raise TransportError("no serial port found")
        self.current_port = port
        try:
            # timeouts: reads never block forever, writes fail instead of hanging
            self._ser = serial.Serial(port, self.baudrate, timeout=0.05, write_timeout=1.0)
            self._ser.reset_input_buffer()
        except (OSError, serial.SerialException) as e:
            raise TransportError(str(e)) from e
        self._buf.clear()
        self._discarding = False
        log.info("serial open %s @ %d", port, self.baudrate)

    def close(self) -> None:
        if self._ser is not None:
            try:
                self._ser.close()
            except Exception:  # pragma: no cover
                pass
        self._ser = None

    def write_line(self, line: str) -> None:
        if self._ser is None:
            raise TransportError("not open")
        try:
            self._ser.write(line.encode("ascii") + b"\n")
        except Exception as e:
            raise TransportError(str(e)) from e

    def read_line(self, timeout: float) -> str | None:
        if self._ser is None:
            raise TransportError("not open")
        deadline = time.monotonic() + timeout
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                raw = bytes(self._buf[:nl])
                del self._buf[: nl + 1]
                if self._discarding:
                    self._discarding = False
                    continue
                return raw.decode("utf-8", errors="replace").strip("\r")
            if len(self._buf) > self.max_line:
                self.oversize_lines += 1
                self._buf.clear()
                self._discarding = True
            if time.monotonic() >= deadline:
                return None
            try:
                chunk = self._ser.read(self._ser.in_waiting or 1)
            except Exception as e:
                raise TransportError(str(e)) from e
            if chunk:
                self._buf.extend(chunk)


class DeviceGateway:
    def __init__(
        self,
        port: str = "auto",
        *,
        transport: LineTransport | None = None,
        baudrate: int = 115200,
        command_timeout: float = 1.5,
        heartbeat_interval: float = 1.0,
        hub_timeout: float = 3.0,
        reconnect_interval: float = 1.0,
        event_dedup_size: int = 512,
        system_id: int | None = None,
        trace: Callable[..., None] | None = None,
    ) -> None:
        """system_id: the UFO system (1, 2) this game belongs to. The gateway then
        only attaches to that system's hub (the hub answers SYSTEM_MISMATCH
        otherwise; with port="auto" the other serial ports are tried)."""
        if system_id is not None and not 1 <= system_id <= P.MAX_SYSTEM_ID:
            raise ValueError(f"system_id must be 1..{P.MAX_SYSTEM_ID}")
        self.system_id = system_id
        # Game mode trace (pc/trace.py TraceLog.record or any callable(kind, **fields)):
        # one record per command sent, ACK and device event.
        self._trace = trace
        self._cycles: dict[int, int] = {}  # dial -> cycle of its last BALL_RECEIVED
        self._transport: LineTransport = transport or SerialLineTransport(port, baudrate)
        self.command_timeout = command_timeout
        self.heartbeat_interval = heartbeat_interval
        self.hub_timeout = hub_timeout
        self.reconnect_interval = reconnect_interval

        self._lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._stop = threading.Event()
        self._io_thread: threading.Thread | None = None
        self._dispatch_thread: threading.Thread | None = None
        self._events: queue.Queue[DeviceEvent | None] = queue.Queue(maxsize=1000)

        self._open = False
        self._session_id = 0
        self._session_ready = threading.Event()
        self._hello_sent_at = 0.0
        self._next_command_id = 1
        self._pending: dict[int, tuple[Future, str, int]] = {}
        self._requests: dict[str, list[Future]] = {}  # DEVICES / DIAG
        self._status_waiters: dict[int, list[Future]] = {}
        self._subscribers: list[tuple[Callable[[DeviceEvent], None], frozenset[str] | None]] = []
        self._seen_events: OrderedDict[tuple[int, int], None] = OrderedDict()
        self._dedup_size = event_dedup_size
        self._online: dict[int, bool] = {}
        self._last_status: dict[int, dict] = {}
        self._last_rx = 0.0
        self._last_hb = 0.0
        self._handshake_since = 0.0  # port opened / session lost: HELLO_ACK expected within hub_timeout
        self.hub_info: dict = {}
        self.stats = {"events": 0, "duplicate_events": 0, "stale_events": 0, "reconnects": 0, "bad_lines": 0}

    # ---- lifecycle ---------------------------------------------------------
    def connect(self, wait: bool = True, timeout: float = 5.0) -> bool:
        """Starts the I/O threads. With wait=True blocks until a session is up."""
        if self._io_thread and self._io_thread.is_alive():
            return self.wait_ready(timeout) if wait else True
        self._stop.clear()
        self._dispatch_thread = threading.Thread(target=self._dispatch_loop, name="ufo-gw-dispatch", daemon=True)
        self._dispatch_thread.start()
        self._io_thread = threading.Thread(target=self._io_loop, name="ufo-gw-io", daemon=True)
        self._io_thread.start()
        return self.wait_ready(timeout) if wait else True

    def wait_ready(self, timeout: float = 5.0) -> bool:
        return self._session_ready.wait(timeout)

    def disconnect(self) -> None:
        if self._open and self._session_id:
            try:
                self._write({"type": "BYE"})  # devices go to the safe state right away
            except Exception:
                pass
        self._stop.set()
        if self._io_thread:
            self._io_thread.join(timeout=2.0)
        self._events.put(None)
        if self._dispatch_thread:
            self._dispatch_thread.join(timeout=2.0)
        self._io_thread = self._dispatch_thread = None

    def __enter__(self) -> DeviceGateway:
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.disconnect()

    @property
    def connected(self) -> bool:
        return self._open and self._session_ready.is_set()

    @property
    def session_id(self) -> int:
        return self._session_id

    # ---- events ------------------------------------------------------------
    def subscribe(
        self, callback: Callable[[DeviceEvent], None], names: Iterable[str] | None = None
    ) -> Callable[[], None]:
        """Registers a callback (called on the dispatcher thread). Returns an
        unsubscribe function. ``names`` filters by event name."""
        entry = (callback, frozenset(names) if names is not None else None)
        with self._lock:
            self._subscribers.append(entry)

        def unsubscribe() -> None:
            with self._lock:
                if entry in self._subscribers:
                    self._subscribers.remove(entry)

        return unsubscribe

    def event_queue(self, names: Iterable[str] | None = None, maxsize: int = 1000) -> queue.Queue[DeviceEvent]:
        """Convenience: a thread-safe queue receiving the (filtered) events."""
        q: queue.Queue[DeviceEvent] = queue.Queue(maxsize=maxsize)
        self.subscribe(lambda ev: q.put_nowait(ev), names)
        return q

    def asyncio_queue(
        self, loop: asyncio.AbstractEventLoop, names: Iterable[str] | None = None
    ) -> asyncio.Queue[DeviceEvent]:
        """Events delivered into an asyncio.Queue of ``loop`` (thread-safe)."""
        q: asyncio.Queue[DeviceEvent] = asyncio.Queue()
        self.subscribe(lambda ev: loop.call_soon_threadsafe(q.put_nowait, ev), names)
        return q

    # ---- commands ----------------------------------------------------------
    def send_command(
        self,
        destination: int,
        name: str,
        params: dict | None = None,
        *,
        wait: bool = True,
        timeout: float | None = None,
    ) -> CommandResult | Future:
        """Sends one command. Returns the CommandResult (wait=True) or a Future.

        Raises ProtocolError for invalid parameters and GatewayNotConnected when
        there is no hub session (nothing is sent in both cases)."""
        if not self.connected:
            raise GatewayNotConnected(f"{name}: hub not connected")
        with self._lock:
            cid = self._next_command_id
            self._next_command_id = cid + 1 if cid + 1 < P.HUB_COMMAND_BIT else 1
            msg = P.command(int(destination), self._session_id, cid, name, params)
            fut: Future = Future()
            self._pending[cid] = (fut, name, int(destination))
        if name != "GET_STATUS":
            p = msg["params"]
            self._trace_record("command", source_dial=int(destination), command_id=cid, command=name,
                               cycle=self._cycles.get(int(destination)), effect_id=p.get("effect"),
                               rgb=p.get("color"), direction=p.get("direction"), params=p)
        try:
            self._write(msg)
        except TransportError as e:
            with self._lock:
                self._pending.pop(cid, None)
            raise GatewayNotConnected(str(e)) from e
        if not wait:
            return fut
        return self._wait_result(fut, cid, name, int(destination), timeout)

    def _trace_record(self, kind: str, **fields) -> None:
        if self._trace is None:
            return
        try:
            self._trace(kind, session_id=self._session_id, **fields)
        except Exception:  # tracing must never disturb the device control
            log.exception("trace sink failed")

    def _wait_result(self, fut: Future, cid: int, name: str, dest: int, timeout: float | None) -> CommandResult:
        try:
            return fut.result(timeout=timeout or self.command_timeout)
        except Exception:
            with self._lock:
                self._pending.pop(cid, None)
            return CommandResult(cid, dest, name, "NO_RESPONSE", origin="gateway")

    def get_devices(self, timeout: float = 1.0) -> list[dict]:
        return self._request("GET_DEVICES", "DEVICES", timeout).get("devices", [])

    def get_diagnostics(self, timeout: float = 1.0) -> dict:
        return self._request("GET_DIAG", "DIAG", timeout)

    def get_status(self, device_id: int, timeout: float = 1.0) -> dict:
        """Requests a fresh STATUS from one device."""
        fut: Future = Future()
        with self._lock:
            self._status_waiters.setdefault(int(device_id), []).append(fut)
        res = self.send_command(device_id, "GET_STATUS", timeout=timeout)
        if not res.ok:
            raise GatewayError(f"GET_STATUS {device_id:#x}: {res.result}")
        try:
            return fut.result(timeout=timeout)
        except Exception as e:
            raise GatewayError(f"GET_STATUS {device_id:#x}: no STATUS") from e

    def last_status(self, device_id: int) -> dict | None:
        return self._last_status.get(int(device_id))

    # Illumination ----------------------------------------------------------
    def set_light_mode(
        self,
        mode: str | P.LightMode,
        brightness: int = 128,
        transition_ms: int = 0,
        speed: int = 128,
        color: tuple[int, int, int] | str | None = None,
        device: int = DeviceId.ILLUMINATION,
        **kw,
    ) -> CommandResult:
        params = {"mode": mode, "brightness": brightness, "transition_ms": transition_ms, "speed": speed}
        if color is not None:
            params["color"] = color
        return self.send_command(device, "SET_LIGHT_MODE", params, **kw)

    def trigger_effect(
        self,
        effect: str | P.EffectId,
        duration_ms: int = 0,
        intensity: int = 255,
        device: int = DeviceId.ILLUMINATION,
        **kw,
    ) -> CommandResult:
        return self.send_command(
            device, "TRIGGER_EFFECT", {"effect": effect, "duration_ms": duration_ms, "intensity": intensity}, **kw
        )

    def relay_pulse(self, duration_ms: int, relay_id: int = 0, device: int = DeviceId.ILLUMINATION, **kw):
        return self.send_command(device, "RELAY_PULSE", {"relay_id": relay_id, "duration_ms": duration_ms}, **kw)

    def relay_off(self, relay_id: int = 255, device: int = DeviceId.ILLUMINATION, **kw) -> CommandResult:
        return self.send_command(device, "RELAY_OFF", {"relay_id": relay_id}, **kw)

    def set_mist(
        self,
        pattern: str | P.MistPattern = "CONTINUOUS",
        duration_s: int = 0,
        device: int = DeviceId.ILLUMINATION,
        **kw,
    ) -> CommandResult:
        """Mist module: CONTINUOUS / BREATH (8 s on, 6 s off) / PUFF (3 s on, 9 s off).

        duration_s = 0 runs up to the device maximum (10 min); longer requests are
        clamped. The end is reported by the MIST_DONE event. OFF stops it.
        """
        return self.send_command(device, "SET_MIST", {"pattern": pattern, "duration_s": duration_s}, **kw)

    def mist_off(self, device: int = DeviceId.ILLUMINATION, **kw) -> CommandResult:
        return self.send_command(device, "SET_MIST", {"pattern": "OFF"}, **kw)

    # M5Dial ------------------------------------------------------------------
    def set_mode(self, device_id: int, mode: str | P.OperationMode, **kw) -> CommandResult:
        """STANDBY / GAME. Dials accept ARM_RECEIVER / RELEASE_BALL only in GAME."""
        return self.send_command(device_id, "SET_MODE", {"mode": mode}, **kw)

    def arm_receiver(self, device_id: int, **kw) -> CommandResult:
        return self.send_command(device_id, "ARM_RECEIVER", **kw)

    def disarm_receiver(self, device_id: int, **kw) -> CommandResult:
        return self.send_command(device_id, "DISARM_RECEIVER", **kw)

    def release_ball(self, device_id: int, **kw) -> CommandResult:
        """ACCEPTED = the release sequence started. Completion is RELEASE_DONE
        (control sequence finished; it does not prove the ball physically left)."""
        return self.send_command(device_id, "RELEASE_BALL", **kw)

    def set_dial_effect(
        self,
        device_id: int,
        effect: str | P.DialEffect,
        direction: str | P.DialDirection = "NONE",
        color: tuple[int, int, int] | str | None = None,
        duration_ms: int = 0,
        priority: str | P.EffectPriority = "NORMAL",
        target: str | P.DialLedTarget = "BOTH",
        **kw,
    ) -> CommandResult:
        """LED effect on one dial (docs/game-mode-interface.md).

        effect: NONE (stop) / SOLID / BREATHE / CHASE / COMET / WIPE / FLASH / SPARKLE.
        direction: TO_SCREEN / TO_DIAL (required for CHASE, COMET, WIPE).
        color: None = the dial's unit colour. duration_ms = 0: until replaced or
        cleared by the device (ball detected, release finished, STOP_ALL, ...).
        target: FRONT (G1) / TRANSFER (G15 LED, NOT_CONFIGURED if not configured) /
        BOTH (front LED only when the G15 LED is not configured).
        A running effect of higher priority answers IGNORED_PRIORITY.
        """
        params = {"effect": effect, "direction": direction, "duration_ms": duration_ms, "priority": priority,
                  "target": target}
        if color is not None:
            params["color"] = color
        return self.send_command(device_id, "SET_DIAL_EFFECT", params, **kw)

    def clear_dial_effect(self, device_id: int, priority: str | P.EffectPriority = "HIGH",
                          target: str | P.DialLedTarget = "BOTH", **kw) -> CommandResult:
        """Stops the PC effect: the dial shows its own state display again."""
        return self.set_dial_effect(device_id, "NONE", priority=priority, target=target, **kw)

    def set_dial_color(self, device_id: int, color: tuple[int, int, int] | str | None = None, **kw) -> CommandResult:
        """Unit colour of one dial for this session (None / (0,0,0) = configured default)."""
        return self.send_command(device_id, "SET_DIAL_COLOR", {"color": color}, **kw)

    def stop_all(self, devices: Iterable[int] | None = None) -> dict[int, CommandResult]:
        targets = list(devices) if devices is not None else [d for d in DeviceId if d != DeviceId.HUB]
        futures = {}
        for d in targets:
            try:
                futures[int(d)] = self.send_command(d, "STOP_ALL", wait=False)
            except GatewayNotConnected as e:
                futures[int(d)] = e
        out = {}
        for d, f in futures.items():
            if isinstance(f, Exception):
                out[d] = CommandResult(0, d, "STOP_ALL", "NOT_CONNECTED", origin="gateway")
            else:
                try:
                    out[d] = f.result(timeout=self.command_timeout)
                except Exception:
                    out[d] = CommandResult(0, d, "STOP_ALL", "NO_RESPONSE", origin="gateway")
        return out

    def online(self, device_id: int) -> bool:
        return self._online.get(int(device_id), False)

    # ---- internals ---------------------------------------------------------
    def _write(self, msg: dict) -> None:
        line = P.encode_line(msg)
        with self._write_lock:
            self._transport.write_line(line)

    def _request(self, req_type: str, resp_type: str, timeout: float) -> dict:
        if not self._open:
            raise GatewayNotConnected(req_type)
        fut: Future = Future()
        with self._lock:
            self._requests.setdefault(resp_type, []).append(fut)
        self._write({"type": req_type})
        try:
            return fut.result(timeout=timeout)
        except Exception as e:
            raise GatewayError(f"{req_type}: no response") from e

    def _emit(self, ev: DeviceEvent) -> None:
        ev.received_at = ev.received_at or time.time()
        try:
            self._events.put_nowait(ev)
        except queue.Full:  # pragma: no cover
            log.error("event queue full, dropping %s", ev.name)

    def _dispatch_loop(self) -> None:
        while True:
            ev = self._events.get()
            if ev is None:
                return
            with self._lock:
                subs = list(self._subscribers)
            for cb, names in subs:
                if names is not None and ev.name not in names:
                    continue
                try:
                    cb(ev)
                except Exception:  # a subscriber must never kill the dispatcher
                    log.exception("event subscriber failed for %s", ev.name)

    def _new_session(self) -> None:
        with self._lock:
            if self._session_ready.is_set():
                self._handshake_since = time.monotonic()
            self._session_ready.clear()
            self._session_id = random.randint(1, 0xFFFFFFFF)
            self._next_command_id = random.randint(1, 0x3FFFFFFF)
            self._seen_events.clear()
            self._cycles.clear()
        self._hello_sent_at = time.monotonic()
        self._write(P.hello(self._session_id, self.system_id))

    def _fail_all_pending(self, why: str) -> None:
        with self._lock:
            pending, self._pending = self._pending, {}
            reqs, self._requests = self._requests, {}
            waiters, self._status_waiters = self._status_waiters, {}
        for cid, (fut, name, dest) in pending.items():
            if not fut.done():
                fut.set_result(CommandResult(cid, dest, name, why, origin="gateway"))
        for futs in list(reqs.values()) + list(waiters.values()):
            for f in futs:
                if not f.done():
                    f.set_exception(GatewayError(why))

    def _on_disconnected(self, reason: str) -> None:
        was_ready = self._session_ready.is_set()
        self._open = False
        self._session_ready.clear()
        try:
            self._transport.close()
        except Exception:  # pragma: no cover
            pass
        self._fail_all_pending("DISCONNECTED")
        if was_ready:
            log.warning("hub link lost: %s", reason)
            self._emit(DeviceEvent("GATEWAY_DISCONNECTED", None, {"reason": reason}))
            for dev, up in list(self._online.items()):
                if up:
                    self._emit(DeviceEvent("DEVICE_OFFLINE", dev, {"reason": "gateway_disconnected"}))
            self._online.clear()

    def _io_loop(self) -> None:
        while not self._stop.is_set():
            if not self._open:
                try:
                    self._transport.open()
                    self._open = True
                    self._last_rx = self._handshake_since = time.monotonic()
                    self._new_session()
                    self._last_hb = time.monotonic()
                except (TransportError, OSError) as e:
                    log.debug("connect failed: %s", e)
                    self._stop.wait(self.reconnect_interval)
                    continue
            try:
                line = self._transport.read_line(0.05)
                now = time.monotonic()
                if line and self._handle_line(line):
                    self._last_rx = now  # only hub protocol lines: a node's debug log is not a hub
                if now - self._last_hb >= self.heartbeat_interval:
                    self._last_hb = now
                    self._write({"type": "HEARTBEAT"})
                if not self._session_ready.is_set() and now - self._hello_sent_at > 1.0:
                    self._new_session()  # HELLO lost / hub still booting: retry
                if not self._session_ready.is_set() and now - self._handshake_since > self.hub_timeout:
                    # auto mode: the port answers but is not a hub (e.g. an ATOM or M5Dial on USB)
                    reject = getattr(self._transport, "reject_current", None)
                    if reject:
                        reject()
                    raise TransportError("no hub handshake on this port")
                if now - self._last_rx > self.hub_timeout:
                    raise TransportError("hub silent")
            except (TransportError, OSError) as e:
                self._on_disconnected(str(e))
                self.stats["reconnects"] += 1
                self._stop.wait(self.reconnect_interval)
        if self._open:
            self._open = False
            try:
                self._transport.close()
            except Exception:  # pragma: no cover
                pass
        self._session_ready.clear()
        self._fail_all_pending("DISCONNECTED")

    def _handle_line(self, line: str) -> bool:
        """Returns False for lines that are not hub protocol messages."""
        try:
            msg = P.decode_line(line)
        except ProtocolError as e:
            self.stats["bad_lines"] += 1
            log.debug("ignoring line %r: %s", line[:80], e)
            return False
        t = msg["type"]
        handler = getattr(self, f"_on_{t.lower()}", None)
        if handler:
            handler(msg)
        else:
            log.debug("unhandled %s", t)
        return True

    def _on_hello_ack(self, m: dict) -> None:
        if m.get("session_id") != self._session_id:
            return
        if self.system_id is not None and m.get("system_id") != self.system_id:
            # an old hub firmware that does not check HELLO.system_id itself
            self._wrong_system(f"hub reports system {m.get('system_id')}")
        self.hub_info = m
        if m.get("example_keys"):
            log.warning("hub reports EXAMPLE ESP-NOW KEYS - not for production (tests/tools/gen_secrets.py)")
        first = not self._session_ready.is_set()
        self._session_ready.set()
        if first:
            log.info("session %08x established (hub fw %s)", self._session_id, m.get("fw"))
            self._emit(DeviceEvent("GATEWAY_CONNECTED", None, {"session_id": self._session_id, "hub": m}))

    def _on_boot(self, m: dict) -> None:
        # The hub restarted: its session is gone. Re-establish ours.
        log.warning("hub rebooted (fw %s)", m.get("fw"))
        self._fail_all_pending("HUB_REBOOTED")
        self._new_session()

    def _on_session_closed(self, m: dict) -> None:
        if m.get("session_id") == self._session_id:
            self._emit(DeviceEvent("SESSION_CLOSED", None, {"reason": m.get("reason")}))
            self._fail_all_pending("SESSION_CLOSED")
            if not self._stop.is_set():
                self._new_session()

    def _on_ack(self, m: dict) -> None:
        cid = m.get("command_id")
        with self._lock:
            entry = self._pending.pop(cid, None)
        if not entry:
            return
        fut, name, dest = entry
        res = CommandResult(
            command_id=cid,
            destination=m.get("destination", dest),
            name=name,
            result=m.get("result", "UNKNOWN"),
            origin=m.get("origin", "hub"),
            duplicate=bool(m.get("duplicate")),
            clamped=bool(m.get("clamped")),
            attempts=int(m.get("attempts", 0) or 0),
            reason=m.get("reason"),
            raw=m,
        )
        if name != "GET_STATUS":
            self._trace_record("ack", source_dial=res.destination, command_id=cid, command=name, ack=res.result,
                               cycle=self._cycles.get(res.destination), duplicate=res.duplicate,
                               attempts=res.attempts)
        if not fut.done():
            fut.set_result(res)

    def _on_event(self, m: dict) -> None:
        src, eid = m.get("source"), m.get("event_id")
        if not isinstance(src, int) or not isinstance(eid, int):
            return
        # Always acknowledge, even duplicates / stale ones, so the hub stops resending.
        try:
            self._write(P.event_ack(src, eid))
        except TransportError:
            return
        if m.get("session_id") != self._session_id:
            self.stats["stale_events"] += 1
            log.info("dropping event %s from old session", m.get("name"))
            return
        key = (src, eid)
        with self._lock:
            if key in self._seen_events:
                self.stats["duplicate_events"] += 1
                return
            self._seen_events[key] = None
            while len(self._seen_events) > self._dedup_size:
                self._seen_events.popitem(last=False)
        self.stats["events"] += 1
        name, data = m.get("name", "UNKNOWN"), m.get("data", {}) or {}
        if name == "BALL_RECEIVED":
            self._cycles[src] = data.get("cycle")
        self._trace_record("event", source_dial=src, event_id=eid, event=name, cycle=self._cycles.get(src),
                           command_id=data.get("command_id"),
                           release_state=name[len("RELEASE_"):] if name.startswith("RELEASE_") else None, data=data)
        self._emit(DeviceEvent(m.get("name", "UNKNOWN"), src, m.get("data", {}), eid, m.get("session_id")))

    def _on_link(self, m: dict) -> None:
        src, up = m.get("source"), bool(m.get("online"))
        if self._online.get(src) == up:
            return
        self._online[src] = up
        self._emit(DeviceEvent("DEVICE_ONLINE" if up else "DEVICE_OFFLINE", src, {}))

    def _on_device_rebooted(self, m: dict) -> None:
        self._emit(DeviceEvent("DEVICE_REBOOTED", m.get("source"), {"boot_id": m.get("boot_id")}))

    def _on_device_error(self, m: dict) -> None:
        self._emit(DeviceEvent("ERROR", m.get("source"), {k: m.get(k) for k in ("code", "detail", "ref_seq")}))

    def _on_status(self, m: dict) -> None:
        src = m.get("source")
        self._last_status[src] = m
        with self._lock:
            waiters = self._status_waiters.pop(src, [])
        for f in waiters:
            if not f.done():
                f.set_result(m)

    def _resolve_request(self, kind: str, m: dict) -> None:
        with self._lock:
            futs = self._requests.pop(kind, [])
        for f in futs:
            if not f.done():
                f.set_result(m)

    def _on_devices(self, m: dict) -> None:
        for d in m.get("devices", []):
            if isinstance(d, dict) and "id" in d:
                was = self._online.get(d["id"])
                self._online[d["id"]] = bool(d.get("online"))
                if was is None and d.get("online"):
                    self._emit(DeviceEvent("DEVICE_ONLINE", d["id"], {}))
        self._resolve_request("DEVICES", m)

    def _on_diag(self, m: dict) -> None:
        self._resolve_request("DIAG", m)

    def _on_heartbeat(self, m: dict) -> None:
        sid = m.get("session_id")
        if self._session_ready.is_set() and sid not in (None, self._session_id):
            log.warning("hub session %s != ours: re-synchronising", sid)
            self._new_session()

    def _wrong_system(self, detail: str) -> None:
        log.error("this hub belongs to another UFO system (%s), want system %s", detail, self.system_id)
        reject = getattr(self._transport, "reject_current", None)
        if reject:
            reject()
        raise TransportError("hub of another UFO system")

    def _on_error(self, m: dict) -> None:
        if m.get("code") == "SYSTEM_MISMATCH":
            self._emit(DeviceEvent("HUB_ERROR", None, {"code": m.get("code"), "detail": m.get("detail")}))
            self._wrong_system(str(m.get("detail")))
        log.warning("hub error %s: %s", m.get("code"), m.get("detail"))
        self._emit(DeviceEvent("HUB_ERROR", None, {"code": m.get("code"), "detail": m.get("detail")}))

    def _on_log(self, m: dict) -> None:
        level = {"error": logging.ERROR, "warn": logging.WARNING}.get(m.get("level"), logging.INFO)
        log.log(level, "hub: %s", m.get("msg"))
