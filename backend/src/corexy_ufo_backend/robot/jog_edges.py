"""#185 / #339: a jog's XY speed kept so that the carriage stops before the stage's edges.

The home corner's limit switches (X=0 and Y=0, homing towards -X / -Y) are pressed within
about 1 mm of 0. A jog that presses one ends there (`JOG end reason=limit_x|limit_y`) and the
older firmware raises `ALARM: hard limit active away from home`. So a jog stays
`margin_min` (default 15 mm) inside X=0 / Y=0 and `margin_max` (5 mm) inside the far soft
limits, where there is no switch.

Why a prediction (#339, the machine on 2026-11-26): the position the backend has is late.
`JOG_POS` comes every 50 ms, the serial line and the parsing add their part, and the JOG the
backend writes reaches the motors later still; from the log, the carriage was 0.13-0.21 s
ahead of the position a JOG was decided on. The game refreshes the JOG at about 20 Hz (gaps
of up to 0.14 s seen), so a speed also lasts until the next one. The old rule (speed <= the
distance left / 0.25 s, 5 mm margin) ran into the Y switch at 59 mm/s.

The rule:

* the predicted position = the last known position + what the speeds written in the last
  `lag_s` add (they have not shown in the position yet);
* d = the distance from the predicted position to the margin line, in the direction of the
  speed asked for (<= 0: nothing towards that edge, the way back is always free);
* the speed towards that edge is at most v with v * react_s + v^2 / (2 * brake) <= d: kept
  for one more refresh (`react_s`) and then braked at `brake` mm/s^2, it ends on the line.

`brake` is half the firmware's serial jog acceleration (600 mm/s^2), as the firmware's own
soft limit does (JOG_SOFT_LIMIT_BRAKE_RATIO). Pure logic: nothing is sent from here.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field


@dataclass
class JogEdgeGuard:
    margin_min: float = 15.0  # inside x_min / y_min (the limit switches)
    margin_max: float = 5.0  # inside x_max / y_max
    lag_s: float = 0.25
    react_s: float = 0.15
    brake_mm_s2: float = 300.0
    # (time, vx, vy) of each XY speed written, newest last: what the position does not show yet
    _sent: deque = field(default_factory=lambda: deque(maxlen=64))

    @property
    def enabled(self) -> bool:
        return self.margin_min > 0 or self.margin_max > 0

    def note_sent(self, now: float, vx: float, vy: float) -> None:
        """The XY speed the firmware was told at `now` (0, 0 when a jog ends)."""
        if self._sent and self._sent[-1][1:] == (vx, vy):
            return  # the same speed goes on
        self._sent.append((now, vx, vy))

    def forget(self) -> None:
        self._sent.clear()

    def travel(self, now: float) -> tuple[float, float]:
        """How far the speeds written in the last lag_s take the carriage (mm, signed)."""
        lag = max(self.lag_s, 0.0)
        if lag <= 0 or not self._sent:
            return 0.0, 0.0
        start = now - lag
        dx = dy = 0.0
        pts = list(self._sent)
        for i, (t0, vx, vy) in enumerate(pts):
            t1 = pts[i + 1][0] if i + 1 < len(pts) else now
            lo, hi = max(t0, start), min(t1, now)
            if hi > lo:
                dx += vx * (hi - lo)
                dy += vy * (hi - lo)
        return dx, dy

    def max_speed(self, d: float) -> float:
        """The fastest speed towards a line d mm away (the margin line, from the prediction)."""
        if d <= 0:
            return 0.0
        a, h = self.brake_mm_s2, max(self.react_s, 0.0)
        if a <= 0:
            return d / h if h > 0 else math.inf
        return a * (math.sqrt(h * h + 2.0 * d / a) - h)

    def axis(self, v: float, at: float, ahead: float, lo: float, hi: float) -> float:
        if v == 0:
            return 0.0
        pred = at + ahead
        if v > 0:
            d = (hi - self.margin_max) - pred
        else:
            d = pred - (lo + self.margin_min)
        return math.copysign(min(abs(v), self.max_speed(d)), v)

    def limit(self, vx: float, vy: float, x: float, y: float, now: float,
              x_min: float, x_max: float, y_min: float, y_max: float) -> tuple[float, float]:
        """(vx, vy) slowed for the edges, from the last known (x, y). Not recorded: call
        note_sent with what is actually written."""
        if not self.enabled:
            return vx, vy
        ax, ay = self.travel(now)
        return self.axis(vx, x, ax, x_min, x_max), self.axis(vy, y, ay, y_min, y_max)
