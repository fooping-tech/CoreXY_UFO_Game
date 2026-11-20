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
from ..serial_service.service import SERIAL_SILENT_MSG, CommandRejected, CommandTimeout, SerialError, SerialService
from .claw import ClawCalibration
from .interface import RobotCommandError, RobotInterface
from .state import MachineState, RobotSnapshot
from .z_calibration import ZCalibration

log = logging.getLogger(__name__)

from .real_claw import RealClawMixin
from .real_constants import *  # noqa: F401,F403 (the names this module always had)
from .real_z import RealZMixin


class RealRobot(RealZMixin, RealClawMixin, RobotInterface):
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
        # #106: the last session's points and the drum at rest, in that session's counts
        self._z_saved: dict = self._load_z_points()
        self._z_saved_t = 0.0
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
        # #163: servos whose jog the firmware refused until their power is cut and restored
        # (`JOG servo id=N disabled reason=unknown_turn_count ... (power-cycle servo)`)
        self.servo_power_cycle: set[int] = set()
        self._busy = False
        self._last_poll = 0.0
        self._last_z_poll = 0.0
        self._z_poll_interval = 1.0 / max(cfg.z_poll_hz, 0.1)
        self._poll_interval = 1.0 / max(cfg.status_poll_hz, 0.5)
        self.serial.add_listener(self._on_line)
        # #161: the link was lost while running: reopen the port (from tick)
        self._reopen_wanted = False
        self._reopen_at = 0.0

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
        # a jog of the lost link is over for the host (the next link starts afresh)
        self._cancel_z_ramp()
        self._jogging = self._jog_requested = False
        self.servo_power_cycle.clear()  # unknown on the next link: its next jog tells again
        if self.cfg.serial_reopen_s > 0:
            self._reopen_wanted = True
            self._reopen_at = time.monotonic() + self.cfg.serial_reopen_s

    async def _drop_silent_link(self, silent_s: float) -> None:
        """#161: commands go out but nothing comes back (e.g. the USB hub's transaction
        error stopped the reading side; writes still reach the firmware). Stop what may be
        moving with the writes alone, best effort (unconfirmed: this guarantees nothing),
        then drop the link like a lost one."""
        try:
            if self._jogging or self._jog_requested or self._z_rate:
                self.serial.write_raw(P.cmd_jog(0.0, 0.0))
            if self._busy:
                self.serial.write_raw("ABORT")
        except Exception as e:  # pragma: no cover - the writes may be dead too
            log.warning("stop on a silent link not sent: %s", e)
        await self.serial.drop_link(
            f"{SERIAL_SILENT_MSG} ({silent_s:.0f} s without a reply)")

    async def _reopen(self, now: float) -> None:
        if now < self._reopen_at:
            return
        self._reopen_at = now + self.cfg.serial_reopen_s
        reason = self.error
        try:
            await self.connect()
        except Exception as e:
            log.info("serial reopen failed: %s", e)
            self.error = reason  # still why the link is down
            return
        if not self.serial.connected:
            # lost again while connecting: _on_serial_lost asked for the next try; say why
            # (not connect()'s "no POS reply")
            self.error = self.serial.last_error or reason
            return
        self._reopen_wanted = False
        self.error = ""
        log.warning("serial link reopened on %s (motors disabled: enable them again)", self.serial.port)

    def recent_log(self, n: int = 50) -> list[str]:
        return list(self.serial.log_lines)[-n:]

    # ---------------------------------------------------------------- parsing
    def _on_line(self, line: str) -> None:
        kind = P.classify_line(line)
        if kind in ("jog_pos", "jog_start", "jog_end", "jog_rejected", "stop_done"):
            self._on_jog_line(kind, line)
        elif kind == "jog_servo":
            self._on_jog_servo(line)
        elif kind == "servo_status":
            self._note_power_cycled(line)
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

    def _end_jog_session(self) -> None:
        if self.serial.connected:
            self.serial.write_raw(P.cmd_jog(0.0, 0.0))
        self._z_rate = 0
        self._z_ramp_from = 0
        self._jog_requested = False
        self._last_jog_t = 0.0  # the next non-zero JOG is a new press

    async def jog(self, vx_mm_s: float, vy_mm_s: float, vz_units_s: float = 0.0, *, z_free: bool = False) -> None:
        at_z_limit = False
        if vz_units_s and not z_free and self._z_limits_apply():
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
        cap = self.jog_cap(max(self.cfg.jog_max_mm_s, 0.0))
        if speed > cap > 0:
            vx_mm_s, vy_mm_s = vx_mm_s * cap / speed, vy_mm_s * cap / speed
        vx_mm_s, vy_mm_s = self._jog_inside_edges(vx_mm_s, vy_mm_s)
        new_press = now - self._last_jog_t > P.JOG_TIMEOUT_S  # firmware's notion of a press
        self._last_jog_t = now
        if new_press and self.error.startswith(("jog rejected", "jog ended")):
            self.error = ""  # the firmware reports again if it still refuses this press
        self.serial.write_raw(P.cmd_jog(vx_mm_s, vy_mm_s, z_send))
        self._z_rate = z_send
        self._jog_requested = True

    def _jog_inside_edges(self, vx: float, vy: float) -> tuple[float, float]:
        """#185: the jog's XY velocity kept jog_edge_margin_mm inside the soft limits: the part
        that heads for an edge is slowed with the distance left to that line and is zero on
        it (or beyond it: only the way back is allowed). The firmware's own soft limit stays
        behind this one; the home corner's limit switches are never reached by a jog."""
        margin = self.cfg.jog_edge_margin_mm
        if margin <= 0:
            return vx, vy
        slow = self.cfg.jog_edge_slow_s
        lim = self.limits
        s = self.snapshot()

        def one(v: float, at: float, lo: float, hi: float) -> float:
            if v == 0:
                return 0.0
            left = (hi - margin - at) if v > 0 else (at - lo - margin)
            if left <= 0:
                return 0.0
            cap = left / slow if slow > 0 else abs(v)
            return math.copysign(min(abs(v), cap), v)

        return one(vx, s.x, lim.x_min, lim.x_max), one(vy, s.y, lim.y_min, lim.y_max)

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
        now = time.monotonic()
        if self.serial.connected:
            silent = self.serial.rx_stalled_for(now)
            if self.cfg.serial_rx_stall_s > 0 and silent >= self.cfg.serial_rx_stall_s:
                await self._drop_silent_link(silent)
                return
        elif self._reopen_wanted:
            await self._reopen(now)
            return
        if not self.serial.connected or self._busy:
            return
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
                    self._remember_z_rest(st)
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
            z_servo_power_cycle=Z_SERVO_ID in self.servo_power_cycle,
            arm_servo_power_cycle=ARM_SERVO_ID in self.servo_power_cycle,
            arm_deg=self._arm_deg(), arm_reference_set=self._arm_zero_counts is not None,
            arm_closed_deg=self.claw.closed_deg, arm_open_deg=self.claw.open_deg, arm_span_deg=self.claw.span_deg,
            limit_x=self._limits_active[0] and self._limits_current(x, y, measured),
            limit_y=self._limits_active[1] and self._limits_current(x, y, measured),
        )

    def _limits_current(self, x: float, y: float, measured: bool) -> bool:
        """The last switch reading still describes where the machine is."""
        return (measured and self._limits_xy is not None
                and abs(self._limits_xy[0] - x) < 0.01 and abs(self._limits_xy[1] - y) < 0.01)
