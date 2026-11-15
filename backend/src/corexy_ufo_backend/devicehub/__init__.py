"""The UFO device hub (UFO-DeviceHub: ESP-NOW hub M5AtomS3R, Illumination ATOM, M5Dial x2), #108.

protocol.py, device_gateway.py and mock_hub.py are copies of UFO-DeviceHub's pc/ package
(https://github.com/fooping-tech/UFO-DeviceHub, commit f98999f; protocol version 1). Do not edit them here: to
update, copy them again from that repository and change the commit above. service.py is this
game's own wrapper (settings, port exclusion, WebSocket-friendly results).

History of the copy: 1302bac (#108) -> f98999f (#138: DialState.SETTINGS, the Dial's own settings mode,
in which it refuses every command but STOP_ALL; protocol.py only, the gateway and the mock are unchanged).
"""

from .service import DeviceHubConfig, DeviceHubService

__all__ = ["DeviceHubConfig", "DeviceHubService"]
