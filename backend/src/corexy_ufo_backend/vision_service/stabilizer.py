"""#118: optical-flow stabilization of the arm-tip camera.

The arm hangs on ball chains and swings, and the camera on its tip swings with it. Each
frame's motion (translation and rotation about the frame centre) is measured from tracked
corners (Lucas-Kanade on a small grey copy, a RANSAC partial affine fit); the motions add up
to a trajectory, a low-pass copy of it (two one-pole stages, ``cutoff_hz``) is the steady
path, and each frame is moved by (steady - trajectory): the swing (fast) is cancelled, a
deliberate XY move (slow) is followed with a short lag. The correction is clamped, and the
frame is zoomed a little so the moved edges stay out of view.

Display only: nothing here reaches the robot.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, fields
from typing import Any

import cv2
import numpy as np


@dataclass
class StabilizerParams:
    track_width: int = 320      # the grey copy the corners are tracked on (px wide)
    cutoff_hz: float = 0.4      # slower than this is followed, faster is cancelled
    max_shift: float = 0.12     # the largest correction, a fraction of the frame width
    max_rot_deg: float = 6.0    # the largest rotation correction
    zoom: float = 1.08          # hides the edges moved into view
    max_corners: int = 200
    min_points: int = 20        # fewer tracked corners than this: no motion measured

    @classmethod
    def from_raw(cls, raw: dict[str, Any] | None) -> StabilizerParams:
        raw = raw or {}
        out = cls()
        for f in fields(cls):
            if f.name in raw and isinstance(raw[f.name], (int, float)) and not isinstance(raw[f.name], bool):
                setattr(out, f.name, type(getattr(out, f.name))(raw[f.name]))
        out.track_width = max(80, min(out.track_width, 1280))
        out.cutoff_hz = max(0.02, min(out.cutoff_hz, 5.0))
        out.max_shift = max(0.0, min(out.max_shift, 0.3))
        out.max_rot_deg = max(0.0, min(out.max_rot_deg, 20.0))
        out.zoom = max(1.0, min(out.zoom, 1.5))
        out.min_points = max(6, out.min_points)
        return out


def _mat3(m2x3: np.ndarray) -> np.ndarray:
    return np.vstack([m2x3, [0.0, 0.0, 1.0]])


def about(center: tuple[float, float], m: np.ndarray) -> np.ndarray:
    """3x3 `m` applied about `center` instead of the origin."""
    cx, cy = center
    t = np.array([[1.0, 0.0, cx], [0.0, 1.0, cy], [0.0, 0.0, 1.0]])
    ti = np.array([[1.0, 0.0, -cx], [0.0, 1.0, -cy], [0.0, 0.0, 1.0]])
    return t @ m @ ti


def rotation(a: float) -> np.ndarray:
    """Rotation by `a` radians in image coordinates (y down: positive turns clockwise on screen)."""
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def correction_matrix(size: tuple[int, int], dx: float, dy: float, da: float, zoom: float) -> np.ndarray:
    """2x3 warp: move the content by (dx, dy), turn it by `da` about the centre, then zoom."""
    w, h = size
    c = (w / 2.0, h / 2.0)
    m = about(c, np.diag([zoom, zoom, 1.0])) @ about(c, rotation(da)) @ np.array(
        [[1.0, 0.0, dx], [0.0, 1.0, dy], [0.0, 0.0, 1.0]])
    return m[:2]


class Stabilizer:
    def __init__(self, params: StabilizerParams | None = None) -> None:
        self.p = params or StabilizerParams()
        self.reset()

    def reset(self) -> None:
        self._prev: np.ndarray | None = None
        self._pts: np.ndarray | None = None
        self._t: float | None = None
        self.traj = np.zeros(3)     # x, y (full-res px), angle (rad): the content's motion so far
        self._s1 = np.zeros(3)
        self._s2 = np.zeros(3)      # the steady path
        self.correction = np.zeros(3)
        self.points = 0
        self.tracking = False

    def measure(self, prev: np.ndarray, cur: np.ndarray, scale: float) -> tuple[np.ndarray | None, int]:
        """The content's motion prev -> cur about the frame centre: (dx, dy in full-res px, angle)."""
        if self._pts is None or len(self._pts) < self.p.min_points * 2:
            self._pts = cv2.goodFeaturesToTrack(prev, maxCorners=self.p.max_corners, qualityLevel=0.01,
                                                minDistance=max(4, prev.shape[1] // 40), blockSize=7)
        if self._pts is None or len(self._pts) < self.p.min_points:
            self._pts = None
            return None, 0
        nxt, st, _err = cv2.calcOpticalFlowPyrLK(prev, cur, self._pts, None, winSize=(21, 21), maxLevel=3)
        ok = st.reshape(-1) == 1
        a, b = self._pts[ok], nxt[ok]
        self._pts = b.reshape(-1, 1, 2) if len(b) else None
        if len(a) < self.p.min_points:
            return None, int(len(a))
        m, inl = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC, ransacReprojThreshold=2.0)
        n = int(inl.sum()) if inl is not None else 0
        if m is None or n < self.p.min_points:
            return None, n
        if inl is not None:  # keep only the corners that moved with the frame
            self._pts = b[inl.reshape(-1) == 1].reshape(-1, 1, 2)
        h, w = prev.shape[:2]
        c = np.array([w / 2.0, h / 2.0, 1.0])
        moved = _mat3(m) @ c
        ang = math.atan2(m[1, 0], m[0, 0])
        return np.array([(moved[0] - c[0]) / scale, (moved[1] - c[1]) / scale, ang]), n

    def update(self, frame: np.ndarray, t: float) -> tuple[np.ndarray, dict[str, Any]]:
        """The stabilized frame (same size) and what was done."""
        h, w = frame.shape[:2]
        scale = min(1.0, self.p.track_width / float(w))
        grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
        small = cv2.resize(grey, (max(1, int(w * scale)), max(1, int(h * scale))), interpolation=cv2.INTER_AREA)
        dt = 1.0 / 30.0 if self._t is None else min(max(t - self._t, 1.0 / 240.0), 0.25)
        self._t = t
        motion = None
        if self._prev is not None:
            motion, self.points = self.measure(self._prev, small, scale)
        self._prev = small
        self.tracking = motion is not None
        if motion is not None:
            self.traj = self.traj + motion
        # no motion measured: the trajectory holds, the steady path catches up, the correction fades
        alpha = 1.0 - math.exp(-2.0 * math.pi * self.p.cutoff_hz * dt)
        self._s1 = self._s1 + alpha * (self.traj - self._s1)
        self._s2 = self._s2 + alpha * (self._s1 - self._s2)
        corr = self._s2 - self.traj
        lim = self.p.max_shift * w
        corr[0] = max(-lim, min(corr[0], lim))
        corr[1] = max(-lim, min(corr[1], lim))
        rl = math.radians(self.p.max_rot_deg)
        corr[2] = max(-rl, min(corr[2], rl))
        self.correction = corr
        m = correction_matrix((w, h), corr[0], corr[1], corr[2], self.p.zoom)
        out = cv2.warpAffine(frame, m, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        return out, {"dx": round(float(corr[0]), 1), "dy": round(float(corr[1]), 1),
                     "rot_deg": round(math.degrees(corr[2]), 2), "points": self.points, "tracking": self.tracking}
