"""Validation, sessions, temporary images and timeouts for study requests."""

from __future__ import annotations

import asyncio
import base64
import binascii
import tempfile
import uuid
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Protocol


class StudyAdapter(Protocol):
    async def start_session(self, workdir: Path, instructions: str) -> str: ...
    # more_images (optional, e.g. an earlier frame to compare with) go before image_path
    async def ask(self, thread_id: str, text: str, image_path: Path,
                  on_delta: Callable[[str], Awaitable[None]], more_images: Sequence[Path] = ()) -> str: ...
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
    # who answers: "claude" (Claude Code CLI, the default) or "codex" (codex app-server)
    provider: str = "claude"
    claude_command: str = "claude"
    claude_model: str = ""  # "" = the CLI's default model
    # Who writes the study mode's explanations (#104): "" = provider; "tutor" = the learning
    # support AI (UFOくん API). The tutor adapter reads only the explanation's prompt, so
    # the advice, the problem's place and the Study tab stay with provider.
    explain_provider: str = ""
    tutor_url: str = ""  # https://<the tutor PC>:8444 (http only on the same PC)
    tutor_token_file: str = "config/secrets/tutor_token.txt"  # never in Git, never shown
    tutor_cafile: str = "config/secrets/tutor_cert.pem"  # the server's self-signed cert (https)
    tutor_grade: int = 3
    tutor_timeout_s: float = 20.0
    tutor_fail_limit: int = 2  # failures in a row before the tutor rests...
    tutor_cooldown_s: float = 120.0  # ...for this long (the worksheet's hints meanwhile)
    root: str = "."  # relative tutor_* files are under the repository (main.py sets it)
    focus_calibration: Any = None  # calibration.json#focus_camera (main.py sets it)

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "StudyConfig":
        data = raw.get("study") if isinstance(raw.get("study"), dict) else {}
        return cls(enabled=bool(data.get("enabled", False)), timeout_s=max(float(data.get("timeout_s", 90.0)), 1.0),
                   max_image_bytes=max(int(data.get("max_image_bytes", 700_000)), 1024),
                   max_image_edge=max(int(data.get("max_image_edge", 1280)), 64),
                   camera_role=str(data.get("camera_role", "overview")),
                   system_prompt=str(data.get("system_prompt", cls.system_prompt)),
                   codex_command=str(data.get("codex_command", "codex app-server --listen stdio://")),
                   provider=str(data.get("provider", "claude")).strip().lower(),
                   claude_command=str(data.get("claude_command", "claude")),
                   claude_model=str(data.get("claude_model", "")),
                   explain_provider=str(data.get("explain_provider", "") or "").strip().lower(),
                   tutor_url=str(data.get("tutor_url", "") or "").strip(),
                   tutor_token_file=str(data.get("tutor_token_file", cls.tutor_token_file)),
                   tutor_cafile=str(data.get("tutor_cafile", cls.tutor_cafile)),
                   tutor_grade=int(data.get("tutor_grade", 3)),
                   tutor_timeout_s=max(float(data.get("tutor_timeout_s", 20.0)), 1.0),
                   tutor_fail_limit=max(int(data.get("tutor_fail_limit", 2)), 1),
                   tutor_cooldown_s=max(float(data.get("tutor_cooldown_s", 120.0)), 0.0))


PROVIDERS = ("claude", "codex", "tutor")


def _under_root(config: StudyConfig, name: str) -> Path:
    p = Path(name).expanduser()
    return p if p.is_absolute() else Path(config.root) / p


def make_adapter(config: StudyConfig, provider: str | None = None) -> StudyAdapter:
    """The adapter for study.provider, or `provider` (imported lazily: each one is optional)."""
    provider = provider or config.provider
    if provider == "tutor":
        from .errors import StudyAdapterError
        from .tutor_adapter import TutorStudyAdapter
        if not config.tutor_url:
            raise StudyAdapterError("学習支援 AI の URL がありません（study.tutor_url）")
        token_file = _under_root(config, config.tutor_token_file)
        try:
            token = token_file.read_text(encoding="utf-8").strip()
        except OSError as e:
            raise StudyAdapterError(f"学習支援 AI のトークンを読めません（{token_file}）") from e
        cafile = _under_root(config, config.tutor_cafile) if config.tutor_cafile else None
        return TutorStudyAdapter(config.tutor_url, token, grade=config.tutor_grade,
                                 cafile=str(cafile) if cafile is not None and cafile.exists() else None,
                                 focus_calibration=config.focus_calibration, timeout_s=config.tutor_timeout_s,
                                 fail_limit=config.tutor_fail_limit, cooldown_s=config.tutor_cooldown_s)
    config = replace(config, provider=provider)
    if config.provider == "claude":
        from .claude_adapter import ClaudeCodeStudyAdapter
        return ClaudeCodeStudyAdapter(config.claude_command, model=config.claude_model)
    if config.provider == "codex":
        from .codex_adapter import CodexStudyAdapter
        return CodexStudyAdapter(config.codex_command)
    raise ValueError(f"study.provider must be one of {PROVIDERS}, not {config.provider!r}")


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
                            "data": {"code": "timeout", "message": "回答がタイムアウトしました"}})
            except Exception as exc:
                await emit({"type": "study_error", "request_id": request_id,
                            "data": {"code": "assistant_error", "message": str(exc)}})
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
