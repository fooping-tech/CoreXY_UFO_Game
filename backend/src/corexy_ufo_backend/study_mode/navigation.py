"""目的の問題が先端カメラに写っていないとき、「今の撮影位置から X mm 動かす」量を計算し、安全を確かめる。

CoreXY UFO Game の backend/src/corexy_ufo_backend/study_mode/ に置く見本（このファイルは numpy だけに依存する）。

1. 学習支援 AI の API が、先端カメラ（10cm の高さ）の画像で「目的の問題の中心が画像の中心からどれだけずれているか」を返す
   （navigate.offset。画像の幅・高さを 1000 とした値。画面の外なら ±500 を超える）
2. offset_to_mm: 先端カメラのキャリブレーション（画像のずれ[px] ↔ アームの移動[mm] の 2×2 行列）で mm に直す
3. plan_relative: 今の撮影位置 + 移動量 が可動範囲の中か、1 回の移動量の上限以内かを確かめる
4. 実機は mm の目標を受け付けない（全体カメラのキャリブレーション経由の u, v だけ）ので、xy_to_uv で u, v に直して
   既存の homework_approach（段階撮影）をもう一度行う

先端カメラのキャリブレーション（tools/calibrate_focus.py で作る。高さごと）:
  {"heights": {"10cm": {"A": [[a11, a12], [a21, a22]], "image": [W, H]}}}
  A は「アームを d mm 動かすと、机の上の物は画像の中で s = -A·d [px] 動く」の A（向き・反転・回転を含む）。
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np


class NavigationError(ValueError):
    pass


@dataclass
class FocusCalibration:
    heights: dict  # 高さの名前 -> {"A": 2x2, "image": [W, H]}

    @classmethod
    def load(cls, path) -> "FocusCalibration":
        """path: a file, or a calibration.json section (anything with read_text, #96)."""
        src = path if hasattr(path, "read_text") else Path(path)
        raw = json.loads(src.read_text(encoding="utf-8"))
        for name, h in raw.get("heights", {}).items():
            a = np.asarray(h["A"], float)
            if a.shape != (2, 2) or abs(np.linalg.det(a)) < 1e-6:
                raise NavigationError(f"先端カメラのキャリブレーション（{name}）が正しくありません")
        return cls(raw.get("heights", {}))

    def offset_to_mm(self, offset: list[float], height: str = "10cm") -> tuple[float, float]:
        """画像のずれ（1000 = 画像の幅・高さ）→ 目的の問題を画像の中心に持ってくるためのアームの移動量 [mm]。"""
        if height not in self.heights:
            raise NavigationError(f"高さ {height} の先端カメラのキャリブレーションがありません")
        h = self.heights[height]
        w, hh = h["image"]
        p = np.array([offset[0] / 1000 * w, offset[1] / 1000 * hh])  # 目的の問題の中心 - 画像の中心 [px]
        d = np.linalg.solve(np.asarray(h["A"], float), p)          # 移動後に物が -p 動けば中心に来る: -A·d = -p
        return round(float(d[0]), 1), round(float(d[1]), 1)

    def direction_to_mm(self, direction: str, distance_mm: float, height: str = "10cm") -> tuple[float, float]:
        """camera_move (up/down/left/right in the picture, distance_mm) -> the arm's move [mm]: the way
        that brings what lies that way in the picture to its centre, distance_mm long (#242)."""
        if height not in self.heights:
            raise NavigationError(f"高さ {height} の先端カメラのキャリブレーションがありません")
        u = {"up": (0.0, -1.0), "down": (0.0, 1.0), "left": (-1.0, 0.0), "right": (1.0, 0.0)}.get(direction)
        if u is None:
            raise NavigationError(f"向き {direction!r} が分かりません")
        d = np.linalg.solve(np.asarray(self.heights[height]["A"], float), np.asarray(u))
        d = d / np.linalg.norm(d) * float(distance_mm)
        return round(float(d[0]), 1), round(float(d[1]), 1)


def plan_relative(current_xy: tuple[float, float], d_mm: tuple[float, float], *, x_range=(0.0, 390.0), y_range=(0.0, 200.0),
                  max_step_mm: float = 60.0, min_step_mm: float = 3.0) -> tuple[float, float]:
    """今の撮影位置 + 移動量。範囲外・大きすぎる移動は断る（NavigationError）。"""
    dx, dy = d_mm
    step = math.hypot(dx, dy)
    if not (math.isfinite(dx) and math.isfinite(dy)):
        raise NavigationError("移動量が数ではありません")
    if step > max_step_mm:
        raise NavigationError(f"1 回の移動が大きすぎます（{step:.0f} mm > {max_step_mm:g} mm）: 全体を撮り直して探してください")
    if step < min_step_mm:
        raise NavigationError("移動量が小さすぎます（もう写っているはず）")
    x, y = current_xy[0] + dx, current_xy[1] + dy
    if not (x_range[0] <= x <= x_range[1] and y_range[0] <= y <= y_range[1]):
        raise NavigationError(f"移動先 ({x:.0f}, {y:.0f}) mm が可動範囲の外です")
    return round(x, 2), round(y, 2)


def xy_to_uv(h_inv, x: float, y: float) -> tuple[float, float]:
    """XY [mm] → 全体カメラの画像の点 (u, v)。CameraXYMap.status()["h_inv"] を使う（to_xy の逆）。"""
    if h_inv is None:
        raise NavigationError("全体カメラのキャリブレーションがありません")
    p = np.asarray(h_inv, float) @ np.array([x, y, 1.0])
    return round(float(p[0] / p[2]), 6), round(float(p[1] / p[2]), 6)


# ---------------------------------------------------------------- 先端カメラのキャリブレーション
def phase_shift(img_a: np.ndarray, img_b: np.ndarray, exclude_px: float = 0.0) -> tuple[float, float]:
    """画像 a → b で、写っている物が何 px 動いたか（位相限定相関。サブピクセル）。グレースケールの 2 次元配列。
    exclude_px > 0: ずれ 0 の近く（その半径の内）の山を見ない。カメラと一緒に動く物（爪・アームの影・
    レンズの汚れ）は画像の中で止まって見え、紙の動きより強い山を 0 に作ることがある（#242）。"""
    a = img_a.astype(float) - img_a.mean()
    b = img_b.astype(float) - img_b.mean()
    win = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))  # 端の影響を減らす
    fa, fb = np.fft.fft2(a * win), np.fft.fft2(b * win)
    r = fb * np.conj(fa)
    r /= np.abs(r) + 1e-9
    c = np.fft.ifft2(r).real
    if exclude_px > 0:
        H0, W0 = c.shape
        yy = np.minimum(np.arange(H0), H0 - np.arange(H0))[:, None]
        xx = np.minimum(np.arange(W0), W0 - np.arange(W0))[None, :]
        c = np.where(yy ** 2 + xx ** 2 <= exclude_px ** 2, c.min(), c)
    iy, ix = np.unravel_index(np.argmax(c), c.shape)

    def sub(cm, cc, cp):  # 放物線で頂点を細かく求める
        den = cm - 2 * cc + cp
        return 0.0 if abs(den) < 1e-12 else 0.5 * (cm - cp) / den
    H, W = c.shape
    dy = iy + sub(c[(iy - 1) % H, ix], c[iy, ix], c[(iy + 1) % H, ix])
    dx = ix + sub(c[iy, (ix - 1) % W], c[iy, ix], c[iy, (ix + 1) % W])
    if dy > H / 2:
        dy -= H
    if dx > W / 2:
        dx -= W
    return float(dx), float(dy)


def estimate_A(moves_mm: list[tuple[float, float]], shifts_px: list[tuple[float, float]]) -> np.ndarray:
    """アームの移動 d[mm] と画像の中の物の動き s[px] の組（2 組以上）から、s = -A·d の A を最小二乗で求める。"""
    D = np.asarray(moves_mm, float)    # n×2
    S = -np.asarray(shifts_px, float)  # n×2  （s = -A d → -s = A d）
    if D.shape[0] < 2 or np.linalg.matrix_rank(D) < 2:
        raise NavigationError("X と Y の両方向に動かした組が必要です")
    At, *_ = np.linalg.lstsq(D, S, rcond=None)  # D·Aᵀ = S
    return At.T


# ------------------------------------------------------------------ the 校正 tab's calibration (#242)
MAX_RESIDUAL_PX = 6.0  # a calibration whose shifts do not fit A within this is not kept
STILL_PX = 4.0  # shifts this small are what moves with the camera (the claw), not the sheet
CAL_EDGE = 640


def px_per_mm(A) -> float | None:
    """How many pixels the picture moves for 1 mm of the arm (sqrt |det A|); None when A is not 2x2."""
    try:
        a = np.asarray(A, float)
        return round(float(abs(np.linalg.det(a)) ** 0.5), 2) if a.shape == (2, 2) else None
    except (TypeError, ValueError):
        return None


def _gray_jpeg(data: bytes, max_edge: int = CAL_EDGE) -> tuple[np.ndarray, tuple[int, int], float]:
    import cv2
    im = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_GRAYSCALE)
    if im is None:
        raise NavigationError("画像を読めません")
    H, W = im.shape
    s = min(1.0, max_edge / max(W, H))
    if s < 1:
        im = cv2.resize(im, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    return np.asarray(im, float), (W, H), s


def calibrate_from_jpegs(base, moves: list) -> dict:
    """The arm-tip camera's calibration from pictures (tools/calibrate_focus.py, done by the 校正 tab):
    a base picture and pictures after moving the arm (dx, dy) mm at the same height ->
    {"A", "image", "residual_px", "px_per_mm", "shifts"}. NavigationError when unusable.

    The camera hangs on the rope and may still swing: `base` and each move's picture may be a
    list of pictures taken in a row. Each shift is then the median of all of them against the
    first base picture, less the base's own (a swing goes either side of where it rests)."""
    bases = list(base) if isinstance(base, (list, tuple)) else [base]
    if not bases:
        raise NavigationError("基準の画像がありません")
    b, size, s = _gray_jpeg(bases[0])

    def shift_of(pictures) -> tuple[float, float]:
        out = []
        for data in pictures:
            img, size2, _ = _gray_jpeg(data)
            if size2 != size:
                raise NavigationError("画像の大きさが違います")
            out.append(phase_shift(b, img, exclude_px=STILL_PX))
        return tuple(float(v) for v in np.median(np.asarray(out), axis=0))
    b0 = (0.0, 0.0)
    if len(bases) > 1:  # the base frames against the first one: the first may be off the swing's middle
        others = [phase_shift(b, _gray_jpeg(d)[0], exclude_px=0.0) for d in bases[1:]]
        b0 = tuple(float(v) for v in np.median(np.asarray([(0.0, 0.0)] + others), axis=0))
    mv, sh = [], []
    for data, dx, dy in moves:
        sx, sy = shift_of(data if isinstance(data, (list, tuple)) else [data])
        mv.append((float(dx), float(dy)))
        sh.append(((sx - b0[0]) / s, (sy - b0[1]) / s))
    A = estimate_A(mv, sh)
    resid = [float(np.hypot(*(np.asarray(x) + A @ np.asarray(m)))) for m, x in zip(mv, sh)]
    ppm = float(abs(np.linalg.det(A)) ** 0.5)
    seen = "、".join(f"({m[0]:+g},{m[1]:+g})mm→({x[0]:+.0f},{x[1]:+.0f})px" for m, x in zip(mv, sh))
    if ppm < 0.3:
        raise NavigationError(f"アームを動かしても画像がほとんど動きませんでした（{seen}）。"
                              "先端カメラに文字が大きく写る高さ・プリントの真上か確かめる")
    if max(resid) > MAX_RESIDUAL_PX:
        raise NavigationError(f"画像のずれがアームの動きと合いません（誤差 {max(resid):.1f} px。{seen}）。"
                              "文字が写っているか、紙や手が動かなかったか確かめてもう一度")
    return {"A": A.round(4).tolist(), "image": list(size), "residual_px": [round(r, 2) for r in resid],
            "px_per_mm": round(ppm, 2), "shifts": [[round(a, 1), round(b2, 1)] for a, b2 in sh]}
