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
    # #339: X = x_min and Y = y_min are the home corner's limit switches (pressed within about
    # 1 mm). No programmed XY target goes nearer them than this, and a jog stops this far
    # inside (backend.xy_home_edge_margin_mm; 0 = the soft limits only, as a bare RobotLimits)
    home_margin: float = 0.0

    def clamp_xy(self, x: float, y: float) -> tuple[float, float]:
        return (min(max(x, self.x_min), self.x_max), min(max(y, self.y_min), self.y_max))

    def clamp_z(self, z: float) -> float:
        return min(max(z, self.z_min), self.z_max)

    def xy_inside(self, x: float, y: float) -> bool:
        return self.x_min <= x <= self.x_max and self.y_min <= y <= self.y_max

    def home_edge_refusal(self, x: float, y: float) -> str:
        """#339: "" or why an XY target is too near the home corner's limit switches."""
        m = self.home_margin
        if m <= 0 or (x >= self.x_min + m and y >= self.y_min + m):
            return ""
        return (f"XY ({x:.1f},{y:.1f}) is within {m:g} mm of the home limit switches "
                f"(X {self.x_min:g} / Y {self.y_min:g}): keep X >= {self.x_min + m:g} and Y >= {self.y_min + m:g}")

    def clamp_home_edge(self, x: float, y: float) -> tuple[float, float]:
        """#339: a target moved out of the home edges' margin (only that side; a point outside
        the soft limits stays outside and is refused as before)."""
        m = max(self.home_margin, 0.0)
        return (max(x, min(self.x_min + m, self.x_max)) if x >= self.x_min else x,
                max(y, min(self.y_min + m, self.y_max)) if y >= self.y_min else y)


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
    # #192: a claw closing to its recorded closed angle that stops this near it (deg) with the
    # torque still on has gripped something: not a failure. 0 = any TIMEOUT is a failure.
    claw_grip_tolerance_deg: float = 3.0
    xy_feed_mm_min: float = 900.0
    # serial JOG speed cap (firmware recommends <= 50 mm/s = 3000 mm/min, see REPLY_FIRMWARE_JOG.md)
    jog_max_mm_s: float = 50.0
    # #188 (SPEED UP): the jog's XY cap while the game's boost lasts (the jog_boost command),
    # and the longest one request may last. None / not above jog_max_mm_s = no boost.
    jog_boost_mm_s: float | None = None
    jog_boost_max_s: float = 30.0
    # #185 / #339: a jog (keys, the hand stick) stays jog_edge_margin_mm inside the far soft
    # limits (x_max / y_max) and limits.home_margin (at least jog_edge_margin_mm) inside the
    # home corner's limit switches (x_min / y_min), and slows down towards those lines from a
    # predicted position (robot/jog_edges.py): the last known one plus what the speeds of the
    # last jog_edge_lag_s add; then the speed v towards an edge keeps
    # v * jog_edge_react_s + v^2 / (2 * jog_edge_brake_mm_s2) <= the distance to its line.
    # Both margins 0 = the firmware's own soft limit only (0.5 mm)
    jog_edge_margin_mm: float = 5.0
    jog_edge_lag_s: float = 0.25
    jog_edge_react_s: float = 0.15
    jog_edge_brake_mm_s2: float = 300.0
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
    z_points_path: Any = None  # calibration.json#z_points: the last top / bottom / rest counts (#106)
    # where the arm's camera looks at the worksheet (#76)
    homework_spot_path: Any = None
    # overview image -> CoreXY XY (#78)
    camera_xy_path: Any = None
    study_height_path: Any = None  # calibration.json#study_height (#110: the 校正 tab)
    focus_camera_path: Any = None  # calibration.json#focus_camera (#104, tools/calibrate_focus.py)
    easy_dials_path: Any = None  # calibration.json#easy_dials (#169: the easy mode's drop points)
    # the real robot homes XY only with a Z reference and the arm wound up (within
    # home_z_tolerance of its top): a lowered arm would hit things on the way. On
    # when loaded from the config file (backend.home_requires_z_top, default true; #350: the
    # repository's config sets it false = home without winding the arm up);
    # off for a bare BackendConfig (tests)
    home_requires_z_top: bool = False
    home_z_tolerance: float = 5.0
    # #175: after XY homing the arm goes on to the middle of the stage (the soft limits'
    # centre, or home_center_mm [x, y]) instead of staying in the home corner
    home_then_center: bool = True
    # #344: a servo that does not answer on its bus (NO_REPLY: nothing turned) is tried again
    # by the automatic sequences for up to this many seconds before it is a fault (0 = never)
    servo_no_reply_retry_s: float = 20.0
    home_center_mm: tuple[float, float] | None = None
    # #179: the feed (mm/min) of the automatic XY moves that are to be quick: to the middle
    # after homing, and the easy mode's carry to a Dial. None = xy_feed_mm_min. The firmware
    # clamps an XY feed to its MAX_FEED_MM_MIN (15909.9)
    xy_fast_feed_mm_min: float | None = None
    # #276: where the arm waits out of the way of the screen (`park`): park_mm [x, y], or by
    # default the left back corner (x_min, y_max) park_margin_mm inside; at park_feed_mm_min
    park_mm: tuple[float, float] | None = None
    park_margin_mm: float = 20.0
    park_feed_mm_min: float = 3000.0

    def fast_feed(self) -> float:
        f = self.xy_fast_feed_mm_min
        return f if f is not None and f > 0 else self.xy_feed_mm_min

    def park_point(self) -> tuple[float, float]:
        """#276: where `park` takes the arm: park_mm when it is inside the soft limits, else the
        left back corner (x_min, y_max: +Y is the back) park_margin_mm inside."""
        lim = self.limits
        p = self.park_mm
        if p is not None and lim.xy_inside(p[0], p[1]) and not lim.home_edge_refusal(p[0], p[1]):
            return p
        m = max(self.park_margin_mm, 0.0)
        return lim.clamp_home_edge(min(lim.x_min + m, lim.x_max), max(lim.y_max - m, lim.y_min))

    def home_center(self) -> tuple[float, float] | None:
        """Where the arm goes after homing (None = it stays at home). A configured point
        outside the soft limits is not used: the middle is."""
        if not self.home_then_center:
            return None
        lim = self.limits
        c = self.home_center_mm
        if c is not None and lim.xy_inside(c[0], c[1]) and not lim.home_edge_refusal(c[0], c[1]):
            return c
        return lim.clamp_home_edge((lim.x_min + lim.x_max) / 2.0, (lim.y_min + lim.y_max) / 2.0)
    # #161: a command sent and nothing at all read for this long = the link is dead even if
    # the port looks open (a USB hiccup can stop the reading side alone); 0 = never
    serial_rx_stall_s: float = 5.0
    # #161: after the link was lost while running, reopen the port this often; 0 = never
    serial_reopen_s: float = 3.0
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
    cfg.z_points_path = calibration_section(path.parent, "z_points")
    cfg.homework_spot_path = calibration_section(path.parent, "homework_spot")
    cfg.camera_xy_path = calibration_section(path.parent, "camera_xy")
    cfg.study_height_path = calibration_section(path.parent, "study_height")
    cfg.focus_camera_path = calibration_section(path.parent, "focus_camera")
    cfg.easy_dials_path = calibration_section(path.parent, "easy_dials")
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
    cfg.claw_grip_tolerance_deg = min(max(float(b.get("claw_grip_tolerance_deg", 3.0)), 0.0), 15.0)
    cfg.xy_feed_mm_min = float(b.get("xy_feed_mm_min", 900.0))
    ff = b.get("xy_fast_feed_mm_min")
    cfg.xy_fast_feed_mm_min = float(ff) if isinstance(ff, (int, float)) and not isinstance(ff, bool) and ff > 0 else None
    cfg.jog_max_mm_s = float(b.get("jog_max_mm_s", 50.0))
    jb = b.get("jog_boost_mm_s")
    cfg.jog_boost_mm_s = (float(jb) if isinstance(jb, (int, float)) and not isinstance(jb, bool)
                          and jb > cfg.jog_max_mm_s else None)
    cfg.jog_boost_max_s = min(max(float(b.get("jog_boost_max_s", 30.0)), 0.0), 60.0)
    cfg.jog_edge_margin_mm = max(float(b.get("jog_edge_margin_mm", 5.0)), 0.0)
    cfg.jog_edge_lag_s = min(max(float(b.get("jog_edge_lag_s", 0.25)), 0.0), 1.0)
    cfg.jog_edge_react_s = min(max(float(b.get("jog_edge_react_s", 0.15)), 0.0), 1.0)
    cfg.jog_edge_brake_mm_s2 = max(float(b.get("jog_edge_brake_mm_s2", 300.0)), 0.0)
    # #339: never below the jog's own margin (the switches are pressed within about 1 mm)
    cfg.limits.home_margin = min(max(float(b.get("xy_home_edge_margin_mm", 15.0)), cfg.jog_edge_margin_mm), 50.0)
    cfg.jog_z_max_counts_s = int(b.get("jog_z_max_counts_s", 2400))
    cfg.z_poll_hz = float(b.get("z_poll_hz", 3.0))
    cfg.home_requires_z_top = bool(b.get("home_requires_z_top", True))
    cfg.home_z_tolerance = float(b.get("home_z_tolerance", 5.0))
    cfg.home_then_center = bool(b.get("home_then_center", True))
    cfg.servo_no_reply_retry_s = min(max(float(b.get("servo_no_reply_retry_s", 20.0)), 0.0), 120.0)
    hc = b.get("home_center_mm")
    if (isinstance(hc, list) and len(hc) == 2
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in hc)):
        cfg.home_center_mm = (float(hc[0]), float(hc[1]))
    pk = b.get("park_mm")
    if (isinstance(pk, list) and len(pk) == 2
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in pk)):
        cfg.park_mm = (float(pk[0]), float(pk[1]))
    cfg.park_margin_mm = min(max(float(b.get("park_margin_mm", 20.0)), 0.0), 100.0)
    cfg.park_feed_mm_min = min(max(float(b.get("park_feed_mm_min", 3000.0)), 300.0), 15900.0)
    cfg.serial_rx_stall_s = float(b.get("serial_rx_stall_s", 5.0))
    cfg.serial_reopen_s = float(b.get("serial_reopen_s", 3.0))
    url = str(data.get("network", {}).get("websocket_url", "ws://127.0.0.1:8765"))
    hostport = url.split("://", 1)[-1].rstrip("/")
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        cfg.websocket_host, cfg.websocket_port = host, int(port)
    return cfg
