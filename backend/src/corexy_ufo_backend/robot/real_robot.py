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
the drum servo's absolute count (`SERVO_STATUS 1 abs=`), relative to the
count captured by `set_z_zero` (the firmware has no Z homing).
"""

from __future__ import annotations

import asyncio
import logging
import math
import time

from ..config import BackendConfig
from ..serial_service import protocol as P
from ..serial_service.service import CommandRejected, CommandTimeout, SerialError, SerialService
from .interface import RobotCommandError, RobotInterface
from .state import MachineState, RobotSnapshot

log = logging.getLogger(__name__)

COUNTS_PER_TURN = 4096
MAX_TURNS_PER_COMMAND = 3.0
Z_SERVO_ID = 1
ARM_SERVO_ID = 2
SERVO_SPEED_COUNTS_PER_S = 2400.0


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
        self._state = MachineState.UNKNOWN
        self._pos_xy = [0.0, 0.0]
        self._xy_measured = False
        self._jogging = False
        self._jog_requested = False  # a non-zero JOG was sent and not yet ended
        self._move_from: tuple[float, float] | None = None
        self._move_to: tuple[float, float] | None = None
        self._move_t0 = 0.0
        self._move_eta = 0.0
        self._z_counts: int | None = None  # servo abs counts, last known
        self._z_zero_counts: int | None = None
        self._z_units_est: float = cfg.limits.z_max if cfg.limits.z_up_is_positive else cfg.limits.z_min
        self._z_measured = False
        self._busy = False
        self._last_poll = 0.0
        self._poll_interval = 1.0 / max(cfg.status_poll_hz, 0.5)
        self.serial.add_listener(self._on_line)

    # ---------------------------------------------------------------- lifecycle
    async def connect(self) -> None:
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
        except SerialError:
            pass

    async def disconnect(self) -> None:
        # Best effort: never leave the machine moving when the host goes away.
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
            self.error = "firmware rebooted"

    def _on_jog_line(self, kind: str, line: str) -> None:
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
        if not enable and (self._jogging or self._jog_requested):
            self.serial.write_raw(P.cmd_jog(0.0, 0.0))
        if not enable and self._busy:
            await self.stop()

    async def home(self) -> None:
        self._require(homed=False)
        self._busy = True
        self._state = MachineState.HOMING
        try:
            r = await self.serial.send("HOME", timeout=90.0)
            if not r.completion or not r.completion.startswith("HOME complete"):
                self.error = r.completion or "homing failed"
                raise RobotCommandError(self.error)
            self.homed = True
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

    def _z_units_from_counts(self, counts: int) -> float:
        if self._z_zero_counts is None:
            return self._z_units_est
        base = self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min
        delta_units = (counts - self._z_zero_counts) * self.cfg.z_sign / self.cfg.z_counts_per_unit
        # z_zero is captured with the arm at its TOP (highest) position.
        if self.limits.z_up_is_positive:
            return base + delta_units
        return base - delta_units

    async def set_z_zero(self) -> None:
        """Define the current drum position as 'arm at top' (Z reference)."""
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        st = await self.serial.servo_status(Z_SERVO_ID)
        if not st.ok or st.abs_counts is None:
            raise RobotCommandError(f"SERVO_STATUS {Z_SERVO_ID} failed: {st.raw}")
        self._z_counts = st.abs_counts
        self._z_zero_counts = st.abs_counts
        self._z_units_est = self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min
        self._z_measured = True

    async def move_z(self, z: float) -> None:
        self._require()
        if self._z_zero_counts is None:
            raise RobotCommandError("Z reference not set (send z_zero with the arm at the top)")
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
            await self._ensure_test_mode()
            remaining = total_turns
            while abs(remaining) > 1e-3:
                chunk = max(-MAX_TURNS_PER_COMMAND, min(MAX_TURNS_PER_COMMAND, remaining))
                eta = abs(chunk) * COUNTS_PER_TURN / SERVO_SPEED_COUNTS_PER_S + 3.0
                r = await self.serial.send(P.cmd_servo_turn(Z_SERVO_ID, chunk), timeout=eta + 5.0)
                res = P.parse_servo_result(r.completion or "")
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
            await self._ensure_test_mode()
            r = await self.serial.send(P.cmd_servo_turn(ARM_SERVO_ID, turns), timeout=15.0)
            res = P.parse_servo_result(r.completion or "")
            if res is None or not res.ok:
                self.error = r.completion or "arm servo failed"
                raise RobotCommandError(self.error)
        except (CommandTimeout, CommandRejected, SerialError) as e:
            self.error = str(e)
            raise RobotCommandError(str(e)) from e
        finally:
            self._busy = False
            self._state = MachineState.IDLE

    async def jog(self, vx_mm_s: float, vy_mm_s: float) -> None:
        stopping = vx_mm_s == 0 and vy_mm_s == 0
        if stopping:
            # always allowed: ends the session (and re-arms after a rejected press)
            if self.serial.connected:
                self.serial.write_raw(P.cmd_jog(0.0, 0.0))
            self._jog_requested = False
            return
        self._require()  # connected, motors enabled, no alarm, homed, no XY move running
        speed = math.hypot(vx_mm_s, vy_mm_s)
        cap = max(self.cfg.jog_max_mm_s, 0.0)
        if speed > cap > 0:
            vx_mm_s, vy_mm_s = vx_mm_s * cap / speed, vy_mm_s * cap / speed
        self.serial.write_raw(P.cmd_jog(vx_mm_s, vy_mm_s))
        self._jog_requested = True

    async def soft_stop(self) -> None:
        if not self.serial.connected:
            raise RobotCommandError("not connected")
        # Outside the serial lock (like ABORT) so it reaches the firmware while an XY
        # move is waiting for ACK_XY; that move then fails with NACK_XY reason=stopped.
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

    # ---------------------------------------------------------------- polling
    async def tick(self) -> None:
        if not self.serial.connected or self._busy:
            return
        now = time.monotonic()
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
            timestamp_ms=int(time.time() * 1000), z_reference_set=self._z_zero_counts is not None,
        )
