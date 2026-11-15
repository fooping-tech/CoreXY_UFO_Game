"""Game mode trace log (JSON Lines) for matching device and screen logs.

    from pc import DeviceGateway
    from pc.trace import TraceLog

    trace = TraceLog("logs/devicehub-trace.jsonl")
    gw = DeviceGateway(port="auto", system_id=1, trace=trace.record)
    ...
    trace.record("game", source_dial=0x20, cycle=3, capsule_id="c-0042", note="portal intake start")

The gateway writes one record per command sent ("command"), per ACK ("ack")
and per device event ("event"). Every record has the same keys (null when not
applicable), so the file can be joined with the screen side log:

    t_mono        time.monotonic() of this PC (seconds)
    wall          local wall clock, ISO 8601 (for humans; join on t_mono)
    kind          command / ack / event / game (written by the game itself)
    session_id    gateway session
    source_dial   device id (0x20 = dial 1 / left, 0x21 = dial 2 / right)
    cycle         receive cycle of that dial (from its last BALL_RECEIVED)
    command_id    command id (RELEASE_* events carry the RELEASE_BALL id)
    event_id      device event id
    event         event name
    command       command name
    effect_id     SET_DIAL_EFFECT effect
    rgb           SET_DIAL_EFFECT / SET_DIAL_COLOR colour (null = unit colour)
    direction     SET_DIAL_EFFECT direction
    ack           ACK result
    release_state STARTED / DONE / FAILED

Extra fields (params, data, capsule_id, ...) are kept as they are. The game
joins its own ``capsule_id`` with (session_id, source_dial, cycle) and, for
the release, with command_id. GET_STATUS polling is not traced.

Never put keys or real device configuration into a trace.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import IO, Any

FIELDS = (
    "session_id",
    "source_dial",
    "cycle",
    "command_id",
    "event_id",
    "event",
    "command",
    "effect_id",
    "rgb",
    "direction",
    "ack",
    "release_state",
)


class TraceLog:
    """Thread-safe JSON Lines writer. ``path=None`` keeps the records in memory only."""

    def __init__(self, path: str | Path | None = None, *, keep: int = 10000) -> None:
        self._lock = threading.Lock()
        self._file: IO[str] | None = None
        self._keep = keep
        self.records: list[dict] = []
        if path is not None:
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            self._file = path.open("a", encoding="utf-8")

    def record(self, kind: str, **fields: Any) -> dict:
        now = time.time()
        rec: dict[str, Any] = {
            "t_mono": round(time.monotonic(), 4),
            "wall": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)) + f".{int(now * 1000) % 1000:03d}",
            "kind": kind,
        }
        for k in FIELDS:
            rec[k] = fields.pop(k, None)
        rec.update(fields)
        with self._lock:
            self.records.append(rec)
            if len(self.records) > self._keep:
                del self.records[: len(self.records) - self._keep]
            if self._file:
                self._file.write(json.dumps(rec, separators=(",", ":"), default=str) + "\n")
                self._file.flush()
        return rec

    def close(self) -> None:
        with self._lock:
            if self._file:
                self._file.close()
                self._file = None

    def __enter__(self) -> TraceLog:
        return self

    def __exit__(self, *exc) -> None:
        self.close()
