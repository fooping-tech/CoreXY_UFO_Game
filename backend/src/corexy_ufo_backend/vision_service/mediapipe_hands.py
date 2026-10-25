"""MediaPipe hand tracker (optional extra `hands`).

Uses the Hand Landmarker of the MediaPipe Tasks API: the legacy
`mp.solutions.hands` is gone from current MediaPipe (1.x). It needs the model
file `hand_landmarker.task` (Apache-2.0, from Google): by default
backend/models/hand_landmarker.task, downloaded on first use if missing.
"""

from __future__ import annotations

import logging
import time
import urllib.request
from pathlib import Path
from typing import Any

from .base import HandResult, HandTracker, classify_gesture

log = logging.getLogger(__name__)

MODEL_URL = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"
DEFAULT_MODEL = Path(__file__).resolve().parents[3] / "models" / "hand_landmarker.task"


def ensure_model(path: Path = DEFAULT_MODEL) -> Path:
    if path.exists() and path.stat().st_size > 0:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    log.info("downloading the hand landmarker model to %s", path)
    tmp = path.with_suffix(".part")
    urllib.request.urlretrieve(MODEL_URL, tmp)  # noqa: S310 - fixed https URL
    tmp.rename(path)
    return path


class MediaPipeHandTracker(HandTracker):
    name = "mediapipe"

    def __init__(self, max_hands: int = 2, min_confidence: float = 0.5, model_path: Path | None = None,
                 delegate: str = "cpu", tracking_confidence: float = 0.3) -> None:
        try:
            import mediapipe as mp  # type: ignore
            from mediapipe.tasks.python import vision  # type: ignore
            from mediapipe.tasks.python.core.base_options import BaseOptions  # type: ignore
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("mediapipe not installed: uv sync --extra vision --extra hands") from e
        self._mp = mp
        model = str(ensure_model(model_path or DEFAULT_MODEL))

        def create(dele: str) -> Any:
            # Two hands are tracked on purpose: with a second hand in view nobody gets control.
            opts = vision.HandLandmarkerOptions(
                base_options=BaseOptions(model_asset_path=model, delegate=getattr(BaseOptions.Delegate, dele.upper())),
                running_mode=vision.RunningMode.VIDEO,
                num_hands=max_hands,
                min_hand_detection_confidence=min_confidence,
                # a fast-moving (blurred) hand scores low: keep tracking it rather than
                # dropping it and searching the whole frame again
                min_hand_presence_confidence=tracking_confidence,
                min_tracking_confidence=tracking_confidence,
            )
            return vision.HandLandmarker.create_from_options(opts)

        # CPU by default. GPU (Metal) roughly halves the time per frame on an
        # M-series Mac, but MediaPipe 1.1.1 aborted the whole process after ~8 min
        # ("Error creating pixel buffer: -6662", a CVPixelBuffer allocation
        # failure in ImageToTensorMetalConverter). GPU needs RGBA input; it falls
        # back to the CPU if it cannot start.
        self.delegate = delegate.lower()
        try:
            self._landmarker = create(self.delegate)
        except Exception as e:  # pragma: no cover - depends on the machine
            if self.delegate == "cpu":
                raise
            log.warning("hand landmarker on %s failed (%s): using the CPU", self.delegate, e)
            self.delegate = "cpu"
            self._landmarker = create("cpu")
        log.info("hand landmarker: %s delegate", self.delegate)
        self._t0 = time.monotonic()
        self._last_ts = -1

    def track(self, frame_bgr: Any) -> HandResult:
        import cv2  # type: ignore

        t0 = time.perf_counter()
        if self.delegate == "gpu":
            image = self._mp.Image(image_format=self._mp.ImageFormat.SRGBA, data=cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGBA))
        else:
            image = self._mp.Image(image_format=self._mp.ImageFormat.SRGB, data=cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB))
        # VIDEO mode needs strictly increasing timestamps
        ts = max(int((time.monotonic() - self._t0) * 1000), self._last_ts + 1)
        self._last_ts = ts
        res = self._landmarker.detect_for_video(image, ts)
        out = HandResult()
        for hand, handed in zip(res.hand_landmarks or [], res.handedness or []):
            out.landmarks.append([(lm.x, lm.y, lm.z) for lm in hand])
            top = handed[0] if handed else None
            out.handedness.append(top.category_name if top else "?")
            out.scores.append(float(top.score) if top else 0.0)
        out.detected = bool(out.landmarks)
        if out.landmarks:
            out.gesture = classify_gesture(out.landmarks[0])
        out.latency_ms = (time.perf_counter() - t0) * 1000
        return out

    def close(self) -> None:
        self._landmarker.close()
