"""What the automatic sequences that move the robot step by step share (the auto catch and the
homework approach, and so the easy mode and the tidy-up built on them): how a run is aborted
and how it ends in FAULT. The safety rules are here, once:

- after an abort was asked for, no new action is sent (request_abort is synchronous; the
  action's own task checks again before it sends);
- the robot's stop (ABORT) is sent once per run, by the sequence or by the caller
  (send_stop=False), never twice;
- a fault always sends the stop before it reports FAULT, then gives the running action
  ABORT_WAIT_S to see the ABORT before it is cancelled.

A subclass keeps: active, error, last_result, _task, _action, _abort_reason, _stop_sent,
robot, params (xy_feed_mm_min), _set_phase(), and sets FAULT_PHASE, label and _log.
"""

from __future__ import annotations

import asyncio
import logging

from ..robot.interface import RobotCommandError

ABORT_WAIT_S = 2.0  # after ABORT, how long a still-running action may take to end


class AbortableSequence:
    label = "sequence"  # in the log lines
    FAULT_PHASE: object = None  # the subclass's phase for a run that ended in a fault
    _log = logging.getLogger(__name__)

    def request_abort(self, reason: str) -> bool:
        """Synchronous part of an abort: from now on no new action is started.
        Returns True if a sequence was running."""
        if not self.active:
            return False
        if not self._abort_reason:
            self._abort_reason = reason
        return True

    async def abort(self, reason: str, *, send_stop: bool = True) -> bool:
        """Stop the sequence now. send_stop=False when the caller sends the robot's stop itself."""
        if not self.request_abort(reason):
            return False
        if send_stop:
            await self._emergency_stop()
        else:
            self._stop_sent = True
        return True

    async def wait(self) -> None:
        if self._task is not None:
            await asyncio.shield(self._task)

    async def _action_body(self, step) -> None:
        # A task runs only after the current one yields: a stop that came in between
        # creating it and its first step must not let the command out after the ABORT.
        if self._abort_reason:
            raise RobotCommandError(f"not sent ({self._abort_reason})")
        if step.kind == "claw":
            await self.robot.arm_goto(step.claw)
        elif step.kind == "z":
            await self.robot.move_z(step.z)
        else:
            await self.robot.move_xy(step.x, step.y, self.params.xy_feed_mm_min)

    async def _emergency_stop(self) -> None:
        if self._stop_sent:
            return
        self._stop_sent = True
        try:
            await self.robot.stop()
        except Exception as e:  # e.g. not connected: report it, nothing else to do here
            self._log.error("%s: emergency stop failed: %s", self.label, e)
            self.error += f" (stop failed: {e})"

    def _fault_text(self, reason: str) -> str:
        """What the FAULT phase and the log say (here: the reason and, if the stop failed, that)."""
        return self.error

    async def _fault(self, reason: str) -> None:
        action = self._action
        self.error = reason
        self.last_result = "fault"
        await self._emergency_stop()
        text = self._fault_text(reason)
        self._set_phase(self.FAULT_PHASE, text)
        self._log.error("%s: FAULT: %s", self.label, text)
        if action is not None and not action.done():
            # ABORT ends the firmware's move / servo command; give the action time to see it
            try:
                await asyncio.wait_for(asyncio.shield(action), ABORT_WAIT_S)
            except Exception:  # its failure is expected after ABORT; the fault is already recorded
                pass
            if not action.done():
                action.cancel()
        elif action is not None and action.done() and not action.cancelled():
            action.exception()  # retrieved: no "exception was never retrieved" warning
