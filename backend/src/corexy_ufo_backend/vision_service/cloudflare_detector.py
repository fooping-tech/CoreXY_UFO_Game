"""Cloudflare-hosted object detection: INTERFACE ONLY.

The existing Cloudflare API used by the project could not be found in the
CoreXY_UFO repository (no endpoint, auth or payload spec is documented there),
so this class deliberately does not invent an endpoint. Provide the real
request/response mapping by subclassing and implementing `_call_api`, or set
`endpoint` + `_call_api` once the spec is known.
"""

from __future__ import annotations

import time
from typing import Any

from .base import Detection, DetectionResult, ObjectDetector


class CloudflareDetector(ObjectDetector):
    name = "cloudflare"

    def __init__(self, endpoint: str | None = None, api_token: str | None = None, timeout_s: float = 3.0) -> None:
        self.endpoint = endpoint
        self.api_token = api_token
        self.timeout_s = timeout_s

    def _call_api(self, jpeg_bytes: bytes) -> list[dict[str, Any]]:
        """Return a list of {label, confidence, bbox:[x,y,w,h] normalised}."""
        raise NotImplementedError(
            "CloudflareDetector: API spec unknown. Implement _call_api() with the real endpoint "
            "(no placeholder endpoint is shipped on purpose)."
        )

    def detect(self, frame_bgr: Any) -> DetectionResult:
        if not self.endpoint:
            raise NotImplementedError("CloudflareDetector has no endpoint configured")
        try:
            import cv2  # type: ignore
        except ImportError as e:  # pragma: no cover
            raise RuntimeError("opencv-python not installed: uv sync --extra vision") from e
        t0 = time.perf_counter()
        h, w = frame_bgr.shape[:2]
        ok, buf = cv2.imencode(".jpg", frame_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        if not ok:
            return DetectionResult(backend=self.name)
        raw = self._call_api(buf.tobytes())
        dets = [Detection(str(d["label"]), float(d.get("confidence", 0.0)), tuple(d["bbox"])) for d in raw]
        return DetectionResult(dets, (w, h), self.name, (time.perf_counter() - t0) * 1000)
