"""Calibration parameters of the one-button auto catch (config/game_config.json "auto_catch").

Two profiles with the same keys:
  "real"    : the real crane. Hardware values are null until measured on the machine,
              and every item of "confirmed" must be true; otherwise the sequence is
              refused on the real robot (no value is guessed).
  "dry_run" : the simulated robot (backend --mock / DryRunRobot). Made-up values that
              only drive the virtual crane; never used for the real robot.

Units: XY in mm (robot frame), Z in the backend's abstract z units (robot.z_min..z_max,
0..100; the larger value is higher when robot.z_up_is_positive), times in seconds.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from ..config import BackendConfig, RobotLimits

COUNTS_PER_TURN = 4096

# Timeout keys, one per state of the sequence (see sequencer.Phase).
TIMEOUT_KEYS = ("open_claw", "lower_to_catch", "close_claw", "raise_with_item", "move_to_box",
                "lower_to_release", "release", "raise_empty", "claw_standby")

# Hardware facts that have to be checked on the machine before the real profile is used.
CONFIRM_KEYS = ("z_direction", "z_scale", "z_positions", "box_xy", "claw_positions", "timeouts", "speeds")

# Values the sequence cannot run without (both profiles).
REQUIRED_KEYS = ("safe_z", "catch_z", "release_z", "z_floor", "max_drop_units", "max_drum_turns",
                 "box_x_mm", "box_y_mm", "xy_feed_mm_min", "xy_feed_max_mm_min", "claw_span_min_deg",
                 "claw_span_max_deg", "claw_settle_s", "total_timeout_s", "xy_tolerance_mm", "z_tolerance",
                 "limit_home_zone_mm", "button_debounce_ms")


@dataclass
class InputPolarity:
    """Electrical polarity of an input: True = the input is active when the raw level is high."""
    catch_button_active_high: bool | None = None
    estop_active_high: bool | None = None
    limit_active_high: bool | None = None


@dataclass
class AutoCatchParams:
    profile: str = "dry_run"
    # Z (abstract units). safe_z: travel height; catch_z / release_z: where the claw
    # closes / opens; z_floor: lowest Z the sequence may ever command.
    safe_z: float | None = None
    catch_z: float | None = None
    release_z: float | None = None
    z_floor: float | None = None
    max_drop_units: float | None = None  # largest descent below safe_z (Z 下降量の上限)
    max_drum_turns: float | None = None  # largest drum turn of one move (巻取り量の上限)
    # rescue box
    box_x_mm: float | None = None
    box_y_mm: float | None = None
    # speeds. XY feed is sent with each XY move; the accelerations and the servo speed
    # are fixed in the firmware and only drive the dry-run model.
    xy_feed_mm_min: float | None = None
    xy_feed_max_mm_min: float | None = None
    xy_accel_mm_s2: float | None = None
    z_speed_units_s: float | None = None
    z_accel_units_s2: float | None = None
    # claw: which recorded position (arm_calibration.json: closed_deg / open_deg) each
    # step goes to; standby None = leave the claw as it is at the end
    claw_open: str = "open"
    claw_close: str = "closed"
    claw_standby: str | None = None
    claw_span_min_deg: float | None = None
    claw_span_max_deg: float | None = None
    claw_settle_s: float | None = None  # servo settle wait after each claw move
    # timeouts
    timeouts_s: dict[str, float] = field(default_factory=dict)
    total_timeout_s: float | None = None
    # completion / monitoring
    xy_tolerance_mm: float | None = None
    z_tolerance: float | None = None
    limit_home_zone_mm: float | None = None  # a limit switch near home (after HOME) is normal
    button_debounce_ms: float | None = None
    polarity: InputPolarity = field(default_factory=InputPolarity)
    confirmed: dict[str, bool] = field(default_factory=dict)
    # dry run only: the virtual claw's recorded positions
    virtual_claw_closed_deg: float | None = None
    virtual_claw_open_deg: float | None = None
    virtual_claw_move_s: float | None = None

    @classmethod
    def from_dict(cls, profile: str, d: dict[str, Any] | None) -> "AutoCatchParams":
        d = d or {}
        p = cls(profile=profile)
        for k in ("safe_z", "catch_z", "release_z", "z_floor", "max_drop_units", "max_drum_turns", "box_x_mm",
                  "box_y_mm", "xy_feed_mm_min", "xy_feed_max_mm_min", "xy_accel_mm_s2", "z_speed_units_s",
                  "z_accel_units_s2", "claw_span_min_deg", "claw_span_max_deg", "claw_settle_s", "total_timeout_s",
                  "xy_tolerance_mm", "z_tolerance", "limit_home_zone_mm", "button_debounce_ms",
                  "virtual_claw_closed_deg", "virtual_claw_open_deg", "virtual_claw_move_s"):
            v = d.get(k)
            setattr(p, k, None if v is None else float(v))
        for k in ("claw_open", "claw_close"):
            if d.get(k) is not None:
                setattr(p, k, str(d[k]))
        p.claw_standby = None if d.get("claw_standby") is None else str(d["claw_standby"])
        p.timeouts_s = {str(k): float(v) for k, v in (d.get("timeouts_s") or {}).items() if v is not None}
        pol = d.get("polarity") or {}
        p.polarity = InputPolarity(**{k: (None if pol.get(k) is None else bool(pol[k]))
                                      for k in ("catch_button_active_high", "estop_active_high", "limit_active_high")})
        p.confirmed = {str(k): bool(v) for k, v in (d.get("confirmed") or {}).items()}
        return p


@dataclass
class AutoCatchConfig:
    real: AutoCatchParams
    dry_run: AutoCatchParams

    @classmethod
    def from_raw(cls, raw: dict[str, Any] | None) -> "AutoCatchConfig":
        a = (raw or {}).get("auto_catch") or {}
        return cls(real=AutoCatchParams.from_dict("real", a.get("real")),
                   dry_run=AutoCatchParams.from_dict("dry_run", a.get("dry_run")))


def height(z: float, limits: RobotLimits) -> float:
    """Z as a height (larger = higher) whatever z_up_is_positive says."""
    return z if limits.z_up_is_positive else -z


def _finite(v: float | None) -> bool:
    return v is not None and math.isfinite(v)


def validate(p: AutoCatchParams, limits: RobotLimits, backend: BackendConfig | None = None) -> list[str]:
    """Every reason these parameters cannot drive the sequence (empty = usable).

    Range checks: XY inside the soft limits, Z inside z_min..z_max and not below
    z_floor, the descent and the drum turn of every move bounded, feeds bounded,
    all timeouts present and positive. For the real profile also: all confirmed."""
    errs: list[str] = []
    for k in REQUIRED_KEYS:
        if not _finite(getattr(p, k)):
            errs.append(f"{k} is not set")
    for k in TIMEOUT_KEYS:
        v = p.timeouts_s.get(k)
        if v is None or not math.isfinite(v) or v <= 0:
            errs.append(f"timeouts_s.{k} is not set (> 0)")
    for k in ("claw_open", "claw_close"):
        if getattr(p, k) not in ("open", "closed"):
            errs.append(f"{k} must be 'open' or 'closed'")
    if p.claw_standby not in (None, "open", "closed"):
        errs.append("claw_standby must be 'open', 'closed' or null")
    if p.profile == "real":
        missing = [k for k in CONFIRM_KEYS if not p.confirmed.get(k, False)]
        if missing:
            errs.append("not confirmed on the real machine: " + ", ".join(missing))
    else:
        for k in ("xy_accel_mm_s2", "z_speed_units_s", "z_accel_units_s2", "virtual_claw_closed_deg",
                  "virtual_claw_open_deg", "virtual_claw_move_s"):
            if not _finite(getattr(p, k)):
                errs.append(f"{k} is not set (dry run model)")
    if errs:
        return errs  # the range checks below need the values

    zs = {"safe_z": p.safe_z, "catch_z": p.catch_z, "release_z": p.release_z, "z_floor": p.z_floor}
    for k, v in zs.items():
        if not limits.z_min <= v <= limits.z_max:  # type: ignore[operator]
            errs.append(f"{k}={v} outside Z range {limits.z_min}..{limits.z_max}")
    h = lambda z: height(z, limits)  # noqa: E731
    for k in ("catch_z", "release_z"):
        z = zs[k]
        if h(z) < h(p.z_floor):  # type: ignore[arg-type]
            errs.append(f"{k}={z} is below z_floor={p.z_floor}")
        if h(z) > h(p.safe_z):  # type: ignore[arg-type]
            errs.append(f"{k}={z} is above safe_z={p.safe_z}")
        drop = h(p.safe_z) - h(z)  # type: ignore[arg-type]
        if drop > p.max_drop_units:  # type: ignore[operator]
            errs.append(f"{k}: descent {drop:.1f} > max_drop_units {p.max_drop_units}")
        if backend is not None:
            turns = drop * backend.z_counts_per_unit / COUNTS_PER_TURN
            if turns > p.max_drum_turns:  # type: ignore[operator]
                errs.append(f"{k}: drum turn {turns:.2f} > max_drum_turns {p.max_drum_turns}")
    if not limits.xy_inside(p.box_x_mm, p.box_y_mm):  # type: ignore[arg-type]
        errs.append(f"box ({p.box_x_mm},{p.box_y_mm}) outside the XY soft limits")
    if not 0 < p.xy_feed_mm_min <= p.xy_feed_max_mm_min:  # type: ignore[operator]
        errs.append(f"xy_feed_mm_min={p.xy_feed_mm_min} outside 0..{p.xy_feed_max_mm_min}")
    if not 0 < p.claw_span_min_deg <= p.claw_span_max_deg < 360:  # type: ignore[operator]
        errs.append("claw_span_min_deg / claw_span_max_deg must satisfy 0 < min <= max < 360")
    for k in ("claw_settle_s", "total_timeout_s", "xy_tolerance_mm", "z_tolerance", "button_debounce_ms"):
        if getattr(p, k) < 0 or (k == "total_timeout_s" and getattr(p, k) <= 0):
            errs.append(f"{k} must be positive")
    return errs
