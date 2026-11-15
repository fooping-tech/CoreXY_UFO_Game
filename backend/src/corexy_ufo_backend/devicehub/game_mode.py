"""Game mode ("SUMMON THE UFO") capsule transfer animations for the two dials.

The contract (effect ids, colours, timing, synchronisation points) is
docs/game-mode-interface.md; this module is its executable form for the game
(CoreXY_UFO_Game) and for the tests.

    from pc import DeviceGateway
    from pc import game_mode as gm

    gw.set_dial_color(gm.LEFT, gm.DEFAULT_COLORS[gm.LEFT])      # optional: session colour
    # BALL_RECEIVED from the left dial -> the screen portal sucks the capsule in
    gm.play(gw, gm.LEFT, "INTAKE")
    # the virtual ball has landed -> the capsule goes back to the right dial
    gm.play(gw, gm.RIGHT, "RETURN_FLOW")
    res = gw.release_ball(gm.RIGHT)          # at the portal animation sync point
    # RELEASE_DONE / RELEASE_FAILED: the dial ends its animation by itself
    # RELEASE_FAILED / timeout:
    gm.play(gw, gm.RIGHT, "FAULT")

All durations are proposals to be calibrated on the real machine.
"""

from __future__ import annotations

from dataclasses import dataclass

from .protocol import DIAL_LEFT, DIAL_RIGHT, CommandResult

LEFT = DIAL_LEFT  # dial 1 (0x20): left of the screen
RIGHT = DIAL_RIGHT  # dial 2 (0x21): right of the screen

# Initial proposal (same values as DIAL_UNIT_COLOR_1 / _2 in config/hardware.h).
DEFAULT_COLORS = {LEFT: (0, 255, 255), RIGHT: (255, 0, 255)}
SIDE = {LEFT: "left", RIGHT: "right"}


@dataclass(frozen=True)
class Animation:
    effect: str
    direction: str = "NONE"
    duration_ms: int = 0  # 0 = until replaced / cleared by the dial
    priority: str = "NORMAL"
    target: str = "BOTH"
    color: tuple[int, int, int] | None = None  # None = the dial's unit colour


ANIMATIONS: dict[str, Animation] = {
    # waiting for a capsule (ARMED): optional, any local event replaces it
    "ATTRACT": Animation("BREATHE", priority="BACKGROUND"),
    # after BALL_RECEIVED: capsule sucked from the dial into the screen portal.
    # The dial already runs the same look by itself (white flash, then the unit
    # colour TO_SCREEN); this re-times it to the screen animation.
    "INTAKE": Animation("CHASE", "TO_SCREEN", 1500),
    # the virtual ball landed (Game RETURNING): light flows from the portal to the dial
    "RETURN_FLOW": Animation("COMET", "TO_DIAL", 0),
    # RELEASE_STARTED: the capsule is leaving the real machine (ends at RELEASE_DONE / FAILED)
    "RELEASING": Animation("CHASE", "TO_DIAL", 0),
    # RELEASE_FAILED / release timeout
    "FAULT": Animation("FLASH", duration_ms=1500, priority="HIGH", color=(255, 0, 0)),
}


def play(gw, dial: int, name: str, *, color=None, **kw) -> CommandResult:
    """Sends the named animation to one dial. ``color`` overrides the animation colour."""
    a = ANIMATIONS[name]
    return gw.set_dial_effect(dial, a.effect, a.direction, color if color is not None else a.color, a.duration_ms,
                              a.priority, a.target, **kw)


def stop(gw, dial: int, **kw) -> CommandResult:
    """Ends any PC animation on the dial (its own state display comes back)."""
    return gw.clear_dial_effect(dial, **kw)
