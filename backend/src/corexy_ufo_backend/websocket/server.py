"""WebSocket/JSON bridge between Godot and the robot / vision services.

Messages (all JSON objects with "type" and "timestamp" in ms):
  server -> client : robot_state, ack, nack, error, vision_event, log, hello
  client -> server : hello, command {request_id, data:{name, params}}, ping

Command names and safety rules:
  enable_motors {enable}  must be sent (true) before any motion command.
  home (XY homing, then on to the middle of the stage: backend.home_then_center, #175), move_xy {x,y,feed?}, move_z {z},
  park (#276: the arm to its waiting point, the left back corner by default, at backend.park_feed_mm_min;
  refused while another motion runs, a jog is on, or the arm is not wound up),
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
  sheet_read {image_jpeg_base64, calc?, crop?} (#230: the 設定 screen's プリント tab: a camera frame
  -> the learning support AI's worksheet reader, POST /v1/sheet -> {problems, counts, summary, ...};
  ~10 s; never the robot, never queued, nothing kept),
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
{destination: 1, grab_id} (only while that catch waits for its destination, once: carry to
Dial 1, the only portal since #200, at the safe height, lower, open, up), easy_status. #177: easy_grab with the arm
below the safe height closes the claw where it is and raises it (nothing goes down); easy_reset
(the start of a game) opens the claw and raises the arm to the top from any height. #179:
easy_cancel {grab_id} (only while that catch waits for its destination, once): the claw opens
where it is and the run ends (last_result "cancelled"); nothing is carried. Nothing chosen within
game_mode.easy.wait_destination_s: the run ends EXPIRED with the claw still closed (nothing
moved, nothing released, no ABORT). The Dial's drop point of the real crane: easy_dial_set
{which: dial_1 (the arm's XY now: the portal) | release_z (its Z now) | clear} saves them in
calibration.json#easy_dials (#299: no confirmation step; the catch height is the Z bottom
record); unrecorded = easy_grab refused on the real robot. The saved
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
from ..sequence.easy import EasyParams, EasySequencer
from ..sequence.prepare import PrepareSequencer
from ..study_mode.height import HeightCalibration, HeightError

log = logging.getLogger(__name__)

from .easy_calibration import EasyCalibrationMixin
from .log_feed import LogFeedMixin
from .study_height import StudyHeightMixin
from .wire import (APPROACH_ALLOWED, AUTO_CATCH_ALLOWED, CANCEL_ON_DISCONNECT, CLEANUP_ALLOWED, COMMANDS,
                   DEVICEHUB_COMMANDS, EASY_ALLOWED, MOTION_COMMANDS, PREPARE_ALLOWED, PRIORITY_COMMANDS, now_ms)


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


class GameServer(LogFeedMixin, StudyHeightMixin, EasyCalibrationMixin):
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
            center=lambda: self.backend_cfg.home_center() if self.backend_cfg is not None else None,
            center_feed=lambda: self.backend_cfg.fast_feed() if self.backend_cfg is not None else None,
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
                "study_ai": "local" if self.homework is not None and self.homework.study_local else "cloud",
                "study_voice": self.homework is not None and self.homework.voice_available,
                "study_voice_problem": self.homework.voice_problem() if self.homework is not None else "",
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
            if self.homework is not None and self.homework.listen_cancel(ws):
                log.info("voice: the listening client disconnected: the recording is dropped")
            log.info("client disconnected (%d)", len(self.clients))
            if not self.clients:
                self.robot.jog_boost(0)  # #188: nobody left who asked for the SPEED UP
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
                                                    lambda reply: self._study_send(ws, reply), roi=data.get("roi"))
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
                                           worksheet_id=str(data.get("worksheet_id", "")), roi=data.get("roi"))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "session_id": session_id, "state": "locating", "kind": str(data.get("kind", ""))}})
            elif msg["type"] == "homework_explain":
                await self.homework.explain(rid, data.get("images") or [], int(data.get("problem", 3) or 3),
                                            str(data.get("grade_label", "")), str(data.get("worksheet_id", "")),
                                            lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "state": "explaining"}})
            elif msg["type"] == "homework_listen_start":  # #233: push to talk (held)
                await self.homework.listen_start(ws, rid, lambda reply: self._study_send(ws, reply))
            elif msg["type"] == "homework_listen_stop":  # let go: the text comes as homework_heard
                await self.homework.listen_stop(ws, rid, lambda reply: self._study_send(ws, reply))
            elif msg["type"] == "homework_listen_cancel":
                self.homework.listen_cancel(ws)
            elif msg["type"] == "homework_talk":  # what the child said + the worksheet -> the tutor
                target = data.get("target_problem")
                await self.homework.talk(rid, str(data.get("text", "")), str(data.get("image_jpeg_base64", "")),
                                         lambda reply: self._study_send(ws, reply),
                                         target=int(target) if isinstance(target, (int, float)) and target else None,
                                         history=data.get("history") if isinstance(data.get("history"), list) else [],
                                         worksheet_id=str(data.get("worksheet_id", "")))
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
        if name == "sheet_read":  # #230: a camera frame -> POST /v1/sheet; never the robot
            return await self._sheet_read(params)
        if name in ("focus_calibrate", "focus_status"):  # #242: the arm-tip camera's calibration; never the robot
            return await self._focus_calibration(name, params)
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
            if name == "easy_cancel":
                self.easy.cancel(params.get("grab_id"))
                return self._ack(name, self.easy.status())
            if name == "easy_goto":
                return await self._easy_goto(params)
            if name == "easy_dial_set":
                return self._easy_dial_set(params)
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
                if not bool(params.get("enable", False)):
                    self.robot.jog_boost(0)
                await self.robot.enable_motors(bool(params.get("enable", False)))
            elif name == "stop":
                self._jog_owner = None  # stopped: nothing left for the jog expiry to stop
                self.robot.jog_boost(0)  # #188: a stop ends the SPEED UP too
                # flag first (no new step can start), then ABORT without any wait in between
                for s in self.sequences:
                    await s.seq.abort("emergency stop (stop)", send_stop=False)
                await self.robot.stop()
            elif name == "soft_stop":
                self._jog_owner = None
                # #188: the SPEED UP's cap is NOT ended here. The game sends soft_stop whenever
                # the hand is lost or the window loses focus, and goes on with the same power
                # when the hand is back: ending it here left the screen saying SPEED UP while
                # the crane was at its usual cap. Its deadline still ends it; so do the
                # emergency stop, motors off, the game's jog_boost 0 and the last client leaving.
                for s in self.sequences:
                    if s.seq.active:
                        if s.seq is self.easy and self.easy.stop_waiting("stopped (soft_stop)"):
                            # #179: it only waits for the destination: nothing moves, so there is
                            # nothing ABORT would have to cut. The run ends there, with no alarm.
                            continue
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
            elif name == "jog_boost":
                # #188 (SPEED UP): the jog's XY cap is backend.jog_boost_mm_s for `seconds`
                # (at most backend.jog_boost_max_s), then the usual one again by itself: the
                # deadline is kept here, so a game that dies cannot leave it raised. It moves
                # nothing; the edge margin, the dead-man and the stops are as always. Ended at
                # once by stop (the emergency stop), motors off, seconds 0 and the last client
                # leaving; a soft_stop only stops the motion (the game sends 0 when the power ends).
                try:
                    seconds = float(params.get("seconds", 0.0))
                except (TypeError, ValueError):
                    return self._nack(name, "bad params: seconds must be a number")
                if not math.isfinite(seconds):
                    return self._nack(name, "bad params: seconds must be a number")
                if seconds > 0 and self.robot.jog_boost_mm_s <= 0:
                    return self._nack(name, "no jog boost is configured (backend.jog_boost_mm_s)")
                lasts = self.robot.jog_boost(seconds)
                return self._ack(name, {"seconds": round(lasts, 2),
                                        "cap_mm_s": self.robot.jog_boost_mm_s if lasts > 0 else 0.0})
            elif name == "clear_alarm":
                await self.robot.clear_alarm()
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
            elif name == "park":
                # #276: the arm out of the way of the screen (the left back corner), slowly.
                # Nobody steers it: only when nothing else moves and the arm is wound up.
                if self.backend_cfg is None:
                    return self._nack(name, "park: no backend config")
                if self._motion_lock.locked():
                    return self._nack(name, "busy: another motion command is running")
                if self._jog_owner is not None:
                    return self._nack(name, "busy: jog active")
                why = self.robot.travel_height_refusal()
                if why:
                    return self._nack(name, f"park refused: {why}")
                x, y = self.backend_cfg.park_point()
                async with self._motion_lock:
                    await self.robot.move_xy(x, y, self.backend_cfg.park_feed_mm_min)
            else:
                async with self._motion_lock:
                    if name == "home":
                        await self.robot.home()
                        await self._center_after_home()
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

    async def _center_after_home(self) -> None:
        """#175: homed (in the home corner): on to the middle of the stage, with the usual XY
        move and all its checks, still inside the motion lock. A stop ends it like any move."""
        center = self.backend_cfg.home_center() if self.backend_cfg is not None else None
        if center is None:
            return
        try:
            await self.robot.move_xy(*center, self.backend_cfg.fast_feed())
        except RobotCommandError as e:
            raise RobotCommandError(f"homed, but the move to the middle of the stage did not finish: {e}") from e

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

    SHEET_READ_MAX_BYTES = 4 * 1024 * 1024

    async def _focus_calibration(self, name: str, params: dict) -> dict:
        """#242: the 校正 tab moved the arm (move_xy) and took the arm-tip camera's pictures; this
        works out how a move in mm shifts the picture (study_mode/navigation.calibrate_from_jpegs)
        and keeps it in calibration.json#focus_camera (as tools/calibrate_focus.py). focus_status:
        which heights are calibrated."""
        import base64
        import binascii
        from ..study_mode.navigation import NavigationError, calibrate_from_jpegs, px_per_mm
        target = getattr(self.backend_cfg, "focus_camera_path", None) if self.backend_cfg is not None else None
        raw: dict = {}
        if target is not None and target.exists():
            try:
                raw = json.loads(target.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                raw = {}
        heights = raw.get("heights") if isinstance(raw.get("heights"), dict) else {}
        if name == "focus_status":
            return self._ack(name, {"heights": {k: {"px_per_mm": px_per_mm(v.get("A")), "residual_px": v.get("residual_px")}
                                                for k, v in heights.items() if isinstance(v, dict) and v.get("A")}})
        if target is None:
            return self._nack(name, "校正の保存先がありません（設定ファイルの場所）")
        height = str(params.get("height", "10cm"))
        try:
            def pictures(d: dict, one: str, many: str) -> list[bytes]:
                # one picture, or several in a row while the camera still swings (at most 12)
                got = d.get(many) if isinstance(d.get(many), list) else [d.get(one, "")]
                return [base64.b64decode(str(x), validate=True) for x in got[:12]]
            base = pictures(params, "base_jpeg_base64", "base_images_jpeg_base64")
            moves = [(pictures(m, "image_jpeg_base64", "images_jpeg_base64"), float(m["dx"]), float(m["dy"]))
                     for m in params.get("moves") or [] if isinstance(m, dict)]
            if not all(base) or not all(all(m[0]) for m in moves):
                base = []
        except (binascii.Error, ValueError, KeyError, TypeError):
            return self._nack(name, "画像か移動量が読めません")
        if not base or len(moves) < 2:
            return self._nack(name, "基準の画像と、X・Y に動かした画像が要ります")
        try:
            result = await asyncio.to_thread(calibrate_from_jpegs, base, moves)
        except NavigationError as e:
            return self._nack(name, str(e))
        heights[height] = {"A": result["A"], "image": result["image"], "residual_px": result["residual_px"]}
        raw["heights"] = heights
        target.write_text(json.dumps(raw, ensure_ascii=False, indent=1), encoding="utf-8")
        log.info("focus camera calibrated at %s: %.1f px/mm, residual %s px", height, result["px_per_mm"], result["residual_px"])
        return self._ack(name, {"height": height, **result})

    async def _sheet_read(self, params: dict) -> dict:
        """The プリント tab's check (#230): one frame of a connected camera, read by the learning
        support AI's worksheet reader with the study.tutor_* settings. The frame is not kept."""
        import base64
        import binascii
        from dataclasses import replace
        from ..config import REPO_ROOT
        from ..study import StudyConfig, make_sheet_client
        from ..study.sheet_client import SheetError, parse_roi, sheet_payload
        name = "sheet_read"
        b64 = params.get("image_jpeg_base64")
        if not isinstance(b64, str) or not b64:
            return self._nack(name, "image_jpeg_base64 is required")
        try:
            data = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            return self._nack(name, "image_jpeg_base64 is not base64")
        if len(data) > self.SHEET_READ_MAX_BYTES:
            return self._nack(name, "the image is too large")
        cfg = self.backend_cfg
        study = replace(StudyConfig.from_raw(cfg.raw if cfg is not None else {}), root=str(REPO_ROOT))
        try:
            roi = parse_roi(params.get("roi"))
            client = make_sheet_client(study)
            calc, crop = params.get("calc") is not False, params.get("crop") is not False
            if roi is not None:
                # #298: a fixed camera's frame with where the sheet lies: the server cuts it out, one request
                res = await asyncio.to_thread(client.read, data, calc=calc, crop=crop, roi=roi)
            else:
                # #252: the sheet found in the frame and straightened (else the problems cut out and read again)
                read = client.read if params.get("zoom") is False else client.read_sheet
                res = await asyncio.to_thread(read, data, calc=calc, crop=crop)
        except SheetError as e:
            return self._nack(name, str(e))
        if self.homework is not None:  # #287: the answer check's reading: the print's answers for the dialogue
            self.homework.note_sheet(res.problems)
        return self._ack(name, sheet_payload(res))

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
        if name == "jog_boost":  # #188: only a cap for the next jogs; it moves nothing
            return True
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
