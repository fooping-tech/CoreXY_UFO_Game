"""The study mode's tidy-up (#86): the claw picks up a magnet jig, sweeps a fixed route,
drops what stuck to it at the collection spot, puts the jig back and parks.

    IDLE --start()--> RAISE -> TO_JIG -> OPEN_CLAW -> LOWER_TO_JIG -> GRIP -> CONFIRM_GRIP
        -> LIFT_JIG -> SWEEP (each waypoint) -> TO_COLLECT -> LOWER_TO_COLLECT -> COLLECT
        -> LIFT -> BACK_TO_JIG -> LOWER_JIG -> RELEASE_JIG -> RAISE_EMPTY -> PARK -> IDLE
    any state --fault / stop / timeout--> FAULT (the robot's stop: ABORT)

Only a fixed, calibrated route: no free search. The grip is never judged by itself
(there is no sensor): CONFIRM_GRIP waits for a grown-up's confirmation (`confirm()`,
the game's Enter key) and faults after grip_confirm_timeout_s. Only magnetic test
objects (paper clips) are collected; pencils and erasers are not attracted.

Same safety frame as the homework approach (it subclasses ApproachSequencer): checked
preconditions, the server's motion lock for the whole run, every poll checks abort /
timeouts / connection / motors / alarm / homing / position / the floor. The route is
checked before anything moves: every point inside the soft limits, every segment clear
of the keep-out rectangles.

`real` (the real crane) is refused until `enabled` is true and every `confirmed` item
was set by hand after measuring it there. `dry_run` drives the mock robot only.
"""

from __future__ import annotations

import asyncio
import logging
import math
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from ..config import RobotLimits
from ..homework.approach import ApproachParams, ApproachSequencer, SequenceFault, _Step
from ..robot.interface import RobotCommandError, RobotInterface

log = logging.getLogger(__name__)

CONFIRM_KEYS = ("jig_xy", "jig_grip_z", "route", "collect", "speeds")


class CleanupPhase:
    RAISE = "RAISE"
    TO_JIG = "TO_JIG"
    OPEN_CLAW = "OPEN_CLAW"
    LOWER_TO_JIG = "LOWER_TO_JIG"
    GRIP = "GRIP"
    CONFIRM_GRIP = "CONFIRM_GRIP"
    LIFT_JIG = "LIFT_JIG"
    SWEEP = "SWEEP"
    TO_COLLECT = "TO_COLLECT"
    LOWER_TO_COLLECT = "LOWER_TO_COLLECT"
    COLLECT = "COLLECT"
    LIFT = "LIFT"
    BACK_TO_JIG = "BACK_TO_JIG"
    LOWER_JIG = "LOWER_JIG"
    RELEASE_JIG = "RELEASE_JIG"
    RAISE_EMPTY = "RAISE_EMPTY"
    PARK = "PARK"


@dataclass(frozen=True)
class CleanupProfile:
    enabled: bool = False
    jig_xy: tuple[float, float] | None = None
    jig_grip_z: float | None = None
    travel_z: float | None = None
    safe_z: float | None = None
    claw_grip: str = "closed"
    claw_release: str = "open"
    route_xy: tuple[tuple[float, float], ...] = ()
    collect_xy: tuple[float, float] | None = None
    collect_z: float | None = None
    collect_dwell_s: float = 1.0
    park_xy: tuple[float, float] | None = None
    keep_out: tuple[tuple[float, float, float, float], ...] = ()
    xy_feed_mm_min: float | None = None
    step_timeout_s: float | None = None
    total_timeout_s: float | None = None
    grip_confirm_timeout_s: float = 60.0
    auto_confirm_grip_s: float | None = None  # dry run only: confirm by itself after this
    confirmed: dict = field(default_factory=dict)
    profile: str = "real"

    @classmethod
    def from_raw(cls, raw: dict[str, Any], profile: str) -> "CleanupProfile":
        sm = raw.get("study_mode") if isinstance(raw.get("study_mode"), dict) else {}
        c = sm.get("cleanup") if isinstance(sm.get("cleanup"), dict) else {}
        d = c.get(profile) if isinstance(c.get(profile), dict) else {}

        def num(key: str) -> float | None:
            v = d.get(key)
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None

        def xy(key: str) -> tuple[float, float] | None:
            v = d.get(key)
            if isinstance(v, list) and len(v) == 2 and all(isinstance(a, (int, float)) for a in v):
                return float(v[0]), float(v[1])
            return None
        route = tuple((float(a), float(b)) for a, b in d.get("route_xy") or [])
        keep = tuple(tuple(float(v) for v in r) for r in d.get("keep_out") or [] if len(r) == 4)
        conf = d.get("confirmed") if isinstance(d.get("confirmed"), dict) else {}
        auto = num("auto_confirm_grip_s") if profile == "dry_run" else None
        return cls(enabled=bool(c.get("enabled_real", False)) if profile == "real" else True,
                   jig_xy=xy("jig_xy"), jig_grip_z=num("jig_grip_z"), travel_z=num("travel_z"), safe_z=num("safe_z"),
                   claw_grip=str(d.get("claw_grip", "closed")), claw_release=str(d.get("claw_release", "open")),
                   route_xy=route, collect_xy=xy("collect_xy"), collect_z=num("collect_z"),
                   collect_dwell_s=float(d.get("collect_dwell_s", 1.0) or 0.0), park_xy=xy("park_xy"),
                   keep_out=keep, xy_feed_mm_min=num("xy_feed_mm_min"), step_timeout_s=num("step_timeout_s"),
                   total_timeout_s=num("total_timeout_s"),
                   grip_confirm_timeout_s=float(d.get("grip_confirm_timeout_s", 60.0) or 60.0),
                   auto_confirm_grip_s=auto, confirmed={k: bool(conf.get(k, False)) for k in CONFIRM_KEYS},
                   profile=profile)

    def problems(self, limits: RobotLimits) -> list[str]:
        """Why this profile may not run ([] = it may)."""
        errs: list[str] = []
        if self.profile == "real":
            if not self.enabled:
                errs.append("the tidy-up is off on the real robot (study_mode.cleanup.enabled_real)")
            unconfirmed = [k for k in CONFIRM_KEYS if not self.confirmed.get(k, False)]
            if unconfirmed:
                errs.append("not confirmed on the robot: " + ", ".join(unconfirmed))
        need = {"jig_xy": self.jig_xy, "jig_grip_z": self.jig_grip_z, "travel_z": self.travel_z,
                "safe_z": self.safe_z, "collect_xy": self.collect_xy, "collect_z": self.collect_z,
                "park_xy": self.park_xy, "step_timeout_s": self.step_timeout_s,
                "total_timeout_s": self.total_timeout_s}
        missing = [k for k, v in need.items() if v is None]
        if missing:
            errs.append("not set: " + ", ".join(missing))
        if not self.route_xy:
            errs.append("no sweep route (route_xy)")
        if errs:
            return errs
        for name in ("jig_grip_z", "travel_z", "safe_z", "collect_z"):
            z = getattr(self, name)
            if not limits.z_min <= z <= limits.z_max:
                errs.append(f"{name} {z:g} outside {limits.z_min:g}..{limits.z_max:g}")
        up = 1.0 if limits.z_up_is_positive else -1.0
        if not up * self.safe_z >= up * self.travel_z > up * self.jig_grip_z:  # type: ignore[operator]
            errs.append("heights must be safe_z >= travel_z > jig_grip_z")
        pts = self.path()
        for x, y in pts:
            if not (math.isfinite(x) and math.isfinite(y) and limits.xy_inside(x, y)):
                errs.append(f"point ({x:g},{y:g}) outside the soft limits")
        for a, b in zip(pts, pts[1:]):
            for r in self.keep_out:
                if segment_hits_rect(a, b, r):
                    errs.append(f"segment {a}->{b} crosses the keep-out area {r}")
        return errs

    def path(self) -> list[tuple[float, float]]:
        """Every XY the run visits, in order (after the start point)."""
        if self.jig_xy is None or self.collect_xy is None or self.park_xy is None:
            return list(self.route_xy)
        return [self.jig_xy, *self.route_xy, self.collect_xy, self.jig_xy, self.park_xy]


def segment_hits_rect(a: tuple[float, float], b: tuple[float, float], r: tuple[float, float, float, float]) -> bool:
    """Does the segment a-b touch the rectangle (x0, y0, x1, y1)? (Liang-Barsky clipping)"""
    x0, y0, x1, y1 = min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])
    dx, dy = b[0] - a[0], b[1] - a[1]
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, a[0] - x0), (dx, x1 - a[0]), (-dy, a[1] - y0), (dy, y1 - a[1])):
        if p == 0:
            if q < 0:
                return False
            continue
        t = q / p
        if p < 0:
            t0 = max(t0, t)
        else:
            t1 = min(t1, t)
        if t0 > t1:
            return False
    return True


class CleanupSequencer(ApproachSequencer):
    """Runs the tidy-up route. Shares the server's motion lock with the other sequences."""

    def __init__(self, robot: RobotInterface, limits: RobotLimits, profile: CleanupProfile, *,
                 lock=None, is_jogging: Callable[[], bool] = lambda: False,
                 other_active: Callable[[], bool] = lambda: False,
                 on_change: Callable[[dict], None] | None = None,
                 poll_s: float = 0.02, clock: Callable[[], float] = time.monotonic) -> None:
        params = ApproachParams(step_timeout_s=profile.step_timeout_s or 30.0,
                                total_timeout_s=profile.total_timeout_s or 240.0,
                                xy_feed_mm_min=profile.xy_feed_mm_min, return_xy=False, open_claw=False)
        super().__init__(robot, limits, params, spot_path=None, lock=lock, is_jogging=is_jogging,
                         other_active=other_active, on_change=on_change, poll_s=poll_s, clock=clock)
        self.profile = profile
        self.confirming = False
        self.waypoint = 0  # 1-based index of the sweep waypoint being driven to (0 = not sweeping)
        self._confirmed = False

    def status(self) -> dict:
        d = super().status()
        d.pop("spot", None)
        d.pop("stages", None)
        d.update({"profile": self.profile.profile, "confirming": self.confirming, "waypoint": self.waypoint,
                  "waypoints": len(self.profile.route_xy), "problems": self.profile.problems(self.limits)})
        return d

    async def start(self, target=None, stages=None, *, open_claw=None) -> None:  # type: ignore[override]
        if self.active:
            raise RobotCommandError("busy: already tidying up")
        refresh = getattr(self.robot, "refresh_status", None)
        if refresh is not None:
            await refresh()
        prof = self.profile
        errs = self.profile.problems(self.limits)
        errs += [e.replace("already approaching", "already tidying up")
                 for e in self.preconditions(need_spot=False, need_claw=True)]
        if errs:
            raise RobotCommandError("tidy-up refused: " + "; ".join(errs))
        if self.lock.locked():
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()
        assert prof.jig_xy and prof.collect_xy and prof.park_xy
        jx, jy = prof.jig_xy
        steps = [_Step(CleanupPhase.RAISE, "z", z=prof.safe_z),  # type: ignore[arg-type]
                 _Step(CleanupPhase.TO_JIG, "xy", x=jx, y=jy),
                 _Step(CleanupPhase.OPEN_CLAW, "claw", claw=prof.claw_release),
                 _Step(CleanupPhase.LOWER_TO_JIG, "z", z=prof.jig_grip_z),  # type: ignore[arg-type]
                 _Step(CleanupPhase.GRIP, "claw", claw=prof.claw_grip),
                 _Step(CleanupPhase.CONFIRM_GRIP, "confirm", seconds=prof.grip_confirm_timeout_s),
                 _Step(CleanupPhase.LIFT_JIG, "z", z=prof.travel_z)]  # type: ignore[arg-type]
        for i, (x, y) in enumerate(prof.route_xy):
            steps.append(_Step(CleanupPhase.SWEEP, "xy", x=x, y=y, stage=str(i + 1)))
        steps += [_Step(CleanupPhase.TO_COLLECT, "xy", x=prof.collect_xy[0], y=prof.collect_xy[1]),
                  _Step(CleanupPhase.LOWER_TO_COLLECT, "z", z=prof.collect_z),  # type: ignore[arg-type]
                  _Step(CleanupPhase.COLLECT, "dwell", seconds=prof.collect_dwell_s),
                  _Step(CleanupPhase.LIFT, "z", z=prof.travel_z),  # type: ignore[arg-type]
                  _Step(CleanupPhase.BACK_TO_JIG, "xy", x=jx, y=jy),
                  _Step(CleanupPhase.LOWER_JIG, "z", z=prof.jig_grip_z),  # type: ignore[arg-type]
                  _Step(CleanupPhase.RELEASE_JIG, "claw", claw=prof.claw_release),
                  _Step(CleanupPhase.RAISE_EMPTY, "z", z=prof.safe_z),  # type: ignore[arg-type]
                  _Step(CleanupPhase.PARK, "xy", x=prof.park_xy[0], y=prof.park_xy[1])]
        self.target = None
        self.stages = []
        self._floor_z = min((prof.jig_grip_z, prof.collect_z), key=self._height)  # type: ignore[arg-type]
        self.active = True
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._stop_sent = False
        self._confirmed = False
        self.confirming = False
        self.waypoint = 0
        self.stage = ""
        self._t_start = self.clock()
        self._task = asyncio.get_running_loop().create_task(self._run(steps))

    def confirm(self) -> bool:
        """A grown-up saw the claw holding the jig: go on."""
        if not (self.active and self.confirming):
            return False
        self._confirmed = True
        return True

    async def _do_step(self, step: _Step) -> None:
        self.waypoint = int(step.stage) if step.phase == CleanupPhase.SWEEP else 0
        if step.kind != "confirm":
            await super()._do_step(step)
            return
        self.confirming = True
        self._set_phase(step.phase, step.describe())
        t0 = self.clock()
        try:
            while not self._confirmed:
                self._check(step, t0)
                waited = self.clock() - t0
                auto = self.profile.auto_confirm_grip_s
                if auto is not None and waited >= auto:
                    log.info("tidy-up (dry run): grip confirmed by itself after %.1f s", waited)
                    break
                if waited > step.seconds:
                    raise SequenceFault(f"the jig grip was not confirmed within {step.seconds:g} s")
                await asyncio.sleep(self.poll_s)
        finally:
            self.confirming = False

    def _check(self, step: _Step, t0: float) -> None:
        if step.kind == "confirm":
            # the operator may take longer than a move's step timeout: only the confirm timeout counts
            step = _Step(step.phase, "hold")
        super()._check(step, t0)
