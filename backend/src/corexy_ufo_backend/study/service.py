"""Validation, sessions, temporary images and timeouts for study requests."""

from __future__ import annotations

import asyncio
import base64
import binascii
import tempfile
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


class StudyAdapter(Protocol):
    async def start_session(self, workdir: Path, instructions: str) -> str: ...
    async def ask(self, thread_id: str, text: str, image_path: Path,
                  on_delta: Callable[[str], Awaitable[None]]) -> str: ...
    async def cancel(self, thread_id: str, turn_id: str | None = None) -> None: ...
    async def close_session(self, thread_id: str) -> None: ...
    async def close(self) -> None: ...


@dataclass(frozen=True)
class StudyConfig:
    enabled: bool = False
    timeout_s: float = 90.0
    max_image_bytes: int = 700_000
    max_image_edge: int = 1280
    camera_role: str = "overview"
    system_prompt: str = ("あなたは画像を見ながら学習を支援する家庭教師です。答えだけでなく、"
                          "考え方を段階的に日本語で説明してください。画像にない事実は推測と明記してください。")
    codex_command: str = "codex app-server --listen stdio://"

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "StudyConfig":
        data = raw.get("study") if isinstance(raw.get("study"), dict) else {}
        return cls(enabled=bool(data.get("enabled", False)), timeout_s=max(float(data.get("timeout_s", 90.0)), 1.0),
                   max_image_bytes=max(int(data.get("max_image_bytes", 700_000)), 1024),
                   max_image_edge=max(int(data.get("max_image_edge", 1280)), 64),
                   camera_role=str(data.get("camera_role", "overview")),
                   system_prompt=str(data.get("system_prompt", cls.system_prompt)),
                   codex_command=str(data.get("codex_command", "codex app-server --listen stdio://")))


@dataclass
class _Session:
    thread_id: str
    temp: tempfile.TemporaryDirectory
    task: asyncio.Task | None = None
    request_id: str = ""
    turn_id: str | None = None


class StudyService:
    def __init__(self, config: StudyConfig, adapter: StudyAdapter) -> None:
        self.config = config
        self.adapter = adapter
        self.sessions: dict[str, _Session] = {}

    async def start_session(self, session_id: str) -> dict[str, Any]:
        if not session_id or len(session_id) > 128:
            raise ValueError("invalid session_id")
        if session_id in self.sessions:
            return {"session_id": session_id, "state": "ready"}
        temp = tempfile.TemporaryDirectory(prefix="corexy-ufo-study-")
        try:
            thread_id = await self.adapter.start_session(Path(temp.name), self.config.system_prompt)
        except Exception:
            temp.cleanup()
            raise
        self.sessions[session_id] = _Session(thread_id, temp)
        return {"session_id": session_id, "state": "ready"}

    @staticmethod
    def _decode_jpeg(value: str, limit: int) -> bytes:
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

    async def ask(self, session_id: str, request_id: str, question: str, image_b64: str,
                  emit: Callable[[dict[str, Any]], Awaitable[None]]) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            raise ValueError("unknown study session")
        if session.task is not None and not session.task.done():
            raise ValueError("another study request is running")
        question = question.strip()
        if not request_id or not question:
            raise ValueError("request_id and question are required")
        image = self._decode_jpeg(image_b64, self.config.max_image_bytes)
        image_path = Path(session.temp.name) / f"{uuid.uuid4().hex}.jpg"
        image_path.write_bytes(image)
        session.request_id = request_id

        async def delta(text: str) -> None:
            if text:
                await emit({"type": "study_delta", "request_id": request_id, "data": {"text": text}})

        async def run() -> None:
            try:
                session.turn_id = await asyncio.wait_for(
                    self.adapter.ask(session.thread_id, question, image_path, delta), self.config.timeout_s)
                await emit({"type": "study_result", "request_id": request_id,
                            "data": {"thread_id": session.thread_id}})
            except asyncio.CancelledError:
                await self.adapter.cancel(session.thread_id, session.turn_id)
                await emit({"type": "study_error", "request_id": request_id,
                            "data": {"code": "cancelled", "message": "質問をキャンセルしました"}})
            except asyncio.TimeoutError:
                await self.adapter.cancel(session.thread_id, session.turn_id)
                await emit({"type": "study_error", "request_id": request_id,
                            "data": {"code": "timeout", "message": "Codexの応答がタイムアウトしました"}})
            except Exception as exc:
                await emit({"type": "study_error", "request_id": request_id,
                            "data": {"code": "codex_error", "message": str(exc)}})
            finally:
                image_path.unlink(missing_ok=True)
                session.turn_id = None

        session.task = asyncio.create_task(run())

    async def cancel(self, request_id: str) -> bool:
        for session in self.sessions.values():
            if session.request_id == request_id and session.task and not session.task.done():
                session.task.cancel()
                await asyncio.gather(session.task, return_exceptions=True)
                return True
        return False

    async def end_session(self, session_id: str) -> None:
        session = self.sessions.pop(session_id, None)
        if session is None:
            return
        if session.task and not session.task.done():
            session.task.cancel()
            await asyncio.gather(session.task, return_exceptions=True)
        await self.adapter.close_session(session.thread_id)
        session.temp.cleanup()

    async def close(self) -> None:
        for session_id in list(self.sessions):
            await self.end_session(session_id)
        await self.adapter.close()
