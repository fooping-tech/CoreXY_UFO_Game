"""Abstract vision interfaces. Concrete detectors are optional extras so the
backend runs without OpenCV / MediaPipe / ultralytics installed."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Detection:
    label: str
    confidence: float
    bbox: tuple[float, float, float, float]  # x, y, w, h normalised 0..1

    @property
    def center(self) -> tuple[float, float]:
        x, y, w, h = self.bbox
        return (x + w / 2, y + h / 2)


@dataclass
class DetectionResult:
    detections: list[Detection] = field(default_factory=list)
    frame_size: tuple[int, int] = (0, 0)
    backend: str = "none"
    latency_ms: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "backend": self.backend,
            "latency_ms": round(self.latency_ms, 1),
            "objects": [{"label": d.label, "confidence": round(d.confidence, 3), "bbox": list(d.bbox), "center": list(d.center)} for d in self.detections],
        }


@dataclass
class HandResult:
    detected: bool = False
    landmarks: list[list[tuple[float, float, float]]] = field(default_factory=list)  # per hand, 21 x (x,y,z)
    handedness: list[str] = field(default_factory=list)
    gesture: str = "none"  # open / fist / point / none
    latency_ms: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "detected": self.detected,
            "hands": len(self.landmarks),
            "handedness": self.handedness,
            "gesture": self.gesture,
            "latency_ms": round(self.latency_ms, 1),
            "landmarks": [[list(p) for p in hand] for hand in self.landmarks],
        }


class ObjectDetector(ABC):
    name = "detector"

    @abstractmethod
    def detect(self, frame_bgr: Any) -> DetectionResult:
        """Synchronous; called from a worker thread."""

    def close(self) -> None:
        return None


class HandTracker(ABC):
    name = "hands"

    @abstractmethod
    def track(self, frame_bgr: Any) -> HandResult: ...

    def close(self) -> None:
        return None


class NullDetector(ObjectDetector):
    name = "null"

    def detect(self, frame_bgr: Any) -> DetectionResult:
        return DetectionResult(backend=self.name)


class NullHandTracker(HandTracker):
    name = "null"

    def track(self, frame_bgr: Any) -> HandResult:
        return HandResult()


def classify_gesture(landmarks: list[tuple[float, float, float]]) -> str:
    """Very small rule-based gesture classifier on 21 MediaPipe landmarks."""
    if len(landmarks) != 21:
        return "none"
    wrist = landmarks[0]
    tips = [8, 12, 16, 20]
    pips = [6, 10, 14, 18]

    def dist(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
        return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5

    extended = [dist(landmarks[t], wrist) > dist(landmarks[p], wrist) * 1.15 for t, p in zip(tips, pips)]
    n = sum(extended)
    if n >= 4:
        return "open"
    if n == 0:
        return "fist"
    if extended[0] and n == 1:
        return "point"
    return "other"
