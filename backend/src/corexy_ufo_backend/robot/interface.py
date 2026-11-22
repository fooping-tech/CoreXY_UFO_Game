"""Abstract robot interface used by the WebSocket server."""

from __future__ import annotations

import time
from abc import ABC, abstractmethod

from ..config import RobotLimits
from .state import RobotSnapshot


class RobotCommandError(Exception):
    pass


class ServoFailed(RobotCommandError):
    """#269: the firmware answered a servo command (SERVO_TURN) with a result other than PASS
    (TIMEOUT, FAILED, REJECTED, multi_turn_lost, ...). The command is over: nothing of it runs
    on, and XY is not moving. A sequence then stops with STOP (no alarm, homing kept) instead
    of ABORT. No answer at all, a lost link, a NACK, ... stay plain RobotCommandError (ABORT)."""


class RobotInterface(ABC):
    name: str = "robot"
    # The soft limits this robot enforces; None when it has none of its own (the server
    # then uses the config's).
    limits: RobotLimits | None = None

    # #188 (SPEED UP): the jog's XY cap raised for a while. jog_boost_mm_s is the cap while
    # it lasts (0 = this robot has none), jog_boost_max_s the longest one request may ask for.
    # It ends by itself (a monotonic deadline kept here, not in the game), and with a stop.
    jog_boost_mm_s: float = 0.0
    jog_boost_max_s: float = 30.0
    _jog_boost_until: float = 0.0

    def jog_boost(self, seconds: float) -> float:
        """Raise the jog's XY cap to jog_boost_mm_s for `seconds` (at most jog_boost_max_s)
        from now; 0 or less ends it now. Returns the seconds it will last."""
        if seconds <= 0 or self.jog_boost_mm_s <= 0:
            self._jog_boost_until = 0.0
            return 0.0
        s = min(float(seconds), max(self.jog_boost_max_s, 0.0))
        self._jog_boost_until = time.monotonic() + s
        return s

    def jog_boost_left(self) -> float:
        return max(self._jog_boost_until - time.monotonic(), 0.0)

    def jog_cap(self, base: float) -> float:
        """The jog's XY cap now: `base`, or the boost's while one lasts (never lower)."""
        return max(base, self.jog_boost_mm_s) if self.jog_boost_left() > 0 else base

    @property
    def is_real(self) -> bool:
        """True for the real machine: the "real" profiles (refused until measured and
        confirmed) apply, anything else uses the "dry_run" ones."""
        return self.name == "real"

    @abstractmethod
    async def connect(self) -> None: ...

    @abstractmethod
    async def disconnect(self) -> None: ...

    @abstractmethod
    def snapshot(self) -> RobotSnapshot: ...

    @abstractmethod
    async def enable_motors(self, enable: bool) -> None:
        """Explicit arming step. Motion commands are refused until enabled."""

    @abstractmethod
    async def home(self) -> None: ...

    @abstractmethod
    async def move_xy(self, x: float, y: float, feed: float | None = None) -> None: ...

    def travel_height_refusal(self) -> str:
        """#276: why a move that nobody steers (park) may not go now because of the arm's
        height ("" = it may: the arm is wound up). The real robot checks its Z; others: ""."""
        return ""

    @abstractmethod
    async def move_z(self, z: float) -> None: ...

    @abstractmethod
    async def set_z_zero(self) -> None: ...

    async def recover_z_servo(self) -> None:
        """Bring the drum servo back after its power was cut alone (real robot only)."""
        return None

    async def restore_z_points(self, apply: bool, turns: int | None = None) -> dict:
        """Call back the last session's Z top / bottom after a power cycle (real robot only, #106)."""
        raise RobotCommandError("前回の Z の呼び出しは実機だけ（この機械では上を記録する）")

    async def set_z_point(self, which: str) -> None:
        """Record the arm's current height as its top ("top") or bottom ("bottom")."""
        if which != "top":
            raise RobotCommandError("this robot only knows the top Z point")
        await self.set_z_zero()

    @abstractmethod
    async def grab(self, close: bool) -> None: ...

    async def arm_step(self, deg: float) -> None:
        """Turn the claw servo by `deg` degrees from where it is (manual testing)."""
        raise RobotCommandError("arm_step not supported")

    async def arm_set(self, which: str) -> None:
        """Record the claw's current angle as its "open" or "closed" position."""
        raise RobotCommandError("arm_set not supported")

    async def arm_goto(self, which: str) -> None:
        """Turn the claw to its recorded "open" or "closed" position."""
        raise RobotCommandError("arm_goto not supported")

    async def arm_zero(self) -> None:
        """Make the claw's current angle 0 degrees (its reference)."""
        raise RobotCommandError("arm_zero not supported")

    @abstractmethod
    async def jog(self, vx_mm_s: float, vy_mm_s: float, vz_units_s: float = 0.0, *, z_free: bool = False) -> None:
        """Velocity jog (dead-man): keep sending while a key is held; all zero stops.

        vz is the Z value per second (+ = larger z). z_free (the settings screen's 校正 tab
        measuring Z again, #102): do not stop at the measured 0..z_max range, so the arm
        reaches a new top / bottom (still hold-to-move; the firmware's own guard stays). The robot stops by itself if
        refreshes stop for ~250 ms, so this is never retried. Requires enable_motors;
        XY also requires homing (Z alone does not, like the firmware)."""

    @abstractmethod
    async def soft_stop(self) -> None:
        """Decelerate the current move / jog to a stop. No alarm, stays homed.
        Unlike stop() this is not an emergency stop."""

    @abstractmethod
    async def stop(self) -> None:
        """Safety stop. Must be usable at any time, even while moving."""

    @abstractmethod
    async def clear_alarm(self) -> None: ...

    async def refresh_status(self) -> None:
        """Read the machine's status now (alarm, homing, limit switches) if it can answer.
        Used before deciding to start an automatic sequence."""
        return None

    async def tick(self) -> None:
        """Called periodically by the server (status polling etc)."""
        return None

    def recent_log(self, n: int = 50) -> list[str]:
        return []
