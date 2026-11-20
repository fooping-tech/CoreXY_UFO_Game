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
CENTRES_MM = {"tl": (14.0, 14.0), "tr": (196.0, 14.0), "bl": (14.0, 283.0), "br": (196.0, 283.0)}
RATIO = (283.0 - 14.0) / (196.0 - 14.0)  # 269 / 182
MAX_CANDIDATES = 14
# a candidate's side (the square root of its area) against the mark's expected side
SIZE_TOLERANCE = (0.5, 2.0)
# three marks seen: the side ratio's error (stricter than four's), the middle mark's angle
THREE_MAX_SCORE = 0.3
THREE_MAX_COS = 0.35  # about 70..110 degrees


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
        out.append({"c": (m["m10"] / m["m00"], m["m01"] / m["m00"]), "area": area,
                    "quad": approx.reshape(4, 2).astype(float)})
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


def _sizes_fit(q: np.ndarray, sides: np.ndarray) -> bool:
    """Each blob is about a mark's size for a sheet this big in the image (a 12 mm square on a
    182 mm wide sheet). A round tape dispenser or a box off the sheet can sit where a rectangle
    of marks would fit, but it is far bigger (#130); perspective changes a mark by less than 2x."""
    tl, tr, bl, br = q
    width = (np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2
    mark = width / (196.0 - 14.0) * MARK_MM
    return bool(np.all(sides >= SIZE_TOLERANCE[0] * mark) and np.all(sides <= SIZE_TOLERANCE[1] * mark))


def find_marks(image: np.ndarray, max_score: float = 0.6) -> dict[str, Any] | None:
    """BGR or gray image -> {"corners": {tl, tr, bl, br: [u, v]}, "score"} or None.

    With three marks seen (#130: a cable over one), the fourth is where the three put it (the
    sheet as a parallelogram: a little off under perspective, close enough to straighten it);
    the answer then names it in "inferred". Four marks seen always win over three."""
    import cv2
    gray = image if image.ndim == 2 else cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    cands = _candidates(gray)
    if len(cands) < 3:
        return None
    pts = np.array([c["c"] for c in cands], dtype=float)
    sides = np.sqrt(np.array([c["area"] for c in cands], dtype=float))
    best: tuple[float, np.ndarray] | None = None
    for idx in itertools.combinations(range(len(pts)), 4):
        q = _order(pts[list(idx)])
        if q is None or not _sizes_fit(q, sides[list(idx)]):
            continue
        s = _score(q)
        if best is None or s < best[0]:
            best = (s, q)
    inferred = ""
    if best is None or best[0] > max_score:
        three = _three_marks(pts, sides, w, h, [c["quad"] for c in cands])
        if three is None:
            return None
        best, inferred = three
    s, q = best
    names = ("tl", "tr", "bl", "br")
    out: dict[str, Any] = {"corners": {n: [round(float(p[0]) / w, 5), round(float(p[1]) / h, 5)] for n, p in zip(names, q)},
                           "score": round(float(s), 4), "size": [w, h]}
    if inferred:
        out["inferred"] = inferred
    return out


def _three_marks(pts: np.ndarray, sides: np.ndarray, w: int, h: int,
                 quads: list[np.ndarray] | None = None) -> tuple[tuple[float, np.ndarray], str] | None:
    """The best sheet from three marks and a computed fourth, or None.

    Three points always make a parallelogram, so its opposite sides are equal by construction:
    the checks are the side ratio (THREE_MAX_SCORE), a right angle at the middle mark (give or
    take perspective, THREE_MAX_COS), the three blobs' size, and the fourth inside the image."""
    best: tuple[float, np.ndarray, np.ndarray] | None = None
    for idx in itertools.combinations(range(len(pts)), 3):
        tri = pts[list(idx)]
        for k in range(3):  # tri[k]: the corner between the other two (opposite the hidden one)
            v, a, b = tri[k], tri[(k + 1) % 3], tri[(k + 2) % 3]
            da, db = a - v, b - v
            na, nb = np.linalg.norm(da), np.linalg.norm(db)
            if na < 1e-6 or nb < 1e-6 or abs(float(da @ db)) / (na * nb) > THREE_MAX_COS:
                continue
            fourth = a + b - v
            if not (-0.02 * w <= fourth[0] <= 1.02 * w and -0.02 * h <= fourth[1] <= 1.02 * h):
                continue
            q = _order(np.vstack([tri, fourth]))
            if q is None:
                continue
            seen = sides[list(idx)]
            if not _sizes_fit(q, np.append(seen, seen.mean())):
                continue
            s = _score(q)
            if s <= THREE_MAX_SCORE and (best is None or s < best[0]):
                best = (s, q, fourth, list(idx))
    if best is None:
        return None
    s, q, fourth, idx = best
    names = ("tl", "tr", "bl", "br")
    k = int(np.argmin(np.linalg.norm(q - fourth, axis=1)))
    if quads is not None:
        better = _perspective_fourth(q, k, [quads[i] for i in idx], [pts[i] for i in idx])
        if better is not None:
            q = q.copy()
            q[k] = better
    return (s, q), names[k]


def _perspective_fourth(q: np.ndarray, k: int, quads: list[np.ndarray], centres: list[np.ndarray]) -> np.ndarray | None:
    """The hidden centre q[k] again, under the camera's perspective: the three seen marks give
    their centres and their 4 corners each (12 points of the page in mm), enough for the page's
    homography; the parallelogram guess only assigns which corner is which. None = keep the guess."""
    import cv2
    names = ("tl", "tr", "bl", "br")
    page_pts, img_pts = [], []
    half = MARK_MM / 2
    # the parallelogram's map page mm -> image, to name each blob corner by its nearest page corner
    src = np.float32([CENTRES_MM[n] for n in names])
    rough = cv2.getPerspectiveTransform(src, np.float32(q))
    for quad, centre in zip(quads, centres):
        n = names[int(np.argmin(np.linalg.norm(q - centre, axis=1)))]
        cx, cy = CENTRES_MM[n]
        page_corners = np.float32([[cx - half, cy - half], [cx + half, cy - half], [cx + half, cy + half], [cx - half, cy + half]])
        guess = cv2.perspectiveTransform(page_corners.reshape(-1, 1, 2), rough).reshape(-1, 2)
        used = set()
        for pc, g in zip(page_corners, guess):
            d = np.linalg.norm(quad - g, axis=1)
            j = int(np.argmin(d))
            if j in used:
                return None
            used.add(j)
            page_pts.append(pc)
            img_pts.append(quad[j])
        page_pts.append((cx, cy))
        img_pts.append(centre)
    hm, _ = cv2.findHomography(np.float32(page_pts), np.float32(img_pts), 0)
    if hm is None:
        return None
    p = hm @ np.array([*CENTRES_MM[names[k]], 1.0])
    if abs(p[2]) < 1e-9:
        return None
    return np.array([p[0] / p[2], p[1] / p[2]])


def find_marks_jpeg(data: bytes) -> dict[str, Any] | None:
    import cv2
    img = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise ValueError("the image is not a readable JPEG")
    return find_marks(img)
