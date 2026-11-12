"""Pick the JSON object out of an assistant's answer (prose and braces may surround it)."""

from __future__ import annotations

import json
import re


def last_json_object(text: str) -> dict | None:
    """The last top-level JSON object in `text`, or None."""
    decoder = json.JSONDecoder()
    found, end = None, 0
    for m in re.finditer(r"\{", text):
        if m.start() < end:
            continue  # inside an object already read
        try:
            obj, stop = decoder.raw_decode(text, m.start())
        except ValueError:
            continue
        if isinstance(obj, dict):
            found, end = obj, stop
    return found
