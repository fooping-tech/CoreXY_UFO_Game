"""Claw (servo ID 2) open / closed positions.

Stored as the angle within the servo's turn (0..360: the servo reports it after a
power cycle too, while the firmware's multi-turn count restarts from it) plus the
signed travel from closed to open. The sign is the direction the claw opens, so a
move between the two never goes round the other way into the claw's stop.
"""

from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

COUNTS_PER_TURN = 4096
WHICH = ("closed", "open")


def deg_in_turn(counts: int) -> float:
    return (counts % COUNTS_PER_TURN) * 360.0 / COUNTS_PER_TURN


@dataclass
class ClawCalibration:
    closed_deg: float | None = None
    open_deg: float | None = None
    span_deg: float | None = None  # closed -> open, signed; None until both are known

    def complete(self) -> bool:
        return self.closed_deg is not None and self.open_deg is not None and bool(self.span_deg)

    def get(self, which: str) -> float | None:
        return self.closed_deg if which == "closed" else self.open_deg

    def mark(self, which: str, deg: float, session_counts: dict[str, int], counts: int) -> None:
        """Record the claw's angle in its turn as `which`.

        The span comes from this session's multi-turn counts when the other end was
        also marked now (exact, direction included); otherwise the old direction is
        kept, and with none known the shorter way round is assumed."""
        if which not in WHICH:
            raise ValueError(f"which must be one of {WHICH}")
        other = "open" if which == "closed" else "closed"
        if which == "closed":
            self.closed_deg = deg
        else:
            self.open_deg = deg
        session_counts[which] = counts
        if other in session_counts:
            c, o = session_counts["closed"], session_counts["open"]
            self.span_deg = (o - c) * 360.0 / COUNTS_PER_TURN
        elif self.closed_deg is not None and self.open_deg is not None:
            diff = self.open_deg - self.closed_deg
            if self.span_deg:
                sgn = math.copysign(1.0, self.span_deg)
                self.span_deg = sgn * ((diff * sgn) % 360.0)
            else:
                self.span_deg = ((diff + 180.0) % 360.0) - 180.0
        if self.span_deg is not None and not 0.0 < abs(self.span_deg) < 360.0:
            self.span_deg = None  # same place, or more than a turn: not a usable range

    def delta_to(self, which: str, cur_deg: float) -> float:
        """Degrees to turn (signed, SERVO_TURN direction) from `cur_deg` (angle in the
        turn) to `which`, staying on the closed..open arc. A claw a little outside the
        arc comes back in over the nearer end."""
        assert self.complete()
        span = float(self.span_deg)  # type: ignore[arg-type]
        sgn = 1.0 if span > 0 else -1.0
        length = abs(span)
        d = ((cur_deg - float(self.closed_deg)) * sgn) % 360.0  # type: ignore[arg-type]
        u = d if d <= length or d - length <= 360.0 - d else d - 360.0
        target = 0.0 if which == "closed" else length
        return (target - u) * sgn

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def load(cls, path: Path | None) -> "ClawCalibration":
        if path is None or not path.exists():
            return cls()
        d = json.loads(path.read_text(encoding="utf-8"))
        f = lambda k: float(d[k]) if d.get(k) is not None else None  # noqa: E731
        return cls(closed_deg=f("closed_deg"), open_deg=f("open_deg"), span_deg=f("span_deg"))

    def save(self, path: Path | None) -> None:
        if path is None:
            return
        path.write_text(json.dumps(self.to_dict(), indent=2) + "\n", encoding="utf-8")
