"""Overview camera image <-> CoreXY XY (mm): a homography fitted to recorded point pairs.

Calibration (#78): jog the arm until the centre of its own (focus) camera is over a mark
on the worksheet, then click that mark in the overview image. The backend pairs the
click (u, v: 0..1 of the overview image as the game shows it, flips applied) with the
robot's XY at that moment. XY is where the arm's camera looks straight down, not where
the arm appears in the overview image (that would be off by the parallax of its height).

With 4+ pairs (spread out, not on one line) a homography maps image -> XY. The desk is
a plane, so one homography is exact up to lens distortion and click error; the fit
reports the error in mm. A target is only accepted inside the calibrated area (plus a
margin): extrapolating far outside the points is not trusted.

Pure computation and a JSON file: this module never moves the robot. The approach
sequencer (approach.py) moves, inside its own safety frame, to targets mapped here.
"""

from __future__ import annotations

import json
import logging
import math
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

log = logging.getLogger(__name__)

MAX_POINTS = 16
MIN_SPACING_MM = 5.0  # two pairs this close in XY add nothing (and an error if clicked apart)
MIN_SPREAD = 0.12  # smallest / largest spread of the points (0 = on one line)
# 8th / 1st singular value of the normalised DLT system. Below it the points do not fix one
# homography (e.g. 3 of 4 points on a line: rank 7, many maps fit exactly and disagree by
# centimetres). Well spread sets measure about 0.2..0.3; 3 of 4 points 1 % off a line, 0.008.
MIN_DLT_CONDITION = 0.03


class CameraMapError(ValueError):
    """A request the calibration cannot serve (the message says why, for the panel)."""


@dataclass(frozen=True)
class CameraMapParams:
    min_points: int = 4
    max_error_mm: float = 5.0  # a fit worse than this is shown but not used to move
    margin_mm: float = 20.0  # how far outside the calibrated points a target may be

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "CameraMapParams":
        hw = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        d = hw.get("camera_map") if isinstance(hw.get("camera_map"), dict) else {}
        return cls(min_points=max(4, int(d.get("min_points", 4))),
                   max_error_mm=float(d.get("max_error_mm", 5.0)),
                   margin_mm=float(d.get("margin_mm", 20.0)))


def camera_signature(raw: Any) -> dict:
    """{width, height, flip_h, flip_v} of the overview image the clicks refer to."""
    if not isinstance(raw, dict):
        raise CameraMapError("camera: the overview image's size and flips are missing")
    try:
        sig = {"width": int(raw["width"]), "height": int(raw["height"]),
               "flip_h": bool(raw.get("flip_h", False)), "flip_v": bool(raw.get("flip_v", False))}
    except (KeyError, TypeError, ValueError) as e:
        raise CameraMapError(f"camera: bad size ({e})") from e
    if sig["width"] <= 0 or sig["height"] <= 0:
        raise CameraMapError("camera: no image yet (size 0)")
    return sig


def image_point(u: Any, v: Any) -> tuple[float, float]:
    u, v = float(u), float(v)
    if not (math.isfinite(u) and math.isfinite(v) and 0.0 <= u <= 1.0 and 0.0 <= v <= 1.0):
        raise CameraMapError(f"the point ({u}, {v}) is not inside the image (0..1)")
    return u, v


# ---------------------------------------------------------------- geometry
def _normalizer(pts: np.ndarray) -> np.ndarray:
    """Hartley normalisation: centroid to 0, mean distance sqrt(2)."""
    c = pts.mean(axis=0)
    d = np.sqrt(((pts - c) ** 2).sum(axis=1)).mean()
    s = math.sqrt(2) / d if d > 0 else 1.0
    return np.array([[s, 0, -s * c[0]], [0, s, -s * c[1]], [0, 0, 1]])


def fit_homography(src: np.ndarray, dst: np.ndarray) -> tuple[np.ndarray, float]:
    """3x3 H with dst ~ H @ [src, 1] (normalised DLT, least squares for > 4 points), and the
    system's condition (8th / 1st singular value: ~0 when the points do not fix one H)."""
    ts, td = _normalizer(src), _normalizer(dst)
    s = (ts @ np.c_[src, np.ones(len(src))].T).T
    d = (td @ np.c_[dst, np.ones(len(dst))].T).T
    rows = []
    for (x, y, _), (X, Y, _) in zip(s, d):
        rows.append([-x, -y, -1, 0, 0, 0, X * x, X * y, X])
        rows.append([0, 0, 0, -x, -y, -1, Y * x, Y * y, Y])
    _, sv, vt = np.linalg.svd(np.asarray(rows))
    condition = float(sv[7] / sv[0]) if len(sv) >= 8 and sv[0] > 0 else 0.0
    hn = vt[-1].reshape(3, 3)
    h = np.linalg.inv(td) @ hn @ ts
    return h / h[2, 2], condition


def apply(h: np.ndarray, x: float, y: float) -> tuple[float, float]:
    p = h @ np.array([x, y, 1.0])
    if abs(p[2]) < 1e-12:
        raise CameraMapError("the point maps to infinity (calibration unusable there)")
    return float(p[0] / p[2]), float(p[1] / p[2])


def spread(pts: np.ndarray) -> float:
    """Smallest / largest singular value of the centred points: 0 on a line, 1 for a round cloud."""
    sv = np.linalg.svd(pts - pts.mean(axis=0), compute_uv=False)
    return float(sv[-1] / sv[0]) if sv[0] > 0 else 0.0


def convex_hull(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
    p = sorted(set(pts))
    if len(p) <= 2:
        return p

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower: list = []
    for q in p:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], q) <= 0:
            lower.pop()
        lower.append(q)
    upper: list = []
    for q in reversed(p):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], q) <= 0:
            upper.pop()
        upper.append(q)
    return lower[:-1] + upper[:-1]


def distance_outside(hull: list[tuple[float, float]], x: float, y: float) -> float:
    """0 inside the (counter-clockwise) hull, else the distance to its edge."""
    n = len(hull)
    if n < 3:
        return math.inf
    inside = all((hull[(i + 1) % n][0] - hull[i][0]) * (y - hull[i][1])
                 - (hull[(i + 1) % n][1] - hull[i][1]) * (x - hull[i][0]) >= 0 for i in range(n))
    if inside:
        return 0.0
    best = math.inf
    for i in range(n):
        (ax, ay), (bx, by) = hull[i], hull[(i + 1) % n]
        dx, dy = bx - ax, by - ay
        t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy or 1.0)))
        best = min(best, math.hypot(x - ax - t * dx, y - ay - t * dy))
    return best


# ---------------------------------------------------------------- the calibration
@dataclass
class CameraXYMap:
    params: CameraMapParams = field(default_factory=CameraMapParams)
    path: Path | None = None
    points: list[dict] = field(default_factory=list)  # {u, v, x, y}
    camera: dict | None = None
    h: np.ndarray | None = None  # image (u, v) -> XY mm
    h_inv: np.ndarray | None = None  # XY mm -> image
    errors_mm: list[float] = field(default_factory=list)
    problem: str = ""  # why there is no usable fit ("" when there is one)
    saved_at: str = ""

    # ---- persistence
    @classmethod
    def load(cls, path: Path | None, params: CameraMapParams | None = None) -> "CameraXYMap":
        m = cls(params=params or CameraMapParams(), path=path)
        if path is None or not path.exists():
            m._refit()
            return m
        try:
            d = json.loads(path.read_text(encoding="utf-8"))
            m.points = [{k: float(p[k]) for k in ("u", "v", "x", "y")} for p in d.get("points", [])]
            m.camera = camera_signature(d["camera"]) if d.get("camera") else None
            m.saved_at = str(d.get("saved_at", ""))
        except (OSError, ValueError, KeyError, TypeError) as e:
            log.warning("ignoring %s: %s", path, e)
            m.points, m.camera = [], None
        m._refit()
        return m

    def save(self) -> None:
        if self.path is None:
            return
        self.saved_at = time.strftime("%Y-%m-%dT%H:%M:%S")
        d = {"_note": "Overview camera (u, v: 0..1 of the image as shown, flips applied) -> CoreXY XY (mm). "
                      "Each point: the arm's camera centred on a mark, that mark clicked in the overview image. "
                      "Recalibrate when the overview camera moves or its flips / resolution change.",
             "saved_at": self.saved_at, "camera": self.camera, "points": self.points,
             "homography": self.h.round(9).tolist() if self.h is not None else None,
             "errors_mm": [round(e, 2) for e in self.errors_mm]}
        self.path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # ---- editing
    def add(self, u: float, v: float, x: float, y: float, camera: dict) -> None:
        u, v = image_point(u, v)
        if not (math.isfinite(x) and math.isfinite(y)):
            raise CameraMapError("the robot's XY is not a number")
        if self.points and self.camera is not None and camera != self.camera:
            raise CameraMapError("the overview camera's size or flips changed since the other points: "
                                 "clear the calibration and record it again")
        if len(self.points) >= MAX_POINTS:
            raise CameraMapError(f"already {MAX_POINTS} points (clear or undo first)")
        for p in self.points:
            if math.hypot(p["x"] - x, p["y"] - y) < MIN_SPACING_MM:
                raise CameraMapError(f"a point at XY ({p['x']:g},{p['y']:g}) is already within "
                                     f"{MIN_SPACING_MM:g} mm: move the arm to another mark")
        self.camera = camera
        self.points.append({"u": round(u, 5), "v": round(v, 5), "x": round(x, 2), "y": round(y, 2)})
        self._refit()
        self.save()

    def undo(self) -> None:
        if self.points:
            self.points.pop()
        if not self.points:
            self.camera = None
        self._refit()
        self.save()

    def clear(self) -> None:
        self.points, self.camera = [], None
        self._refit()
        self.save()

    # ---- fit
    def _refit(self) -> None:
        self.h = self.h_inv = None
        self.errors_mm = []
        n, need = len(self.points), self.params.min_points
        if n < need:
            self.problem = f"{n} / {need} 点（あと {need - n} 点）"
            return
        uv = np.array([[p["u"], p["v"]] for p in self.points])
        xy = np.array([[p["x"], p["y"]] for p in self.points])
        if spread(uv) < MIN_SPREAD or spread(xy) < MIN_SPREAD:
            self.problem = "点が一直線に近い（プリントの四隅のように広く散らして記録する）"
            return
        try:
            h, condition = fit_homography(uv, xy)
            h_inv = np.linalg.inv(h)
        except np.linalg.LinAlgError:
            self.problem = "当てはめに失敗した（点を散らして記録し直す）"
            return
        if condition < MIN_DLT_CONDITION:
            self.problem = ("点の配置で対応が 1 つに決まらない（3 点以上が一直線に並んでいる）: "
                            "一直線から外れた所に点を足す")
            return
        # the map must not fold: the same orientation at every point
        signs = {np.sign(np.linalg.det(self._jacobian(h, u, v))) for u, v in uv}
        if len(signs) != 1 or 0 in signs:
            self.problem = "対応が折り返している（クリックした点の取り違え？最後の点を取り消す）"
            return
        self.h, self.h_inv = h, h_inv / h_inv[2, 2]
        self.errors_mm = [math.hypot(*np.subtract(apply(h, u, v), (x, y))) for (u, v), (x, y) in zip(uv, xy)]
        self.problem = ""
        if self.max_error > self.params.max_error_mm:
            self.problem = (f"誤差が大きい（最大 {self.max_error:.1f} mm > {self.params.max_error_mm:g} mm）: "
                            "誤差の大きい点を取り消して記録し直す")

    @staticmethod
    def _jacobian(h: np.ndarray, u: float, v: float) -> np.ndarray:
        eps = 1e-4
        x0, y0 = apply(h, u, v)
        x1, y1 = apply(h, u + eps, v)
        x2, y2 = apply(h, u, v + eps)
        return np.array([[x1 - x0, x2 - x0], [y1 - y0, y2 - y0]]) / eps

    @property
    def max_error(self) -> float:
        return max(self.errors_mm) if self.errors_mm else 0.0

    @property
    def rms_error(self) -> float:
        return math.sqrt(sum(e * e for e in self.errors_mm) / len(self.errors_mm)) if self.errors_mm else 0.0

    @property
    def usable(self) -> bool:
        return self.h is not None and not self.problem

    # ---- use
    def to_xy(self, u: Any, v: Any, camera: dict) -> tuple[float, float]:
        """XY (mm) under the image point, refused unless the calibration is trusted there."""
        u, v = image_point(u, v)
        if self.h is None or not self.usable:
            raise CameraMapError("camera calibration not usable: " + (self.problem or "not calibrated"))
        if camera != self.camera:
            raise CameraMapError(f"the overview camera changed since calibration ({self.camera} -> {camera}): "
                                 "calibrate again")
        x, y = apply(self.h, u, v)
        out = distance_outside(convex_hull([(p["x"], p["y"]) for p in self.points]), x, y)
        if out > self.params.margin_mm:
            raise CameraMapError(f"XY ({x:.0f},{y:.0f}) is {out:.0f} mm outside the calibrated area "
                                 f"(at most {self.params.margin_mm:g} mm): add a calibration point near there")
        return round(x, 2), round(y, 2)

    def status(self) -> dict:
        return {"points": list(self.points), "camera": self.camera, "usable": self.usable,
                "problem": self.problem, "min_points": self.params.min_points,
                "rms_mm": round(self.rms_error, 2), "max_mm": round(self.max_error, 2),
                "errors_mm": [round(e, 2) for e in self.errors_mm],
                # XY mm -> image (u, v): the panel marks where the arm's camera looks
                "h_inv": self.h_inv.round(9).tolist() if self.h_inv is not None else None,
                "saved_at": self.saved_at}
