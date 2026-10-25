"""Z (drum servo) follows the real arm: joystick / other tools, JOG_POS Z_ABS, W/S jog."""

import asyncio
import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.serial_service import protocol as P
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer


def test_protocol_z_fields():
    assert P.cmd_jog(0, 0, 1229) == "JOG 0.0 0.0 1229 0"
    assert P.cmd_jog(10, 0) == "JOG 10.0 0.0"
    assert P.z_abs_from("JOG_POS X=1.000 Y=2.000 VX=0.0 VY=0.0 Z_ABS=4731 ARM_ABS=NA") == 4731
    assert P.z_abs_from("JOG_POS X=1.000 Y=2.000 VX=0.0 VY=0.0 Z_ABS=NA ARM_ABS=NA") is None


async def make_robot(z_sign=1):
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=122.88, z_sign=z_sign)
    r = RealRobot(cfg, SerialService("fake", transport_factory=FakeFirmware))
    await r.connect()
    return r


async def poll_z(robot):
    robot._last_z_poll = 0.0  # due now
    await robot.tick()


async def test_arm_moved_elsewhere_is_picked_up_by_polling():
    robot = await make_robot()
    try:
        await robot.set_z_zero()  # arm at the top -> z = 100
        assert robot.snapshot().z == 100.0
        robot.serial.transport.servo_abs[1] -= int(1.5 * 4096)  # joystick lowers the arm 1.5 turns
        await poll_z(robot)
        s = robot.snapshot()
        assert s.z == pytest.approx(50.0, abs=0.01) and s.z_reference_set
    finally:
        await robot.disconnect()


async def test_without_reference_z_stays_put_but_counts_are_tracked():
    robot = await make_robot()
    try:
        robot.serial.transport.servo_abs[1] += 777
        await poll_z(robot)
        s = robot.snapshot()
        assert s.z == 100.0 and not s.z_reference_set and robot._z_counts == 1777
    finally:
        await robot.disconnect()


async def test_z_jog_works_unhomed_and_is_capped():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)  # not homed
        await robot.jog(0, 0, -10)
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0 -1229 0"
        await robot.jog(0, 0, -100)  # 12288 counts/s requested, servo max 2400
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0 -2400 0"
        with pytest.raises(RobotCommandError, match="not homed"):
            await robot.jog(10, 0, 0)  # XY still needs homing
        await robot.jog(0, 0, 0)
    finally:
        await robot.disconnect()


async def test_z_jog_direction_follows_z_sign():
    robot = await make_robot(z_sign=-1)
    try:
        await robot.enable_motors(True)
        await robot.jog(0, 0, 10)  # up: with z_sign -1 the servo turns negative
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0 -1229 0"
        await robot.jog(0, 0, 0)
    finally:
        await robot.disconnect()


async def test_z_jog_stays_inside_the_range_once_referenced():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.set_z_zero()  # z = 100 = top
        await robot.jog(0, 0, 10)  # further up: nothing to send but a stop
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0"
        await robot.jog(0, 0, -10)  # down is fine
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0 -1229 0"
        await robot.jog(0, 0, 0)
    finally:
        await robot.disconnect()


async def test_jog_pos_z_abs_updates_z_during_a_jog():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.set_z_zero()
        for _ in range(6):
            await robot.jog(0, 0, -20)  # 2458 -> capped 2400 counts/s, firmware reports Z_ABS
            await asyncio.sleep(0.01)
        await asyncio.sleep(0.02)
        z = robot.snapshot().z
        assert z < 100.0 and robot.snapshot().measured is not None
        assert z == pytest.approx(100.0 - (robot._z_zero_counts - robot._z_counts) / 122.88, abs=1e-6)
        await robot.jog(0, 0, 0)
    finally:
        await robot.disconnect()


async def test_mock_z_jog(monkeypatch):
    from corexy_ufo_backend.robot import mock_robot as mock_module
    clock = [1000.0]
    monkeypatch.setattr(mock_module.time, "monotonic", lambda: clock[0])
    r = MockRobot()
    await r.connect()
    await r.enable_motors(True)  # not homed: Z alone still jogs
    z0 = r.pos[2]
    for _ in range(50):
        clock[0] += 0.02
        await r.jog(0, 0, -20.0)
        await r.tick()
    assert z0 - r.pos[2] > 10
    await r.jog(0, 0, 0)
    for _ in range(50):
        clock[0] += 0.02
        await r.tick()
    assert r.vel[2] == 0.0 and r.limits.z_min <= r.pos[2] <= r.limits.z_max


async def test_server_passes_vz():
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
                    m = json.loads(await asyncio.wait_for(ws.recv(), 2))
                    if m.get("request_id") == rid:
                        return m
            await cmd("e", "enable_motors", enable=True)
            assert (await cmd("z", "jog", vx=0, vy=0, vz=-15))["type"] == "ack"
            assert robot._jog_cap[2] == 15.0
            assert (await cmd("z0", "jog", vx=0, vy=0, vz=0))["type"] == "ack"
    finally:
        await srv.stop()


# ------------------------------------------------------------------ release ramp
def z_rates(robot):
    """Z counts/s of every JOG line sent so far (0 for `JOG vx vy` and plain stops)."""
    out = []
    for line in robot.serial.transport.sent:
        if line.startswith("JOG "):
            parts = line.split()
            out.append(int(parts[3]) if len(parts) > 3 else 0)
    return out


async def test_release_ramps_z_down_before_stopping():
    # The firmware holds the last READ servo position when the rate drops to 0; at
    # speed that read lags and the drum swings back. Ramp down instead.
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.jog(0, 0, -15)  # -1843 counts/s
        await robot.jog(0, 0, 0)    # all keys released
        await asyncio.sleep(0.5)
        rates = z_rates(robot)
        ramp = rates[1:]
        assert rates[0] == -1843 and ramp[-1] == 0 and len(ramp) >= 4
        assert all(-1843 <= r < 0 for r in ramp[:-1]) and ramp[-2] > -150, ramp  # very slow at the end
        assert all(abs(a) >= abs(b) for a, b in zip(ramp, ramp[1:])), ramp  # never speeds up
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0"
    finally:
        await robot.disconnect()


async def test_new_press_or_stop_cancels_the_ramp():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.jog(0, 0, -15)
        await robot.jog(0, 0, 0)
        await robot.jog(0, 0, 15)  # pressed again (W) during the ramp
        n = len(robot.serial.transport.sent)
        await asyncio.sleep(0.15)
        assert len(robot.serial.transport.sent) == n  # the old ramp wrote nothing more
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0 1843 0"
        await robot.jog(0, 0, 0)
        await robot.soft_stop()  # Space during the ramp
        n = len(robot.serial.transport.sent)
        await asyncio.sleep(0.5)
        assert len(robot.serial.transport.sent) == n and robot.serial.transport.sent[-1] == "STOP"
    finally:
        await robot.disconnect()


async def test_no_ramp_at_the_end_of_the_range():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.set_z_zero()  # z = 100
        robot._z_units_est = 99.0
        await robot.jog(0, 0, 15)
        robot._z_units_est = 100.0  # reached the top
        await robot.jog(0, 0, 15)   # still held: stop at once, no coasting past the end
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0"
        await asyncio.sleep(0.15)
        assert robot.serial.transport.sent[-1] == "JOG 0.0 0.0"
    finally:
        await robot.disconnect()


async def test_releasing_only_w_s_ramps_z_within_the_refreshes():
    robot = await make_robot()
    try:
        await robot.enable_motors(True)
        await robot.home()
        await robot.jog(20, 0, -15)
        for _ in range(9):  # arrow still held, W/S released
            await asyncio.sleep(0.05)
            await robot.jog(20, 0, 0)
        rates = z_rates(robot)
        assert rates[0] == -1843 and rates[-1] == 0 and any(-1843 < r < 0 for r in rates), rates
        assert all(abs(a) >= abs(b) for a, b in zip(rates, rates[1:])), rates
        await robot.jog(0, 0, 0)
    finally:
        await robot.disconnect()
