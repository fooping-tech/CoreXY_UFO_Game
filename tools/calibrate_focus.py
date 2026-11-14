"""先端カメラのキャリブレーション: 「アームを d mm 動かすと、画像の中の物が何 px 動くか」を測る（高さごとに 1 回）。

使い方（このリポジトリの backend で。OpenCV が要る: uv sync --extra vision）:
  1. プリントを机に置き、アームを撮影の高さ（例: 10cm）にして先端カメラの画像を保存する → base.jpg
  2. 同じ高さのまま X に +10 mm 動かして保存 → x10.jpg、元に戻して Y に +10 mm 動かして保存 → y10.jpg
     （ゲームの jog / move_xy などで。動かしている間に紙や手を動かさない）
  3. cd backend && uv run python ../tools/calibrate_focus.py --height 10cm --base base.jpg \
         --move x10.jpg 10 0 --move y10.jpg 0 10
     → config/calibration.json の focus_camera に保存（この機械だけの値。Git には入らない。#96, #104）。
       --out にファイルを指定すると、そのファイルに書く。
  出力の A（2×2）は向き・反転・回転も含む。測ったずれと、A から計算し直したずれの差（px）も表示する。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "backend" / "src"))
from corexy_ufo_backend.calibration_store import section  # noqa: E402
from corexy_ufo_backend.study_mode.navigation import estimate_A, phase_shift  # noqa: E402


def gray(path: str, max_edge: int = 640) -> tuple[np.ndarray, tuple[int, int], float]:
    import cv2
    im = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if im is None:
        raise SystemExit(f"画像を読めません: {path}")
    H, W = im.shape
    s = min(1.0, max_edge / max(W, H))
    if s < 1:
        im = cv2.resize(im, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    return np.asarray(im, float), (W, H), s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--height", required=True, help="高さの名前（10cm / 5cm / landing）")
    ap.add_argument("--base", required=True)
    ap.add_argument("--move", nargs=3, action="append", metavar=("IMAGE", "DX_MM", "DY_MM"), required=True)
    ap.add_argument("--out", default="", help="書き出すファイル（省くと config/calibration.json の focus_camera）")
    args = ap.parse_args()
    base, size, s = gray(args.base)
    moves, shifts = [], []
    for path, dx, dy in args.move:
        img, size2, _ = gray(path)
        if size2 != size:
            raise SystemExit(f"画像の大きさが違います: {path}")
        sx, sy = phase_shift(base, img)
        moves.append((float(dx), float(dy)))
        shifts.append((sx / s, sy / s))  # 元の解像度の px に戻す
        print(f"{path}: アーム ({dx}, {dy}) mm → 画像の中の物 ({sx / s:+.1f}, {sy / s:+.1f}) px")
    A = estimate_A(moves, shifts)
    resid = [np.hypot(*(np.asarray(sh) + A @ np.asarray(mv))) for mv, sh in zip(moves, shifts)]
    out = Path(args.out) if args.out else section(REPO / "config", "focus_camera")
    raw = json.loads(out.read_text(encoding="utf-8")) if out.exists() else {"heights": {}}
    raw.setdefault("heights", {})[args.height] = {"A": A.round(4).tolist(), "image": list(size),
                                                  "residual_px": [round(float(r), 2) for r in resid]}
    if isinstance(out, Path):
        out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(raw, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"A = {A.round(3).tolist()}  （1 mm あたり約 {np.abs(np.linalg.det(A)) ** 0.5:.1f} px）  誤差 {max(resid):.2f} px")
    print(f"保存しました: {out}")


if __name__ == "__main__":
    main()
