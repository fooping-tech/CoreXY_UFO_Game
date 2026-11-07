"""DryRunRobot: the MockRobot plus what the auto catch needs to be checked without hardware.

Nothing here is sent anywhere. On top of MockRobot (virtual XY/Z with bounded
speed and acceleration, completion = the virtual axis reaches its target):

  * a claw servo whose move takes `claw_move_s` and then "completes" (like the
    firmware's SERVO_TURN result line), with recorded open / closed positions;
  * raw input lines with polarity and debounce, like the hardware would give:
    the X / Y home limit switches and an emergency-stop button (an E-stop
    press behaves like the firmware's ABORT: alarm, homing lost);
  * fault injection (`inject`) for the tests and the --auto-catch-dry-run runner:
      stall_xy / stall_z  an axis stops following its target (-> state timeout)
      claw_stall          the claw command never completes (-> timeout)
      claw_fail           the claw command fails (servo result=TIMEOUT)
      z_glitch            the Z reading jumps out of range (sensor anomaly)
      disconnect          the link to the robot is lost
"""

from __future__ import annotations

import asyncio
import math
import time

from ..config import RobotLimits
from .interface import RobotCommandError
from .mock_robot import MockRobot
from .state import MachineState, RobotSnapshot

FAULTS = ("stall_xy", "stall_z", "claw_stall", "claw_fail", "z_glitch", "disconnect")


class DebouncedInput:
    """A raw digital input -> debounced 'active' (polarity: active_high)."""

    def __init__(self, active_high: bool, debounce_s: float) -> None:
        self.active_high = active_high
        self.debounce_s = debounce_s
        self.active = False
        self._raw_active = False
        self._since = 0.0

    def set_raw(self, level: bool, now: float) -> None:
        raw_active = level if self.active_high else not level
        if raw_active != self._raw_active:
            self._raw_active = raw_active
            self._since = now

    def update(self, now: float) -> bool:
        if self._raw_active != self.active and now - self._since >= self.debounce_s:
            self.active = self._raw_active
        return self.active


class DryRunRobot(MockRobot):
    name = "mock"  # the game treats it like the mock (no real hardware behind it)
    dry_run = True

    def __init__(self, limits: RobotLimits | None = None, *, claw_closed_deg: float = 0.0,
                 claw_open_deg: float = -120.0, claw_move_s: float = 0.4,
                 limit_active_high: bool = False, estop_active_high: bool = False,
                 input_debounce_s: float = 0.03, **kw) -> None:
        super().__init__(limits, **kw)
        self.arm_marks = {"closed": claw_closed_deg, "open": claw_open_deg}
        self.arm_deg = claw_closed_deg
        self.claw_move_s = claw_move_s
        self.faults: set[str] = set()
        self.inputs = {
            "limit_x": DebouncedInput(limit_active_high, input_debounce_s),
            "limit_y": DebouncedInput(limit_active_high, input_debounce_s),
            "estop": DebouncedInput(estop_active_high, input_debounce_s),
        }
        # idle levels: every input inactive
        for k, inp in self.inputs.items():
            inp.set_raw(not inp.active_high, 0.0)
        self.commands: list[str] = []  # what would have been sent (for the dry-run log)
        self._claw_moving = False

    # ---------------------------------------------------------------- faults / inputs
    def inject(self, fault: str) -> None:
        if fault not in FAULTS:
            raise ValueError(f"unknown fault {fault!r} (one of {FAULTS})")
        self.faults.add(fault)
        if fault == "disconnect":
            self.connected = False
            self.motors_enabled = False

    def set_input(self, name: str, level: bool) -> None:
        """Raw electrical level of an input line (True = high)."""
        self.inputs[name].set_raw(level, time.monotonic())

    def press_input(self, name: str) -> None:
        """Drive an input to its active level."""
        self.set_input(name, self.inputs[name].active_high)

    def release_input(self, name: str) -> None:
        self.set_input(name, not self.inputs[name].active_high)

    # ---------------------------------------------------------------- commands
    async def move_xy(self, x: float, y: float, feed: float | None = None) -> None:
        self.commands.append(f"XY {x:.3f} {y:.3f} F{feed or 0:.0f}")
        await super().move_xy(x, y, feed)

    async def move_z(self, z: float) -> None:
        self.commands.append(f"Z -> {z:.2f}")
        await super().move_z(z)

    async def arm_goto(self, which: str) -> None:
        self.commands.append(f"CLAW -> {which}")
        if which not in self.arm_marks:
            raise RobotCommandError("arm_goto: which must be closed or open")
        self._require(homed=False)
        if "claw_fail" in self.faults:
            await asyncio.sleep(self.claw_move_s)
            raise RobotCommandError("SERVO_TURN id=2 result=TIMEOUT (dry run: claw_fail)")
        self._claw_moving = True
        try:
            while "claw_stall" in self.faults:  # never completes on its own; ABORT still ends it
                if self.alarm:
                    raise RobotCommandError("SERVO_TURN id=2 result=ABORTED")
                await asyncio.sleep(0.01)
            start, end = self.arm_deg, self.arm_marks[which]
            t0 = time.monotonic()
            while (f := (time.monotonic() - t0) / max(self.claw_move_s, 1e-6)) < 1.0:
                if self.alarm:
                    raise RobotCommandError("SERVO_TURN id=2 result=ABORTED")
                self.arm_deg = start + (end - start) * f
                await asyncio.sleep(0.01)
            self.arm_deg = end
        finally:
            self._claw_moving = False

    async def stop(self) -> None:
        self.commands.append("ABORT")
        await super().stop()

    # ---------------------------------------------------------------- simulation
    async def tick(self) -> None:
        frozen = [i for i, f in ((0, "stall_xy"), (1, "stall_xy"), (2, "stall_z")) if f in self.faults]
        saved = [(i, self.pos[i]) for i in frozen]
        await super().tick()
        for i, p in saved:
            self.pos[i] = p
            self.vel[i] = 0.0
        now = time.monotonic()
        for inp in self.inputs.values():
            inp.update(now)
        if self.inputs["estop"].active and not self.alarm and self.connected:
            # an E-stop button wired to the controller: same result as ABORT
            await self.stop()
            self.error = "emergency stop input"

    def _state(self) -> MachineState:
        st = super()._state()
        if st == MachineState.IDLE and self._claw_moving:
            return MachineState.GRABBING
        return st

    def snapshot(self) -> RobotSnapshot:
        s = super().snapshot()
        s.limit_x = self.inputs["limit_x"].active
        s.limit_y = self.inputs["limit_y"].active
        if "z_glitch" in self.faults:
            s.z = math.nan
        return s
