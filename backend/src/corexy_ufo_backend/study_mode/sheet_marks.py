"""The study mode's worksheet in the overview frame (#116): its four corner marks, found with
OpenCV alone (no AI, nothing sent anywhere), so the game can show the real sheet, straightened.

The marks (tools/build_worksheets.py, fiducials): a 12 mm black square with a 4 mm white square
in its middle, centred at (14, 14), (196, 14), (14, 283), (196, 283) mm of the A4 page. Candidates
are dark four-sided blobs with one bright hole of about the right size; of them, the four that
make the closest 182 x 269 mm rectangle (in shape, under the camera's perspective) are the marks.

The answer is the four centres as 0..1 of the image as given (the game sends the frame as it
shows it: flips applied), named by the page: tl, tr, bl, br. Which short side is the page's top
cannot be told from the marks alone (they are all alike): the one nearer the top of the image.
"""

from __future__ import annotations

import itertools
import math
from typing import Any

import numpy as np

MARK_MM = 12.0
HOLE_MM = 4.0
CENTRES_MM = {"tl": (14.0, 14.0), "tr": (196.0, 14.0), "bl": (14.0, 283.0), "br": (196.0, 283.0)}
RATIO = (283.0 - 14.0) / (196.0 - 14.0)  # 269 / 182
MAX_CANDIDATES = 14


def _candidates(gray: np.ndarray) -> list[dict]:
    import cv2
    h, w = gray.shape
    blur = cv2.GaussianBlur(gray, (3, 3), 0)
    block = max(15, (min(h, w) // 12) | 1)
    binary = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, block, 12)
    contours, hier = cv2.findContours(binary, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)
    if hier is None:
        return []
    hier = hier[0]
    min_area = (min(h, w) * 0.008) ** 2
    max_area = (min(h, w) * 0.2) ** 2
    out = []
    for i, c in enumerate(contours):
        area = cv2.contourArea(c)
        if not min_area <= area <= max_area:
            continue
        approx = cv2.approxPolyDP(c, 0.08 * cv2.arcLength(c, True), True)
        if len(approx) != 4 or not cv2.isContourConvex(approx):
            continue
        x, y, bw, bh = cv2.boundingRect(approx)
        if not 0.4 <= bw / max(bh, 1) <= 2.5 or area < 0.5 * bw * bh:
            continue
        # one bright hole inside: (4 / 12)^2 = 0.11 of the mark, give or take blur and perspective
        child = hier[i][2]
        hole_ok = False
        while child != -1:
            ratio = cv2.contourArea(contours[child]) / area
            if 0.03 <= ratio <= 0.3:
                hole_ok = True
                break
            child = hier[child][0]
        if not hole_ok:
            continue
        m = cv2.moments(c)
        if m["m00"] <= 0:
            continue
        out.append({"c": (m["m10"] / m["m00"], m["m01"] / m["m00"]), "area": area})
    out.sort(key=lambda d: -d["area"])
    return out[:MAX_CANDIDATES]


def _order(pts: np.ndarray) -> np.ndarray | None:
    """Four points -> tl, tr, bl, br around their centre (convex, no crossing)."""
    c = pts.mean(axis=0)
    ang = np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0])
    ring = pts[np.argsort(ang)]  # clockwise on screen (y down), starting anywhere
    # rotate the ring so that the first edge is a short side whose midpoint is nearest the top
    best = None
    for k in range(4):
        r = np.roll(ring, -k, axis=0)
        e0 = np.linalg.norm(r[1] - r[0])
        e1 = np.linalg.norm(r[2] - r[1])
        if e0 > e1:
            continue  # r[0] -> r[1] must be a short side (the page's top)
        top_y = (r[0][1] + r[1][1]) / 2
        if best is None or top_y < best[0]:
            best = (top_y, r)
    if best is None:
        return None
    r = best[1]
    # clockwise from the top-left: tl, tr, br, bl
    return np.array([r[0], r[1], r[3], r[2]])


def _score(q: np.ndarray) -> float:
    """How far four ordered centres are from a 182 x 269 rectangle (0 = exact)."""
    tl, tr, bl, br = q
    top, bottom = np.linalg.norm(tr - tl), np.linalg.norm(br - bl)
    left, right = np.linalg.norm(bl - tl), np.linalg.norm(br - tr)
    if min(top, bottom, left, right) < 1e-6:
        return math.inf
    ratio = ((left + right) / 2) / ((top + bottom) / 2)
    # perspective changes opposite sides: allow it, but not a shape that is no rectangle
    return abs(math.log(ratio / RATIO)) + abs(math.log(top / bottom)) + abs(math.log(left / right))


def find_marks(image: np.ndarray, max_score: float = 0.6) -> dict[str, Any] | None:
    """BGR or gray image -> {"corners": {tl, tr, bl, br: [u, v]}, "score"} or None."""
    import cv2
    gray = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    cands = _candidates(gray)
    if len(cands) < 4:
        return None
    pts = np.array([c["c"] for c in cands], dtype=float)
    best: tuple[float, np.ndarray] | None = None
    for idx in itertools.combinations(range(len(pts)), 4):
        q = _order(pts[list(idx)])
        if q is None:
            continue
        s = _score(q)
        if best is None or s < best[0]:
            best = (s, q)
    if best is None or best[0] > max_score:
        return None
    s, q = best
    names = ("tl", "tr", "bl", "br")
    return {"corners": {n: [round(float(p[0]) / w, 5), round(float(p[1]) / h, 5)] for n, p in zip(names, q)},
            "score": round(float(s), 4), "size": [w, h]}


def find_marks_jpeg(data: bytes) -> dict[str, Any] | None:
    import cv2
    img = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise ValueError("the image is not a readable JPEG")
    return find_marks(img)
