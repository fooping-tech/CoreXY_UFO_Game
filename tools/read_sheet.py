"""プリント 1 枚を学習支援 AI のプリント読み取り API（POST /v1/sheet、#230）で読み、結果と枠を描いた画像を出す。

    cd backend && uv run python ../tools/read_sheet.py ../tools/samples/worksheet_sample.jpg
    （--out 枠を描いた画像の保存先。省くと <写真>.sheet.jpg。--no-crop / --no-calc はサーバの切り出し・計算し直しを止める）

接続先・トークン・証明書は、ゲームと同じ config の study.tutor_url / tutor_token_file / tutor_cafile。
トークンと画像は画面に出さない。401 なら再試行しない（10 回まちがえると 10 分ブロックされる）。
描いた画像には児童の手書きが写るので、共有しない・リポジトリに入れないこと。
終了コード: 0 = 読めた、1 = 失敗、2 = つながったが問題を読めなかった。
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import replace
from pathlib import Path

import cv2
import numpy as np

from corexy_ufo_backend.config import REPO_ROOT
from corexy_ufo_backend.study import StudyConfig, make_sheet_client
from corexy_ufo_backend.study.sheet_client import SheetError

COLOURS = {"correct": (80, 200, 80), "incorrect": (60, 60, 230), "blank": (200, 160, 60),
           "partial": (40, 180, 230), "unreadable": (150, 150, 150)}  # BGR


def study_raw() -> dict:
    out: dict = {}
    for name in ("game_config.json", "local_settings.json"):
        try:
            d = json.loads((REPO_ROOT / "config" / name).read_text(encoding="utf-8")).get("study", {})
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(d, dict):
            out.update(d)
    return {"study": out}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("photo")
    ap.add_argument("--out", help="枠を描いた画像の保存先（既定 <写真>.sheet.jpg）")
    ap.add_argument("--no-crop", action="store_true")
    ap.add_argument("--no-calc", action="store_true")
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    photo = Path(a.photo)
    data = photo.read_bytes()
    cfg = replace(StudyConfig.from_raw(study_raw()), root=str(REPO_ROOT))
    try:
        client = make_sheet_client(cfg)
        print(f"接続先: {client.base}（トークン: {'あり' if client.token else 'なし'}）… 約 10 秒")
        res = client.read(data, calc=not a.no_calc, crop=not a.no_crop)
    except SheetError as e:
        print(f"[NG] {e.kind}: {e}")
        return 1
    print(f"[OK] {res.summary()}・{res.raw.get('seconds', '?')} 秒・切り出し: {'あり' if res.cropped else 'なし'}")
    for n in res.raw.get("notes") or []:
        print(f"  注記: {n}")
    for p in res.problems:
        line = f"  {p['number']:>2}. {p['answer_status']:<10} 答え「{p['student_answer']}」 正答 {p.get('correct_answer')}"
        print(line + ("（見切れ）" if p.get("visible") == "partial" else "") + "".join(f" / {n}" for n in p["notes"]))
    # the boxes on the photo itself (0..1000 scale x the photo's size; EXIF rotation applied)
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    t = max(2, round(max(img.shape[:2]) / 500))
    for p in res.problems:
        box, ans = res.boxes_on_source(p)
        c = COLOURS.get(p["answer_status"], (150, 150, 150))
        if box:
            cv2.rectangle(img, box[:2], box[2:], c, t)
            cv2.putText(img, str(p["number"]), (box[0] + t, box[1] + 12 * t), cv2.FONT_HERSHEY_SIMPLEX, 0.5 * t, c, t)
        if ans:
            cv2.rectangle(img, ans[:2], ans[2:], c, max(1, t // 2))
    out = Path(a.out) if a.out else photo.with_suffix(".sheet.jpg")
    cv2.imwrite(str(out), img)
    print(f"枠を描いた画像: {out}（緑 正解・赤 まちがい・青 空白・橙 書きかけ・灰 読めない。細い枠が答えのらん）")
    return 0 if res.read_anything else 2


if __name__ == "__main__":
    sys.exit(main())
