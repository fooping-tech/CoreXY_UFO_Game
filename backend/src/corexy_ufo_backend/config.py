"""Shared configuration loader (reads ../config/game_config.json)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CONFIG_PATH = REPO_ROOT / "config" / "game_config.json"


@dataclass
class RobotLimits:
    x_min: float = 0.0
    x_max: float = 390.0
    y_min: float = 0.0
    y_max: float = 200.0
    z_min: float = 0.0
    z_max: float = 100.0
    z_up_is_positive: bool = True

    def clamp_xy(self, x: float, y: float) -> tuple[float, float]:
        return (min(max(x, self.x_min), self.x_max), min(max(y, self.y_min), self.y_max))

    def clamp_z(self, z: float) -> float:
        return min(max(z, self.z_min), self.z_max)

    def xy_inside(self, x: float, y: float) -> bool:
        return self.x_min <= x <= self.x_max and self.y_min <= y <= self.y_max


@dataclass
class BackendConfig:
    serial_port: str = ""
    baudrate: int = 115200
    status_poll_hz: float = 10.0
    host_timeout_s: float = 2.0
    z_counts_per_unit: float = 122.88
    z_sign: int = 1
    arm_open_turns: float = 0.5
    xy_feed_mm_min: float = 900.0
    websocket_host: str = "127.0.0.1"
    websocket_port: int = 8765
    limits: RobotLimits = field(default_factory=RobotLimits)
    raw: dict[str, Any] = field(default_factory=dict)


def load_config(path: Path | None = None) -> BackendConfig:
    path = path or DEFAULT_CONFIG_PATH
    cfg = BackendConfig()
    if not path.exists():
        return cfg
    data = json.loads(path.read_text(encoding="utf-8"))
    cfg.raw = data
    r = data.get("robot", {})
    cfg.limits = RobotLimits(
        x_min=float(r.get("x_min_mm", 0.0)),
        x_max=float(r.get("x_max_mm", 390.0)),
        y_min=float(r.get("y_min_mm", 0.0)),
        y_max=float(r.get("y_max_mm", 200.0)),
        z_min=float(r.get("z_min_mm", 0.0)),
        z_max=float(r.get("z_max_mm", 100.0)),
        z_up_is_positive=bool(r.get("z_up_is_positive", True)),
    )
    b = data.get("backend", {})
    cfg.serial_port = str(b.get("serial_port", ""))
    cfg.baudrate = int(b.get("baudrate", 115200))
    cfg.status_poll_hz = float(b.get("status_poll_hz", 10.0))
    cfg.host_timeout_s = float(b.get("host_timeout_s", 2.0))
    cfg.z_counts_per_unit = float(b.get("z_counts_per_unit", 122.88))
    cfg.z_sign = int(b.get("z_sign", 1))
    cfg.arm_open_turns = float(b.get("arm_open_turns", 0.5))
    cfg.xy_feed_mm_min = float(b.get("xy_feed_mm_min", 900.0))
    url = str(data.get("network", {}).get("websocket_url", "ws://127.0.0.1:8765"))
    hostport = url.split("://", 1)[-1].rstrip("/")
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        cfg.websocket_host, cfg.websocket_port = host, int(port)
    return cfg
