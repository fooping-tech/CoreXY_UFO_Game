"""Claw (servo ID 2) manual steps: arm_step / arm_zero on the real robot, the mock and the server."""

import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer


async def make_real():
    r = RealRobot(BackendConfig(), SerialService("fake", transport_factory=FakeFirmware))
    await r.connect()
    return r


async def test_arm_step_turns_servo_2_relatively_with_fine_resolution():
    robot = await make_real()
    try:
        with pytest.raises(RobotCommandError, match="motors not enabled"):
            await robot.arm_step(5)
        await robot.enable_motors(True)  # not homed: a servo needs no XY homing
        await robot.arm_step(1.0)
        sent = [l for l in robot.serial.transport.sent if l.startswith(("TEST_MODE", "SERVO_TURN 2"))]
        assert sent == ["TEST_MODE ON", "SERVO_TURN 2 0.00278"]  # 1 degree, not "0.00"
        await robot.arm_zero()
        assert robot.snapshot().arm_deg == 0.0 and robot.snapshot().arm_reference_set
        await robot.arm_step(-10.0)
        await robot.arm_step(-10.0)
        assert robot.snapshot().arm_deg == pytest.approx(-20.0, abs=0.2)
        assert robot.serial.transport.sent[-2] == "SERVO_TURN 2 -0.02778"
        with pytest.raises(RobotCommandError, match="90"):
            await robot.arm_step(120)  # one step at most 90 degrees
    finally:
        await robot.disconnect()


async def test_arm_angle_before_a_reference_is_the_raw_angle_in_the_turn():
    robot = await make_real()
    try:
        robot.serial.transport.servo_abs[2] = 4096 * 2 + 1024  # two turns and a quarter
        await robot.arm_zero()
        robot._arm_zero_counts = None
        assert robot.snapshot().arm_deg == pytest.approx(90.0)
        assert not robot.snapshot().arm_reference_set
    finally:
        await robot.disconnect()


async def test_mock_claw_and_the_server_commands():
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            async def cmd(rid, name, **params):
                await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
                while True:
                    m = json.loads(await ws.recv())
                    if m.get("request_id") == rid:
                        return m
            assert (await cmd("a0", "arm_step", deg=5))["type"] == "nack"  # motors off
            await cmd("e", "enable_motors", enable=True)
            r = await cmd("a1", "arm_step", deg=5)
            assert r["type"] == "ack" and r["data"]["arm_deg"] == 5.0
            r = await cmd("a2", "arm_step", deg=-2.5)
            assert r["data"]["arm_deg"] == 2.5
            assert (await cmd("z", "arm_zero"))["data"]["arm_deg"] == 0.0
            assert (await cmd("a3", "arm_step", deg=200))["type"] == "nack"
            assert (await cmd("a4", "arm_step"))["type"] == "nack"  # no deg
    finally:
        await srv.stop()
