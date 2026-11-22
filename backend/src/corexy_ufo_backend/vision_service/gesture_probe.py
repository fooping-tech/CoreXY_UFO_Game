"""Gesture probe (#256): what the hand recognition sees, frame by frame, so a
"the hand was lost" can be told apart from "the hand was seen but the shape was
judged wrong". `tools/gesture_probe.py` records (camera + labels typed by the
person) and replays; this module is the pure part: per-frame measurements, the
JSONL record and the summary per label. No camera, no MediaPipe import.

A record is one JSON object per frame (`frame_record`). The label is what the
person says the hand is doing ("open" = パー, "fist" = グー, "pinch" = ピンチ,
"none" = no hand on purpose, "" = not labelled). The game's own decision is
HandControl's `hand_control` event (reason / pose / pinch), recorded as is.

Next to the game's 2D rule (a finger is folded when its tip is nearer the wrist
than its PIP joint, in the image) the record has a 3D reading for comparison:
the bend of each finger (degrees, the sum of the MCP, PIP and DIP angles) from
MediaPipe's world landmarks (metres, centred on the hand), which do not shrink
when a finger points at the camera. `pose3d` applies the game's shape rule to
those bends. It is a reference only: the game does not use it.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Iterable

from .hand_control import FINGERS, THUMB_OUT, WRIST, Landmark, hand_scale, thumb_out

LABELS = {"open": "パー", "fist": "グー", "pinch": "ピンチ", "none": "手なし"}
# (MCP, PIP, DIP, TIP) per finger, for the 3D bend
CHAINS = {"index": (5, 6, 7, 8), "middle": (9, 10, 11, 12), "ring": (13, 14, 15, 16), "pinky": (17, 18, 19, 20)}
# a finger counts as folded in 3D above this total bend (straight about 0-40, a fist about 180-260)
BEND_FOLDED_DEG = 100.0
CLAW_POSES = ("fist", "thumb", "peace")  # the shapes that end a running pinch (hand_control.py)


# ---------------------------------------------------------------- per frame

def finger_extension(lm: list[Landmark], w: int, h: int) -> dict[str, float]:
    """|wrist - tip| / |wrist - PIP| per finger, in pixels: the game's 2D rule
    calls a finger folded below 1.0 (and straight above STRAIGHT_RATIO)."""
    wx, wy = lm[WRIST][0] * w, lm[WRIST][1] * h
    out: dict[str, float] = {}
    for name, (tip, pip) in FINGERS.items():
        t = math.hypot(lm[tip][0] * w - wx, lm[tip][1] * h - wy)
        p = math.hypot(lm[pip][0] * w - wx, lm[pip][1] * h - wy)
        out[name] = t / p if p > 1e-9 else 0.0
    return out


def thumb_out_ratio(lm: list[Landmark], w: int, h: int) -> float:
    """|thumb tip - middle MCP| / hand size (thumb_out() compares it with THUMB_OUT)."""
    scale = hand_scale(lm, w, h)
    if scale <= 1e-6:
        return 0.0
    tx, ty = lm[4][0] * w, lm[4][1] * h
    mx, my = lm[9][0] * w, lm[9][1] * h
    return math.hypot(tx - mx, ty - my) / scale


def _angle(a: Landmark, b: Landmark, c: Landmark) -> float:
    """The turn at b, degrees: 0 when a, b, c lie on a straight line."""
    u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
    v = (c[0] - b[0], c[1] - b[1], c[2] - b[2])
    nu = math.sqrt(u[0] ** 2 + u[1] ** 2 + u[2] ** 2)
    nv = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    if nu * nv <= 1e-12:
        return 0.0
    cos = (u[0] * v[0] + u[1] * v[1] + u[2] * v[2]) / (nu * nv)
    return math.degrees(math.acos(max(-1.0, min(1.0, cos))))


def finger_bend3d(wlm: list[Landmark]) -> dict[str, float]:
    """Total bend per finger (degrees) from world landmarks: the angles at the
    MCP (wrist -> MCP -> PIP), the PIP and the DIP."""
    out: dict[str, float] = {}
    for name, (mcp, pip, dip, tip) in CHAINS.items():
        out[name] = (_angle(wlm[WRIST], wlm[mcp], wlm[pip]) + _angle(wlm[mcp], wlm[pip], wlm[dip])
                     + _angle(wlm[pip], wlm[dip], wlm[tip]))
    return out


def pose_from_folded(folded: dict[str, bool], thumb_is_out: bool) -> str:
    """The game's shape rule (hand_control.hand_pose) on given folded flags."""
    f = folded
    if all(f.values()):
        return "thumb" if thumb_is_out else "fist"
    if not f["index"] and not f["middle"] and f["ring"] and f["pinky"]:
        return "peace"
    if not f["index"] and not f["middle"] and not f["ring"] and f["pinky"]:
        return "three"
    if not f["index"] and f["middle"] and f["ring"] and f["pinky"]:
        return "point"
    if not any(f.values()):
        return "open"
    return "other"


def image_quality(frame_bgr: Any) -> tuple[float, float]:
    """(mean brightness 0..255, sharpness = variance of the Laplacian; low = blurred)."""
    import cv2  # type: ignore

    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    small = cv2.resize(gray, (320, 240), interpolation=cv2.INTER_AREA)
    return float(small.mean()), float(cv2.Laplacian(small, cv2.CV_64F).var())


def _r(v: float, nd: int = 3) -> float:
    return round(float(v), nd)


def frame_record(*, i: int, t: float, label: str, ev: dict[str, Any], hands: list[list[Landmark]],
                 world: list[list[Landmark]] | None, scores: list[float], handedness: list[str],
                 w: int, h: int, latency_ms: float, gap_ms: float,
                 bright: float | None = None, blur: float | None = None) -> dict[str, Any]:
    """One JSONL line: the label, HandControl's decision and the measurements of the first hand."""
    rec: dict[str, Any] = {
        "i": i, "t": _r(t, 3), "label": label, "hands": len(hands),
        "scores": [_r(s) for s in scores], "handed": list(handedness),
        "reason": str(ev.get("reason", "")), "detected": bool(ev.get("detected", False)),
        "held": bool(ev.get("held", False)), "pose": str(ev.get("pose", "")),
        "pinch": bool(ev.get("pinch", False)), "pinch_finger": str(ev.get("pinch_finger", "")),
        "pinch_ratio": _r(ev.get("pinch_ratio", 0.0)),
        "latency_ms": _r(latency_ms, 1), "gap_ms": _r(gap_ms, 1),
    }
    if bright is not None:
        rec["bright"] = _r(bright, 1)
    if blur is not None:
        rec["blur"] = _r(blur, 1)
    if hands and len(hands[0]) == 21:
        lm = hands[0]
        rec["hand_px"] = _r(hand_scale(lm, w, h), 1)
        rec["ext"] = {k: _r(v) for k, v in finger_extension(lm, w, h).items()}
        rec["thumb_out"] = _r(thumb_out_ratio(lm, w, h))
        rec["lm"] = [[_r(p[0], 4), _r(p[1], 4), _r(p[2], 4)] for p in lm]
        if world and len(world[0]) == 21:
            bend = finger_bend3d(world[0])
            rec["bend"] = {k: _r(v, 1) for k, v in bend.items()}
            rec["pose3d"] = pose_from_folded({k: v > BEND_FOLDED_DEG for k, v in bend.items()},
                                             thumb_out(lm, w, h))
            rec["wlm"] = [[_r(p[0], 4), _r(p[1], 4), _r(p[2], 4)] for p in world[0]]
    return rec


# ---------------------------------------------------------------- summary

@dataclass
class Segment:
    """A run of frames with one label."""

    label: str
    start: int  # index into the records
    end: int  # exclusive
    tracked_at_start: bool  # the hand was already seen in the frame just before
    first_seen_ms: float | None  # from the segment's start to the first frame with one hand


def _median(xs: list[float]) -> float | None:
    if not xs:
        return None
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def _pct(xs: list[float], q: float) -> float | None:
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def _seen(r: dict[str, Any]) -> bool:
    return r.get("hands") == 1


def segments(recs: list[dict[str, Any]]) -> list[Segment]:
    out: list[Segment] = []
    i = 0
    while i < len(recs):
        lab = recs[i].get("label", "")
        j = i
        while j < len(recs) and recs[j].get("label", "") == lab:
            j += 1
        first = next((k for k in range(i, j) if _seen(recs[k])), None)
        out.append(Segment(label=lab, start=i, end=j, tracked_at_start=i > 0 and _seen(recs[i - 1]),
                           first_seen_ms=None if first is None else (recs[first]["t"] - recs[i]["t"]) * 1000.0))
        i = j
    return out


def lost_runs(recs: list[dict[str, Any]]) -> list[float]:
    """Lengths (ms) of the runs of frames without exactly one hand that follow a seen
    hand (a hand that never showed up is not "lost"). A run ends at the next seen frame
    or at the end of the records; its length is from its first frame to that point."""
    out: list[float] = []
    start: float | None = None
    seen_before = False
    for r in recs:
        if _seen(r):
            if start is not None:
                out.append((r["t"] - start) * 1000.0)
                start = None
            seen_before = True
        elif seen_before and start is None:
            start = r["t"]
    if start is not None and recs:
        out.append((recs[-1]["t"] - start) * 1000.0)
    return out


def pinch_ends(recs: list[dict[str, Any]]) -> Counter[str]:
    """Why each running pinch ended: "shape:<pose>" (the frame was judged a fist /
    thumbs-up / peace sign: the pinch is cut at once), "lost" (no hand for longer than
    the grace) or "opened" (the fingers were opened: the intended release)."""
    out: Counter[str] = Counter()
    for prev, r in zip(recs, recs[1:]):
        if not (prev.get("pinch") and not r.get("pinch")):
            continue
        if not _seen(r):
            out["lost:" + (r.get("reason") or "no_hand")] += 1
        elif r.get("reason") == "outside_roi":  # HandControl resets outside the ROI before it looks at the shape
            out["outside_roi"] += 1
        elif r.get("pose") in CLAW_POSES:
            out["shape:" + r["pose"]] += 1
        else:
            out["opened"] += 1
    return out


@dataclass
class LabelSummary:
    label: str
    frames: int = 0
    seconds: float = 0.0
    seen: int = 0  # frames with exactly one hand
    reasons: Counter[str] = field(default_factory=Counter)
    poses: Counter[str] = field(default_factory=Counter)  # the game's 2D pose, on seen frames
    poses3d: Counter[str] = field(default_factory=Counter)
    lost_ms: list[float] = field(default_factory=list)
    pinch_frames: int = 0
    pinch_end: Counter[str] = field(default_factory=Counter)
    blocking_fingers: Counter[str] = field(default_factory=Counter)  # fingers that kept the expected shape away
    thumb_out_frames: int = 0  # fist: the thumb counted as out (a thumbs-up)
    segments: int = 0
    seg_tracked: list[tuple[bool, float, float | None]] = field(default_factory=list)  # (tracked at start, seen share, first seen ms)
    ext_median: dict[str, float | None] = field(default_factory=dict)
    bend_median: dict[str, float | None] = field(default_factory=dict)
    thumb_out_median: float | None = None
    hand_px_median: float | None = None
    blur_median: float | None = None
    bright_median: float | None = None
    latency_median: float | None = None
    latency_p95: float | None = None
    gaps_over_stale: int = 0

    def to_dict(self) -> dict[str, Any]:
        d = self.__dict__.copy()
        for k in ("reasons", "poses", "poses3d", "pinch_end", "blocking_fingers"):
            d[k] = dict(d[k])
        d["seen_share"] = self.seen / self.frames if self.frames else 0.0
        return d


EXPECTED = {"open": ("open",), "fist": ("fist",), "pinch": ()}


def summarize(recs: list[dict[str, Any]], *, lost_grace_ms: float = 300.0, stale_ms: float = 350.0) -> dict[str, LabelSummary]:
    """Per label (unlabelled frames are left out)."""
    out: dict[str, LabelSummary] = {}
    segs = segments(recs)
    for seg in segs:
        if not seg.label:
            continue
        s = out.setdefault(seg.label, LabelSummary(label=seg.label))
        rs = recs[seg.start:seg.end]
        s.segments += 1
        n_seen = sum(1 for r in rs if _seen(r))
        s.seg_tracked.append((seg.tracked_at_start, n_seen / len(rs), seg.first_seen_ms))
        s.lost_ms.extend(lost_runs(rs))
        s.pinch_end.update(pinch_ends(rs))
    for lab, s in out.items():
        rs = [r for r in recs if r.get("label") == lab]
        s.frames = len(rs)
        s.seconds = sum(r.get("gap_ms", 0.0) for r in rs) / 1000.0
        seen = [r for r in rs if _seen(r)]
        s.seen = len(seen)
        s.reasons.update(r.get("reason") or "ok" for r in rs)
        s.poses.update(r.get("pose") or "?" for r in seen)
        s.poses3d.update(r["pose3d"] for r in seen if "pose3d" in r)
        s.pinch_frames = sum(1 for r in rs if r.get("pinch"))
        for r in seen:
            ext = r.get("ext") or {}
            if lab == "open" and r.get("pose") != "open":
                s.blocking_fingers.update(k for k, v in ext.items() if v < 1.0)
            elif lab == "fist" and r.get("pose") != "fist":
                s.blocking_fingers.update(k for k, v in ext.items() if v >= 1.0)
                if r.get("pose") == "thumb":
                    s.thumb_out_frames += 1
        for k in FINGERS:
            s.ext_median[k] = _median([r["ext"][k] for r in seen if "ext" in r])
            s.bend_median[k] = _median([r["bend"][k] for r in seen if "bend" in r])
        s.thumb_out_median = _median([r["thumb_out"] for r in seen if "thumb_out" in r])
        s.hand_px_median = _median([r["hand_px"] for r in seen if "hand_px" in r])
        s.blur_median = _median([r["blur"] for r in rs if "blur" in r])
        s.bright_median = _median([r["bright"] for r in rs if "bright" in r])
        lat = [r.get("latency_ms", 0.0) for r in rs]
        s.latency_median, s.latency_p95 = _median(lat), _pct(lat, 0.95)
        s.gaps_over_stale = sum(1 for r in rs if r.get("gap_ms", 0.0) > stale_ms)
    return out


def key_metrics(summary: dict[str, LabelSummary], *, lost_grace_ms: float = 300.0) -> dict[str, dict[str, float]]:
    """The few numbers to compare two runs by, per label: `seen` (share of frames with
    one hand), `right` (share of all frames judged as the label: the open / fist pose,
    or pinching), `stops` (losses long enough to stop the stick) and, for a pinch,
    `cut_by_shape` (pinches ended by a fist / thumbs-up / peace frame)."""
    out: dict[str, dict[str, float]] = {}
    for lab, s in summary.items():
        if not s.frames:
            continue
        m = {"seen": s.seen / s.frames,
             "stops": float(sum(1 for x in s.lost_ms if x >= lost_grace_ms))}
        if lab == "pinch":
            m["right"] = s.pinch_frames / s.frames
            m["cut_by_shape"] = float(sum(n for k, n in s.pinch_end.items() if k.startswith("shape:")))
        elif lab in ("open", "fist"):
            m["right"] = s.poses.get(lab, 0) / s.frames
            if s.poses3d:
                m["right3d"] = s.poses3d.get(lab, 0) / s.frames
        out[lab] = m
    return out


def _fmt(v: float | None, nd: int = 2) -> str:
    return "-" if v is None else f"{v:.{nd}f}"


def _share(c: Counter[str], total: int, top: int = 6) -> str:
    if not total:
        return "-"
    return ", ".join(f"{k} {100 * n / total:.0f}%" for k, n in c.most_common(top))


def report(summary: dict[str, LabelSummary], *, lost_grace_ms: float = 300.0, stale_ms: float = 350.0) -> str:
    """A plain Japanese report for the person who recorded."""
    lines: list[str] = []
    order = [k for k in ("pinch", "open", "fist", "none") if k in summary] + \
            sorted(k for k in summary if k not in LABELS)
    for lab in order:
        s = summary[lab]
        name = LABELS.get(lab, lab)
        lines.append(f"■ {name}（{lab}）: {s.frames} フレーム / 約 {s.seconds:.1f} 秒 / 区間 {s.segments}")
        if not s.frames:
            continue
        lines.append(f"  手が 1 つ見えた割合: {100 * s.seen / s.frames:.0f}%   reason: {_share(s.reasons, s.frames)}")
        if lab != "none":
            lines.append(f"  ゲームの形の判定（2D）: {_share(s.poses, s.seen)}")
            if s.poses3d:
                lines.append(f"  参考: 3D の曲がりで判定した形: {_share(s.poses3d, sum(s.poses3d.values()))}")
        if s.lost_ms:
            long = [x for x in s.lost_ms if x >= lost_grace_ms]
            lines.append(f"  見失い: {len(s.lost_ms)} 回（うち {lost_grace_ms:.0f} ms 以上で操作が止まるもの {len(long)} 回、"
                         f"最長 {max(s.lost_ms):.0f} ms）")
        if lab == "pinch":
            lines.append(f"  ピンチ中のフレーム: {100 * s.pinch_frames / s.frames:.0f}%")
            if s.pinch_end:
                lines.append("  ピンチが切れた理由: " + ", ".join(f"{k} {n} 回" for k, n in s.pinch_end.most_common()))
        if lab in ("open", "fist") and s.blocking_fingers:
            what = "「折れている」と判定された指" if lab == "open" else "「伸びている」と判定された指"
            lines.append(f"  {what}（外れたフレームの延べ数）: "
                         + ", ".join(f"{k} {n}" for k, n in s.blocking_fingers.most_common()))
        if lab == "fist":
            if s.thumb_out_frames:
                lines.append(f"  親指が出ている（いいね）と判定: {s.thumb_out_frames} フレーム"
                             f"（親指の比の中央値 {_fmt(s.thumb_out_median)}、しきい値 {THUMB_OUT}）")
            for tracked in (True, False):
                xs = [x for x in s.seg_tracked if x[0] == tracked]
                if xs:
                    firsts = [x[2] for x in xs if x[2] is not None]
                    never = sum(1 for x in xs if x[2] is None)
                    head = "直前から手を追跡していた区間" if tracked else "手が見えていない状態から始めた区間"
                    lines.append(f"  {head}: {len(xs)} 個、手が見えた割合の平均 "
                                 f"{100 * sum(x[1] for x in xs) / len(xs):.0f}%、"
                                 f"最初に見えるまで中央値 {_fmt(_median(firsts), 0)} ms、一度も見えず {never} 個")
        if lab != "none" and any(v is not None for v in s.ext_median.values()):
            lines.append("  指の伸び（先端/第2関節 の距離比、1.0 未満で「折れている」）中央値: "
                         + ", ".join(f"{k} {_fmt(v)}" for k, v in s.ext_median.items()))
        if any(v is not None for v in s.bend_median.values()):
            lines.append(f"  参考: 指の曲がり 3D（度、{BEND_FOLDED_DEG:.0f} 超で「折れている」）中央値: "
                         + ", ".join(f"{k} {_fmt(v, 0)}" for k, v in s.bend_median.items()))
        lines.append(f"  手の大きさ {_fmt(s.hand_px_median, 0)} px、明るさ {_fmt(s.bright_median, 0)}、"
                     f"くっきり度 {_fmt(s.blur_median, 0)}、処理時間 中央値 {_fmt(s.latency_median, 0)} ms / "
                     f"95% {_fmt(s.latency_p95, 0)} ms、{stale_ms:.0f} ms を超えた間隔 {s.gaps_over_stale} 回")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def read_jsonl(lines: Iterable[str]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """(meta, frame records) from a probe file."""
    import json

    meta: dict[str, Any] = {}
    recs: list[dict[str, Any]] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if d.get("type") == "meta":
            meta = d
        else:
            recs.append(d)
    return meta, recs
