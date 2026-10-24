"""MockRobot: same bounded-velocity model as the Godot mock, for running the
backend + WebSocket without hardware (`corexy-ufo-backend --mock`)."""

from __future__ import annotations

import asyncio
import math
import time

from ..config import RobotLimits
from .interface import RobotCommandError, RobotInterface
from .state import MachineState, RobotSnapshot


class MockRobot(RobotInterface):
    name = "mock"

    def __init__(self, limits: RobotLimits | None = None, *, speed_xy: float = 250.0, accel_xy: float = 1000.0,
                 speed_z: float = 60.0, accel_z: float = 400.0) -> None:
        self.limits = limits or RobotLimits()
        self.speed = [speed_xy, speed_xy, speed_z]
        self.accel = [accel_xy, accel_xy, accel_z]
        lim = self.limits
        z0 = lim.z_max if lim.z_up_is_positive else lim.z_min
        self.pos = [(lim.x_min + lim.x_max) / 2, (lim.y_min + lim.y_max) / 2, z0]
        self.vel = [0.0, 0.0, 0.0]
        self.target = list(self.pos)
        self.connected = False
        self.homed = False
        self.motors_enabled = False
        self.alarm = False
        self.error = ""
        self._grabbing = False
        self._homing_until = 0.0
        self._last = time.monotonic()
        self.z_reference_set = True

    async def connect(self) -> None:
        self.connected = True
        self._last = time.monotonic()

    async def disconnect(self) -> None:
        self.connected = False

    def _require(self, *, homed: bool = True) -> None:
        if not self.connected:
            raise RobotCommandError("not connected")
        if not self.motors_enabled:
            raise RobotCommandError("motors not enabled")
        if self.alarm:
            raise RobotCommandError("alarm active; clear_alarm first")
        if homed and not self.homed:
            raise RobotCommandError("not homed")

    async def enable_motors(self, enable: bool) -> None:
        if not self.connected:
            raise RobotCommandError("not connected")
        self.motors_enabled = enable
        if not enable:
            self.target = list(self.pos)
            self.vel = [0.0, 0.0, 0.0]

    async def home(self) -> None:
        self._require(homed=False)
        self._homing_until = time.monotonic() + 1.5
        self.target[0] = self.limits.x_min
        self.target[1] = self.limits.y_min
        await asyncio.sleep(0)
        self.homed = True

    async def move_xy(self, x: float, y: float, feed: float | None = None) -> None:
        self._require()
        if not self.limits.xy_inside(x, y):
            raise RobotCommandError(f"XY ({x},{y}) outside soft limits")
        self.target[0], self.target[1] = x, y

    async def move_z(self, z: float) -> None:
        self._require()
        self.target[2] = self.limits.clamp_z(z)

    async def set_z_zero(self) -> None:
        self.z_reference_set = True

    async def grab(self, close: bool) -> None:
        self._require()
        self._grabbing = close

    async def stop(self) -> None:
        self.vel = [0.0, 0.0, 0.0]
        self.target = list(self.pos)
        self.alarm = True
        self.homed = False
        self.error = "abort requested"

    async def clear_alarm(self) -> None:
        self.alarm = False
        self.error = ""

    async def tick(self) -> None:
        now = time.monotonic()
        dt = min(now - self._last, 0.1)
        self._last = now
        if not self.connected:
            return
        for i in range(3):
            d = self.target[i] - self.pos[i]
            if dt <= 0.0:
                continue
            # Fastest speed that can still stop at the target decelerating by
            # accel*dt per step (discrete form of sqrt(2*a*d)), capped to what
            # covers the remaining distance in this step (otherwise the
            # discrete controller overshoots and hunts around the target).
            a_dt = self.accel[i] * dt
            stop_v = a_dt * (math.sqrt(0.25 + 2 * abs(d) / (a_dt * dt)) - 0.5)
            desired = math.copysign(min(self.speed[i], stop_v, abs(d) / dt), d)
            v = self.vel[i]
            step = self.accel[i] * dt
            v = v + max(-step, min(step, desired - v))
            if abs(d) < 1e-3 or (v * d > 0 and abs(v) * dt >= abs(d)):
                v = 0.0
                self.pos[i] = self.target[i]
            else:
                self.pos[i] += v * dt
            self.vel[i] = v

    def _state(self) -> MachineState:
        if self.alarm:
            return MachineState.ALARM
        if time.monotonic() < self._homing_until:
            return MachineState.HOMING
        if self._grabbing:
            return MachineState.GRABBING
        if abs(self.vel[2]) > 0.01:
            up = self.vel[2] > 0 if self.limits.z_up_is_positive else self.vel[2] < 0
            return MachineState.Z_RAISING if up else MachineState.Z_LOWERING
        if abs(self.vel[0]) > 0.01 or abs(self.vel[1]) > 0.01:
            return MachineState.MOVING_XY
        return MachineState.IDLE

    def snapshot(self) -> RobotSnapshot:
        return RobotSnapshot(
            connected=self.connected, homed=self.homed, motors_enabled=self.motors_enabled,
            state=self._state(), x=self.pos[0], y=self.pos[1], z=self.pos[2], measured=True,
            alarm=self.alarm, error=self.error, test_mode=True, timestamp_ms=int(time.time() * 1000),
            z_reference_set=self.z_reference_set,
        )
