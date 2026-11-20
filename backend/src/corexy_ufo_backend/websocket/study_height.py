"""GameServer's commands for the study mode's camera heights (#110): what was measured on the
machine, saved in calibration.json and used only once confirmed. Nothing here moves the robot."""

from __future__ import annotations

import json
import logging
import math
from typing import Any

from ..study_mode.height import DRUM_RADIUS_MM, HeightCalibration, HeightError

log = logging.getLogger(__package__ + ".server")


class StudyHeightMixin:
    # ------------------------------------------------------------------ study heights (#110)
    def _height_saved(self) -> dict | None:
        path = self._height_path
        if self.study_profile != "real" or path is None:
            return None
        try:
            if not path.exists():
                return None
            d = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("study heights not read: %s", e)
            return None
        return d if isinstance(d, dict) else None

    def _z_counts_per_unit(self) -> float | None:
        """The measured Z calibration only: the config's guess would give a wrong cm."""
        cal = getattr(self.robot, "z_cal", None)
        return float(cal.counts_per_unit) if cal is not None and cal.complete() else None

    def _height_z_changed(self, saved: dict) -> bool:
        """Review on #111: the Z calibration changed since the heights were saved: the recorded
        desk Z and the ruler check no longer hold (counts per unit is what turns Z into cm)."""
        then, now = saved.get("z_counts_per_unit"), self._z_counts_per_unit()
        if not isinstance(then, (int, float)) or isinstance(then, bool) or now is None:
            return then is not None or now is not None
        return abs(float(then) - now) > 1e-6 * max(abs(now), 1.0)

    @property
    def height(self) -> HeightCalibration:
        """#165: on the real robot the heights come from the Z calibration with no ruler check:
        the desk = the Z bottom record, cm per Z from the measured Z calibration and the drum
        (15 mm unless the 校正 tab saved another radius), the claw tips 10 cm above it."""
        if self.study_profile != "real":
            return self._height_base
        saved = self._height_saved() or {"drum_radius_mm": DRUM_RADIUS_MM, "desk": "bottom"}
        if self._height_z_changed(saved) and saved.get("desk") != "bottom":
            saved = {**saved, "desk": None}  # a Z recorded in the old units: record the desk again
        return self._height_base.with_measured({**saved, "confirmed": True}, self._z_counts_per_unit(),
                                               self.approach.limits)

    def _height_status(self) -> dict:
        data = self.height.status(self.approach.limits)
        data["saved"] = self._height_saved()
        data["z_calibrated"] = self._z_counts_per_unit() is not None
        # only a desk recorded as a Z is stale after measuring Z again ("bottom" follows it, #165)
        data["z_changed"] = (data["saved"] is not None and data["saved"].get("desk") != "bottom"
                             and self._height_z_changed(data["saved"]))
        data["default_drum_radius_mm"] = DRUM_RADIUS_MM
        return data

    def _study_height_set(self, params: dict) -> dict:
        """The 校正 tab's values -> calibration.json#study_height, unconfirmed (#110)."""
        name = "study_height_set"
        if self.study_profile != "real" or self._height_path is None:
            return self._nack(name, "仮想クレーンでは模擬の値（study_mode.height.dry_run）を使う。実機でだけ測る")

        def num(key: str, lo: float, hi: float) -> float:
            v = params.get(key)
            if not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) or not lo <= v <= hi:
                raise ValueError(f"{key} must be a number in {lo:g}..{hi:g}")
            return round(float(v), 3)
        try:
            out: dict[str, Any] = {"drum_radius_mm": num("drum_radius_mm", 3.0, 100.0)}
            # optional: the lens above the tips and the closest stage (#110: one 10 cm stage of the tips)
            if params.get("camera_offset_cm") is not None:
                out["camera_offset_cm"] = num("camera_offset_cm", 0.0, 30.0)
            if params.get("landing_tip_cm") is not None:
                out["landing_tip_cm"] = num("landing_tip_cm", 0.0, 20.0)
                out["allow_landing_contact"] = params.get("allow_landing_contact") is True
        except ValueError as e:
            return self._nack(name, str(e))
        desk = params.get("desk", "bottom")
        if desk == "here":
            s = self.robot.snapshot()
            if not s.z_reference_set:
                return self._nack(name, "Z の基準がない: W で一番上まで巻き上げて「上を記録」してから")
            out["desk"] = round(float(s.z), 2)
        elif desk == "bottom":
            out["desk"] = "bottom"
        else:
            saved = self._height_saved() or {}
            out["desk"] = saved.get("desk", "bottom")  # keep the recorded desk
        out["confirmed"] = False  # every change is checked on the robot again
        out["z_counts_per_unit"] = self._z_counts_per_unit()  # what these Z values mean (review on #111)
        try:
            self._height_path.write_text(json.dumps(out))
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        log.info("study heights saved (not confirmed yet): %s", out)
        return self._ack(name, self._height_status())

    def _study_height_confirm(self, params: dict) -> dict:
        """A grown-up checked the test moves with a ruler: the staged descent may use them."""
        name = "study_height_confirm"
        saved = self._height_saved()
        if saved is None:
            return self._nack(name, "まだ保存していない（値を入れて「保存」）")
        on = params.get("confirmed") is not False
        if on and self._height_z_changed(saved):
            return self._nack(name, "Z を測り直したので、撮影の高さを「保存」し直して、試してから確かめる")
        if on:
            try:
                self._height_base.with_measured({**saved, "confirmed": True}, self._z_counts_per_unit(),
                                                self.approach.limits).stages(self.approach.limits)
            except HeightError as e:
                return self._nack(name, f"このままでは使えない: {e}")
        try:
            self._height_path.write_text(json.dumps({**saved, "confirmed": on}))
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        log.info("study heights %s", "confirmed" if on else "unconfirmed")
        return self._ack(name, self._height_status())
