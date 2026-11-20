"""The abort / fault rules every step-by-step sequence shares (sequence/abortable.py, #216)."""

import asyncio
from types import SimpleNamespace

import pytest

from corexy_ufo_backend.homework.approach import ApproachSequencer
from corexy_ufo_backend.robot.interface import RobotCommandError
from corexy_ufo_backend.sequence import AutoCatchSequencer
from corexy_ufo_backend.sequence.abortable import AbortableSequence
from corexy_ufo_backend.sequence.cleanup import CleanupSequencer
from corexy_ufo_backend.sequence.easy import EasySequencer


class Robot:
    def __init__(self, stop_fails=False):
        self.calls: list[str] = []
        self.stop_fails = stop_fails

    async def stop(self):
        self.calls.append("stop")
        if self.stop_fails:
            raise RobotCommandError("not connected")

    async def move_xy(self, x, y, feed):
        self.calls.append("move_xy")

    async def move_z(self, z):
        self.calls.append("move_z")

    async def arm_goto(self, which):
        self.calls.append("arm_goto")


class Seq(AbortableSequence):
    FAULT_PHASE = "FAULT"

    def __init__(self, robot):
        self.robot = robot
        self.params = SimpleNamespace(xy_feed_mm_min=600.0)
        self.active = True
        self.error = ""
        self.last_result = ""
        self._task = None
        self._action = None
        self._abort_reason = ""
        self._stop_sent = False
        self.phases: list[tuple] = []

    def _set_phase(self, phase, note=""):
        self.phases.append((phase, note, list(self.robot.calls)))


def test_the_four_sequencers_use_the_one_implementation():
    for cls in (AutoCatchSequencer, EasySequencer, ApproachSequencer, CleanupSequencer):
        assert issubclass(cls, AbortableSequence)
        for name in ("request_abort", "abort", "wait", "_emergency_stop", "_action_body"):
            assert getattr(cls, name) is getattr(AbortableSequence, name), (cls, name)
    assert AutoCatchSequencer._fault is AbortableSequence._fault
    assert ApproachSequencer._fault is AbortableSequence._fault


async def test_the_stop_is_sent_once_and_not_at_all_when_the_caller_sends_it():
    s = Seq(Robot())
    assert await s.abort("stop pressed") and await s.abort("again")
    await s._fault("stop pressed")
    assert s.robot.calls == ["stop"] and s._abort_reason == "stop pressed"  # the first reason stays

    s = Seq(Robot())
    assert await s.abort("server stop", send_stop=False)
    await s._fault("server stop")
    assert s.robot.calls == []  # the caller's own stop is the one

    s = Seq(Robot())
    s.active = False
    assert not await s.abort("nothing runs") and s.robot.calls == [] and s._abort_reason == ""


async def test_after_an_abort_no_action_goes_out():
    s = Seq(Robot())
    step = SimpleNamespace(kind="xy", x=1.0, y=2.0)
    await s._action_body(step)
    assert s.robot.calls == ["move_xy"]
    s.request_abort("stop pressed")
    for kind in ("xy", "z", "claw"):
        with pytest.raises(RobotCommandError, match="not sent"):
            await s._action_body(SimpleNamespace(kind=kind, x=0.0, y=0.0, z=0.0, claw="open"))
    assert s.robot.calls == ["move_xy"]


async def test_a_fault_stops_first_then_reports_and_ends_the_running_action():
    s = Seq(Robot())
    s._action = asyncio.get_running_loop().create_task(asyncio.sleep(60))
    import corexy_ufo_backend.sequence.abortable as mod
    old, mod.ABORT_WAIT_S = mod.ABORT_WAIT_S, 0.05
    try:
        await s._fault("Z below z_floor")
    finally:
        mod.ABORT_WAIT_S = old
    assert s.phases == [("FAULT", "Z below z_floor", ["stop"])]  # the stop was out before FAULT was said
    assert s.error == "Z below z_floor" and s.last_result == "fault"
    await asyncio.sleep(0)
    assert s._action.cancelled()


async def test_a_stop_that_fails_is_reported_and_the_fault_still_ends():
    s = Seq(Robot(stop_fails=True))
    await s._fault("alarm")
    assert s.robot.calls == ["stop"] and "stop failed: not connected" in s.error
    assert s.phases[0][0] == "FAULT" and s.last_result == "fault"
