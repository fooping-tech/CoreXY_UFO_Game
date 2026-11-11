"""Take the arm's (focus) camera close to the worksheet, then back.

    IDLE --start()--> RAISE -> MOVE_XY -> OPEN_CLAW -> LOWER -> HOLD -> RAISE_BACK
                      [-> CLOSE_CLAW] -> RETURN_XY -> IDLE
    any state --fault / stop--> FAULT (stop sent: ABORT, alarm, homing lost)

The place is a spot recorded by hand (`set_spot`: jog the arm above the worksheet
at the height wanted, record it), or a target XY (`start(target=...)`, e.g. a point
clicked in the overview image and mapped by camera_map.py, #78) looked at from the
recorded spot's height.

The arm hangs from the Z rope and its camera cable can tilt it, so a hanging camera may
not look straight down. With open_claw (default) the claws are opened before lowering
and the spot's Z is where the open claws stand on the worksheet: the arm rests on them,
upright (lowering a little further only slackens the rope; it presses with no more than
the arm's own weight). close_claw_after closes them again once back up.

HOLD waits for the game to capture its frames (`release()`), at most hold_timeout_s,
then the arm goes back up (and back to where it started).

Staged capture (#86, the study mode's HELP): `start(target, stages=[(name, z), ...])`
goes down in steps, highest first (camera 10 cm, 5 cm, the landing: study_mode/height.py),
and at each one waits settle_s for the swing to die down, then holds for that stage's
capture (`release(stage)` moves on; a release naming another stage is ignored). A hold
that times out (nobody captured) never goes further down: the lower stages are skipped
and the arm goes back up:

    RAISE -> MOVE_XY [-> OPEN_CLAW] -> (LOWER -> SETTLE -> HOLD) x stages -> RAISE_BACK
          [-> CLOSE_CLAW] -> RETURN_XY

all under one motion lock, so the game never sends jogs or moves of its own in between.
No recorded spot is needed; the lowest stage is the floor the arm must not pass. Same safety frame as
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
    OPEN_CLAW = "OPEN_CLAW"
    LOWER = "LOWER"
    HOLD = "HOLD"
    RAISE_BACK = "RAISE_BACK"
    CLOSE_CLAW = "CLOSE_CLAW"
    RETURN_XY = "RETURN_XY"
    SETTLE = "SETTLE"
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
    open_claw: bool = True  # stand the arm on its open claws: the camera looks straight down
    close_claw_after: bool = False
    claw_settle_s: float = 0.5  # after a claw turn, before the next step
    settle_s: float = 1.0  # staged capture: wait for the swing to die down before each capture

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "ApproachParams":
        hw = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        d = hw.get("approach") if isinstance(hw.get("approach"), dict) else {}
        feed = d.get("xy_feed_mm_min")
        return cls(xy_tolerance_mm=float(d.get("xy_tolerance_mm", 2.0)), z_tolerance=float(d.get("z_tolerance", 3.0)),
                   step_timeout_s=float(d.get("step_timeout_s", 30.0)), hold_timeout_s=float(d.get("hold_timeout_s", 15.0)),
                   total_timeout_s=float(d.get("total_timeout_s", 150.0)), return_xy=bool(d.get("return_xy", True)),
                   xy_feed_mm_min=float(feed) if feed is not None else None,
                   open_claw=bool(d.get("open_claw", True)), close_claw_after=bool(d.get("close_claw_after", False)),
                   claw_settle_s=float(d.get("claw_settle_s", 0.5)),
                   settle_s=max(float(d.get("settle_s", 1.0)), 0.0))


@dataclass(frozen=True)
class _Step:
    phase: str  # an ApproachPhase (or a subclass's phase)
    kind: str  # "z" | "xy" | "hold" | "claw" | "dwell" | "confirm"
    claw: str = ""
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    stage: str = ""  # staged capture: the stage this hold / move belongs to
    seconds: float = 0.0  # dwell length

    def describe(self) -> str:
        if self.kind == "z":
            return f"Z -> {self.z:g}"
        if self.kind == "xy":
            return f"XY -> ({self.x:g}, {self.y:g})"
        if self.kind == "claw":
            return f"claw -> {self.claw}"
        if self.kind == "dwell":
            return f"wait {self.seconds:g} s"
        if self.kind == "confirm":
            return "wait for the operator's confirmation"
        return "wait for the capture" + (f" ({self.stage})" if self.stage else "")


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
        self.target: tuple[float, float] | None = None  # XY of this run when not the spot's
        # staged capture (#86): [(name, z)] of this run, the stage held now, the floor of this run
        self.stages: list[tuple[str, float]] = []
        self.stage = ""
        self.holding = False
        self._floor_z: float | None = None
        self._skip_stages = False  # a staged hold timed out: no lower stage, straight back up

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
                "target": {"x": self.target[0], "y": self.target[1]} if self.target is not None else None,
                "stages": [{"name": n, "z": round(z, 2)} for n, z in self.stages],
                "stage": self.stage, "holding": self.holding,
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
    def preconditions(self, *, need_spot: bool = True, need_claw: bool | None = None) -> list[str]:
        errs: list[str] = []
        s = self.robot.snapshot()
        if self.active:
            errs.append("already approaching")
        if not need_spot:
            pass
        elif self.spot is None:
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
        if (self.params.open_claw if need_claw is None else need_claw) and (
                s.arm_closed_deg is None or s.arm_open_deg is None):
            errs.append("claw open / closed positions not recorded (arm_set), needed to stand the arm on "
                        "its open claws (or set homework.approach.open_claw false)")
        if not all(math.isfinite(v) for v in (s.x, s.y, s.z)):
            errs.append("sensor: position is not a number")
        elif not self.limits.xy_inside(s.x, s.y):
            errs.append(f"XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
        return errs

    async def start(self, target: tuple[float, float] | None = None,
                    stages: list[tuple[str, float]] | None = None, *, open_claw: bool | None = None) -> None:
        """Approach the recorded spot, or `target` XY at the recorded spot's height; with
        `stages` (staged capture, needs `target`) go down through those Z values instead."""
        if self.active:
            raise RobotCommandError("busy: already approaching")
        refresh = getattr(self.robot, "refresh_status", None)
        if refresh is not None:
            await refresh()
        use_claw = self.params.open_claw if open_claw is None else open_claw
        errs = self.preconditions(need_spot=not stages, need_claw=use_claw)
        if stages:
            if target is None:
                errs.append("a staged capture needs a target XY")
            lim = self.limits
            heights = [self._height(z) for _, z in stages]
            if any(not (math.isfinite(z) and lim.z_min <= z <= lim.z_max) for _, z in stages):
                errs.append("a stage's Z is outside the Z limits")
            elif any(b >= a for a, b in zip(heights, heights[1:])):
                errs.append("the stages must go down (highest first)")
        if target is not None:
            tx, ty = float(target[0]), float(target[1])
            if not (math.isfinite(tx) and math.isfinite(ty)):
                errs.append("target XY is not a number")
            elif not self.limits.xy_inside(tx, ty):
                errs.append(f"target XY ({tx:.1f},{ty:.1f}) outside the soft limits")
        if errs:
            raise RobotCommandError("approach refused: " + "; ".join(errs))
        if self.lock.locked():
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()
        s = self.robot.snapshot()
        top = self.top_z
        self.target = (float(target[0]), float(target[1])) if target is not None else None
        p = self.params
        self.stages = [(str(n), float(z)) for n, z in stages] if stages else []
        if self.stages:
            assert self.target is not None
            gx, gy = self.target
            self._floor_z = min((z for _, z in self.stages), key=self._height)
        else:
            assert self.spot is not None
            gx, gy = self.target if self.target is not None else (self.spot.x, self.spot.y)
            self._floor_z = self.spot.z
        steps = [_Step(ApproachPhase.RAISE, "z", z=top),
                 _Step(ApproachPhase.MOVE_XY, "xy", x=gx, y=gy)]
        if use_claw:
            steps.append(_Step(ApproachPhase.OPEN_CLAW, "claw", claw="open"))
        if self.stages:
            for name, z in self.stages:
                steps += [_Step(ApproachPhase.LOWER, "z", z=z, stage=name),
                          _Step(ApproachPhase.SETTLE, "dwell", stage=name, seconds=p.settle_s),
                          _Step(ApproachPhase.HOLD, "hold", stage=name)]
        else:
            steps += [_Step(ApproachPhase.LOWER, "z", z=self.spot.z),  # type: ignore[union-attr]
                      _Step(ApproachPhase.HOLD, "hold")]
        steps.append(_Step(ApproachPhase.RAISE_BACK, "z", z=top))
        if use_claw and p.close_claw_after:
            steps.append(_Step(ApproachPhase.CLOSE_CLAW, "claw", claw="closed"))
        if self.params.return_xy and math.hypot(s.x - gx, s.y - gy) > self.params.xy_tolerance_mm:
            steps.append(_Step(ApproachPhase.RETURN_XY, "xy", x=s.x, y=s.y))
        self.active = True
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._stop_sent = False
        self._released.clear()
        self._skip_stages = False
        self.stage = ""
        self.holding = False
        self._t_start = self.clock()
        self._task = asyncio.get_running_loop().create_task(self._run(steps))

    def release(self, stage: str = "") -> bool:
        """The game captured its frames: leave HOLD (go back up, or on to the next stage).
        A release naming a stage other than the one held now is ignored (a late one)."""
        if not self.active:
            return False
        if stage and (not self.holding or stage != self.stage):
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
                if self._skip_stages and step.stage:
                    continue  # a staged hold timed out: skip the lower stages
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
            self.holding = False
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
        floor = self._floor_z
        if floor is not None and self._height(s.z) < self._height(floor) - tol_z:
            raise SequenceFault(f"Z {s.z:.1f} below the lowest point of this run {floor:g}")

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
        elif step.kind == "claw":
            await self.robot.arm_goto(step.claw)
        else:
            await self.robot.move_xy(step.x, step.y, self.params.xy_feed_mm_min)

    async def _do_step(self, step: _Step) -> None:
        if step.stage:
            self.stage = step.stage
        self.holding = step.kind == "hold"
        if step.kind == "hold" and self.stages:
            self._released.clear()  # each stage waits for its own release (unstaged: as before)
        self._set_phase(step.phase, step.describe())
        t0 = self.clock()
        self._check(step, t0)
        if step.kind == "hold":
            try:
                while not self._released.is_set():
                    self._check(step, t0)
                    if self.clock() - t0 > self.params.hold_timeout_s:
                        if self.stages:
                            self._skip_stages = True
                        log.warning("homework approach: no capture within %.0f s, going back up",
                                    self.params.hold_timeout_s)
                        return
                    await asyncio.sleep(self.poll_s)
            finally:
                self.holding = False
            return
        if step.kind == "dwell":
            while self.clock() - t0 < step.seconds:
                self._check(step, t0)
                await asyncio.sleep(self.poll_s)
            return
        action = self._action = asyncio.get_running_loop().create_task(self._action_body(step))
        while True:
            self._check(step, t0)
            if action.done():
                exc = action.exception()
                if exc is not None:
                    raise SequenceFault(f"{step.phase} failed: {exc}")
                if step.kind == "claw":
                    # the servo command reported PASS: let the claws settle, still checking
                    t_done = self.clock()
                    while self.clock() - t_done < self.params.claw_settle_s:
                        self._check(step, t0)
                        await asyncio.sleep(self.poll_s)
                    return
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
