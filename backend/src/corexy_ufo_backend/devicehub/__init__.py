"""The UFO device hub (UFO-DeviceHub: ESP-NOW hub M5AtomS3R, Illumination ATOM, M5Dial x2), #108.

The hub's PC client (the gateway, the protocol, the mock hub, the trace) is UFO-DeviceHub's own
Python package `ufo-devicehub` (https://github.com/fooping-tech/UFO-DeviceHub), a dependency of
this backend: import it as `ufo_devicehub`. There is no copy of it here (#159), and none is to
be made again. Where it comes from and which commit this game is verified with:
backend/pyproject.toml ([tool.uv.sources]), tools/devicehub.pin, tools/setup_devicehub.sh.

service.py is this game's own adapter: the settings, the robot's (Core2) ports that are never
opened, the exclusive open, the words for the screen, the asyncio bridge to the WebSocket.
"""

from .service import DeviceHubConfig, DeviceHubService

__all__ = ["DeviceHubConfig", "DeviceHubService"]
