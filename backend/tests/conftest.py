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
        self.move_delay = 0.01
        self.queue_full_once = False
        self.reject_next_xy = False
        self._open = False
        self._tasks: list[asyncio.Task] = []

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

    def _later(self, delay: float, *lines: str) -> None:
        async def go() -> None:
            await asyncio.sleep(delay)
            for l in lines:
                self._emit(l)
        self._tasks.append(asyncio.get_running_loop().create_task(go()))

    def pos_line(self) -> str:
        return (f"POS X={self.x:.3f} Y={self.y:.3f} A=0 B=0 F=900.000 EN=HARDWIRED_ACTIVE "
                f"HOMED={'YES' if self.homed else 'NO'} X_HOMED=YES Y_HOMED=YES HOMING=Idle MOTION=NO JOB=IDLE PEN=UP "
                f"ALARM={'YES' if self.alarm else 'NO'} ALARM_REASON=\"{self.alarm_reason}\" TMC=READY LIMIT_X=OPEN LIMIT_Y=OPEN "
                f"LIMIT_X_RAW=OPEN LIMIT_Y_RAW=OPEN TEST_MODE={'ON' if self.test_mode else 'OFF'} JOY=NONE")

    def write_line(self, line: str) -> None:
        if not self._open:
            raise ConnectionError("closed")
        self.sent.append(line)
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
            if self.alarm:
                self._later(0.0, "REJECT: machine is alarmed reason=" + self.alarm_reason, f"NACK_XY target=({x:.3f},{y:.3f}) reason=alarm")
            elif not self.homed:
                self._later(0.0, "REJECT: machine is not homed", f"NACK_XY target=({x:.3f},{y:.3f}) reason=rejected")
            elif self.reject_next_xy or not (0 <= x <= 390 and 0 <= y <= 200):
                self.reject_next_xy = False
                self._later(0.0, f"REJECT: X {x:.3f} outside [0.000, 390.000]", f"NACK_XY target=({x:.3f},{y:.3f}) reason=rejected")
            else:
                self.x, self.y = x, y
                self._later(self.move_delay, f"ACK_XY target=({x:.3f},{y:.3f}) A=0 B=0 F=900.000")
        elif name == "TEST_MODE":
            self._emit("ACK QUEUED TEST_MODE")
            self.test_mode = line.endswith("ON")
            self._emit("TEST_MODE result=ON (moves clear HOMED; limits stop TEST_JOG/TEST_A/TEST_B)" if self.test_mode else "TEST_MODE result=OFF homed=YES")
        elif name == "SERVO_TURN":
            self._emit("ACK QUEUED SERVO_TURN")
            _, sid, turns = line.split()
            sid = int(sid)
            turns = float(turns)
            if not self.test_mode:
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
            self._emit(f"SERVO_STATUS id={sid} result=OK flags=0x00 mode=0 torque=1 raw=100 goal=100 limits=0/4095 tracking=YES abs={self.servo_abs[sid]} turns={self.servo_abs[sid]/4096:.2f} voltage=7.4 temp=31 moving=0")
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
