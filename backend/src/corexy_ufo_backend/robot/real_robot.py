"""RealRobot: drives the M5Stack Core2 firmware through SerialService.

Mapping of game commands onto the firmware (see docs/firmware_protocol.md):

  enable_motors  -> nothing is sent; it only arms this backend. Z/arm need
                    `TEST_MODE ON`, which is sent on the first Z/arm command.
  home           -> `HOME`              wait `HOME complete`
  move_xy        -> `XY x y F`          wait `ACK_XY` / `NACK_XY`
  move_z         -> `SERVO_TURN 1 t`    (chunks of <= 3 turns) wait result=
  grab/release   -> `SERVO_TURN 2 ±t`   wait result=
  stop           -> `ABORT`             (firmware sets ALARM + clears HOMED)
  soft_stop      -> `STOP`              wait `STOP complete` (decelerates, no alarm, stays homed)
  jog vx vy      -> `JOG vx vy`         fire-and-forget, refreshed by the client at ~20 Hz;
                                        `JOG start` / `JOG_POS` / `JOG end` update the state
  clear_alarm    -> `ALARM_CLEAR`

Position: XY is read from `POS` when the machine is idle (measured). During
an XY move the firmware does not answer POS, so the position is estimated by
linear interpolation from start to target (measured=False). During a jog the
firmware reports `JOG_POS` every 50 ms (measured). Z is tracked from
the drum servo's absolute count (`SERVO_STATUS 1 abs=`), relative to a point
recorded by hand (the firmware has no Z homing): `set_z_point("top")` (= z_zero,
the arm wound up) and / or `set_z_point("bottom")` (the arm lowered). With both,
the counts per unit and the drum's direction are measured (ZCalibration, saved)
instead of taken from the config. The recorded counts only hold for one firmware
session: a reboot, a new link or a lost one forgets them.
"""

from __future__ import annotations

import asyncio
import logging
import math
import time

from ..config import BackendConfig
from ..serial_service import protocol as P
from ..serial_service.service import CommandRejected, CommandTimeout, SerialError, SerialService
from .claw import WHICH as CLAW_WHICH
from .claw import ClawCalibration, deg_in_turn
from .interface import RobotCommandError, RobotInterface
from .state import MachineState, RobotSnapshot
from .z_calibration import CLEAR as Z_CLEAR
from .z_calibration import WHICH as Z_WHICH
from .z_calibration import ZCalibration

log = logging.getLogger(__name__)

COUNTS_PER_TURN = 4096
MAX_TURNS_PER_COMMAND = 3.0
Z_SERVO_ID = 1
ARM_SERVO_ID = 2
# arm_step: largest single manual step of the claw servo (degrees)
ARM_STEP_MAX_DEG = 90.0
CLAW_TOLERANCE_DEG = 0.5  # already there: no turn
JOG_END_WAIT_S = 2.0  # how long a servo command waits for a jog (and its ramp) to end
SERVO_SPEED_COUNTS_PER_S = 2400.0
# Z jog release ramp. The firmware's servo jog holds the position it last READ when
# the rate drops to 0; at speed that read lags the drum, so the servo overshoots and
# swings back ("reverses for a moment" on W/S release; the joystick's analog stick
# never drops the rate at once). Ramping the rate down first lets it stop cleanly.
# Ease-out (rate * f^2): the last steps are very slow, so the hanging arm is not
# thrown up and does not drop back when a raise (W) stops.
Z_RAMP_S = 0.35
# The drum servo alone lost power (operators cut it): it is back to one turn
# (limits 0/4095) while the firmware still tracks turns, so a jog stops silently
# at the end of that turn and the turn count is gone.
Z_SERVO_RESET_MSG = ("Z servo reset (its power was cut): a jog stops at the end of one turn "
                     "and the drum's turn count is lost; recover it (z_servo_recover), "
                     "then record the Z points again")
# Newer firmware (CoreXY_UFO #11) reports the same state as `tracking=LOST` and sets
# multi-turn again when the next jog starts (`JOG servo id=1 ... tracking=RESET`):
# no recovery command is needed, but the turn count is still gone.
Z_SERVO_LOST_MSG = ("Z servo reset (its power was cut): the drum's turn count is lost; "
                    "jog Z (the first press sets multi-turn again), then record the Z points again")
CLAW_SERVO_RESET_MSG = ("claw servo reset (its power was cut): its recorded counts are gone; "
                        "press again (the firmware refused this one before moving)")
# z_servo_recover: a SERVO_TURN this small (up), refused unmoved while the servo is reset
Z_RECOVER_TURNS = 0.01
Z_RAMP_STEP_S = 0.04


class RealRobot(RobotInterface):
    name = "real"

    def __init__(self, cfg: BackendConfig, serial: SerialService | None = None) -> None:
        self.cfg = cfg
        self.serial = serial or SerialService(cfg.serial_port or None, cfg.baudrate)
        self.serial.set_disconnect_callback(self._on_serial_lost)
        self.limits = cfg.limits
        self.motors_enabled = False
        self.homed = False
        self.alarm = False
        self.error = ""
        self.test_mode = False
        self.claw = ClawCalibration.load(cfg.arm_calibration_path)
        self._claw_marks: dict[str, int] = {}  # multi-turn counts of this session's marks
        self._z_cfg_default = (cfg.z_counts_per_unit, cfg.z_sign)  # the config's guess, for z_set clear
        self.z_cal = ZCalibration.load(cfg.z_calibration_path)
        if self.z_cal.complete():
            self._apply_z_cal()
        self._state = MachineState.UNKNOWN
        self._pos_xy = [0.0, 0.0]
        self._xy_measured = False
        # POS LIMIT_X / LIMIT_Y and the XY of that same POS: the switches are only
        # reported while the machine is still there (not paired with a later or
        # estimated position: the firmware does not answer POS during a move)
        self._limits_active = (False, False)
        self._limits_xy: tuple[float, float] | None = None
        self._jogging = False
        self._jog_requested = False  # a non-zero JOG was sent and not yet ended
        self._last_jog_t = 0.0  # when the last non-zero JOG was written
        self._z_rate = 0  # Z counts/s last sent
        self._z_ramp_from = 0  # Z rate being ramped down to 0 (0 = no ramp)
        self._z_ramp_t0 = 0.0
        self._z_ramp_task: asyncio.Task | None = None
        self._move_from: tuple[float, float] | None = None
        self._move_to: tuple[float, float] | None = None
        self._move_t0 = 0.0
        self._move_eta = 0.0
        self._z_counts: int | None = None  # servo abs counts, last known
        self._arm_counts: int | None = None  # claw servo abs counts, last read
        self._arm_zero_counts: int | None = None  # arm_zero reference
        # drum counts of this session's Z points: arm at its top / at its bottom
        self._z_top_counts: int | None = None
        self._z_bottom_counts: int | None = None
        self._z_units_est: float = cfg.limits.z_max if cfg.limits.z_up_is_positive else cfg.limits.z_min
        self._z_measured = False
        self.z_servo_reset = False  # see Z_SERVO_RESET_MSG
        # the firmware said LOST: its next Z jog sets multi-turn again by itself
        self.z_servo_jog_recovers = False
        self._busy = False
        self._last_poll = 0.0
        self._last_z_poll = 0.0
        self._z_poll_interval = 1.0 / max(cfg.z_poll_hz, 0.1)
        self._poll_interval = 1.0 / max(cfg.status_poll_hz, 0.5)
        self.serial.add_listener(self._on_line)

    # ---------------------------------------------------------------- lifecycle
    async def connect(self) -> None:
        self._claw_marks.clear()  # a new link may mean a restarted firmware count
        self._forget_z_points()
        await self.serial.connect()
        try:
            pos = await self.serial.query_pos()
            self._apply_pos(pos)
        except SerialError as e:
            self.error = f"no POS reply: {e}"
            log.warning(self.error)
        try:
            st = await self.serial.servo_status(Z_SERVO_ID)
            if st.ok and st.abs_counts is not None:
                self._z_counts = st.abs_counts
            self._note_z_status(st)
        except SerialError:
            pass

    async def disconnect(self) -> None:
        # Best effort: never leave the machine moving when the host goes away.
        self._cancel_z_ramp()
        if self.serial.connected and (self._jogging or self._jog_requested):
            try:
                self.serial.write_raw(P.cmd_jog(0.0, 0.0))
            except Exception:  # pragma: no cover
                pass
        if self.serial.connected and self._busy:
            try:
                self.serial.write_raw("ABORT")
            except Exception:  # pragma: no cover
                pass
        await self.serial.disconnect()
        self.motors_enabled = False

    def _on_serial_lost(self) -> None:
        self._claw_marks.clear()
        self._forget_z_points()
        self.motors_enabled = False
        self._state = MachineState.UNKNOWN
        self.error = self.serial.last_error

    def recent_log(self, n: int = 50) -> list[str]:
        return list(self.serial.log_lines)[-n:]

    # ---------------------------------------------------------------- parsing
    def _on_line(self, line: str) -> None:
        kind = P.classify_line(line)
        if kind in ("jog_pos", "jog_start", "jog_end", "jog_rejected", "stop_done"):
            self._on_jog_line(kind, line)
        elif kind == "jog_servo":
            self._on_jog_servo(line)
        elif kind == "pos":
            pos = P.parse_pos_line(line)
            if pos:
                self._apply_pos(pos)
        elif kind == "reject" or kind == "error":
            self.error = line
        elif kind == "boot":
            # firmware rebooted under us: everything is unknown again
            self.homed = False
            self.test_mode = False
            self._z_counts = None
            # the multi-turn counts restart from the angle in the turn: counts taken
            # before are not comparable any more (a claw span from them could point
            # the wrong way round); the recorded angles and direction stay valid
            self._forget_z_points()  # same for Z: the recorded points no longer match
            self._forget_arm_counts()
            self.error = "firmware rebooted"

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

    def _on_jog_line(self, kind: str, line: str) -> None:
        if kind == "jog_pos":
            z_abs = P.z_abs_from(line)
            if z_abs is not None:
                self._apply_z_counts(z_abs)
        xy = P.xy_from(line)
        if xy and kind in ("jog_pos", "jog_end", "stop_done"):
            self._pos_xy = [xy[0], xy[1]]
            self._xy_measured = True
        kv = P.parse_kv(line)
        if kind == "jog_start":
            self._jogging = True
            self._state = MachineState.MOVING_XY
            if self.error.startswith("jog rejected"):
                self.error = ""
        elif kind == "jog_end":
            self._jogging = False
            self._jog_requested = False
            self.homed = kv.get("HOMED", "YES" if self.homed else "NO") == "YES"
            if not self._busy:
                self._state = MachineState.IDLE
            if kv.get("reason") in ("abort", "alarm", "limit_x", "limit_y"):
                self.error = "jog ended: " + kv["reason"]
        elif kind == "jog_rejected":
            self._jog_requested = False
            self.error = "jog rejected: " + kv.get("reason", line)
        elif kind == "stop_done":
            self._jogging = False
            self._jog_requested = False
            self.homed = kv.get("HOMED", "YES" if self.homed else "NO") == "YES"

    def _apply_pos(self, pos: P.PosReport) -> None:
        self._pos_xy = [pos.x, pos.y]
        self._xy_measured = True
        self.homed = pos.homed
        self.alarm = pos.alarm
        self.test_mode = pos.test_mode
        self._limits_active = (pos.limit_x, pos.limit_y)
        self._limits_xy = (pos.x, pos.y)
        if pos.alarm:
            self.error = pos.alarm_reason
        elif self.error.startswith("alarm") or self.error == "abort requested":
            self.error = ""

    # ---------------------------------------------------------------- guards
    def _require(self, *, homed: bool = True) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        if not self.motors_enabled:
            raise RobotCommandError("motors not enabled (send enable_motors first)")
        if self.alarm:
            raise RobotCommandError(f"alarm active: {self.error}")
        if homed and not self.homed:
            raise RobotCommandError("not homed")
        if self._busy:
            raise RobotCommandError("busy")

    async def _ensure_test_mode(self) -> None:
        if self.test_mode:
            return
        r = await self.serial.send("TEST_MODE ON", timeout=5.0)
        if r.completion and "result=ON" in r.completion:
            self.test_mode = True
        else:
            raise RobotCommandError(f"TEST_MODE ON refused: {r.completion}")

    # ---------------------------------------------------------------- commands
    async def enable_motors(self, enable: bool) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        self.motors_enabled = enable
        if not enable:
            self._cancel_z_ramp()
        if not enable and (self._jogging or self._jog_requested):
            self.serial.write_raw(P.cmd_jog(0.0, 0.0))
        if not enable and self._busy:
            await self.stop()

    def _home_z_refusal(self) -> str:
        """Why XY may not home now ("" = it may): the arm must be wound up first."""
        if not self.cfg.home_requires_z_top:
            return ""
        if self._z_reference() is None:
            return "Z reference not set: wind the arm up and record its top (z_set top) before homing"
        top = self._z_point_units("top")
        if abs(self._z_units_est - top) > self.cfg.home_z_tolerance:
            return (f"the arm is not wound up (Z {self._z_units_est:.1f}, top {top:.0f}): "
                    "raise it to the top before homing")
        return ""

    async def home(self) -> None:
        self._require(homed=False)
        why = self._home_z_refusal()
        if why:
            raise RobotCommandError(why)
        self._busy = True
        self._state = MachineState.HOMING
        try:
            r = await self.serial.send("HOME", timeout=90.0)
            if not r.completion or not r.completion.startswith("HOME complete"):
                self.error = r.completion or "homing failed"
                raise RobotCommandError(self.error)
            self.homed = True
            if self.error.startswith(("jog rejected", "jog ended")):
                self.error = ""  # homing fixed what the jog refusal was about
            self.alarm = False
            self._pos_xy = [0.0, 0.0]
            self._xy_measured = True
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._state = MachineState.IDLE

    async def move_xy(self, x: float, y: float, feed: float | None = None) -> None:
        self._require()
        if not self.limits.xy_inside(x, y):
            raise RobotCommandError(f"XY ({x:.1f},{y:.1f}) outside soft limits")
        feed = feed or self.cfg.xy_feed_mm_min
        dist = math.hypot(x - self._pos_xy[0], y - self._pos_xy[1])
        self._busy = True
        self._state = MachineState.MOVING_XY
        self._move_from = (self._pos_xy[0], self._pos_xy[1])
        self._move_to = (x, y)
        self._move_t0 = time.monotonic()
        self._move_eta = dist / max(feed / 60.0, 1.0) + 0.15
        self._xy_measured = False
        try:
            r = await self.serial.send(P.cmd_xy(x, y, feed), timeout=self._move_eta + 20.0)
            if r.completion and r.completion.startswith("ACK_XY"):
                self._pos_xy = [x, y]
            elif r.completion and "reason=stopped" in r.completion:
                # interrupted on purpose by soft_stop: not an error; the firmware says where it stopped
                xy = P.xy_from(r.completion)
                if xy:
                    self._pos_xy = [xy[0], xy[1]]
                    self._xy_measured = True
                raise RobotCommandError("stopped: " + r.completion)
            else:
                self.error = r.completion or "XY failed"
                raise RobotCommandError(self.error)
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._move_from = self._move_to = None
            self._state = MachineState.IDLE

    def _z_point_units(self, which: str) -> float:
        """Z of the arm at its top / bottom."""
        top = self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min
        bottom = self.limits.z_min if self.limits.z_up_is_positive else self.limits.z_max
        return top if which == "top" else bottom

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

    def _forget_arm_counts(self) -> None:
        """The claw servo's multi-turn count restarted: counts taken before are not
        comparable (a claw span from them could point the wrong way round). The
        recorded angles in the turn and the direction stay valid."""
        self._claw_marks.clear()
        self._arm_counts = None
        self._arm_zero_counts = None

    def _claw_turn_result(self, r) -> None:
        """Check a SERVO_TURN 2 reply; raise RobotCommandError when it failed."""
        res = P.parse_servo_result(r.completion or "")
        if res is not None and "multi_turn_lost" in res.raw:
            # the servo's power was cut: refused unmoved; the next turn goes through
            # but its counts restart from the angle in the turn
            self._forget_arm_counts()
            self.error = CLAW_SERVO_RESET_MSG
            raise RobotCommandError(self.error)
        if res is None or not res.ok:
            self.error = r.completion or "arm servo failed"
            raise RobotCommandError(self.error)

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
        log.info("Z %s set at %d counts", which, counts)

    async def move_z(self, z: float) -> None:
        self._require()
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
                chunk = max(-MAX_TURNS_PER_COMMAND, min(MAX_TURNS_PER_COMMAND, remaining))
                eta = abs(chunk) * COUNTS_PER_TURN / SERVO_SPEED_COUNTS_PER_S + 3.0
                r = await self.serial.send(P.cmd_servo_turn(Z_SERVO_ID, chunk), timeout=eta + 5.0)
                res = P.parse_servo_result(r.completion or "")
                if res is not None and "multi_turn_lost" in res.raw:
                    # the drum servo's power was cut: refused unmoved; the next turn
                    # goes through but its counts restart, so the Z points are gone
                    self._forget_z_points()
                    self.error = Z_SERVO_RESET_MSG
                    raise RobotCommandError(self.error)
                if res is None or not res.ok:
                    self.error = r.completion or "SERVO_TURN failed"
                    if res and res.actual is not None:
                        self._z_counts = res.actual
                        self._z_units_est = self._z_units_from_counts(res.actual)
                    raise RobotCommandError(self.error)
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
            self._claw_turn_result(r)
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
            self._claw_turn_result(r)
            await self._read_arm()
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False

    async def _read_arm(self) -> None:
        st = await self.serial.servo_status(ARM_SERVO_ID)
        if not st.ok or st.abs_counts is None:
            raise RobotCommandError(f"SERVO_STATUS {ARM_SERVO_ID} failed: {st.raw}")
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
            self._claw_turn_result(r)
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

    def _end_jog_session(self) -> None:
        if self.serial.connected:
            self.serial.write_raw(P.cmd_jog(0.0, 0.0))
        self._z_rate = 0
        self._z_ramp_from = 0
        self._jog_requested = False
        self._last_jog_t = 0.0  # the next non-zero JOG is a new press

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

    async def jog(self, vx_mm_s: float, vy_mm_s: float, vz_units_s: float = 0.0) -> None:
        at_z_limit = False
        if vz_units_s and self._z_limits_apply():
            # with a Z reference, never jog out of the 0..100 range
            z = self._z_units_est
            if (vz_units_s > 0 and z >= self.limits.z_max) or (vz_units_s < 0 and z <= self.limits.z_min):
                vz_units_s, at_z_limit = 0.0, True
        z_counts_s = int(round(vz_units_s * self._z_counts_per_unit_signed()))
        zcap = max(int(self.cfg.jog_z_max_counts_s), 0)
        z_counts_s = max(-zcap, min(zcap, z_counts_s))
        stopping = vx_mm_s == 0 and vy_mm_s == 0 and z_counts_s == 0
        if stopping or vx_mm_s or vy_mm_s or z_counts_s:
            if self._z_ramp_task and not self._z_ramp_task.done():
                self._z_ramp_task.cancel()  # a new request takes over from a running ramp
                self._z_ramp_task = None
        if at_z_limit:
            self._z_ramp_from = self._z_rate = 0  # at the end of the range: stop at once
        now = time.monotonic()
        z_send = self._ramped_z(z_counts_s, now)
        if stopping:
            # always allowed: ends the session (and re-arms after a rejected press)
            if z_send and self.serial.connected and self.motors_enabled:
                self.serial.write_raw(P.cmd_jog(0.0, 0.0, z_send))
                self._z_rate = z_send
                self._z_ramp_task = asyncio.get_running_loop().create_task(self._ramp_z_to_stop())
            else:
                self._end_jog_session()
            return
        if z_counts_s and self.z_servo_reset and not self.z_servo_jog_recovers:
            # older firmware: the jog would stop at the end of one turn, silently
            raise RobotCommandError(Z_SERVO_RESET_MSG)
        # connected, motors enabled, no alarm, no move running; XY also needs homing
        self._require(homed=bool(vx_mm_s or vy_mm_s))
        speed = math.hypot(vx_mm_s, vy_mm_s)
        cap = max(self.cfg.jog_max_mm_s, 0.0)
        if speed > cap > 0:
            vx_mm_s, vy_mm_s = vx_mm_s * cap / speed, vy_mm_s * cap / speed
        new_press = now - self._last_jog_t > P.JOG_TIMEOUT_S  # firmware's notion of a press
        self._last_jog_t = now
        if new_press and self.error.startswith(("jog rejected", "jog ended")):
            self.error = ""  # the firmware reports again if it still refuses this press
        self.serial.write_raw(P.cmd_jog(vx_mm_s, vy_mm_s, z_send))
        self._z_rate = z_send
        self._jog_requested = True

    async def soft_stop(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        # Outside the serial lock (like ABORT) so it reaches the firmware while an XY
        # move is waiting for ACK_XY; that move then fails with NACK_XY reason=stopped.
        self._cancel_z_ramp()
        try:
            done = await self.serial.soft_stop()
        except CommandTimeout as e:
            raise RobotCommandError("STOP not confirmed") from e
        self._on_jog_line("stop_done", done)
        self._move_from = self._move_to = None
        if not self._busy:
            self._state = MachineState.IDLE

    async def stop(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        self._cancel_z_ramp()
        self._state = MachineState.ESTOP
        await self.serial.abort()
        # Firmware semantics: ABORT raises the alarm and clears HOMED.
        self.alarm = True
        self.homed = False
        self.error = "abort requested"
        self._xy_measured = False

    async def clear_alarm(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        if self._busy:
            raise RobotCommandError("busy")
        r = await self.serial.send("ALARM_CLEAR", timeout=5.0)
        if r.completion:
            self.alarm = False
            self.error = ""
            self._state = MachineState.IDLE

    async def refresh_status(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        if self._busy or self._jogging or self._jog_requested:
            return  # the firmware does not answer POS during a move; the caller sees "busy"
        try:
            self._apply_pos(await self.serial.query_pos(timeout=3.0))
            self._last_poll = time.monotonic()
        except SerialError as e:
            raise RobotCommandError(f"POS failed: {e}") from e

    # ---------------------------------------------------------------- polling
    async def tick(self) -> None:
        if not self.serial.connected or self._busy:
            return
        now = time.monotonic()
        if (not self._jogging and not self._jog_requested
                and now - self._last_z_poll >= self._z_poll_interval and now - self._last_poll >= 0.05):
            # Track the drum servo when something else moves it (joystick, other tools).
            # During a jog JOG_POS carries Z_ABS instead.
            self._last_z_poll = now
            try:
                st = await self.serial.servo_status(Z_SERVO_ID, timeout=2.0)
                self._note_z_status(st)
                if st.ok and st.abs_counts is not None:
                    self._apply_z_counts(st.abs_counts)
            except SerialError:
                pass  # a missed sample is fine; the next poll retries
            return
        if now - self._last_poll < self._poll_interval:
            return
        self._last_poll = now
        try:
            pos = await self.serial.query_pos(timeout=3.0)
            self._apply_pos(pos)
            if pos.alarm:
                self._state = MachineState.ALARM
            elif pos.homing_active:
                self._state = MachineState.HOMING
            elif pos.motion:
                self._state = MachineState.MOVING_XY
            else:
                self._state = MachineState.IDLE
        except SerialError as e:
            self.error = f"POS poll failed: {e}"

    # ---------------------------------------------------------------- snapshot
    def _estimated_xy(self) -> tuple[float, float, bool]:
        if self._move_from and self._move_to:
            t = min(1.0, (time.monotonic() - self._move_t0) / max(self._move_eta, 1e-3))
            # smoothstep ~ trapezoid-ish profile
            s = t * t * (3 - 2 * t)
            return (
                self._move_from[0] + (self._move_to[0] - self._move_from[0]) * s,
                self._move_from[1] + (self._move_to[1] - self._move_from[1]) * s,
                False,
            )
        return (self._pos_xy[0], self._pos_xy[1], self._xy_measured)

    def snapshot(self) -> RobotSnapshot:
        x, y, measured = self._estimated_xy()
        return RobotSnapshot(
            connected=self.serial.connected, homed=self.homed, motors_enabled=self.motors_enabled,
            state=self._state, x=x, y=y, z=self._z_units_est, measured=measured and self._z_measured,
            alarm=self.alarm, error=self.error, test_mode=self.test_mode,
            timestamp_ms=int(time.time() * 1000), z_reference_set=self._z_reference() is not None,
            z_top_set=self._z_top_counts is not None, z_bottom_set=self._z_bottom_counts is not None,
            z_calibrated=self.z_cal.complete(), z_servo_reset=self.z_servo_reset,
            z_servo_jog_recovers=self.z_servo_reset and self.z_servo_jog_recovers,
            arm_deg=self._arm_deg(), arm_reference_set=self._arm_zero_counts is not None,
            arm_closed_deg=self.claw.closed_deg, arm_open_deg=self.claw.open_deg, arm_span_deg=self.claw.span_deg,
            limit_x=self._limits_active[0] and self._limits_current(x, y, measured),
            limit_y=self._limits_active[1] and self._limits_current(x, y, measured),
        )

    def _limits_current(self, x: float, y: float, measured: bool) -> bool:
        """The last switch reading still describes where the machine is."""
        return (measured and self._limits_xy is not None
                and abs(self._limits_xy[0] - x) < 0.01 and abs(self._limits_xy[1] - y) < 0.01)
