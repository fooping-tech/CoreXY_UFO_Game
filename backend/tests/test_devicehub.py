"""The peripherals' hub for the settings screen's テスト tab (#108), against UFO-DeviceHub's own
MockHub (the same gateway code as with the real hub)."""

from __future__ import annotations

import asyncio
import json

import pytest
import websockets

from corexy_ufo_backend.devicehub import DeviceHubConfig, DeviceHubService
from corexy_ufo_backend.devicehub import device_gateway as gwmod
from corexy_ufo_backend.devicehub.device_gateway import TransportError
from corexy_ufo_backend.devicehub.service import ExcludingSerialTransport
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.websocket import GameServer

ILL, DIAL1, DIAL2 = 0x10, 0x20, 0x21


def test_config_from_raw():
    assert DeviceHubConfig.from_raw({}) == DeviceHubConfig(False, "auto", 1)
    c = DeviceHubConfig.from_raw({"devicehub": {"enabled": True, "port": "mock", "system_id": 2.0}})
    assert c == DeviceHubConfig(True, "mock", 2)
    assert DeviceHubConfig.from_raw({"devicehub": {"system_id": 9}}).system_id == 1


def test_auto_detect_never_opens_the_robots_port(monkeypatch):
    opened = []

    class FakeSerial:
        def __init__(self, port, *a, **k):
            opened.append((port, k.get("exclusive")))

        def reset_input_buffer(self):
            pass

    import serial
    monkeypatch.setattr(serial, "Serial", FakeSerial)
    monkeypatch.setattr(gwmod, "guess_ports", lambda: ["/dev/cu.usbserial-CORE2", "/dev/cu.usbmodem-HUB"])
    t = ExcludingSerialTransport("auto", exclude=["/dev/cu.usbserial-CORE2"])
    t.open()
    assert opened == [("/dev/cu.usbmodem-HUB", True)]  # the hub only, exclusively
    t._rejected.add("/dev/cu.usbmodem-HUB")  # it was not a hub after all
    t.open()  # every other port refused: starts over, but still never the robot's port
    assert opened == [("/dev/cu.usbmodem-HUB", True), ("/dev/cu.usbmodem-HUB", True)]
    monkeypatch.setattr(gwmod, "guess_ports", lambda: ["/dev/cu.usbserial-CORE2"])
    with pytest.raises(TransportError, match="robot's ports are not tried"):
        ExcludingSerialTransport("auto", exclude=["/dev/cu.usbserial-CORE2"]).open()
    with pytest.raises(TransportError, match="robot's"):
        ExcludingSerialTransport("/dev/cu.usbserial-CORE2", exclude=["/dev/cu.usbserial-CORE2"]).open()


def test_a_port_that_cannot_be_opened_does_not_hide_the_hub(monkeypatch):
    """Review on #109: a locked port first in the list: the next attempt tries the hub."""
    opened = []

    class FakeSerial:
        def __init__(self, port, *a, **k):
            opened.append(port)
            if port.endswith("LOCKED"):
                raise OSError("Resource busy")

        def reset_input_buffer(self):
            pass

    import serial
    monkeypatch.setattr(serial, "Serial", FakeSerial)
    monkeypatch.setattr(gwmod, "guess_ports", lambda: ["/dev/cu.usbmodem-LOCKED", "/dev/cu.usbmodem-HUB"])
    t = ExcludingSerialTransport("auto")
    with pytest.raises(TransportError):
        t.open()
    t.open()
    assert opened == ["/dev/cu.usbmodem-LOCKED", "/dev/cu.usbmodem-HUB"]


async def _server(devicehub):
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, devicehub=devicehub)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def _cmd(ws, name, params=None, rid="r", events=None):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params or {}}}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 10))
        if m.get("type") == "devicehub_event" and events is not None:
            events.append(m["data"])
        if m.get("request_id") == rid:
            return m


async def _until_connected(ws, events):
    for i in range(100):
        m = await _cmd(ws, "devicehub_meta", rid=f"meta{i}", events=events)
        if m["data"]["connected"]:
            return m
        await asyncio.sleep(0.05)
    raise AssertionError("the mock hub never connected")


async def test_the_test_tab_commands_through_the_mock_hub():
    hub = DeviceHubService(DeviceHubConfig(True, "mock", 1))
    srv, port = await _server(hub)
    events: list[dict] = []
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            meta = await _until_connected(ws, events)
            assert meta["data"]["system_id"] == 1 and "GAME_PLAY" in meta["data"]["enums"]["light_modes"]
            for i in range(60):  # the devices come online after the hub's session
                devs = (await _cmd(ws, "devicehub_devices", rid=f"d{i}", events=events))["data"]["devices"]
                if sum(1 for d in devs if d.get("online")) >= 3:
                    break
                await asyncio.sleep(0.1)
            assert sum(1 for d in devs if d.get("online")) >= 3, devs
            light = await _cmd(ws, "devicehub_command", {"device": ILL, "name": "SET_LIGHT_MODE",
                                                          "params": {"mode": "GAME_PLAY", "brightness": 180}},
                               rid="light", events=events)
            assert light["type"] == "ack" and light["data"]["result"]["ok"], light
            pulse = await _cmd(ws, "devicehub_command", {"device": ILL, "name": "RELAY_PULSE",
                                                          "params": {"relay_id": 0, "duration_ms": 100}},
                               rid="pulse", events=events)
            assert pulse["data"]["result"]["ok"]
            mode = await _cmd(ws, "devicehub_command", {"device": DIAL1, "name": "SET_MODE", "params": {"mode": "GAME"}},
                              rid="mode", events=events)
            assert mode["data"]["result"]["ok"]
            for i in range(40):  # RELAY_DONE comes back as an event
                if any(e.get("name") == "RELAY_DONE" for e in events):
                    break
                await _cmd(ws, "devicehub_meta", rid=f"w{i}", events=events)
                await asyncio.sleep(0.05)
            assert any(e.get("name") == "RELAY_DONE" for e in events), events
            st = await _cmd(ws, "devicehub_status", {"device": ILL}, rid="st", events=events)
            assert st["type"] == "ack" and isinstance(st["data"]["status"], dict)
            diag = await _cmd(ws, "devicehub_diag", rid="diag", events=events)
            assert diag["type"] == "ack"
            bad = await _cmd(ws, "devicehub_command", {"device": "ill", "name": "SET_MIST"}, rid="bad", events=events)
            assert bad["type"] == "nack"
            stop = await _cmd(ws, "devicehub_stop_all", rid="stop", events=events)
            assert stop["type"] == "ack" and stop["data"]["results"]
    finally:
        await srv.stop()


async def test_without_a_hub_the_commands_say_why():
    srv, port = await _server(None)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "devicehub_meta")
            assert m["type"] == "nack" and "devicehub.enabled" in m["data"]["reason"]
    finally:
        await srv.stop()


async def test_stop_all_goes_through_during_the_auto_catch():
    hub = DeviceHubService(DeviceHubConfig(True, "mock", 1))
    srv, port = await _server(hub)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _until_connected(ws, [])
            srv.auto.status = lambda: {"phase": "MOVE"}  # noqa: E731
            type(srv.auto).active = property(lambda self: True)
            try:
                m = await _cmd(ws, "devicehub_stop_all", rid="s")
            finally:
                del type(srv.auto).active
            assert m["type"] == "ack"
    finally:
        await srv.stop()


async def _wait_event(ws, events, name, source, tries=80):
    for i in range(tries):
        if any(e.get("name") == name and e.get("source") == source for e in events):
            return True
        await _cmd(ws, "devicehub_meta", rid=f"we{name}{source}{i}", events=events)
        await asyncio.sleep(0.05)
    return False


async def test_the_game_mode_round_on_the_mock_hub_left_and_right():
    """#138: a capsule lands in each Dial (devicehub_mock_ball), the game releases it from the
    same Dial; both Dials at once, each with its own cycle and events."""
    hub = DeviceHubService(DeviceHubConfig(True, "mock", 1))
    srv, port = await _server(hub)
    events: list[dict] = []
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            meta = await _until_connected(ws, events)
            assert meta["data"]["port"] == "mock" and meta["data"]["session_id"] > 0
            for i in range(60):
                devs = (await _cmd(ws, "devicehub_devices", rid=f"gd{i}", events=events))["data"]["devices"]
                if sum(1 for d in devs if d.get("online")) >= 3:
                    break
                await asyncio.sleep(0.1)
            early = await _cmd(ws, "devicehub_mock_ball", {"device": DIAL1}, rid="early", events=events)
            assert early["type"] == "ack" and early["data"]["accepted"] is False  # not armed: no capsule is taken
            for d in (DIAL1, DIAL2):
                assert (await _cmd(ws, "devicehub_command", {"device": d, "name": "SET_MODE", "params": {"mode": "GAME"}},
                                   rid=f"m{d}", events=events))["data"]["result"]["ok"]
                assert (await _cmd(ws, "devicehub_command", {"device": d, "name": "ARM_RECEIVER", "params": {}},
                                   rid=f"a{d}", events=events))["data"]["result"]["ok"]
            for d in (DIAL1, DIAL2):  # both sides at once
                ball = await _cmd(ws, "devicehub_mock_ball", {"device": d}, rid=f"b{d}", events=events)
                assert ball["type"] == "ack" and ball["data"]["accepted"] is True, ball
            again = await _cmd(ws, "devicehub_mock_ball", {"device": DIAL1}, rid="again", events=events)
            assert again["data"]["accepted"] is False  # one capsule per Dial
            for d in (DIAL1, DIAL2):
                assert await _wait_event(ws, events, "BALL_RECEIVED", d), events
            received = [e for e in events if e.get("name") == "BALL_RECEIVED"]
            assert len(received) == 2 and all(e["data"]["cycle"] == 1 and e["session_id"] == meta["data"]["session_id"]
                                              and e["event_id"] is not None for e in received), received
            for d in (DIAL2, DIAL1):  # released in the other order: each Dial its own
                rel = await _cmd(ws, "devicehub_command", {"device": d, "name": "RELEASE_BALL", "params": {}},
                                 rid=f"r{d}", events=events)
                assert rel["data"]["result"]["ok"] and rel["data"]["result"]["command_id"] > 0, rel
            twice = await _cmd(ws, "devicehub_command", {"device": DIAL1, "name": "RELEASE_BALL", "params": {}},
                               rid="twice", events=events)
            assert not twice["data"]["result"]["ok"]  # busy: a second release is refused, never queued
            for d in (DIAL1, DIAL2):
                assert await _wait_event(ws, events, "RELEASE_DONE", d, tries=120), events
                assert sum(1 for e in events if e.get("name") == "RELEASE_STARTED" and e.get("source") == d) == 1
                st = await _cmd(ws, "devicehub_status", {"device": d}, rid=f"s{d}", events=events)
                assert st["data"]["status"]["dial_state"] == "COMPLETE" and st["data"]["status"]["releases"] == 1, st
            bad = await _cmd(ws, "devicehub_mock_ball", {"device": "left"}, rid="bad", events=events)
            assert bad["type"] == "nack"
    finally:
        await srv.stop()


async def test_the_mock_ball_is_refused_on_a_real_hub():
    """#138: only the simulated hub fakes a capsule; a real hub's switch is the only source."""

    class Quiet:  # a transport that never answers (stands for a real serial port)
        current_port = "/dev/cu.usbmodem-HUB"

        def open(self): ...
        def close(self): ...
        def write_line(self, line): ...

        def read_line(self, timeout):
            import time
            time.sleep(min(timeout, 0.01))
            return None

    hub = DeviceHubService(DeviceHubConfig(True, "auto", 1), transport=Quiet())
    srv, port = await _server(hub)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "devicehub_mock_ball", {"device": DIAL1})
            assert m["type"] == "nack" and "mock" in m["data"]["reason"], m
    finally:
        await srv.stop()


async def test_the_dial_led_contract_on_the_mock_hub(tmp_path):
    """#138 / UFO-DeviceHub #8 (docs/game-mode-interface.md): the unit colour and the transfer
    effects reach each Dial for itself; a lower priority is refused, a release ends the effect;
    the hub's trace is written."""
    trace = tmp_path / "hub.jsonl"
    hub = DeviceHubService(DeviceHubConfig(True, "mock", 1, str(trace)))
    srv, port = await _server(hub)
    events: list[dict] = []

    async def dial(ws, device, name, params, rid):
        return await _cmd(ws, "devicehub_command", {"device": device, "name": name, "params": params}, rid=rid, events=events)

    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            meta = await _until_connected(ws, events)
            assert "COMET" in meta["data"]["enums"]["dial_effects"] and "TO_DIAL" in meta["data"]["enums"]["dial_directions"]
            for i in range(60):
                devs = (await _cmd(ws, "devicehub_devices", rid=f"ld{i}", events=events))["data"]["devices"]
                if sum(1 for d in devs if d.get("online")) >= 3:
                    break
                await asyncio.sleep(0.1)
            for d in (DIAL1, DIAL2):
                assert (await dial(ws, d, "SET_MODE", {"mode": "GAME"}, f"lm{d}"))["data"]["result"]["ok"]
            assert (await dial(ws, DIAL2, "SET_DIAL_COLOR", {"color": [255, 64, 208]}, "col"))["data"]["result"]["ok"]
            intake = {"effect": "CHASE", "direction": "TO_SCREEN", "duration_ms": 1500, "priority": "NORMAL", "target": "BOTH"}
            back = {"effect": "COMET", "direction": "TO_DIAL", "duration_ms": 0, "priority": "NORMAL", "target": "BOTH"}
            assert (await dial(ws, DIAL1, "SET_DIAL_EFFECT", intake, "fx1"))["data"]["result"]["ok"]
            assert (await dial(ws, DIAL2, "SET_DIAL_EFFECT", back, "fx2"))["data"]["result"]["ok"]  # the other way at once
            left, right = hub.transport.devices[DIAL1], hub.transport.devices[DIAL2]
            assert left.led("FRONT")["source"] == "pc" and left.led("FRONT")["direction"] == "TO_SCREEN"
            assert right.led("TRANSFER")["effect"] == "COMET" and tuple(right.led("FRONT")["color"]) == (255, 64, 208)
            st = await _cmd(ws, "devicehub_status", {"device": DIAL2}, rid="lst", events=events)
            assert st["data"]["status"]["front_effect"] == "COMET" and st["data"]["status"]["unit_color"] == [255, 64, 208]
            fault = {"effect": "FLASH", "duration_ms": 1500, "priority": "HIGH", "color": [255, 0, 0]}
            assert (await dial(ws, DIAL1, "SET_DIAL_EFFECT", fault, "hi"))["data"]["result"]["ok"]
            low = await dial(ws, DIAL1, "SET_DIAL_EFFECT", intake, "low")
            assert low["data"]["result"]["result"] == "IGNORED_PRIORITY"  # decoration: refused, nothing else changes
            bad = await dial(ws, DIAL1, "SET_DIAL_EFFECT", {"effect": "CHASE"}, "nodir")
            assert bad["type"] == "nack"  # CHASE needs a direction: refused before it is sent
            # a release ends the PC effect by itself
            assert (await dial(ws, DIAL2, "ARM_RECEIVER", {}, "larm"))["data"]["result"]["ok"]
            assert (await _cmd(ws, "devicehub_mock_ball", {"device": DIAL2}, rid="lball", events=events))["data"]["accepted"]
            assert (await dial(ws, DIAL2, "SET_DIAL_EFFECT", back, "fx3"))["data"]["result"]["ok"]
            assert (await dial(ws, DIAL2, "RELEASE_BALL", {}, "lrel"))["data"]["result"]["ok"]
            assert await _wait_event(ws, events, "RELEASE_DONE", DIAL2, tries=120)
            assert right.led("FRONT")["source"] == "local"
    finally:
        await srv.stop()
    rows = [json.loads(line) for line in trace.read_text(encoding="utf-8").splitlines()]
    fx = [r for r in rows if r["kind"] == "command" and r["command"] == "SET_DIAL_EFFECT"]
    assert fx and fx[0]["effect_id"] == "CHASE" and fx[0]["direction"] == "TO_SCREEN" and fx[0]["source_dial"] == DIAL1
    assert any(r["kind"] == "event" and r["release_state"] == "DONE" and r["source_dial"] == DIAL2 for r in rows)
