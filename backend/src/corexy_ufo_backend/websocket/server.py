"""WebSocket/JSON bridge between Godot and the robot / vision services.

Messages (all JSON objects with "type" and "timestamp" in ms):
  server -> client : robot_state, ack, nack, error, vision_event, log, hello
  client -> server : hello, command {request_id, data:{name, params}}, ping

Command names and safety rules:
  enable_motors {enable}  must be sent (true) before any motion command.
  home, move_xy {x,y,feed?}, move_z {z}, z_zero (= z_set top),
  z_set {which: top|bottom|clear} (record the arm's height as its top / bottom; both =
  measured counts per unit, saved; clear = start over), z_restore {apply, turns?} (#106: the
  last session's top / bottom after a power cycle; apply false = the estimate only, true =
  use it when the turn shift is still `turns`), z_servo_recover (after the drum
  servo's power was cut alone: a SERVO_TURN the firmware refuses unmoved, so the next jog
  sets it to multi-turn again; a motion command), grab {close}, stop (ABORT, emergency),
  soft_stop (decelerate, no alarm), jog {vx,vy,vz?,z_free?} (mm/s; vz = Z value/s; z_free = the 校正 tab: past the measured Z range; dead-man: resend ~20 Hz while
  held, {0,0} on release; the firmware stops after 250 ms without one; the host also
  sends a zero jog when the jogging client disconnects or its refresh is older than
  jog_expiry_s), clear_alarm,
  worksheet_find {image_jpeg_base64} (#116: the study worksheet's corner marks in the overview
  frame -> {found, corners: {tl, tr, bl, br: [u, v]}, score}; OpenCV only, nothing kept),
  services_check {ask?} (#114: Jev / the tutor AI / Claude Code / Codex / VOICEVOX reachable? ask =
  one short question with the sample worksheet; never the robot, never queued),
  get_state, list_ports, gesture_config {pinch_start?, pinch_release?, pinch_confirm_ms?, ...}
  (hand joystick thresholds at run time; vision only), arm_step {deg} (claw servo ID 2 turned
  by deg degrees, relative, |deg| <= 90; a motion command), arm_zero (claw angle reference),
  arm_set {which: closed|open} (record the claw's current angle as that position; saved),
  arm_goto {which} (turn the claw there, on the closed..open arc; a motion command),
  auto_catch (start the one-button catch sequence; ACK = started, progress in robot_state.auto_catch
  and {"type": "auto_catch"} messages), auto_catch_status,
  homework_spot_set (record where the arm is now as the homework spot), homework_approach
  (take the arm's camera down to the spot and back; ACK = started, progress in
  robot_state.homework_approach and {"type": "homework_approach"} messages; holds the
  motion lock like the auto catch), homework_approach_release (the frames are captured:
  go back up), homework_approach_status.
  devicehub_meta / devicehub_devices / devicehub_status {device} / devicehub_diag /
  devicehub_command {device, name, params} / devicehub_stop_all (#108): the peripherals' hub
  (UFO-DeviceHub) for the settings screen's テスト tab; never the robot, never queued behind
  its commands, accepted during the sequences. Its events come as {"type": "devicehub_event"}.
  devicehub_mock_ball {device} (#138): with the simulated hub (devicehub.port "mock") only, a
  capsule lands in that Dial (BALL_RECEIVED when it is armed); the real hub refuses it.
  homework_approach {u, v, camera} (#78) looks at the overview image point (u, v: 0..1)
  instead: mapped to XY by the camera calibration, at the recorded spot's height.
  homework_navigate {u, v, camera | xy (mock only), d_mm: [dx, dy]} (#104): the tutor AI's "the
  problem is d_mm away from the last capture" -> the next target {u, v, xy, from}; never moves
  (the game sends homework_approach next). Refused over 60 mm, under 3 mm, outside the soft
  limits or the trusted camera calibration.
  camera_map_add {u, v, camera: {width, height, flip_h, flip_v}} (pair the clicked overview
  point with the arm's XY now: its own camera centred on that mark), camera_map_undo,
  camera_map_clear, camera_map_status (never move the robot)
While the auto catch runs it holds the motion lock: every command except stop, soft_stop,
get_state, auto_catch_status, list_ports, gesture_config, a zero jog and enable_motors false is
refused (busy). stop / soft_stop / enable_motors false end it with ABORT.
Every command is ACK'd or NACK'd with its request_id. A request_id that was
already handled is answered with the cached result and NOT executed again
(protects against duplicate/retried motion commands).

Ordering: commands of one connection run one after another (so enable_motors
-> move_xy keeps its order), EXCEPT the out-of-band commands in PRIORITY_COMMANDS
(stop, soft_stop, jog, get_state), which run immediately even while a long move
of the same connection is still waiting for the firmware.

Study mode (#86): homework_approach {xy?|u, v, camera, stages: "study"} takes the arm camera
down in stages (camera 10 cm, 5 cm, the landing; heights from study_mode.height: the real
robot's must be measured and confirmed) and holds at each for the capture
(homework_approach_release {stage}). xy (a target in mm) is accepted only by the mock robot
(the mock demo has no overview camera to click in). study_height_status. The tidy-up:
study_cleanup_start (ACK = started; progress in robot_state.study_cleanup and
{"type": "study_cleanup"} messages; holds the motion lock), study_cleanup_confirm (a grown-up
saw the claw hold the jig), study_cleanup_status. Off on the real robot until
study_mode.cleanup.enabled_real and its confirmed items are set.

The 校正 tab's preparation (#167): calibration_prepare (ACK = started; progress in
robot_state.calibration_prepare and {"type": "calibration_prepare"} messages; holds the motion
lock): motors on, the drum's tracking, the last session's Z points, the arm to the top, the claw
open / closed, home. Stops at the first refusal; stop / soft_stop / motors off abort it.
calibration_prepare_status.

The score game's easy mode (#169): easy_grab (catch where the arm is: claw open, down, claw
closed, up to the safe height; ACK = started; progress in robot_state.easy_mode and
{"type": "easy_mode"} messages; holds the motion lock until the delivery ended), easy_deliver
{destination: 1 | 2, grab_id} (only while that catch waits for its destination, once: carry to
Dial 1 / Dial 2 at the safe height, lower, open, up), easy_status. #177: easy_grab with the arm
below the safe height closes the claw where it is and raises it (nothing goes down); easy_reset
(the start of a game) opens the claw and raises the arm to the top from any height. Nothing chosen within
game_mode.easy.wait_destination_s: the run ends EXPIRED with the claw still closed (nothing
moved, nothing released, no ABORT). The Dials' drop points of the real crane: easy_dial_set
{which: dial_1 | dial_2 (the arm's XY now) | release_z | catch_z (its Z now) | clear} saves
them unconfirmed in calibration.json#easy_dials, easy_dial_confirm {confirmed} after a person
watched a test; unrecorded or unconfirmed = easy_grab refused on the real robot. The saved
values are the next session's too (no recording again), unless Z was measured again since.
The preparation (calibration_prepare) ends with a step that says whether they are in use.

Homework messages (type homework_*, never the robot): start / frame / advice / stop, and
(#79) homework_locate {session_id, kind: stuck|next, image_jpeg_base64} ->
homework_locate_result {problem, u, v, verified, usable, ...} / homework_locate_error
(the game then looks there with the homework_approach command {u, v}), and
homework_say {text} -> homework_speech {wav_base64, engine, credit} / homework_speech_error.
Study mode (#86): homework_start {worksheet_id} (per-problem answers in the progress),
homework_locate {kind: problem, problem, worksheet_id}, homework_explain {images: [{role,
image_jpeg_base64}], problem, grade_label, worksheet_id} -> homework_explain_result /
homework_explain_error (with the worksheet's own hints as a fallback).
"""

from __future__ import annotations

import asyncio
import json
import math
import logging
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection, serve

from ..config import BackendConfig, RobotLimits
from ..robot.interface import RobotCommandError, RobotInterface
from ..robot.state import MachineState
from ..homework.approach import ApproachParams, ApproachSequencer
from ..homework.camera_map import CameraMapError, CameraMapParams, CameraXYMap, camera_signature
from ..sequence import AutoCatchConfig, AutoCatchSequencer
from ..sequence.cleanup import CleanupProfile, CleanupSequencer
from ..sequence.easy import EasyParams, EasySequencer, real_catch_params
from ..sequence.prepare import PrepareSequencer
from ..study_mode.height import DRUM_RADIUS_MM, HeightCalibration, HeightError

log = logging.getLogger(__name__)

# Serial lines not forwarded to the game's log (periodic position reports).
SERIAL_LOG_SKIP = ("TX POS", "RX POS ", "RX JOG_POS ")
LOG_QUEUE_MAX = 500

# The device hub (#108): never the robot, never waits behind its commands, its STOP ALL always goes
DEVICEHUB_COMMANDS = ("devicehub_meta", "devicehub_devices", "devicehub_status", "devicehub_diag",
                      "devicehub_command", "devicehub_stop_all", "devicehub_mock_ball")
COMMANDS = ("enable_motors", "home", "move_xy", "move_z", "z_zero", "z_set", "z_restore", "z_servo_recover", "grab", "stop", "soft_stop", "jog",
            "clear_alarm", "get_state", "list_ports", "gesture_config", "arm_step", "arm_zero",
            "arm_set", "arm_goto", "auto_catch", "auto_catch_status",
            "homework_spot_set", "homework_approach", "homework_approach_release", "homework_approach_status",
            "homework_navigate",
            "camera_map_add", "camera_map_undo", "camera_map_clear", "camera_map_status",
            "study_height_status", "study_height_set", "study_height_confirm",
            "study_cleanup_start", "study_cleanup_confirm", "study_cleanup_status",
            "calibration_prepare", "calibration_prepare_status",
            "easy_grab", "easy_reset", "easy_deliver", "easy_status", "easy_dial_set", "easy_dial_confirm",
            *DEVICEHUB_COMMANDS, "services_check", "worksheet_find")
MOTION_COMMANDS = ("home", "move_xy", "move_z", "grab", "arm_step", "arm_goto", "z_servo_recover")
# Never queued behind another command of the same connection: a stop must reach
# the robot while a move_xy of that connection is still running.
# Out-of-band commands that only read: cancelled at once when their client disconnects, so
# the disconnect's safety aborts never wait for them (review on #115: services_check can wait
# 90 s for an AI). Anything that stops something (stop, devicehub_stop_all, ...) is let finish.
CANCEL_ON_DISCONNECT = ("services_check", "worksheet_find", "devicehub_meta", "devicehub_devices", "devicehub_status",
                        "devicehub_diag")
PRIORITY_COMMANDS = (*DEVICEHUB_COMMANDS, "services_check", "worksheet_find", "stop", "soft_stop", "jog", "get_state", "auto_catch_status",
                     "homework_approach_release", "homework_approach_status",
                     "study_cleanup_confirm", "study_cleanup_status", "calibration_prepare_status",
                     "easy_deliver", "easy_status")
# Accepted while the auto catch runs (anything else is refused as busy).
AUTO_CATCH_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch", "auto_catch_status", "list_ports",
                      "gesture_config", "homework_approach_status", "camera_map_status", "study_cleanup_status",
                      "study_height_status", "easy_status")
# Accepted while the arm approaches the homework (anything else is refused as busy).
APPROACH_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                    "homework_approach", "homework_approach_release", "homework_approach_status",
                    "camera_map_status", "study_cleanup_status", "study_height_status", "easy_status")
# Accepted while the 校正 tab's preparation runs (#167; anything else is refused as busy).
PREPARE_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                   "homework_approach_status", "camera_map_status", "study_cleanup_status", "study_height_status",
                   "calibration_prepare_status", "easy_status")
# Accepted while the study mode tidies up (anything else is refused as busy).
CLEANUP_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                   "homework_approach_status", "camera_map_status", "study_cleanup_start", "study_cleanup_confirm",
                   "study_cleanup_status", "study_height_status", "easy_status")
# Accepted while the easy mode catches, waits for its destination or carries (#169).
EASY_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch_status", "list_ports", "gesture_config",
                "homework_approach_status", "camera_map_status", "study_cleanup_status", "study_height_status",
                "easy_deliver", "easy_status")


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass
class RunningSequence:
    """One automatic sequence the server runs (auto catch, homework approach, tidy-up).

    Everything the server does to all of them (abort on stop / soft_stop / motors off /
    the owner's disconnect / shutdown, the status in robot_state, the busy refusal) goes
    over GameServer.sequences, so a new sequence cannot be left out of a stop."""
    key: str  # its status in robot_state's data, and the type of its change broadcast
    seq: Any  # the sequencer: active, status(), abort(), wait()
    start_command: str  # the client whose command starts it owns it
    during: str  # "... during <this>" in the abort reasons
    busy: str  # the refusal of other commands while it runs
    allowed: tuple[str, ...]  # the commands accepted while it runs
    owner: ServerConnection | None = None
    also_starts: tuple[str, ...] = ()  # other commands that start it (their client owns it too)

    @property
    def the(self) -> str:
        return self.during if self.during.startswith("the ") else "the " + self.during


class GameServer:
    def __init__(self, robot: RobotInterface, host: str = "127.0.0.1", port: int = 8765, *,
                 state_hz: float = 30.0, vision: Any | None = None,
                 auto_catch: AutoCatchConfig | None = None, backend_cfg: BackendConfig | None = None,
                 study: Any | None = None, homework: Any | None = None,
                 approach: ApproachParams | None = None, camera_map: CameraMapParams | None = None,
                 devicehub: Any | None = None, easy: EasyParams | None = None) -> None:
        self.robot = robot
        self.devicehub = devicehub  # #108: the peripherals' hub (DeviceHubService), or None
        self.connect_error = ""  # #124: why the robot's connect at start failed (main.py), for list_ports
        self.backend_cfg = backend_cfg  # #114: services_check reads the study / speech settings
        self.host = host
        self.port = port
        self.state_interval = 1.0 / state_hz
        self.vision = vision
        self.study = study
        self.clients: set[ServerConnection] = set()
        self._study_sessions: dict[ServerConnection, set[str]] = {}
        self.homework = homework
        self._homework_sessions: dict[ServerConnection, set[str]] = {}
        self._handled: OrderedDict[str, dict] = OrderedDict()
        self._server = None
        self._tasks: list[asyncio.Task] = []
        self._motion_lock = asyncio.Lock()
        # Moving jog bookkeeping: who sent the last non-zero jog and when (monotonic).
        # The firmware (and MockRobot) stop 250 ms after the last JOG by themselves;
        # the host also stops at once when that client disconnects, and when no
        # refresh came for jog_expiry_s (a frozen game must not keep the crane going).
        self._jog_owner: ServerConnection | None = None
        self._jog_last = 0.0
        self.jog_expiry_s = 0.3
        # Backend log + serial traffic sent to the clients as {"type": "log"} so the
        # game's debug panel can show and copy it.
        self._log_queue: asyncio.Queue[str] | None = None
        self._log_handler: logging.Handler | None = None
        self._log_loop_ref: asyncio.AbstractEventLoop | None = None
        self._last_tx_jog = ""
        # One-button auto catch. The real robot uses the "real" profile (refused until
        # measured and confirmed), anything else the "dry_run" profile.
        ac = auto_catch or AutoCatchConfig.from_raw({})
        limits = robot.limits or (backend_cfg.limits if backend_cfg else RobotLimits())
        self.auto = AutoCatchSequencer(
            robot, ac.real if robot.is_real else ac.dry_run, limits,
            backend_cfg, lock=self._motion_lock, is_jogging=lambda: self._jog_owner is not None,
            on_change=lambda status: self._on_sequence_change("auto_catch", status))
        # Homework approach (#76): the arm's camera down to a recorded spot and back.
        self.approach = ApproachSequencer(
            robot, limits, approach, spot_path=backend_cfg.homework_spot_path if backend_cfg is not None else None,
            lock=self._motion_lock, is_jogging=lambda: self._jog_owner is not None,
            other_active=lambda: self.auto.active or self.cleanup.active or self.easy.active,
            on_change=lambda status: self._on_sequence_change("homework_approach", status))
        # Study mode (#86): capture heights and the tidy-up. The real robot uses the "real"
        # profiles (refused until measured and confirmed), anything else the "dry_run" ones.
        raw = backend_cfg.raw if backend_cfg is not None else {}
        self.study_profile = "real" if robot.is_real else "dry_run"
        self._height_base = HeightCalibration.from_raw(raw, self.study_profile)
        # #110: the 校正 tab's measured values (calibration.json#study_height) over the config's
        self._height_path = getattr(backend_cfg, "study_height_path", None) if backend_cfg is not None else None
        self.study_open_claw = bool(((raw.get("study_mode") or {}).get("help") or {}).get("open_claw", False))
        self.cleanup = CleanupSequencer(
            robot, limits, CleanupProfile.from_raw(raw, self.study_profile), lock=self._motion_lock,
            is_jogging=lambda: self._jog_owner is not None,
            other_active=lambda: self.auto.active or self.approach.active or self.easy.active,
            on_change=lambda status: self._on_sequence_change("study_cleanup", status))
        # #167: the 校正 tab's one-button preparation
        self.prepare = PrepareSequencer(
            robot, lock=self._motion_lock, is_jogging=lambda: self._jog_owner is not None,
            easy_check=lambda: self._easy_prepare_note(),
            on_change=lambda status: self._on_sequence_change("calibration_prepare", status))
        # #169: the score game's easy mode (catch here, wait for the destination, carry to a Dial).
        # The catch uses the auto catch's profile; the Dials' drop points are the real crane's own
        # measurements (calibration.json#easy_dials) or the dry run's made-up ones.
        self._easy_path = getattr(backend_cfg, "easy_dials_path", None) if backend_cfg is not None else None
        self._easy_fixed = easy  # the tests' own values
        self._easy_limits = limits
        self._easy_dry = ac.dry_run
        first = self._easy_params()
        self.easy = EasySequencer(
            robot, self._easy_catch(first), limits, backend_cfg, easy=first,
            lock=self._motion_lock, is_jogging=lambda: self._jog_owner is not None,
            other_active=lambda: any(q.seq.active for q in self.sequences if q.seq is not self.easy),
            on_change=lambda status: self._on_sequence_change("easy_mode", status))
        self.sequences = (
            RunningSequence("auto_catch", self.auto, "auto_catch", "auto catch",
                            "busy: auto catch running (stop to abort)", AUTO_CATCH_ALLOWED),
            RunningSequence("homework_approach", self.approach, "homework_approach", "the homework approach",
                            "busy: the arm is approaching the homework (stop to abort)", APPROACH_ALLOWED),
            RunningSequence("study_cleanup", self.cleanup, "study_cleanup_start", "the tidy-up",
                            "busy: the study mode is tidying up (stop to abort)", CLEANUP_ALLOWED),
            RunningSequence("calibration_prepare", self.prepare, "calibration_prepare", "the preparation",
                            "busy: preparing the robot (stop to abort)", PREPARE_ALLOWED),
            RunningSequence("easy_mode", self.easy, "easy_grab", "the easy mode's catch and carry",
                            "busy: the easy mode is catching / carrying (stop to abort)", EASY_ALLOWED,
                            also_starts=("easy_reset",)),
        )
        # Overview camera -> XY calibration (#78): calibration.json's camera_xy section (#96).
        self.camera_map = CameraXYMap.load(backend_cfg.camera_xy_path if backend_cfg is not None else None,
                                           camera_map)

    # ------------------------------------------------------------ lifecycle
    async def start(self) -> None:
        self._server = await serve(self._handle_client, self.host, self.port, ping_interval=5, ping_timeout=5)
        self._tasks.append(asyncio.create_task(self._poll_loop()))
        self._tasks.append(asyncio.create_task(self._state_loop()))
        if self.vision is not None:
            self.vision.on_event = self._on_vision_event
        self._start_log_feed()
        if self.devicehub is not None:
            self.devicehub.start(self._on_devicehub_event)
        log.info("websocket listening on ws://%s:%d", self.host, self.port)

    async def _on_devicehub_event(self, data: dict) -> None:
        await self.broadcast({"type": "devicehub_event", "timestamp": now_ms(), "data": data})

    async def stop(self) -> None:
        for s in self.sequences:
            if s.seq.active:
                await s.seq.abort(f"backend shutting down during {s.during}")
                await s.seq.wait()
        if self.study is not None:
            await self.study.close()
        if self.homework is not None:
            await self.homework.close()
        if self.devicehub is not None:
            await asyncio.to_thread(self.devicehub.close)
        self._stop_log_feed()
        for t in self._tasks:
            t.cancel()
        self._tasks.clear()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    # ------------------------------------------------------------ log feed
    def _start_log_feed(self) -> None:
        self._log_loop_ref = asyncio.get_running_loop()
        self._log_queue = asyncio.Queue(maxsize=LOG_QUEUE_MAX)
        server = self

        class _Forward(logging.Handler):
            def emit(self, record: logging.LogRecord) -> None:
                # may come from a vision thread: hand it to the event loop
                server._queue_log_threadsafe(f"[backend] {record.levelname} {record.getMessage()}")

        self._log_handler = _Forward(level=logging.INFO)
        logging.getLogger("corexy_ufo_backend").addHandler(self._log_handler)
        serial = getattr(self.robot, "serial", None)
        if serial is not None and hasattr(serial, "log_listeners"):
            serial.log_listeners.append(self._on_serial_log)
        self._tasks.append(asyncio.create_task(self._log_loop()))

    def _stop_log_feed(self) -> None:
        if self._log_handler is not None:
            logging.getLogger("corexy_ufo_backend").removeHandler(self._log_handler)
            self._log_handler = None
        serial = getattr(self.robot, "serial", None)
        if serial is not None and self._on_serial_log in getattr(serial, "log_listeners", []):
            serial.log_listeners.remove(self._on_serial_log)

    def _on_serial_log(self, line: str) -> None:
        # POS / JOG_POS come many times a second and say nothing new; a held key
        # resends the same JOG line at 20 Hz: show a JOG only when it changes
        if line.startswith(SERIAL_LOG_SKIP):
            return
        if line.startswith("TX JOG "):
            if line == self._last_tx_jog:
                return
            self._last_tx_jog = line
        self._queue_log_threadsafe("[serial] " + line)

    def _queue_log(self, line: str) -> None:
        if self._log_queue is not None and not self._log_queue.full():
            self._log_queue.put_nowait(line)

    def _queue_log_threadsafe(self, line: str) -> None:
        try:
            self._log_loop_ref.call_soon_threadsafe(self._queue_log, line)
        except RuntimeError:  # pragma: no cover - loop closed
            pass

    async def _log_loop(self) -> None:
        assert self._log_queue is not None
        while True:
            line = await self._log_queue.get()
            await self.broadcast({"type": "log", "timestamp": now_ms(), "data": {"line": line}})

    # ------------------------------------------------------------ broadcast
    async def broadcast(self, msg: dict) -> None:
        if not self.clients:
            return
        text = json.dumps(msg)
        dead = []
        for c in list(self.clients):
            try:
                await c.send(text)
            except Exception:
                dead.append(c)
        for c in dead:
            self.clients.discard(c)

    async def _poll_loop(self) -> None:
        # robot.tick() can wait on the serial line (POS round trip ~70-100 ms on the
        # real robot); it runs here so the state broadcast never waits for it.
        while True:
            try:
                await self.robot.tick()
                await self._expire_jog()
            except Exception:  # pragma: no cover
                log.exception("poll loop")
            await asyncio.sleep(0.01)

    async def _expire_jog(self) -> None:
        if self._jog_owner is not None and time.monotonic() - self._jog_last > self.jog_expiry_s:
            log.warning("jog refresh expired (%.0f ms): stopping", (time.monotonic() - self._jog_last) * 1000)
            await self._end_jog()

    async def _end_jog(self) -> None:
        self._jog_owner = None
        try:
            await self.robot.jog(0.0, 0.0, 0.0)
        except RobotCommandError as e:  # pragma: no cover - a zero jog is not refused
            log.warning("zero jog: %s", e)

    async def _state_loop(self) -> None:
        # Fixed-rate schedule: sleep until the next slot instead of a fixed
        # interval after the work, so tick/broadcast time does not stretch the
        # period (the game interpolates these samples; irregular gaps show up
        # as stop-and-go on the rope). When late, restart the schedule one
        # interval from now rather than bursting to catch up (back-to-back
        # samples a few ms apart are useless for interpolation).
        loop = asyncio.get_running_loop()
        next_t = loop.time()
        while True:
            try:
                msg = self.robot.snapshot().to_message()
                self._add_sequence_status(msg["data"])
                await self.broadcast(msg)
            except Exception:  # pragma: no cover
                log.exception("state loop")
            next_t += self.state_interval
            now = loop.time()
            if next_t < now:
                next_t = now + self.state_interval
            await asyncio.sleep(max(next_t - now, 0.0))

    def _add_sequence_status(self, data: dict) -> None:
        for s in self.sequences:
            data[s.key] = s.seq.status()

    def _on_sequence_change(self, key: str, status: dict) -> None:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:  # pragma: no cover
            return
        loop.create_task(self.broadcast({"type": key, "timestamp": now_ms(), "data": status}))

    def _on_vision_event(self, event: dict) -> None:
        asyncio.get_event_loop().create_task(self.broadcast({"type": "vision_event", "timestamp": now_ms(), "data": event}))

    # ------------------------------------------------------------ clients
    async def _handle_client(self, ws: ServerConnection) -> None:
        self.clients.add(ws)
        log.info("client connected (%d)", len(self.clients))
        try:
            await ws.send(json.dumps({"type": "hello", "timestamp": now_ms(), "data": {"server": "corexy-ufo-backend", "robot": self.robot.name, "commands": list(COMMANDS), "study": self.study is not None, "study_provider": self._study_provider(), "homework": self.homework is not None,
                "homework_advice": self.homework is not None and self.homework.advice_available,
                "homework_speech": self.homework is not None and self.homework.speech_available,
                "study_profile": self.study_profile}}))
            await ws.send(json.dumps(self.robot.snapshot().to_message()))
            queue: asyncio.Queue = asyncio.Queue()
            worker = asyncio.create_task(self._ordered_worker(ws, queue))
            out_of_band: set[asyncio.Task] = set()
            readers: dict[asyncio.Task, str] = {}  # out-of-band tasks to cancel on a disconnect
            try:
                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        await ws.send(json.dumps({"type": "error", "timestamp": now_ms(), "data": {"message": "invalid json"}}))
                        continue
                    name = str((msg.get("data") or {}).get("name", "")) if msg.get("type") == "command" else ""
                    if name in PRIORITY_COMMANDS:
                        task = asyncio.create_task(self._dispatch(ws, msg))
                        out_of_band.add(task)
                        task.add_done_callback(out_of_band.discard)
                        if name in CANCEL_ON_DISCONNECT:
                            readers[task] = name
                            task.add_done_callback(lambda t: readers.pop(t, None))
                    else:
                        queue.put_nowait(msg)
            finally:
                # The client is gone: drop queued commands (no move should start for a
                # client that left), let a running one finish (never cancel a move half-way).
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
                for task in list(readers):  # nothing waits for a diagnostic (an AI's answer)
                    task.cancel()
                await asyncio.gather(worker, *out_of_band, return_exceptions=True)
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(ws)
            for session_id in self._study_sessions.pop(ws, set()):
                if self.study is not None:
                    await self.study.end_session(session_id)
            for session_id in self._homework_sessions.pop(ws, set()):
                if self.homework is not None:
                    await self.homework.stop(session_id)
            log.info("client disconnected (%d)", len(self.clients))
            if self._jog_owner is ws:
                log.warning("the jogging client disconnected: stopping the jog")
                await self._end_jog()
            for s in self.sequences:
                if s.owner is ws and s.seq.active:
                    # nobody left who could press stop: end the sequence in the safe state
                    log.warning("the client running %s disconnected: aborting it", s.the)
                    await s.seq.abort(f"operator disconnected during {s.during}")

    async def _ordered_worker(self, ws: ServerConnection, queue: asyncio.Queue) -> None:
        while True:
            msg = await queue.get()
            if msg is None:
                return
            try:
                await self._dispatch(ws, msg)
            except websockets.ConnectionClosed:
                return

    async def _dispatch(self, ws: ServerConnection, msg: dict) -> None:
        t = msg.get("type")
        if t == "ping":
            await ws.send(json.dumps({"type": "pong", "timestamp": now_ms(), "echo": msg.get("timestamp")}))
        elif t == "hello":
            pass
        elif t == "command":
            await self._handle_command(ws, msg)
        elif t and t.startswith("study_"):
            await self._handle_study(ws, msg)
        elif t and t.startswith("homework_"):
            await self._handle_homework(ws, msg)
        else:
            await ws.send(json.dumps({"type": "error", "timestamp": now_ms(), "data": {"message": f"unknown type {t}"}}))

    async def _handle_homework(self, ws: ServerConnection, msg: dict) -> None:
        """Homework watch (optional, never touches the robot): start / frame / stop."""
        rid = str(msg.get("request_id", ""))
        data = msg.get("data") if isinstance(msg.get("data"), dict) else {}
        session_id = str(data.get("session_id", ""))
        if self.homework is None:
            await self._study_send(ws, {"type": "homework_error", "request_id": rid, "data": {
                "code": "disabled", "message": "宿題の見守りは無効です（config の homework.enabled）"}})
            return
        try:
            if msg["type"] == "homework_start":
                result = await self.homework.start(session_id, str(data.get("worksheet_id", "")))
                self._homework_sessions.setdefault(ws, set()).add(session_id)
                await self._study_send(ws, {"type": "homework_status", "data": result})
            elif msg["type"] == "homework_frame":
                started = await self.homework.frame(session_id, rid, str(data.get("image_jpeg_base64", "")),
                                                    lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "session_id": session_id, "state": "estimating" if started else "skipped"}})
            elif msg["type"] == "homework_advice":
                await self.homework.advise(session_id, rid, str(data.get("image_jpeg_base64", "")),
                                           bool(data.get("composite", False)),
                                           lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "session_id": session_id, "state": "advising"}})
            elif msg["type"] == "homework_locate":
                await self.homework.locate(session_id, rid, str(data.get("kind", "")),
                                           str(data.get("image_jpeg_base64", "")),
                                           lambda reply: self._study_send(ws, reply),
                                           problem=int(data.get("problem", 0) or 0),
                                           worksheet_id=str(data.get("worksheet_id", "")))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "session_id": session_id, "state": "locating", "kind": str(data.get("kind", ""))}})
            elif msg["type"] == "homework_explain":
                await self.homework.explain(rid, data.get("images") or [], int(data.get("problem", 3) or 3),
                                            str(data.get("grade_label", "")), str(data.get("worksheet_id", "")),
                                            lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "state": "explaining"}})
            elif msg["type"] == "homework_say":
                await self.homework.say(rid, str(data.get("text", "")), lambda reply: self._study_send(ws, reply))
            elif msg["type"] == "homework_stop":
                result = await self.homework.stop(session_id)
                self._homework_sessions.get(ws, set()).discard(session_id)
                await self._study_send(ws, {"type": "homework_status", "data": result or {
                    "session_id": session_id, "state": "stopped"}})
            else:
                raise ValueError(f"unknown homework message {msg['type']}")
        except Exception as exc:
            describe = getattr(exc, "describe", None)
            await self._study_send(ws, {"type": "homework_error", "request_id": rid, "data": {
                "code": getattr(exc, "kind", "invalid_request"),
                "message": describe() if callable(describe) else str(exc)}})

    def _study_provider(self) -> str:
        cfg = getattr(self.study, "config", None)
        return str(getattr(cfg, "provider", "")) if self.study is not None else ""

    async def _study_send(self, ws: ServerConnection, message: dict) -> None:
        message.setdefault("timestamp", now_ms())
        await ws.send(json.dumps(message))

    async def _handle_study(self, ws: ServerConnection, msg: dict) -> None:
        rid = str(msg.get("request_id", ""))
        data = msg.get("data") if isinstance(msg.get("data"), dict) else {}
        if self.study is None:
            await self._study_send(ws, {"type": "study_error", "request_id": rid,
                "data": {"code": "disabled", "message": "学習機能は無効です。configと--studyを確認してください"}})
            return
        try:
            if msg["type"] == "study_session_start":
                session_id = str(data.get("session_id", ""))
                result = await self.study.start_session(session_id)
                self._study_sessions.setdefault(ws, set()).add(session_id)
                await self._study_send(ws, {"type": "study_status", "data": {"available": True, **result}})
            elif msg["type"] == "study_request":
                await self.study.ask(str(data.get("session_id", "")), rid,
                    str(data.get("question", "")), str(data.get("image_jpeg_base64", "")),
                    lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "study_status", "request_id": rid,
                    "data": {"available": True, "state": "thinking"}})
            elif msg["type"] == "study_cancel":
                if not await self.study.cancel(rid):
                    raise ValueError("unknown or completed study request")
            elif msg["type"] == "study_session_end":
                session_id = str(data.get("session_id", ""))
                await self.study.end_session(session_id)
                self._study_sessions.get(ws, set()).discard(session_id)
                await self._study_send(ws, {"type": "study_status", "data": {"available": True, "state": "closed"}})
            else:
                raise ValueError(f"unknown study message {msg['type']}")
        except Exception as exc:
            await self._study_send(ws, {"type": "study_error", "request_id": rid,
                "data": {"code": "invalid_request", "message": str(exc)}})

    async def _handle_command(self, ws: ServerConnection, msg: dict) -> None:
        rid = str(msg.get("request_id", ""))
        data = msg.get("data") or {}
        name = str(data.get("name", ""))
        params = data.get("params") or {}
        if rid and rid in self._handled:
            cached = self._handled[rid]
            await ws.send(json.dumps({**cached, "timestamp": now_ms(), "duplicate": True}))
            return
        reply = await self.execute(name, params)
        for s in self.sequences:
            if name in (s.start_command, *s.also_starts) and reply.get("type") == "ack":
                s.owner = ws
        if name == "jog" and reply.get("type") == "ack":
            moving = any(float(params.get(k, 0.0) or 0.0) for k in ("vx", "vy", "vz"))
            self._jog_owner = ws if moving else None
            self._jog_last = time.monotonic()
        reply["request_id"] = rid
        reply["timestamp"] = now_ms()
        if rid:
            self._handled[rid] = reply
            while len(self._handled) > 500:
                self._handled.popitem(last=False)
        await ws.send(json.dumps(reply))

    async def execute(self, name: str, params: dict) -> dict:
        """Run one command; returns an ack/nack message (without request_id)."""
        if name not in COMMANDS:
            return self._nack(name, f"unknown command {name!r}")
        if name in DEVICEHUB_COMMANDS:  # the peripherals only: not the robot, not its sequences
            return await self._devicehub(name, params)
        if name == "worksheet_find":  # #116: the sheet's corner marks in the overview frame; never the robot
            return await self._worksheet_find(params)
        if name == "services_check":  # #114: Jev / the tutor / Claude Code / VOICEVOX; never the robot
            from ..services_check import check_all
            cfg = self.backend_cfg
            results = await check_all(cfg.raw if cfg is not None else {}, ask=params.get("ask") is True,
                                      focus_calibration=getattr(cfg, "focus_camera_path", None))
            return self._ack(name, {"results": results})
        try:
            for s in self.sequences:
                if s.seq.active and name not in s.allowed and not self._allowed_during_auto(name, params):
                    return self._nack(name, s.busy)
            if name in MOTION_COMMANDS and self._motion_lock.locked():
                return self._nack(name, "busy: another motion command is running")
            if name == "get_state":
                data = self.robot.snapshot().to_message()["data"]
                self._add_sequence_status(data)
                return self._ack(name, data)
            if name == "homework_approach_status":
                return self._ack(name, self.approach.status())
            if name == "homework_navigate":
                return self._homework_navigate(params)
            if name == "homework_approach":
                target = None
                if "xy" in params:
                    # the mock demo has no overview image: a target in mm, never for the real robot
                    if self.robot.is_real:
                        return self._nack(name, "a target in mm (xy) is only for the mock robot: use u, v "
                                                "and the camera calibration")
                    xy = params.get("xy")
                    target = (float(xy[0]), float(xy[1]))
                elif "u" in params or "v" in params:
                    target = self.camera_map.to_xy(params.get("u"), params.get("v"),
                                                   camera_signature(params.get("camera")))
                stages = None
                if params.get("stages") == "study":
                    try:
                        stages = [(st.name, st.z) for st in self.height.stages(self.approach.limits)]
                    except HeightError as e:
                        return self._nack(name, f"staged capture refused: {e}")
                    if target is None:
                        return self._nack(name, "a staged capture needs a target (u, v or xy)")
                    await self.approach.start(target, stages, open_claw=self.study_open_claw)
                else:
                    await self.approach.start(target)
                return self._ack(name, self.approach.status())
            if name == "study_height_status":
                return self._ack(name, self._height_status())
            if name == "study_height_set":
                return self._study_height_set(params)
            if name == "study_height_confirm":
                return self._study_height_confirm(params)
            if name == "calibration_prepare_status":
                return self._ack(name, self.prepare.status())
            if name == "calibration_prepare":
                if any(q.seq.active for q in self.sequences):
                    return self._nack(name, "busy: another sequence is running")
                await self.prepare.start()
                return self._ack(name, self.prepare.status())
            if name == "easy_status":
                return self._ack(name, self._easy_status())
            if name == "easy_grab":
                self._easy_refresh()  # the Z calibration may have been measured again since
                await self.easy.start_grab()
                return self._ack(name, self.easy.status())
            if name == "easy_reset":
                self._easy_refresh()
                await self.easy.start_reset()
                return self._ack(name, self.easy.status())
            if name == "easy_deliver":
                self.easy.choose(params.get("destination"), params.get("grab_id"))
                return self._ack(name, self.easy.status())
            if name == "easy_dial_set":
                return self._easy_dial_set(params)
            if name == "easy_dial_confirm":
                return self._easy_dial_confirm(params)
            if name == "study_cleanup_status":
                return self._ack(name, self.cleanup.status())
            if name == "study_cleanup_start":
                await self.cleanup.start()
                return self._ack(name, self.cleanup.status())
            if name == "study_cleanup_confirm":
                if not self.cleanup.confirm():
                    return self._nack(name, "nothing to confirm (the tidy-up is not waiting for the jig grip)")
                return self._ack(name, self.cleanup.status())
            if name.startswith("camera_map_"):
                return self._camera_map_command(name, params)
            if name == "homework_approach_release":
                stage = str(params.get("stage", "") or "")
                if not self.approach.release(stage) and stage:
                    return self._nack(name, f"not holding at stage {stage!r} (now {self.approach.stage or '-'})")
                return self._ack(name, self.approach.status())
            if name == "homework_spot_set":
                self.approach.set_spot()
                return self._ack(name, self.approach.status())
            if name == "auto_catch_status":
                return self._ack(name, self.auto.status())
            if name == "auto_catch":
                await self.auto.start()
                return self._ack(name, self.auto.status())
            if name == "gesture_config":
                # pinch thresholds of the hand joystick (vision only, never moves the robot)
                cfg = self.vision.configure_hands(params) if self.vision is not None else None
                if cfg is None:
                    return self._nack(name, "no hand joystick camera (start the backend with --gesture)")
                return self._ack(name, cfg)
            if name == "list_ports":
                from ..serial_service.transport import list_serial_ports
                ports = list_serial_ports()
                return self._ack(name, {"ports": ports, "robot": self._robot_link([p["device"] for p in ports])})
            if name == "enable_motors":
                if not bool(params.get("enable", False)):
                    for s in self.sequences:
                        await s.seq.abort(f"motors disabled during {s.during}")
                await self.robot.enable_motors(bool(params.get("enable", False)))
            elif name == "stop":
                self._jog_owner = None  # stopped: nothing left for the jog expiry to stop
                # flag first (no new step can start), then ABORT without any wait in between
                for s in self.sequences:
                    await s.seq.abort("emergency stop (stop)", send_stop=False)
                await self.robot.stop()
            elif name == "soft_stop":
                self._jog_owner = None
                for s in self.sequences:
                    if s.seq.active:
                        # STOP does not stop the servos (Z drum, claw): end the sequence with ABORT
                        await s.seq.abort(f"stopped (soft_stop) during {s.during}")
                        return self._ack(name, self.robot.snapshot().to_message()["data"])
                # outside the motion lock: it must reach a running move
                await self.robot.soft_stop()
            elif name == "jog":
                # Dead-man refresh, sent ~20 Hz while a key is held; never retried. Outside
                # the motion lock, but refused while a home/move/grab command is running.
                vx, vy = float(params.get("vx", 0.0)), float(params.get("vy", 0.0))
                vz = float(params.get("vz", 0.0))
                if (vx or vy or vz) and self._motion_lock.locked():
                    return self._nack(name, "busy: another motion command is running")
                # z_free: the game's 校正 tab measuring Z again (#102), past the measured range
                await self.robot.jog(vx, vy, vz, z_free=params.get("z_free") is True)
            elif name == "clear_alarm":
                await self.robot.clear_alarm()
            elif name == "z_zero":
                await self.robot.set_z_zero()
            elif name == "z_set":
                await self.robot.set_z_point(str(params.get("which", "")))
            elif name == "z_restore":
                turns = params.get("turns")
                data = await self.robot.restore_z_points(params.get("apply") is True,
                                                         int(turns) if turns is not None else None)
                return self._ack(name, {"restore": data, **self.robot.snapshot().to_message()["data"]})
            elif name == "z_servo_recover":
                await self.robot.recover_z_servo()
            elif name == "arm_zero":
                await self.robot.arm_zero()
            elif name == "arm_set":
                await self.robot.arm_set(str(params["which"]))
            else:
                async with self._motion_lock:
                    if name == "home":
                        await self.robot.home()
                    elif name == "move_xy":
                        await self.robot.move_xy(float(params["x"]), float(params["y"]), params.get("feed"))
                    elif name == "move_z":
                        await self.robot.move_z(float(params["z"]))
                    elif name == "grab":
                        await self.robot.grab(bool(params.get("close", True)))
                    elif name == "arm_step":
                        await self.robot.arm_step(float(params["deg"]))
                    elif name == "arm_goto":
                        await self.robot.arm_goto(str(params["which"]))
            return self._ack(name, self.robot.snapshot().to_message()["data"])
        except CameraMapError as e:
            return self._nack(name, str(e))
        except (KeyError, ValueError, TypeError) as e:
            return self._nack(name, f"bad params: {e}")
        except RobotCommandError as e:
            return self._nack(name, str(e))
        except Exception as e:  # pragma: no cover
            log.exception("command %s failed", name)
            return self._nack(name, f"internal error: {e}")

    def _robot_link(self, available: list[str]) -> dict:
        """The robot's serial link for the 校正 tab (#124): connected, or why not. Read only."""
        connected = self.robot.snapshot().connected
        if not self.robot.is_real:
            return {"kind": "mock", "connected": connected, "problem": ""}
        from ..serial_service.transport import link_report
        cfg = self.backend_cfg
        registered = [cfg.serial_port, cfg.serial_port_2] if cfg is not None else []
        serial = getattr(self.robot, "serial", None)
        error = self.connect_error or str(getattr(serial, "last_error", "") or "")
        # the hub's own port (#108) is not a board to register for the robot
        hub = self.devicehub
        hub_port = getattr(getattr(hub, "transport", None), "current_port", None) \
            if hub is not None and getattr(getattr(hub, "gw", None), "connected", False) else None
        return {"kind": "real", **link_report(registered, getattr(serial, "port", None), available, connected, error,
                                              not_robot=(str(hub_port),) if hub_port else ())}

    def _camera_map_command(self, name: str, params: dict) -> dict:
        if name == "camera_map_add":
            s = self.robot.snapshot()
            if not s.connected:
                raise RobotCommandError("robot not connected")
            if not s.homed:
                raise RobotCommandError("not homed: home first (XY must be known)")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                raise RobotCommandError(f"the arm is moving ({s.state}): wait until it stops")
            self.camera_map.add(params.get("u"), params.get("v"), s.x, s.y, camera_signature(params.get("camera")))
            log.info("camera map: point %d at XY (%.1f, %.1f): %s", len(self.camera_map.points), s.x, s.y,
                     self.camera_map.problem or f"fit ok, max {self.camera_map.max_error:.2f} mm")
        elif name == "camera_map_undo":
            self.camera_map.undo()
        elif name == "camera_map_clear":
            self.camera_map.clear()
        return self._ack(name, self.camera_map.status())

    # ------------------------------------------------------------------ study heights (#110)
    def _height_saved(self) -> dict | None:
        path = self._height_path
        if self.study_profile != "real" or path is None:
            return None
        try:
            if not path.exists():
                return None
            d = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("study heights not read: %s", e)
            return None
        return d if isinstance(d, dict) else None

    def _z_counts_per_unit(self) -> float | None:
        """The measured Z calibration only: the config's guess would give a wrong cm."""
        cal = getattr(self.robot, "z_cal", None)
        return float(cal.counts_per_unit) if cal is not None and cal.complete() else None

    def _height_z_changed(self, saved: dict) -> bool:
        """Review on #111: the Z calibration changed since the heights were saved: the recorded
        desk Z and the ruler check no longer hold (counts per unit is what turns Z into cm)."""
        then, now = saved.get("z_counts_per_unit"), self._z_counts_per_unit()
        if not isinstance(then, (int, float)) or isinstance(then, bool) or now is None:
            return then is not None or now is not None
        return abs(float(then) - now) > 1e-6 * max(abs(now), 1.0)

    @property
    def height(self) -> HeightCalibration:
        """#165: on the real robot the heights come from the Z calibration with no ruler check:
        the desk = the Z bottom record, cm per Z from the measured Z calibration and the drum
        (15 mm unless the 校正 tab saved another radius), the claw tips 10 cm above it."""
        if self.study_profile != "real":
            return self._height_base
        saved = self._height_saved() or {"drum_radius_mm": DRUM_RADIUS_MM, "desk": "bottom"}
        if self._height_z_changed(saved) and saved.get("desk") != "bottom":
            saved = {**saved, "desk": None}  # a Z recorded in the old units: record the desk again
        return self._height_base.with_measured({**saved, "confirmed": True}, self._z_counts_per_unit(),
                                               self.approach.limits)

    def _height_status(self) -> dict:
        data = self.height.status(self.approach.limits)
        data["saved"] = self._height_saved()
        data["z_calibrated"] = self._z_counts_per_unit() is not None
        # only a desk recorded as a Z is stale after measuring Z again ("bottom" follows it, #165)
        data["z_changed"] = (data["saved"] is not None and data["saved"].get("desk") != "bottom"
                             and self._height_z_changed(data["saved"]))
        data["default_drum_radius_mm"] = DRUM_RADIUS_MM
        return data

    def _study_height_set(self, params: dict) -> dict:
        """The 校正 tab's values -> calibration.json#study_height, unconfirmed (#110)."""
        name = "study_height_set"
        if self.study_profile != "real" or self._height_path is None:
            return self._nack(name, "仮想クレーンでは模擬の値（study_mode.height.dry_run）を使う。実機でだけ測る")

        def num(key: str, lo: float, hi: float) -> float:
            v = params.get(key)
            if not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) or not lo <= v <= hi:
                raise ValueError(f"{key} must be a number in {lo:g}..{hi:g}")
            return round(float(v), 3)
        try:
            out: dict[str, Any] = {"drum_radius_mm": num("drum_radius_mm", 3.0, 100.0)}
            # optional: the lens above the tips and the closest stage (#110: one 10 cm stage of the tips)
            if params.get("camera_offset_cm") is not None:
                out["camera_offset_cm"] = num("camera_offset_cm", 0.0, 30.0)
            if params.get("landing_tip_cm") is not None:
                out["landing_tip_cm"] = num("landing_tip_cm", 0.0, 20.0)
                out["allow_landing_contact"] = params.get("allow_landing_contact") is True
        except ValueError as e:
            return self._nack(name, str(e))
        desk = params.get("desk", "bottom")
        if desk == "here":
            s = self.robot.snapshot()
            if not s.z_reference_set:
                return self._nack(name, "Z の基準がない: W で一番上まで巻き上げて「上を記録」してから")
            out["desk"] = round(float(s.z), 2)
        elif desk == "bottom":
            out["desk"] = "bottom"
        else:
            saved = self._height_saved() or {}
            out["desk"] = saved.get("desk", "bottom")  # keep the recorded desk
        out["confirmed"] = False  # every change is checked on the robot again
        out["z_counts_per_unit"] = self._z_counts_per_unit()  # what these Z values mean (review on #111)
        try:
            self._height_path.write_text(json.dumps(out))
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        log.info("study heights saved (not confirmed yet): %s", out)
        return self._ack(name, self._height_status())

    def _study_height_confirm(self, params: dict) -> dict:
        """A grown-up checked the test moves with a ruler: the staged descent may use them."""
        name = "study_height_confirm"
        saved = self._height_saved()
        if saved is None:
            return self._nack(name, "まだ保存していない（値を入れて「保存」）")
        on = params.get("confirmed") is not False
        if on and self._height_z_changed(saved):
            return self._nack(name, "Z を測り直したので、撮影の高さを「保存」し直して、試してから確かめる")
        if on:
            try:
                self._height_base.with_measured({**saved, "confirmed": True}, self._z_counts_per_unit(),
                                                self.approach.limits).stages(self.approach.limits)
            except HeightError as e:
                return self._nack(name, f"このままでは使えない: {e}")
        try:
            self._height_path.write_text(json.dumps({**saved, "confirmed": on}))
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        log.info("study heights %s", "confirmed" if on else "unconfirmed")
        return self._ack(name, self._height_status())

    # ------------------------------------------------------------------ easy mode's Dials (#169)
    def _easy_saved(self) -> dict | None:
        path = self._easy_path
        if path is None:
            return None
        try:
            if not path.exists():
                return None
            d = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            log.warning("easy mode's drop points not read: %s", e)
            return None
        return d if isinstance(d, dict) else None

    def _easy_params(self) -> EasyParams:
        if self._easy_fixed is not None:
            return self._easy_fixed
        profile = "real" if self.robot.is_real else "dry_run"
        raw = self.backend_cfg.raw if self.backend_cfg is not None else {}
        saved = self._easy_saved() if profile == "real" else None
        easy = EasyParams.from_raw(raw, profile, saved)
        if profile == "real" and saved is not None and (easy.catch_z is not None or easy.release_z is not None):
            # the recorded heights are in the Z units of the calibration they were recorded with
            import dataclasses
            easy = dataclasses.replace(easy, stale_z=self._height_z_changed(saved))
        return easy

    def _easy_catch(self, easy: EasyParams):
        """The catch's profile: the real crane's from what the 校正 tab measured, else the dry run's."""
        if not self.robot.is_real or self._easy_fixed is not None:
            return self._easy_dry
        raw = self.backend_cfg.raw if self.backend_cfg is not None else {}
        return real_catch_params(raw, easy, self._easy_limits, self.backend_cfg)

    def _easy_refresh(self) -> None:
        """The saved values (and the Z calibration they depend on) as they are now."""
        if not self.easy.active:
            easy = self._easy_params()
            self.easy.set_easy(easy, self._easy_catch(easy))

    def _easy_status(self) -> dict:
        self._easy_refresh()
        return {**self.easy.status(), "dials": self.easy.easy.as_dict(), "problems": self.easy.problems()}

    def _easy_prepare_note(self) -> str:
        """The preparation's last step (#167 / #169): the last session's drop points are in use,
        or why not. Never a failure: the easy mode is a choice."""
        if not self.robot.is_real:
            return "skip: 仮想クレーン（模擬の値を使う）"
        if self._easy_saved() is None:
            return "skip: まだ記録していない（かんたんモードを使うときだけ、校正タブの 8 で）"
        self._easy_refresh()
        problems = self.easy.problems()
        if problems:
            return "skip: まだ使えない: " + problems[0]
        e = self.easy.easy
        return "前回の値を使う（Dial 1 X %.0f / Y %.0f、Dial 2 X %.0f / Y %.0f、キャッチ Z %.1f、投入 Z %.1f）" % (
            *e.dials[1], *e.dials[2], e.catch_z, e.release_z)

    def _easy_write(self, name: str, saved: dict) -> dict:
        try:
            self._easy_path.write_text(json.dumps(saved))
            self._easy_refresh()
        except (OSError, ValueError) as e:
            return self._nack(name, f"保存できません: {e}")
        return self._ack(name, self._easy_status())

    def _easy_dial_set(self, params: dict) -> dict:
        """The 校正 tab: where the arm is now = a Dial's drop point (XY) or the release height (Z).
        Saved unconfirmed: every change is watched on the machine again before it is used."""
        name = "easy_dial_set"
        if not self.robot.is_real or self._easy_path is None or self._easy_fixed is not None:
            return self._nack(name, "仮想クレーンでは模擬の値（game_mode.easy.dry_run）を使う。実機でだけ記録する")
        if self.easy.active:
            return self._nack(name, "busy: the easy mode is catching / carrying")
        which = str(params.get("which", ""))
        saved = dict(self._easy_saved() or {})
        s = self.robot.snapshot()
        if which == "clear":
            saved = {}
        elif which in ("dial_1", "dial_2"):
            if not s.connected:
                return self._nack(name, "robot not connected")
            if not s.homed:
                return self._nack(name, "not homed: home first (XY must be known)")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                return self._nack(name, f"the arm is moving ({s.state}): wait until it stops")
            if not (math.isfinite(s.x) and math.isfinite(s.y) and self.easy.limits.xy_inside(s.x, s.y)):
                return self._nack(name, f"XY ({s.x:.1f},{s.y:.1f}) outside the soft limits")
            saved[which] = {"x": round(float(s.x), 2), "y": round(float(s.y), 2)}
        elif which in ("release_z", "catch_z"):
            if not s.connected:
                return self._nack(name, "robot not connected")
            if not s.z_reference_set:
                return self._nack(name, "Z の基準がない: W で一番上まで巻き上げて「上を記録」してから")
            if s.state != MachineState.IDLE or self._jog_owner is not None or self._motion_lock.locked():
                return self._nack(name, f"the arm is moving ({s.state}): wait until it stops")
            if self._z_counts_per_unit() is None:
                return self._nack(name, "Z の上と下を両方記録してから（Z の 1 単位が何 cm か分からない）")
            if saved and self._height_z_changed(saved) and (saved.get("release_z") is not None
                                                             or saved.get("catch_z") is not None):
                # the other height was recorded in the old Z units: it is recorded again too
                saved.pop("release_z", None)
                saved.pop("catch_z", None)
            saved[which] = round(float(s.z), 2)
            saved["z_counts_per_unit"] = self._z_counts_per_unit()  # what these Z values mean
        else:
            return self._nack(name, "which must be dial_1, dial_2, release_z, catch_z or clear")
        if which != "clear":
            saved["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        saved["confirmed"] = False
        log.info("easy mode's drop points saved (not confirmed yet): %s", saved)
        return self._easy_write(name, saved)

    def _easy_dial_confirm(self, params: dict) -> dict:
        """A person watched the arm over both Dials at the release height: the values may be used."""
        name = "easy_dial_confirm"
        if not self.robot.is_real or self._easy_path is None or self._easy_fixed is not None:
            return self._nack(name, "仮想クレーンでは模擬の値（game_mode.easy.dry_run）を使う。実機でだけ確かめる")
        if self.easy.active:
            return self._nack(name, "busy: the easy mode is catching / carrying")
        saved = self._easy_saved()
        if saved is None:
            return self._nack(name, "まだ記録していない（Dial 1・Dial 2 の位置と投入の高さ）")
        on = params.get("confirmed") is not False
        if on:
            self._easy_refresh()
            # everything but the confirmation itself
            errs = self.easy.easy.problems(self.easy.params, self.easy.limits, need_confirmed=False)
            if errs:
                return self._nack(name, "このままでは使えない: " + "; ".join(errs))
        log.info("easy mode's drop points %s", "confirmed" if on else "unconfirmed")
        return self._easy_write(name, {**saved, "confirmed": on})

    WORKSHEET_FIND_MAX_BYTES = 1_500_000

    async def _worksheet_find(self, params: dict) -> dict:
        """The study mode shows the real worksheet (#116): its four corner marks in the frame the
        game sends (as it shows it), found here with OpenCV. Nothing is kept or sent anywhere."""
        import base64
        import binascii
        from ..study_mode.sheet_marks import find_marks_jpeg
        name = "worksheet_find"
        b64 = params.get("image_jpeg_base64")
        if not isinstance(b64, str) or not b64:
            return self._nack(name, "image_jpeg_base64 is required")
        try:
            data = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            return self._nack(name, "image_jpeg_base64 is not base64")
        if len(data) > self.WORKSHEET_FIND_MAX_BYTES:
            return self._nack(name, "the image is too large")
        try:
            found = await asyncio.to_thread(find_marks_jpeg, data)
        except ValueError as e:
            return self._nack(name, str(e))
        return self._ack(name, {"found": found is not None, **(found or {})})

    async def _devicehub(self, name: str, params: dict) -> dict:
        """The settings screen's テスト tab (#108): UFO-DeviceHub's console commands."""
        from ..devicehub.service import DeviceHubError
        hub = self.devicehub
        if hub is None:
            return self._nack(name, "周辺機器のハブを使っていない（設定の devicehub.enabled をオンにして ./start.sh）")
        try:
            if name == "devicehub_meta":
                return self._ack(name, hub.meta())
            if name == "devicehub_devices":
                return self._ack(name, {"devices": await hub.devices()})
            if name == "devicehub_diag":
                return self._ack(name, {"diag": await hub.diag()})
            if name == "devicehub_status":
                return self._ack(name, {"device": params.get("device"), "status": await hub.status(int(params.get("device")))})
            if name == "devicehub_command":
                result = await hub.command(params.get("device"), params.get("name"), params.get("params") or {})
                return self._ack(name, {"result": result})
            if name == "devicehub_mock_ball":  # the simulated hub only (#138)
                return self._ack(name, await hub.mock_ball(params.get("device")))
            return self._ack(name, {"results": await hub.stop_all()})
        except (DeviceHubError, TypeError, ValueError) as e:
            return self._nack(name, str(e))

    @staticmethod
    def _allowed_during_auto(name: str, params: dict) -> bool:
        if name == "jog":  # a zero jog (key release) is harmless
            return not any(float(params.get(k, 0.0) or 0.0) for k in ("vx", "vy", "vz"))
        if name == "enable_motors":
            return not bool(params.get("enable", False))
        return False

    @staticmethod
    def _ack(name: str, data: dict) -> dict:
        return {"type": "ack", "data": {"command": name, **data}}

    # The tutor AI's "the problem is d_mm away" (#104) is never a motion: this only says where the
    # next staged capture (homework_approach, with all its own checks) would look.
    NAVIGATE_MAX_STEP_MM = 60.0

    def _homework_navigate(self, params: dict) -> dict:
        """{u, v, camera} (or xy on the mock) of the last capture + d_mm -> the next target as
        u, v of the overview image (or xy). Refused: a step over 60 mm or under 3 mm, outside the
        soft limits, outside the trusted camera calibration, xy on the real robot. Never moves."""
        from ..study_mode.navigation import NavigationError, plan_relative, xy_to_uv
        name = "homework_navigate"
        lim = self.approach.limits
        try:
            d = params.get("d_mm")
            if not isinstance(d, (list, tuple)) or len(d) != 2:
                raise ValueError("d_mm must be [dx, dy] (mm)")
            step = (float(d[0]), float(d[1]))
            max_step = min(float(params.get("max_step_mm", self.NAVIGATE_MAX_STEP_MM)), self.NAVIGATE_MAX_STEP_MM)
            ranges = {"x_range": (lim.x_min, lim.x_max), "y_range": (lim.y_min, lim.y_max), "max_step_mm": max_step}
            if "xy" in params:
                if self.robot.is_real:
                    return self._nack(name, "a target in mm (xy) is only for the mock robot: use u, v "
                                            "and the camera calibration")
                xy = params.get("xy")
                cur = (float(xy[0]), float(xy[1]))
                nxt = plan_relative(cur, step, **ranges)
                return self._ack(name, {"xy": list(nxt), "from": list(cur)})
            cam = camera_signature(params.get("camera"))
            cur = self.camera_map.to_xy(params.get("u"), params.get("v"), cam)
            nxt = plan_relative(cur, step, **ranges)
            u, v = xy_to_uv(self.camera_map.h_inv, *nxt)
            self.camera_map.to_xy(u, v, cam)  # the new point too must be inside the trusted calibration
        except (NavigationError, CameraMapError, TypeError, ValueError, IndexError) as e:
            return self._nack(name, f"移動先を決められません: {e}")
        return self._ack(name, {"u": u, "v": v, "xy": list(nxt), "from": list(cur)})

    @staticmethod
    def _nack(name: str, reason: str) -> dict:
        return {"type": "nack", "data": {"command": name, "reason": reason}}
