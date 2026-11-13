"""The HELP explanation: overview + the 3 close-ups -> Claude Code / Codex -> structured JSON.

One question with every image (the adapters' more_images), so one call costs one turn.
The assistant reads the problem, gives a hint and a step-by-step explanation for the
child's grade, and says what it could not read instead of guessing. For a known sample
worksheet the recognised problem is compared with the worksheet's own text: a mismatch
asks for confirmation (needs_confirmation) rather than trusting either side.
"""

from __future__ import annotations

import math
import re
import unicodedata
from typing import Any

from ..jsonpick import last_json_object

EXPLAIN_SYSTEM_PROMPT = (
    "あなたは子どもの宿題を手伝う、やさしい UFO のキャラクター「UFOくん」です。画像から問題を読み取り、"
    "子どもが自分で考えられるように、ヒントと考え方を短い日本語で伝えます。答えそのものは最後まで言いません。"
    "読み取れない部分は推測せず、読めなかったと書きます。指示された JSON だけを出力します。")

FIELDS = ("problem_number", "recognized_problem", "confidence", "hint", "explanation", "speech_text",
          "needs_confirmation")


class ExplainError(ValueError):
    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def explain_prompt(problem_number: int, grade_label: str, roles: list[str], known: dict | None) -> str:
    """roles: what each image is, in the order sent (e.g. overview, 10cm, 5cm, landing)."""
    names = {"overview": "机の上から撮ったプリント全体", "10cm": "アームのカメラで 10cm 上から",
             "5cm": "アームのカメラで 5cm 上から", "landing": "アームのカメラでいちばん近くから"}
    parts = [f"{grade_label or '子ども'}の宿題プリントの写真が {len(roles)} 枚あります（順に: "
             + "、".join(names.get(r, r) for r in roles) + "）。",
             f"子どもは問題 {problem_number} で困っています。"]
    if known:
        parts.append(f"このプリントの問題 {problem_number} は「{known.get('prompt', '')}」のはずです。"
                     "写真と違っていたら、写真を優先して needs_confirmation を true にしてください。")
    parts.append(
        "\n1. 問題文を読み取ってください（読めない所は「読めない」と書く）。"
        "\n2. その学年に合わせて、子どもが自分で考えられるヒントを 1 つ。"
        "\n3. 解き方を段階的に（答えの数そのものは書かない）。"
        "\n4. speech_text は UFOくんが話す言葉（です・ます調でなく、やさしい話し言葉、80 文字以内）。"
        "\n出力は次の JSON だけ:"
        '\n{"problem_number": 3, "recognized_problem": "読み取った問題文", "confidence": 0.0〜1.0, '
        '"hint": "ヒント", "explanation": "段階的な説明", "speech_text": "話す言葉", "needs_confirmation": false}')
    return "".join(parts)


def parse_explanation(text: str, problem_number: int) -> dict[str, Any]:
    found = last_json_object(text)
    if not isinstance(found, dict):
        raise ExplainError("parse", "解説の JSON を読み取れませんでした")
    out: dict[str, Any] = {}
    try:
        out["problem_number"] = int(found.get("problem_number", problem_number))
    except (TypeError, ValueError):
        out["problem_number"] = problem_number
    for key in ("recognized_problem", "hint", "explanation", "speech_text"):
        out[key] = str(found.get(key, "") or "").strip()[:600]
    try:
        conf = float(found.get("confidence", 0.0))
    except (TypeError, ValueError):
        conf = 0.0
    out["confidence"] = min(max(conf, 0.0), 1.0) if math.isfinite(conf) else 0.0
    out["needs_confirmation"] = bool(found.get("needs_confirmation", False))
    if not out["hint"] and not out["explanation"]:
        raise ExplainError("empty", "解説が空でした")
    if not out["speech_text"]:
        out["speech_text"] = out["hint"] or out["explanation"]
    if out["problem_number"] != problem_number or out["confidence"] < 0.5:
        out["needs_confirmation"] = True
    return out


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"[\s、。，．,.!?！？「」()（）]", "", s)


def similarity(a: str, b: str) -> float:
    """Character bigram overlap (Dice), 0..1: enough to tell the same short problem from another."""
    a, b = _norm(a), _norm(b)
    if not a or not b:
        return 0.0
    if len(a) < 2 or len(b) < 2:
        return 1.0 if a == b else 0.0
    ga = {a[i:i + 2] for i in range(len(a) - 1)}
    gb = {b[i:i + 2] for i in range(len(b) - 1)}
    return 2 * len(ga & gb) / (len(ga) + len(gb))


def compare_with_known(result: dict[str, Any], known_prompt: str, threshold: float = 0.35) -> dict[str, Any]:
    """Adds matches_worksheet / similarity; a mismatch needs a grown-up's confirmation."""
    out = dict(result)
    sim = similarity(out.get("recognized_problem", ""), known_prompt)
    out["similarity"] = round(sim, 3)
    out["matches_worksheet"] = sim >= threshold
    if not out["matches_worksheet"]:
        out["needs_confirmation"] = True
    return out


def fallback_explanation(problem: dict, problem_number: int, reason: str = "") -> dict[str, Any]:
    """The worksheet's own hints when the assistant is not available (mock demo / failure)."""
    hints = list(problem.get("hints") or [])
    steps = "".join(f"{i + 1}. {h}\n" for i, h in enumerate(hints))
    return {"problem_number": problem_number, "recognized_problem": problem.get("prompt", ""), "confidence": 1.0,
            "hint": hints[0] if hints else "", "explanation": steps.strip(),
            "speech_text": "。".join(h.rstrip("。") for h in hints[:3]) + "。" if hints else "",
            "needs_confirmation": False, "matches_worksheet": True, "similarity": 1.0,
            "source": "worksheet", "reason": reason}


def split_speech(text: str, max_chars: int = 40) -> list[str]:
    """Short lines for the speech bubble and the voice (split at 。！？ and then by length)."""
    text = " ".join(str(text).split())
    out: list[str] = []
    for sentence in re.findall(r"[^。！？!?\n]+[。！？!?]*", text):
        sentence = sentence.strip()
        while len(sentence) > max_chars:
            cut = max(sentence.rfind("、", 0, max_chars), sentence.rfind(" ", 0, max_chars))
            cut = cut + 1 if cut > max_chars // 3 else max_chars
            out.append(sentence[:cut].strip())
            sentence = sentence[cut:].strip()
        if sentence:
            out.append(sentence)
    return out
