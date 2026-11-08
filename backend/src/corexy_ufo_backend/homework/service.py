"""Homework watch sessions: frames from the game -> Jev -> progress messages.

The game captures the overview camera every `interval_s` while a session runs and
sends the JPEG (`homework_frame`); this service runs one Jev call at a time per
session (a frame arriving while one runs is skipped, as in the jev repo) and
answers with `homework_progress` / `homework_error`. Nothing here touches the
robot. Frames are not stored.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from .jev import JevClient, JevError, JevResult, load_credentials
from .progress import ProgressTracker, build_input, parse

log = logging.getLogger(__name__)

Emit = Callable[[dict[str, Any]], Awaitable[None]]
# 4xx answers in a row (other than 429) before a session stops by itself
FATAL_LIMIT = 3


class JevRunner(Protocol):
    def run(self, jev_input: dict, timeout: float = 30.0) -> JevResult: ...


@dataclass(frozen=True)
class HomeworkConfig:
    enabled: bool = False
    interval_s: float = 10.0
    timeout_s: float = 30.0
    max_image_edge: int = 1024  # the jev repo measured tokens at 1024 px (about 8.8k per call)
    max_image_bytes: int = 700_000
    camera_role: str = "overview"
    env_path: Path | None = None

    @classmethod
    def from_raw(cls, raw: dict[str, Any], env_path: Path | None = None) -> "HomeworkConfig":
        d = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        return cls(enabled=bool(d.get("enabled", False)),
                   interval_s=max(float(d.get("interval_s", 10.0)), 2.0),
                   timeout_s=max(float(d.get("timeout_s", 30.0)), 1.0),
                   max_image_edge=max(int(d.get("max_image_edge", 1024)), 64),
                   max_image_bytes=max(int(d.get("max_image_bytes", 700_000)), 1024),
                   camera_role=str(d.get("camera_role", "overview")),
                   env_path=env_path)


@dataclass
class _Session:
    client: JevRunner
    started: float = field(default_factory=time.monotonic)
    tracker: ProgressTracker = field(default_factory=ProgressTracker)
    task: asyncio.Task | None = None
    count: int = 0
    skipped: int = 0
    errors: int = 0
    fatal_in_row: int = 0
    input_tokens: int = 0
    cost_usd: float = 0.0
    stopped: str = ""  # why it stopped by itself

    def elapsed(self) -> float:
        return time.monotonic() - self.started

    def summary(self) -> dict[str, Any]:
        return {"elapsed_s": round(self.elapsed(), 1), "count": self.count, "skipped": self.skipped,
                "errors": self.errors, "input_tokens": self.input_tokens,
                "cost_usd": round(self.cost_usd, 6), "smoothed_pct": self.tracker.smoothed_pct}


def decode_jpeg(value: str, limit: int) -> bytes:
    if len(value) > (limit * 4 // 3) + 16:
        raise ValueError("image is too large")
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError("invalid base64 image") from exc
    if len(raw) > limit:
        raise ValueError("image is too large")
    if len(raw) < 4 or raw[:2] != b"\xff\xd8" or raw[-2:] != b"\xff\xd9":
        raise ValueError("image is not a JPEG")
    return raw


class HomeworkService:
    def __init__(self, config: HomeworkConfig,
                 client_factory: Callable[[], JevRunner] | None = None) -> None:
        self.config = config
        # credentials are read when a session starts, so a fixed .env needs no restart
        self._client_factory = client_factory or (lambda: JevClient(load_credentials(config.env_path)))
        self.sessions: dict[str, _Session] = {}

    async def start(self, session_id: str) -> dict[str, Any]:
        if not session_id or len(session_id) > 128:
            raise ValueError("invalid session_id")
        if session_id not in self.sessions:
            self.sessions[session_id] = _Session(client=self._client_factory())  # JevError("config") if no key
            log.info("homework session %s started", session_id)
        s = self.sessions[session_id]
        return {"session_id": session_id, "state": "running", "interval_s": self.config.interval_s,
                "camera_role": self.config.camera_role, "elapsed_s": round(s.elapsed(), 1)}

    async def frame(self, session_id: str, request_id: str, image_b64: str, emit: Emit) -> bool:
        """Start a Jev call for this frame; False when one is still running (skipped)."""
        s = self.sessions.get(session_id)
        if s is None:
            raise ValueError("unknown homework session")
        if s.task is not None and not s.task.done():
            s.skipped += 1
            return False
        image = decode_jpeg(image_b64, self.config.max_image_bytes)
        jev_input = build_input(base64.b64encode(image).decode("ascii"))
        s.task = asyncio.create_task(self._run(session_id, s, request_id, jev_input, emit))
        return True

    async def _run(self, session_id: str, s: _Session, request_id: str, jev_input: dict, emit: Emit) -> None:
        try:
            res = await asyncio.wait_for(asyncio.to_thread(s.client.run, jev_input, self.config.timeout_s),
                                         self.config.timeout_s + 5.0)
        except asyncio.CancelledError:
            raise
        except (JevError, asyncio.TimeoutError) as e:
            err = e if isinstance(e, JevError) else JevError("timeout", "Jev の応答がタイムアウトしました")
            s.errors += 1
            s.fatal_in_row = s.fatal_in_row + 1 if err.fatal else 0
            data: dict[str, Any] = {"code": err.kind, "message": err.describe(), "status": err.status,
                                    **s.summary()}
            if s.fatal_in_row >= FATAL_LIMIT:
                s.stopped = f"{FATAL_LIMIT} errors in a row"
                data["stopped"] = True
                self.sessions.pop(session_id, None)
                log.warning("homework session %s stopped: %s", session_id, err.describe())
            await emit({"type": "homework_error", "request_id": request_id, "data": data})
            return
        s.fatal_in_row = 0
        s.count += 1
        s.input_tokens += int(res.usage.get("input_tokens") or 0)
        s.cost_usd += res.cost_usd or 0.0
        reading = parse(res.output)
        smoothed = s.tracker.add(s.elapsed(), reading)
        await emit({"type": "homework_progress", "request_id": request_id, "data": {
            "progress_pct": reading.progress_pct, "smoothed_pct": smoothed, "held": reading.held,
            "held_reason": reading.held_reason, "visible_prob": reading.visible_prob,
            "occluded_prob": reading.occluded_prob, "top_level_prob": reading.top_level_prob,
            "latency_ms": round(res.latency_s * 1000), **s.summary()}})

    async def stop(self, session_id: str) -> dict[str, Any] | None:
        s = self.sessions.pop(session_id, None)
        if s is None:
            return None
        if s.task is not None and not s.task.done():
            s.task.cancel()
            await asyncio.gather(s.task, return_exceptions=True)
        log.info("homework session %s stopped: %s", session_id, s.summary())
        return {"session_id": session_id, "state": "stopped", **s.summary(),
                "history": s.tracker.history}

    async def close(self) -> None:
        for session_id in list(self.sessions):
            await self.stop(session_id)
