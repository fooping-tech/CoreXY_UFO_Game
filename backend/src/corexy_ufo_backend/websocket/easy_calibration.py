"""GameServer's commands for the easy mode's Dial drop point and heights (#169): recorded on the
machine, saved in calibration.json#easy_dials and used only once confirmed. Only easy_goto
(the practice's demonstration) moves the robot, as an ordinary move_xy."""

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
        if profile == "real" and saved is not None and (easy.catch_z is not None or easy.release_z is not None):
            # the recorded heights are in the Z units of the calibration they were recorded with
            import dataclasses
            easy = dataclasses.replace(easy, stale_z=self._height_z_changed(saved))
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
            return "skip: まだ記録していない（かんたんモードを使うときだけ、校正タブの 8 で）"
        self._easy_refresh()
        problems = self.easy.problems()
        if problems:
            return "skip: まだ使えない: " + problems[0]
        e = self.easy.easy
        return "前回の値を使う（Dial 1 X %.0f / Y %.0f、キャッチ Z %.1f、投入 Z %.1f）" % (
            *e.dials[1], e.catch_z, e.release_z)

    def _easy_write(self, name: str, saved: dict) -> dict:
        try:
            self._easy_path.write_text(json.dumps(saved))
            self._easy_refresh()
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        return self._ack(name, self._easy_status())

    def _easy_dial_set(self, params: dict) -> dict:
        """The 校正 tab: where the arm is now = a Dial's drop point (XY) or the release height (Z).
        Saved unconfirmed: every change is watched on the machine again before it is used."""
        name = "easy_dial_set"
        if not self.robot.is_real or self._easy_path is None or self._easy_fixed is not None:
            return self._nack(name, "仮想クレーンでは模擬の値（game_mode.easy.dry_run）を使う。実機でだけ記録する")
        if self.easy.active:
            return self._nack(name, "busy: the easy mode is catching / carrying")
        which = str(params.get("which", ""))
        saved = dict(self._easy_saved() or {})
        saved.pop("dial_2", None)  # #200: an older version's Dial 2 is not kept in the file
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
        elif which in ("release_z", "catch_z"):
            if not s.connected:
                return self._nack(name, "robot not connected")
            if not s.z_reference_set:
                return self._nack(name, "Z の基準がない: W で一番上まで巻き上げて「上を記録」してから")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                return self._nack(name, f"the arm is moving ({s.state}): wait until it stops")
            if self._z_counts_per_unit() is None:
                return self._nack(name, "Z の上と下を両方記録してから（Z の 1 単位が何 cm か分からない）")
            if saved and self._height_z_changed(saved) and (saved.get("release_z") is not None
                                                             or saved.get("catch_z") is not None):
                # the other height was recorded in the old Z units: it is recorded again too
                saved.pop("release_z", None)
                saved.pop("catch_z", None)
            saved[which] = round(float(s.z), 2)
            saved["z_counts_per_unit"] = self._z_counts_per_unit()  # what these Z values mean
        else:
            return self._nack(name, "which must be dial_1, release_z, catch_z or clear")
        if which != "clear":
            saved["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        saved["confirmed"] = False
        log.info("easy mode's drop points saved (not confirmed yet): %s", saved)
        return self._easy_write(name, saved)

    def _easy_dial_confirm(self, params: dict) -> dict:
        """A person watched the arm over the Dial at the release height: the values may be used."""
        name = "easy_dial_confirm"
        if not self.robot.is_real or self._easy_path is None or self._easy_fixed is not None:
            return self._nack(name, "仮想クレーンでは模擬の値（game_mode.easy.dry_run）を使う。実機でだけ確かめる")
        if self.easy.active:
            return self._nack(name, "busy: the easy mode is catching / carrying")
        saved = self._easy_saved()
        if saved is None:
            return self._nack(name, "まだ記録していない（Dial 1 の位置と投入の高さ）")
        on = params.get("confirmed") is not False
        if on:
            self._easy_refresh()
            # everything but the confirmation itself
            errs = self.easy.easy.problems(self.easy.params, self.easy.limits, need_confirmed=False)
            if errs:
                return self._nack(name, "このままでは使えない: " + "; ".join(errs))
        log.info("easy mode's drop points %s", "confirmed" if on else "unconfirmed")
        return self._easy_write(name, {**saved, "confirmed": on})
