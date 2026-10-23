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
