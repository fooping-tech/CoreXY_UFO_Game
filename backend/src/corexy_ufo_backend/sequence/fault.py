"""The one fault of the automatic sequences (auto catch, homework approach, tidy-up)."""

from __future__ import annotations


class SequenceFault(Exception):
    """A step failed or a check refused to go on: the sequence ends in FAULT with an ABORT.

    servo_ended (#269): the step's servo command was answered with a failed result (the
    command is over, nothing moves): the sequence stops with STOP instead (no alarm, homing
    kept), unless a stop was asked for or STOP cannot be confirmed."""

    def __init__(self, message: str = "", *, servo_ended: bool = False) -> None:
        super().__init__(message)
        self.servo_ended = servo_ended
