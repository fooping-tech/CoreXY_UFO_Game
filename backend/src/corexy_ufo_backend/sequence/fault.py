"""The one fault of the automatic sequences (auto catch, homework approach, tidy-up)."""

from __future__ import annotations


class SequenceFault(Exception):
    """A step failed or a check refused to go on: the sequence ends in FAULT with an ABORT."""
