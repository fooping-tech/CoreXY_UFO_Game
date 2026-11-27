"""#348: every way the servo bus (the drum servo id=1 and the claw servo id=2 share it) fails
for a while, as CoreXY_UFO's StsServoBus words it, and what the backend does with it. The bus
comes back by itself after a few seconds (seen after XY moves), so none of these may stop the
game; a servo that really lost power (one-turn limits) or whose count the firmware cannot take
back still stops as before.

  firmware answer                                          | what nothing / something did      | here
  ---------------------------------------------------------+-----------------------------------+------------------------
  SERVO_STATUS result=NO_REPLY                             | read only                         | ServoNoReply, retried
  SERVO_TURN REJECTED reason=no_reply / read_failed /      | refused before anything turned    | ServoNoReply, retried
    not_position_mode mode=-1 / eeprom_unlocked lock=-1    |                                   |
  SERVO_TURN REJECTED reason=multi_turn_lost (retry)       | power cut OR limits not read      | status asked: one-turn = power
                                                           | (the same answer); count dropped  | cut (as before), else retried
  SERVO_TURN FAILED reason=feedback_lost / goal_write_     | it may have turned to its goal    | ServoPositionUnknown: the count
    failed / hold_write_failed, REJECTED reason=idle_drift | unheard; count dropped            | taken back (nudge), retried
  SERVO_STATUS limits=-1/-1 (and other -1 fields)          | some registers not read           | not a power cut (#346)
  ... recover=multi_turn_lost, runaway, hold_check_moved,  | a real servo fault                | ServoFailed as before
    unknown_turn_count, goal_mismatch, TIMEOUT torque=ON   |                                   |
"""

from __future__ import annotations

import asyncio

import pytest

from corexy_ufo_backend.config import RobotLimits
from corexy_ufo_backend.homework.approach import ApproachPhase, ApproachSequencer, HomeworkSpot
from corexy_ufo_backend.robot.interface import (RobotCommandError, ServoFailed, ServoNoReply, ServoPositionUnknown,
                                                is_servo_no_reply, is_servo_position_unknown, servo_bus_error)
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.sequence.prepare import PrepareSequencer

from test_camera_map import wait_phase
from test_claw_positions import _claw_ready
from test_easy_mode import EasyRig
from test_homework_advice import ready_robot
from test_z_servo_reset import make_robot, poll_z

# ------------------------------------------------------------------ the firmware's words
UNMOVED = [
    "SERVO_STATUS id=1 result=NO_REPLY tracking=YES",
    "SERVO_TURN id=1 value=-0.65 result=REJECTED reason=no_reply",
    "SERVO_TURN id=2 value=0.10 result=REJECTED reason=read_failed",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=not_position_mode mode=-1",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=eeprom_unlocked lock=-1",
]
POSITION_UNKNOWN = [
    "SERVO_TURN id=2 value=0.14 result=FAILED target=2432 reason=feedback_lost tracking=INVALID recover=no_reply "
    "raw=-1 goal=0 moving=-1",
    "SERVO_TURN id=2 value=0.14 result=FAILED target=2432 reason=feedback_lost tracking=INVALID recover=still_moving "
    "raw=2400 goal=2432 moving=1",
    "SERVO_TURN id=1 value=0.50 result=FAILED reason=goal_write_failed",
    "SERVO_TURN id=1 value=0.50 result=FAILED reason=hold_write_failed",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=idle_drift drift=+300 tracking=INVALID (power-cycle servo)",
]
REAL_FAULTS = [
    "SERVO_TURN id=1 value=0.50 result=FAILED target=9 reason=feedback_lost tracking=INVALID recover=multi_turn_lost "
    "raw=9 goal=0 moving=0",
    "SERVO_TURN id=1 value=0.50 result=FAILED target=9 actual=900 reason=runaway torque=OFF tracking=INVALID",
    "SERVO_TURN id=1 value=0.50 result=FAILED reason=hold_check_moved drift=+40 torque=OFF (power-cycle servo)",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=unknown_turn_count torque=1 moving=0 goal=0 raw=9 (power-cycle servo)",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=goal_mismatch goal=0 raw=9 (power-cycle servo)",
    "SERVO_TURN id=2 value=0.14 result=TIMEOUT target=2432 actual=2300 ms=2233 torque=ON",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=servo_error flags=0x20",
    "SERVO_TURN id=1 value=0.50 result=REJECTED reason=not_position_mode mode=3",
    "SERVO_TURN id=1 value=3.50 result=REJECTED reason=turns_over max=3.0",
    "SERVO_TURN id=1 value=0.50 result=ABORTED target=9 actual=5 reason=abort hold=YES",
]


@pytest.mark.parametrize("line", UNMOVED)
def test_refused_before_anything_turned(line):
    assert is_servo_no_reply(line) and not is_servo_position_unknown(line)


@pytest.mark.parametrize("line", POSITION_UNKNOWN)
def test_the_count_dropped_on_a_bus_error(line):
    assert is_servo_position_unknown(line) and not is_servo_no_reply(line)


@pytest.mark.parametrize("line", REAL_FAULTS)
def test_a_real_servo_fault_is_not_a_bus_error(line):
    assert not is_servo_no_reply(line) and not is_servo_position_unknown(line)


def test_both_kinds_are_servo_failures_a_sequence_may_try_again():
    for exc in (ServoNoReply("x"), ServoPositionUnknown("x")):
        assert isinstance(exc, ServoFailed) and servo_bus_error(exc)
    assert not servo_bus_error(ServoFailed("x")) and not servo_bus_error(RobotCommandError("x"))


# ------------------------------------------------------------------ the drum servo (real robot)
async def _drum():
    robot = await make_robot()
    await robot.set_z_point("top")  # counts 1000 = Z 100 (122.88 counts per unit)
    await robot.home()
    return robot, robot.serial.transport


def _counts(z: float) -> float:
    return 1000 + (z - 100.0) * 122.88


@pytest.mark.parametrize("kind", ["read_failed", "not_position_mode"])
async def test_a_drum_turn_refused_on_the_bus_moves_nothing_and_goes_through_next(kind):
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append(kind)
        with pytest.raises(ServoNoReply):
            await robot.move_z(50.0)
        assert fw.servo_abs[1] == 1000 and robot.snapshot().z == pytest.approx(100.0)
        await robot.move_z(50.0)
        assert fw.servo_abs[1] == pytest.approx(_counts(50.0), abs=2)
    finally:
        await robot.disconnect()


async def test_limits_not_read_are_not_a_power_cut_of_the_drum():
    """multi_turn_lost is also the firmware's answer when it could not read the limits: the
    status says multi-turn, so the Z points stay and the next move goes on."""
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append("limits_unread")
        with pytest.raises(ServoPositionUnknown, match="not a power cut"):
            await robot.move_z(50.0)
        s = robot.snapshot()
        assert s.z_top_set and s.z_reference_set and not s.z_servo_reset
        await robot.move_z(50.0)
        assert fw.servo_abs[1] == pytest.approx(_counts(50.0), abs=15)
        assert robot.snapshot().z == pytest.approx(50.0, abs=0.2)
    finally:
        await robot.disconnect()


async def test_a_real_power_cut_of_the_drum_still_forgets_the_points():
    robot, fw = await _drum()
    try:
        fw.servo_limits[1] = "0/4095"  # back to one turn
        with pytest.raises(ServoFailed) as e:
            await robot.move_z(50.0)
        assert not isinstance(e.value, (ServoNoReply, ServoPositionUnknown))
        assert not robot.snapshot().z_top_set
    finally:
        await robot.disconnect()


@pytest.mark.parametrize("kind", ["feedback_lost", "goal_write_failed"])
async def test_a_drum_that_turned_unheard_is_counted_from_where_it_really_is(kind):
    """The drum went on to its goal while the bus said nothing; the firmware's abs is the last
    count heard. The next move takes the count back first, and works from there."""
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append(kind)
        with pytest.raises(ServoPositionUnknown):
            await robot.move_z(50.0)
        assert fw.servo_stale[1] == pytest.approx(_counts(50.0), abs=2)  # it is there really
        await poll_z(robot)  # the stale abs (1000) is not taken for where the drum is
        assert robot.snapshot().z == pytest.approx(100.0)
        await robot.move_z(80.0)  # from 50 (where it is), not from 100 (the stale count)
        assert fw.servo_abs[1] == pytest.approx(_counts(80.0), abs=2)
        assert robot.snapshot().z == pytest.approx(80.0, abs=0.05)
        assert any(c.startswith("SERVO_TURN 1 ") and abs(float(c.split()[2])) < 0.01 for c in fw.sent)  # the nudge
    finally:
        await robot.disconnect()


async def test_the_count_is_taken_back_only_at_rest_and_with_the_limits_read():
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append("feedback_lost")
        with pytest.raises(ServoPositionUnknown):
            await robot.move_z(50.0)
        fw.servo_moving.add(1)
        with pytest.raises(ServoPositionUnknown, match="taken back"):
            await robot.move_z(80.0)  # still turning: not yet, nothing sent to turn
        fw.servo_moving.clear()
        fw.servo_limits_unread.add(1)
        with pytest.raises(ServoPositionUnknown, match="taken back"):
            await robot.move_z(80.0)  # the limits not read (-1/-1): not yet
        fw.servo_limits_unread.clear()
        assert fw.servo_abs[1] == 1000  # nothing turned while it was not known
        await robot.move_z(80.0)
        assert fw.servo_abs[1] == pytest.approx(_counts(80.0), abs=2)
    finally:
        await robot.disconnect()


async def test_a_power_cut_found_while_taking_the_count_back_forgets_the_points():
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append("feedback_lost")
        with pytest.raises(ServoPositionUnknown):
            await robot.move_z(50.0)
        fw.servo_limits[1] = "0/4095"
        with pytest.raises(ServoFailed) as e:
            await robot.move_z(80.0)
        assert not servo_bus_error(e.value) and not robot.snapshot().z_top_set
    finally:
        await robot.disconnect()


async def test_a_count_the_firmware_cannot_take_back_is_a_real_fault():
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1] += ["feedback_lost", "unknown_turn_count"]
        with pytest.raises(ServoPositionUnknown):
            await robot.move_z(50.0)
        with pytest.raises(ServoFailed, match="could not be taken back") as e:
            await robot.move_z(80.0)
        assert not servo_bus_error(e.value)
    finally:
        await robot.disconnect()


async def test_no_point_is_recorded_from_a_stale_count():
    robot, fw = await _drum()
    try:
        fw.servo_turn_fault[1].append("feedback_lost")
        with pytest.raises(ServoPositionUnknown):
            await robot.move_z(50.0)
        fw.servo_moving.add(1)
        with pytest.raises(ServoPositionUnknown):
            await robot.set_z_point("bottom")
        fw.servo_moving.clear()
        await robot.set_z_point("bottom")  # taken back first: the bottom is where it really is
        assert robot._z_bottom_counts == pytest.approx(_counts(50.0), abs=15)
        fw.servo_no_reply.add(1)
        with pytest.raises(ServoNoReply):
            await robot.set_z_point("bottom")
    finally:
        await robot.disconnect()


# ------------------------------------------------------------------ the claw servo (real robot)
async def test_a_claw_that_turned_unheard_is_counted_from_where_it_really_is(tmp_path):
    robot, fw = await _claw_ready(tmp_path)  # closed at 0 deg, open at +60, standing open
    try:
        closed = fw.servo_abs[2] - round(60 * 4096 / 360)
        fw.servo_turn_fault[2].append("feedback_lost")
        with pytest.raises(ServoPositionUnknown):
            await robot.arm_goto("closed")
        assert fw.servo_stale[2] == pytest.approx(closed, abs=2)
        await robot.arm_goto("closed")  # already there: no second 60 deg on top of it
        assert fw.servo_abs[2] == pytest.approx(closed, abs=8)
        await robot.arm_goto("open")
        assert fw.servo_abs[2] == pytest.approx(closed + 60 * 4096 / 360, abs=8)
    finally:
        await robot.disconnect()


async def test_limits_not_read_are_not_a_power_cut_of_the_claw(tmp_path):
    robot, fw = await _claw_ready(tmp_path)
    try:
        fw.servo_turn_fault[2].append("limits_unread")
        with pytest.raises(ServoPositionUnknown, match="not a power cut"):
            await robot.arm_goto("closed")
        assert robot.claw.complete()  # the recorded open / closed stay
        await robot.arm_goto("closed")
        assert robot.snapshot().arm_deg == pytest.approx(0.0, abs=1.0)
    finally:
        await robot.disconnect()


async def test_a_claw_turn_refused_on_the_bus_goes_through_next(tmp_path):
    robot, fw = await _claw_ready(tmp_path)
    try:
        fw.servo_turn_fault[2].append("read_failed")
        with pytest.raises(ServoNoReply):
            await robot.arm_goto("closed")
        await robot.arm_goto("closed")
        assert robot.snapshot().arm_deg == pytest.approx(0.0, abs=1.0)
    finally:
        await robot.disconnect()


# ------------------------------------------------------------------ the sequences
def _rig(retry_s: float) -> EasyRig:
    rig = EasyRig()
    rig.seq.backend.servo_no_reply_retry_s = retry_s
    return rig


async def _heal_after(rig: EasyRig, fault: str, s: float) -> None:
    await asyncio.sleep(s)
    rig.robot.faults.discard(fault)


async def test_the_easy_mode_plays_on_through_a_lost_feedback():
    async with _rig(2.0) as rig:
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        rig.robot.inject("servo_feedback_lost")
        heal = asyncio.create_task(_heal_after(rig, "servo_feedback_lost", 0.6))
        rig.seq.choose(1, rig.seq.grab_id)
        await rig.seq.wait()
        await heal
        assert rig.seq.last_result == "done", rig.seq.error
        assert "ABORT" not in rig.robot.commands and "STOP" not in rig.robot.commands


async def test_a_lost_feedback_that_lasts_is_a_servo_fault_stopped_with_stop():
    async with _rig(0.6) as rig:
        rig.robot.inject("servo_feedback_lost")
        await rig.seq.start_reset()
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and "servo bus error for" in rig.seq.error
        assert rig.seq.status()["servo_fault"] is True
        assert "STOP" in rig.robot.commands and "ABORT" not in rig.robot.commands


async def test_the_preparation_tries_a_servo_step_again():
    robot = MockRobot()
    await robot.connect()
    await robot.arm_set("open")
    robot.arm_deg = 40.0
    await robot.arm_set("closed")
    real_goto, fails = robot.arm_goto, [ServoNoReply("SERVO_STATUS id=2 result=NO_REPLY"),
                                        ServoPositionUnknown("SERVO_TURN id=2 result=FAILED reason=feedback_lost")]

    async def flaky(which):
        if fails:
            raise fails.pop(0)
        await real_goto(which)

    robot.arm_goto = flaky  # type: ignore[method-assign]
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0, servo_retry_s=5.0)
    await seq.start()
    await asyncio.wait_for(seq.wait(), 30)
    assert seq.last_result == "done", seq.error
    off = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)  # no retry: stops as before
    fails.append(ServoNoReply("SERVO_STATUS id=2 result=NO_REPLY"))
    await off.start()
    await asyncio.wait_for(off.wait(), 30)
    assert off.last_result == "fault" and "NO_REPLY" in off.error


async def test_the_homework_approach_tries_a_servo_step_again():
    r = await ready_robot()
    seq = ApproachSequencer(r, RobotLimits())
    seq.servo_retry_s = 5.0
    seq.spot = HomeworkSpot(150, 90, 30)
    real_move_z, fails = r.move_z, [ServoNoReply("SERVO_TURN id=1 result=REJECTED reason=no_reply")] * 2

    async def flaky(z):
        if fails:
            raise fails.pop(0)
        await real_move_z(z)

    r.move_z = flaky  # type: ignore[method-assign]
    await seq.start()
    await wait_phase(seq, ApproachPhase.HOLD)
    seq.release()
    await seq.wait()
    assert seq.last_result == "done", seq.error
