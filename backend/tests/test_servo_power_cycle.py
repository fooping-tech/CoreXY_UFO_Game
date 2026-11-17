"""#163: the firmware refuses a servo's jogs until its power is cut and restored
(Core2 restarted while the servo kept power, torque off, its turn count unknown).
The backend keeps that in robot_state so the game can say what to do."""

from __future__ import annotations

import pytest

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import RealRobot
from corexy_ufo_backend.serial_service.service import SerialService

# the lines of 2026-11-17 10:22 (CoreXY_UFO StsServoBus::enableTracking)
REFUSED = ("JOG servo id=1 disabled reason=unknown_turn_count torque=0 moving=0 goal=3945 raw=3889 "
           "(power-cycle servo)")
STILL_STUCK = ("SERVO_STATUS id=1 result=OK flags=0x00 mode=0 torque=0 raw=3889 goal=3945 limits=0/0 "
               "tracking=NO abs=0 turns=0.00 voltage=7.6 temp=24 moving=0")
POWERED_AGAIN = ("SERVO_STATUS id=1 result=OK flags=0x00 mode=0 torque=0 raw=1302 goal=0 limits=0/4095 "
                 "tracking=NO abs=0 turns=0.00 voltage=7.6 temp=20 moving=0")


@pytest.fixture
async def robot():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=122.88, z_sign=1)
    svc = SerialService("fake", transport_factory=FakeFirmware)
    r = RealRobot(cfg, svc)
    await r.connect()
    yield r
    await r.disconnect()


def _data(r: RealRobot) -> dict:
    return r.snapshot().to_message()["data"]


async def test_a_refused_jog_asks_for_a_power_cycle(robot):
    assert _data(robot)["z_servo_power_cycle"] is False
    robot._on_line(REFUSED)
    d = _data(robot)
    assert d["z_servo_power_cycle"] is True and d["arm_servo_power_cycle"] is False
    assert "unknown_turn_count" in d["error"]


async def test_the_claw_and_goal_mismatch_too(robot):
    robot._on_line("JOG servo id=2 disabled reason=goal_mismatch goal=10 raw=900 (power-cycle servo)")
    d = _data(robot)
    assert d["arm_servo_power_cycle"] is True and d["z_servo_power_cycle"] is False


async def test_other_refusals_are_not_a_power_cycle(robot):
    robot._on_line("JOG servo id=1 disabled reason=eeprom_unlocked lock=0")
    robot._on_line("JOG servo id=1 stopped reason=feedback_lost tracking=INVALID")
    assert _data(robot)["z_servo_power_cycle"] is False


async def test_still_stuck_until_the_servo_is_powered_again(robot):
    robot._on_line(REFUSED)
    robot._on_line(STILL_STUCK)
    assert _data(robot)["z_servo_power_cycle"] is True
    robot._on_line(POWERED_AGAIN)  # one turn again: its power was cut and restored
    assert _data(robot)["z_servo_power_cycle"] is False


async def test_an_accepted_jog_clears_it(robot):
    robot._on_line(REFUSED)
    robot._on_line("JOG servo id=1 begin_ms=230 (hold check; XY waits) tracking=NEW")
    assert _data(robot)["z_servo_power_cycle"] is False


async def test_the_other_servos_status_does_not_clear_it(robot):
    robot._on_line(REFUSED)
    robot._on_line(POWERED_AGAIN.replace("id=1", "id=2"))
    assert _data(robot)["z_servo_power_cycle"] is True


async def test_a_lost_link_forgets_it(robot):
    robot._on_line(REFUSED)
    robot.serial._on_transport_lost(OSError("device disconnected"))
    assert robot.servo_power_cycle == set()
