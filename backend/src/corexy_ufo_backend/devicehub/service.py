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

from ufo_devicehub import (
    CommandResult,
    DeviceEvent,
    DeviceGateway,
    GatewayError,
    GatewayNotConnected,
    MockConfig,
    MockHub,
    ProtocolError,
    SerialLineTransport,
    TraceLog,
)
from ufo_devicehub import protocol as P

log = logging.getLogger(__name__)

__all__ = ["DeviceHubConfig", "DeviceHubService", "DeviceHubError", "ExcludingSerialTransport"]


class DeviceHubError(RuntimeError):
    """A request the hub cannot serve now (the message says why, for the テスト tab)."""


@dataclass(frozen=True)
class DeviceHubConfig:
    enabled: bool = False
    port: str = "auto"  # "auto" (never the robot's ports), a port name, or "mock" (no hardware)
    system_id: int = 1  # which UFO system's hub (1 / 2): another system's hub is refused
    # a JSON Lines file for UFO-DeviceHub's trace (every command, ACK and event; pc/trace.py), "" = none.
    # It joins with the game's own trace by session / dial / cycle / command id (#138).
    trace: str = ""

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "DeviceHubConfig":
        d = raw.get("devicehub") if isinstance(raw.get("devicehub"), dict) else {}
        try:
            system_id = int(d.get("system_id", 1))
        except (TypeError, ValueError):
            system_id = 1
        return cls(enabled=bool(d.get("enabled", False)), port=str(d.get("port", "auto") or "auto").strip(),
                   system_id=system_id if 1 <= system_id <= P.MAX_SYSTEM_ID else 1,
                   trace=str(d.get("trace", "") or "").strip())


class ExcludingSerialTransport(SerialLineTransport):
    """The gateway's serial transport as this game opens it: auto-detect never opens `exclude`
    (the robot's ports), naming one of them is refused, and the port is opened exclusively (no
    second program on the hub). All of it is UFO-DeviceHub's own SerialLineTransport (its
    `exclude` and `exclusive`): nothing of the transport is written again here."""

    def __init__(self, port: str, baudrate: int = 115200, exclude: Iterable[str] = ()) -> None:
        super().__init__(port, baudrate, exclude=exclude, exclusive=True)


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
        "dial_effects": [e.name for e in P.DialEffect],
        "dial_directions": [d.name for d in P.DialDirection],
        "dial_priorities": [p.name for p in P.EffectPriority],
        "dial_targets": [t.name for t in P.DialLedTarget],
    }


# how long a refusal is "now": the gateway tries again every few seconds
PROBLEM_FRESH_S = 30.0


class DeviceHubService:
    def __init__(self, config: DeviceHubConfig, *, exclude_ports: Iterable[str] = (), transport=None) -> None:
        self.config = config
        if transport is None and config.port == "mock":
            transport = MockHub(MockConfig(system_id=config.system_id))
        if transport is None:
            transport = ExcludingSerialTransport(config.port or "auto", exclude=exclude_ports)
        self.transport = transport
        self.trace = None
        if config.trace:
            self.trace = TraceLog(config.trace)
        self.gw = DeviceGateway(transport=transport, system_id=config.system_id,
                                trace=self.trace.record if self.trace is not None else None)
        self._unsubscribe: Callable[[], None] | None = None

    def problem(self) -> str:
        """Why the hub is not connected, in words for the screen ("" = connected). Read only:
        the facts are the gateway's link_diagnostics(), nothing is sent."""
        d = self.gw.link_diagnostics()
        if d["connected"]:
            return ""
        port = d["port"] or self.config.port
        fresh = lambda age: age is not None and age < PROBLEM_FRESH_S  # noqa: E731
        if fresh(d["wrong_system_age_s"]):
            return (f"ポート {port} のハブは別のシステムのもの（{d['wrong_system']}）。"
                    f"設定のシステム番号は {self.config.system_id}（設定画面の「実機」で合わせて、起動し直す）")
        kind, open_error = d["open_error_kind"], d["open_error"]
        if kind == "no_port":
            return "ハブの USB シリアルポートが見つからない（ハブを USB でつなぐ。ロボットのポートは試さない）"
        if kind == "excluded":
            return f"ポート {self.config.port} はロボット（Core2）のポートで、ハブのものではない（設定の devicehub.port を直す）"
        if open_error:
            return f"ハブのポートを開けない（{open_error}）。ほかのプログラム（試験画面 pc.web_console など）が使っていないか"
        if fresh(d["rejected_age_s"]):
            return (f"ポート {d['rejected_port']} は開けたが、ハブとして応答しない"
                    "（ハブ以外の機器か、ハブのファームウェアが動いていない）")
        return f"ハブの応答を待っている（ポート {port}）"

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
        if self.trace is not None:
            self.trace.close()

    # ---- requests (async: the gateway blocks until the hub answers) -----------------
    def meta(self) -> dict:
        port = getattr(self.transport, "current_port", None) or self.config.port
        return {"system_id": self.config.system_id, "port": port, "connected": self.gw.connected,
                "problem": self.problem(),
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

    async def mock_ball(self, device: Any) -> dict:
        """The simulated hub only (port "mock"): a capsule lands in a Dial, as if its switch
        closed (the game mode's rehearsal without hardware, #138). The real hub never fakes it."""
        ball = getattr(self.transport, "ball", None)
        if self.config.port != "mock" or ball is None:
            raise DeviceHubError("devicehub_mock_ball は仮想ハブ（devicehub.port が mock）のときだけ")
        if not isinstance(device, int) or isinstance(device, bool):
            raise DeviceHubError("device (int) is needed")
        try:
            return {"device": device, "accepted": bool(await asyncio.to_thread(ball, device))}
        except KeyError as e:
            raise DeviceHubError(f"unknown device {device}") from e

    async def stop_all(self) -> dict:
        return {str(k): result_dict(v) for k, v in (await self._call(self.gw.stop_all)).items()}
