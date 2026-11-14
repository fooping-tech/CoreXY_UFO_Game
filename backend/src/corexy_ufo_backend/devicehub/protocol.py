"""UFO device protocol - Python mirror of shared/protocol.h + shared/messages.h.

Two layers:

* the PC <-> Hub **JSON Lines** protocol (what the game talks to), and
* the hub <-> device **ESP-NOW binary packet** (used by the mock, the golden
  vectors and diagnostics tools).

Every numeric value here must match shared/messages.h; this is enforced by
tests/protocol/test_consistency.py. Do not edit one side only.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from enum import IntEnum, IntFlag
from typing import Any

PROTOCOL_VERSION = 1
MAGIC = 0x5546  # system 1; system n uses MAGIC + n - 1 (see system_magic)
MAX_SYSTEM_ID = 8
HEADER_SIZE = 17
MAX_PACKET_SIZE = 64
MAX_PAYLOAD = MAX_PACKET_SIZE - HEADER_SIZE  # 47
MAX_LINE = 512  # UFO_SERIAL_MAX_LINE (hub input limit, bytes without "\n")
HUB_COMMAND_BIT = 0x80000000  # command ids >= this are reserved for the hub

_HEADER = struct.Struct("<HBBBBHIIB")
assert _HEADER.size == HEADER_SIZE


def system_magic(system_id: int) -> int:
    """Packet magic of a UFO system (several systems share one venue)."""
    if not 1 <= system_id <= MAX_SYSTEM_ID:
        raise ValueError(f"system_id must be 1..{MAX_SYSTEM_ID}")
    return MAGIC + system_id - 1


class ProtocolError(ValueError):
    """Invalid message / parameter (raised before anything is sent)."""


# ---- enums (values == shared/messages.h) -----------------------------------
class MsgType(IntEnum):
    COMMAND = 0x01
    EVENT = 0x02
    ACK = 0x03
    STATUS = 0x04
    HEARTBEAT = 0x05
    ERROR = 0x06


class DeviceId(IntEnum):
    HUB = 0x01
    ILLUMINATION = 0x10
    M5DIAL_1 = 0x20
    M5DIAL_2 = 0x21


class CommandCode(IntEnum):
    SESSION_BEGIN = 0x01
    SESSION_END = 0x02
    GET_STATUS = 0x03
    STOP_ALL = 0x04
    SET_MODE = 0x05
    SET_LIGHT_MODE = 0x10
    TRIGGER_EFFECT = 0x11
    RELAY_PULSE = 0x12
    RELAY_OFF = 0x13
    SET_MIST = 0x14
    ARM_RECEIVER = 0x20
    DISARM_RECEIVER = 0x21
    RELEASE_BALL = 0x22


class EventCode(IntEnum):
    BALL_RECEIVED = 0x10
    RELEASE_STARTED = 0x11
    RELEASE_DONE = 0x12
    RELEASE_FAILED = 0x13
    RELAY_DONE = 0x20
    MIST_DONE = 0x21
    DEVICE_ERROR = 0x30


class AckResult(IntEnum):
    ACCEPTED = 0x00
    BUSY = 0x01
    REJECTED_STATE = 0x02
    REJECTED_SESSION = 0x03
    INVALID_PARAMS = 0x04
    UNSUPPORTED = 0x05
    COOLDOWN = 0x06
    IGNORED_PRIORITY = 0x07
    NOT_CONFIGURED = 0x08
    TIMEOUT = 0x80
    OFFLINE = 0x81
    QUEUE_FULL = 0x82
    UNKNOWN_DEVICE = 0x83
    NO_SESSION = 0x84
    BAD_REQUEST = 0x85
    SESSION_MISMATCH = 0x86
    SUPERSEDED = 0x87


class AckFlag(IntFlag):
    DUPLICATE = 0x01
    CLAMPED = 0x02


class DeviceType(IntEnum):
    HUB = 0x01
    ILLUMINATION = 0x02
    DIAL = 0x03


class OperationMode(IntEnum):
    STANDBY = 0x00
    GAME = 0x01


class LightMode(IntEnum):
    OFF = 0x00
    IDLE = 0x01
    STUDY = 0x02
    GAME_READY = 0x03
    GAME_PLAY = 0x04
    RESULT = 0x05
    ERROR = 0x06
    CUSTOM = 0x07
    AURORA = 0x08
    STORM = 0x09
    CAMPFIRE = 0x0A
    MIST_GLOW = 0x0B
    MAGIC_PUFF = 0x0C
    NIGHT = 0x0D


class MistPattern(IntEnum):
    OFF = 0x00
    CONTINUOUS = 0x01
    BREATH = 0x02  # 8 s on / 6 s off
    PUFF = 0x03  # 3 s on / 9 s off


class MistStatusFlag(IntFlag):
    OUTPUT_ON = 0x01
    LOCAL_MODE = 0x02


class EffectId(IntEnum):
    NONE = 0x00
    GAME_START = 0x01
    ARM_MOVE = 0x02
    ARM_DESCEND = 0x03
    CATCH = 0x04
    BALL_RECEIVED = 0x05
    BALL_RELEASED = 0x06
    SCORE = 0x07
    GAME_CLEAR = 0x08
    GAME_OVER = 0x09


class DialState(IntEnum):
    DISABLED = 0x00
    READY = 0x01
    ARMED = 0x02
    BALL_DETECTED = 0x03
    RELEASING = 0x04
    RETURNING = 0x05
    COMPLETE = 0x06
    ERROR = 0x07


class IlluminationState(IntEnum):
    NORMAL = 0x00
    EFFECT = 0x01
    RELAY_ACTIVE = 0x02
    MIST_ACTIVE = 0x03
    ERROR = 0x07


class ReleaseFailReason(IntEnum):
    ABORTED = 0x01
    LINK_LOST = 0x02
    SERVO_NOT_CONFIGURED = 0x03


class RelayEndReason(IntEnum):
    COMPLETED = 0x00
    OFF_COMMAND = 0x01
    SAFETY = 0x02
    WATCHDOG = 0x03
    LOCAL_BUTTON = 0x04


class ErrorCode(IntEnum):
    NONE = 0x00
    MAC_MISMATCH = 0x01
    SERVO_NOT_CONFIGURED = 0x02
    OUTBOX_OVERFLOW = 0x03
    RELAY_WATCHDOG = 0x04
    BAD_PACKET = 0x05
    EXAMPLE_KEYS = 0x06


class NodeFlag(IntFlag):
    SESSION_VALID = 0x01
    HUB_LINK_UP = 0x02
    BUSY = 0x04
    EXAMPLE_KEYS = 0x08
    CONFIG_ERROR = 0x10
    RELAY_ON = 0x20
    SWITCH_ON = 0x40
    GAME_MODE = 0x80


# Wire event name used in JSON (EventCode.DEVICE_ERROR is "ERROR" on the wire).
EVENT_WIRE_NAMES = {code: ("ERROR" if code == EventCode.DEVICE_ERROR else code.name) for code in EventCode}

# Events the gateway delivers to the application (device events + link events).
DEVICE_EVENTS = frozenset(EVENT_WIRE_NAMES.values())
GATEWAY_EVENTS = frozenset(
    {
        "DEVICE_ONLINE",
        "DEVICE_OFFLINE",
        "DEVICE_REBOOTED",
        "SESSION_CLOSED",
        "GATEWAY_CONNECTED",
        "GATEWAY_DISCONNECTED",
        "HUB_ERROR",
    }
)

# Commands the PC may send (hub-only SESSION_* are excluded).
PC_COMMANDS = frozenset(c.name for c in CommandCode if c not in (CommandCode.SESSION_BEGIN, CommandCode.SESSION_END))
# Commands accepted without a session on the device side (safety / read only).
NO_SESSION_COMMANDS = frozenset({"GET_STATUS", "STOP_ALL", "RELAY_OFF", "DISARM_RECEIVER"})
COMMAND_PARAM_LENGTH = {
    CommandCode.SESSION_BEGIN: 0,
    CommandCode.SESSION_END: 0,
    CommandCode.GET_STATUS: 0,
    CommandCode.STOP_ALL: 0,
    CommandCode.SET_MODE: 1,
    CommandCode.SET_LIGHT_MODE: 8,
    CommandCode.TRIGGER_EFFECT: 4,
    CommandCode.RELAY_PULSE: 3,
    CommandCode.RELAY_OFF: 1,
    CommandCode.SET_MIST: 3,
    CommandCode.ARM_RECEIVER: 0,
    CommandCode.DISARM_RECEIVER: 0,
    CommandCode.RELEASE_BALL: 0,
}


# ---- command parameter validation (mirrors firmware/hub/json_bridge.cpp) ----
def _enum_value(enum: type[IntEnum], value: Any, *, minimum: int = 0, what: str) -> int:
    if isinstance(value, enum):
        v = int(value)
    elif isinstance(value, str):
        try:
            v = int(enum[value.upper()])
        except KeyError:
            raise ProtocolError(f"invalid {what}: {value!r}") from None
    elif isinstance(value, int) and not isinstance(value, bool):
        v = value
    else:
        raise ProtocolError(f"invalid {what}: {value!r}")
    if v < minimum or v not in {int(m) for m in enum}:
        raise ProtocolError(f"invalid {what}: {value!r}")
    return v


def _uint(params: dict, key: str, maximum: int, default: int | None) -> int:
    v = params.get(key, default)
    if v is None:
        raise ProtocolError(f"{key} is required")
    if isinstance(v, bool) or not isinstance(v, int) or v < 0 or v > maximum:
        raise ProtocolError(f"{key} must be an integer 0..{maximum}")
    return v


def _color(value: Any) -> tuple[int, int, int]:
    if value is None:
        return (0, 0, 0)
    if isinstance(value, str) and len(value) == 7 and value.startswith("#"):
        try:
            return (int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16))
        except ValueError:
            pass
    if isinstance(value, (list, tuple)) and len(value) == 3 and all(
        isinstance(c, int) and not isinstance(c, bool) and 0 <= c <= 255 for c in value
    ):
        return (value[0], value[1], value[2])
    raise ProtocolError("color must be [r, g, b] (0-255) or '#RRGGBB'")


def normalize_command(name: str, params: dict | None = None) -> dict:
    """Validates a PC command and returns canonical JSON params (names for enums)."""
    if name not in PC_COMMANDS:
        raise ProtocolError(f"unknown command {name!r}")
    p = dict(params or {})
    code = CommandCode[name]
    if code in (
        CommandCode.GET_STATUS,
        CommandCode.STOP_ALL,
        CommandCode.ARM_RECEIVER,
        CommandCode.DISARM_RECEIVER,
        CommandCode.RELEASE_BALL,
    ):
        if p:
            raise ProtocolError(f"{name} takes no parameters")
        return {}
    if code == CommandCode.SET_MODE:
        return {"mode": OperationMode(_enum_value(OperationMode, p.get("mode"), what="mode")).name}
    if code == CommandCode.SET_LIGHT_MODE:
        out = {
            "mode": LightMode(_enum_value(LightMode, p.get("mode"), what="mode")).name,
            "brightness": _uint(p, "brightness", 255, 128),
            "transition_ms": _uint(p, "transition_ms", 65535, 0),
            "speed": _uint(p, "speed", 255, 128),
        }
        if p.get("color") is not None:
            out["color"] = list(_color(p["color"]))
        return out
    if code == CommandCode.TRIGGER_EFFECT:
        eff = p.get("effect", p.get("effect_id"))
        return {
            "effect": EffectId(_enum_value(EffectId, eff, minimum=1, what="effect")).name,
            "duration_ms": _uint(p, "duration_ms", 65535, 0),
            "intensity": _uint(p, "intensity", 255, 255),
        }
    if code == CommandCode.RELAY_PULSE:
        d = _uint(p, "duration_ms", 65535, None)
        if d == 0:
            raise ProtocolError("duration_ms must be 1..65535")
        return {"relay_id": _uint(p, "relay_id", 254, 0), "duration_ms": d}
    if code == CommandCode.RELAY_OFF:
        return {"relay_id": _uint(p, "relay_id", 255, 255)}
    if code == CommandCode.SET_MIST:
        return {
            "pattern": MistPattern(_enum_value(MistPattern, p.get("pattern"), what="pattern")).name,
            "duration_s": _uint(p, "duration_s", 65535, 0),
        }
    raise ProtocolError(f"unhandled command {name}")  # pragma: no cover


# ---- JSON Lines -------------------------------------------------------------
def encode_line(msg: dict) -> str:
    line = json.dumps(msg, separators=(",", ":"), ensure_ascii=True)
    if "\n" in line or len(line.encode()) > MAX_LINE:
        raise ProtocolError(f"line too long ({len(line)} > {MAX_LINE})")
    return line


def decode_line(line: str | bytes) -> dict:
    if isinstance(line, bytes):
        try:
            line = line.decode("utf-8")
        except UnicodeDecodeError as e:
            raise ProtocolError("line is not UTF-8") from e
    line = line.strip()
    if not line:
        raise ProtocolError("empty line")
    try:
        msg = json.loads(line)
    except json.JSONDecodeError as e:
        raise ProtocolError(f"bad JSON: {e}") from e
    if not isinstance(msg, dict) or not isinstance(msg.get("type"), str):
        raise ProtocolError("message must be an object with a 'type'")
    return msg


def hello(session_id: int, system_id: int | None = None) -> dict:
    """HELLO. With system_id the hub refuses the session unless it belongs to that
    system (ERROR SYSTEM_MISMATCH) - two UFO systems can share one venue / PC."""
    if not 0 < session_id <= 0xFFFFFFFF:
        raise ProtocolError("session_id must be a non-zero uint32")
    m = {"protocol_version": PROTOCOL_VERSION, "type": "HELLO", "session_id": session_id}
    if system_id is not None:
        if not 1 <= system_id <= MAX_SYSTEM_ID:
            raise ProtocolError(f"system_id must be 1..{MAX_SYSTEM_ID}")
        m["system_id"] = system_id
    return m


def command(destination: int, session_id: int, command_id: int, name: str, params: dict | None = None) -> dict:
    if not 0 < command_id < HUB_COMMAND_BIT:
        raise ProtocolError("command_id must be 1..0x7FFFFFFF")
    if not 0 <= int(destination) <= 255:
        raise ProtocolError("destination must be a device id")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "type": "COMMAND",
        "destination": int(destination),
        "session_id": session_id,
        "command_id": command_id,
        "name": name,
        "params": normalize_command(name, params),
    }


def event_ack(source: int, event_id: int) -> dict:
    return {"type": "EVENT_ACK", "source": source, "event_id": event_id}


def simple(type_: str) -> dict:
    return {"type": type_}


# ---- binary ESP-NOW packet ---------------------------------------------------
@dataclass
class Packet:
    source: int
    destination: int
    message_type: int
    sequence: int = 0
    session_id: int = 0
    command_id: int = 0
    payload: bytes = b""
    magic: int = MAGIC
    version: int = PROTOCOL_VERSION

    def encode(self) -> bytes:
        if len(self.payload) > MAX_PAYLOAD:
            raise ProtocolError("payload too long")
        if self.message_type not in {int(m) for m in MsgType}:
            raise ProtocolError("bad message type")
        return (
            _HEADER.pack(
                self.magic,
                self.version,
                self.source,
                self.destination,
                self.message_type,
                self.sequence,
                self.session_id,
                self.command_id,
                len(self.payload),
            )
            + self.payload
        )

    @classmethod
    def decode(cls, data: bytes, magic: int = MAGIC) -> Packet:
        """magic: system_magic(n) of the system the frame must belong to."""
        if len(data) < HEADER_SIZE:
            raise ProtocolError("too_short")
        if len(data) > MAX_PACKET_SIZE:
            raise ProtocolError("too_long")
        hdr_magic, ver, src, dst, typ, seq, sess, txn, plen = _HEADER.unpack_from(data)
        if hdr_magic != magic:
            raise ProtocolError("bad_magic")
        if ver != PROTOCOL_VERSION:
            raise ProtocolError("bad_version")
        if typ not in {int(m) for m in MsgType}:
            raise ProtocolError("bad_type")
        if plen > MAX_PAYLOAD or HEADER_SIZE + plen != len(data):
            raise ProtocolError("bad_length")
        return cls(src, dst, typ, seq, sess, txn, bytes(data[HEADER_SIZE:]), hdr_magic, ver)


def encode_command_payload(name: str, params: dict | None = None) -> bytes:
    """Binary command payload, identical to buildCommandPayload() on the hub."""
    code = CommandCode[name]
    p = normalize_command(name, params) if name in PC_COMMANDS else {}
    if code == CommandCode.SET_MODE:
        return bytes([code, OperationMode[p["mode"]]])
    if code == CommandCode.SET_LIGHT_MODE:
        r, g, b = p.get("color", (0, 0, 0))
        return struct.pack(
            "<BBBHBBBB", code, LightMode[p["mode"]], p["brightness"], p["transition_ms"], p["speed"], r, g, b
        )
    if code == CommandCode.TRIGGER_EFFECT:
        return struct.pack("<BBHB", code, EffectId[p["effect"]], p["duration_ms"], p["intensity"])
    if code == CommandCode.RELAY_PULSE:
        return struct.pack("<BBH", code, p["relay_id"], p["duration_ms"])
    if code == CommandCode.RELAY_OFF:
        return struct.pack("<BB", code, p["relay_id"])
    if code == CommandCode.SET_MIST:
        return struct.pack("<BBH", code, MistPattern[p["pattern"]], p["duration_s"])
    return bytes([code])


def encode_ack_payload(acked_type: int, result: int, flags: int = 0, acked_seq: int = 0, detail: int = 0) -> bytes:
    return struct.pack("<BBBHB", acked_type, result, flags, acked_seq, detail)


def encode_event_payload(code: EventCode, **f: int) -> bytes:
    if code == EventCode.BALL_RECEIVED:
        return struct.pack("<BH", code, f.get("cycle", 0))
    if code == EventCode.RELEASE_STARTED:
        return struct.pack("<BI", code, f.get("command_id", 0))
    if code == EventCode.RELEASE_DONE:
        return struct.pack("<BIH", code, f.get("command_id", 0), f.get("elapsed_ms", 0))
    if code == EventCode.RELEASE_FAILED:
        return struct.pack("<BIB", code, f.get("command_id", 0), f.get("reason", 0))
    if code == EventCode.RELAY_DONE:
        return struct.pack("<BBHB", code, f.get("relay_id", 0), f.get("on_ms", 0), f.get("reason", 0))
    if code == EventCode.MIST_DONE:
        return struct.pack("<BHB", code, f.get("on_s", 0), f.get("reason", 0))
    if code == EventCode.DEVICE_ERROR:
        return struct.pack("<BBB", code, f.get("code", 0), f.get("detail", 0))
    raise ProtocolError(f"unknown event {code}")


def encode_hub_heartbeat(uptime_ms: int, flags: int) -> bytes:
    return struct.pack("<IB", uptime_ms, flags)


def encode_node_heartbeat(
    echo_seq: int,
    boot_id: int,
    uptime_ms: int,
    device_type: int,
    state: int,
    flags: int,
    rssi: int = 0,
    rx_rejected: int = 0,
    fw: tuple[int, int] = (0, 1),
) -> bytes:
    return struct.pack(
        "<HIIBBBbHBB", echo_seq, boot_id, uptime_ms, device_type, state, flags, rssi, rx_rejected, fw[0], fw[1]
    )


@dataclass
class CommandResult:
    """Outcome of one command. ``ok`` means the device accepted it (ACK=ACCEPTED).

    ACCEPTED is *acceptance*, not physical completion: e.g. RELEASE_BALL is
    finished only when the RELEASE_DONE event arrives.
    """

    command_id: int
    destination: int
    name: str
    result: str
    origin: str = "hub"
    duplicate: bool = False
    clamped: bool = False
    attempts: int = 0
    reason: str | None = None
    raw: dict = field(default_factory=dict, repr=False)

    @property
    def ok(self) -> bool:
        return self.result == "ACCEPTED"


@dataclass
class DeviceEvent:
    """An event delivered to the application.

    Device events (BALL_RECEIVED, ...) carry ``event_id``; it is unique per
    device and session and duplicates are already removed by the gateway.
    """

    name: str
    source: int | None
    data: dict = field(default_factory=dict)
    event_id: int | None = None
    session_id: int | None = None
    received_at: float = 0.0
