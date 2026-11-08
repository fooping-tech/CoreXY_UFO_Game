"""The drum servo's power cut on its own: detected from SERVO_STATUS, reported,
Z jogs refused, and recovered with a SERVO_TURN the firmware refuses unmoved."""

import asyncio
import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.robot.real_robot import Z_SERVO_RESET_MSG
from corexy_ufo_backend.serial_service import protocol as P
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer

# seen on the real robot (2026-11-08): a jog down did nothing, without an error
REAL_LINE = ("SERVO_STATUS id=1 result=OK flags=0x00 mode=0 torque=1 raw=0 goal=0 limits=0/4095 "
             "tracking=YES abs=0 turns=0.00 voltage=7.6 temp=24 moving=0")


def test_status_line_tells_a_reset_servo():
    st = P.parse_servo_status(REAL_LINE)
    assert st.limits == (0, 4095) and st.tracking and st.multi_turn_lost
    ok = P.parse_servo_status(REAL_LINE.replace("limits=0/4095", "limits=0/0"))
    assert ok.limits == (0, 0) and not ok.multi_turn_lost
    before_first_jog = P.parse_servo_status(REAL_LINE.replace("tracking=YES", "tracking=NO"))
    assert not before_first_jog.multi_turn_lost  # one turn is normal until a jog starts tracking


async def make_robot():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=122.88, z_sign=1)
    r = RealRobot(cfg, SerialService("fake", transport_factory=FakeFirmware))
    await r.connect()
    await r.enable_motors(True)
    return r


async def poll_z(robot):
    robot._last_z_poll = 0.0
    await robot.tick()


async def test_a_cut_servo_is_reported_its_points_forgotten_and_z_jogs_refused():
    robot = await make_robot()
    fw = robot.serial.transport
    try:
        await robot.set_z_point("top")
        fw.cut_servo_power(1)
        await poll_z(robot)
        s = robot.snapshot()
        assert s.z_servo_reset and s.error == Z_SERVO_RESET_MSG
        assert not s.z_reference_set and not s.z_top_set  # the turn count is gone
        with pytest.raises(RobotCommandError, match="Z servo reset"):
            await robot.jog(0, 0, -10)
        with pytest.raises(RobotCommandError, match="Z servo reset"):
            await robot.set_z_point("top")
        await robot.jog(0, 0, 0)  # a stop is always taken
    finally:
        await robot.disconnect()


async def test_recover_lets_the_next_jog_go_past_the_old_turn():
    robot = await make_robot()
    fw = robot.serial.transport
    try:
        fw.cut_servo_power(1)
        await poll_z(robot)
        assert robot.z_servo_reset
        await robot.recover_z_servo()
        turn = [s for s in fw.sent if s.startswith("SERVO_TURN 1")]
        assert turn == ["SERVO_TURN 1 0.01"]  # upwards, refused unmoved by the firmware
        s = robot.snapshot()
        assert not s.z_servo_reset and s.error == "" and fw.servo_abs[1] == 0
        # the next jog re-enables multi-turn: lowering goes below the old turn's end
        for _ in range(5):
            await robot.jog(0, 0, -15)
            await asyncio.sleep(0.01)
        await robot.jog(0, 0, 0)
        assert fw.servo_limits[1] == "0/0" and fw.servo_abs[1] < 0
    finally:
        await robot.disconnect()


async def test_recover_sends_nothing_when_the_servo_is_fine():
    robot = await make_robot()
    fw = robot.serial.transport
    try:
        await robot.recover_z_servo()
        assert not [s for s in fw.sent if s.startswith("SERVO_TURN")]
        assert not robot.z_servo_reset
    finally:
        await robot.disconnect()


async def test_a_reset_seen_at_connect_is_reported():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True))

    class CutFirmware(FakeFirmware):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self.cut_servo_power(1)

    r = RealRobot(cfg, SerialService("fake", transport_factory=CutFirmware))
    await r.connect()
    try:
        assert r.snapshot().z_servo_reset
    finally:
        await r.disconnect()


async def test_server_z_servo_recover_is_a_command():
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"type": "command", "request_id": "r", "data": {"name": "z_servo_recover", "params": {}}}))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 2))
                if m.get("request_id") == "r":
                    assert m["type"] == "ack"
                    break
    finally:
        await srv.stop()
