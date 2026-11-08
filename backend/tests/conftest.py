"""Fake firmware used by the serial/robot tests. It replies to commands with
the exact line formats the real firmware prints (see protocol.py)."""

from __future__ import annotations

import asyncio
import re

from corexy_ufo_backend.serial_service.transport import SerialTransport


class FakeFirmware(SerialTransport):
    """Drop-in SerialTransport that simulates the Core2 firmware."""

    def __init__(self, port: str = "fake", baudrate: int = 115200, *, startup_delay: float = 0.0, on_disconnect=None) -> None:
        super().__init__(port, baudrate, startup_delay=startup_delay, on_disconnect=on_disconnect)
        self.sent: list[str] = []
        self.x = 0.0
        self.y = 0.0
        self.homed = False
        self.alarm = False
        self.alarm_reason = "none"
        self.test_mode = False
        self.servo_abs = {1: 1000, 2: 0}
        # multi-turn tracking per servo: the firmware's flag and the servo's limits
        self.servo_tracking = {1: True, 2: True}
        self.servo_limits = {1: "0/0", 2: "0/0"}
        # CoreXY_UFO #11: SERVO_STATUS says tracking=LOST and a jog sets multi-turn
        # again (JOG servo ... tracking=RESET). False: the older firmware (#62)
        self.reports_lost = True
        self.move_delay = 0.01
        self.queue_full_once = False
        self.reject_next_xy = False
        self.jogging = False
        self.jog_rejected = False  # firmware stays silent for the rest of a rejected press
        self._xy_move: tuple[tuple[float, float], tuple[float, float]] | None = None
        self._xy_task: asyncio.Task | None = None
        self._open = False
        self._tasks: list[asyncio.Task] = []

    def cut_servo_power(self, sid: int = 1) -> None:
        """The servo alone lost power: back to one turn. The older firmware does not
        notice; the newer one reports LOST (its abs stays the old value)."""
        self.servo_limits[sid] = "0/4095"
        if not self.reports_lost:
            self.servo_abs[sid] = 0

    def _servo_lost(self, sid: int) -> bool:
        return self.servo_tracking[sid] and self.servo_limits[sid] != "0/0"

    def _begin_servo_jog(self, sid: int) -> None:
        """beginJog: enableTracking when not tracking; the newer firmware also sets
        multi-turn again when the servo's limits went back to one turn."""
        if self._servo_lost(sid):
            if not self.reports_lost:  # older firmware: stays one turn, stops at its ends
                self._emit(f"JOG servo id={sid} begin_ms=212 (hold check; XY waits)")
                return
            state = "RESET"
            self.servo_abs[sid] = 100  # counts restart from the angle in the turn
        elif self.servo_tracking[sid]:
            state = "KEPT"
        else:
            state = "NEW"
        self.servo_tracking[sid], self.servo_limits[sid] = True, "0/0"
        suffix = f" tracking={state}" if self.reports_lost else ""
        self._emit(f"JOG servo id={sid} begin_ms=230 (hold check; XY waits){suffix}")

    @property
    def is_open(self) -> bool:
        return self._open

    async def open(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._open = True
        self._emit("CoreXY plotter ready. Type HELP.")

    async def close(self) -> None:
        self._open = False
        for t in self._tasks:
            t.cancel()

    def _emit(self, line: str) -> None:
        self.lines.put_nowait(line)

    def _later(self, delay: float, *lines: str, then=None) -> asyncio.Task:
        async def go() -> None:
            await asyncio.sleep(delay)
            for l in lines:
                self._emit(l)
            if then:
                then()
        task = asyncio.get_running_loop().create_task(go())
        self._tasks.append(task)
        return task

    def _homed_s(self) -> str:
        return "YES" if self.homed else "NO"

    def pos_line(self) -> str:
        return (f"POS X={self.x:.3f} Y={self.y:.3f} A=0 B=0 F=900.000 EN=HARDWIRED_ACTIVE "
                f"HOMED={'YES' if self.homed else 'NO'} X_HOMED=YES Y_HOMED=YES HOMING=Idle MOTION=NO JOB=IDLE PEN=UP "
                f"ALARM={'YES' if self.alarm else 'NO'} ALARM_REASON=\"{self.alarm_reason}\" TMC=READY LIMIT_X=OPEN LIMIT_Y=OPEN "
                f"LIMIT_X_RAW=OPEN LIMIT_Y_RAW=OPEN TEST_MODE={'ON' if self.test_mode else 'OFF'} JOY=NONE")

    def write_line(self, line: str) -> None:
        if not self._open:
            raise ConnectionError("closed")
        self.sent.append(line)
        if self.tx_log:
            self.tx_log(line)
        name = line.split()[0]
        if self.queue_full_once:
            self.queue_full_once = False
            self._emit("ERROR: CommandQueue full")
            return
        if name in ("POS", "M114"):
            self._emit("ACK QUEUED " + name)
            self._emit(self.pos_line())
        elif name == "HOME":
            self._emit("ACK QUEUED HOME")
            self.x = self.y = 0.0
            self.homed = True
            self._later(self.move_delay, "HOME complete X=0.000 Y=0.000 A=0 B=0 limitX=ON limitY=ON")
        elif name == "XY":
            self._emit("ACK QUEUED XY")
            parts = line.split()
            x, y = float(parts[1]), float(parts[2])
            if self.jogging:
                self._emit(f"NACK_XY target=({x:.3f},{y:.3f}) reason=jog_active")
            elif self.alarm:
                self._later(0.0, "REJECT: machine is alarmed reason=" + self.alarm_reason, f"NACK_XY target=({x:.3f},{y:.3f}) reason=alarm")
            elif not self.homed:
                self._later(0.0, "REJECT: machine is not homed", f"NACK_XY target=({x:.3f},{y:.3f}) reason=rejected")
            elif self.reject_next_xy or not (0 <= x <= 390 and 0 <= y <= 200):
                self.reject_next_xy = False
                self._later(0.0, f"REJECT: X {x:.3f} outside [0.000, 390.000]", f"NACK_XY target=({x:.3f},{y:.3f}) reason=rejected")
            else:
                self._xy_move = ((self.x, self.y), (x, y))
                self.x, self.y = x, y

                def done() -> None:
                    self._xy_move = None
                self._xy_task = self._later(self.move_delay, f"ACK_XY target=({x:.3f},{y:.3f}) A=0 B=0 F=900.000", then=done)
        elif name == "JOG":
            # REPLY_FIRMWARE_JOG.md: start once, silent refreshes, JOG_POS while moving
            parts = line.split()
            vx, vy = float(parts[1]), float(parts[2])
            zero = all(float(p) == 0 for p in parts[1:])
            if zero:
                self.jog_rejected = False
                if self.jogging:
                    self.jogging = False
                    self._emit(f"JOG end reason=zero X={self.x:.3f} Y={self.y:.3f} HOMED={self._homed_s()} src=SERIAL")
            elif self.jogging:
                self.x = min(max(self.x + vx * 0.05, 0.0), 390.0)
                self.y = min(max(self.y + vy * 0.05, 0.0), 200.0)
                zc = int(float(parts[3])) if len(parts) > 3 else 0
                self.servo_abs[1] += int(zc * 0.05)
                if self.servo_limits[1] != "0/0":  # one turn only: stuck at its ends, no error
                    self.servo_abs[1] = min(max(self.servo_abs[1], 0), 4095)
                self._emit(f"JOG_POS X={self.x:.3f} Y={self.y:.3f} VX={vx:.1f} VY={vy:.1f} Z_ABS={self.servo_abs[1]} ARM_ABS=NA")
            elif self.jog_rejected:
                pass
            else:
                reason = ("alarm" if self.alarm else "busy" if self._xy_move else
                          "not_homed" if (vx or vy) and not self.homed else None)  # Z alone: no homing needed
                if reason:
                    self.jog_rejected = True
                    self._emit(f"NACK_JOG reason={reason}")
                else:
                    self.jogging = True
                    rates = {1: float(parts[3]) if len(parts) > 3 else 0.0,
                             2: float(parts[4]) if len(parts) > 4 else 0.0}
                    self._emit(f"JOG start vx={vx:.1f} vy={vy:.1f} z={rates[1]:.0f} arm={rates[2]:.0f} "
                               f"src=SERIAL HOMED={self._homed_s()}")
                    for sid, rate in rates.items():
                        if rate:
                            self._begin_servo_jog(sid)
        elif name == "STOP":
            self._emit("ACK QUEUED STOP")
            if self._xy_move and self._xy_task and not self._xy_task.done():
                self._xy_task.cancel()
                (x0, y0), (x1, y1) = self._xy_move
                self.x, self.y = (x0 + x1) / 2, (y0 + y1) / 2  # stopped half-way
                self._xy_move = None
                self._emit(f"NACK_XY target=({x1:.3f},{y1:.3f}) reason=stopped X={self.x:.3f} Y={self.y:.3f}")
            if self.jogging:
                self.jogging = False
                self._emit(f"JOG end reason=command X={self.x:.3f} Y={self.y:.3f} HOMED={self._homed_s()} src=SERIAL")
            self._emit(f"STOP complete X={self.x:.3f} Y={self.y:.3f} HOMED={self._homed_s()}")
        elif name == "TEST_MODE":
            self._emit("ACK QUEUED TEST_MODE")
            self.test_mode = line.endswith("ON")
            self._emit("TEST_MODE result=ON (moves clear HOMED; limits stop TEST_JOG/TEST_A/TEST_B)" if self.test_mode else "TEST_MODE result=OFF homed=YES")
        elif name == "SERVO_TURN":
            self._emit("ACK QUEUED SERVO_TURN")
            _, sid, turns = line.split()
            sid = int(sid)
            turns = float(turns)
            if self.jogging:
                self._emit("NACK_SERVO_TURN reason=jog_active")
            elif self.test_mode and self.servo_tracking[sid] and self.servo_limits[sid] != "0/0":
                # like moveRelative: the servo lost its multi-turn limits, nothing moves
                self.servo_tracking[sid] = False
                self._emit(f"SERVO_TURN id={sid} value={turns:.2f} result=REJECTED reason=multi_turn_lost (retry)")
            elif not self.test_mode:
                self._emit(f"SERVO_TURN id={sid} value={turns:.2f} result=REJECTED reason=test_mode_off")
            elif abs(turns) > 3.0:
                self._emit(f"SERVO_TURN id={sid} value={turns:.2f} result=REJECTED reason=turns_over")
            else:
                target = self.servo_abs[sid] + int(turns * 4096)
                self.servo_abs[sid] = target
                self._later(self.move_delay, f"SERVO_TURN id={sid} value={turns:.2f} result=PASS target={target} actual={target} error=+0 ms=120")
        elif name == "SERVO_STATUS":
            self._emit("ACK QUEUED SERVO_STATUS")
            sid = int(line.split()[1])
            tracking = "YES" if self.servo_tracking[sid] else "NO"
            if self.reports_lost and self._servo_lost(sid):
                tracking = "LOST"
            self._emit(f"SERVO_STATUS id={sid} result=OK flags=0x00 mode=0 torque=1 raw=100 goal=100 limits={self.servo_limits[sid]} tracking={tracking} abs={self.servo_abs[sid]} turns={self.servo_abs[sid]/4096:.2f} voltage=7.4 temp=31 moving=0")
        elif name == "ABORT":
            self._emit("ACK QUEUED ABORT")
            self.alarm = True
            self.alarm_reason = "abort requested"
            self.homed = False
            self._emit("ABORT complete")
        elif name == "ALARM_CLEAR":
            self._emit("ACK QUEUED ALARM_CLEAR")
            self.alarm = False
            self.alarm_reason = "none"
            self._emit("ALARM_CLEAR complete")
        else:
            self._emit(f"ERROR: unknown command: {name}")
