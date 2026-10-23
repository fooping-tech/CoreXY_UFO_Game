"""MediaPipe hand tracker (optional extra `hands`)."""

from __future__ import annotations

import time
from typing import Any

from .base import HandResult, HandTracker, classify_gesture


class MediaPipeHandTracker(HandTracker):
    name = "mediapipe"

    def __init__(self, max_hands: int = 2, min_confidence: float = 0.5) -> None:
        try:
            import mediapipe as mp  # type: ignore
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("mediapipe not installed: uv sync --extra hands") from e
        self._mp = mp
        self._hands = mp.solutions.hands.Hands(max_num_hands=max_hands, min_detection_confidence=min_confidence,
                                               min_tracking_confidence=min_confidence)

    def track(self, frame_bgr: Any) -> HandResult:
        import cv2  # type: ignore

        t0 = time.perf_counter()
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        res = self._hands.process(rgb)
        out = HandResult()
        if res.multi_hand_landmarks:
            out.detected = True
            for hand, handed in zip(res.multi_hand_landmarks, res.multi_handedness or []):
                pts = [(lm.x, lm.y, lm.z) for lm in hand.landmark]
                out.landmarks.append(pts)
                out.handedness.append(handed.classification[0].label if handed.classification else "?")
            out.gesture = classify_gesture(out.landmarks[0])
        out.latency_ms = (time.perf_counter() - t0) * 1000
        return out

    def close(self) -> None:
        self._hands.close()
