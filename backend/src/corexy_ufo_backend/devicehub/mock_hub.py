"""Mock hub + mock devices (JSON Lines level) for hardware-free testing.

``MockHub`` implements the same LineTransport interface as the serial
transport, so ``DeviceGateway(transport=MockHub())`` runs the real gateway
code against a simulated hub that follows the firmware rules (sessions,
command de-duplication, ACK/timeout, event re-send until EVENT_ACK, relay
limits, M5Dial state machine).

Fault injection: ACK loss, duplicated events, ignored EVENT_ACKs, device
power loss / reboot, USB unplug, silent hub, hub reboot.

Run ``python -m pc.mock_hub --pty`` to expose the mock on a pseudo terminal
(for tests/tools/ufo_cli.py or the game) - POSIX only.
"""

from __future__ import annotations

import argparse
import json
import queue
import threading
import time
from dataclasses import dataclass, field

from . import protocol as P
from .device_gateway import TransportError
from .protocol import DeviceId, ProtocolError


@dataclass
class MockConfig:
    max_retries: int = 3
    pc_timeout: float = 3.0
    pc_event_retry: float = 0.5
    relay_max_on_ms: int = 3000
    relay_cooldown_ms: int = 2000
    servo_hold_ms: int = 1500
    servo_settle_ms: int = 600
    effect_default_ms: int = 1000
    mist_max_s: int = 600
    # Game mode LEDs (docs/game-mode-interface.md)
    dial_transfer_led: bool = True  # second LED on G15 (False = DIAL_TRANSFER_LED_PIN -1)
    dial_colors: dict = field(default_factory=lambda: {0x20: (0, 255, 255), 0x21: (255, 0, 255)})
    dial_rx_flash_ms: int = 150
    dial_rx_chase_ms: int = 1500
    system_id: int = 1
    channel: int = 1
    tick: float = 0.005


def _ms() -> int:
    return int(time.monotonic() * 1000)


class MockDevice:
    device_type = "UNKNOWN"

    def __init__(self, dev_id: int, hub: MockHub) -> None:
        self.id = dev_id
        self.hub = hub
        self.online = True
        self.session = 0
        self.op_mode = "STANDBY"
        self.dedup: dict[int, str] = {}
        self.boot_id = 1
        self.executed: list[tuple[str, dict]] = []

    def set_session(self, s: int) -> None:
        if s != self.session:
            self.session = s
            self.dedup.clear()
            self.on_session_changed(s)

    def handle(self, name: str, params: dict, cid: int, session: int) -> tuple[str, bool]:
        """Returns (result, clamped). Implements the NodeCore rules."""
        if name not in P.NO_SESSION_COMMANDS and (self.session == 0 or session != self.session):
            return "REJECTED_SESSION", False
        if name == "GET_STATUS":
            self.hub._emit_line(self.status())
            return "ACCEPTED", False
        if cid in self.dedup:
            return self.dedup[cid], False
        res, clamped = self.execute(name, params, cid)
        self.dedup[cid] = res
        if res == "ACCEPTED":
            self.executed.append((name, params))
        return res, clamped

    # overridden
    def execute(self, name: str, params: dict, cid: int) -> tuple[str, bool]:
        return "UNSUPPORTED", False

    def on_session_changed(self, s: int) -> None:
        self.op_mode = "STANDBY"

    def on_link_lost(self) -> None:
        pass

    def tick(self, now: int) -> None:
        pass

    def state(self) -> str:
        return "NORMAL"

    def status(self) -> dict:
        return {
            "type": "STATUS",
            "source": self.id,
            "device_type": self.device_type,
            "state": self.state(),
            "op_mode": self.op_mode,
            "boot_id": self.boot_id,
            "fw": "0.1",
            "flags": {"session_valid": self.session != 0, "hub_link": self.online},
        }

    def emit(self, name: str, **data) -> None:
        if self.session:
            self.hub._queue_event(self.id, self.session, name, data)


class MockIllumination(MockDevice):
    device_type = "ILLUMINATION"
    PRIORITY = {"GAME_CLEAR": 3, "SCORE": 2}

    def __init__(self, dev_id: int, hub: MockHub) -> None:
        super().__init__(dev_id, hub)
        self.light_mode = "IDLE"
        self.brightness = 128
        self.effect: str | None = None
        self.effect_until = 0
        self.relay_on = False
        self.relay_on_at = 0
        self.relay_until = 0
        self.cooldown_until = 0
        self.relay_pulses = 0
        self.mist_pattern = "OFF"
        self.mist_started = 0
        self.mist_until = 0
        self.mist_on_ms = 0
        self.mist_last = 0

    PATTERN = {"CONTINUOUS": (1, 1), "BREATH": (14000, 8000), "PUFF": (12000, 3000)}

    def mist_output(self, now: int) -> bool:
        if self.mist_pattern == "OFF":
            return False
        period, on = self.PATTERN[self.mist_pattern]
        return (now - self.mist_started) % period < on

    def mist_stop(self, now: int, reason: P.RelayEndReason) -> None:
        if self.mist_pattern != "OFF":
            self.mist_tick(now)
            self.mist_pattern = "OFF"
            self.emit("MIST_DONE", on_s=self.mist_on_ms // 1000, reason=int(reason))

    def mist_tick(self, now: int) -> None:
        if self.mist_pattern != "OFF" and self.mist_output(self.mist_last):
            self.mist_on_ms += now - self.mist_last
        self.mist_last = now

    def relay_off(self, now: int, reason: P.RelayEndReason) -> None:
        if self.relay_on:
            self.relay_on = False
            self.cooldown_until = now + self.hub.cfg.relay_cooldown_ms
            self.emit("RELAY_DONE", relay_id=0, on_ms=now - self.relay_on_at, reason=int(reason))

    def execute(self, name: str, p: dict, cid: int) -> tuple[str, bool]:
        now = _ms()
        if name == "STOP_ALL":
            self.relay_off(now, P.RelayEndReason.SAFETY)
            self.mist_stop(now, P.RelayEndReason.SAFETY)
            self.effect = None
            return "ACCEPTED", False
        if name == "SET_MODE":
            self.op_mode = p["mode"]
            return "ACCEPTED", False
        if name == "SET_LIGHT_MODE":
            self.light_mode, self.brightness = p["mode"], p["brightness"]
            if self.light_mode == "ERROR":
                self.effect = None
            return "ACCEPTED", False
        if name == "TRIGGER_EFFECT":
            if self.light_mode == "ERROR":
                return "IGNORED_PRIORITY", False
            if self.effect and now < self.effect_until:
                if self.PRIORITY.get(p["effect"], 1) < self.PRIORITY.get(self.effect, 1):
                    return "IGNORED_PRIORITY", False
            self.effect = p["effect"]
            self.effect_until = now + (p["duration_ms"] or self.hub.cfg.effect_default_ms)
            return "ACCEPTED", False
        if name == "RELAY_PULSE":
            if p["relay_id"] != 0:
                return "INVALID_PARAMS", False
            if self.relay_on:
                return "BUSY", False
            if now < self.cooldown_until:
                return "COOLDOWN", False
            d = p["duration_ms"]
            clamped = d > self.hub.cfg.relay_max_on_ms
            d = min(d, self.hub.cfg.relay_max_on_ms)
            self.relay_on, self.relay_on_at, self.relay_until = True, now, now + d
            self.relay_pulses += 1
            return "ACCEPTED", clamped
        if name == "SET_MIST":
            if p["pattern"] == "OFF":
                self.mist_stop(now, P.RelayEndReason.OFF_COMMAND)
                return "ACCEPTED", False
            if not self.online:
                return "REJECTED_STATE", False
            d = p["duration_s"] or self.hub.cfg.mist_max_s
            clamped = d > self.hub.cfg.mist_max_s
            d = min(d, self.hub.cfg.mist_max_s)
            self.mist_tick(now)
            self.mist_pattern, self.mist_started, self.mist_until = p["pattern"], now, now + d * 1000
            self.mist_on_ms, self.mist_last = 0, now
            return "ACCEPTED", clamped
        if name == "RELAY_OFF":
            if p["relay_id"] not in (0, 255):
                return "INVALID_PARAMS", False
            self.relay_off(now, P.RelayEndReason.OFF_COMMAND)
            return "ACCEPTED", False
        return "UNSUPPORTED", False

    def on_session_changed(self, s: int) -> None:
        super().on_session_changed(s)
        self.relay_off(_ms(), P.RelayEndReason.SAFETY)
        self.mist_stop(_ms(), P.RelayEndReason.SAFETY)
        self.effect = None
        if s == 0:
            self.light_mode = "IDLE"

    def on_link_lost(self) -> None:
        self.relay_off(_ms(), P.RelayEndReason.SAFETY)
        self.mist_stop(_ms(), P.RelayEndReason.SAFETY)

    def tick(self, now: int) -> None:
        if self.relay_on and now >= self.relay_until:
            self.relay_off(now, P.RelayEndReason.COMPLETED)
        if self.effect and now >= self.effect_until:
            self.effect = None
        self.mist_tick(now)
        if self.mist_pattern != "OFF" and now >= self.mist_until:
            self.mist_stop(now, P.RelayEndReason.COMPLETED)

    def state(self) -> str:
        if self.relay_on:
            return "RELAY_ACTIVE"
        if self.mist_pattern != "OFF":
            return "MIST_ACTIVE"
        return "EFFECT" if self.effect else "NORMAL"

    def status(self) -> dict:
        s = super().status()
        s.update(
            light_mode=self.light_mode,
            brightness=self.brightness,
            active_effect=self.effect or "NONE",
            relay_on_mask=1 if self.relay_on else 0,
            relay_pulses=self.relay_pulses,
            mist_pattern=self.mist_pattern,
            mist_on=self.mist_output(_ms()),
            local_mode=False,
            mist_remaining_s=max(0, (self.mist_until - _ms() + 999) // 1000) if self.mist_pattern != "OFF" else 0,
            mist_on_s=self.mist_on_ms // 1000,
        )
        return s


class MockDial(MockDevice):
    device_type = "DIAL"

    def __init__(self, dev_id: int, hub: MockHub) -> None:
        super().__init__(dev_id, hub)
        self.dial_state = "DISABLED"
        self.cycle = 0
        self.phase_until = 0
        self.release_cmd = 0
        self.release_started = 0
        self.releases = 0
        self.servo_moves = 0
        self.aborted = False
        # Game mode LEDs: one PC effect slot per output, like the firmware
        self.slots: dict[str, dict | None] = {"FRONT": None, "TRANSFER": None}
        self.color = tuple(hub.cfg.dial_colors.get(int(dev_id), (0, 255, 255)))
        self.detected_at = 0
        self.release_at = 0
        self.effect_log: list[dict] = []  # every accepted SET_DIAL_EFFECT (tests / traces)

    @property
    def busy(self) -> bool:
        return self.dial_state in ("RELEASING", "RETURNING")

    def _idle(self) -> None:
        self.dial_state = "READY" if self.op_mode == "GAME" else "DISABLED"

    # ---- LEDs (same rules as firmware/m5dial/dial_controller.cpp) -------------
    def clear_effects(self) -> None:
        self.slots = {"FRONT": None, "TRANSFER": None}

    def _slot(self, target: str, now: int) -> dict | None:
        s = self.slots[target]
        if s and s["duration_ms"] and now - s["started_at"] >= s["duration_ms"]:
            self.slots[target] = s = None
        return s

    def _set_effect(self, p: dict, cid: int, now: int) -> str:
        targets = ["FRONT", "TRANSFER"] if p["target"] == "BOTH" else [p["target"]]
        if not self.hub.cfg.dial_transfer_led:
            targets = [t for t in targets if t != "TRANSFER"]
        if not targets:
            return "NOT_CONFIGURED"
        prio = int(P.EffectPriority[p["priority"]])
        for t in targets:
            s = self._slot(t, now)
            if s and prio < s["priority"]:
                return "IGNORED_PRIORITY"
        for t in targets:
            self.slots[t] = None if p["effect"] == "NONE" else {
                "effect": p["effect"], "direction": p["direction"], "color": tuple(p.get("color", (0, 0, 0))),
                "duration_ms": p["duration_ms"], "priority": prio, "started_at": now, "command_id": cid,
            }
        self.effect_log.append({"command_id": cid, "targets": targets, **p})
        return "ACCEPTED"

    def led(self, target: str = "FRONT", now: int | None = None) -> dict:
        """What the output shows now: {scene, source ('local' / 'pc'), effect, direction, color}."""
        now = _ms() if now is None else now
        off = {"scene": "OFF", "source": "local", "effect": "NONE", "direction": "NONE", "color": (0, 0, 0)}
        ring = target == "FRONT"
        if not ring and not self.hub.cfg.dial_transfer_led:
            return off
        if not self.online:
            return {**off, "scene": "LINK_LOST"} if ring else off
        cfg = self.hub.cfg
        since_rx = now - self.detected_at
        fx = {"scene": "EFFECT", "source": "local", "direction": "NONE", "color": self.color}
        if self.dial_state == "BALL_DETECTED" and since_rx < cfg.dial_rx_flash_ms:
            return {**fx, "effect": "SOLID", "color": (255, 255, 255)}
        s = self._slot(target, now)
        if s:
            return {"scene": "EFFECT", "source": "pc", "effect": s["effect"], "direction": s["direction"],
                    "color": s["color"] if any(s["color"]) else self.color}
        if self.dial_state == "BALL_DETECTED":
            if since_rx < cfg.dial_rx_flash_ms + cfg.dial_rx_chase_ms:
                return {**fx, "effect": "CHASE", "direction": "TO_SCREEN"}
            return {**fx, "effect": "BREATHE"}
        if self.busy:
            return {**fx, "effect": "CHASE", "direction": "TO_DIAL"}
        scene = {"DISABLED": "IDLE", "READY": "READY", "ARMED": "ARMED", "COMPLETE": "COMPLETE"}.get(
            self.dial_state, "OFF")
        return {**off, "scene": scene, "color": self.color} if ring else off

    def execute(self, name: str, p: dict, cid: int) -> tuple[str, bool]:
        if name == "SET_DIAL_EFFECT":
            return self._set_effect(p, cid, _ms()), False
        if name == "SET_DIAL_COLOR":
            c = tuple(p["color"])
            self.color = c if any(c) else tuple(self.hub.cfg.dial_colors.get(int(self.id), (0, 255, 255)))
            return "ACCEPTED", False
        if name == "STOP_ALL":
            self.op_mode = "STANDBY"
            self.clear_effects()
            if self.busy:
                self.aborted = True
                self.dial_state = "RETURNING"
                self.phase_until = _ms() + self.hub.cfg.servo_settle_ms
            else:
                self._idle()
            return "ACCEPTED", False
        if name == "SET_MODE":
            if p["mode"] == "STANDBY":
                if self.busy:
                    return "BUSY", False
                self.op_mode, self.dial_state = "STANDBY", "DISABLED"
            else:
                self.op_mode = "GAME"
                if self.dial_state == "DISABLED":
                    self.dial_state = "READY"
            return "ACCEPTED", False
        if name == "ARM_RECEIVER":
            if self.busy:
                return "BUSY", False
            if self.op_mode != "GAME":
                return "REJECTED_STATE", False
            if self.dial_state == "ARMED":
                return "ACCEPTED", False
            if self.dial_state not in ("READY", "COMPLETE"):
                return "REJECTED_STATE", False
            self.cycle += 1
            self.dial_state = "ARMED"
            return "ACCEPTED", False
        if name == "DISARM_RECEIVER":
            if self.busy:
                return "BUSY", False
            if self.dial_state == "BALL_DETECTED":
                return "REJECTED_STATE", False
            if self.dial_state == "ARMED":
                self.dial_state = "READY"
            return "ACCEPTED", False
        if name == "RELEASE_BALL":
            if self.busy:
                return "BUSY", False
            if self.op_mode != "GAME" or self.dial_state != "BALL_DETECTED":
                return "REJECTED_STATE", False
            now = _ms()
            self.release_at = now
            self.dial_state, self.phase_until = "RELEASING", now + self.hub.cfg.servo_hold_ms
            self.release_cmd, self.release_started, self.aborted = cid, now, False
            self.releases += 1
            self.servo_moves += 1
            self.emit("RELEASE_STARTED", command_id=cid)
            return "ACCEPTED", False
        return "UNSUPPORTED", False

    def ball(self) -> bool:
        if self.dial_state != "ARMED" or not self.online:
            return False
        self.dial_state = "BALL_DETECTED"
        self.detected_at = _ms()
        self.clear_effects()  # the local receive animation starts at once
        self.emit("BALL_RECEIVED", cycle=self.cycle)
        return True

    def on_session_changed(self, s: int) -> None:
        super().on_session_changed(s)
        self.clear_effects()
        self.color = tuple(self.hub.cfg.dial_colors.get(int(self.id), (0, 255, 255)))
        if not self.busy:
            self._idle()

    def on_link_lost(self) -> None:
        self.clear_effects()
        if self.dial_state == "ARMED":
            self.dial_state = "READY"

    def tick(self, now: int) -> None:
        if self.dial_state == "RELEASING" and now >= self.phase_until:
            self.dial_state, self.phase_until = "RETURNING", now + self.hub.cfg.servo_settle_ms
        elif self.dial_state == "RETURNING" and now >= self.phase_until:
            self.clear_effects()  # the release animation ends with the sequence
            if self.aborted:
                self.emit("RELEASE_FAILED", command_id=self.release_cmd, reason=int(P.ReleaseFailReason.ABORTED))
                self._idle()
            else:
                self.emit("RELEASE_DONE", command_id=self.release_cmd, elapsed_ms=now - self.release_started)
                if self.op_mode == "GAME":
                    self.dial_state = "COMPLETE"
                else:
                    self._idle()

    def state(self) -> str:
        return self.dial_state

    def status(self) -> dict:
        s = super().status()
        now = _ms()
        ring, strip = self._slot("FRONT", now), self._slot("TRANSFER", now)
        s.update(dial_state=self.dial_state, cycle=self.cycle, releases=self.releases,
                 last_release_command=self.release_cmd,
                 front_effect=ring["effect"] if ring else "NONE",
                 transfer_effect=strip["effect"] if strip else "NONE",
                 transfer_led=self.hub.cfg.dial_transfer_led, unit_color=list(self.color))
        return s


@dataclass
class _PcEvent:
    source: int
    session: int
    event_id: int
    name: str
    data: dict
    last_tx: float = 0.0
    attempts: int = 0


class MockHub:
    """Simulated hub (+ Illumination + 2 M5Dials) behind a LineTransport API."""

    def __init__(self, config: MockConfig | None = None, *, autostart: bool = True) -> None:
        self.cfg = config or MockConfig()
        self._lock = threading.RLock()
        self._out: queue.Queue[str] = queue.Queue()
        self.received: list[dict] = []
        self.session = 0
        self.last_pc_rx = time.monotonic()
        self.plugged = True
        self.is_open = False
        self.silent = False
        self.duplicate_events = False
        self.ignore_event_acks = False
        self._ack_loss: dict[int, int] = {}
        self._outbox: list[_PcEvent] = []
        self._next_event_id = 1000
        self.counters = {"commands": 0, "ack_timeouts": 0, "retransmissions": 0, "events": 0, "event_resends": 0}
        self.devices: dict[int, MockDevice] = {
            DeviceId.ILLUMINATION: MockIllumination(DeviceId.ILLUMINATION, self),
            DeviceId.M5DIAL_1: MockDial(DeviceId.M5DIAL_1, self),
            DeviceId.M5DIAL_2: MockDial(DeviceId.M5DIAL_2, self),
        }
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        if autostart:
            self.start()

    # ---- LineTransport ------------------------------------------------------
    def open(self) -> None:
        if not self.plugged:
            raise TransportError("mock: unplugged")
        self.is_open = True

    def close(self) -> None:
        self.is_open = False

    def write_line(self, line: str) -> None:
        if not self.plugged or not self.is_open:
            raise TransportError("mock: unplugged")
        if len(line.encode()) > P.MAX_LINE:
            self._emit_line({"type": "ERROR", "code": "LINE_TOO_LONG"})
            return
        self._handle_pc_line(line)

    def read_line(self, timeout: float) -> str | None:
        if not self.plugged or not self.is_open:
            raise TransportError("mock: unplugged")
        try:
            return self._out.get(timeout=timeout)
        except queue.Empty:
            return None

    # ---- simulation control ------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="mock-hub", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)

    def lose_acks(self, device_id: int, count: int) -> None:
        """The next ``count`` device ACKs from this device are lost on air."""
        with self._lock:
            self._ack_loss[int(device_id)] = count

    def ball(self, device_id: int) -> bool:
        with self._lock:
            dev = self.devices[int(device_id)]
            return isinstance(dev, MockDial) and dev.ball()

    def set_device_online(self, device_id: int, online: bool, *, reboot: bool = False) -> None:
        with self._lock:
            dev = self.devices[int(device_id)]
            if dev.online == online:
                return
            dev.online = online
            if not online:
                dev.on_link_lost()
                self._emit_line({"type": "LINK", "source": dev.id, "online": False})
                return
            if reboot:
                fresh = type(dev)(dev.id, self)
                fresh.boot_id = dev.boot_id + 1
                self.devices[dev.id] = dev = fresh
                self._emit_line({"type": "DEVICE_REBOOTED", "source": dev.id, "boot_id": dev.boot_id})
            self._emit_line({"type": "LINK", "source": dev.id, "online": True})
            dev.set_session(self.session)

    def unplug(self) -> None:
        self.plugged = False
        self.is_open = False

    def replug(self) -> None:
        self.plugged = True

    def reboot_hub(self) -> None:
        with self._lock:
            self.session = 0
            self._outbox.clear()
            for d in self.devices.values():
                d.set_session(0)
            self._emit_line({"type": "BOOT", "protocol_version": 1, "fw": "mock", "hub_mac": "02:00:00:00:00:01",
                             "system_id": self.cfg.system_id, "channel": self.cfg.channel})

    # ---- hub behaviour -------------------------------------------------------
    def _emit_line(self, msg: dict) -> None:
        if self.silent:
            return
        self._out.put(json.dumps(msg, separators=(",", ":")))

    def _queue_event(self, source: int, session: int, name: str, data: dict) -> None:
        with self._lock:
            self._next_event_id += 1
            ev = _PcEvent(source, session, self._next_event_id, name, data)
            self._outbox.append(ev)
            self.counters["events"] += 1
            self._send_event(ev)
            if self.duplicate_events:
                self._send_event(ev)

    def _send_event(self, ev: _PcEvent) -> None:
        ev.attempts += 1
        ev.last_tx = time.monotonic()
        self._emit_line(
            {
                "type": "EVENT",
                "source": ev.source,
                "session_id": ev.session,
                "event_id": ev.event_id,
                "name": ev.name,
                "attempt": ev.attempts,
                "data": ev.data,
            }
        )

    def _set_session(self, s: int) -> None:
        if s == self.session:
            return
        self.session = s
        self._outbox.clear()
        for d in self.devices.values():
            if d.online:
                d.set_session(s)

    def _ack(self, dest: int, cid: int, result: str, origin: str = "hub", **extra) -> None:
        msg = {"type": "ACK", "destination": dest, "command_id": cid, "result": result, "origin": origin}
        msg.setdefault("duplicate", False)
        msg.setdefault("clamped", False)
        msg.update(extra)
        self._emit_line(msg)

    def _handle_pc_line(self, line: str) -> None:
        with self._lock:
            try:
                m = P.decode_line(line)
            except ProtocolError as e:
                self._emit_line({"type": "ERROR", "code": "BAD_JSON", "detail": str(e)})
                return
            self.received.append(m)
            if m.get("protocol_version", 1) != 1:
                self._emit_line({"type": "ERROR", "code": "UNSUPPORTED_VERSION"})
                return
            self.last_pc_rx = time.monotonic()
            t = m["type"]
            if t == "HELLO":
                s = m.get("session_id")
                if not isinstance(s, int) or s <= 0:
                    self._emit_line({"type": "ERROR", "code": "BAD_REQUEST"})
                    return
                sys_id = m.get("system_id")
                if sys_id is not None and sys_id != self.cfg.system_id:
                    self._emit_line({"type": "ERROR", "code": "SYSTEM_MISMATCH",
                                     "detail": f"this hub is system {self.cfg.system_id}"})
                    return
                self._set_session(s)
                self._emit_line(
                    {"type": "HELLO_ACK", "protocol_version": 1, "session_id": s, "fw": "mock", "hub_id": 1,
                     "hub_mac": "02:00:00:00:00:01", "channel": self.cfg.channel, "system_id": self.cfg.system_id,
                     "system_check": "ok", "example_keys": False, "example_devices": True}
                )
            elif t == "BYE":
                self._close_session("pc_request")
            elif t == "HEARTBEAT":
                self._emit_line({"type": "HEARTBEAT", "session_id": self.session})
            elif t == "EVENT_ACK":
                if not self.ignore_event_acks:
                    self._outbox = [
                        e for e in self._outbox if not (e.source == m.get("source") and e.event_id == m.get("event_id"))
                    ]
            elif t == "GET_DEVICES":
                self._emit_line({"type": "DEVICES", "session_id": self.session, "devices": [
                    {"id": d.id, "name": type(d).__name__, "online": d.online, "state": d.state(),
                     "session_ok": d.session == self.session != 0} for d in self.devices.values()]})
            elif t == "GET_DIAG":
                self._emit_line({"type": "DIAG", "fw": "mock", "session_id": self.session,
                                 "counters": dict(self.counters),
                                 "devices": [{"id": d.id, "online": d.online} for d in self.devices.values()]})
            elif t == "COMMAND":
                self._command(m)
            else:
                self._emit_line({"type": "ERROR", "code": "UNKNOWN_TYPE", "detail": t})

    def _command(self, m: dict) -> None:
        dest, cid, sid, name = m.get("destination"), m.get("command_id"), m.get("session_id"), m.get("name")
        if not isinstance(dest, int) or not isinstance(cid, int) or cid <= 0 or not isinstance(sid, int):
            self._ack(dest or 0, cid or 0, "BAD_REQUEST")
            return
        try:
            params = P.normalize_command(name, m.get("params"))
        except ProtocolError as e:
            self._ack(dest, cid, "BAD_REQUEST", reason=str(e))
            return
        dev = self.devices.get(dest)
        needs_session = name not in P.NO_SESSION_COMMANDS
        if dev is None:
            self._ack(dest, cid, "UNKNOWN_DEVICE")
        elif needs_session and self.session == 0:
            self._ack(dest, cid, "NO_SESSION")
        elif needs_session and sid != self.session:
            self._ack(dest, cid, "SESSION_MISMATCH")
        elif not dev.online:
            self._ack(dest, cid, "OFFLINE")
        else:
            self.counters["commands"] += 1
            lost = self._ack_loss.pop(dest, 0)
            first_result, clamped = dev.handle(name, params, cid, sid)  # the device executes once ...
            attempts = 1
            for _ in range(min(lost, self.cfg.max_retries)):  # ... and answers retransmissions from its cache
                attempts += 1
                self.counters["retransmissions"] += 1
            if lost > self.cfg.max_retries:
                self.counters["ack_timeouts"] += 1
                self._ack(dest, cid, "TIMEOUT", attempts=attempts)
            else:
                self._ack(dest, cid, first_result, origin="device", duplicate=lost > 0, clamped=clamped,
                          attempts=attempts)

    def _close_session(self, reason: str) -> None:
        if self.session == 0:
            return
        old = self.session
        self._set_session(0)
        self._emit_line({"type": "SESSION_CLOSED", "session_id": old, "reason": reason})

    def _run(self) -> None:
        while not self._stop.is_set():
            now = _ms()
            with self._lock:
                for d in self.devices.values():
                    if d.online:
                        d.tick(now)
                t = time.monotonic()
                if self.session and t - self.last_pc_rx > self.cfg.pc_timeout:
                    self._close_session("pc_timeout")
                for ev in self._outbox:
                    if t - ev.last_tx >= self.cfg.pc_event_retry:
                        self.counters["event_resends"] += 1
                        self._send_event(ev)
            self._stop.wait(self.cfg.tick)


def _serve_pty() -> None:  # pragma: no cover - manual tool
    import os
    import pty
    import select

    hub = MockHub()
    hub.open()
    master, slave = pty.openpty()
    print(f"mock hub on {os.ttyname(slave)}  (Ctrl-C to stop)")
    buf = b""
    while True:
        r, _, _ = select.select([master], [], [], 0.01)
        if r:
            buf += os.read(master, 4096)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    hub.write_line(line.decode(errors="replace").strip())
        while True:
            out = hub.read_line(0)
            if out is None:
                break
            os.write(master, out.encode() + b"\n")


def main() -> None:  # pragma: no cover
    ap = argparse.ArgumentParser(description="UFO mock hub")
    ap.add_argument("--pty", action="store_true", help="serve the mock on a pseudo terminal")
    args = ap.parse_args()
    if args.pty:
        _serve_pty()
    else:
        ap.print_help()


if __name__ == "__main__":  # pragma: no cover
    main()
