"""YOLO object detector via `ultralytics` (optional extra `yolo`)."""

from __future__ import annotations

import time
from typing import Any

from .base import Detection, DetectionResult, ObjectDetector


class YoloDetector(ObjectDetector):
    name = "yolo"

    def __init__(self, model: str = "yolov8n.pt", conf: float = 0.35, classes: list[str] | None = None) -> None:
        try:
            from ultralytics import YOLO  # type: ignore
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("ultralytics not installed: uv sync --extra yolo") from e
        self.model = YOLO(model)
        self.conf = conf
        self.classes = set(classes) if classes else None

    def detect(self, frame_bgr: Any) -> DetectionResult:
        t0 = time.perf_counter()
        h, w = frame_bgr.shape[:2]
        res = self.model.predict(frame_bgr, conf=self.conf, verbose=False)[0]
        out: list[Detection] = []
        names = res.names
        for box in res.boxes:
            label = names[int(box.cls[0])]
            if self.classes and label not in self.classes:
                continue
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            out.append(Detection(label, float(box.conf[0]), (x1 / w, y1 / h, (x2 - x1) / w, (y2 - y1) / h)))
        return DetectionResult(out, (w, h), self.name, (time.perf_counter() - t0) * 1000)
