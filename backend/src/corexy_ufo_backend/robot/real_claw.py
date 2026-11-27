"""RealRobot's claw (servo ID 2): grab, the manual steps, the recorded open / closed
positions and the grip check. A mixin of RealRobot: the state is its own."""

from __future__ import annotations

import asyncio
import logging
import math
import time

from ..serial_service import protocol as P
from ..serial_service.service import CommandRejected, CommandTimeout, SerialError
from .claw import WHICH as CLAW_WHICH
from .claw import deg_in_turn
from .interface import (RobotCommandError, ServoFailed, ServoNoReply, ServoPositionUnknown, is_servo_no_reply,
                        is_servo_position_unknown)
from .real_constants import *  # noqa: F401,F403
from .state import MachineState

log = logging.getLogger(__package__ + ".real_robot")


class RealClawMixin:
    def _forget_arm_counts(self) -> None:
        """The claw servo's multi-turn count restarted: counts taken before are not
        comparable (a claw span from them could point the wrong way round). The
        recorded angles in the turn and the direction stay valid."""
        self._claw_marks.clear()
        self._arm_counts = None
        self._arm_zero_counts = None

    def _claw_gripped(self, res) -> bool:
        """#192: a claw closing on something stops just short of the recorded closed angle and
        keeps pressing: the firmware then answers TIMEOUT with the torque still on. That is a
        grip, not a failure, when it stopped within backend.claw_grip_tolerance_deg of the
        target (0 = never). Farther away, or with the torque off, it stays a failure."""
        tol = max(getattr(self.cfg, "claw_grip_tolerance_deg", 0.0), 0.0)
        if tol <= 0 or res.result != "TIMEOUT" or res.target is None or res.actual is None:
            return False
        if "torque=ON" not in res.raw:
            return False
        return abs(res.target - res.actual) * 360.0 / COUNTS_PER_TURN <= tol

    async def _claw_turn_result(self, r, closing: bool = False) -> None:
        """Check a SERVO_TURN 2 reply; raise RobotCommandError when it failed. closing: the
        turn goes to the recorded closed angle (a grip that stops just short of it is fine)."""
        res = P.parse_servo_result(r.completion or "")
        if closing and res is not None and self._claw_gripped(res):
            log.info("claw closed on something %d counts short of its closed angle: a grip (%s)",
                     abs(res.target - res.actual), res.raw)
            return
        if res is not None and "multi_turn_lost" in res.raw:
            # refused unmoved: the servo's power was cut, or its limits were not read (#348)
            if await self._claw_limits_one_turn() is True:
                # the power was cut: the next turn goes through but its counts restart
                # from the angle in the turn
                self._forget_arm_counts()
                self.error = CLAW_SERVO_RESET_MSG
                raise ServoFailed(self.error)
            self._arm_resync_needed = True
            self.error = (r.completion or "") + " (limits not one-turn: not a power cut, trying again)"
            raise ServoPositionUnknown(self.error)
        if res is not None and not res.ok and is_servo_position_unknown(res.raw):
            self._arm_resync_needed = True  # #348: where the claw is must be taken back first
            self.error = r.completion or "arm servo failed"
            raise ServoPositionUnknown(self.error)
        if res is None or not res.ok:
            self.error = r.completion or "arm servo failed"
            if res is not None and is_servo_no_reply(res.raw):
                raise ServoNoReply(self.error)  # #344: refused unmoved, the bus did not answer
            # a servo result: the command ended (#269); no result line: not known
            raise ServoFailed(self.error) if res is not None else RobotCommandError(self.error)

    async def grab(self, close: bool) -> None:
        self._require()
        turns = self.cfg.arm_open_turns * (1.0 if close else -1.0)
        self._busy = True
        self._state = MachineState.GRABBING if close else MachineState.RELEASING
        try:
            if self.claw.complete():  # recorded positions win over the fixed relative turn
                await self._read_arm()
                turns = self._claw_delta("closed" if close else "open") / 360.0
                if abs(turns) < CLAW_TOLERANCE_DEG / 360.0:
                    return
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            r = await self.serial.send(P.cmd_servo_turn(ARM_SERVO_ID, turns), timeout=15.0)
            await self._claw_turn_result(r, closing=close and self.claw.complete())
            await self._refresh_arm()  # the same servo as arm_step: keep its angle current
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._state = MachineState.IDLE

    # ------------------------------------------------------------ claw (manual)
    async def arm_step(self, deg: float) -> None:
        """Turn the claw servo by `deg` degrees (SERVO_TURN 2, relative; TEST_MODE ON).

        Relative on purpose: SERVO_ANGLE takes the shorter way round to an angle in
        the turn, which can swing a claw with a limited range into its stop."""
        if not math.isfinite(deg) or abs(deg) > ARM_STEP_MAX_DEG:
            raise RobotCommandError(f"arm_step: deg must be within +-{ARM_STEP_MAX_DEG:.0f}")
        self._require(homed=False)  # a servo: no XY homing needed
        if deg == 0.0:
            return
        self._busy = True
        try:
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            r = await self.serial.send(P.cmd_servo_turn(ARM_SERVO_ID, deg / 360.0), timeout=15.0)
            await self._claw_turn_result(r)
            await self._read_arm()
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False

    async def _claw_limits_one_turn(self) -> bool | None:
        """#348: True = the claw servo is back to one turn, False = multi-turn, None = not known."""
        try:
            st = await self.serial.servo_status(ARM_SERVO_ID)
        except SerialError:
            return None
        if not st.ok or st.limits is None:
            return None
        return st.limits != (0, 0)

    async def _resync_claw(self) -> bool:
        """#348: as RealZMixin._resync_z, for the claw (the nudge: the smallest turn, either way;
        pressing on a capsule it stalls and still says where it is)."""
        if not self._arm_resync_needed:
            return True
        try:
            st = await self.serial.servo_status(ARM_SERVO_ID)
        except SerialError:
            return False
        if not st.ok or st.limits is None:
            return False
        if st.limits != (0, 0):
            self._arm_resync_needed = False
            self._forget_arm_counts()
            self.error = CLAW_SERVO_RESET_MSG
            raise ServoFailed(f"{self.error} ({st.raw})")
        if str(st.extra.get("moving", "")) != "0":
            return False
        if st.tracking and not st.tracking_lost and st.abs_counts is not None:
            self._arm_resync_needed = False
            self._arm_counts = st.abs_counts
            return True
        try:
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            r = await self.serial.send(P.cmd_servo_turn(ARM_SERVO_ID, SERVO_NUDGE_TURNS), timeout=10.0)
        except (CommandTimeout, CommandRejected, SerialError) as e:
            log.warning("claw resync: %s", e)
            return False
        return self._took_back(ARM_SERVO_ID, r.completion or "")

    async def _read_arm(self) -> None:
        if self._arm_resync_needed and not await self._resync_claw():
            raise ServoPositionUnknown(CLAW_RESYNC_MSG)  # #348: the count would be a stale one
        st = await self.serial.servo_status(ARM_SERVO_ID)
        if not st.ok or st.abs_counts is None:
            msg = f"SERVO_STATUS {ARM_SERVO_ID} failed: {st.raw}"
            # #344: nothing was sent to turn: a sequence may try again
            raise ServoNoReply(msg) if is_servo_no_reply(st.raw) else RobotCommandError(msg)
        self._arm_counts = st.abs_counts

    def _claw_delta(self, which: str) -> float:
        assert self._arm_counts is not None
        return self.claw.delta_to(which, deg_in_turn(self._arm_counts))

    async def arm_set(self, which: str) -> None:
        if which not in CLAW_WHICH:
            raise RobotCommandError(f"arm_set: which must be one of {CLAW_WHICH}")
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        try:
            await self._read_arm()
        except (CommandTimeout, CommandRejected, SerialError) as e:
            raise RobotCommandError(str(e)) from e
        assert self._arm_counts is not None
        self.claw.mark(which, deg_in_turn(self._arm_counts), self._claw_marks, self._arm_counts)
        self.claw.save(self.cfg.arm_calibration_path)
        log.info("claw %s set at %.1f deg (span %s)", which, deg_in_turn(self._arm_counts), self.claw.span_deg)

    async def arm_goto(self, which: str) -> None:
        if which not in CLAW_WHICH:
            raise RobotCommandError(f"arm_goto: which must be one of {CLAW_WHICH}")
        if not self.claw.complete():
            raise RobotCommandError("claw open / closed positions not both set (arm_set)")
        self._require(homed=False)
        self._busy = True
        try:
            await self._read_arm()
            deg = self._claw_delta(which)
            if abs(deg) < CLAW_TOLERANCE_DEG:
                return
            await self._wait_jog_ended()
            await self._ensure_test_mode()
            r = await self.serial.send(P.cmd_servo_turn(ARM_SERVO_ID, deg / 360.0), timeout=15.0)
            await self._claw_turn_result(r, closing=which == "closed")
            await self._refresh_arm()
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False

    async def _wait_jog_ended(self, timeout: float = JOG_END_WAIT_S) -> None:
        """A servo command sent while a jog (or its ramp-down after the key was let go)
        is still running is refused by the firmware (NACK ... jog_active): wait for it."""
        t_end = time.monotonic() + timeout
        while (self._jogging or self._jog_requested or (self._z_ramp_task and not self._z_ramp_task.done())):
            if time.monotonic() > t_end:
                raise RobotCommandError("busy: jog still running")
            await asyncio.sleep(0.02)

    async def _refresh_arm(self) -> None:
        """Re-read the claw after it moved; if that fails, show it as not read."""
        try:
            await self._read_arm()
        except (RobotCommandError, CommandTimeout, CommandRejected, SerialError):
            self._arm_counts = None

    async def arm_zero(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        try:
            await self._read_arm()
        except (CommandTimeout, CommandRejected, SerialError) as e:
            raise RobotCommandError(str(e)) from e
        self._arm_zero_counts = self._arm_counts

    def _arm_deg(self) -> float | None:
        if self._arm_counts is None:
            return None
        if self._arm_zero_counts is None:
            return (self._arm_counts % COUNTS_PER_TURN) * 360.0 / COUNTS_PER_TURN
        return (self._arm_counts - self._arm_zero_counts) * 360.0 / COUNTS_PER_TURN
