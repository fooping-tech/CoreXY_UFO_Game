import pytest

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import RealRobot, RobotCommandError
from corexy_ufo_backend.robot.state import MachineState
from corexy_ufo_backend.serial_service.service import SerialService


@pytest.fixture
async def robot():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=122.88, z_sign=1)
    svc = SerialService("fake", transport_factory=FakeFirmware)
    svc._transport_factory = lambda port, baud, **kw: FakeFirmware(port, baud, **kw)
    r = RealRobot(cfg, svc)
    await r.connect()
    yield r
    await r.disconnect()


async def test_motors_disabled_at_start(robot):
    snap = robot.snapshot()
    assert snap.connected and not snap.motors_enabled
    with pytest.raises(RobotCommandError):
        await robot.home()


async def test_home_and_move(robot):
    await robot.enable_motors(True)
    await robot.home()
    assert robot.snapshot().homed
    await robot.move_xy(100, 50)
    s = robot.snapshot()
    assert (s.x, s.y) == (100, 50) and s.measured is False  # z not yet referenced
    assert s.state == MachineState.IDLE


async def test_soft_limits_enforced_host_side(robot):
    await robot.enable_motors(True)
    await robot.home()
    with pytest.raises(RobotCommandError):
        await robot.move_xy(500, 50)
    assert "XY 500" not in " ".join(robot.serial.transport.sent)


async def test_firmware_nack_surfaces(robot):
    await robot.enable_motors(True)
    await robot.home()
    robot.serial.transport.reject_next_xy = True
    with pytest.raises(RobotCommandError):
        await robot.move_xy(10, 10)
    assert "NACK_XY" in robot.snapshot().error


async def test_z_requires_reference_then_chunks(robot):
    await robot.enable_motors(True)
    await robot.home()
    with pytest.raises(RobotCommandError):
        await robot.move_z(50)
    await robot.set_z_zero()
    assert robot.snapshot().z == 100.0  # top
    await robot.move_z(0.0)  # arm all the way down: 100 units = 12288 counts = 3 turns
    sent = [l for l in robot.serial.transport.sent if l.startswith("SERVO_TURN 1")]
    assert sent == ["SERVO_TURN 1 -3.00"]
    assert abs(robot.snapshot().z - 0.0) < 0.01
    assert "TEST_MODE ON" in robot.serial.transport.sent
    await robot.move_z(100.0)
    sent = [l for l in robot.serial.transport.sent if l.startswith("SERVO_TURN 1")]
    assert sent[-1] == "SERVO_TURN 1 3.00"
    assert abs(robot.snapshot().z - 100.0) < 0.01


async def test_z_chunking_over_three_turns():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0), z_counts_per_unit=200.0)  # 100 units = ~4.9 turns
    svc = SerialService("fake", transport_factory=FakeFirmware)
    r = RealRobot(cfg, svc)
    await r.connect()
    await r.enable_motors(True)
    await r.home()
    await r.set_z_zero()
    await r.move_z(0.0)
    sent = [l for l in svc.transport.sent if l.startswith("SERVO_TURN 1")]
    assert len(sent) == 2 and sent[0] == "SERVO_TURN 1 -3.00"
    assert abs(r.snapshot().z) < 0.5
    await r.disconnect()


async def _z_robot(reports: bool, fw_max: float):
    """A robot whose Z range is ~4.9 turns (100 units x 200 counts), on a firmware that
    takes fw_max turns per SERVO_TURN (and says so in CONFIG when reports)."""
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0), z_counts_per_unit=200.0)
    svc = SerialService("fake", transport_factory=FakeFirmware)
    r = RealRobot(cfg, svc)
    orig_open = FakeFirmware.open

    async def open_with(self):
        self.reports_max_turns = reports
        self.max_turns = {1: fw_max, 2: 3.0}
        await orig_open(self)
    FakeFirmware.open = open_with
    try:
        await r.connect()
    finally:
        FakeFirmware.open = orig_open
    return r, svc


async def test_z_moves_in_one_turn_command_when_the_firmware_takes_six():
    # #248: the firmware says 6 turns for the drum: the whole range in one SERVO_TURN (no seam stop)
    r, svc = await _z_robot(True, 6.0)
    assert "CONFIG" in svc.transport.sent and r.z_max_turns == 6.0
    await r.enable_motors(True)
    await r.home()
    await r.set_z_zero()
    await r.move_z(0.0)
    sent = [l for l in svc.transport.sent if l.startswith("SERVO_TURN 1")]
    assert len(sent) == 1 and sent[0] == "SERVO_TURN 1 -4.88281"
    assert abs(r.snapshot().z) < 0.5
    await r.disconnect()


async def test_z_keeps_three_turns_on_older_firmware():
    # no SERVO_LIMITS line in CONFIG: 3 turns as before
    r, svc = await _z_robot(False, 3.0)
    assert "CONFIG" in svc.transport.sent and r.z_max_turns == 3.0
    await r.disconnect()


async def test_z_refused_over_the_limit_goes_on_in_smaller_steps():
    # the backend thinks 6 but the firmware takes 3 (reflashed): refused unmoved, then 3 + rest
    r, svc = await _z_robot(False, 3.0)
    r.z_max_turns = 6.0
    await r.enable_motors(True)
    await r.home()
    await r.set_z_zero()
    await r.move_z(0.0)
    sent = [l for l in svc.transport.sent if l.startswith("SERVO_TURN 1")]
    assert sent == ["SERVO_TURN 1 -4.88281", "SERVO_TURN 1 -3.00", "SERVO_TURN 1 -1.88281"]
    assert r.z_max_turns == 3.0 and abs(r.snapshot().z) < 0.5 and "turns_over" not in r.snapshot().error
    await r.disconnect()


async def test_stop_sets_alarm_and_clear(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.stop()
    s = robot.snapshot()
    assert s.alarm and not s.homed
    with pytest.raises(RobotCommandError):
        await robot.move_xy(1, 1)
    await robot.clear_alarm()
    assert not robot.snapshot().alarm
    with pytest.raises(RobotCommandError):  # still needs homing after ABORT
        await robot.move_xy(1, 1)


async def test_grab(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.grab(True)
    assert robot.serial.transport.sent[-2:] == ["SERVO_TURN 2 0.50", "SERVO_STATUS 2"]  # then re-read the claw
    await robot.grab(False)
    assert robot.serial.transport.sent[-2:] == ["SERVO_TURN 2 -0.50", "SERVO_STATUS 2"]
