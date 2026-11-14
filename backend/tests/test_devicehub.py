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

ILL, DIAL1 = 0x10, 0x20


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
