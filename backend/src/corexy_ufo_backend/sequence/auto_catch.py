"""One-button auto catch: an explicit state machine on top of RobotInterface.

    IDLE --start()--> OPEN_CLAW -> LOWER_TO_CATCH -> CLOSE_CLAW -> RAISE_WITH_ITEM
         -> MOVE_TO_BOX -> LOWER_TO_RELEASE -> RELEASE -> RAISE_EMPTY -> CLAW_STANDBY -> IDLE
    any state --fault / stop--> FAULT (ABORT sent: alarm, homing lost)

Each state starts one robot action as a task and then polls (every poll_s) until
it is finished: the action returned without error AND the robot reports the
target (XY within xy_tolerance_mm and not moving, Z within z_tolerance, claw
moves followed by claw_settle_s). Nothing waits on a fixed delay.

Every poll also checks, before anything else: an abort request (stop / soft_stop),
the state's timeout, the total timeout, connection, motors armed, alarm, homing
kept, limit switches (active away from home), and that the reported position is
finite and inside the soft limits and not below z_floor. Any of these ends the
sequence in FAULT and sends the emergency stop (ABORT: XY and the servos stop,
alarm on, homing cleared), so it cannot restart until clear_alarm + home.

Exclusion: the sequence holds the server's motion lock for its whole run, so
manual moves, jogs and a second start are refused (busy). stop is never blocked.
"""

from __future__ import annotations

import asyncio
import logging
import math
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from ..config import BackendConfig, RobotLimits
from ..robot.interface import RobotCommandError, RobotInterface
from ..robot.state import MachineState, RobotSnapshot
from .params import AutoCatchParams, height, validate

log = logging.getLogger(__name__)

HISTORY_MAX = 30
ABORT_WAIT_S = 2.0  # after ABORT, how long a still-running action may take to end


class Phase(StrEnum):
    IDLE = "IDLE"
    OPEN_CLAW = "OPEN_CLAW"
    LOWER_TO_CATCH = "LOWER_TO_CATCH"
    CLOSE_CLAW = "CLOSE_CLAW"
    RAISE_WITH_ITEM = "RAISE_WITH_ITEM"
    MOVE_TO_BOX = "MOVE_TO_BOX"
    LOWER_TO_RELEASE = "LOWER_TO_RELEASE"
    RELEASE = "RELEASE"
    RAISE_EMPTY = "RAISE_EMPTY"
    CLAW_STANDBY = "CLAW_STANDBY"
    FAULT = "FAULT"


@dataclass(frozen=True)
class Step:
    phase: Phase
    timeout_key: str
    kind: str  # "claw" | "z" | "xy"
    claw: str = ""
    z: float = 0.0
    x: float = 0.0
    y: float = 0.0

    def describe(self) -> str:
        if self.kind == "claw":
            return f"claw -> {self.claw}"
        if self.kind == "z":
            return f"Z -> {self.z:g}"
        return f"XY -> ({self.x:g}, {self.y:g})"


class SequenceFault(Exception):
    pass


def build_steps(p: AutoCatchParams) -> list[Step]:
    steps = [
        Step(Phase.OPEN_CLAW, "open_claw", "claw", claw=p.claw_open),
        Step(Phase.LOWER_TO_CATCH, "lower_to_catch", "z", z=float(p.catch_z)),  # type: ignore[arg-type]
        Step(Phase.CLOSE_CLAW, "close_claw", "claw", claw=p.claw_close),
        Step(Phase.RAISE_WITH_ITEM, "raise_with_item", "z", z=float(p.safe_z)),  # type: ignore[arg-type]
        Step(Phase.MOVE_TO_BOX, "move_to_box", "xy", x=float(p.box_x_mm), y=float(p.box_y_mm)),  # type: ignore[arg-type]
        Step(Phase.LOWER_TO_RELEASE, "lower_to_release", "z", z=float(p.release_z)),  # type: ignore[arg-type]
        Step(Phase.RELEASE, "release", "claw", claw=p.claw_open),
        Step(Phase.RAISE_EMPTY, "raise_empty", "z", z=float(p.safe_z)),  # type: ignore[arg-type]
    ]
    if p.claw_standby is not None:
        steps.append(Step(Phase.CLAW_STANDBY, "claw_standby", "claw", claw=p.claw_standby))
    return steps


class AutoCatchSequencer:
    def __init__(self, robot: RobotInterface, params: AutoCatchParams, limits: RobotLimits,
                 backend: BackendConfig | None = None, *, lock: asyncio.Lock | None = None,
                 is_jogging: Callable[[], bool] = lambda: False,
                 on_change: Callable[[dict], None] | None = None,
                 poll_s: float = 0.02, clock: Callable[[], float] = time.monotonic) -> None:
        self.robot = robot
        self.params = params
        self.limits = limits
        self.backend = backend
        self.lock = lock or asyncio.Lock()
        self.is_jogging = is_jogging
        self.on_change = on_change
        self.poll_s = poll_s
        self.clock = clock
        self.phase = Phase.IDLE
        self.active = False
        self.error = ""
        self.last_result = ""  # "" | "done" | "fault"
        self.step_index = 0
        self.steps: list[Step] = []
        self.history: list[dict] = []
        self._task: asyncio.Task | None = None
        self._action: asyncio.Task | None = None  # the robot command of the current state
        self._abort_reason = ""
        self._stop_sent = False
        self._t_start = 0.0
        self._t_phase = 0.0
        self._last_press = -math.inf

    # ------------------------------------------------------------------ status
    def status(self) -> dict:
        now = self.clock()
        return {
            "active": self.active,
            "phase": str(self.phase),
            "step": self.step_index,
            "steps": len(self.steps),
            "error": self.error,
            "last_result": self.last_result,
            "profile": self.params.profile,
            "elapsed_s": round(now - self._t_start, 2) if self.active else 0.0,
            "phase_elapsed_s": round(now - self._t_phase, 2) if self.active else 0.0,
            "history": list(self.history[-10:]),
        }

    def _set_phase(self, phase: Phase, note: str = "") -> None:
        prev = self.phase
        self.phase = phase
        self._t_phase = self.clock()
        self.history.append({"t_ms": int(time.time() * 1000), "from": str(prev), "to": str(phase), "note": note})
        del self.history[:-HISTORY_MAX]
        log.info("auto_catch: %s -> %s%s", prev, phase, f" ({note})" if note else "")
        self._changed()

    def _changed(self) -> None:
        if self.on_change is not None:
            try:
                self.on_change(self.status())
            except Exception:  # pragma: no cover - a UI hook must not break the sequence
                log.exception("auto_catch on_change")

    # ------------------------------------------------------------ preconditions
    def _limit_fault(self, s: RobotSnapshot) -> str:
        zone = float(self.params.limit_home_zone_mm or 0.0)
        if s.limit_x and s.x > self.limits.x_min + zone:
            return f"X limit switch active away from home (x={s.x:.1f})"
        if s.limit_y and s.y > self.limits.y_min + zone:
            return f"Y limit switch active away from home (y={s.y:.1f})"
        return ""

    def preconditions(self) -> list[str]:
        """Why the sequence cannot start now (empty = it can)."""
        errs = list(validate(self.params, self.limits, self.backend))
        s = self.robot.snapshot()
        if self.active:
            errs.append("auto catch already running")
        if not s.connected:
            errs.append("robot not connected")
        if not s.motors_enabled:
            errs.append("motors not enabled")
        if s.alarm or s.state in (MachineState.ALARM, MachineState.ESTOP):
            errs.append(f"alarm active ({s.error or s.state}): clear_alarm, then home")
        if not s.homed:
            errs.append("not homed")
        if not s.z_reference_set:
            errs.append("Z reference not set (z_zero)")
        if s.arm_span_deg is None:
            errs.append("claw open / closed positions not recorded (arm_set)")
        else:
            span = abs(s.arm_span_deg)
            lo, hi = self.params.claw_span_min_deg, self.params.claw_span_max_deg
            if lo is not None and hi is not None and not lo <= span <= hi:
                errs.append(f"claw span {span:.1f} deg outside {lo:g}..{hi:g} (servo angle limits)")
        if s.state != MachineState.IDLE and s.state not in (MachineState.ALARM, MachineState.ESTOP):
            errs.append(f"robot busy ({s.state})")
        if self.lock.locked() and not self.active:
            errs.append("busy: another motion command is running")
        if self.is_jogging():
            errs.append("busy: jog active (release the keys)")
        for v in (s.x, s.y, s.z):
            if not math.isfinite(v):
                errs.append("sensor: position is not a number")
                return errs
        if not self.limits.xy_inside(s.x, s.y):
            errs.append(f"XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
        if self.params.safe_z is not None and self.params.z_tolerance is not None:
            if height(s.z, self.limits) < height(self.params.safe_z, self.limits) - self.params.z_tolerance:
                errs.append(f"Z {s.z:.1f} below safe_z {self.params.safe_z:g}: raise the claw first")
        lf = self._limit_fault(s)
        if lf:
            errs.append(lf)
        return errs

    # ------------------------------------------------------------------ control
    async def start(self) -> None:
        """Start from IDLE / FAULT. Raises RobotCommandError (with every reason) if not allowed.
        Button chatter: a press within button_debounce_ms of the previous one is ignored."""
        now = self.clock()
        debounce = (self.params.button_debounce_ms or 0.0) / 1000.0
        if now - self._last_press < debounce:
            self._last_press = now
            raise RobotCommandError("debounced: pressed again too soon")
        self._last_press = now
        if self.active:
            raise RobotCommandError("busy: auto catch already running")
        refresh = getattr(self.robot, "refresh_status", None)
        if refresh is not None:
            await refresh()  # fresh limits / alarm before deciding
        errs = self.preconditions()
        if errs:
            raise RobotCommandError("auto catch refused: " + "; ".join(errs))
        if self.lock.locked():  # taken while refresh_status was waiting
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()  # free: returns at once, no other task can slip in
        self.active = True
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._stop_sent = False
        self.steps = build_steps(self.params)
        self.step_index = 0
        self._t_start = self.clock()
        self._task = asyncio.get_running_loop().create_task(self._run())

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

    # ------------------------------------------------------------------ run loop
    async def _run(self) -> None:
        try:
            for i, step in enumerate(self.steps):
                self.step_index = i + 1
                await self._do_step(step)
            self._finish_ok()
        except SequenceFault as f:
            await self._fault(str(f))
        except asyncio.CancelledError:
            await self._fault("sequence cancelled")
            raise
        except Exception as e:  # pragma: no cover - a bug must still end in a safe state
            log.exception("auto_catch")
            await self._fault(f"internal error: {e}")
        finally:
            self._action = None
            self.active = False
            if self.lock.locked():
                self.lock.release()
            self._changed()

    def _check(self, step: Step, t0: float) -> None:
        if self._abort_reason:
            raise SequenceFault(self._abort_reason)
        now = self.clock()
        p = self.params
        if now - self._t_start > p.total_timeout_s:  # type: ignore[operator]
            raise SequenceFault(f"total timeout ({p.total_timeout_s:g} s) in {step.phase}")
        limit = p.timeouts_s[step.timeout_key]
        if now - t0 > limit:
            raise SequenceFault(f"{step.phase} timeout ({limit:g} s, {step.describe()})")
        s = self.robot.snapshot()
        if not s.connected:
            raise SequenceFault("robot disconnected")
        if not s.motors_enabled:
            raise SequenceFault("motors disabled")
        if s.alarm or s.state in (MachineState.ALARM, MachineState.ESTOP):
            raise SequenceFault(f"alarm: {s.error or s.state}")
        if not s.homed:
            raise SequenceFault("homing lost")
        if not all(math.isfinite(v) for v in (s.x, s.y, s.z)):
            raise SequenceFault("sensor: position is not a number")
        tol_xy, tol_z = float(p.xy_tolerance_mm), float(p.z_tolerance)  # type: ignore[arg-type]
        lim = self.limits
        if not (lim.x_min - tol_xy <= s.x <= lim.x_max + tol_xy and lim.y_min - tol_xy <= s.y <= lim.y_max + tol_xy):
            raise SequenceFault(f"sensor: XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
        if not lim.z_min - tol_z <= s.z <= lim.z_max + tol_z:
            raise SequenceFault(f"sensor: Z {s.z:.1f} outside {lim.z_min:g}..{lim.z_max:g}")
        if height(s.z, lim) < height(float(p.z_floor), lim) - tol_z:  # type: ignore[arg-type]
            raise SequenceFault(f"Z {s.z:.1f} below z_floor {p.z_floor:g}")
        lf = self._limit_fault(s)
        if lf:
            raise SequenceFault(lf)

    def _reached(self, step: Step) -> bool:
        s = self.robot.snapshot()
        if step.kind == "xy":
            return (math.hypot(s.x - step.x, s.y - step.y) <= float(self.params.xy_tolerance_mm)  # type: ignore[arg-type]
                    and s.state == MachineState.IDLE)
        if step.kind == "z":
            return (abs(s.z - step.z) <= float(self.params.z_tolerance)  # type: ignore[arg-type]
                    and s.state not in (MachineState.Z_LOWERING, MachineState.Z_RAISING))
        return True  # claw: the servo command itself reported PASS

    def _start_action(self, step: Step) -> asyncio.Task:
        if step.kind == "claw":
            coro = self.robot.arm_goto(step.claw)
        elif step.kind == "z":
            coro = self.robot.move_z(step.z)
        else:
            coro = self.robot.move_xy(step.x, step.y, self.params.xy_feed_mm_min)
        return asyncio.get_running_loop().create_task(coro)

    async def _do_step(self, step: Step) -> None:
        self._set_phase(step.phase, step.describe())
        t0 = self.clock()
        self._check(step, t0)  # an abort that came in between: no new action
        action = self._action = self._start_action(step)
        settled_since: float | None = None
        while True:
            self._check(step, t0)
            if action.done():
                exc = action.exception()
                if exc is not None:
                    raise SequenceFault(f"{step.phase} failed: {exc}")
                if self._reached(step):
                    if step.kind != "claw":
                        return
                    now = self.clock()
                    settled_since = now if settled_since is None else settled_since
                    if now - settled_since >= float(self.params.claw_settle_s):  # type: ignore[arg-type]
                        return
            await asyncio.sleep(self.poll_s)

    def _finish_ok(self) -> None:
        self.last_result = "done"
        self._set_phase(Phase.IDLE, "done")

    async def _emergency_stop(self) -> None:
        if self._stop_sent:
            return
        self._stop_sent = True
        try:
            await self.robot.stop()
        except Exception as e:  # e.g. not connected: report it, nothing else to do here
            log.error("auto_catch: emergency stop failed: %s", e)
            self.error += f" (stop failed: {e})"

    async def _fault(self, reason: str) -> None:
        action = self._action
        self.error = reason
        self.last_result = "fault"
        await self._emergency_stop()
        self._set_phase(Phase.FAULT, self.error)
        log.error("auto_catch: FAULT: %s", self.error)
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
