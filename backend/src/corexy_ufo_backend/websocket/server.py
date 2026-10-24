"""WebSocket/JSON bridge between Godot and the robot / vision services.

Messages (all JSON objects with "type" and "timestamp" in ms):
  server -> client : robot_state, ack, nack, error, vision_event, log, hello
  client -> server : hello, command {request_id, data:{name, params}}, ping

Command names and safety rules:
  enable_motors {enable}  must be sent (true) before any motion command.
  home, move_xy {x,y,feed?}, move_z {z}, z_zero, grab {close}, stop (ABORT, emergency),
  soft_stop (decelerate, no alarm), jog {vx,vy} (mm/s, dead-man: resend ~20 Hz while
  held, {0,0} on release; the firmware stops after 250 ms without one), clear_alarm,
  get_state, list_ports
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

from ..robot.interface import RobotCommandError, RobotInterface

log = logging.getLogger(__name__)

COMMANDS = ("enable_motors", "home", "move_xy", "move_z", "z_zero", "grab", "stop", "soft_stop", "jog",
            "clear_alarm", "get_state", "list_ports")
MOTION_COMMANDS = ("home", "move_xy", "move_z", "grab")
# Never queued behind another command of the same connection: a stop must reach
# the robot while a move_xy of that connection is still running.
PRIORITY_COMMANDS = ("stop", "soft_stop", "jog", "get_state")


def now_ms() -> int:
    return int(time.time() * 1000)


class GameServer:
    def __init__(self, robot: RobotInterface, host: str = "127.0.0.1", port: int = 8765, *,
                 state_hz: float = 30.0, vision: Any | None = None) -> None:
        self.robot = robot
        self.host = host
        self.port = port
        self.state_interval = 1.0 / state_hz
        self.vision = vision
        self.clients: set[ServerConnection] = set()
        self._handled: OrderedDict[str, dict] = OrderedDict()
        self._server = None
        self._tasks: list[asyncio.Task] = []
        self._motion_lock = asyncio.Lock()

    # ------------------------------------------------------------ lifecycle
    async def start(self) -> None:
        self._server = await serve(self._handle_client, self.host, self.port, ping_interval=5, ping_timeout=5)
        self._tasks.append(asyncio.create_task(self._poll_loop()))
        self._tasks.append(asyncio.create_task(self._state_loop()))
        if self.vision is not None:
            self.vision.on_event = self._on_vision_event
        log.info("websocket listening on ws://%s:%d", self.host, self.port)

    async def stop(self) -> None:
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
            except Exception:  # pragma: no cover
                log.exception("poll loop")
            await asyncio.sleep(0.01)

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
                snap = self.robot.snapshot()
                await self.broadcast(snap.to_message())
            except Exception:  # pragma: no cover
                log.exception("state loop")
            next_t += self.state_interval
            now = loop.time()
            if next_t < now:
                next_t = now + self.state_interval
            await asyncio.sleep(max(next_t - now, 0.0))

    def _on_vision_event(self, event: dict) -> None:
        asyncio.get_event_loop().create_task(self.broadcast({"type": "vision_event", "timestamp": now_ms(), "data": event}))

    # ------------------------------------------------------------ clients
    async def _handle_client(self, ws: ServerConnection) -> None:
        self.clients.add(ws)
        log.info("client connected (%d)", len(self.clients))
        try:
            await ws.send(json.dumps({"type": "hello", "timestamp": now_ms(), "data": {"server": "corexy-ufo-backend", "robot": self.robot.name, "commands": list(COMMANDS)}}))
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
            log.info("client disconnected (%d)", len(self.clients))

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
        else:
            await ws.send(json.dumps({"type": "error", "timestamp": now_ms(), "data": {"message": f"unknown type {t}"}}))

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
            if name in MOTION_COMMANDS and self._motion_lock.locked():
                return self._nack(name, "busy: another motion command is running")
            if name == "get_state":
                return self._ack(name, self.robot.snapshot().to_message()["data"])
            if name == "list_ports":
                from ..serial_service.transport import list_serial_ports
                return self._ack(name, {"ports": list_serial_ports()})
            if name == "enable_motors":
                await self.robot.enable_motors(bool(params.get("enable", False)))
            elif name == "stop":
                await self.robot.stop()
            elif name == "soft_stop":
                # outside the motion lock: it must reach a running move
                await self.robot.soft_stop()
            elif name == "jog":
                # Dead-man refresh, sent ~20 Hz while a key is held; never retried. Outside
                # the motion lock, but refused while a home/move/grab command is running.
                vx, vy = float(params.get("vx", 0.0)), float(params.get("vy", 0.0))
                if (vx or vy) and self._motion_lock.locked():
                    return self._nack(name, "busy: another motion command is running")
                await self.robot.jog(vx, vy)
            elif name == "clear_alarm":
                await self.robot.clear_alarm()
            elif name == "z_zero":
                await self.robot.set_z_zero()
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
            return self._ack(name, self.robot.snapshot().to_message()["data"])
        except (KeyError, ValueError, TypeError) as e:
            return self._nack(name, f"bad params: {e}")
        except RobotCommandError as e:
            return self._nack(name, str(e))
        except Exception as e:  # pragma: no cover
            log.exception("command %s failed", name)
            return self._nack(name, f"internal error: {e}")

    @staticmethod
    def _ack(name: str, data: dict) -> dict:
        return {"type": "ack", "data": {"command": name, **data}}

    @staticmethod
    def _nack(name: str, reason: str) -> dict:
        return {"type": "nack", "data": {"command": name, "reason": reason}}
