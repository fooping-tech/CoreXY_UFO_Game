"""Which problem to look at, and where its answer box is in the overview image (#79).

Three kinds:
- "stuck": the problem the child seems stuck on (written halfway, or the first blank
  after the last answered one), judged by comparing the frame at the last progress
  gain with the frame now (one image alone was ambiguous in the #78 trials: the same
  photo of a sheet answered out of order gave different answers).
- "next": the next problem to solve (the first one without an answer after the last
  answered one).
- "problem" (#86): a given problem of a known worksheet (the study mode's HELP looks at
  problem 3, the challenge). The assistant is told which one; Jev is asked with the
  worksheet's own description, and (when the 4 corner marks are found) the box must also
  lie where the worksheet's layout puts it.

The study assistant (Claude Code / Codex) names the problem and gives its answer box in
pixels of the image now (Claude's own pixel coordinates were 0..1.5 px off in the #78
trials). Before the arm moves, Jev is asked for the same answer box (a "box" question,
3..13 px off there): the box is used only when the centre of Claude's box lies inside
Jev's box (widened by `jev_margin`). Nothing here moves the robot.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from typing import Any

from ..jsonpick import last_json_object
from .progress import IMAGE_ASSET

KINDS = ("stuck", "next", "problem")

LOCATE_SYSTEM_PROMPT = (
    "あなたは小学生の宿題プリントの写真を読み取り、問題と解答欄の位置を答えるアシスタントです。"
    "指示された JSON だけを出力します。答えそのものは書きません。")


@dataclass(frozen=True)
class LocateParams:
    timeout_s: float = 120.0
    jev_timeout_s: float = 30.0
    require_jev: bool = True  # move only when Jev agrees (no Jev key: nothing is located)
    jev_margin: float = 0.02  # Jev's box widened by this (0..1 of the image) on every side
    max_box_area: float = 0.25  # an "answer box" larger than this part of the image is not one

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "LocateParams":
        hw = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        d = hw.get("locate") if isinstance(hw.get("locate"), dict) else {}
        return cls(timeout_s=max(float(d.get("timeout_s", 120.0)), 5.0),
                   jev_timeout_s=max(float(d.get("jev_timeout_s", 30.0)), 1.0),
                   require_jev=bool(d.get("require_jev", True)),
                   jev_margin=min(max(float(d.get("jev_margin", 0.02)), 0.0), 0.2),
                   max_box_area=min(max(float(d.get("max_box_area", 0.25)), 0.001), 1.0))


class LocateError(ValueError):
    """The problem or its place could not be told (the arm must not move)."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def jpeg_size(data: bytes) -> tuple[int, int]:
    """(width, height) from a JPEG's SOF header."""
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7 or marker == 0xFF:
            i += 1 if marker == 0xFF else 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], "big")
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC) and i + 9 <= len(data):
            h = int.from_bytes(data[i + 5:i + 7], "big")
            w = int.from_bytes(data[i + 7:i + 9], "big")
            if w > 0 and h > 0:
                return w, h
        if marker == 0xDA or length < 2:
            break
        i += 2 + length
    raise LocateError("image", "画像の大きさを読み取れませんでした")


def locate_prompt(kind: str, width: int, height: int, has_before: bool, target: str = "") -> str:
    if kind not in KINDS:
        raise LocateError("invalid_request", f"unknown kind {kind!r}")
    if kind == "problem" and not target:
        raise LocateError("invalid_request", "kind problem needs the problem (target)")
    parts = []
    if has_before:
        parts.append("算数の宿題プリントを机の上から撮った写真が 2 枚あります。1 枚目は最後に答えが増えたときの写真、"
                     f"2 枚目は今の写真（{width}×{height} ピクセル）です。")
    else:
        parts.append(f"算数の宿題プリントを机の上から撮った今の写真です（{width}×{height} ピクセル）。")
    if kind == "stuck":
        parts.append("子どもの手が止まっている問題を 1 つ選んでください。途中まで書いてある問題があればそれ、"
                     "なければ、最後に答えが書かれた問題の次の、答えがまだない問題です。")
        if has_before:
            parts.append("1 枚目から書き足された所があれば、その問題を優先してください。")
    elif kind == "problem":
        parts.append(f"次の問題を探してください: {target}")
    else:
        parts.append("次に解く問題を 1 つ選んでください。最後に答えが書かれた問題の次の、答えがまだない問題です"
                     "（途中まで書いてある問題があればそれ）。")
    parts.append(
        "\nその問題の「解答欄」（答えを書く枠。文章題は答えを書く所）の位置を、今の写真の左上を原点とする"
        "ピクセル座標で答えてください。名前・日付・おうちの人の欄は数えません。"
        "\n出力は次の JSON だけ:"
        '\n{"found": true, "problem": "大問2の(3) 4×12（日本語、子どもに読み上げる短い名前）", '
        '"description_en": "problem (3) \\"4 × 12 =\\" in section 2（英語で、その問題を特定できる説明）", '
        '"box": [left, top, right, bottom]}'
        '\n決められないとき（プリントが見えない、全部解き終わっている など）は {"found": false, "reason": "理由"}')
    return "".join(parts)


def parse_answer(text: str, width: int, height: int, max_box_area: float = 0.25) -> dict[str, Any]:
    """Claude's JSON -> {problem, description_en, box: (l, t, r, b) in 0..1}. LocateError when unusable."""
    found = last_json_object(text)
    if not isinstance(found, dict):
        raise LocateError("parse", "アシスタントの答えから位置を読み取れませんでした")
    if not found.get("found", False):
        raise LocateError("not_found", "問題を決められませんでした: " + str(found.get("reason", "理由なし")))
    box = found.get("box")
    try:
        l, t, r, b = (float(v) for v in box)  # type: ignore[union-attr]
    except (TypeError, ValueError):
        raise LocateError("parse", "解答欄の位置が 4 つの数ではありません") from None
    if not all(math.isfinite(v) for v in (l, t, r, b)):
        raise LocateError("parse", "解答欄の位置が数ではありません")
    l, r = sorted((l, r))
    t, b = sorted((t, b))
    slack_x, slack_y = 0.02 * width, 0.02 * height
    if l < -slack_x or t < -slack_y or r > width + slack_x or b > height + slack_y:
        raise LocateError("out_of_image", "解答欄の位置が画像の外です")
    if r - l < 1 or b - t < 1:
        raise LocateError("parse", "解答欄の大きさがありません")
    box01 = (max(l / width, 0.0), max(t / height, 0.0), min(r / width, 1.0), min(b / height, 1.0))
    if (box01[2] - box01[0]) * (box01[3] - box01[1]) > max_box_area:
        raise LocateError("parse", "解答欄として大きすぎます（プリント全体を指している）")
    problem = str(found.get("problem", "")).strip()[:60]
    description = str(found.get("description_en", "")).strip()[:200]
    if not description:
        description = problem or "the problem"
    return {"problem": problem, "description_en": description, "box": box01}


MARK_TEXT = {"tl": "top-left", "tr": "top-right", "bl": "bottom-left", "br": "bottom-right"}


def jev_box_input(jpeg_base64: str, description_en: str, marks: bool = False) -> dict:
    """The answer box question; with marks, also the worksheet's 4 black corner squares (#86)."""
    questions: dict = {"box": {"type": "box", "instructions": (
        "Find the answer box (the rectangle where the handwritten answer goes) for "
        f"{description_en} of the math worksheet in `{IMAGE_ASSET}`.")}}
    if marks:
        for key, text in MARK_TEXT.items():
            questions[f"mark_{key}"] = {"type": "box", "instructions": (
                f"Find the solid black square printed in the {text} corner of the worksheet in `{IMAGE_ASSET}`.")}
    return {
        "state": {IMAGE_ASSET: IMAGE_ASSET},  # without it: HTTP 400, code 7003
        "assets": {IMAGE_ASSET: {"type": "image", "format": "jpeg", "data_base64": jpeg_base64}},
        "questions": questions,
    }


def jev_marks(output: dict) -> dict[str, tuple[float, float]]:
    """Centres (0..1) of the corner marks Jev found (only those it found)."""
    out = {}
    for key in MARK_TEXT:
        found = jev_box({"answers": {"box": (output.get("answers") or {}).get(f"mark_{key}")}})
        if found is not None:
            out[key] = centre(found[0])
    return out


def jev_box(output: dict) -> tuple[tuple[float, float, float, float], float | None] | None:
    """Jev's answer box (0..1, l < r, t < b) and confidence; None without one."""
    a = (output.get("answers") or {}).get("box") or {}
    if not isinstance(a, dict):
        return None
    box = a.get("box")
    if not isinstance(box, dict):
        return None
    try:
        l, r = sorted((float(box["left"]), float(box["right"])))
        t, b = sorted((float(box["top"]), float(box["bottom"])))
    except (KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(v) for v in (l, t, r, b)):
        return None
    conf = a.get("confidence")
    return (l, t, r, b), float(conf) if isinstance(conf, (int, float)) else None


def centre(box: tuple[float, float, float, float]) -> tuple[float, float]:
    return (box[0] + box[2]) / 2, (box[1] + box[3]) / 2


def agrees(claude_box: tuple[float, float, float, float], jev: tuple[float, float, float, float],
           margin: float) -> bool:
    """Claude's centre inside Jev's box widened by margin."""
    cx, cy = centre(claude_box)
    return jev[0] - margin <= cx <= jev[2] + margin and jev[1] - margin <= cy <= jev[3] + margin
