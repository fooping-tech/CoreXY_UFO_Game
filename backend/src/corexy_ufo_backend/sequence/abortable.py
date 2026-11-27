"""What the automatic sequences that move the robot step by step share (the auto catch and the
homework approach, and so the easy mode and the tidy-up built on them): how a run is aborted
and how it ends in FAULT. The safety rules are here, once:

- after an abort was asked for, no new action is sent (request_abort is synchronous; the
  action's own task checks again before it sends);
- the robot's stop (ABORT) is sent once per run, by the sequence or by the caller
  (send_stop=False), never twice;
- a fault always sends the stop before it reports FAULT, then gives the running action
  ABORT_WAIT_S to see the ABORT before it is cancelled;
- #269: a fault that is only a servo command answered with a failed result (the command is
  over, nothing moves: SequenceFault.servo_ended) is stopped with STOP instead of ABORT, so
  the firmware raises no alarm and keeps its homing. Not when a stop was asked for (that
  stays ABORT), and ABORT after all when STOP cannot be sent or confirmed.

A subclass keeps: active, error, last_result, _task, _action, _abort_reason, _stop_sent,
robot, params (xy_feed_mm_min), _set_phase(), and sets FAULT_PHASE, label and _log.
"""

from __future__ import annotations

import asyncio
import logging

from ..robot.interface import RobotCommandError, ServoNoReply, servo_bus_error

ABORT_WAIT_S = 2.0  # after ABORT, how long a still-running action may take to end
SERVO_RETRY_INTERVAL_S = 0.5  # #344: between the tries of a step whose servo bus failed


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

    async def _soft_stop_instead(self) -> bool:
        """#269: STOP (no alarm, homing kept) in place of ABORT. False = not done (ABORT then)."""
        if self._stop_sent:
            return True
        try:
            await self.robot.soft_stop()
        except Exception as e:  # not connected, not confirmed: the usual ABORT
            self._log.warning("%s: STOP after a servo failure did not go through (%s): ABORT", self.label, e)
            return False
        self._stop_sent = True
        self.error += " (servo error: stopped with STOP, no alarm)"
        return True

    # #344/#348: how long a step whose servo bus failed (ServoNoReply / ServoPositionUnknown) is
    # tried again; None = the backend config's servo_no_reply_retry_s (0 without one)
    servo_retry_s: float | None = None

    def _servo_retry_window(self) -> float:
        if self.servo_retry_s is not None:
            return max(float(self.servo_retry_s), 0.0)
        backend = getattr(self, "backend", None)
        return max(float(getattr(backend, "servo_no_reply_retry_s", 0.0) or 0.0), 0.0)

    async def _servo_try_again(self, step, exc: BaseException, since: float | None) -> float | None:
        """#344/#348: a step's servo command failed on the servo bus (nothing turned, or the
        firmware dropped its count, which the robot takes back at the next try). Within the
        window: pause, then the caller starts the step again; the streak's start is returned.
        None = not such an error, a stop was asked for, or the window is over (a fault then)."""
        if not servo_bus_error(exc) or self._abort_reason:
            return None
        now = self.clock()
        window = self._servo_retry_window()
        if since is None:
            since = now
            if window > 0:
                self._set_phase(step.phase, f"{step.describe()}: servo bus error, trying again for up to "
                                            f"{window:g} s ({exc})")
        if now - since >= window:
            return None
        if not self._abort_reason:
            self._log.warning("%s: %s: servo bus error, trying again (%s)", self.label, step.phase, exc)
        end = self.clock() + SERVO_RETRY_INTERVAL_S
        while True:
            before = self.clock()
            await asyncio.sleep(self.poll_s)
            t = self.clock()
            self._t_start += t - before  # the pause is not the run's time (its total timeout)
            self._check(step, t)  # a stop, an alarm, a lost link still end it at once
            if t >= end:
                return since

    def _servo_why(self, exc: BaseException, since: float | None) -> str:
        why = str(exc)
        if since is not None and servo_bus_error(exc):
            gone = "no answer" if isinstance(exc, ServoNoReply) else "servo bus error"
            why += f" ({gone} for {self.clock() - since:.1f} s)"
        return why

    # #302: the last FAULT was a servo command's own failure, stopped with STOP (no alarm, homing
    # kept, nothing moving): the game takes it as "try again", not as a fault of the crane
    servo_fault: bool = False

    async def _fault(self, reason: str, *, servo_ended: bool = False) -> None:
        action = self._action
        self.error = reason
        self.last_result = "fault"
        self.servo_fault = False
        soft = servo_ended and not self._abort_reason and await self._soft_stop_instead()
        if not soft:
            await self._emergency_stop()
        self.servo_fault = soft  # (set before the FAULT phase below is reported)
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
