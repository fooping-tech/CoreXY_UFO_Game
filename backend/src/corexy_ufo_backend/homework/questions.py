"""Per-problem answers on a known worksheet (#86), in the same Jev call as the progress.

The watch's Jev call (progress.py: visible / occluded / progress score) gets one more
"noul" question per problem of the study mode's worksheet: is there a handwritten answer
in that problem's answer box? The probabilities go to the game, which keeps each
problem's state (empty / writing / filled / held) and needs several readings in a row
before it counts a problem as filled. A reading is only about the paper: it never says
whether the answer is right.
"""

from __future__ import annotations

from typing import Any

from .progress import IMAGE_ASSET


def question_key(number: int) -> str:
    return f"answer_{number}"


def add_questions(jev_input: dict, worksheet: dict) -> dict:
    """jev_input with one question per problem of `worksheet` (same image, same call)."""
    questions = dict(jev_input.get("questions") or {})
    for p in worksheet.get("problems", []):
        desc = str(p.get("description_en") or f"problem {p.get('number')}")
        area = ("the area of" if p.get("figure") is not None and p.get("answer_box_mm", [0])[0] < 30
                else "the answer box of")
        questions[question_key(int(p["number"]))] = {"type": "noul", "instructions": (
            f"Is there a handwritten answer (pencil marks written by a child) in {area} {desc} "
            f"of the worksheet in `{IMAGE_ASSET}`? Printed text does not count.")}
    return {**jev_input, "questions": questions}


def parse_questions(output: dict, worksheet: dict) -> list[dict[str, Any]]:
    """[{number, filled_prob (None when not answered)}] in problem order."""
    answers = output.get("answers") or {}
    out = []
    for p in worksheet.get("problems", []):
        n = int(p["number"])
        a = answers.get(question_key(n)) or {}
        v = a.get("noul") if a.get("type") == "noul" else None
        out.append({"number": n, "filled_prob": float(v) if isinstance(v, (int, float)) else None})
    return out
