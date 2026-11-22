"""ジェスチャー認識の記録・集計（#256）: 「手を見失った」のか「手は見えたが形の判定で外れた」のかを切り分ける。

ゲームと同じ設定（config の gesture: カメラ・MediaPipe のしきい値・ピンチのしきい値）で、カメラだけを使う。
ロボットにもゲームにも何も送らない。ゲーム（./start.sh）を止めてから使う（カメラの取り合いを避ける）。

使い方（backend で。OpenCV と MediaPipe が要る: uv sync --extra vision --extra hands）:

  cd backend
  uv run python ../tools/gesture_probe.py record
      ウィンドウにカメラの映像と今の判定が出る。キーで「今どの手を出しているか（正解）」を付ける:
        1 = パー   2 = グー   3 = ピンチ   0 = 手を出していない   Space = 正解なし   q / Esc = 終わり
      正解のキーを押してから、その手を数秒〜十数秒続ける（動かしてもよい）。
      logs/gesture_probe/<日時>/ に probe.jsonl（フレームごとの記録）と video.avi（元の映像）を保存する。
      映像には手と部屋が写る: Git に入らない場所に置き、共有しない。

  uv run python ../tools/gesture_probe.py analyze ../logs/gesture_probe/<日時>
      正解ごとの集計を表示する（--json で機械向け）。

  uv run python ../tools/gesture_probe.py replay ../logs/gesture_probe/<日時> --detection-confidence 0.3
      保存した映像を、設定を変えて判定し直す（同じ手の動きで設定を比べる）。変えられるもの:
        --detection-confidence / --tracking-confidence（MediaPipe）、--crop x0,y0,x1,y1（0..1 で切り抜いてから渡す）、
        --pinch-start / --pinch-release / --lost-grace-ms（ゲームのピンチの判定）、--delegate cpu|gpu
      映像は圧縮されているので、比べるときは変えない replay（引数なし）を基準にする。
      結果は replay-<名前>.jsonl に保存し、変えない replay（replay-base.jsonl）があれば並べて表示する。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "backend" / "src"))
from corexy_ufo_backend.config import load_config  # noqa: E402
from corexy_ufo_backend.vision_service import gesture_probe as gp  # noqa: E402
from corexy_ufo_backend.vision_service.hand_control import HandControl, HandControlConfig  # noqa: E402

LOG_ROOT = REPO / "logs" / "gesture_probe"
KEYS = {ord("1"): "open", ord("2"): "fist", ord("3"): "pinch", ord("0"): "none", ord(" "): ""}
SHOWN = {"open": "OPEN (pa-)", "fist": "FIST (gu-)", "pinch": "PINCH", "none": "NO HAND", "": "-"}


def gesture_settings(args: argparse.Namespace) -> dict[str, Any]:
    """The game's gesture section with this run's changes."""
    g = dict(load_config().raw.get("gesture", {}))
    for key, attr in (("detection_confidence", "detection_confidence"), ("tracking_confidence", "tracking_confidence"),
                      ("pinch_start", "pinch_start"), ("pinch_release", "pinch_release"),
                      ("lost_grace_ms", "lost_grace_ms"), ("delegate", "delegate")):
        v = getattr(args, attr, None)
        if v is not None:
            g[key] = v
    return g


def make_tracker(g: dict[str, Any]):
    from corexy_ufo_backend.vision_service.mediapipe_hands import MediaPipeHandTracker
    return MediaPipeHandTracker(delegate=str(g.get("delegate", "gpu")), recreate_s=float(g.get("gpu_recreate_s", 10.0)),
                                min_confidence=float(g.get("detection_confidence", 0.5)),
                                tracking_confidence=float(g.get("tracking_confidence", 0.3)))


def make_control(g: dict[str, Any], crop: tuple[float, float, float, float] | None) -> HandControl:
    cfg = HandControlConfig.from_dict(g)
    if crop is not None:
        cfg.roi_enabled = False  # the crop already is the region; its coordinates are not the full frame's
    return HandControl(cfg)


def parse_crop(s: str | None) -> tuple[float, float, float, float] | None:
    if not s:
        return None
    v = tuple(float(x) for x in s.split(","))
    if len(v) != 4 or not (0 <= v[0] < v[2] <= 1 and 0 <= v[1] < v[3] <= 1):
        raise SystemExit("--crop は x0,y0,x1,y1（0..1、x0<x1、y0<y1）")
    return v  # type: ignore[return-value]


def apply_crop(frame, crop):
    if crop is None:
        return frame
    h, w = frame.shape[:2]
    x0, y0, x1, y1 = crop
    return frame[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]


def process(frame, *, i: int, t: float, gap_ms: float, label: str, tracker, control: HandControl, crop) -> dict[str, Any]:
    """One frame through the game's pipeline -> one record."""
    img = apply_crop(frame, crop)
    h, w = img.shape[:2]
    hr = tracker.track(img, ts_ms=int(t * 1000))
    ev = control.update(hr.landmarks, hr.scores, w, h, t * 1000.0)
    bright, blur = gp.image_quality(img)
    return gp.frame_record(i=i, t=t, label=label, ev=ev, hands=hr.landmarks, world=hr.world, scores=hr.scores,
                           handedness=hr.handedness, w=w, h=h, latency_ms=hr.latency_ms, gap_ms=gap_ms,
                           bright=bright, blur=blur)


def meta_line(g: dict[str, Any], **extra: Any) -> dict[str, Any]:
    keep = ("camera", "frame_width", "frame_height", "fps", "delegate", "detection_confidence", "tracking_confidence",
            "pinch_start", "pinch_release", "pinch_confirm_ms", "release_confirm_ms", "lost_grace_ms", "stale_ms",
            "min_confidence", "roi", "roi_enabled")
    return {"type": "meta", "issue": 256, "created": datetime.now().isoformat(timespec="seconds"),
            "gesture": {k: g[k] for k in keep if k in g}, **extra}


def draw(frame, rec: dict[str, Any], label: str, flip: tuple[bool, bool]):
    import cv2

    img = frame.copy()
    h, w = img.shape[:2]
    lm = rec.get("lm")
    if lm:
        pts = [(int(p[0] * w), int(p[1] * h)) for p in lm]
        for a, b in ((0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11),
                     (11, 12), (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)):
            cv2.line(img, pts[a], pts[b], (0, 220, 255), 2)
        for p in pts:
            cv2.circle(img, p, 3, (0, 80, 255), -1)
    fh, fv = flip
    if fh and fv:
        img = cv2.flip(img, -1)
    elif fh:
        img = cv2.flip(img, 1)
    elif fv:
        img = cv2.flip(img, 0)
    ok = (label == "open" and rec["pose"] == "open") or (label == "fist" and rec["pose"] == "fist") or \
         (label == "pinch" and rec["pinch"]) or (label == "none" and rec["hands"] == 0)
    color = (60, 200, 60) if ok else (40, 40, 230) if label else (220, 220, 220)
    ext = rec.get("ext") or {}
    rows = [f"LABEL: {SHOWN.get(label, label)}   [1]open [2]fist [3]pinch [0]none [space]- [q]quit",
            f"hands={rec['hands']}  reason={rec['reason'] or 'ok'}  pose={rec['pose'] or '-'}"
            f"  3d={rec.get('pose3d', '-')}  pinch={'ON' if rec['pinch'] else 'off'}  ratio={rec['pinch_ratio']:.2f}",
            "ext: " + "  ".join(f"{k[:2]}={v:.2f}" for k, v in ext.items())
            + (f"  thumb={rec.get('thumb_out', 0):.2f}" if ext else ""),
            f"hand={rec.get('hand_px', 0):.0f}px  bright={rec.get('bright', 0):.0f}  sharp={rec.get('blur', 0):.0f}"
            f"  {rec['latency_ms']:.0f}ms"]
    cv2.rectangle(img, (0, 0), (img.shape[1], 18 * len(rows) + 8), (0, 0, 0), -1)
    for k, row in enumerate(rows):
        cv2.putText(img, row, (6, 18 + 18 * k), cv2.FONT_HERSHEY_SIMPLEX, 0.45, color if k == 1 else (235, 235, 235), 1,
                    cv2.LINE_AA)
    return img


def open_camera(index: int, width: int, height: int):
    import cv2

    if sys.platform == "darwin":
        cap = cv2.VideoCapture(index, cv2.CAP_AVFOUNDATION)
    elif sys.platform == "win32":
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
    else:
        cap = cv2.VideoCapture(index)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    if not cap.isOpened():
        raise SystemExit(f"カメラ {index} を開けません（ゲームが使っていないか確かめてください）")
    return cap


def cmd_record(args: argparse.Namespace) -> None:
    import cv2
    from corexy_ufo_backend.vision_service.cameras import resolve_camera

    g = gesture_settings(args)
    crop = parse_crop(args.crop)
    spec = args.camera or str(g.get("camera", "0"))
    index = resolve_camera(spec)
    cap = open_camera(index, int(g.get("frame_width", 640)), int(g.get("frame_height", 480)))
    overview = load_config().raw.get("camera", {}).get("overview", {})
    flip = (bool(overview.get("flip_h", False)), bool(overview.get("flip_v", False)))
    out = Path(args.out) if args.out else LOG_ROOT / datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    tracker = make_tracker(g)
    control = make_control(g, crop)
    writer = None
    fps = float(g.get("fps", 30.0))
    label = ""
    i = 0
    t0 = time.perf_counter()
    prev_t = 0.0
    print(f"記録先: {out}\nキー: 1 パー / 2 グー / 3 ピンチ / 0 手なし / Space 正解なし / q 終わり")
    with open(out / "probe.jsonl", "w", encoding="utf-8") as f:
        f.write(json.dumps(meta_line(g, camera_spec=spec, camera_index=index, crop=crop, flip=flip,
                                     video=None if args.no_video else "video.avi"), ensure_ascii=False) + "\n")
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    time.sleep(0.02)
                    continue
                t = time.perf_counter() - t0
                if writer is None and not args.no_video:
                    h, w = frame.shape[:2]
                    writer = cv2.VideoWriter(str(out / "video.avi"), cv2.VideoWriter_fourcc(*"MJPG"), fps, (w, h))
                if writer is not None:
                    writer.write(frame)
                rec = process(frame, i=i, t=t, gap_ms=(t - prev_t) * 1000.0 if i else 0.0, label=label,
                              tracker=tracker, control=control, crop=crop)
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                prev_t = t
                i += 1
                cv2.imshow("gesture probe (#256)", draw(apply_crop(frame, crop), rec, label, flip))
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key in KEYS:
                    label = KEYS[key]
                if args.seconds and t >= args.seconds:
                    break
        finally:
            cap.release()
            if writer is not None:
                writer.release()
            tracker.close()
            cv2.destroyAllWindows()
    print(f"{i} フレームを記録しました: {out}\n")
    analyze_file(out / "probe.jsonl", g)


def load(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if path.is_dir():
        path = path / "probe.jsonl"
    with open(path, encoding="utf-8") as f:
        return gp.read_jsonl(f)


def analyze_file(path: Path, g: dict[str, Any] | None = None, *, as_json: bool = False) -> dict[str, gp.LabelSummary]:
    meta, recs = load(path)
    g = g or meta.get("gesture", {})
    grace, stale = float(g.get("lost_grace_ms", 300.0)), float(g.get("stale_ms", 350.0))
    summary = gp.summarize(recs, lost_grace_ms=grace, stale_ms=stale)
    if as_json:
        print(json.dumps({k: v.to_dict() for k, v in summary.items()}, ensure_ascii=False, indent=1, default=str))
    else:
        print(gp.report(summary, lost_grace_ms=grace, stale_ms=stale))
    return summary


def cmd_analyze(args: argparse.Namespace) -> None:
    analyze_file(Path(args.path), as_json=args.json)


def cmd_replay(args: argparse.Namespace) -> None:
    import cv2

    src = Path(args.path)
    meta, recs = load(src)
    folder = src if src.is_dir() else src.parent
    video = folder / (meta.get("video") or "video.avi")
    if not video.exists():
        raise SystemExit(f"映像がありません: {video}（record を --no-video で記録した?）")
    g = dict(meta.get("gesture", {}))
    for key in ("detection_confidence", "tracking_confidence", "pinch_start", "pinch_release", "lost_grace_ms", "delegate"):
        v = getattr(args, key, None)
        if v is not None:
            g[key] = v
    # the recorded crop unless changed: the labels and the video belong to that crop
    crop = parse_crop(args.crop) if args.crop else (tuple(meta["crop"]) if meta.get("crop") else None)
    changes = {k: getattr(args, k) for k in ("detection_confidence", "tracking_confidence", "pinch_start",
                                              "pinch_release", "lost_grace_ms", "delegate", "crop")
               if getattr(args, k, None) is not None}
    name = args.name or ("base" if not changes else "_".join(f"{k}={v}" for k, v in changes.items()).replace(",", "-"))
    tracker = make_tracker(g)
    control = make_control(g, crop)
    cap = cv2.VideoCapture(str(video))
    new: list[dict[str, Any]] = []
    try:
        for r in recs:
            ok, frame = cap.read()
            if not ok:
                break
            new.append(process(frame, i=r["i"], t=r["t"], gap_ms=r.get("gap_ms", 0.0), label=r.get("label", ""),
                               tracker=tracker, control=control, crop=crop))
    finally:
        cap.release()
        tracker.close()
    out = folder / f"replay-{name}.jsonl"
    with open(out, "w", encoding="utf-8") as f:
        f.write(json.dumps(meta_line(g, replay_of=str(video.name), changes=changes, crop=crop), ensure_ascii=False) + "\n")
        for r in new:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    grace, stale = float(g.get("lost_grace_ms", 300.0)), float(g.get("stale_ms", 350.0))
    summary = gp.summarize(new, lost_grace_ms=grace, stale_ms=stale)
    print(f"replay {name}: {len(new)} / {len(recs)} フレーム → {out}\n")
    print(gp.report(summary, lost_grace_ms=grace, stale_ms=stale))
    base = folder / "replay-base.jsonl"
    if name != "base" and base.exists():
        bmeta, brecs = load(base)
        bgrace = float(bmeta.get("gesture", {}).get("lost_grace_ms", grace))  # the baseline's own grace
        bm = gp.key_metrics(gp.summarize(brecs, lost_grace_ms=bgrace), lost_grace_ms=bgrace)
        nm = gp.key_metrics(summary, lost_grace_ms=grace)
        print("基準（replay-base）との比較: seen = 手が見えた割合, right = 正しく判定された割合, stops = 操作が止まる見失い")
        for lab in nm:
            cells = []
            for k, v in nm[lab].items():
                b = bm.get(lab, {}).get(k)
                fmt = (lambda x: f"{100 * x:.0f}%") if k in ("seen", "right", "right3d") else (lambda x: f"{x:.0f}")
                cells.append(f"{k} {fmt(b) if b is not None else '-'} → {fmt(v)}")
            print(f"  {gp.LABELS.get(lab, lab)}: " + ", ".join(cells))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def tuning(p: argparse.ArgumentParser) -> None:
        p.add_argument("--detection-confidence", type=float)
        p.add_argument("--tracking-confidence", type=float)
        p.add_argument("--pinch-start", type=float)
        p.add_argument("--pinch-release", type=float)
        p.add_argument("--lost-grace-ms", type=float)
        p.add_argument("--delegate", choices=("cpu", "gpu"))
        p.add_argument("--crop", help="x0,y0,x1,y1 (0..1): この範囲だけを MediaPipe に渡す")

    p = sub.add_parser("record", help="カメラで記録する")
    tuning(p)
    p.add_argument("--camera", help="カメラ名の一部か番号（既定: config の gesture.camera）")
    p.add_argument("--out", help="保存先のフォルダ（既定: logs/gesture_probe/<日時>）")
    p.add_argument("--no-video", action="store_true", help="映像を保存しない（replay できなくなる）")
    p.add_argument("--seconds", type=float, default=0.0, help="この秒数で自動で終わる")
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("analyze", help="記録を集計する")
    p.add_argument("path", help="記録のフォルダか .jsonl")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_analyze)

    p = sub.add_parser("replay", help="保存した映像を設定を変えて判定し直す")
    p.add_argument("path", help="記録のフォルダ")
    p.add_argument("--name", help="結果の名前（replay-<名前>.jsonl）")
    tuning(p)
    p.set_defaults(func=cmd_replay)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
