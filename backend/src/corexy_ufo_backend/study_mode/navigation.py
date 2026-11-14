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
def phase_shift(img_a: np.ndarray, img_b: np.ndarray) -> tuple[float, float]:
    """画像 a → b で、写っている物が何 px 動いたか（位相限定相関。サブピクセル）。グレースケールの 2 次元配列。"""
    a = img_a.astype(float) - img_a.mean()
    b = img_b.astype(float) - img_b.mean()
    win = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))  # 端の影響を減らす
    fa, fb = np.fft.fft2(a * win), np.fft.fft2(b * win)
    r = fb * np.conj(fa)
    r /= np.abs(r) + 1e-9
    c = np.fft.ifft2(r).real
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
