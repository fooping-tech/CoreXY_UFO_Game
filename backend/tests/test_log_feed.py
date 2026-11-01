"""The server forwards the backend log and the serial traffic to the clients as `log` messages."""

import asyncio
import json

import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig
from corexy_ufo_backend.robot import RealRobot
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer


async def test_serial_lines_and_backend_log_reach_the_client():
    robot = RealRobot(BackendConfig(), SerialService("fake", transport_factory=FakeFirmware))
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"type": "command", "request_id": "e", "data": {"name": "enable_motors", "params": {"enable": True}}}))
            await ws.send(json.dumps({"type": "command", "request_id": "j", "data": {"name": "jog", "params": {"vx": 0, "vy": 0, "vz": 10}}}))
            await ws.send(json.dumps({"type": "command", "request_id": "j2", "data": {"name": "jog", "params": {"vx": 0, "vy": 0, "vz": 10}}}))
            lines = []
            loop = asyncio.get_running_loop()
            end = loop.time() + 1.5
            while loop.time() < end:
                try:
                    m = json.loads(await asyncio.wait_for(ws.recv(), end - loop.time()))
                except TimeoutError:
                    break
                if m["type"] == "log":
                    lines.append(m["data"]["line"])
        assert any(l.startswith("[backend] WARNING jog refresh expired") for l in lines), lines
        assert any(l.startswith("[serial] TX ") for l in lines), lines
        jogs = [l for l in lines if l.startswith("[serial] TX JOG ")]
        assert jogs and jogs.count(jogs[0]) == 1, lines  # the same JOG resent is shown once
        assert not any(l.startswith(("[serial] TX POS", "[serial] RX POS ")) for l in lines)
    finally:
        await srv.stop()
        await robot.disconnect()
