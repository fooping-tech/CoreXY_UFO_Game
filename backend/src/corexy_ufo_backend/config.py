"""Shared configuration loader (reads ../config/game_config.json).

The settings screen (#93) writes config/local_settings.json (not in Git), read here over
game_config.json. Only the keys and values its settings_screen section allows are used, so
a hand-edited file cannot change the calibration or the safety settings.
"""

from __future__ import annotations

import json
import logging
import math
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .calibration_store import section as calibration_section

log = logging.getLogger(__name__)

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
    serial_port_2: str = ""  # a second board (#100): the one connected is used
    baudrate: int = 115200
    status_poll_hz: float = 10.0
    host_timeout_s: float = 2.0
    z_counts_per_unit: float = 122.88
    z_sign: int = 1
    arm_open_turns: float = 0.5
    xy_feed_mm_min: float = 900.0
    # serial JOG speed cap (firmware recommends <= 50 mm/s = 3000 mm/min, see REPLY_FIRMWARE_JOG.md)
    jog_max_mm_s: float = 50.0
    # Z (drum servo) jog speed cap; the servo itself tops out at 2400 counts/s
    jog_z_max_counts_s: int = 2400
    # how often the drum servo position is polled while idle (picks up joystick moves)
    z_poll_hz: float = 3.0
    websocket_host: str = "127.0.0.1"
    websocket_port: int = 8765
    limits: RobotLimits = field(default_factory=RobotLimits)
    # The values measured on this machine, each a section of config/calibration.json
    # (#96; a plain Path works too, as in the tests). None: not saved.
    # the claw's open / closed angles
    arm_calibration_path: Any = None
    # the Z calibration from the top / bottom points
    z_calibration_path: Any = None
    # where the arm's camera looks at the worksheet (#76)
    homework_spot_path: Any = None
    # overview image -> CoreXY XY (#78)
    camera_xy_path: Any = None
    focus_camera_path: Any = None  # calibration.json#focus_camera (#104, tools/calibrate_focus.py)
    # the real robot homes XY only with a Z reference and the arm wound up (within
    # home_z_tolerance of its top): a lowered arm would hit things on the way. On
    # when loaded from the config file (backend.home_requires_z_top, default true);
    # off for a bare BackendConfig (tests)
    home_requires_z_top: bool = False
    home_z_tolerance: float = 5.0
    raw: dict[str, Any] = field(default_factory=dict)


LOCAL_FILE = "local_settings.json"


def schema_items(schema: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for sec in schema.get("sections") or []:
        for it in (sec or {}).get("items") or []:
            if isinstance(it, dict) and "key" in it:
                out[str(it["key"])] = it
    return out


_MISSING = object()


def check_value(item: dict[str, Any], v: Any) -> Any:
    """The value as the schema item allows it, or _MISSING (the same rules as the game's)."""
    t = item.get("type")
    if t == "bool":
        return v if isinstance(v, bool) else _MISSING
    if t == "enum":
        return v if isinstance(v, str) and any(o and str(o[0]) == v for o in item.get("options") or []) else _MISSING
    if t == "number":
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            return _MISSING
        if ("min" in item and v < float(item["min"])) or ("max" in item and v > float(item["max"])):
            return _MISSING
        return float(v)
    if t == "text":
        if not isinstance(v, str) or len(v) > int(item.get("max_length", 200)) or any(ord(c) < 32 for c in v):
            return _MISSING
        return v
    return _MISSING


def flatten(d: dict[str, Any], prefix: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k, v in d.items():
        key = f"{prefix}.{k}" if prefix else str(k)
        if isinstance(v, dict) and v:
            out.update(flatten(v, key))
        else:
            out[key] = v
    return out


def set_path(d: dict[str, Any], key: str, v: Any) -> None:
    parts = key.split(".")
    cur = d
    for p in parts[:-1]:
        if not isinstance(cur.get(p), dict):
            cur[p] = {}
        cur = cur[p]
    cur[parts[-1]] = v


def local_overrides(config_dir: Path, data: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """The allowed overrides of config_dir/local_settings.json ("a.b.c" -> value) and warnings.
    data = game_config.json: its settings_screen section lists what may change."""
    warnings: list[str] = []
    schema = data.get("settings_screen") if isinstance(data.get("settings_screen"), dict) else {}
    local_path = config_dir / str(schema.get("file", LOCAL_FILE))
    if not local_path.exists():
        return {}, []
    try:
        raw = json.loads(local_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return {}, [f"{local_path}: {e}"]
    if not isinstance(raw, dict):
        return {}, [f"{local_path}: not a JSON object"]
    items = schema_items(schema)
    out: dict[str, Any] = {}
    for k, v in flatten(raw).items():
        if k not in items:
            warnings.append(f"{local_path}: {k} is not a setting the settings screen may change: ignored")
            continue
        checked = check_value(items[k], v)
        if checked is _MISSING:
            warnings.append(f"{local_path}: {k} = {v!r} is not allowed: ignored")
            continue
        out[k] = checked
    return out, warnings


def load_config(path: Path | None = None, *, local: bool = True) -> BackendConfig:
    path = path or DEFAULT_CONFIG_PATH
    cfg = BackendConfig()
    cfg.arm_calibration_path = calibration_section(path.parent, "claw")
    cfg.z_calibration_path = calibration_section(path.parent, "z")
    cfg.homework_spot_path = calibration_section(path.parent, "homework_spot")
    cfg.camera_xy_path = calibration_section(path.parent, "camera_xy")
    cfg.focus_camera_path = calibration_section(path.parent, "focus_camera")
    if not path.exists():
        return cfg
    data = json.loads(path.read_text(encoding="utf-8"))
    # CXUFO_NO_LOCAL_SETTINGS=1 (the tests): this machine's own file must not change them
    if local and not os.environ.get("CXUFO_NO_LOCAL_SETTINGS"):
        overrides, warnings = local_overrides(path.parent, data)
        for w in warnings:
            log.warning("local settings: %s", w)
        for k, v in overrides.items():
            set_path(data, k, v)
        if overrides:
            log.info("local settings (%s): %s", LOCAL_FILE, ", ".join(sorted(overrides)))
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
    cfg.serial_port_2 = str(b.get("serial_port_2", ""))
    cfg.baudrate = int(b.get("baudrate", 115200))
    cfg.status_poll_hz = float(b.get("status_poll_hz", 10.0))
    cfg.host_timeout_s = float(b.get("host_timeout_s", 2.0))
    cfg.z_counts_per_unit = float(b.get("z_counts_per_unit", 122.88))
    cfg.z_sign = int(b.get("z_sign", 1))
    cfg.arm_open_turns = float(b.get("arm_open_turns", 0.5))
    cfg.xy_feed_mm_min = float(b.get("xy_feed_mm_min", 900.0))
    cfg.jog_max_mm_s = float(b.get("jog_max_mm_s", 50.0))
    cfg.jog_z_max_counts_s = int(b.get("jog_z_max_counts_s", 2400))
    cfg.z_poll_hz = float(b.get("z_poll_hz", 3.0))
    cfg.home_requires_z_top = bool(b.get("home_requires_z_top", True))
    cfg.home_z_tolerance = float(b.get("home_z_tolerance", 5.0))
    url = str(data.get("network", {}).get("websocket_url", "ws://127.0.0.1:8765"))
    hostport = url.split("://", 1)[-1].rstrip("/")
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        cfg.websocket_host, cfg.websocket_port = host, int(port)
    return cfg
