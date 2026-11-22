"""RealRobot's Z axis (the drum servo, ID 1): counts <-> Z units, the recorded top / bottom
points and their restore after a power cycle (#106), the servo that lost its turn count, the
jog's servo lines, move_z and the Z jog's ramp. A mixin of RealRobot: the state is its own."""

from __future__ import annotations

import asyncio
import json
import logging
import time

from ..serial_service import protocol as P
from ..serial_service.service import CommandRejected, CommandTimeout, SerialError
from .interface import RobotCommandError, ServoFailed
from .real_constants import *  # noqa: F401,F403
from .state import MachineState
from .z_calibration import CLEAR as Z_CLEAR
from .z_calibration import WHICH as Z_WHICH
from .z_calibration import ZCalibration

log = logging.getLogger(__package__ + ".real_robot")


class RealZMixin:
    def _apply_z_counts(self, counts: int) -> None:
        """Drum servo absolute counts -> Z (only meaningful once a Z point is set)."""
        self._z_counts = counts
        if self._z_reference() is not None:
            self._z_units_est = self._z_units_from_counts(counts)
            self._z_measured = True

    def _z_counts_per_unit_signed(self) -> float:
        """Servo counts per +1 Z unit, same convention as move_z (z_sign, z_up_is_positive)."""
        k = self.cfg.z_counts_per_unit * self.cfg.z_sign
        return k if self.limits.z_up_is_positive else -k

    def _z_point_units(self, which: str) -> float:
        """Z of the arm at its top / bottom."""
        top = self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min
        bottom = self.limits.z_min if self.limits.z_up_is_positive else self.limits.z_max
        return top if which == "top" else bottom

    def _z_range_recorded(self) -> bool:
        """Both the top and the bottom recorded this session (#126)."""
        return self._z_top_counts is not None and self._z_bottom_counts is not None

    def _z_reference(self) -> tuple[int, float] | None:
        """(counts, Z) of the point Z is counted from: the top if recorded, else the bottom."""
        if self._z_top_counts is not None:
            return self._z_top_counts, self._z_point_units("top")
        if self._z_bottom_counts is not None:
            return self._z_bottom_counts, self._z_point_units("bottom")
        return None

    @property
    def _z_zero_counts(self) -> int | None:
        """The reference counts (kept for the tests and logs written against z_zero)."""
        ref = self._z_reference()
        return ref[0] if ref else None

    def _forget_z_points(self) -> None:
        self._z_top_counts = self._z_bottom_counts = None

    def _on_jog_servo(self, line: str) -> None:
        js = P.parse_jog_servo(line)
        if js is None:
            return
        if js.reset:
            # the firmware set multi-turn again after the servo's power was cut:
            # its counts restarted from the angle in the turn
            log.warning("servo %d multi-turn set again by the jog (tracking=RESET): forgetting its points",
                        js.servo_id)
            if js.servo_id == Z_SERVO_ID:
                self._forget_z_points()
                if self.z_servo_reset:
                    self.z_servo_reset = False
                    if self.error in (Z_SERVO_RESET_MSG, Z_SERVO_LOST_MSG):
                        self.error = ""
            elif js.servo_id == ARM_SERVO_ID:
                self._forget_arm_counts()
        elif js.event in ("disabled", "stopped"):
            # cleared by the next press, like the other "jog ended" errors
            self.error = "jog ended: " + line.removeprefix("JOG ")
            if js.event == "disabled" and (js.reason in POWER_CYCLE_REASONS or "power-cycle" in line):
                if js.servo_id not in self.servo_power_cycle:
                    log.warning("servo %d refuses jogs until its power is cut and restored: %s", js.servo_id, line)
                self.servo_power_cycle.add(js.servo_id)
        if js.event == "begin":
            self.servo_power_cycle.discard(js.servo_id)  # the firmware took it again

    def _note_power_cycled(self, line: str) -> None:
        """#163: a refused servo's SERVO_STATUS says it was powered again (back to one
        turn: its limits are not 0/0 any more) or the firmware tracks it again."""
        if not self.servo_power_cycle:
            return
        st = P.parse_servo_status(line)
        if st is None or not st.ok or st.servo_id not in self.servo_power_cycle:
            return
        if (st.limits is not None and st.limits != (0, 0)) or (st.tracking and not st.tracking_lost):
            log.info("servo %d can be jogged again (%s)", st.servo_id, st.raw)
            self.servo_power_cycle.discard(st.servo_id)

    def _note_z_status(self, st: P.ServoStatus) -> None:
        """Notice a drum servo whose power was cut on its own (and its recovery)."""
        if not st.ok:
            return
        if st.multi_turn_lost:
            if not self.z_servo_reset:
                log.warning("Z servo reset detected (%s): forgetting the Z points", st.raw)
                self._forget_z_points()  # the drum's turn count is gone
                self.z_servo_reset = True
            self.z_servo_jog_recovers = st.tracking_lost
            self.error = Z_SERVO_LOST_MSG if st.tracking_lost else Z_SERVO_RESET_MSG
        elif self.z_servo_reset:
            log.info("Z servo multi-turn state recovered")
            self.z_servo_reset = False
            if self.error in (Z_SERVO_RESET_MSG, Z_SERVO_LOST_MSG):
                self.error = ""

    async def recover_z_servo(self) -> None:
        """After the drum servo's power was cut alone: send the smallest SERVO_TURN.
        The firmware refuses it before moving (multi_turn_lost) and drops its turn
        tracking, so the next jog sets the servo to multi-turn again. Only sent while
        the reset is seen in SERVO_STATUS (otherwise it would turn a hair, upwards)."""
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        try:
            st = await self.serial.servo_status(Z_SERVO_ID)
        except SerialError as e:
            raise RobotCommandError(f"SERVO_STATUS {Z_SERVO_ID} failed: {e}") from e
        self._note_z_status(st)
        if not self.z_servo_reset:
            log.info("z_servo_recover: the Z servo is not reset, nothing to do")
            return
        self._require(homed=False)
        self._busy = True
        try:
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            turns = Z_RECOVER_TURNS * (1 if self.cfg.z_sign >= 0 else -1)  # z_sign: + counts = arm up
            r = await self.serial.send(P.cmd_servo_turn(Z_SERVO_ID, turns), timeout=10.0)
            res = P.parse_servo_result(r.completion or "")
            if res is None or not (res.ok or "multi_turn_lost" in res.raw):
                self.error = r.completion or "SERVO_TURN failed"
                raise RobotCommandError(self.error)
            st = await self.serial.servo_status(Z_SERVO_ID)
            self._note_z_status(st)
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._state = MachineState.IDLE
        if self.z_servo_reset:
            raise RobotCommandError("Z servo still reset after recovery: power-cycle the robot")

    def _apply_z_cal(self) -> None:
        """Measured counts per unit / direction replace the config's (shared with the auto catch)."""
        assert self.z_cal.counts_per_unit is not None and self.z_cal.sign is not None
        self.cfg.z_counts_per_unit = self.z_cal.counts_per_unit
        self.cfg.z_sign = self.z_cal.sign

    def _z_units_from_counts(self, counts: int) -> float:
        ref = self._z_reference()
        if ref is None:
            return self._z_units_est
        ref_counts, ref_units = ref
        delta_units = (counts - ref_counts) * self.cfg.z_sign / self.cfg.z_counts_per_unit
        # z_sign: + counts = arm up; Z grows upwards when z_up_is_positive
        if self.limits.z_up_is_positive:
            return ref_units + delta_units
        return ref_units - delta_units

    # ---------------------------------------------------------------- Z points kept (#106)
    def _load_z_points(self) -> dict:
        path = getattr(self.cfg, "z_points_path", None)
        try:
            if path is None or not path.exists():
                return {}
            d = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("Z points not read (%s): record the top again", e)
            return {}
        if not isinstance(d, dict) or not isinstance(d.get("last"), int):
            return {}
        out = {k: d[k] for k in ("top", "bottom", "last") if isinstance(d.get(k), int) and not isinstance(d[k], bool)}
        return out if "top" in out or "bottom" in out else {}

    def _save_z_points(self, last: int) -> None:
        """Keep this session's points with the drum at rest (same counts) for a later z_restore."""
        path = getattr(self.cfg, "z_points_path", None)
        if path is None or (self._z_top_counts is None and self._z_bottom_counts is None):
            return
        d = {"top": self._z_top_counts, "bottom": self._z_bottom_counts, "last": int(last),
             "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        try:
            path.write_text(json.dumps(d))
        except (OSError, ValueError) as e:
            log.warning("Z points not saved: %s", e)
            return
        self._z_saved = {k: v for k, v in d.items() if isinstance(v, int)}
        self._z_saved_t = time.monotonic()

    def _remember_z_rest(self, st: P.ServoStatus) -> None:
        """At rest with a valid turn count: keep where the drum is (at most once a second)."""
        if (self._z_top_counts is None and self._z_bottom_counts is None) or self.z_servo_reset:
            return
        if not st.ok or st.abs_counts is None or not st.tracking or st.tracking_lost:
            return
        if str(st.extra.get("moving", "0")) not in ("0", ""):
            return
        if abs(st.abs_counts - int(self._z_saved.get("last", st.abs_counts + 999))) < Z_REST_SAVE_COUNTS:
            return
        if time.monotonic() - self._z_saved_t < 1.0:
            return
        self._save_z_points(st.abs_counts)

    async def restore_z_points(self, apply: bool, turns: int | None = None) -> dict:
        """The last session's top / bottom in today's counts (#106).

        The firmware counts the drum in multi-turn from where it started tracking: the angle in
        the turn (raw) when the servo itself was powered up, or the old count when only the
        Core2 restarted. Either way today's counts differ from the saved ones by whole turns
        (4096), so: shift = the whole turns nearest to (now - last at rest). Moved more than
        half a turn while off cannot be told from the turn next to it: the estimate is shown
        and a grown-up checks the arm's height before apply (and a drift over
        Z_RESTORE_MAX_DRIFT is refused)."""
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        saved = self._z_saved
        if "last" not in saved or "top" not in saved:
            raise RobotCommandError("前回の Z の記録がありません（W で一番上まで巻き上げて「上を記録」）")
        st = await self.serial.servo_status(Z_SERVO_ID)
        if not st.ok or st.abs_counts is None:
            raise RobotCommandError(f"SERVO_STATUS {Z_SERVO_ID} failed: {st.raw}")
        self._note_z_status(st)
        if self.z_servo_reset or not st.tracking or st.tracking_lost:
            raise RobotCommandError("巻き上げサーボの回転の追跡がまだ始まっていない: W か S を一瞬押してから、もう一度")
        now = st.abs_counts
        d = now - saved["last"]
        k = round(d / COUNTS_PER_TURN)
        drift = d - k * COUNTS_PER_TURN
        top = saved["top"] + k * COUNTS_PER_TURN
        bottom = saved["bottom"] + k * COUNTS_PER_TURN if "bottom" in saved else None
        per_unit = abs(self._z_counts_per_unit_signed()) or 1.0
        z_top = self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min
        z_est = z_top + (now - top) / self._z_counts_per_unit_signed()
        out = {"turns": k, "drift_counts": drift, "drift_units": round(drift / per_unit, 1),
               "z": round(z_est, 1), "has_bottom": bottom is not None, "applied": False,
               "too_far": abs(drift) > Z_RESTORE_MAX_DRIFT}
        if not apply:
            return out
        if turns is not None and turns != k:
            raise RobotCommandError("見積もりのあとにドラムが回った: もう一度「前回の上下を呼び出す」から")
        if out["too_far"]:
            raise RobotCommandError(f"前回から {out['drift_units']:+.0f} 単位ずれている（電源を切っている間に回った）: "
                                    "W で一番上まで巻き上げて「上を記録」")
        self._z_top_counts, self._z_bottom_counts = top, bottom
        self._apply_z_counts(now)
        self._save_z_points(now)
        out["applied"] = True
        log.info("Z points restored: shift %+d turns, drift %+d counts, Z %.1f", k, drift, z_est)
        return out

    async def set_z_zero(self) -> None:
        """Define the current drum position as 'arm at top' (Z reference)."""
        await self.set_z_point("top")

    def _z_limits_apply(self) -> bool:
        """The 0..z_max range stops a Z jog only once it is known in drum counts:
        a reference AND a measured calibration. Before that the range is the config's
        guess, and stopping there would keep the arm from reaching its real top /
        bottom while they are being recorded (the jog is hold-to-move anyway)."""
        return self._z_reference() is not None and self.z_cal.complete()

    async def set_z_point(self, which: str) -> None:
        """Record the current drum position as the arm's top or bottom. With both
        recorded in this session, measure counts per unit and direction from them
        (and save them); points too close together are refused. "clear" forgets the
        points and the measured calibration (back to the config's values)."""
        if which == Z_CLEAR:
            self._forget_z_points()
            self._z_saved = {}
            if getattr(self.cfg, "z_points_path", None) is not None:
                self.cfg.z_points_path.unlink(missing_ok=True)
            self.z_cal = ZCalibration()
            ZCalibration.delete(self.cfg.z_calibration_path)
            self.cfg.z_counts_per_unit, self.cfg.z_sign = self._z_cfg_default
            log.info("Z points and calibration cleared")
            return
        if which not in Z_WHICH:
            raise RobotCommandError(f"z_set: which must be one of {Z_WHICH + (Z_CLEAR,)}")
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        st = await self.serial.servo_status(Z_SERVO_ID)
        if not st.ok or st.abs_counts is None:
            raise RobotCommandError(f"SERVO_STATUS {Z_SERVO_ID} failed: {st.raw}")
        self._note_z_status(st)
        if self.z_servo_reset:
            raise RobotCommandError(Z_SERVO_RESET_MSG)
        counts = st.abs_counts
        top = counts if which == "top" else self._z_top_counts
        bottom = counts if which == "bottom" else self._z_bottom_counts
        if top is not None and bottom is not None:
            try:
                cal = ZCalibration.from_points(top, bottom, self.limits.z_max - self.limits.z_min)
            except ValueError as e:
                raise RobotCommandError(f"z_set {which}: {e}") from e
            self.z_cal = cal
            self._apply_z_cal()
            self.z_cal.save(self.cfg.z_calibration_path)
            log.info("Z calibrated from top %d / bottom %d: %.2f counts per unit, sign %+d",
                     top, bottom, cal.counts_per_unit, cal.sign)
        self._z_top_counts, self._z_bottom_counts = top, bottom
        self._z_counts = counts
        self._z_units_est = self._z_point_units(which)
        self._z_measured = True
        self._save_z_points(counts)  # for z_restore after a power cycle (#106)
        log.info("Z %s set at %d counts", which, counts)

    async def move_z(self, z: float) -> None:
        # #126: with both Z points recorded this session the move stays inside the measured
        # range, like the unhomed Z jog: no XY homing needed (the calibration tab's 上げる /
        # 下げる come before homing, which wants the arm wound up first)
        self._require(homed=not self._z_range_recorded())
        if self._z_reference() is None:
            raise RobotCommandError("Z reference not set (z_set top with the arm wound up, or bottom with it lowered)")
        z = self.limits.clamp_z(z)
        delta_units = z - self._z_units_est
        if abs(delta_units) < 1e-3:
            return
        going_up = delta_units > 0 if self.limits.z_up_is_positive else delta_units < 0
        total_turns = delta_units * self.cfg.z_counts_per_unit / COUNTS_PER_TURN * self.cfg.z_sign
        if not self.limits.z_up_is_positive:
            total_turns = -total_turns
        self._busy = True
        self._state = MachineState.Z_RAISING if going_up else MachineState.Z_LOWERING
        try:
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            remaining = total_turns
            while abs(remaining) > 1e-3:
                # #248: as few pieces as the firmware takes (the drum stops at each seam)
                most = self.z_max_turns
                chunk = max(-most, min(most, remaining))
                eta = abs(chunk) * COUNTS_PER_TURN / SERVO_SPEED_COUNTS_PER_S + 3.0
                r = await self.serial.send(P.cmd_servo_turn(Z_SERVO_ID, chunk), timeout=eta + 5.0)
                res = P.parse_servo_result(r.completion or "")
                over = P.turns_over_max(r.completion or "") if res is not None and res.reason == "turns_over" else None
                if over is not None and 0 < over < abs(chunk):
                    # refused before moving: this firmware takes less (an older one); go on in its steps
                    log.warning("SERVO_TURN %.2f over the firmware's %.1f turns: smaller steps", chunk, over)
                    self.z_max_turns = over
                    continue
                if res is not None and "multi_turn_lost" in res.raw:
                    # the drum servo's power was cut: refused unmoved; the next turn
                    # goes through but its counts restart, so the Z points are gone
                    self._forget_z_points()
                    self.error = Z_SERVO_RESET_MSG
                    raise ServoFailed(self.error)
                if res is None or not res.ok:
                    self.error = r.completion or "SERVO_TURN failed"
                    if res and res.actual is not None:
                        self._z_counts = res.actual
                        self._z_units_est = self._z_units_from_counts(res.actual)
                    # a reply that is a servo result: the command ended (#269); anything else
                    # (no result line at all) is not known to have ended
                    raise ServoFailed(self.error) if res is not None else RobotCommandError(self.error)
                if res.actual is not None:
                    self._z_counts = res.actual
                    self._z_units_est = self._z_units_from_counts(res.actual)
                else:
                    self._z_units_est += (chunk / total_turns) * delta_units if total_turns else 0.0
                remaining -= chunk
            self._z_measured = True
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._state = MachineState.IDLE

    def _ramped_z(self, requested: int, now: float) -> int:
        """Z rate to send: the request, or (after a release) an ease-out ramp down to 0."""
        if requested:
            self._z_ramp_from = 0
            return requested
        if not self._z_ramp_from and self._z_rate:
            self._z_ramp_from, self._z_ramp_t0 = self._z_rate, now  # just released
        if self._z_ramp_from:
            f = 1.0 - (now - self._z_ramp_t0) / Z_RAMP_S
            if f > 0.0:
                return int(self._z_ramp_from * f * f)
            self._z_ramp_from = 0
        return 0

    def _cancel_z_ramp(self) -> None:
        if self._z_ramp_task and not self._z_ramp_task.done():
            self._z_ramp_task.cancel()
        self._z_ramp_task = None
        self._z_ramp_from = 0
        self._z_rate = 0

    async def _ramp_z_to_stop(self) -> None:
        """All keys released while Z was moving: keep ramping Z down, then end the jog."""
        try:
            while self.serial.connected:
                await asyncio.sleep(Z_RAMP_STEP_S)
                z = self._ramped_z(0, time.monotonic())
                if not z:
                    break
                self.serial.write_raw(P.cmd_jog(0.0, 0.0, z))
                self._z_rate = z
            self._end_jog_session()
        except asyncio.CancelledError:
            pass
