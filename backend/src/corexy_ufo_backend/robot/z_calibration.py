"""Z (drum servo ID 1) calibration from two recorded points.

The firmware has no Z homing: Z is the drum servo's multi-turn count relative to a
point recorded by hand. Two points are recorded: the arm wound up to its top
("top", Z = z_max when up is positive) and lowered to its bottom ("bottom",
Z = z_min). Their counts are only comparable within one firmware session (the
multi-turn count restarts after a reboot), but the difference between them is a
property of the machine: it gives the counts per Z unit and which way the drum
turns to raise the arm. That pair is saved, so after a power cycle recording one
of the two points again is enough.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from pathlib import Path

log = logging.getLogger(__name__)

WHICH = ("top", "bottom")
# the two points must be at least this far apart (half a drum turn): closer ones
# are a mistake (e.g. "bottom" pressed without lowering the arm)
MIN_SPAN_COUNTS = 2048


@dataclass
class ZCalibration:
    counts_per_unit: float | None = None
    # +1: drum counts grow as the arm goes up (the config's z_sign convention)
    sign: int | None = None
    span_counts: int | None = None  # top - bottom, as measured

    def complete(self) -> bool:
        return self.counts_per_unit is not None and self.sign is not None

    @classmethod
    def from_points(cls, top_counts: int, bottom_counts: int, z_range: float) -> "ZCalibration":
        span = int(top_counts) - int(bottom_counts)
        if abs(span) < MIN_SPAN_COUNTS:
            raise ValueError(f"top and bottom are only {abs(span)} counts apart (need >= {MIN_SPAN_COUNTS}: "
                             "lower the arm to the bottom before recording it)")
        if z_range <= 0:
            raise ValueError("z range must be positive")
        return cls(counts_per_unit=abs(span) / z_range, sign=1 if span > 0 else -1, span_counts=span)

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def load(cls, path: Path | None) -> "ZCalibration":
        if path is None or not path.exists():
            return cls()
        try:
            d = json.loads(path.read_text(encoding="utf-8"))
            c = cls(counts_per_unit=float(d["counts_per_unit"]), sign=int(d["sign"]),
                    span_counts=int(d["span_counts"]) if d.get("span_counts") is not None else None)
        except (OSError, ValueError, KeyError, TypeError) as e:
            log.warning("ignoring %s: %s", path, e)
            return cls()
        if c.counts_per_unit is None or c.counts_per_unit <= 0 or c.sign not in (1, -1):
            log.warning("ignoring %s: bad values %s", path, d)
            return cls()
        return c

    def save(self, path: Path | None) -> None:
        if path is None:
            return
        path.write_text(json.dumps(self.to_dict(), indent=2) + "\n", encoding="utf-8")
