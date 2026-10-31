"""Abstract robot interface used by the WebSocket server."""

from __future__ import annotations

from abc import ABC, abstractmethod

from .state import RobotSnapshot


class RobotCommandError(Exception):
    pass


class RobotInterface(ABC):
    name: str = "robot"

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

    @abstractmethod
    async def move_z(self, z: float) -> None: ...

    @abstractmethod
    async def set_z_zero(self) -> None: ...

    @abstractmethod
    async def grab(self, close: bool) -> None: ...

    async def arm_step(self, deg: float) -> None:
        """Turn the claw servo by `deg` degrees from where it is (manual testing)."""
        raise RobotCommandError("arm_step not supported")

    async def arm_zero(self) -> None:
        """Make the claw's current angle 0 degrees (its reference)."""
        raise RobotCommandError("arm_zero not supported")

    @abstractmethod
    async def jog(self, vx_mm_s: float, vy_mm_s: float, vz_units_s: float = 0.0) -> None:
        """Velocity jog (dead-man): keep sending while a key is held; all zero stops.

        vz is the Z value per second (+ = larger z). The robot stops by itself if
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

    async def tick(self) -> None:
        """Called periodically by the server (status polling etc)."""
        return None

    def recent_log(self, n: int = 50) -> list[str]:
        return []
