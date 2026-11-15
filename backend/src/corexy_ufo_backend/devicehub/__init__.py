"""The UFO device hub (UFO-DeviceHub: ESP-NOW hub M5AtomS3R, Illumination ATOM, M5Dial x2), #108.

protocol.py, device_gateway.py, mock_hub.py, trace.py and game_mode.py are copies of UFO-DeviceHub's pc/
package (https://github.com/fooping-tech/UFO-DeviceHub, commit e965cdf; protocol version 1, firmware 0.3).
Do not edit them here: to
update, copy them again from that repository and change the commit above. service.py is this
game's own wrapper (settings, port exclusion, WebSocket-friendly results).

History of the copy: 1302bac (#108) -> f98999f (#138: DialState.SETTINGS, the Dial's own settings mode,
in which it refuses every command but STOP_ALL; protocol.py only, the gateway and the mock are unchanged)
-> e965cdf (#138, UFO-DeviceHub #8: SET_DIAL_EFFECT / SET_DIAL_COLOR, the Dial's LED fields in STATUS, the
gateway's trace hook; trace.py and game_mode.py are new. The contract is that repository's
docs/game-mode-interface.md. Additions only: older firmware answers UNSUPPORTED / BAD_REQUEST).
"""

from .service import DeviceHubConfig, DeviceHubService

__all__ = ["DeviceHubConfig", "DeviceHubService"]
