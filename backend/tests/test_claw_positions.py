"""Claw open / closed positions: recording, turning there on the right side, saving, grab."""

import asyncio
import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.robot.claw import ClawCalibration
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer


def test_delta_stays_on_the_arc_across_zero_and_comes_back_over_the_nearer_end():
    # closed at 330 deg, opens +60 (through 0) to 30 deg
    c = ClawCalibration(closed_deg=330.0, open_deg=30.0, span_deg=60.0)
    assert c.delta_to("open", 330.0) == pytest.approx(60.0)
    assert c.delta_to("closed", 30.0) == pytest.approx(-60.0)
    assert c.delta_to("open", 10.0) == pytest.approx(20.0)  # mid-way, past 0
    assert c.delta_to("closed", 40.0) == pytest.approx(-70.0)  # a bit beyond open: back over open
    assert c.delta_to("open", 320.0) == pytest.approx(70.0)  # a bit before closed: in over closed
    # the same arc opening the other way: closed 30, opens -60 to 330
    r = ClawCalibration(closed_deg=30.0, open_deg=330.0, span_deg=-60.0)
    assert r.delta_to("open", 30.0) == pytest.approx(-60.0)
    assert r.delta_to("closed", 330.0) == pytest.approx(60.0)


def test_mark_takes_the_span_from_this_sessions_turns_or_keeps_the_old_direction():
    c = ClawCalibration()
    marks: dict[str, int] = {}
    c.mark("closed", 300.0, marks, 4096 + 3413)  # 300 deg, one turn up
    assert not c.complete()
    c.mark("open", 200.0, marks, 4096 + 2276)  # opened by turning back 100 deg
    assert c.span_deg == pytest.approx(-100.0, abs=0.1)
    # later session: only closed re-marked; open stays put, direction kept
    c.mark("closed", 290.0, {}, 3300)
    assert c.span_deg == pytest.approx(-90.0)
    with pytest.raises(ValueError):
        c.mark("half", 0.0, {}, 0)


async def make_real(path=None):
    cfg = BackendConfig()
    cfg.arm_calibration_path = path
    r = RealRobot(cfg, SerialService("fake", transport_factory=FakeFirmware))
    await r.connect()
    return r


async def test_set_open_and_closed_then_turn_there_and_survive_a_power_cycle(tmp_path):
    path = tmp_path / "arm_calibration.json"
    robot = await make_real(path)
    fw = robot.serial.transport
    try:
        with pytest.raises(RobotCommandError, match="not both set"):
            await robot.arm_goto("open")
        await robot.enable_motors(True)
        fw.servo_abs[2] = 3800  # ~334 deg in the turn
        await robot.arm_set("closed")
        await robot.arm_step(60.0)  # opens through 0 deg
        await robot.arm_set("open")
        snap = robot.snapshot()
        assert snap.arm_span_deg == pytest.approx(60.0, abs=0.2)
        assert json.loads(path.read_text())["span_deg"] == pytest.approx(60.0, abs=0.2)
        await robot.arm_goto("closed")
        assert fw.sent[-2].startswith("SERVO_TURN 2 -0.16")  # back the way it opened
        assert fw.servo_abs[2] == pytest.approx(3800, abs=3)
    finally:
        await robot.disconnect()
    # power cycle: the multi-turn count restarts from the angle in the turn
    robot = await make_real(path)
    fw = robot.serial.transport
    try:
        await robot.enable_motors(True)
        fw.servo_abs[2] = 3800 % 4096
        await robot.arm_goto("open")
        assert fw.sent[-2].startswith("SERVO_TURN 2 0.16")  # +60, not -300
    finally:
        await robot.disconnect()


async def test_grab_uses_the_recorded_positions(tmp_path):
    robot = await make_real(tmp_path / "c.json")
    fw = robot.serial.transport
    try:
        await robot.enable_motors(True)
        await robot.home()
        fw.servo_abs[2] = 1000
        await robot.arm_set("open")
        await robot.arm_step(-45.0)
        await robot.arm_set("closed")
        await robot.arm_step(20.0)  # somewhere in between
        await robot.grab(True)
        assert fw.sent[-2].startswith("SERVO_TURN 2 -0.05")  # the 20 deg back to closed
        await robot.grab(False)
        assert fw.sent[-2].startswith("SERVO_TURN 2 0.12")  # 45 deg to open
    finally:
        await robot.disconnect()


async def test_server_arm_set_and_goto_on_the_mock():
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
            await cmd("e", "enable_motors", enable=True)
            assert (await cmd("g0", "arm_goto", which="open"))["type"] == "nack"  # nothing recorded
            await cmd("s1", "arm_set", which="closed")
            await cmd("a", "arm_step", deg=30)
            r = await cmd("s2", "arm_set", which="open")
            assert r["data"]["arm_span_deg"] == 30.0
            r = await cmd("g1", "arm_goto", which="closed")
            assert r["type"] == "ack" and r["data"]["arm_deg"] == 0.0
            assert (await cmd("s3", "arm_set", which="middle"))["type"] == "nack"
    finally:
        await srv.stop()


async def test_a_refused_servo_turn_fails_at_once_not_after_the_timeout(tmp_path):
    robot = await make_real(tmp_path / "c.json")
    fw = robot.serial.transport
    try:
        await robot.enable_motors(True)
        fw.jogging = True  # a jog session the backend does not know about
        t0 = asyncio.get_running_loop().time()
        with pytest.raises(RobotCommandError, match="jog_active"):
            await robot.arm_step(5.0)
        assert asyncio.get_running_loop().time() - t0 < 1.0  # was a 15 s wait, busy all along
        assert not robot._busy
    finally:
        await robot.disconnect()


async def test_claw_right_after_a_z_jog_waits_for_the_ramp_down_then_turns(tmp_path):
    robot = await make_real(tmp_path / "c.json")
    fw = robot.serial.transport
    try:
        await robot.enable_motors(True)
        await robot.jog(0.0, 0.0, 15.0)
        await asyncio.sleep(0.1)
        await robot.jog(0.0, 0.0, 0.0)  # key let go: Z ramps down for a while
        await robot.arm_step(5.0)  # Q / [ pressed meanwhile
        turns = [l for l in fw.sent if l.startswith("SERVO_TURN 2")]
        assert turns == ["SERVO_TURN 2 0.01389"]
        assert fw.sent.index(turns[0]) > max(i for i, l in enumerate(fw.sent) if l.startswith("JOG"))
    finally:
        await robot.disconnect()
