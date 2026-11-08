"""Take the arm's (focus) camera close to the worksheet, then back.

    IDLE --start()--> RAISE -> MOVE_XY -> LOWER -> HOLD -> RAISE_BACK -> RETURN_XY -> IDLE
    any state --fault / stop--> FAULT (stop sent: ABORT, alarm, homing lost)

The place is a spot recorded by hand (`set_spot`: jog the arm above the worksheet
at the height wanted, record it). No camera-to-CoreXY mapping yet: that is a later
step (then the spot can be the stuck problem itself).

HOLD waits for the game to capture its frames (`release()`), at most hold_timeout_s,
then the arm goes back up (and back to where it started). Same safety frame as
the auto catch (sequence/auto_catch.py): checked preconditions, the server's
motion lock held for the whole run (manual moves / jogs / the auto catch refused),
every poll checks the abort request, timeouts, connection, motors, alarm, homing
and the position; anything wrong ends in FAULT with the robot's stop (ABORT).
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any

from ..config import RobotLimits
from ..robot.interface import RobotCommandError, RobotInterface
from ..robot.state import MachineState

log = logging.getLogger(__name__)

ABORT_WAIT_S = 2.0


class ApproachPhase(StrEnum):
    IDLE = "IDLE"
    RAISE = "RAISE"
    MOVE_XY = "MOVE_XY"
    LOWER = "LOWER"
    HOLD = "HOLD"
    RAISE_BACK = "RAISE_BACK"
    RETURN_XY = "RETURN_XY"
    FAULT = "FAULT"


@dataclass(frozen=True)
class HomeworkSpot:
    """Where the arm's camera looks at the worksheet: XY in mm, Z in the backend's units."""
    x: float
    y: float
    z: float

    @classmethod
    def load(cls, path: Path | None) -> "HomeworkSpot | None":
        if path is None or not path.exists():
            return None
        try:
            d = json.loads(path.read_text(encoding="utf-8"))
            spot = cls(float(d["x"]), float(d["y"]), float(d["z"]))
        except (OSError, ValueError, KeyError, TypeError) as e:
            log.warning("ignoring %s: %s", path, e)
            return None
        return spot if all(math.isfinite(v) for v in (spot.x, spot.y, spot.z)) else None

    def save(self, path: Path | None) -> None:
        if path is not None:
            path.write_text(json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8")


@dataclass(frozen=True)
class ApproachParams:
    xy_tolerance_mm: float = 2.0
    z_tolerance: float = 3.0
    step_timeout_s: float = 30.0
    hold_timeout_s: float = 15.0
    total_timeout_s: float = 150.0
    return_xy: bool = True  # back to where it started, out of the child's way
    xy_feed_mm_min: float | None = None

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "ApproachParams":
        hw = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        d = hw.get("approach") if isinstance(hw.get("approach"), dict) else {}
        feed = d.get("xy_feed_mm_min")
        return cls(xy_tolerance_mm=float(d.get("xy_tolerance_mm", 2.0)), z_tolerance=float(d.get("z_tolerance", 3.0)),
                   step_timeout_s=float(d.get("step_timeout_s", 30.0)), hold_timeout_s=float(d.get("hold_timeout_s", 15.0)),
                   total_timeout_s=float(d.get("total_timeout_s", 150.0)), return_xy=bool(d.get("return_xy", True)),
                   xy_feed_mm_min=float(feed) if feed is not None else None)


@dataclass(frozen=True)
class _Step:
    phase: ApproachPhase
    kind: str  # "z" | "xy" | "hold"
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def describe(self) -> str:
        if self.kind == "z":
            return f"Z -> {self.z:g}"
        if self.kind == "xy":
            return f"XY -> ({self.x:g}, {self.y:g})"
        return "wait for the capture"


class SequenceFault(Exception):
    pass


class ApproachSequencer:
    def __init__(self, robot: RobotInterface, limits: RobotLimits, params: ApproachParams | None = None, *,
                 spot_path: Path | None = None, lock: asyncio.Lock | None = None,
                 is_jogging: Callable[[], bool] = lambda: False,
                 other_active: Callable[[], bool] = lambda: False,
                 on_change: Callable[[dict], None] | None = None,
                 poll_s: float = 0.02, clock: Callable[[], float] = time.monotonic) -> None:
        self.robot = robot
        self.limits = limits
        self.params = params or ApproachParams()
        self.spot_path = spot_path
        self.spot = HomeworkSpot.load(spot_path)
        self.lock = lock or asyncio.Lock()
        self.is_jogging = is_jogging
        self.other_active = other_active
        self.on_change = on_change
        self.poll_s = poll_s
        self.clock = clock
        self.phase = ApproachPhase.IDLE
        self.active = False
        self.error = ""
        self.last_result = ""  # "" | "done" | "fault"
        self._task: asyncio.Task | None = None
        self._action: asyncio.Task | None = None
        self._released = asyncio.Event()
        self._abort_reason = ""
        self._stop_sent = False
        self._t_start = 0.0

    # ------------------------------------------------------------------ status
    @property
    def top_z(self) -> float:
        return self.limits.z_max if self.limits.z_up_is_positive else self.limits.z_min

    def _height(self, z: float) -> float:
        return z if self.limits.z_up_is_positive else -z

    def status(self) -> dict:
        return {"active": self.active, "phase": str(self.phase), "error": self.error,
                "last_result": self.last_result,
                "spot": asdict(self.spot) if self.spot is not None else None,
                "elapsed_s": round(self.clock() - self._t_start, 2) if self.active else 0.0}

    def _set_phase(self, phase: ApproachPhase, note: str = "") -> None:
        log.info("homework approach: %s -> %s%s", self.phase, phase, f" ({note})" if note else "")
        self.phase = phase
        self._changed()

    def _changed(self) -> None:
        if self.on_change is not None:
            try:
                self.on_change(self.status())
            except Exception:  # pragma: no cover - a UI hook must not break the sequence
                log.exception("homework approach on_change")

    # ------------------------------------------------------------------ spot
    def set_spot(self) -> HomeworkSpot:
        """Record where the arm is now as the spot (jog it there first)."""
        if self.active:
            raise RobotCommandError("busy: the arm is approaching the worksheet")
        s = self.robot.snapshot()
        if not s.connected:
            raise RobotCommandError("robot not connected")
        if not s.homed:
            raise RobotCommandError("not homed: home first (XY must be known)")
        if not s.z_reference_set:
            raise RobotCommandError("Z reference not set: record the arm's top point first")
        if not all(math.isfinite(v) for v in (s.x, s.y, s.z)):
            raise RobotCommandError("sensor: position is not a number")
        spot = HomeworkSpot(round(s.x, 2), round(s.y, 2), round(s.z, 2))
        errs = self._spot_errors(spot)
        if errs:
            raise RobotCommandError("; ".join(errs))
        self.spot = spot
        spot.save(self.spot_path)
        log.info("homework spot recorded: %s", spot)
        self._changed()
        return spot

    def _spot_errors(self, spot: HomeworkSpot) -> list[str]:
        lim = self.limits
        errs = []
        if not lim.xy_inside(spot.x, spot.y):
            errs.append(f"spot XY ({spot.x:g},{spot.y:g}) outside the soft limits")
        if not lim.z_min <= spot.z <= lim.z_max:
            errs.append(f"spot Z {spot.z:g} outside {lim.z_min:g}..{lim.z_max:g}")
        return errs

    # ------------------------------------------------------------------ control
    def preconditions(self) -> list[str]:
        errs: list[str] = []
        s = self.robot.snapshot()
        if self.active:
            errs.append("already approaching")
        if self.spot is None:
            errs.append("no homework spot recorded (jog the arm above the worksheet, then record it)")
        else:
            errs += self._spot_errors(self.spot)
        if not s.connected:
            errs.append("robot not connected")
        if not s.motors_enabled:
            errs.append("motors not enabled")
        if s.alarm or s.state in (MachineState.ALARM, MachineState.ESTOP):
            errs.append(f"alarm active ({s.error or s.state}): clear_alarm, then home")
        if not s.homed:
            errs.append("not homed")
        if not s.z_reference_set:
            errs.append("Z reference not set")
        if s.state not in (MachineState.IDLE, MachineState.ALARM, MachineState.ESTOP):
            errs.append(f"robot busy ({s.state})")
        if self.other_active():
            errs.append("busy: auto catch running")
        if self.lock.locked() and not self.active:
            errs.append("busy: another motion command is running")
        if self.is_jogging():
            errs.append("busy: jog active (release the keys)")
        if not all(math.isfinite(v) for v in (s.x, s.y, s.z)):
            errs.append("sensor: position is not a number")
        elif not self.limits.xy_inside(s.x, s.y):
            errs.append(f"XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
        return errs

    async def start(self) -> None:
        if self.active:
            raise RobotCommandError("busy: already approaching")
        refresh = getattr(self.robot, "refresh_status", None)
        if refresh is not None:
            await refresh()
        errs = self.preconditions()
        if errs:
            raise RobotCommandError("approach refused: " + "; ".join(errs))
        if self.lock.locked():
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()
        s = self.robot.snapshot()
        assert self.spot is not None
        top, spot = self.top_z, self.spot
        steps = [_Step(ApproachPhase.RAISE, "z", z=top),
                 _Step(ApproachPhase.MOVE_XY, "xy", x=spot.x, y=spot.y),
                 _Step(ApproachPhase.LOWER, "z", z=spot.z),
                 _Step(ApproachPhase.HOLD, "hold"),
                 _Step(ApproachPhase.RAISE_BACK, "z", z=top)]
        if self.params.return_xy and math.hypot(s.x - spot.x, s.y - spot.y) > self.params.xy_tolerance_mm:
            steps.append(_Step(ApproachPhase.RETURN_XY, "xy", x=s.x, y=s.y))
        self.active = True
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._stop_sent = False
        self._released.clear()
        self._t_start = self.clock()
        self._task = asyncio.get_running_loop().create_task(self._run(steps))

    def release(self) -> bool:
        """The game captured its frames: leave HOLD (go back up)."""
        if not self.active:
            return False
        self._released.set()
        return True

    def request_abort(self, reason: str) -> bool:
        if not self.active:
            return False
        if not self._abort_reason:
            self._abort_reason = reason
        return True

    async def abort(self, reason: str, *, send_stop: bool = True) -> bool:
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
    async def _run(self, steps: list[_Step]) -> None:
        try:
            for step in steps:
                await self._do_step(step)
            self.last_result = "done"
            self._set_phase(ApproachPhase.IDLE, "done")
        except SequenceFault as f:
            await self._fault(str(f))
        except asyncio.CancelledError:
            await self._fault("sequence cancelled")
            raise
        except Exception as e:  # pragma: no cover - a bug must still end in a safe state
            log.exception("homework approach")
            await self._fault(f"internal error: {e}")
        finally:
            self._action = None
            self.active = False
            if self.lock.locked():
                self.lock.release()
            self._changed()

    def _check(self, step: _Step, t0: float) -> None:
        if self._abort_reason:
            raise SequenceFault(self._abort_reason)
        now = self.clock()
        p = self.params
        if now - self._t_start > p.total_timeout_s:
            raise SequenceFault(f"total timeout ({p.total_timeout_s:g} s) in {step.phase}")
        if step.kind != "hold" and now - t0 > p.step_timeout_s:
            raise SequenceFault(f"{step.phase} timeout ({p.step_timeout_s:g} s, {step.describe()})")
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
        lim, tol_xy, tol_z = self.limits, p.xy_tolerance_mm, p.z_tolerance
        if not (lim.x_min - tol_xy <= s.x <= lim.x_max + tol_xy and lim.y_min - tol_xy <= s.y <= lim.y_max + tol_xy):
            raise SequenceFault(f"sensor: XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
        if self.spot is not None and self._height(s.z) < self._height(self.spot.z) - tol_z:
            raise SequenceFault(f"Z {s.z:.1f} below the recorded spot {self.spot.z:g}")

    def _reached(self, step: _Step) -> bool:
        s = self.robot.snapshot()
        if step.kind == "xy":
            return math.hypot(s.x - step.x, s.y - step.y) <= self.params.xy_tolerance_mm and s.state == MachineState.IDLE
        return abs(s.z - step.z) <= self.params.z_tolerance and s.state not in (
            MachineState.Z_LOWERING, MachineState.Z_RAISING)

    async def _action_body(self, step: _Step) -> None:
        if self._abort_reason:
            raise RobotCommandError(f"not sent ({self._abort_reason})")
        if step.kind == "z":
            await self.robot.move_z(step.z)
        else:
            await self.robot.move_xy(step.x, step.y, self.params.xy_feed_mm_min)

    async def _do_step(self, step: _Step) -> None:
        self._set_phase(step.phase, step.describe())
        t0 = self.clock()
        self._check(step, t0)
        if step.kind == "hold":
            while not self._released.is_set():
                self._check(step, t0)
                if self.clock() - t0 > self.params.hold_timeout_s:
                    log.warning("homework approach: no capture within %.0f s, going back up",
                                self.params.hold_timeout_s)
                    return
                await asyncio.sleep(self.poll_s)
            return
        action = self._action = asyncio.get_running_loop().create_task(self._action_body(step))
        while True:
            self._check(step, t0)
            if action.done():
                exc = action.exception()
                if exc is not None:
                    raise SequenceFault(f"{step.phase} failed: {exc}")
                if self._reached(step):
                    return
            await asyncio.sleep(self.poll_s)

    async def _emergency_stop(self) -> None:
        if self._stop_sent:
            return
        self._stop_sent = True
        try:
            await self.robot.stop()
        except Exception as e:
            log.error("homework approach: emergency stop failed: %s", e)
            self.error += f" (stop failed: {e})"

    async def _fault(self, reason: str) -> None:
        action = self._action
        self.error = reason
        self.last_result = "fault"
        await self._emergency_stop()
        self._set_phase(ApproachPhase.FAULT, reason)
        log.error("homework approach: FAULT: %s", reason)
        if action is not None and not action.done():
            try:
                await asyncio.wait_for(asyncio.shield(action), ABORT_WAIT_S)
            except Exception:
                pass
            if not action.done():
                action.cancel()
        elif action is not None and action.done() and not action.cancelled():
            action.exception()
