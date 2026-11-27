"""#344: a servo that does not answer on its bus for a few seconds (seen on the machine after XY
moves: SERVO_STATUS result=NO_REPLY, SERVO_TURN REJECTED reason=no_reply) does not stop the easy
mode: the step is tried again for up to backend.servo_no_reply_retry_s, then it is the usual
servo FAULT (STOP, no alarm). The stop key still ends it at once."""

import asyncio

import pytest

from corexy_ufo_backend.robot.interface import RobotCommandError, ServoFailed, ServoNoReply, is_servo_no_reply

from test_claw_positions import _claw_ready
from test_easy_mode import EasyRig


def test_the_firmware_lines_that_say_the_servo_did_not_answer():
    assert is_servo_no_reply("SERVO_STATUS id=2 result=NO_REPLY tracking=YES")
    assert is_servo_no_reply("SERVO_TURN id=1 value=-0.65 result=REJECTED reason=no_reply")
    # a command that ended on its own (it may have turned) is not one: no retry for it
    assert not is_servo_no_reply("SERVO_TURN id=2 value=0.14 result=TIMEOUT target=1 actual=2 ms=9")
    assert not is_servo_no_reply("SERVO_TURN id=1 value=0.50 result=REJECTED reason=multi_turn_lost (retry)")
    assert not is_servo_no_reply("SERVO_TURN id=1 value=3.50 result=REJECTED reason=turns_over max=3.0")


async def test_the_real_robot_tells_a_servo_that_does_not_answer(tmp_path):
    robot, fw = await _claw_ready(tmp_path)
    try:
        fw.servo_no_reply.add(2)  # the status read before the turn: nothing is sent to turn
        with pytest.raises(ServoNoReply, match="NO_REPLY"):
            await robot.arm_goto("closed")
        fw.servo_no_reply.clear()
        await robot.arm_goto("closed")  # back: it goes through
        # the turn itself refused (the status still answered)
        real_status = robot.serial.servo_status

        async def status_then_silence(sid):
            st = await real_status(sid)
            fw.servo_no_reply.add(2)
            return st

        robot.serial.servo_status = status_then_silence  # type: ignore[method-assign]
        with pytest.raises(ServoNoReply, match="reason=no_reply"):
            await robot.arm_goto("open")
        assert isinstance(ServoNoReply("x"), ServoFailed) and isinstance(ServoNoReply("x"), RobotCommandError)
    finally:
        await robot.disconnect()


def _rig(retry_s: float) -> EasyRig:
    rig = EasyRig()
    rig.seq.backend.servo_no_reply_retry_s = retry_s
    return rig


async def _heal_after(rig: EasyRig, s: float) -> None:
    await asyncio.sleep(s)
    rig.robot.faults.discard("servo_no_reply")


async def test_a_short_silence_of_the_claw_is_waited_out():
    async with _rig(2.0) as rig:
        rig.robot.inject("servo_no_reply")
        heal = asyncio.create_task(_heal_after(rig, 0.6))
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION", timeout=5.0)
        await heal
        assert rig.seq.error == "" and rig.seq.last_result == ""
        assert "ABORT" not in rig.robot.commands and "STOP" not in rig.robot.commands
        assert rig.robot.commands.count("CLAW -> open") >= 2  # tried again, the same step
        assert any("servo bus error" in h["note"] for h in rig.seq.history)
        await rig.seq.abort("test over")
        await rig.seq.wait()


async def test_a_short_silence_of_the_drum_over_the_dial_is_waited_out():
    """The case seen on the machine: the carry to the Dial, then Z refused with no_reply."""
    async with _rig(2.0) as rig:
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        rig.robot.inject("servo_no_reply")
        heal = asyncio.create_task(_heal_after(rig, 0.6))
        rig.seq.choose(1, rig.seq.grab_id)
        await rig.seq.wait()
        await heal
        assert rig.seq.last_result == "done", rig.seq.error
        assert "ABORT" not in rig.robot.commands and not rig.robot.alarm and rig.robot.homed


async def test_a_silence_longer_than_the_retry_is_a_servo_fault():
    async with _rig(0.6) as rig:
        rig.robot.inject("servo_no_reply")
        await rig.seq.start_reset()
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and "OPEN_CLAW failed" in rig.seq.error and "no answer for" in rig.seq.error
        st = rig.seq.status()
        assert st["servo_fault"] is True  # #302: the game tries again, it does not stop
        assert "STOP" in rig.robot.commands and "ABORT" not in rig.robot.commands and not rig.robot.alarm


async def test_no_retry_when_switched_off():
    async with _rig(0.0) as rig:
        rig.robot.inject("servo_no_reply")
        await rig.seq.start_reset()
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and rig.robot.commands.count("CLAW -> open") == 1


async def test_the_stop_key_ends_the_wait_at_once():
    async with _rig(20.0) as rig:
        rig.robot.inject("servo_no_reply")
        await rig.seq.start_reset()
        await asyncio.sleep(0.3)
        assert rig.seq.active
        t0 = asyncio.get_running_loop().time()
        await rig.seq.abort("stop key")
        await rig.seq.wait()
        assert asyncio.get_running_loop().time() - t0 < 1.0
        assert rig.seq.state == "FAULT" and "stop key" in rig.seq.error
        assert "ABORT" in rig.robot.commands and rig.robot.alarm  # a stop stays FAULT + ABORT


async def test_the_wait_does_not_count_toward_the_total_timeout():
    async with _rig(3.0) as rig:
        rig.seq.params = rig.seq.params.__class__(**{**rig.seq.params.__dict__, "total_timeout_s": 1.0})
        rig.robot.inject("servo_no_reply")
        heal = asyncio.create_task(_heal_after(rig, 1.5))
        await rig.seq.start_reset()
        await rig.seq.wait()
        await heal
        assert rig.seq.last_result == "done", rig.seq.error
