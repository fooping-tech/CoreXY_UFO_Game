"""#118: the arm-tip camera, stabilized, streamed to the game on its own WebSocket port.

A separate port from the game's control connection: a megabyte or two of JPEG a second never
sits in front of robot_state, an ACK or a stop. The camera is opened while a client is
connected (and a moment after, so a reconnect does not reopen it) and released otherwise.
A slow client gets the newest frame only: frames are never queued.

Messages to the client:
  binary  b"FCS1" + uint32 LE header length + header JSON + JPEG
          header = {seq, t_ms, w, h, stabilized, dx, dy, rot_deg, points, tracking, fps}
  text    {"type": "focus_status", "data": {"state": "opening"|"streaming"|"error", "message"?}}
Messages from the client (text JSON):
  {"stabilize": true|false}  turn the correction on or off (to compare)

Display only: frames are drawn by the game (and used for the study mode's photo like the
camera it replaces); nothing here reaches the robot.
"""

from __future__ import annotations

import asyncio
import json
import logging
import struct
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import cv2
import numpy as np
import websockets

from .stabilizer import Stabilizer, StabilizerParams

log = logging.getLogger(__name__)

MAGIC = b"FCS1"


@dataclass
class FocusStreamParams:
    enabled: bool = True
    port: int = 8766
    camera: str = "Innomaker"   # part of the camera's name, or an index
    width: int = 1280
    height: int = 720
    fps: float = 30.0
    jpeg_quality: int = 80
    linger_s: float = 3.0       # the camera stays open this long after the last client leaves
    stabilizer: StabilizerParams = field(default_factory=StabilizerParams)

    @classmethod
    def from_raw(cls, raw: dict[str, Any] | None) -> FocusStreamParams:
        cam = ((raw or {}).get("camera") or {})
        focus = cam.get("focus") or {}
        s = focus.get("stabilize") or {}
        p = cls(enabled=bool(cam.get("enabled", True)) and bool(s.get("enabled", False)),
                camera=str(focus.get("match", "") or s.get("camera", "")),
                stabilizer=StabilizerParams.from_raw(s))
        for k in ("port", "width", "height", "jpeg_quality"):
            if isinstance(s.get(k), int) and not isinstance(s.get(k), bool):
                setattr(p, k, int(s[k]))
        for k in ("fps", "linger_s"):
            if isinstance(s.get(k), (int, float)) and not isinstance(s.get(k), bool):
                setattr(p, k, float(s[k]))
        p.jpeg_quality = max(30, min(p.jpeg_quality, 95))
        p.fps = max(1.0, min(p.fps, 60.0))
        return p


def pack(header: dict[str, Any], jpeg: bytes) -> bytes:
    h = json.dumps(header, separators=(",", ":")).encode()
    return MAGIC + struct.pack("<I", len(h)) + h + jpeg


def unpack(data: bytes) -> tuple[dict[str, Any], bytes]:
    if len(data) < 8 or data[:4] != MAGIC:
        raise ValueError("not a focus frame")
    n = struct.unpack("<I", data[4:8])[0]
    if 8 + n > len(data):
        raise ValueError("truncated focus frame")
    return json.loads(data[8:8 + n]), data[8 + n:]


def open_camera(p: FocusStreamParams) -> Any:
    from .cameras import resolve_camera
    index = resolve_camera(p.camera or "0")
    if sys.platform == "darwin":
        cap = cv2.VideoCapture(index, cv2.CAP_AVFOUNDATION)
    elif sys.platform == "win32":
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
    else:
        cap = cv2.VideoCapture(index)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, p.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, p.height)
    cap.set(cv2.CAP_PROP_FPS, p.fps)
    if not cap.isOpened():
        cap.release()
        raise OSError(f"camera {p.camera!r} (index {index}) could not be opened")
    return cap


class FocusStream:
    def __init__(self, params: FocusStreamParams, host: str = "127.0.0.1",
                 opener: Callable[[FocusStreamParams], Any] = open_camera) -> None:
        self.p = params
        self.host = host
        self.opener = opener
        self.stabilize = True
        self.clients: set[Any] = set()
        self.state = "idle"
        self.message = ""
        self.frames = 0
        self._server: Any = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._latest: bytes | None = None
        self._new = asyncio.Event()
        self._thread: threading.Thread | None = None
        self._halt = threading.Event()
        self._linger: asyncio.TimerHandle | None = None

    @property
    def port(self) -> int:
        if self._server is not None and self._server.sockets:
            return int(next(iter(self._server.sockets)).getsockname()[1])
        return self.p.port

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._server = await websockets.serve(self._client, self.host, self.p.port, compression=None,
                                              max_size=64 * 1024, ping_interval=5, ping_timeout=10)
        log.info("arm camera stream (stabilized) on ws://%s:%d, camera %r", self.host, self.port, self.p.camera)

    async def stop(self) -> None:
        if self._linger is not None:
            self._linger.cancel()
        await self._stop_camera()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    # ------------------------------------------------------------ clients
    async def _client(self, ws: Any) -> None:
        self.clients.add(ws)
        if self._linger is not None:
            self._linger.cancel()
            self._linger = None
        self._start_camera()
        reader = asyncio.create_task(self._read(ws))
        try:
            await self._send_status(ws)
            seq_sent = None
            while not reader.done():
                ev = self._new
                waiter = asyncio.create_task(ev.wait())
                done, _ = await asyncio.wait({waiter, reader}, return_when=asyncio.FIRST_COMPLETED)
                if reader in done:
                    waiter.cancel()
                    break
                data = self._latest
                if data is not None and data is not seq_sent:
                    seq_sent = data
                    await ws.send(data)
        except websockets.ConnectionClosed:
            pass
        finally:
            reader.cancel()
            self.clients.discard(ws)
            if not self.clients and self._loop is not None:
                self._linger = self._loop.call_later(self.p.linger_s,
                                                     lambda: asyncio.ensure_future(self._stop_if_idle()))

    async def _read(self, ws: Any) -> None:
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if isinstance(msg, dict) and isinstance(msg.get("stabilize"), bool):
                    self.stabilize = msg["stabilize"]
                    log.info("arm camera stabilization %s", "on" if self.stabilize else "off")
        except websockets.ConnectionClosed:
            pass

    async def _send_status(self, ws: Any) -> None:
        data: dict[str, Any] = {"state": self.state}
        if self.message:
            data["message"] = self.message
        try:
            await ws.send(json.dumps({"type": "focus_status", "data": data}))
        except websockets.ConnectionClosed:
            pass

    def _set_state(self, state: str, message: str = "") -> None:
        """From the camera thread."""
        def apply() -> None:
            self.state, self.message = state, message
            for c in list(self.clients):
                asyncio.ensure_future(self._send_status(c))
        if self._loop is not None:
            try:
                self._loop.call_soon_threadsafe(apply)
            except RuntimeError:  # pragma: no cover - loop closed
                pass

    def _publish(self, data: bytes) -> None:
        self._latest = data
        ev, self._new = self._new, asyncio.Event()
        ev.set()

    async def _stop_if_idle(self) -> None:
        self._linger = None
        if not self.clients:
            await self._stop_camera()

    # ------------------------------------------------------------ camera thread
    def _start_camera(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._halt.clear()
        self._thread = threading.Thread(target=self._run, name="focus-stream", daemon=True)
        self._thread.start()

    async def _stop_camera(self) -> None:
        self._halt.set()
        t, self._thread = self._thread, None
        if t is not None:
            await asyncio.to_thread(t.join, 3.0)
        self._latest = None
        self.state = "idle"

    def _run(self) -> None:
        self._set_state("opening")
        try:
            cap = self.opener(self.p)
        except (OSError, ValueError) as e:
            log.error("arm camera stream: %s", e)
            self._set_state("error", str(e))
            return
        stab = Stabilizer(self.p.stabilizer)
        quality = [int(cv2.IMWRITE_JPEG_QUALITY), self.p.jpeg_quality]
        seq = 0
        fps = 0.0
        last = None
        fails_since = None
        try:
            self._set_state("streaming")
            while not self._halt.is_set():
                ok, frame = cap.read()
                now = time.monotonic()
                if not ok or frame is None:
                    fails_since = fails_since or now
                    if now - fails_since > 2.0:
                        self._set_state("error", "the camera stopped sending frames")
                        return
                    time.sleep(0.02)
                    continue
                if fails_since is not None:
                    fails_since = None
                    self._set_state("streaming")
                if last is not None:
                    fps = fps * 0.9 + 0.1 / max(now - last, 1e-3)
                last = now
                if self.stabilize:
                    out, info = stab.update(frame, now)
                else:
                    stab.reset()
                    out, info = frame, {"dx": 0.0, "dy": 0.0, "rot_deg": 0.0, "points": 0, "tracking": False}
                ok, jpg = cv2.imencode(".jpg", out, quality)
                if not ok:
                    continue
                seq += 1
                self.frames = seq
                h, w = out.shape[:2]
                header = {"seq": seq, "t_ms": int(time.time() * 1000), "w": w, "h": h,
                          "stabilized": self.stabilize, "fps": round(fps, 1), **info}
                data = pack(header, jpg.tobytes())
                if self._loop is not None:
                    try:
                        self._loop.call_soon_threadsafe(self._publish, data)
                    except RuntimeError:  # pragma: no cover - loop closed
                        return
        finally:
            cap.release()
