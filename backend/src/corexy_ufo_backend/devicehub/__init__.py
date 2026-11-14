"""The UFO device hub (UFO-DeviceHub: ESP-NOW hub M5AtomS3R, Illumination ATOM, M5Dial x2), #108.

protocol.py, device_gateway.py and mock_hub.py are copies of UFO-DeviceHub's pc/ package
(https://github.com/fooping-tech/UFO-DeviceHub, commit 1302bac). Do not edit them here: to
update, copy them again from that repository and change the commit above. service.py is this
game's own wrapper (settings, port exclusion, WebSocket-friendly results).
"""

from .service import DeviceHubConfig, DeviceHubService

__all__ = ["DeviceHubConfig", "DeviceHubService"]
