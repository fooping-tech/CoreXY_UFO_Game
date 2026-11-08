"""WebSocket/JSON bridge between Godot and the robot / vision services.

Messages (all JSON objects with "type" and "timestamp" in ms):
  server -> client : robot_state, ack, nack, error, vision_event, log, hello
  client -> server : hello, command {request_id, data:{name, params}}, ping

Command names and safety rules:
  enable_motors {enable}  must be sent (true) before any motion command.
  home, move_xy {x,y,feed?}, move_z {z}, z_zero (= z_set top),
  z_set {which: top|bottom|clear} (record the arm's height as its top / bottom; both =
  measured counts per unit, saved; clear = start over), z_servo_recover (after the drum
  servo's power was cut alone: a SERVO_TURN the firmware refuses unmoved, so the next jog
  sets it to multi-turn again; a motion command), grab {close}, stop (ABORT, emergency),
  soft_stop (decelerate, no alarm), jog {vx,vy,vz?} (mm/s; vz = Z value/s; dead-man: resend ~20 Hz while
  held, {0,0} on release; the firmware stops after 250 ms without one; the host also
  sends a zero jog when the jogging client disconnects or its refresh is older than
  jog_expiry_s), clear_alarm,
  get_state, list_ports, gesture_config {pinch_start?, pinch_release?, pinch_confirm_ms?, ...}
  (hand joystick thresholds at run time; vision only), arm_step {deg} (claw servo ID 2 turned
  by deg degrees, relative, |deg| <= 90; a motion command), arm_zero (claw angle reference),
  arm_set {which: closed|open} (record the claw's current angle as that position; saved),
  arm_goto {which} (turn the claw there, on the closed..open arc; a motion command),
  auto_catch (start the one-button catch sequence; ACK = started, progress in robot_state.auto_catch
  and {"type": "auto_catch"} messages), auto_catch_status
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
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import OrderedDict
from typing import Any

import websockets
from websockets.asyncio.server import ServerConnection, serve

from ..config import BackendConfig, RobotLimits
from ..robot.interface import RobotCommandError, RobotInterface
from ..sequence import AutoCatchConfig, AutoCatchSequencer

log = logging.getLogger(__name__)

# Serial lines not forwarded to the game's log (periodic position reports).
SERIAL_LOG_SKIP = ("TX POS", "RX POS ", "RX JOG_POS ")
LOG_QUEUE_MAX = 500

COMMANDS = ("enable_motors", "home", "move_xy", "move_z", "z_zero", "z_set", "z_servo_recover", "grab", "stop", "soft_stop", "jog",
            "clear_alarm", "get_state", "list_ports", "gesture_config", "arm_step", "arm_zero",
            "arm_set", "arm_goto", "auto_catch", "auto_catch_status")
MOTION_COMMANDS = ("home", "move_xy", "move_z", "grab", "arm_step", "arm_goto", "z_servo_recover")
# Never queued behind another command of the same connection: a stop must reach
# the robot while a move_xy of that connection is still running.
PRIORITY_COMMANDS = ("stop", "soft_stop", "jog", "get_state", "auto_catch_status")
# Accepted while the auto catch runs (anything else is refused as busy).
AUTO_CATCH_ALLOWED = ("stop", "soft_stop", "get_state", "auto_catch", "auto_catch_status", "list_ports",
                      "gesture_config")


def now_ms() -> int:
    return int(time.time() * 1000)


class GameServer:
    def __init__(self, robot: RobotInterface, host: str = "127.0.0.1", port: int = 8765, *,
                 state_hz: float = 30.0, vision: Any | None = None,
                 auto_catch: AutoCatchConfig | None = None, backend_cfg: BackendConfig | None = None,
                 study: Any | None = None, homework: Any | None = None) -> None:
        self.robot = robot
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
        self.auto = AutoCatchSequencer(
            robot, ac.real if robot.name == "real" else ac.dry_run,
            getattr(robot, "limits", None) or (backend_cfg.limits if backend_cfg else RobotLimits()),
            backend_cfg, lock=self._motion_lock, is_jogging=lambda: self._jog_owner is not None,
            on_change=self._on_auto_change)
        self._auto_owner: ServerConnection | None = None

    # ------------------------------------------------------------ lifecycle
    async def start(self) -> None:
        self._server = await serve(self._handle_client, self.host, self.port, ping_interval=5, ping_timeout=5)
        self._tasks.append(asyncio.create_task(self._poll_loop()))
        self._tasks.append(asyncio.create_task(self._state_loop()))
        if self.vision is not None:
            self.vision.on_event = self._on_vision_event
        self._start_log_feed()
        log.info("websocket listening on ws://%s:%d", self.host, self.port)

    async def stop(self) -> None:
        if self.auto.active:
            await self.auto.abort("backend shutting down during auto catch")
            await self.auto.wait()
        if self.study is not None:
            await self.study.close()
        if self.homework is not None:
            await self.homework.close()
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
                msg["data"]["auto_catch"] = self.auto.status()
                await self.broadcast(msg)
            except Exception:  # pragma: no cover
                log.exception("state loop")
            next_t += self.state_interval
            now = loop.time()
            if next_t < now:
                next_t = now + self.state_interval
            await asyncio.sleep(max(next_t - now, 0.0))

    def _on_auto_change(self, status: dict) -> None:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:  # pragma: no cover
            return
        loop.create_task(self.broadcast({"type": "auto_catch", "timestamp": now_ms(), "data": status}))

    def _on_vision_event(self, event: dict) -> None:
        asyncio.get_event_loop().create_task(self.broadcast({"type": "vision_event", "timestamp": now_ms(), "data": event}))

    # ------------------------------------------------------------ clients
    async def _handle_client(self, ws: ServerConnection) -> None:
        self.clients.add(ws)
        log.info("client connected (%d)", len(self.clients))
        try:
            await ws.send(json.dumps({"type": "hello", "timestamp": now_ms(), "data": {"server": "corexy-ufo-backend", "robot": self.robot.name, "commands": list(COMMANDS), "study": self.study is not None, "study_provider": self._study_provider(), "homework": self.homework is not None}}))
            await ws.send(json.dumps(self.robot.snapshot().to_message()))
            queue: asyncio.Queue = asyncio.Queue()
            worker = asyncio.create_task(self._ordered_worker(ws, queue))
            out_of_band: set[asyncio.Task] = set()
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
                    else:
                        queue.put_nowait(msg)
            finally:
                # The client is gone: drop queued commands (no move should start for a
                # client that left), let a running one finish (never cancel a move half-way).
                while not queue.empty():
                    queue.get_nowait()
                queue.put_nowait(None)
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
            if self._auto_owner is ws and self.auto.active:
                # nobody left who could press stop: end the sequence in the safe state
                log.warning("the client running the auto catch disconnected: aborting it")
                await self.auto.abort("operator disconnected during auto catch")

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
                result = await self.homework.start(session_id)
                self._homework_sessions.setdefault(ws, set()).add(session_id)
                await self._study_send(ws, {"type": "homework_status", "data": result})
            elif msg["type"] == "homework_frame":
                started = await self.homework.frame(session_id, rid, str(data.get("image_jpeg_base64", "")),
                                                    lambda reply: self._study_send(ws, reply))
                await self._study_send(ws, {"type": "homework_status", "request_id": rid, "data": {
                    "session_id": session_id, "state": "estimating" if started else "skipped"}})
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
        if name == "auto_catch" and reply.get("type") == "ack":
            self._auto_owner = ws
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
        try:
            if self.auto.active and name not in AUTO_CATCH_ALLOWED and not self._allowed_during_auto(name, params):
                return self._nack(name, "busy: auto catch running (stop to abort)")
            if name in MOTION_COMMANDS and self._motion_lock.locked():
                return self._nack(name, "busy: another motion command is running")
            if name == "get_state":
                data = self.robot.snapshot().to_message()["data"]
                data["auto_catch"] = self.auto.status()
                return self._ack(name, data)
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
                return self._ack(name, {"ports": list_serial_ports()})
            if name == "enable_motors":
                if not bool(params.get("enable", False)):
                    await self.auto.abort("motors disabled during auto catch")
                await self.robot.enable_motors(bool(params.get("enable", False)))
            elif name == "stop":
                self._jog_owner = None  # stopped: nothing left for the jog expiry to stop
                # flag first (no new step can start), then ABORT without any wait in between
                await self.auto.abort("emergency stop (stop)", send_stop=False)
                await self.robot.stop()
            elif name == "soft_stop":
                self._jog_owner = None
                if self.auto.active:
                    # STOP does not stop the servos (Z drum, claw): end the sequence with ABORT
                    await self.auto.abort("stopped (soft_stop) during auto catch")
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
                await self.robot.jog(vx, vy, vz)
            elif name == "clear_alarm":
                await self.robot.clear_alarm()
            elif name == "z_zero":
                await self.robot.set_z_zero()
            elif name == "z_set":
                await self.robot.set_z_point(str(params.get("which", "")))
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
        except (KeyError, ValueError, TypeError) as e:
            return self._nack(name, f"bad params: {e}")
        except RobotCommandError as e:
            return self._nack(name, str(e))
        except Exception as e:  # pragma: no cover
            log.exception("command %s failed", name)
            return self._nack(name, f"internal error: {e}")

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

    @staticmethod
    def _nack(name: str, reason: str) -> dict:
        return {"type": "nack", "data": {"command": name, "reason": reason}}
