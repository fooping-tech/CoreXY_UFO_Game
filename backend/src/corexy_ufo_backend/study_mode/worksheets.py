"""The study mode's sample worksheets (config/worksheets.json, made by tools/build_worksheets.py).

Every worksheet has exactly 3 problems (1, 2 easy; 3 the challenge = the HELP target),
regions in millimetres on the A4 page and 4 corner marks. `paper_to_image` fits the
page -> image homography from the marks found in an overview image (0..1 coordinates),
so a problem's region on paper can be checked against where Claude / Jev found it.
Pure data and maths: nothing here moves the robot.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from ..config import REPO_ROOT
from ..homework.camera_map import apply, fit_homography

DEFAULT_PATH = REPO_ROOT / "config" / "worksheets.json"
MARKS = ("tl", "tr", "bl", "br")
GRADE_COUNT = 12


class WorksheetError(ValueError):
    pass


@dataclass(frozen=True)
class WorksheetCatalog:
    data: dict

    @classmethod
    def load(cls, path: Path | None = None) -> "WorksheetCatalog":
        path = path or DEFAULT_PATH
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            raise WorksheetError(f"worksheets: cannot read {path}: {e}") from e
        cat = cls(data)
        errs = cat.problems()
        if errs:
            raise WorksheetError("worksheets: " + "; ".join(errs))
        return cat

    # ---------------------------------------------------------------- checks
    def problems(self) -> list[str]:
        """What is wrong with the data ([] = usable)."""
        d = self.data
        errs: list[str] = []
        paper = d.get("paper_mm") or [0, 0]
        pw, ph = float(paper[0]), float(paper[1])
        marks = d.get("fiducials") or {}
        if sorted(marks) != sorted(MARKS):
            errs.append(f"fiducials must be {MARKS}")
        grades = [g.get("id") for g in d.get("grades", [])]
        if len(grades) != GRADE_COUNT or len(set(grades)) != GRADE_COUNT:
            errs.append(f"{GRADE_COUNT} distinct grades expected, got {len(set(grades))}")
        seen = set()
        for ws in d.get("worksheets", []):
            wid = ws.get("worksheet_id", "?")
            seen.add(ws.get("grade"))
            probs = ws.get("problems", [])
            if [p.get("number") for p in probs] != [1, 2, 3]:
                errs.append(f"{wid}: problems must be numbered 1, 2, 3")
                continue
            if ws.get("help_problem") != 3 or probs[2].get("difficulty") != "challenge":
                errs.append(f"{wid}: problem 3 must be the challenge and the HELP target")
            if any(p.get("difficulty") != "easy" for p in probs[:2]):
                errs.append(f"{wid}: problems 1 and 2 must be easy")
            for p in probs:
                if not p.get("prompt") or not p.get("answer") or len(p.get("hints") or []) < 2:
                    errs.append(f"{wid} #{p['number']}: prompt, answer and hints are needed")
                for key in ("region_mm", "answer_box_mm"):
                    b = p.get(key) or []
                    if len(b) != 4 or not (0 <= b[0] < b[2] <= pw and 0 <= b[1] < b[3] <= ph):
                        errs.append(f"{wid} #{p['number']}: {key} outside the page")
        missing = set(grades) - seen
        if missing:
            errs.append(f"no worksheet for {sorted(missing)}")
        return errs

    # ---------------------------------------------------------------- lookups
    @property
    def grades(self) -> list[dict]:
        return list(self.data.get("grades", []))

    def get(self, worksheet_id: str) -> dict:
        for ws in self.data.get("worksheets", []):
            if ws.get("worksheet_id") == worksheet_id:
                return ws
        raise WorksheetError(f"unknown worksheet {worksheet_id!r}")

    def for_grade(self, grade: str) -> dict:
        for ws in self.data.get("worksheets", []):
            if ws.get("grade") == grade:
                return ws
        raise WorksheetError(f"no worksheet for grade {grade!r}")

    @staticmethod
    def problem(ws: dict, number: int) -> dict:
        for p in ws.get("problems", []):
            if p.get("number") == number:
                return p
        raise WorksheetError(f"{ws.get('worksheet_id')}: no problem {number}")

    def mark_centres(self) -> dict[str, tuple[float, float]]:
        return {k: (float(v["center_mm"][0]), float(v["center_mm"][1])) for k, v in self.data["fiducials"].items()}


# ---------------------------------------------------------------- page <-> image
def paper_to_image(catalog: WorksheetCatalog, marks_uv: dict[str, tuple[float, float]]) -> np.ndarray:
    """Homography page mm -> image (u, v) from the 4 corner marks' centres in the image."""
    if sorted(marks_uv) != sorted(MARKS):
        raise WorksheetError("all 4 corner marks are needed")
    centres = catalog.mark_centres()
    src = np.array([centres[k] for k in MARKS])
    dst = np.array([marks_uv[k] for k in MARKS], dtype=float)
    if not np.all(np.isfinite(dst)):
        raise WorksheetError("a corner mark is not a number")
    h, condition = fit_homography(src, dst)
    if condition < 1e-6:
        raise WorksheetError("the corner marks do not fix the page (on one line?)")
    return h


def box_in_image(h: np.ndarray, box_mm: list[float]) -> tuple[float, float, float, float]:
    """The image box (l, t, r, b) around a page box's 4 corners."""
    x0, y0, x1, y1 = box_mm
    pts = [apply(h, x, y) for x, y in ((x0, y0), (x1, y0), (x0, y1), (x1, y1))]
    us, vs = [p[0] for p in pts], [p[1] for p in pts]
    return min(us), min(vs), max(us), max(vs)


def point_inside(box: tuple[float, float, float, float], u: float, v: float, margin: float = 0.0) -> bool:
    return math.isfinite(u) and math.isfinite(v) and \
        box[0] - margin <= u <= box[2] + margin and box[1] - margin <= v <= box[3] + margin


def known_problem_for_prompt(ws: dict, number: int) -> dict[str, Any]:
    """What the explanation prompt may say about a known problem (never the answer)."""
    p = WorksheetCatalog.problem(ws, number)
    return {"number": number, "prompt": p["prompt"], "difficulty": p["difficulty"], "grade_label": ws.get("grade_label", "")}
