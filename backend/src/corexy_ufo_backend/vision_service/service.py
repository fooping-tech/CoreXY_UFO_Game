"""VisionService: up to two cameras, each feeding an object detector and/or a
hand tracker. Capture + inference run in worker threads so neither Godot's
WebSocket traffic nor the serial link is ever blocked. Results are turned
into `vision_event` dicts via `on_event`.

Camera roles:
  A (table, top-down)  -> object detector (stationery)
  B (hand)             -> hand tracker
If only one camera is present it can be shared by both recognisers.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from .base import DetectionResult, HandResult, HandTracker, ObjectDetector
from .hand_control import HandControl

log = logging.getLogger(__name__)


@dataclass
class CameraConfig:
    index: int = 0
    width: int = 640
    height: int = 480
    fps: float = 15.0
    roles: tuple[str, ...] = ("objects",)  # "objects" and/or "hands"
    name: str = "A"
    # the hand joystick: a `hand_control` event per frame from this camera's hands
    control: HandControl | None = None
    # include the 21 landmarks in hand_control (debugging only)
    debug_landmarks: bool = False


@dataclass
class _CameraWorker:
    cfg: CameraConfig
    detector: ObjectDetector | None
    hands: HandTracker | None
    on_event: Callable[[dict], None]
    thread: threading.Thread | None = None
    stop: threading.Event = field(default_factory=threading.Event)
    last_objects: DetectionResult | None = None
    last_hands: HandResult | None = None
    frames: int = 0
    error: str = ""
    # a frame read failing for this long counts as a lost camera (hand control stops)
    lost_after_s: float = 0.3

    def run(self) -> None:
        try:
            import cv2  # type: ignore
        except ImportError:
            self.error = "opencv-python not installed (uv sync --extra vision)"
            log.error(self.error)
            return
        # AVFoundation explicitly on macOS: its indices follow camera_index_by_name()
        cap = cv2.VideoCapture(self.cfg.index, cv2.CAP_AVFOUNDATION) if sys.platform == "darwin" else cv2.VideoCapture(self.cfg.index)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.cfg.width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.cfg.height)
        if not cap.isOpened():
            self.error = f"camera {self.cfg.index} could not be opened"
            log.error(self.error)
            return
        period = 1.0 / max(self.cfg.fps, 1.0)
        prev_gesture = "none"
        prev_labels: set[str] = set()
        failing_since: float | None = None
        lost_sent = False
        while not self.stop.is_set():
            t0 = time.perf_counter()
            ok, frame = cap.read()
            if not ok:
                now = time.monotonic()
                failing_since = failing_since or now
                if self.cfg.control is not None and not lost_sent and now - failing_since >= self.lost_after_s:
                    self.on_event(self.cfg.control.camera_lost(timestamp_ms=int(time.time() * 1000)))
                    lost_sent = True
                time.sleep(0.05)
                continue
            failing_since = None
            lost_sent = False
            self.frames += 1
            if self.detector is not None and "objects" in self.cfg.roles:
                try:
                    res = self.detector.detect(frame)
                    self.last_objects = res
                    labels = {d.label for d in res.detections}
                    self.on_event({"event": "objects", "camera": self.cfg.name, **res.to_dict()})
                    for lbl in labels - prev_labels:
                        self.on_event({"event": "object_appeared", "camera": self.cfg.name, "label": lbl})
                    for lbl in prev_labels - labels:
                        self.on_event({"event": "object_disappeared", "camera": self.cfg.name, "label": lbl})
                    prev_labels = labels
                except NotImplementedError as e:
                    self.error = str(e)
                    self.detector = None
                except Exception as e:  # pragma: no cover
                    self.error = f"detector: {e}"
            if self.hands is not None and "hands" in self.cfg.roles:
                try:
                    hr = self.hands.track(frame)
                    self.last_hands = hr
                    if self.cfg.control is not None:
                        h, w = frame.shape[:2]
                        ev = self.cfg.control.update(hr.landmarks, hr.scores, w, h, time.monotonic() * 1000.0,
                                                     timestamp_ms=int(time.time() * 1000), latency_ms=hr.latency_ms)
                        if self.cfg.debug_landmarks:
                            ev["landmarks"] = [[list(p) for p in hand] for hand in hr.landmarks]
                        self.on_event(ev)
                    if hr.gesture != prev_gesture:
                        self.on_event({"event": "gesture", "camera": self.cfg.name, "gesture": hr.gesture, "detected": hr.detected})
                        prev_gesture = hr.gesture
                    if self.cfg.control is None:  # hand_control already carries what the game needs
                        self.on_event({"event": "hands", "camera": self.cfg.name, **{k: v for k, v in hr.to_dict().items() if k != "landmarks"}})
                except Exception as e:  # pragma: no cover
                    self.error = f"hands: {e}"
            dt = time.perf_counter() - t0
            if dt < period:
                time.sleep(period - dt)
        cap.release()


class VisionService:
    def __init__(self, cameras: list[CameraConfig], detector: ObjectDetector | None = None,
                 hands: HandTracker | None = None, *, loop: asyncio.AbstractEventLoop | None = None) -> None:
        self.cameras = cameras
        self.detector = detector
        self.hands = hands
        self.on_event: Callable[[dict], None] | None = None
        self._loop = loop
        self._workers: list[_CameraWorker] = []

    def _emit(self, event: dict) -> None:
        """Called from worker threads; hop onto the asyncio loop."""
        event.setdefault("timestamp", int(time.time() * 1000))
        cb = self.on_event
        if cb is None:
            return
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(cb, event)
        else:
            cb(event)

    def start(self) -> None:
        self._loop = self._loop or asyncio.get_event_loop()
        for cfg in self.cameras:
            w = _CameraWorker(cfg, self.detector, self.hands, self._emit)
            w.thread = threading.Thread(target=w.run, name=f"camera-{cfg.name}", daemon=True)
            w.thread.start()
            self._workers.append(w)

    def stop(self) -> None:
        for w in self._workers:
            w.stop.set()
        for w in self._workers:
            if w.thread:
                w.thread.join(timeout=2.0)
        self._workers.clear()
        if self.detector:
            self.detector.close()
        if self.hands:
            self.hands.close()

    def status(self) -> list[dict[str, Any]]:
        return [{"camera": w.cfg.name, "index": w.cfg.index, "frames": w.frames, "error": w.error,
                 "objects": w.last_objects.to_dict() if w.last_objects else None,
                 "hands": {k: v for k, v in w.last_hands.to_dict().items() if k != "landmarks"} if w.last_hands else None}
                for w in self._workers]
