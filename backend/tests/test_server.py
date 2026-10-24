import asyncio
import json

import pytest
import websockets

from corexy_ufo_backend.robot import MockRobot
from corexy_ufo_backend.websocket import GameServer


@pytest.fixture
async def server():
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=50)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    yield srv, robot, port
    await srv.stop()


async def _recv_type(ws, t, timeout=2.0):
    end = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < end:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        if msg["type"] == t:
            return msg
    raise AssertionError(f"no {t}")


async def _cmd(ws, rid, name, **params):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), 2))
        if msg["type"] in ("ack", "nack") and msg.get("request_id") == rid:
            return msg


async def test_hello_and_state_stream(server):
    _, _, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        hello = await _recv_type(ws, "hello")
        assert "move_xy" in hello["data"]["commands"]
        st = await _recv_type(ws, "robot_state")
        assert st["data"]["connected"] and not st["data"]["motors_enabled"]
        assert "timestamp" in st


async def test_motion_refused_until_enabled(server):
    _, _, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        r = await _cmd(ws, "r1", "move_xy", x=10, y=10)
        assert r["type"] == "nack" and "not enabled" in r["data"]["reason"]
        r = await _cmd(ws, "r2", "enable_motors", enable=True)
        assert r["type"] == "ack"
        r = await _cmd(ws, "r3", "move_xy", x=10, y=10)
        assert r["type"] == "nack" and "not homed" in r["data"]["reason"]
        r = await _cmd(ws, "r4", "home")
        assert r["type"] == "ack" and r["data"]["homed"]
        r = await _cmd(ws, "r5", "move_xy", x=10, y=10)
        assert r["type"] == "ack"


async def test_duplicate_request_id_not_reexecuted(server):
    _, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _cmd(ws, "a", "enable_motors", enable=True)
        await _cmd(ws, "b", "home")
        r1 = await _cmd(ws, "dup", "move_xy", x=50, y=60)
        robot.target[0] = 999.0  # if re-executed, target would be reset to 50
        r2 = await _cmd(ws, "dup", "move_xy", x=50, y=60)
        assert r1["type"] == "ack" and r2["type"] == "ack" and r2.get("duplicate") is True
        assert robot.target[0] == 999.0


async def test_bad_params_and_unknown(server):
    _, _, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        r = await _cmd(ws, "x", "move_xy", x="nope", y=1)
        assert r["type"] == "nack" and "bad params" in r["data"]["reason"]
        r = await _cmd(ws, "y", "launch_missiles")
        assert r["type"] == "nack"


async def test_stop_always_allowed_and_limits(server):
    _, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _cmd(ws, "1", "enable_motors", enable=True)
        await _cmd(ws, "2", "home")
        r = await _cmd(ws, "3", "move_xy", x=10000, y=0)
        assert r["type"] == "nack" and "soft limits" in r["data"]["reason"]
        r = await _cmd(ws, "4", "stop")
        assert r["type"] == "ack" and r["data"]["alarm"]
        st = await _recv_type(ws, "robot_state")
        assert st["data"]["state"] == "ALARM"


async def test_mock_robot_settles_on_target(monkeypatch):
    # The discrete axis controller used to overshoot and hunt around the
    # target forever (+-0.1 mm), so the position chattered and the state never
    # went back to IDLE.
    from corexy_ufo_backend.robot import mock_robot as mock_module

    clock = [1000.0]
    monkeypatch.setattr(mock_module.time, "monotonic", lambda: clock[0])
    robot = MockRobot()
    await robot.connect()
    await robot.enable_motors(True)
    robot.homed = True
    await robot.move_xy(40.0, 20.0)
    trace = []
    for _ in range(300):  # 10 s at 30 Hz
        clock[0] += 1.0 / 30.0
        await robot.tick()
        trace.append(robot.pos[0])
    assert robot.pos[0] == 40.0 and robot.pos[1] == 20.0
    assert robot.vel[0] == 0.0 and robot.vel[1] == 0.0
    # monotone approach: no overshoot past the target on the way in
    assert min(trace) >= 40.0
    assert robot.snapshot().state.value == "IDLE"
