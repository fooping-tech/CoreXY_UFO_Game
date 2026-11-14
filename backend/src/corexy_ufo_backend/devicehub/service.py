"""The device hub for this game (#108): the settings screen's テスト tab drives it over the
WebSocket, through the very DeviceGateway UFO-DeviceHub's own test console uses (sessions,
ACKs, retries, EVENT_ACK).

The hub's own auto-detect opens every USB serial port in turn and sends HELLO lines to it:
here the robot's (Core2) ports are never tried, so it never writes to the crane's firmware,
and the hub's port is opened exclusively. Gateway calls block (they wait for the ACK), so they
run in a worker thread; events come back on the asyncio loop.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Iterable
from dataclasses import asdict, dataclass
from typing import Any

from . import protocol as P
from .device_gateway import DeviceGateway, GatewayError, GatewayNotConnected, SerialLineTransport, TransportError, guess_port
from .protocol import CommandResult, DeviceEvent, ProtocolError

log = logging.getLogger(__name__)

__all__ = ["DeviceHubConfig", "DeviceHubService", "DeviceHubError", "ExcludingSerialTransport"]


class DeviceHubError(RuntimeError):
    """A request the hub cannot serve now (the message says why, for the テスト tab)."""


@dataclass(frozen=True)
class DeviceHubConfig:
    enabled: bool = False
    port: str = "auto"  # "auto" (never the robot's ports), a port name, or "mock" (no hardware)
    system_id: int = 1  # which UFO system's hub (1 / 2): another system's hub is refused

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "DeviceHubConfig":
        d = raw.get("devicehub") if isinstance(raw.get("devicehub"), dict) else {}
        try:
            system_id = int(d.get("system_id", 1))
        except (TypeError, ValueError):
            system_id = 1
        return cls(enabled=bool(d.get("enabled", False)), port=str(d.get("port", "auto") or "auto").strip(),
                   system_id=system_id if 1 <= system_id <= P.MAX_SYSTEM_ID else 1)


class ExcludingSerialTransport(SerialLineTransport):
    """The gateway's serial transport, but auto-detect never opens `exclude` (the robot's ports)
    and the port is opened exclusively (no second program on the hub)."""

    def __init__(self, port: str, baudrate: int = 115200, exclude: Iterable[str] = ()) -> None:
        super().__init__(port, baudrate)
        self.exclude = {p for p in exclude if p}

    def open(self) -> None:
        try:
            import serial
        except ImportError as e:  # pragma: no cover
            raise TransportError("pyserial is not installed") from e
        if self.port == "auto":
            port = guess_port(self._rejected | self.exclude)
            if not port and self._rejected:
                self._rejected.clear()  # every hub refused: start over (never the robot's ports)
                port = guess_port(self.exclude)
        else:
            port = self.port
            if port in self.exclude:
                raise TransportError(f"{port} is the robot's (Core2) port, not the hub's")
        if not port:
            raise TransportError("no serial port found for the hub (the robot's ports are not tried)")
        self.current_port = port
        try:
            self._ser = serial.Serial(port, self.baudrate, timeout=0.05, write_timeout=1.0, exclusive=True)
            self._ser.reset_input_buffer()
        except (OSError, serial.SerialException, ValueError) as e:
            raise TransportError(f"{port}: {e} (another program, e.g. pc.web_console, may have it open)") from e
        self._buf.clear()
        self._discarding = False


def result_dict(r: CommandResult) -> dict:
    d = asdict(r)
    d.pop("raw", None)
    d["ok"] = r.ok
    return d


def event_dict(e: DeviceEvent) -> dict:
    d = asdict(e)
    d["time"] = time.strftime("%H:%M:%S", time.localtime()) + f".{int(time.time() * 1000) % 1000:03d}"
    return d


def enums() -> dict:
    """The names the テスト tab offers, from protocol.py (as UFO-DeviceHub's console)."""
    return {
        "light_modes": [m.name for m in P.LightMode],
        "effects": [e.name for e in P.EffectId if e != P.EffectId.NONE],
        "mist_patterns": [m.name for m in P.MistPattern],
        "devices": [{"id": int(d), "name": d.name} for d in P.DeviceId if d != P.DeviceId.HUB],
    }


class DeviceHubService:
    def __init__(self, config: DeviceHubConfig, *, exclude_ports: Iterable[str] = (), transport=None) -> None:
        self.config = config
        if transport is None and config.port == "mock":
            from .mock_hub import MockConfig, MockHub
            transport = MockHub(MockConfig(system_id=config.system_id))
        if transport is None:
            transport = ExcludingSerialTransport(config.port or "auto", exclude=exclude_ports)
        self.transport = transport
        self.gw = DeviceGateway(transport=transport, system_id=config.system_id)
        self._unsubscribe: Callable[[], None] | None = None

    def start(self, on_event: Callable[[dict], Awaitable[None]]) -> None:
        """Opens the hub in the background (reconnects by itself); events go to on_event."""
        loop = asyncio.get_running_loop()

        def forward(ev: DeviceEvent) -> None:  # the gateway's dispatcher thread
            d = event_dict(ev)
            try:
                loop.call_soon_threadsafe(lambda: asyncio.ensure_future(on_event(d)))
            except RuntimeError:  # the loop is closed: shutting down
                pass
        self._unsubscribe = self.gw.subscribe(forward)
        self.gw.connect(wait=False)
        log.info("device hub: system %d, port %s", self.config.system_id, self.config.port)

    def close(self) -> None:
        if self._unsubscribe is not None:
            self._unsubscribe()
            self._unsubscribe = None
        self.gw.disconnect()

    # ---- requests (async: the gateway blocks until the hub answers) -----------------
    def meta(self) -> dict:
        port = getattr(self.transport, "current_port", None) or self.config.port
        return {"system_id": self.config.system_id, "port": port, "connected": self.gw.connected,
                "session_id": self.gw.session_id if self.gw.connected else 0, "hub": self.gw.hub_info,
                "enums": enums()}

    async def _call(self, fn: Callable[[], Any]) -> Any:
        try:
            return await asyncio.to_thread(fn)
        except GatewayNotConnected as e:
            raise DeviceHubError(f"ハブにつながっていない: {e}") from e
        except (GatewayError, ProtocolError) as e:
            raise DeviceHubError(str(e)) from e

    async def devices(self) -> list[dict]:
        return await self._call(self.gw.get_devices)

    async def diag(self) -> dict:
        return await self._call(self.gw.get_diagnostics)

    async def status(self, device: int) -> dict:
        return await self._call(lambda: self.gw.get_status(int(device)))

    async def command(self, device: Any, name: Any, params: Any) -> dict:
        if not isinstance(device, int) or isinstance(device, bool) or not isinstance(name, str) \
                or not isinstance(params, dict):
            raise DeviceHubError("device (int), name (str) and params (object) are needed")
        return result_dict(await self._call(lambda: self.gw.send_command(device, name, params)))

    async def stop_all(self) -> dict:
        return {str(k): result_dict(v) for k, v in (await self._call(self.gw.stop_all)).items()}
