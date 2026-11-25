"""The study mode's watch and locate with the learning support AI's worksheet reader (#232).

With `study.ai: local` (the default) the study mode sends nothing to the cloud: the overview
frame goes to POST /v1/sheet (study/sheet_client.py) on the local LLM server instead of Jev and
Claude / Codex, and this turns its answer into what the game already reads:

- the watch: per problem of the worksheet, `filled_prob` as Jev's question gave it (questions.py),
  from the answer's state: written (correct / incorrect) = filled, partial = writing, blank =
  empty, unreadable or cut off = no reading. Like Jev's, a reading never says whether the answer
  is right (`answers` carries only the state and what was read, never the right answer).
- the locate: the centre of the problem's answer box (else of the problem's box) as u, v
  (0..1 of the image sent), as the Claude + Jev locate gave it.

The image may have been cut out and turned upright by the game first (the プリント tab's
settings): u, v are in that image, and the game puts them back on the whole frame.
"""

from __future__ import annotations

from typing import Any

from .progress import Reading

# filled_prob per answer state (the game: >= its filled_prob (0.6) counts as written)
FILLED_PROB = {"correct": 0.95, "incorrect": 0.95, "partial": 0.5, "blank": 0.05}


def worksheet_numbers(worksheet: dict | None, problems: list[dict] | None = None) -> list[int]:
    """The problems a reading is about: the known worksheet's, or (worksheet None: a real print,
    #237) every problem the reader saw on it, whatever their number and count."""
    if worksheet is not None:
        return [int(p["number"]) for p in worksheet.get("problems", [])]
    return sorted({int(p["number"]) for p in problems or [] if isinstance(p.get("number"), int) and p["number"] > 0})


def questions_from_sheet(problems: list[dict], worksheet: dict | None) -> list[dict[str, Any]]:
    """[{number, filled_prob (None when not read)}] in the worksheet's problem order."""
    by_number = {int(p["number"]): p for p in problems if isinstance(p.get("number"), int)}
    out = []
    for n in worksheet_numbers(worksheet, problems):
        p = by_number.get(n)
        prob = None
        if p is not None and p.get("visible", "full") != "partial":
            prob = FILLED_PROB.get(str(p.get("answer_status", "")))
        out.append({"number": n, "filled_prob": prob})
    return out


def answers_from_sheet(problems: list[dict], worksheet: dict | None) -> list[dict[str, Any]]:
    """What was read per problem of the worksheet: the state, the child's answer and whether the
    problem was cut off (the answer check never grades a cut-off problem: review on #241), and
    where the problem and its answer box are (0..1000 of the image read: #306, the answer check
    right after the print is found draws its ○ from this reading). Never the right answer."""
    wanted = set(worksheet_numbers(worksheet, problems))
    return [{"number": int(p["number"]), "answer_status": str(p.get("answer_status", "")),
             "student_answer": str(p.get("student_answer", "")), "visible": str(p.get("visible", "full")),
             "box": p.get("box"), "answer_box": p.get("answer_box")}
            for p in problems if isinstance(p.get("number"), int) and p["number"] in wanted]


def reading_from_sheet(problems: list[dict], worksheet: dict | None) -> Reading:
    """The progress: the share of the worksheet's problems read as written. Held (the shown
    value stays) when nothing was read: an empty sheet answer means "could not read"."""
    qs = questions_from_sheet(problems, worksheet)
    known = [q["filled_prob"] for q in qs if q["filled_prob"] is not None]
    if not problems:
        reason = "not_visible"
    elif not known:
        reason = "no_answer"
    else:
        reason = ""
    pct = None
    if known and qs:
        pct = 100.0 * sum(1 for v in known if v >= 0.9) / len(qs)
    return Reading(visible_prob=1.0 if problems else 0.0, occluded_prob=None, top_level_prob=None,
                   progress_ev_pct=pct, progress_pct=pct, held=reason != "", held_reason=reason)


def locate_in_sheet(problems: list[dict], number: int) -> dict[str, Any] | None:
    """{box (0..1, the answer box or else the problem's box), u, v, which} or None when the sheet
    does not show problem `number` (or shows it without a box)."""
    for p in problems:
        if p.get("number") != number:
            continue
        for which in ("answer_box", "box"):
            b = p.get(which)
            if isinstance(b, (list, tuple)) and len(b) == 4 and all(isinstance(v, (int, float)) for v in b):
                l, r = sorted((b[0] / 1000.0, b[2] / 1000.0))
                t, bt = sorted((b[1] / 1000.0, b[3] / 1000.0))
                box = (max(l, 0.0), max(t, 0.0), min(r, 1.0), min(bt, 1.0))
                if box[2] - box[0] <= 0 or box[3] - box[1] <= 0:
                    continue
                return {"box": [round(v, 4) for v in box], "u": round((box[0] + box[2]) / 2, 4),
                        "v": round((box[1] + box[3]) / 2, 4), "which": which,
                        "partial": p.get("visible") == "partial"}
        return None
    return None
