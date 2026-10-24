"""Serial JOG / non-alarm STOP (firmware a49bc54, CoreXY_UFO docs/handoff/REPLY_FIRMWARE_JOG.md)."""

import asyncio
import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.robot.state import MachineState
from corexy_ufo_backend.serial_service import protocol as P
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer


# ------------------------------------------------------------------ protocol
def test_protocol_lines():
    assert P.cmd_jog(50, 0) == "JOG 50.0 0.0"
    assert P.cmd_jog(-12.345, 3) == "JOG -12.3 3.0"
    cases = {
        "JOG start vx=50.0 vy=0.0 z=0 arm=0 src=SERIAL HOMED=YES": "jog_start",
        "JOG_POS X=123.456 Y=100.000 VX=50.0 VY=0.0 Z_ABS=4731 ARM_ABS=NA": "jog_pos",
        "JOG end reason=zero X=200.123 Y=100.000 HOMED=YES src=SERIAL": "jog_end",
        "JOG soft_limit axis=X X=389.525": "jog_soft_limit",
        "NACK_JOG reason=not_homed": "jog_rejected",
        "STOP complete X=187.250 Y=100.000 HOMED=YES": "stop_done",
    }
    for line, kind in cases.items():
        assert P.classify_line(line) == kind, line
    assert P.xy_from("JOG_POS X=123.456 Y=100.000 VX=50.0") == (123.456, 100.0)
    assert P.xy_from("NACK_XY target=(20.000,100.000) reason=stopped X=187.250 Y=100.000") == (187.25, 100.0)
    assert P.xy_from("JOG soft_limit axis=X X=389.525") is None
    assert P.is_failure_line("NACK_XY target=(1.000,2.000) reason=jog_active")


# ------------------------------------------------------------------ RealRobot + FakeFirmware
@pytest.fixture
async def robot():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True))
    svc = SerialService("fake", transport_factory=FakeFirmware)
    r = RealRobot(cfg, svc)
    await r.connect()
    yield r
    await r.disconnect()


def fw(robot) -> FakeFirmware:
    return robot.serial.transport


async def settle():
    await asyncio.sleep(0.02)


async def test_jog_needs_arming_and_homing(robot):
    with pytest.raises(RobotCommandError, match="motors not enabled"):
        await robot.jog(30, 0)
    await robot.enable_motors(True)
    with pytest.raises(RobotCommandError, match="not homed"):
        await robot.jog(30, 0)
    assert not [l for l in fw(robot).sent if l.startswith("JOG ")]


async def test_jog_session_updates_position_and_state(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.move_xy(100, 50)
    await robot.jog(40, 0)
    await settle()
    assert robot.snapshot().state == MachineState.MOVING_XY
    for _ in range(5):  # refreshes: firmware stays silent except JOG_POS
        await robot.jog(40, 0)
    await settle()
    s = robot.snapshot()
    assert s.x == pytest.approx(110.0) and s.y == pytest.approx(50.0)
    await robot.jog(0, 0)
    await settle()
    s = robot.snapshot()
    assert s.state == MachineState.IDLE and s.homed and not s.alarm
    assert fw(robot).sent[-1] == "JOG 0.0 0.0"


async def test_jog_speed_is_capped(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.jog(300, 400)  # 500 mm/s requested, cap 50 mm/s keeps the direction
    assert fw(robot).sent[-1] == "JOG 30.0 40.0"


async def test_firmware_rejection_is_reported_once(robot):
    await robot.enable_motors(True)
    await robot.home()
    fw(robot).homed = False  # firmware lost homing (e.g. after ABORT elsewhere)
    await robot.jog(30, 0)
    await robot.jog(30, 0)
    await settle()
    assert robot.snapshot().error == "jog rejected: not_homed"
    lines = [l for l in fw(robot).sent if l.startswith("JOG")]
    assert lines == ["JOG 30.0 0.0", "JOG 30.0 0.0"]


async def test_jog_refused_while_xy_move_runs(robot):
    await robot.enable_motors(True)
    await robot.home()
    fw(robot).move_delay = 0.3
    move = asyncio.create_task(robot.move_xy(200, 100))
    await settle()
    with pytest.raises(RobotCommandError, match="busy"):
        await robot.jog(30, 0)
    await move


async def test_xy_refused_while_jogging(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.jog(30, 0)
    await settle()
    with pytest.raises(RobotCommandError, match="jog_active"):
        await robot.move_xy(10, 10)
    await robot.jog(0, 0)


async def test_soft_stop_interrupts_xy_move_without_alarm(robot):
    await robot.enable_motors(True)
    await robot.home()
    fw(robot).move_delay = 2.0
    move = asyncio.create_task(robot.move_xy(200, 100))
    await asyncio.sleep(0.05)
    await asyncio.wait_for(robot.soft_stop(), 1.0)  # not blocked by the move holding the serial lock
    with pytest.raises(RobotCommandError, match="stopped"):
        await asyncio.wait_for(move, 1.0)
    s = robot.snapshot()
    assert (s.x, s.y) == (100.0, 50.0)  # where the firmware says it stopped
    assert s.homed and not s.alarm and s.state == MachineState.IDLE
    assert "stopped" not in s.error  # stopping on purpose is not an error
    await robot.move_xy(10, 10)  # next move works right away


async def test_soft_stop_ends_a_jog(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.jog(30, 0)
    await settle()
    await robot.soft_stop()
    assert robot.snapshot().state == MachineState.IDLE and not fw(robot).jogging


async def test_disarming_ends_a_jog(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.jog(30, 0)
    await settle()
    await robot.enable_motors(False)
    await settle()
    assert not fw(robot).jogging


# ------------------------------------------------------------------ MockRobot
async def test_mock_jog_moves_stops_and_respects_limits(monkeypatch):
    from corexy_ufo_backend.robot import mock_robot as mock_module
    clock = [1000.0]
    monkeypatch.setattr(mock_module.time, "monotonic", lambda: clock[0])
    r = MockRobot()
    await r.connect()
    await r.enable_motors(True)
    r.homed = True
    x0 = r.pos[0]

    async def run(seconds, refresh=None):
        for _ in range(int(seconds * 50)):
            clock[0] += 0.02
            if refresh:
                await r.jog(*refresh)
            await r.tick()

    await run(1.0, refresh=(40.0, 0.0))  # held for 1 s at 40 mm/s
    assert 30 < r.pos[0] - x0 < 41 and r.vel[0] == pytest.approx(40.0)
    x_release = r.pos[0]
    await run(1.0)  # refreshes stop: dead-man keeps going 250 ms, then decelerates
    assert r.vel[0] == 0.0 and r.pos[0] - x_release <= 40 * 0.25 + 1.0
    await run(0.5, refresh=(40.0, 0.0))
    x_release = r.pos[0]
    await r.jog(0, 0)  # key released: explicit zero stops at once (braking distance only)
    await run(0.5)
    assert r.vel[0] == 0.0 and r.pos[0] - x_release <= 1.0
    await run(10.0, refresh=(50.0, 50.0))  # hold toward the far corner
    assert r.pos[0] <= r.limits.x_max and r.pos[1] <= r.limits.y_max
    await r.jog(0, 0)
    await run(0.5)
    assert r.vel[:2] == [0.0, 0.0]


async def test_mock_soft_stop_decelerates(monkeypatch):
    from corexy_ufo_backend.robot import mock_robot as mock_module
    clock = [1000.0]
    monkeypatch.setattr(mock_module.time, "monotonic", lambda: clock[0])
    r = MockRobot()
    await r.connect()
    await r.enable_motors(True)
    r.homed = True
    await r.move_xy(r.limits.x_max, r.pos[1])
    for _ in range(20):
        clock[0] += 0.02
        await r.tick()
    v = r.vel[0]
    await r.soft_stop()
    for _ in range(100):
        clock[0] += 0.02
        await r.tick()
    assert v > 0 and r.vel[0] == 0.0 and r.pos[0] < r.limits.x_max and not r.alarm and r.homed


# ------------------------------------------------------------------ WebSocket server
@pytest.fixture
async def server():
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=50)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    yield srv, robot, port
    await srv.stop()


async def _cmd(ws, rid, name, **params):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), 2))
        if msg["type"] in ("ack", "nack") and msg.get("request_id") == rid:
            return msg


async def test_server_jog_and_soft_stop(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        assert (await _cmd(ws, "j0", "jog", vx=30, vy=0))["type"] == "nack"  # not armed
        await _cmd(ws, "e1", "enable_motors", enable=True)
        await _cmd(ws, "h1", "home")
        assert (await _cmd(ws, "j1", "jog", vx=30, vy=0))["type"] == "ack"
        assert (await _cmd(ws, "j2", "jog", vx=0, vy=0))["type"] == "ack"
        # a move holding the motion lock: jog is refused, soft_stop still goes through
        async with srv._motion_lock:
            assert (await _cmd(ws, "j3", "jog", vx=30, vy=0))["data"]["reason"].startswith("busy")
            assert (await _cmd(ws, "s1", "soft_stop"))["type"] == "ack"
            assert (await _cmd(ws, "j4", "jog", vx=0, vy=0))["type"] == "ack"  # release always allowed


# ------------------------------------------------------------------ server ordering / responsiveness
class SlowRobot(MockRobot):
    """move_xy that takes a while (like the real robot waiting for ACK_XY) and a slow tick."""

    def __init__(self, move_s: float = 1.0, tick_s: float = 0.0) -> None:
        super().__init__()
        self.move_s, self.tick_s = move_s, tick_s
        self.stopped_during_move = None

    async def move_xy(self, x, y, feed=None):
        self._require()
        self.moving = True
        try:
            await asyncio.sleep(self.move_s)
        finally:
            self.moving = False

    async def soft_stop(self):
        self.stopped_during_move = getattr(self, "moving", False)
        await super().soft_stop()

    async def tick(self):
        if self.tick_s:
            await asyncio.sleep(self.tick_s)  # a POS round trip on the real robot
        await super().tick()


async def _start(robot):
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def test_stop_is_not_queued_behind_a_running_move():
    # The same connection sends move_xy and then stop: stop must not wait for the move.
    robot = SlowRobot(move_s=1.5)
    srv, port = await _start(robot)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _cmd(ws, "e", "enable_motors", enable=True)
            await _cmd(ws, "h", "home")
            await ws.send(json.dumps({"type": "command", "request_id": "m", "data": {"name": "move_xy", "params": {"x": 10, "y": 10}}}))
            await asyncio.sleep(0.1)
            loop = asyncio.get_running_loop()
            t0 = loop.time()
            assert (await _cmd(ws, "s", "soft_stop"))["type"] == "ack"
            assert (await _cmd(ws, "j", "jog", vx=0, vy=0))["type"] == "ack"
            assert (await _cmd(ws, "g", "get_state"))["type"] == "ack"
            assert (await _cmd(ws, "x", "stop"))["type"] == "ack"
            assert loop.time() - t0 < 0.5 and robot.stopped_during_move
    finally:
        await srv.stop()


async def test_ordinary_commands_keep_their_order():
    robot = SlowRobot(move_s=0.0)
    srv, port = await _start(robot)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            # sent back to back: enable_motors must run before home and move_xy
            for rid, name, params in [("e", "enable_motors", {"enable": True}), ("h", "home", {}), ("m", "move_xy", {"x": 5, "y": 5})]:
                await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
            got = {}
            while len(got) < 3:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 2))
                if msg["type"] in ("ack", "nack"):
                    got[msg["request_id"]] = msg["type"]
            assert got == {"e": "ack", "h": "ack", "m": "ack"}
    finally:
        await srv.stop()


async def test_state_stream_does_not_wait_for_slow_polls():
    robot = SlowRobot(tick_s=0.1)  # 100 ms per poll would cap a coupled loop at 10 Hz
    srv, port = await _start(robot)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            n, loop = 0, asyncio.get_running_loop()
            end = loop.time() + 1.0
            while loop.time() < end:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 1))
                n += msg["type"] == "robot_state"
            assert n >= 22, n  # ~30 Hz
    finally:
        await srv.stop()
