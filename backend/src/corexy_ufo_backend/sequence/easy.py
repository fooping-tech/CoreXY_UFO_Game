"""The score game's easy mode (#169): catch on the spot, wait for the destination, carry.

    MANUAL_XY --start_grab()--> AUTO_GRAB: OPEN_CLAW -> LOWER_TO_CATCH -> CLOSE_CLAW -> RAISE_WITH_ITEM
        -> WAIT_DESTINATION --choose(1)--> DELIVER_DIAL_1: (at the safe height?) MOVE_TO_DIAL
        -> LOWER_TO_RELEASE -> RELEASE -> RAISE_EMPTY -> MANUAL_XY
    MANUAL_XY --start_grab() with the arm below the safe height--> AUTO_GRAB: CLOSE_CLAW -> RAISE_WITH_ITEM
        -> WAIT_DESTINATION ... (#177: the easy mode has no way to raise the arm by hand, so a fist
        with the arm down closes the claw where it is and brings it up)
    MANUAL_XY --start_reset()--> RESET: OPEN_CLAW -> RAISE_EMPTY -> MANUAL_XY (#177: the start of a
        game: the claw open, the arm at the top, from whatever height it was left at)
    WAIT_DESTINATION --cancel()--> CANCEL: RELEASE (the claw opens where it is, at the safe height)
        -> MANUAL_XY (#179: the catch missed the capsule: let go and try again)
    WAIT_DESTINATION --nothing chosen in wait_destination_s--> EXPIRED
    WAIT_DESTINATION --stop_waiting() (the game's stop key)--> STOPPED: like EXPIRED, nothing is
        moving, so nothing has to be cut with ABORT: no alarm, homing kept, the claw still closed
        (#179). In every moving state the stop key is still FAULT + ABORT: the firmware's STOP
        does not stop the servos (Z drum, claw), only ABORT does.
    any state --fault / stop / the operator gone--> FAULT (ABORT sent: alarm, homing lost)

One run of one task: the server's motion lock is held from the catch to the end of the
delivery (the wait included), so manual moves, jogs and every other sequence are refused
all the way. It is the auto catch's state machine (AutoCatchSequencer) with other steps:
the same completion checks, the same monitoring on every poll (abort request, timeouts,
connection, motors, alarm, homing, limit switches, the position inside the soft limits and
above z_floor), the same FAULT + ABORT.

What it never does:
  - move, open the claw or let go by itself when nobody chose: EXPIRED ends the run with
    the claw still closed and nothing sent (no ABORT either: nothing is moving). The lock is
    given back so a person can put things right by hand;
  - take a choice that is not for this catch: choose() needs this catch's grab_id, only
    while it waits, only once;
  - claim a capsule: a finished catch means the claw closed and came up, a finished
    delivery that it opened over the Dial. Whether a capsule was held or landed is not
    known here (the Dial's BALL_RECEIVED says so, to the game).

Where the Dials are (`EasyParams`): the real crane's are measured on the machine and saved
in calibration.json#easy_dials (the 校正 tab), and count only once confirmed there; the
dry run's are made up in game_config.json game_mode.easy.dry_run.

The catch's profile (an AutoCatchParams: heights, claw, speeds, timeouts, tolerances):
  dry run   the auto catch's dry_run profile.
  real      `real_catch_params`: every hardware fact is one the 校正 tab measured on this
            machine: the catch and release heights recorded there (easy_dials), the travel
            height = the Z top record, the Z scale and direction from the Z calibration, the
            claw's recorded positions, the Dials' XY. What is not a fact of the machine (the
            timeouts, the tolerances, the XY feed = the backend's usual one) comes from
            game_mode.easy.real. It counts as confirmed only when the easy_dials are; a Z
            measured again since makes the recorded heights stale (record them again).
            It does not use auto_catch.real (the one-button catch's own, with its rescue box).
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
import math
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

from ..config import BackendConfig, RobotLimits
from ..robot.interface import RobotCommandError, RobotInterface
from .auto_catch import AutoCatchSequencer, Step
from .fault import SequenceFault
from .params import AutoCatchParams, height

log = logging.getLogger(__name__)

CANCELLED = -1  # the "destination" of a catch given up (cancel())
STOPPED = -2  # the wait ended by the stop key (stop_waiting())
# #200: the only portal is Dial 1, on the left of the screen. (Dial 2, the right, is gone: a
# dial_2 still saved in an older calibration.json#easy_dials is not read.)
DESTINATIONS = (1,)
WAIT_KEY = "wait_destination"
WAIT_MARGIN_S = 5.0  # the monitoring's own timeout of the wait: never reached before the expiry


class EasyPhase(StrEnum):
    IDLE = "IDLE"
    OPEN_CLAW = "OPEN_CLAW"
    LOWER_TO_CATCH = "LOWER_TO_CATCH"
    CLOSE_CLAW = "CLOSE_CLAW"
    RAISE_WITH_ITEM = "RAISE_WITH_ITEM"
    WAIT_DESTINATION = "WAIT_DESTINATION"
    MOVE_TO_DIAL = "MOVE_TO_DIAL"
    LOWER_TO_RELEASE = "LOWER_TO_RELEASE"
    RELEASE = "RELEASE"
    RAISE_EMPTY = "RAISE_EMPTY"
    EXPIRED = "EXPIRED"
    STOPPED = "STOPPED"
    FAULT = "FAULT"


class _Expired(Exception):
    """Nobody chose a destination in time."""


def _xy(v: Any) -> tuple[float, float] | None:
    if isinstance(v, dict):
        v = [v.get("x"), v.get("y")]
    if (isinstance(v, (list, tuple)) and len(v) == 2
            and all(isinstance(a, (int, float)) and not isinstance(a, bool) and math.isfinite(a) for a in v)):
        return float(v[0]), float(v[1])
    return None


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


@dataclass(frozen=True)
class EasyParams:
    """Where a capsule is let go (over the Dial), and how long a choice is waited for."""
    profile: str = "dry_run"
    dials: dict[int, tuple[float, float] | None] = field(default_factory=lambda: {n: None for n in DESTINATIONS})
    release_z: float | None = None
    wait_destination_s: float = 15.0
    # #299: no longer asked for (the 校正 tab's 確かめた step was removed): what is recorded is used.
    # Kept so a file of an older version still reads.
    confirmed: bool = True
    # real only: where the claw closes = the Z bottom record (#299: the 校正 tab's 下に記録; the
    # server sets it from the Z calibration, None while Z has no bottom). The dry run: auto_catch.dry_run
    catch_z: float | None = None
    stale_z: bool = False  # real only: Z was measured again since the release height was recorded
    saved_at: str = ""  # when the values were last recorded (shown: "the last session's values")
    # #270: no catch that goes down within this many mm (XY) of a portal (0 = no keep-out)
    portal_keepout_mm: float = 60.0

    @classmethod
    def from_raw(cls, raw: dict[str, Any] | None, profile: str, saved: dict[str, Any] | None = None) -> "EasyParams":
        """dry_run: game_config.json game_mode.easy.dry_run. real: only `saved`
        (calibration.json#easy_dials); nothing of the config stands in for a measurement. The real
        catch height is not read from the file (#299: it is the Z bottom; see the server)."""
        gm = (raw or {}).get("game_mode")
        e = gm.get("easy") if isinstance(gm, dict) and isinstance(gm.get("easy"), dict) else {}
        wait = _num(e.get("wait_destination_s"))
        keep = _num(e.get("portal_keepout_mm"))
        d = (saved if profile == "real" else e.get("dry_run")) or {}
        if not isinstance(d, dict):
            d = {}
        return cls(profile=profile, dials={n: _xy(d.get(f"dial_{n}")) for n in DESTINATIONS},
                   release_z=_num(d.get("release_z")), wait_destination_s=wait if wait is not None else 15.0,
                   confirmed=True,
                   catch_z=None,
                   saved_at=str(d.get("saved_at", "")) if profile == "real" else "",
                   portal_keepout_mm=max(keep, 0.0) if keep is not None else 60.0)

    def near_portal(self, x: float, y: float) -> str:
        """#270: "" or why a catch may not go down at (x, y): too near a portal's XY."""
        if self.portal_keepout_mm <= 0 or not (math.isfinite(x) and math.isfinite(y)):
            return ""
        for n in DESTINATIONS:
            d = self.dials.get(n)
            if d is None:
                continue
            dist = math.hypot(x - d[0], y - d[1])
            if dist < self.portal_keepout_mm:
                return f"near the portal (Dial {n}, {dist:.0f} mm < {self.portal_keepout_mm:g} mm)"
        return ""

    def problems(self, catch: AutoCatchParams, limits: RobotLimits, *, need_confirmed: bool = True) -> list[str]:
        """Why a delivery may not run with these values ([] = it may)."""
        errs: list[str] = []
        for n in DESTINATIONS:
            xy = self.dials.get(n)
            if xy is None:
                errs.append(f"Dial {n} drop point is not recorded")
            elif not limits.xy_inside(*xy):
                errs.append(f"Dial {n} drop point ({xy[0]:g},{xy[1]:g}) outside the XY soft limits")
        if self.profile == "real" and self.catch_z is None:
            errs.append("the catch height (the Z bottom) is not recorded")
        if self.profile == "real" and self.stale_z:
            errs.append("Z was measured again since the release height was recorded: record the release height again")
        if self.release_z is None:
            errs.append("the Dial's release height is not recorded")
        elif not limits.z_min <= self.release_z <= limits.z_max:
            errs.append(f"release height {self.release_z:g} outside Z range {limits.z_min:g}..{limits.z_max:g}")
        elif catch.safe_z is not None and catch.z_floor is not None:
            h = lambda z: height(z, limits)  # noqa: E731
            if h(self.release_z) < h(catch.z_floor):
                errs.append(f"release height {self.release_z:g} is below z_floor {catch.z_floor:g}")
            if h(self.release_z) > h(catch.safe_z):
                errs.append(f"release height {self.release_z:g} is above safe_z {catch.safe_z:g}")
            if catch.max_drop_units is not None and h(catch.safe_z) - h(self.release_z) > catch.max_drop_units:
                errs.append(f"release height: descent {h(catch.safe_z) - h(self.release_z):.1f} > max_drop_units "
                            f"{catch.max_drop_units:g}")
        if not (math.isfinite(self.wait_destination_s) and self.wait_destination_s > 0):
            errs.append("wait_destination_s must be > 0")
        if self.profile == "real" and need_confirmed and not self.confirmed:
            errs.append("the Dial's drop point is not confirmed on the real machine (校正 tab)")
        return errs

    def as_dict(self) -> dict:
        return {"profile": self.profile,
                **{f"dial_{n}": list(self.dials[n]) if self.dials.get(n) else None for n in DESTINATIONS},
                "release_z": self.release_z,
                "wait_destination_s": self.wait_destination_s, "confirmed": self.confirmed,
                "catch_z": self.catch_z, "stale_z": self.stale_z, "saved_at": self.saved_at}


# What is not a fact of the machine, when game_mode.easy.real leaves it out.
REAL_DEFAULTS = {"xy_tolerance_mm": 1.0, "z_tolerance": 1.0, "claw_settle_s": 0.5, "claw_span_min_deg": 5.0,
                 "claw_span_max_deg": 355.0, "limit_home_zone_mm": 5.0, "total_timeout_s": 120.0}
REAL_TIMEOUTS = {"open_claw": 6.0, "lower_to_catch": 20.0, "close_claw": 6.0, "raise_with_item": 20.0,
                 "move_to_box": 45.0, "lower_to_release": 20.0, "release": 6.0, "raise_empty": 20.0, "claw_standby": 6.0}


def real_catch_params(raw: dict[str, Any] | None, easy: EasyParams, limits: RobotLimits,
                      backend: BackendConfig | None) -> AutoCatchParams:
    """The real crane's catch profile for the easy mode, from what the 校正 tab measured.
    Missing measurements stay None (validate() then refuses it): nothing is guessed."""
    gm = (raw or {}).get("game_mode")
    e = gm.get("easy") if isinstance(gm, dict) and isinstance(gm.get("easy"), dict) else {}
    r = e.get("real") if isinstance(e.get("real"), dict) else {}
    p = AutoCatchParams(profile="real")
    for k, v in REAL_DEFAULTS.items():
        n = _num(r.get(k))
        setattr(p, k, n if n is not None else v)
    t = r.get("timeouts_s") if isinstance(r.get("timeouts_s"), dict) else {}
    p.timeouts_s = {k: (_num(t.get(k)) or v) for k, v in REAL_TIMEOUTS.items()}
    # the carry to a Dial is the only XY move of the easy mode: the quick feed (#179)
    feed = _num(r.get("xy_feed_mm_min")) or (backend.fast_feed() if backend is not None else None)
    p.xy_feed_mm_min = p.xy_feed_max_mm_min = feed
    p.button_debounce_ms = 0.0
    p.claw_standby = None
    # the travel height: the Z top record (the arm wound all the way up)
    p.safe_z = limits.z_max if limits.z_up_is_positive else limits.z_min
    p.catch_z = easy.catch_z
    p.release_z = easy.release_z
    if easy.catch_z is not None and easy.release_z is not None:
        h = lambda z: height(z, limits)  # noqa: E731
        p.z_floor = min((easy.catch_z, easy.release_z), key=h)  # never below the lower of the two
        drop = h(p.safe_z) - h(p.z_floor)
        p.max_drop_units = drop + p.z_tolerance  # exactly the recorded descent, no more
        cpu = backend.z_counts_per_unit if backend is not None else 0.0
        p.max_drum_turns = p.max_drop_units * cpu / 4096 * 1.05 + 0.05
    if easy.dials.get(1) is not None:
        p.box_x_mm, p.box_y_mm = easy.dials[1]  # (the auto catch's box: not used here, must be valid)
    # every confirm item is covered by a measurement of the 校正 tab, watched by a person there
    from .params import CONFIRM_KEYS
    # (#299: recorded is used, no separate confirmation; a release height of an older Z is not)
    p.confirmed = {k: easy.confirmed and not easy.stale_z for k in CONFIRM_KEYS}
    return p


def grab_steps(p: AutoCatchParams) -> list[Step]:
    return [Step(EasyPhase.OPEN_CLAW, "open_claw", "claw", claw=p.claw_open),  # type: ignore[arg-type]
            Step(EasyPhase.LOWER_TO_CATCH, "lower_to_catch", "z", z=float(p.catch_z)),  # type: ignore[arg-type]
            Step(EasyPhase.CLOSE_CLAW, "close_claw", "claw", claw=p.claw_close),  # type: ignore[arg-type]
            Step(EasyPhase.RAISE_WITH_ITEM, "raise_with_item", "z", z=float(p.safe_z))]  # type: ignore[arg-type]


def low_grab_steps(p: AutoCatchParams) -> list[Step]:
    """The arm is already down: close where it is, and up. Nothing goes down."""
    return [Step(EasyPhase.CLOSE_CLAW, "close_claw", "claw", claw=p.claw_close),  # type: ignore[arg-type]
            Step(EasyPhase.RAISE_WITH_ITEM, "raise_with_item", "z", z=float(p.safe_z))]  # type: ignore[arg-type]


def reset_steps(p: AutoCatchParams) -> list[Step]:
    """To the start: the claw open (what it held is let go where it is, not from the top), and up."""
    return [Step(EasyPhase.OPEN_CLAW, "open_claw", "claw", claw=p.claw_open),  # type: ignore[arg-type]
            Step(EasyPhase.RAISE_EMPTY, "raise_empty", "z", z=float(p.safe_z))]  # type: ignore[arg-type]


def deliver_steps(p: AutoCatchParams, e: EasyParams, destination: int) -> list[Step]:
    x, y = e.dials[destination]  # type: ignore[misc]
    return [Step(EasyPhase.MOVE_TO_DIAL, "move_to_box", "xy", x=x, y=y),  # type: ignore[arg-type]
            Step(EasyPhase.LOWER_TO_RELEASE, "lower_to_release", "z", z=float(e.release_z)),  # type: ignore[arg-type]
            Step(EasyPhase.RELEASE, "release", "claw", claw=p.claw_open),  # type: ignore[arg-type]
            Step(EasyPhase.RAISE_EMPTY, "raise_empty", "z", z=float(p.safe_z))]  # type: ignore[arg-type]


class EasySequencer(AutoCatchSequencer):
    label = "easy_mode"

    def __init__(self, robot: RobotInterface, params: AutoCatchParams, limits: RobotLimits,
                 backend: BackendConfig | None = None, *, easy: EasyParams | None = None,
                 lock: asyncio.Lock | None = None, is_jogging: Callable[[], bool] = lambda: False,
                 other_active: Callable[[], bool] = lambda: False,
                 on_change: Callable[[dict], None] | None = None,
                 poll_s: float = 0.02, clock: Callable[[], float] = time.monotonic) -> None:
        super().__init__(robot, params, limits, backend, lock=lock, is_jogging=is_jogging, on_change=on_change,
                         poll_s=poll_s, clock=clock)
        self.phase = EasyPhase.IDLE  # type: ignore[assignment]
        self.other_active = other_active
        self.state = "MANUAL_XY"
        self.destination = 0
        self.grab_id = ""
        self._chosen = 0
        self._t_begin = 0.0
        self._t_wait = 0.0
        self._reset_only = False
        self._stop_reason = ""
        self._strict: AutoCatchParams | None = None  # the params as validated, while a run uses relaxed ones
        self.easy = easy or EasyParams(profile=params.profile)
        self.set_easy(self.easy)

    def set_easy(self, easy: EasyParams, params: AutoCatchParams | None = None) -> None:
        """New drop points (the 校正 tab recorded one), and with them the catch's profile when it
        is built from them (the real crane). Never while a run uses the old ones."""
        if self.active:
            raise RobotCommandError("busy: the easy mode's catch is running")
        self.easy = easy
        if params is not None:
            self.params = params
        # the wait's own entry in the timeouts the monitoring reads (see _wait_destination)
        self.params = dataclasses.replace(self.params, timeouts_s={
            **self.params.timeouts_s, WAIT_KEY: max(easy.wait_destination_s, 0.0) + WAIT_MARGIN_S})

    # ------------------------------------------------------------------ status
    def problems(self) -> list[str]:
        """Why the easy mode cannot run with the values it has (the robot's state aside)."""
        from .params import validate
        errs = self.easy.problems(self.params, self.limits)
        return errs + [e for e in validate(self.params, self.limits, self.backend) if e not in errs]

    # what is only a moment's (another motion, a jog, a run going on): not a reason to hold a game back
    _PASSING = ("busy", "robot busy", "auto catch already running")

    def blockers(self) -> list[str]:
        """#275: why a catch would be refused now, the robot's state included (homing, alarm,
        motors, the Z reference, the claw, the recorded values), but not what passes by itself
        (another motion, a jog). The game starts no score game while there is one. [] while a
        run goes on (it was allowed)."""
        if self.active:
            return []
        errs = self.preconditions(any_height=True) + self.easy.problems(self.params, self.limits)
        return [e for e in dict.fromkeys(errs) if not e.startswith(self._PASSING)]

    def status(self) -> dict:
        now = self.clock()
        waiting = self.active and self.state == "WAIT_DESTINATION"
        return {
            "blockers": self.blockers(),
            "active": self.active,
            "state": self.state,
            "step": str(self.phase),
            "destination": self.destination,
            "grab_id": self.grab_id,
            "elapsed_s": round(now - self._t_begin, 2) if self.active else 0.0,
            "wait_left_s": round(max(self.easy.wait_destination_s - (now - self._t_wait), 0.0), 2) if waiting else 0.0,
            "wait_s": self.easy.wait_destination_s,
            "last_result": self.last_result,  # "" | "done" | "cancelled" | "stopped" | "fault" | "expired"
            "error": self.error,
            "reason": self.error,
            "profile": self.params.profile,
            "history": list(self.history[-10:]),
        }

    def _set_state(self, state: str) -> None:
        self.state = state
        self._t_start = self.clock()  # the total timeout counts per part: the wait is a person's time

    # ------------------------------------------------------------------ control
    async def start(self) -> None:  # the auto catch's whole run is not this sequence's
        raise RobotCommandError("the easy mode starts with easy_grab")

    def _is_low(self) -> bool:
        """The arm is below the safe height now (it was left down: the easy mode cannot raise it by hand)."""
        s = self.robot.snapshot()
        if self.params.safe_z is None or self.params.z_tolerance is None or not math.isfinite(s.z):
            return False
        return height(s.z, self.limits) < height(self.params.safe_z, self.limits) - self.params.z_tolerance

    def _relax_for_the_way_up(self) -> None:
        """A run that starts below the safe height only goes up from there (and closes or opens
        the claw where it is). The arm may be lower than the recorded catch height (it was left
        there by hand), so for this run the floor is the bottom of the Z range and the bounds
        on one move are the whole range: the way up must never be the thing that is refused.
        The validated params are back as soon as the arm is up (and whenever the run ends)."""
        lim = self.limits
        bottom = lim.z_min if lim.z_up_is_positive else lim.z_max
        span = abs(lim.z_max - lim.z_min)
        cpu = self.backend.z_counts_per_unit if self.backend is not None else 0.0
        self._strict = self.params
        self.params = dataclasses.replace(self.params, z_floor=bottom, max_drop_units=span,
                                          max_drum_turns=span * cpu / 4096 * 1.05 + 0.05)

    def _restore_strict(self) -> None:
        if self._strict is not None:
            self.params = self._strict
            self._strict = None

    async def start_reset(self) -> None:
        """The start of a game (#177): the claw open and the arm at the top, from any height."""
        await self._begin(reset=True)

    async def start_grab(self) -> None:
        """Catch here; with the arm already down: close where it is and come up.
        Raises RobotCommandError (with every reason) if not allowed."""
        await self._begin(reset=False)

    async def _begin(self, *, reset: bool) -> None:
        if self.active:
            raise RobotCommandError("busy: the easy mode's catch is already running")
        if self.other_active():
            raise RobotCommandError("busy: another sequence is running")
        await self.robot.refresh_status()  # fresh limits / alarm before deciding
        low = self._is_low()
        errs = self.preconditions(any_height=low or reset)
        if not reset:
            errs += self.easy.problems(self.params, self.limits)
            if not low:  # #270: it would go down onto the portal (coming up from low is fine)
                s = self.robot.snapshot()
                near = self.easy.near_portal(s.x, s.y)
                if near:
                    errs.append(near)
        if errs:
            raise RobotCommandError(("easy reset" if reset else "easy catch") + " refused: " + "; ".join(errs))
        if self.lock.locked():  # taken while refresh_status was waiting
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()
        if low:
            self._relax_for_the_way_up()
        self._reset_only = reset
        self.active = True
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._stop_sent = False
        self.destination = 0
        self._chosen = 0
        self.grab_id = uuid.uuid4().hex[:12]
        self.steps = reset_steps(self.params) if reset else (low_grab_steps(self.params) if low else grab_steps(self.params))
        self.step_index = 0
        self._t_begin = self.clock()
        self._set_state("RESET" if reset else "AUTO_GRAB")
        self._task = asyncio.get_running_loop().create_task(self._run())

    def choose(self, destination: Any, grab_id: Any) -> None:
        """The player's sign for the catch `grab_id`: carry it to Dial 1. Once, and only while waiting."""
        if isinstance(destination, bool) or destination not in DESTINATIONS:
            raise RobotCommandError("destination must be 1 (Dial 1, the only portal)")
        if not self.active or self.state != "WAIT_DESTINATION":
            raise RobotCommandError(f"not waiting for a destination (state {self.state})")
        if not grab_id or str(grab_id) != self.grab_id:
            raise RobotCommandError("stale: this choice is not for the current catch")
        if self._abort_reason:
            raise RobotCommandError(f"stopping ({self._abort_reason})")
        if self._chosen:
            raise RobotCommandError(f"already chosen (Dial {self._chosen})")
        self._chosen = int(destination)

    def cancel(self, grab_id: Any) -> None:
        """The player gives this catch up (the claw came up empty): the claw opens where it
        is and the hand has the crane again. Like a choice: once, only while waiting, only
        for this catch. Nothing is carried."""
        if not self.active or self.state != "WAIT_DESTINATION":
            raise RobotCommandError(f"not waiting for a destination (state {self.state})")
        if not grab_id or str(grab_id) != self.grab_id:
            raise RobotCommandError("stale: this is not the current catch")
        if self._abort_reason:
            raise RobotCommandError(f"stopping ({self._abort_reason})")
        if self._chosen:
            raise RobotCommandError("already chosen")
        self._chosen = CANCELLED

    def stop_waiting(self, reason: str) -> bool:
        """The stop key while the run only waits (nothing is moving): the run ends there, with
        no ABORT. Returns False when it is not waiting (then the caller aborts it as ever)."""
        if not self.active or self.state != "WAIT_DESTINATION" or self._chosen or self._abort_reason:
            return False
        if self._action is not None and not self._action.done():
            return False  # (never: the wait has no action; a moving run is never ended this way)
        self._stop_reason = reason
        self._chosen = STOPPED
        return True

    # ------------------------------------------------------------------ run loop
    async def _run(self) -> None:
        try:
            for i, step in enumerate(self.steps):
                self.step_index = i + 1
                await self._do_step(step)
            # the arm is up: from here (the wait, the carry, the descent over the Dial) the
            # validated floor and bounds count again (review on #178)
            self._restore_strict()
            if self._reset_only:
                self.state = "MANUAL_XY"
                self.last_result = "done"
                self._set_phase(EasyPhase.IDLE, "done (at the start)")  # type: ignore[arg-type]
                return
            dest = await self._wait_destination()
            if dest == STOPPED:
                self.error = (f"{self._stop_reason} while waiting for the destination: the claw is still closed "
                              "at the safe height; nothing was moved or released")
                self.last_result = "stopped"
                self.state = "STOPPED"
                self._set_phase(EasyPhase.STOPPED, self.error)  # type: ignore[arg-type]
                return
            if dest == CANCELLED:
                self._set_state("CANCEL")
                self.step_index = len(self.steps) + 1
                await self._do_step(Step(EasyPhase.RELEASE, "release", "claw", claw=self.params.claw_open))  # type: ignore[arg-type]
                self.state = "MANUAL_XY"
                self.last_result = "cancelled"
                self._set_phase(EasyPhase.IDLE, "cancelled: the claw is open, nothing was carried")  # type: ignore[arg-type]
                return
            self.destination = dest
            self._set_state(f"DELIVER_DIAL_{dest}")
            self._require_safe_height()
            steps = deliver_steps(self.params, self.easy, dest)
            first = len(self.steps) + 1
            self.steps = self.steps + steps
            for i, step in enumerate(steps):
                self.step_index = first + i
                await self._do_step(step)
            self.state = "MANUAL_XY"
            self.last_result = "done"
            self._set_phase(EasyPhase.IDLE, f"done (Dial {dest})")  # type: ignore[arg-type]
        except _Expired:
            # nobody chose: nothing is moved, opened or let go. Not an ABORT either (nothing is
            # moving): the claw stays closed where it is, for a person to see to.
            self.error = (f"no destination chosen within {self.easy.wait_destination_s:g} s: the claw is still "
                          "closed at the safe height; nothing was moved or released")
            self.last_result = "expired"
            self.state = "EXPIRED"
            self._set_phase(EasyPhase.EXPIRED, self.error)  # type: ignore[arg-type]
        except SequenceFault as f:
            await self._fault(str(f), servo_ended=f.servo_ended)
        except asyncio.CancelledError:
            await self._fault("sequence cancelled")
            raise
        except Exception as e:  # pragma: no cover - a bug must still end in a safe state
            log.exception("easy_mode")
            await self._fault(f"internal error: {e}")
        finally:
            self._action = None
            self.active = False
            self._restore_strict()
            if self.lock.locked():
                self.lock.release()
            self._changed()

    async def _wait_destination(self) -> int:
        """Holds still (the lock kept, everything monitored) until choose() or the expiry."""
        step = Step(EasyPhase.WAIT_DESTINATION, WAIT_KEY, "hold")  # type: ignore[arg-type]
        self._set_state("WAIT_DESTINATION")
        self._t_wait = self.clock()
        self._set_phase(step.phase, f"up to {self.easy.wait_destination_s:g} s")
        while True:
            self._check(step, self._t_wait)  # a stop, an alarm, a lost link: FAULT as in any state
            if self._chosen:
                return self._chosen
            if self.clock() - self._t_wait >= self.easy.wait_destination_s:
                raise _Expired()
            await asyncio.sleep(self.poll_s)

    def _require_safe_height(self) -> None:
        """XY only ever travels at the safe height: checked from the reading, not assumed."""
        s = self.robot.snapshot()
        tol = float(self.params.z_tolerance)  # type: ignore[arg-type]
        safe = float(self.params.safe_z)  # type: ignore[arg-type]
        if not math.isfinite(s.z) or height(s.z, self.limits) < height(safe, self.limits) - tol:
            raise SequenceFault(f"not at the safe height before the carry (Z {s.z:.1f}, safe_z {safe:g})")

    async def _fault(self, reason: str, *, servo_ended: bool = False) -> None:
        self.state = "FAULT"
        await super()._fault(reason, servo_ended=servo_ended)
