"""Pinch "hand joystick" input: turns MediaPipe hand landmarks into a small
`hand_control` event for the game (no landmarks on the wire).

Rules (all thresholds from config `gesture.*`):
  - pinch ratio = |thumb tip (4) - index tip (8)| / hand size, the hand size
    being the larger of the hand width |index MCP (5) - pinky MCP (17)| and
    PALM_TO_WIDTH x the palm length |wrist (0) - middle MCP (9)| (a hand turned
    on its side looks narrow but not short); in pixels so the image aspect does
    not skew it, and independent of how big the hand looks
  - hysteresis: a pinch starts at ratio <= pinch_start and ends at >= pinch_release,
    or already at >= pinch_start when the pinching finger is straight again (an
    open hand: a relaxed open hand stays well under a wide pinch_release)
  - a starting pinch must hold for pinch_confirm_ms before it is reported, and
    an ending one for release_confirm_ms (a fingertip jittering past the release
    threshold for a frame while the hand moves is not a release)
  - MediaPipe drops a moving hand for a frame or two now and then: a loss
    (no hand / ambiguous / two hands) shorter than lost_grace_ms repeats the
    last good frame (marked `held`); a longer one is reported as lost
  - the hand position is the palm centre (wrist + the four MCPs), not the
    fingertips, so opening / closing the fingers does not move the "stick"
  - no control (detected false, pinch false) with two or more hands, a low
    confidence, or the palm outside the operating region (ROI)
  - the thumb may pinch the index, middle or ring finger (`pinch_finger`): the
    one nearest the thumb when the pinch starts, kept until it is released
  - `palm`: which side of the hand faces the camera above the desk, from the
    winding of wrist -> index MCP -> pinky MCP in the image: "up" (the palm),
    "down" (the back of the hand) or "side" (edge on, |sin| < PALM_SIDE_SIN).
    The winding is mirrored for the other hand: a right hand by default,
    `palm_invert` for a left one (the game uses it: palm up = XY, down = Z)
  - `pose`: "fist" (index..pinky folded), "peace" (index + middle out, ring +
    pinky folded), "point" (only the index out), "open", or "other". A finger is
    folded when its tip is nearer the wrist than its PIP joint.
  - `point_dx` / `point_dy`: where the index finger points in the image (unit
    vector from its MCP (5) to its tip (8), in pixels so the aspect does not skew
    it; x right, y down), and `point_len` its length over the hand size (short
    when it points at the camera). Sent for every detected hand; the game uses
    them only for a "point" pose. No pinch starts in a fist or a peace sign (the
    thumb lies near the fingertips there), nor with the pinching finger folded,
    and turning into one ends a running pinch

Pure logic, no MediaPipe import: tests feed landmarks directly.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

Landmark = tuple[float, float, float]

THUMB_TIP, INDEX_TIP, INDEX_MCP, PINKY_MCP = 4, 8, 5, 17
WRIST, MIDDLE_MCP = 0, 9
MIDDLE_TIP = 12
# (tip, pip) of index, middle, ring, pinky
FINGERS = {"index": (8, 6), "middle": (12, 10), "ring": (16, 14), "pinky": (20, 18)}
RING_TIP = 16
PINCH_TIPS = {"index": INDEX_TIP, "middle": MIDDLE_TIP, "ring": RING_TIP}
# below this |sin| between wrist->index MCP and wrist->pinky MCP the hand is edge on
PALM_SIDE_SIN = 0.3
# wrist-to-tip over wrist-to-PIP above which a finger counts as straight
# (stretched out about 1.3; bent round to meet the thumb about 1.0)
STRAIGHT_RATIO = 1.2
# palm length -> width: a flat adult hand is about 1.1-1.3 widths long, so this
# only takes over when the width is foreshortened
PALM_TO_WIDTH = 0.75
PALM_POINTS = (0, 5, 9, 13, 17)


@dataclass
class HandControlConfig:
    pinch_start: float = 0.45
    pinch_release: float = 0.65
    pinch_confirm_ms: float = 80.0
    release_confirm_ms: float = 60.0
    lost_grace_ms: float = 150.0
    # MediaPipe already drops hands below its presence threshold; the per-hand
    # score left is the left/right (handedness) score, which drops for a hand
    # seen from above, so it does not gate control by default
    min_confidence: float = 0.0
    # operating region in normalised image coords (x0, y0, x1, y1); the whole frame by default
    roi: tuple[float, float, float, float] = (0.0, 0.0, 1.0, 1.0)
    roi_enabled: bool = False
    # palm facing for a left hand (or a mirrored camera): swap "up" and "down"
    palm_invert: bool = False

    def update(self, d: dict[str, Any]) -> None:
        """Change thresholds at run time (debug panel); the release stays above the start."""
        for k in ("pinch_start", "pinch_release", "pinch_confirm_ms", "release_confirm_ms", "lost_grace_ms"):
            if k in d:
                setattr(self, k, float(d[k]))
        self.pinch_start = min(max(self.pinch_start, 0.05), 1.5)
        self.pinch_release = min(max(self.pinch_release, self.pinch_start + 0.05), 2.0)
        for k in ("pinch_confirm_ms", "release_confirm_ms", "lost_grace_ms"):
            setattr(self, k, min(max(getattr(self, k), 0.0), 1000.0))
        if "palm_invert" in d:
            self.palm_invert = bool(d["palm_invert"])

    def to_dict(self) -> dict[str, float]:
        return {"pinch_start": self.pinch_start, "pinch_release": self.pinch_release,
                "pinch_confirm_ms": self.pinch_confirm_ms, "release_confirm_ms": self.release_confirm_ms,
                "lost_grace_ms": self.lost_grace_ms, "palm_invert": self.palm_invert}

    @classmethod
    def from_dict(cls, d: dict[str, Any] | None) -> HandControlConfig:
        d = d or {}
        c = cls()
        c.pinch_start = float(d.get("pinch_start", c.pinch_start))
        c.pinch_release = float(d.get("pinch_release", c.pinch_release))
        c.pinch_confirm_ms = float(d.get("pinch_confirm_ms", c.pinch_confirm_ms))
        c.release_confirm_ms = float(d.get("release_confirm_ms", c.release_confirm_ms))
        c.lost_grace_ms = float(d.get("lost_grace_ms", c.lost_grace_ms))
        c.min_confidence = float(d.get("min_confidence", c.min_confidence))
        roi = d.get("roi")
        if isinstance(roi, (list, tuple)) and len(roi) == 4:
            c.roi = tuple(float(v) for v in roi)  # type: ignore[assignment]
        c.roi_enabled = bool(d.get("roi_enabled", c.roi_enabled))
        c.palm_invert = bool(d.get("palm_invert", c.palm_invert))
        return c


def _px(p: Landmark, w: int, h: int) -> tuple[float, float]:
    return (p[0] * w, p[1] * h)


def hand_scale(lm: list[Landmark], w: int, h: int) -> float:
    """The hand size in pixels: the larger of the hand width and PALM_TO_WIDTH x the palm length."""
    ax, ay = _px(lm[INDEX_MCP], w, h)
    bx, by = _px(lm[PINKY_MCP], w, h)
    wx, wy = _px(lm[WRIST], w, h)
    mx, my = _px(lm[MIDDLE_MCP], w, h)
    return max(math.hypot(ax - bx, ay - by), PALM_TO_WIDTH * math.hypot(wx - mx, wy - my))


def pinch_ratio(lm: list[Landmark], w: int, h: int, tip: int = INDEX_TIP) -> float:
    """Thumb-to-`tip` distance over the hand size (see the module doc), in pixels."""
    tx, ty = _px(lm[THUMB_TIP], w, h)
    ix, iy = _px(lm[tip], w, h)
    scale = hand_scale(lm, w, h)
    if scale <= 1e-6:
        return math.inf
    return math.hypot(tx - ix, ty - iy) / scale


def point_direction(lm: list[Landmark], w: int, h: int) -> tuple[float, float, float]:
    """(dx, dy, length): the index finger's MCP -> tip direction in the image as a
    unit vector (x right, y down), and its length over the hand size."""
    ax, ay = _px(lm[INDEX_MCP], w, h)
    tx, ty = _px(lm[INDEX_TIP], w, h)
    dx, dy = tx - ax, ty - ay
    n = math.hypot(dx, dy)
    scale = hand_scale(lm, w, h)
    if n <= 1e-9 or scale <= 1e-6:
        return (0.0, 0.0, 0.0)
    return (dx / n, dy / n, n / scale)


def finger_folded(lm: list[Landmark], finger: str, w: int, h: int) -> bool:
    tip, pip = FINGERS[finger]
    wx, wy = _px(lm[WRIST], w, h)
    t, p = _px(lm[tip], w, h), _px(lm[pip], w, h)
    return math.hypot(t[0] - wx, t[1] - wy) < math.hypot(p[0] - wx, p[1] - wy)


def palm_facing(lm: list[Landmark], w: int, h: int, invert: bool = False) -> tuple[str, float]:
    """("up" / "down" / "side", signed sin) for a right hand seen from above: the
    back of the hand turns wrist -> index MCP -> pinky MCP clockwise on the screen
    (image y down: positive cross product)."""
    wx, wy = _px(lm[WRIST], w, h)
    ax, ay = _px(lm[INDEX_MCP], w, h)
    bx, by = _px(lm[PINKY_MCP], w, h)
    a = (ax - wx, ay - wy)
    b = (bx - wx, by - wy)
    na, nb = math.hypot(*a), math.hypot(*b)
    if na * nb <= 1e-9:
        return "side", 0.0
    sin = (a[0] * b[1] - a[1] * b[0]) / (na * nb)
    if invert:
        sin = -sin
    if abs(sin) < PALM_SIDE_SIN:
        return "side", sin
    return ("down" if sin > 0 else "up"), sin


def finger_straight(lm: list[Landmark], finger: str, w: int, h: int) -> bool:
    """The finger points out: its tip is clearly farther from the wrist than its PIP
    (a pinching finger is bent, its tip about as far as the PIP)."""
    tip, pip = FINGERS[finger]
    wx, wy = _px(lm[WRIST], w, h)
    t, p = _px(lm[tip], w, h), _px(lm[pip], w, h)
    return math.hypot(t[0] - wx, t[1] - wy) > STRAIGHT_RATIO * math.hypot(p[0] - wx, p[1] - wy)


def hand_pose(lm: list[Landmark], w: int, h: int) -> str:
    """"fist" / "peace" / "point" / "open" / "other" from which fingers are folded (thumb ignored)."""
    f = {k: finger_folded(lm, k, w, h) for k in FINGERS}
    if all(f.values()):
        return "fist"
    if not f["index"] and not f["middle"] and f["ring"] and f["pinky"]:
        return "peace"
    if not f["index"] and f["middle"] and f["ring"] and f["pinky"]:
        return "point"
    if not any(f.values()):
        return "open"
    return "other"


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
    _finger: str = ""  # the pinching finger ("index" / "middle" / "ring"), or the one about to be confirmed
    _pinch_since_ms: float | None = None
    _release_since_ms: float | None = None
    _last_good: dict[str, Any] | None = None  # the last frame with exactly one usable hand
    _lost_since_ms: float | None = None

    def reset(self) -> None:
        self._pinched = False
        self._finger = ""
        self._pinch_since_ms = None
        self._release_since_ms = None
        self._last_good = None
        self._lost_since_ms = None

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
            "pinch_finger": "", "pose": "", "palm": "", "palm_sin": 0.0,
            "point_dx": 0.0, "point_dy": 0.0, "point_len": 0.0,
        }
        conf = float(confidences[0]) if len(hands) == 1 and confidences else 0.0
        lost = ""
        if len(hands) != 1:
            lost = "no_hand" if not hands else "multiple_hands"
        elif len(hands[0]) != 21 or conf < self.cfg.min_confidence:
            lost = "ambiguous"
        if lost:
            return self._lost(ev, lost, now_ms)
        self._lost_since_ms = None
        lm = hands[0]
        ev["confidence"] = round(conf, 3)
        cx, cy = palm_center(lm)
        ratios = {k: pinch_ratio(lm, frame_w, frame_h, t) for k, t in PINCH_TIPS.items()}
        pose = hand_pose(lm, frame_w, frame_h)
        palm, palm_sin = palm_facing(lm, frame_w, frame_h, self.cfg.palm_invert)
        pdx, pdy, plen = point_direction(lm, frame_w, frame_h)
        # the finger that counts: the held one, else the closer of the two
        finger = self._finger or min(ratios, key=lambda k: ratios[k])
        ratio = ratios[finger]
        ev.update(hand_x=round(cx, 4), hand_y=round(cy, 4), pinch_ratio=round(min(ratio, 99.0), 3),
                  pose=pose, palm=palm, palm_sin=round(palm_sin, 3),
                  point_dx=round(pdx, 4), point_dy=round(pdy, 4), point_len=round(min(plen, 99.0), 3))
        if not self._in_roi(cx, cy):
            self.reset()
            ev["reason"] = "outside_roi"
            return ev
        ev["detected"] = True
        ev["in_roi"] = True
        if self._pinched and pose in ("fist", "peace"):
            # closing into a fist can pass through a pinch-like frame; a fist keeps the
            # ratio small and would never release: a claw pose always ends the pinch
            self._pinched = False
            self._finger = ""
            self._pinch_since_ms = None
            self._release_since_ms = None
        elif self._pinched:
            # released: opened past pinch_release, or the pinching finger is straight
            # again while the gap is past pinch_start (an open hand; a wide release
            # threshold alone is only reached by spreading the thumb wide)
            opened = ratio >= self.cfg.pinch_release or (
                ratio >= self.cfg.pinch_start and finger_straight(lm, self._finger or finger, frame_w, frame_h))
            if opened:
                if self._release_since_ms is None:
                    self._release_since_ms = now_ms
                if now_ms - self._release_since_ms >= self.cfg.release_confirm_ms:
                    self._pinched = False
                    self._finger = ""
                    self._pinch_since_ms = None
                    self._release_since_ms = None
            else:
                self._release_since_ms = None
        elif (ratio <= self.cfg.pinch_start and pose not in ("fist", "peace")
              and not finger_folded(lm, finger, frame_w, frame_h)):
            if self._pinch_since_ms is None or finger != self._finger:
                self._pinch_since_ms = now_ms  # (re)start the confirmation for this finger
            self._finger = finger
            if now_ms - self._pinch_since_ms >= self.cfg.pinch_confirm_ms:
                self._pinched = True
        else:
            self._pinch_since_ms = None  # the closing pinch opened again before it was confirmed
            self._finger = ""
        ev["pinch"] = self._pinched
        ev["pinch_finger"] = self._finger if self._pinched else ""
        self._last_good = {k: ev[k] for k in ("detected", "pinch", "hand_x", "hand_y", "pinch_ratio", "confidence", "in_roi",
                                              "pinch_finger", "pose", "palm", "palm_sin",
                                              "point_dx", "point_dy", "point_len")}
        return ev

    def _lost(self, ev: dict[str, Any], reason: str, now_ms: float) -> dict[str, Any]:
        """No usable hand this frame: hold the last good frame for a moment, then report it."""
        if self._last_good is not None:
            if self._lost_since_ms is None:
                self._lost_since_ms = now_ms
            if now_ms - self._lost_since_ms < self.cfg.lost_grace_ms:
                ev.update(self._last_good)
                ev["held"] = True
                ev["reason"] = "held_" + reason
                return ev
        self.reset()
        ev["reason"] = reason
        return ev

    def camera_lost(self, frame_w: int = 0, frame_h: int = 0, *, timestamp_ms: int = 0) -> dict[str, Any]:
        """The camera stopped delivering frames: an event that stops any control."""
        self.reset()
        self.sequence += 1
        return {"event": "hand_control", "camera_ok": False, "detected": False, "hand_count": 0, "pinch": False,
                "hand_x": 0.0, "hand_y": 0.0, "pinch_ratio": 0.0, "confidence": 0.0, "in_roi": False,
                "reason": "camera_lost", "frame_w": frame_w, "frame_h": frame_h,
                "timestamp": int(timestamp_ms), "sequence": self.sequence, "latency_ms": 0.0,
                "point_dx": 0.0, "point_dy": 0.0, "point_len": 0.0}
