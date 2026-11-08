"""How far a math worksheet is answered, from one Jev call (3 questions).

Ported unchanged from ~/python_ws/jev/homework_progress.py and its docs
(docs/homework_progress.md, 2026-11-09). Measured there on one 13-problem
worksheet, 30 frames from the C270: mean error 3 points without a hand in view,
100% found on 11 of 14 finished frames (never on an unfinished one), all 9
frames with a hand over the answers held. The thresholds fit that data: check
them again on other worksheets.
"""

from __future__ import annotations

import statistics
from collections import deque
from dataclasses import dataclass, field
from typing import Any

IMAGE_ASSET = "photo"
LEVELS = list(range(0, 101, 20))  # score criteria: at most 10 (11 -> HTTP 400 too_long)
_LEVEL_TEXT = {
    0: "no answers are written on the math worksheet",
    50: "about half of the problems have handwritten answers",
    100: "every problem on the worksheet has a handwritten answer",
}
CRITERIA = [f"{p}%: " + _LEVEL_TEXT.get(p, f"about {p}% of the problems have handwritten answers")
            for p in LEVELS]
VISIBLE_Q = "Is a math homework worksheet clearly visible in `photo`?"
_EXCLUDE = ("Only count the answer boxes for the math problems. Ignore the name, date, "
            "and parent comment fields.")
PROGRESS_Q = ("How much of the math homework worksheet in `photo` has been answered, "
              "judging by handwritten answers filled in? " + _EXCLUDE)
OCCLUDED_Q = ("Is a hand, arm, or pen covering any of the answer boxes on the worksheet "
              "in `photo`?")
VISIBLE_THRESHOLD = 0.5
# P(100% level): finished 0.55..0.71 (a sheet moved half out of view 0.26..0.31), unfinished <= 0.16
TOP_LEVEL_THRESHOLD = 0.5
# occluded: hand 0.37..0.91, no hand 0.10..0.26
OCCLUDED_THRESHOLD = 0.35
SMOOTH_WINDOW = 3


def build_input(jpeg_base64: str) -> dict:
    return {
        "state": {IMAGE_ASSET: IMAGE_ASSET},
        "assets": {IMAGE_ASSET: {"type": "image", "format": "jpeg", "data_base64": jpeg_base64}},
        "questions": {
            "visible": {"type": "noul", "instructions": VISIBLE_Q},
            "occluded": {"type": "noul", "instructions": OCCLUDED_Q},
            "progress": {"type": "score", "instructions": PROGRESS_Q, "criteria": CRITERIA},
        },
    }


def score_to_pct(answer: dict) -> float | None:
    """Expected progress % from the level probabilities ("0".."5" = LEVELS index)."""
    probs = answer.get("probabilities") or {}
    total = weighted = 0.0
    for k, p in probs.items():
        if not (isinstance(k, str) and k.isdigit()) or int(k) >= len(LEVELS) or p is None:
            return None  # an unexpected shape: no guess
        total += p
        weighted += p * LEVELS[int(k)]
    return weighted / total if total > 0 else None


def _noul(answers: dict, key: str) -> float | None:
    a = answers.get(key) or {}
    return a.get("noul") if a.get("type") == "noul" else None


@dataclass
class Reading:
    """One Jev answer turned into progress. `held`: do not update the shown value."""
    visible_prob: float | None
    occluded_prob: float | None
    top_level_prob: float | None
    progress_ev_pct: float | None
    progress_pct: float | None
    held: bool
    held_reason: str  # "" | "not_visible" | "occluded" | "no_answer"
    confidence: float | None = None
    probabilities: dict | None = None


def parse(output: dict) -> Reading:
    """100% when P(100% level) >= TOP_LEVEL_THRESHOLD, else the expected value (the expected
    value alone stops at 85..90% on a finished sheet, measured)."""
    answers = output.get("answers") or {}
    prog = answers.get("progress") or {}
    is_score = prog.get("type") == "score"
    visible, occluded = _noul(answers, "visible"), _noul(answers, "occluded")
    ev = score_to_pct(prog) if is_score else None
    top = (prog.get("probabilities") or {}).get(str(len(LEVELS) - 1)) if is_score else None
    pct = 100.0 if top is not None and top >= TOP_LEVEL_THRESHOLD else ev
    if visible is None or visible < VISIBLE_THRESHOLD:
        reason = "not_visible"
    elif occluded is not None and occluded >= OCCLUDED_THRESHOLD:
        reason = "occluded"
    elif pct is None:
        reason = "no_answer"
    else:
        reason = ""
    return Reading(visible_prob=visible, occluded_prob=occluded, top_level_prob=top,
                   progress_ev_pct=ev, progress_pct=pct, held=reason != "", held_reason=reason,
                   confidence=prog.get("confidence") if is_score else None,
                   probabilities=prog.get("probabilities") if is_score else None)


STALL_S = 180.0  # no gain of STALL_MIN_GAIN points for this long = stalled
STALL_MIN_GAIN = 5.0


@dataclass
class ProgressTracker:
    """The shown value: median of the last SMOOTH_WINDOW updated readings (held ones skipped).
    Not forced to grow (an answer can be erased). `history` keeps every reading.

    Stall: the shown value has not grown by stall_min_gain points for stall_s (time
    since the last such gain, or since the start / the last advice). Not at 100%,
    and not while the last reading was held because a hand covers the answers
    (the child is likely writing)."""
    stall_s: float = STALL_S
    stall_min_gain: float = STALL_MIN_GAIN
    window: deque = field(default_factory=lambda: deque(maxlen=SMOOTH_WINDOW))
    history: list[dict[str, Any]] = field(default_factory=list)
    _base_t: float = 0.0
    _base_pct: float | None = None
    _last_reason: str = ""

    @property
    def smoothed_pct(self) -> float | None:
        return statistics.median(self.window) if self.window else None

    def add(self, elapsed_s: float, reading: Reading) -> float | None:
        if not reading.held and reading.progress_pct is not None:
            self.window.append(reading.progress_pct)
        smoothed = self.smoothed_pct
        self._last_reason = reading.held_reason
        if smoothed is not None:
            if self._base_pct is None:
                self._base_pct = smoothed  # the clock runs from the start (_base_t = 0)
            elif smoothed >= self._base_pct + self.stall_min_gain:
                self._base_t, self._base_pct = elapsed_s, smoothed  # progress: restart the clock
            elif smoothed < self._base_pct:
                self._base_pct = smoothed  # erased: compare later gains from here, keep the clock
        self.history.append({"elapsed_s": round(elapsed_s, 1), "progress_pct": reading.progress_pct,
                             "smoothed_pct": smoothed, "held": reading.held_reason})
        return smoothed

    def stalled_for(self, elapsed_s: float) -> float:
        """Seconds without progress (0 when not counted: no value yet, 100%, a hand over the sheet)."""
        smoothed = self.smoothed_pct
        if smoothed is None or smoothed >= 100.0 or self._last_reason == "occluded":
            return 0.0
        return max(elapsed_s - self._base_t, 0.0)

    def stalled(self, elapsed_s: float) -> bool:
        return self.stalled_for(elapsed_s) >= self.stall_s

    def reset_stall(self, elapsed_s: float) -> None:
        """After an advice: wait stall_s again before the next one."""
        self._base_t = elapsed_s
        if self.smoothed_pct is not None:
            self._base_pct = self.smoothed_pct
