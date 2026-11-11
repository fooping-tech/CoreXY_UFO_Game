"""Capture heights for the HELP close-ups: camera 10 cm / 5 cm above the desk, then the landing.

The backend's Z is an abstract unit (0..z_max, the drum servo count scaled): it does not
say how far the arm is above the desk. These values tie it to the desk:

    z_desk_tip        Z where the claw tips just touch the desk (measured)
    z_per_cm          Z units per cm of height (measured with a block of known height)
    camera_offset_cm  how far the arm camera's lens is above the claw tips (measured)
    landing_tip_cm    claw tip height at the landing stage (0 = touching the sheet)
    min_clearance_cm  the smallest tip height allowed without contact
    allow_landing_contact  landing_tip_cm below min_clearance_cm (touching) only when true

    Z(camera h cm above the desk) = z_desk_tip + up * (h - camera_offset_cm) * z_per_cm
    (up = +1 when a larger Z is higher, robot.z_up_is_positive)

`real` drives the real robot: every null must be measured there and every `confirmed`
item set true by hand, otherwise the staged descent is refused. `dry_run` holds
made-up values for the mock robot only. Pure computation.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from ..config import RobotLimits

CONFIRM_KEYS = ("z_desk_tip", "z_per_cm", "camera_offset_cm", "landing")
STAGE_NAMES = ("10cm", "5cm", "landing")


class HeightError(ValueError):
    """The staged descent cannot run with these values (the message says why)."""


@dataclass(frozen=True)
class CaptureStage:
    name: str
    camera_cm: float
    tip_cm: float
    z: float


@dataclass(frozen=True)
class HeightCalibration:
    z_desk_tip: float | None = None
    z_per_cm: float | None = None
    camera_offset_cm: float | None = None
    landing_tip_cm: float | None = None
    min_clearance_cm: float = 1.0
    allow_landing_contact: bool = False
    capture_heights_cm: tuple[float, ...] = (10.0, 5.0)
    confirmed: dict = field(default_factory=dict)
    profile: str = "real"

    @classmethod
    def from_raw(cls, raw: dict[str, Any], profile: str) -> "HeightCalibration":
        sm = raw.get("study_mode") if isinstance(raw.get("study_mode"), dict) else {}
        h = sm.get("height") if isinstance(sm.get("height"), dict) else {}
        d = h.get(profile) if isinstance(h.get(profile), dict) else {}

        def num(key: str) -> float | None:
            v = d.get(key)
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
        heights = h.get("capture_heights_cm", [10.0, 5.0])
        conf = d.get("confirmed") if isinstance(d.get("confirmed"), dict) else {}
        return cls(z_desk_tip=num("z_desk_tip"), z_per_cm=num("z_per_cm"), camera_offset_cm=num("camera_offset_cm"),
                   landing_tip_cm=num("landing_tip_cm"), min_clearance_cm=float(d.get("min_clearance_cm", 1.0)),
                   allow_landing_contact=bool(d.get("allow_landing_contact", False)),
                   capture_heights_cm=tuple(float(v) for v in heights) if isinstance(heights, list) else (10.0, 5.0),
                   confirmed={k: bool(conf.get(k, False)) for k in CONFIRM_KEYS}, profile=profile)

    def z_for_tip(self, tip_cm: float, limits: RobotLimits) -> float:
        assert self.z_desk_tip is not None and self.z_per_cm is not None
        up = 1.0 if limits.z_up_is_positive else -1.0
        return self.z_desk_tip + up * tip_cm * self.z_per_cm

    def stages(self, limits: RobotLimits) -> list[CaptureStage]:
        """10 cm, 5 cm and the landing as Z values, highest first; HeightError when not allowed."""
        errs: list[str] = []
        missing = [k for k in ("z_desk_tip", "z_per_cm", "camera_offset_cm", "landing_tip_cm") if getattr(self, k) is None]
        if missing:
            errs.append("not measured: " + ", ".join(missing))
        if self.profile == "real":
            unconfirmed = [k for k in CONFIRM_KEYS if not self.confirmed.get(k, False)]
            if unconfirmed:
                errs.append("not confirmed on the robot: " + ", ".join(unconfirmed))
        if errs:
            raise HeightError("height calibration (study_mode.height." + self.profile + ") " + "; ".join(errs))
        assert self.z_per_cm is not None and self.camera_offset_cm is not None and self.landing_tip_cm is not None
        if not (math.isfinite(self.z_per_cm) and self.z_per_cm > 0):
            raise HeightError("z_per_cm must be a positive number")
        if len(self.capture_heights_cm) != 2:
            raise HeightError("capture_heights_cm must be two heights (10 cm, 5 cm)")
        out: list[CaptureStage] = []
        for name, cam in zip(STAGE_NAMES, self.capture_heights_cm):
            tip = cam - self.camera_offset_cm
            if tip < self.min_clearance_cm:
                raise HeightError(f"{name}: the claw tips would be {tip:.1f} cm above the desk "
                                  f"(< min_clearance_cm {self.min_clearance_cm:g})")
            out.append(CaptureStage(name, cam, tip, self.z_for_tip(tip, limits)))
        tip = self.landing_tip_cm
        if tip < 0:
            raise HeightError("landing_tip_cm below the desk")
        if tip < self.min_clearance_cm and not self.allow_landing_contact:
            raise HeightError(f"landing at {tip:g} cm touches the sheet: set allow_landing_contact only after "
                              "checking it on the robot (otherwise landing_tip_cm >= min_clearance_cm)")
        out.append(CaptureStage("landing", tip + self.camera_offset_cm, tip, self.z_for_tip(tip, limits)))
        heights = [s.tip_cm for s in out]
        if any(b >= a for a, b in zip(heights, heights[1:])):
            raise HeightError(f"the stages must go down: tip heights {heights}")
        for s in out:
            if not limits.z_min <= s.z <= limits.z_max:
                raise HeightError(f"{s.name}: Z {s.z:.1f} outside {limits.z_min:g}..{limits.z_max:g}")
        return out

    def status(self, limits: RobotLimits) -> dict:
        try:
            stages = [{"name": s.name, "camera_cm": round(s.camera_cm, 2), "tip_cm": round(s.tip_cm, 2),
                       "z": round(s.z, 2)} for s in self.stages(limits)]
            return {"profile": self.profile, "usable": True, "stages": stages, "problem": ""}
        except HeightError as e:
            return {"profile": self.profile, "usable": False, "stages": [], "problem": str(e)}
