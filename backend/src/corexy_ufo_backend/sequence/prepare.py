"""The 校正 tab's one-button preparation (#167): what is done by hand after every start.

    IDLE --start()--> MOTORS -> Z_TRACK -> Z_RESTORE -> Z_TOP -> CLAW_OPEN -> CLAW_CLOSE -> HOME -> CENTER -> CLAW_READY
        -> EASY -> IDLE
    any step --refused / stop / timeout--> FAULT (stopped there, with the reason)

- MOTORS: enable_motors (the backend's arming; a grown-up pressed the button)
- Z_TRACK: the drum servo's multi-turn tracking starts with a jog: a short slow jog up when
  the call-back says it has not started yet (real robot only)
- Z_RESTORE: the last session's top / bottom (#106) when this session has not recorded
  them; refused when the drum turned too far while off (record the top by hand then).
  The button's text asks the grown-up to check the arm's height first: a whole turn moved
  while off cannot be told apart
- Z_TOP: the arm wound up to the recorded top (home wants it there)
- CLAW_OPEN / CLAW_CLOSE: the claw's recorded positions, open then closed (skipped when
  not recorded)
- HOME: XY homing
- CENTER (#175): on to the middle of the stage (backend.home_then_center; skipped when off)
- CLAW_READY (#175): the claw is left open, ready to catch (skipped when not recorded). The
  open / closed pair before homing stays: it shows both recorded positions work, and the
  arm travels with the claw closed
- EASY (#169): nothing moves. Says whether the last session's drop points of the score game's
  easy mode are in use (they are kept in calibration.json), or why not. Never a failure.

Every step is an existing robot command with its own checks; the sequence holds the
server's motion lock for the whole run and stops at the first refusal. A stop / soft_stop
/ motors off aborts it like the other sequences (GameServer.sequences).
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable

from ..robot.interface import RobotCommandError, RobotInterface
from .fault import SequenceFault

log = logging.getLogger(__name__)

STEPS = (
    ("motors", "モーター有効"),
    ("z_track", "巻き上げサーボの追跡を始める"),
    ("z_restore", "前回の Z の上下を呼び出す"),
    ("z_top", "アームを一番上へ"),
    ("claw_open", "爪を開く"),
    ("claw_close", "爪を閉じる"),
    ("home", "原点復帰"),
    ("center", "ステージの真ん中へ"),
    ("claw_ready", "爪を開いておく"),
    ("easy", "かんたんモードの投入位置（前回の値）"),
)
TRACK_JOG_UNITS_S = 5.0  # slow; upwards (the sign follows z_up_is_positive)
# home waits up to 90 s for the firmware (RealRobot.home): its step may take longer than the others
STEP_TIMEOUT_S = {"home": 120.0}
TRACK_JOG_S = 0.3
TRACK_SETTLE_S = 1.0  # the jog's end (and the firmware's hold check) before asking again
NOT_TRACKING = "追跡がまだ始まっていない"


class PrepareSequencer:
    """Runs the preparation. Same protocol as the other sequences: active, status(),
    abort(reason, send_stop=), wait()."""

    def __init__(self, robot: RobotInterface, *, lock: asyncio.Lock,
                 is_jogging: Callable[[], bool] = lambda: False,
                 on_change: Callable[[dict], None] | None = None,
                 easy_check: Callable[[], str] | None = None,
                 center: Callable[[], tuple[float, float] | None] | None = None,
                 center_feed: Callable[[], float | None] | None = None,
                 step_timeout_s: float = 60.0, settle_s: float = TRACK_SETTLE_S,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.robot = robot
        self.lock = lock
        self.is_jogging = is_jogging
        self.on_change = on_change
        self.easy_check = easy_check
        self.center = center
        self.center_feed = center_feed
        self.step_timeout_s = step_timeout_s
        self.settle_s = settle_s
        self.clock = clock
        self.active = False
        self.step = ""
        self.states: dict[str, str] = {k: "todo" for k, _ in STEPS}
        self.notes: dict[str, str] = {}
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._task: asyncio.Task | None = None

    # ------------------------------------------------------------------ protocol
    def status(self) -> dict:
        return {"active": self.active, "step": self.step, "error": self.error, "last_result": self.last_result,
                "steps": [{"key": k, "label": label, "state": self.states[k], "note": self.notes.get(k, "")}
                          for k, label in STEPS]}

    async def start(self) -> None:
        if self.active:
            raise RobotCommandError("busy: already preparing")
        if self.is_jogging():
            raise RobotCommandError("busy: a key is held (jog): let go first")
        if not self.robot.snapshot().connected:
            raise RobotCommandError("robot not connected")
        if self.lock.locked():
            raise RobotCommandError("busy: another motion command is running")
        await self.lock.acquire()
        self.active = True
        self.step = ""
        self.states = {k: "todo" for k, _ in STEPS}
        self.notes = {}
        self.error = ""
        self.last_result = ""
        self._abort_reason = ""
        self._changed()
        self._task = asyncio.get_running_loop().create_task(self._run())

    def request_abort(self, reason: str) -> bool:
        """Flag the run to stop at the next check (no command sent)."""
        if not self.active or self._abort_reason:
            return False
        self._abort_reason = reason
        return True

    async def abort(self, reason: str, *, send_stop: bool = True) -> bool:
        if not self.request_abort(reason):
            return False
        if send_stop:
            try:
                await self.robot.stop()
            except Exception as e:  # pragma: no cover - the stop is best effort here
                log.warning("preparation: stop failed: %s", e)
        return True

    async def wait(self) -> None:
        if self._task is not None:
            await asyncio.shield(self._task)

    # ------------------------------------------------------------------ run
    def _changed(self) -> None:
        if self.on_change is not None:
            self.on_change(self.status())

    def _check_abort(self) -> None:
        if self._abort_reason:
            raise SequenceFault(self._abort_reason)

    async def _run(self) -> None:
        try:
            for key, _ in STEPS:
                self._check_abort()
                self.step = key
                self.states[key] = "run"
                self._changed()
                limit = STEP_TIMEOUT_S.get(key, self.step_timeout_s)
                try:
                    note = await asyncio.wait_for(getattr(self, "_do_" + key)(), limit)
                except asyncio.TimeoutError as e:
                    # the firmware may still be moving (cancelling the wait does not stop it):
                    # stop it before the motion lock is let go (review on #168)
                    await self._stop_robot()
                    raise SequenceFault(f"{key}: no answer within {limit:g} s (stopped with ABORT)") from e
                except RobotCommandError as e:
                    self._check_abort()  # a stop makes the running command fail: say "stopped"
                    raise SequenceFault(str(e)) from e
                self._check_abort()
                self.states[key] = "skip" if note.startswith("skip:") else "done"
                self.notes[key] = note.removeprefix("skip:").strip()
            self.step = ""
            self.last_result = "done"
            log.info("preparation done")
        except SequenceFault as f:
            self._fail(str(f))
        except asyncio.CancelledError:
            await self._stop_robot()
            self._fail("cancelled")
            raise
        except Exception as e:  # pragma: no cover - a bug must still end with the lock released
            log.exception("preparation")
            self._fail(f"internal error: {e}")
        finally:
            self.active = False
            if self.lock.locked():
                self.lock.release()
            self._changed()

    async def _stop_robot(self) -> None:
        if self._abort_reason:
            return  # aborted: the server's stop / the abort's own stop went out
        try:
            await self.robot.stop()
        except Exception as e:  # pragma: no cover - best effort; the fault says why anyway
            log.warning("preparation: stop failed: %s", e)

    def _fail(self, reason: str) -> None:
        if self.step:
            self.states[self.step] = "fail"
        self.error = reason
        self.last_result = "fault"
        log.warning("preparation stopped at %s: %s", self.step or "start", reason)

    # ------------------------------------------------------------------ steps
    async def _do_motors(self) -> str:
        await self.robot.enable_motors(True)
        return ""

    def _z_recorded(self) -> bool:
        s = self.robot.snapshot()
        return s.z_top_set and s.z_bottom_set

    async def _do_z_track(self) -> str:
        if not self.robot.is_real:
            return "skip: 仮想クレーン"
        if self._z_recorded():
            return "skip: この起動で上下を記録済み"
        try:
            await self.robot.restore_z_points(False)
            return "skip: 追跡中"
        except RobotCommandError as e:
            if NOT_TRACKING not in str(e):
                raise
        # the firmware starts tracking the drum with a jog: a short slow one, upwards
        up = 1.0 if self.robot.limits.z_up_is_positive else -1.0  # review on #168: the arm goes up
        await self.robot.jog(0.0, 0.0, up * TRACK_JOG_UNITS_S)
        try:
            await asyncio.sleep(TRACK_JOG_S)
        finally:
            await self.robot.jog(0.0, 0.0, 0.0)
        await asyncio.sleep(self.settle_s)
        return "少し巻き上げて追跡を始めた"

    async def _do_z_restore(self) -> str:
        if not self.robot.is_real:
            return "skip: 仮想クレーン"
        if self._z_recorded():
            return "skip: この起動で上下を記録済み"
        est = await self.robot.restore_z_points(False)
        if est.get("too_far"):
            raise RobotCommandError(
                f"前回から {float(est.get('drift_units', 0.0)):+.0f} 単位ずれている（電源を切っている間に回った）: "
                "W で一番上まで巻き上げて「ここを上に記録」、S で一番下まで下げて「ここを下に記録」")
        out = await self.robot.restore_z_points(True, int(est.get("turns", 0)))
        return f"Z {float(out.get('z', est.get('z', 0.0))):.1f}"

    async def _do_z_top(self) -> str:
        if not self._z_recorded():
            return "skip: Z の下の記録がない（上だけ: 原点復帰の前に W で一番上へ）"
        lim = self.robot.limits
        top = lim.z_max if lim.z_up_is_positive else lim.z_min
        await self.robot.move_z(top)
        return ""

    def _claw_recorded(self) -> bool:
        s = self.robot.snapshot()
        return s.arm_open_deg is not None and s.arm_closed_deg is not None

    async def _do_claw_open(self) -> str:
        if not self._claw_recorded():
            return "skip: 爪の開き・閉じが未記録"
        await self.robot.arm_goto("open")
        return ""

    async def _do_claw_close(self) -> str:
        if not self._claw_recorded():
            return "skip: 爪の開き・閉じが未記録"
        await self.robot.arm_goto("closed")
        return ""

    async def _do_home(self) -> str:
        await self.robot.home()
        return ""

    async def _do_center(self) -> str:
        to = self.center() if self.center is not None else None
        if to is None:
            return "skip: 使っていない（backend.home_then_center）"
        await self.robot.move_xy(*to, self.center_feed() if self.center_feed is not None else None)
        return f"X {to[0]:.0f} / Y {to[1]:.0f}"

    async def _do_claw_ready(self) -> str:
        if not self._claw_recorded():
            return "skip: 爪の開き・閉じが未記録"
        await self.robot.arm_goto("open")
        return ""

    async def _do_easy(self) -> str:
        if self.easy_check is None:
            return "skip: 使っていない"
        try:
            return self.easy_check()
        except Exception as e:  # a check only: it never stops the preparation
            log.warning("preparation: easy mode check: %s", e)
            return f"skip: 確かめられなかった（{e}）"
