"""GameServer's commands for the easy mode's Dial drop point and release height (#169): recorded
on the machine and saved in calibration.json#easy_dials. #299: recorded in the 校正 tab's "Z の上下と
原点復帰" with the Z top and bottom, used as recorded (no confirmation step), and the catch height
is the Z bottom itself. Only easy_goto (the practice's demonstration) moves the robot, as an
ordinary move_xy."""

from __future__ import annotations

import json
import logging
import math
import time

from ..robot.state import MachineState
from ..sequence.easy import DESTINATIONS, EasyParams, real_catch_params

log = logging.getLogger(__package__ + ".server")


class EasyCalibrationMixin:
    # ------------------------------------------------------------------ easy mode's Dials (#169)
    def _easy_saved(self) -> dict | None:
        path = self._easy_path
        if path is None:
            return None
        try:
            if not path.exists():
                return None
            d = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("easy mode's drop points not read: %s", e)
            return None
        return d if isinstance(d, dict) else None

    def _easy_params(self) -> EasyParams:
        if self._easy_fixed is not None:
            return self._easy_fixed
        profile = "real" if self.robot.is_real else "dry_run"
        raw = self.backend_cfg.raw if self.backend_cfg is not None else {}
        saved = self._easy_saved() if profile == "real" else None
        easy = EasyParams.from_raw(raw, profile, saved)
        if profile == "real":
            import dataclasses
            # #299: the catch goes down to the Z bottom record (0 = 下): known once Z has both records
            lim = self._easy_limits
            bottom = (lim.z_min if lim.z_up_is_positive else lim.z_max) if self._z_counts_per_unit() is not None else None
            # the recorded release height is in the Z units of the calibration it was recorded with
            stale = saved is not None and easy.release_z is not None and self._height_z_changed(saved)
            easy = dataclasses.replace(easy, catch_z=bottom, stale_z=stale)
        return easy

    def _easy_catch(self, easy: EasyParams):
        """The catch's profile: the real crane's from what the 校正 tab measured, else the dry run's."""
        if not self.robot.is_real or self._easy_fixed is not None:
            return self._easy_dry
        raw = self.backend_cfg.raw if self.backend_cfg is not None else {}
        return real_catch_params(raw, easy, self._easy_limits, self.backend_cfg)

    async def _easy_goto(self, params: dict) -> dict:
        """#183 (the practice shows the carry): one XY move to a Dial's recorded point at the
        easy mode's feed, nothing else (no Z, no claw). Only with the easy mode's values usable
        and the arm at the travel height (the carry's own height); an ordinary XY move under
        the motion lock, stopped like any other."""
        name = "easy_goto"
        try:
            dest = int(params.get("destination"))
        except (TypeError, ValueError):
            return self._nack(name, "bad params: destination must be 1")
        if dest not in DESTINATIONS:
            return self._nack(name, "bad params: destination must be 1")
        self._easy_refresh()
        problems = self.easy.problems()
        if problems:
            return self._nack(name, "easy mode not ready: " + "; ".join(problems))
        p = self.easy.params
        z = self.robot.snapshot().z
        tol = max(float(p.z_tolerance or 0.0), self.backend_cfg.home_z_tolerance if self.backend_cfg is not None else 5.0)
        if p.safe_z is None or abs(z - float(p.safe_z)) > tol:
            return self._nack(name, f"the arm is not at the travel height (Z {z:.1f}, travel {p.safe_z}): raise it first")
        x, y = self.easy.easy.dials[dest]
        async with self._motion_lock:
            await self.robot.move_xy(float(x), float(y), p.xy_feed_mm_min)
        return self._ack(name, {"destination": dest, **self.robot.snapshot().to_message()["data"]})

    def _easy_refresh(self) -> None:
        """The saved values (and the Z calibration they depend on) as they are now."""
        if not self.easy.active:
            easy = self._easy_params()
            self.easy.set_easy(easy, self._easy_catch(easy))

    def _easy_status(self) -> dict:
        self._easy_refresh()
        return {**self.easy.status(), "dials": self.easy.easy.as_dict(), "problems": self.easy.problems()}

    def _easy_prepare_note(self) -> str:
        """The preparation's last step (#167 / #169): the last session's drop points are in use,
        or why not. Never a failure: the easy mode is a choice."""
        if not self.robot.is_real:
            return "skip: 仮想クレーン（模擬の値を使う）"
        if self._easy_saved() is None:
            return "skip: まだ記録していない（かんたんモードを使うときだけ、校正タブの 2 で）"
        self._easy_refresh()
        problems = self.easy.problems()
        if problems:
            return "skip: まだ使えない: " + problems[0]
        e = self.easy.easy
        return "前回の値を使う（ポータル X %.0f / Y %.0f、キャッチ Z %.1f（下）、投入 Z %.1f）" % (
            *e.dials[1], e.catch_z, e.release_z)

    def _easy_write(self, name: str, saved: dict) -> dict:
        try:
            self._easy_path.write_text(json.dumps(saved))
            self._easy_refresh()
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        return self._ack(name, self._easy_status())

    def _easy_dial_set(self, params: dict) -> dict:
        """The 校正 tab: where the arm is now = the portal's (Dial 1's) drop point (XY) or the release
        height (Z). #299: used as recorded; the catch height is the Z bottom (not recorded here)."""
        name = "easy_dial_set"
        if not self.robot.is_real or self._easy_path is None or self._easy_fixed is not None:
            return self._nack(name, "仮想クレーンでは模擬の値（game_mode.easy.dry_run）を使う。実機でだけ記録する")
        if self.easy.active:
            return self._nack(name, "busy: the easy mode is catching / carrying")
        which = str(params.get("which", ""))
        saved = dict(self._easy_saved() or {})
        saved.pop("dial_2", None)  # #200: an older version's Dial 2 is not kept in the file
        saved.pop("catch_z", None)  # #299: the catch height is the Z bottom
        saved.pop("confirmed", None)  # #299: no confirmation step
        s = self.robot.snapshot()
        if which == "clear":
            saved = {}
        elif which == "dial_1":
            if not s.connected:
                return self._nack(name, "robot not connected")
            if not s.homed:
                return self._nack(name, "not homed: home first (XY must be known)")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                return self._nack(name, f"the arm is moving ({s.state}): wait until it stops")
            if not (math.isfinite(s.x) and math.isfinite(s.y) and self.easy.limits.xy_inside(s.x, s.y)):
                return self._nack(name, f"XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
            saved[which] = {"x": round(float(s.x), 2), "y": round(float(s.y), 2)}
        elif which == "catch_z":
            return self._nack(name, "キャッチの高さは Z の下と同じ（「ここを下に記録」で決まる）")
        elif which == "release_z":
            if not s.connected:
                return self._nack(name, "robot not connected")
            if not s.z_reference_set:
                return self._nack(name, "Z の基準がない: W で一番上まで巻き上げて「上を記録」してから")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                return self._nack(name, f"the arm is moving ({s.state}): wait until it stops")
            if self._z_counts_per_unit() is None:
                return self._nack(name, "Z の上と下を両方記録してから（Z の 1 単位が何 cm か分からない）")
            saved[which] = round(float(s.z), 2)
            saved["z_counts_per_unit"] = self._z_counts_per_unit()  # what these Z values mean
        else:
            return self._nack(name, "which must be dial_1, release_z or clear")
        if which != "clear":
            saved["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        log.info("easy mode's drop points saved: %s", saved)
        return self._easy_write(name, saved)
