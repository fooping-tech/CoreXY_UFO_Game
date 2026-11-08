"""Robot state model shared by the mock and the real robot."""

from __future__ import annotations

import time
from dataclasses import asdict, dataclass
from enum import StrEnum


class MachineState(StrEnum):
    UNKNOWN = "UNKNOWN"
    IDLE = "IDLE"
    HOMING = "HOMING"
    MOVING_XY = "MOVING_XY"
    Z_LOWERING = "Z_LOWERING"
    Z_RAISING = "Z_RAISING"
    GRABBING = "GRABBING"
    RELEASING = "RELEASING"
    ALARM = "ALARM"
    ESTOP = "ESTOP"


@dataclass
class RobotPose:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0


@dataclass
class RobotSnapshot:
    connected: bool = False
    homed: bool = False
    motors_enabled: bool = False
    state: MachineState = MachineState.UNKNOWN
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    measured: bool = True
    alarm: bool = False
    error: str = ""
    test_mode: bool = False
    timestamp_ms: int = 0
    z_reference_set: bool = False
    # Z points recorded in this firmware session (top = arm wound up, bottom = lowered)
    # and whether counts per unit / direction are measured (from both points, or saved)
    z_top_set: bool = False
    z_bottom_set: bool = False
    z_calibrated: bool = False
    # claw servo (ID 2): degrees from the arm_zero reference (or the raw angle in
    # its turn, 0..360, before one is set); None = not read yet
    arm_deg: float | None = None
    arm_reference_set: bool = False
    # recorded claw positions: angle in the servo's turn; span = closed -> open, signed
    arm_closed_deg: float | None = None
    arm_open_deg: float | None = None
    arm_span_deg: float | None = None
    # home limit switches (firmware-debounced, POS LIMIT_X / LIMIT_Y = ACTIVE); the
    # real robot can only read them between moves
    limit_x: bool = False
    limit_y: bool = False

    def to_message(self) -> dict:
        d = asdict(self)
        d["state"] = str(self.state)
        ts = d.pop("timestamp_ms") or int(time.time() * 1000)
        return {"type": "robot_state", "timestamp": ts, "data": d}
