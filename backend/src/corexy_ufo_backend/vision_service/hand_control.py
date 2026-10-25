"""Pinch "hand joystick" input: turns MediaPipe hand landmarks into a small
`hand_control` event for the game (no landmarks on the wire).

Rules (all thresholds from config `gesture.*`):
  - pinch ratio = |thumb tip (4) - index tip (8)| / |index MCP (5) - pinky MCP (17)|,
    measured in pixels so the image aspect does not skew it, and independent of
    how big the hand looks
  - hysteresis: a pinch starts at ratio <= pinch_start and ends at >= pinch_release
  - a starting pinch must hold for pinch_confirm_ms before it is reported
  - the hand position is the palm centre (wrist + the four MCPs), not the
    fingertips, so opening / closing the fingers does not move the "stick"
  - no control (detected false, pinch false) with two or more hands, a low
    confidence, or the palm outside the operating region (ROI)

Pure logic, no MediaPipe import: tests feed landmarks directly.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

Landmark = tuple[float, float, float]

THUMB_TIP, INDEX_TIP, INDEX_MCP, PINKY_MCP = 4, 8, 5, 17
PALM_POINTS = (0, 5, 9, 13, 17)


@dataclass
class HandControlConfig:
    pinch_start: float = 0.35
    pinch_release: float = 0.55
    pinch_confirm_ms: float = 100.0
    min_confidence: float = 0.6
    # operating region in normalised image coords (x0, y0, x1, y1); the whole frame by default
    roi: tuple[float, float, float, float] = (0.0, 0.0, 1.0, 1.0)
    roi_enabled: bool = False

    @classmethod
    def from_dict(cls, d: dict[str, Any] | None) -> HandControlConfig:
        d = d or {}
        c = cls()
        c.pinch_start = float(d.get("pinch_start", c.pinch_start))
        c.pinch_release = float(d.get("pinch_release", c.pinch_release))
        c.pinch_confirm_ms = float(d.get("pinch_confirm_ms", c.pinch_confirm_ms))
        c.min_confidence = float(d.get("min_confidence", c.min_confidence))
        roi = d.get("roi")
        if isinstance(roi, (list, tuple)) and len(roi) == 4:
            c.roi = tuple(float(v) for v in roi)  # type: ignore[assignment]
        c.roi_enabled = bool(d.get("roi_enabled", c.roi_enabled))
        return c


def _px(p: Landmark, w: int, h: int) -> tuple[float, float]:
    return (p[0] * w, p[1] * h)


def pinch_ratio(lm: list[Landmark], w: int, h: int) -> float:
    """Fingertip distance over the hand width (index MCP - pinky MCP), in pixels."""
    tx, ty = _px(lm[THUMB_TIP], w, h)
    ix, iy = _px(lm[INDEX_TIP], w, h)
    ax, ay = _px(lm[INDEX_MCP], w, h)
    bx, by = _px(lm[PINKY_MCP], w, h)
    scale = math.hypot(ax - bx, ay - by)
    if scale <= 1e-6:
        return math.inf
    return math.hypot(tx - ix, ty - iy) / scale


def palm_center(lm: list[Landmark]) -> tuple[float, float]:
    """Mean of the wrist and the four MCP joints, normalised image coords."""
    xs = [lm[i][0] for i in PALM_POINTS]
    ys = [lm[i][1] for i in PALM_POINTS]
    return (sum(xs) / len(xs), sum(ys) / len(ys))


@dataclass
class HandControl:
    """Stateful per camera: hysteresis and the confirmation timer."""

    cfg: HandControlConfig = field(default_factory=HandControlConfig)
    sequence: int = 0
    _pinched: bool = False
    _pinch_since_ms: float | None = None

    def reset(self) -> None:
        self._pinched = False
        self._pinch_since_ms = None

    def _in_roi(self, x: float, y: float) -> bool:
        if not self.cfg.roi_enabled:
            return True
        x0, y0, x1, y1 = self.cfg.roi
        return x0 <= x <= x1 and y0 <= y <= y1

    def update(self, hands: list[list[Landmark]], confidences: list[float], frame_w: int, frame_h: int,
               now_ms: float, *, timestamp_ms: int = 0, latency_ms: float = 0.0) -> dict[str, Any]:
        """One frame -> one `hand_control` event. `now_ms` is a monotonic clock."""
        self.sequence += 1
        ev: dict[str, Any] = {
            "event": "hand_control", "camera_ok": True, "detected": False, "hand_count": len(hands),
            "pinch": False, "hand_x": 0.0, "hand_y": 0.0, "pinch_ratio": 0.0, "confidence": 0.0,
            "in_roi": False, "reason": "", "frame_w": frame_w, "frame_h": frame_h,
            "timestamp": int(timestamp_ms), "sequence": self.sequence, "latency_ms": round(latency_ms, 1),
        }
        if len(hands) != 1:
            self.reset()
            ev["reason"] = "no_hand" if not hands else "multiple_hands"
            return ev
        lm = hands[0]
        conf = float(confidences[0]) if confidences else 0.0
        ev["confidence"] = round(conf, 3)
        if len(lm) != 21 or conf < self.cfg.min_confidence:
            self.reset()
            ev["reason"] = "ambiguous"
            return ev
        cx, cy = palm_center(lm)
        ratio = pinch_ratio(lm, frame_w, frame_h)
        ev.update(hand_x=round(cx, 4), hand_y=round(cy, 4), pinch_ratio=round(min(ratio, 99.0), 3))
        if not self._in_roi(cx, cy):
            self.reset()
            ev["reason"] = "outside_roi"
            return ev
        ev["detected"] = True
        ev["in_roi"] = True
        if self._pinched:
            if ratio >= self.cfg.pinch_release:
                self.reset()
        elif ratio <= self.cfg.pinch_start:
            if self._pinch_since_ms is None:
                self._pinch_since_ms = now_ms
            if now_ms - self._pinch_since_ms >= self.cfg.pinch_confirm_ms:
                self._pinched = True
        else:
            self._pinch_since_ms = None  # the closing pinch opened again before it was confirmed
        ev["pinch"] = self._pinched
        return ev

    def camera_lost(self, frame_w: int = 0, frame_h: int = 0, *, timestamp_ms: int = 0) -> dict[str, Any]:
        """The camera stopped delivering frames: an event that stops any control."""
        self.reset()
        self.sequence += 1
        return {"event": "hand_control", "camera_ok": False, "detected": False, "hand_count": 0, "pinch": False,
                "hand_x": 0.0, "hand_y": 0.0, "pinch_ratio": 0.0, "confidence": 0.0, "in_roi": False,
                "reason": "camera_lost", "frame_w": frame_w, "frame_h": frame_h,
                "timestamp": int(timestamp_ms), "sequence": self.sequence, "latency_ms": 0.0}
