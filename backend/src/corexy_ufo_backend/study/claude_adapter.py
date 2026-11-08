"""Study adapter around the Claude Code CLI in stream-json mode.

One ``claude -p --input-format stream-json --output-format stream-json`` process
per study session: the conversation lives in that process, so a follow-up
question keeps its context. Nothing outside this module depends on the CLI's
wire format (checked against Claude Code 2.1.319):

- in:  ``{"type":"user","message":{"role":"user","content":[image, text]}}`` per question;
       ``{"type":"control_request","request_id":..,"request":{"subtype":"interrupt"}}``
- out: ``stream_event`` with ``content_block_delta`` / ``text_delta`` while answering,
       ``control_response`` for the interrupt, ``result`` at the end of every turn
       (``is_error`` / ``subtype`` tell a failure; an interrupt ends it with
       ``error_during_execution``). Other lines (``system``, ``assistant``, ...) are ignored.

The process gets no tools, no MCP servers, no user / project settings (so no
hooks, CLAUDE.md or skills of this repository) and keeps nothing on disk. It
signs in with the user's own Claude Code login: no key is stored here.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import shlex
import shutil
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .errors import StudyAdapterError

# The process lost the conversation (it was stopped after a cancel that did not
# answer, or it exited): the next question starts a new one and says so.
RESTARTED_NOTE = "（前の会話が途切れたため、新しい会話として答えます）\n\n"
_STDERR_KEEP = 2000


# Where the CLI is when `claude` is not on PATH (relative to the home directory,
# so no user name is written anywhere). Editor extensions carry their own copy
# under a versioned directory: the newest one is taken each time a session
# starts, so an extension update needs no config change.
_HOME_CANDIDATES = (".local/bin/claude", ".claude/local/claude")
_SYSTEM_CANDIDATES = ("/opt/homebrew/bin/claude", "/usr/local/bin/claude")
_EXTENSION_GLOBS = (
    ".vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude",
    ".vscode-insiders/extensions/anthropic.claude-code-*/resources/native-binary/claude",
    ".cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude",
)


def _version_key(path: Path) -> tuple[int, ...]:
    """anthropic.claude-code-2.1.319-darwin-arm64 -> (2, 1, 319)."""
    for part in path.parts:
        m = re.match(r"anthropic\.claude-code-(\d+(?:\.\d+)*)", part)
        if m:
            return tuple(int(x) for x in m.group(1).split("."))
    return ()


def find_claude(home: Path | None = None) -> str | None:
    """The Claude Code CLI when `claude` is not on PATH, or None."""
    home = home if home is not None else Path.home()
    for rel in _HOME_CANDIDATES:
        p = home / rel
        if os.access(p, os.X_OK):
            return str(p)
    for c in _SYSTEM_CANDIDATES:
        if os.access(c, os.X_OK):
            return c
    found = [p for g in _EXTENSION_GLOBS for p in home.glob(g) if os.access(p, os.X_OK)]
    if found:
        return str(max(found, key=_version_key))
    return None


def resolve_claude(program: str) -> str:
    """claude_command's program: `~` expanded; a bare `claude` that is not on PATH
    is looked for in the usual places (find_claude)."""
    program = os.path.expanduser(program)
    if os.sep in program or shutil.which(program):
        return program
    if program == "claude":
        return find_claude() or program
    return program


def claude_argv(command: str, system_prompt: str, model: str = "") -> list[str]:
    argv = shlex.split(command)
    if not argv:
        raise StudyAdapterError("claude_command is empty")
    argv[0] = resolve_claude(argv[0])
    argv += [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages",
        "--tools", "",  # no built-in tools: it can only look at the image and answer
        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--setting-sources", "",  # no user / project settings, hooks, CLAUDE.md
        "--no-session-persistence", "--permission-mode", "default",
        "--system-prompt", system_prompt,
    ]
    if model:
        argv += ["--model", model]
    return argv


@dataclass
class _Turn:
    on_delta: Callable[[str], Awaitable[None]]
    done: asyncio.Future
    turn_id: str


@dataclass
class _Session:
    workdir: Path
    instructions: str
    proc: asyncio.subprocess.Process | None = None
    reader: asyncio.Task | None = None
    stderr_task: asyncio.Task | None = None
    stderr: bytearray = field(default_factory=bytearray)
    turn: _Turn | None = None
    controls: dict[str, asyncio.Future] = field(default_factory=dict)
    restarted: bool = False  # the conversation was lost: say so in the next answer
    write_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class ClaudeCodeStudyAdapter:
    def __init__(self, command: str = "claude", *, model: str = "",
                 cleanup_timeout_s: float = 3.0) -> None:
        self.command = command
        self.model = model
        self.cleanup_timeout_s = cleanup_timeout_s
        self._sessions: dict[str, _Session] = {}

    # ------------------------------------------------------------ process
    async def _spawn(self, s: _Session) -> None:
        argv = claude_argv(self.command, s.instructions, self.model)
        try:
            s.proc = await asyncio.create_subprocess_exec(
                *argv, cwd=str(s.workdir), stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                # a turn's lines carry the answer only, but keep the same
                # finite, image-sized bound as the Codex adapter
                limit=16 * 1024 * 1024,
            )
        except FileNotFoundError as exc:
            raise StudyAdapterError(
                f"Claude Code CLI not found: {argv[0]} (install Claude Code, or set "
                "study.claude_command to its path; ~ is allowed)") from exc
        s.stderr.clear()
        s.reader = asyncio.create_task(self._read_loop(s))
        s.stderr_task = asyncio.create_task(self._drain_stderr(s))

    def _alive(self, s: _Session) -> bool:
        return s.proc is not None and s.proc.returncode is None

    async def _stop(self, s: _Session) -> None:
        proc, s.proc = s.proc, None
        if proc is not None and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 2.0)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
        for task in (s.reader, s.stderr_task):
            if task is not None:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
        s.reader = s.stderr_task = None
        self._fail(s, StudyAdapterError("Claude Code stopped"))

    def _fail(self, s: _Session, error: Exception) -> None:
        if s.turn is not None and not s.turn.done.done():
            s.turn.done.set_exception(error)
        for fut in s.controls.values():
            if not fut.done():
                fut.set_exception(error)
        s.controls.clear()

    async def _write(self, s: _Session, message: dict[str, Any]) -> None:
        proc = s.proc
        if proc is None or proc.stdin is None or proc.returncode is not None:
            raise StudyAdapterError("Claude Code is not running")
        async with s.write_lock:
            proc.stdin.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
            await proc.stdin.drain()

    async def _drain_stderr(self, s: _Session) -> None:
        assert s.proc is not None and s.proc.stderr is not None
        try:
            while chunk := await s.proc.stderr.read(4096):
                s.stderr += chunk
                del s.stderr[:-_STDERR_KEEP]
        except asyncio.CancelledError:
            return

    def _stderr_tail(self, s: _Session) -> str:
        return s.stderr.decode(errors="replace").strip()[-300:]

    async def _read_loop(self, s: _Session) -> None:
        assert s.proc is not None and s.proc.stdout is not None
        try:
            while line := await s.proc.stdout.readline():
                try:
                    message = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                await self._handle(s, message)
        except asyncio.CancelledError:
            return
        except Exception as exc:  # pragma: no cover - defensive
            self._fail(s, StudyAdapterError(f"Claude Code reader failed: {exc}"))
            return
        # stdout closed: the process exited
        detail = self._stderr_tail(s)
        self._fail(s, StudyAdapterError("Claude Code stopped unexpectedly" + (f": {detail}" if detail else "")))

    async def _handle(self, s: _Session, message: dict[str, Any]) -> None:
        kind = message.get("type")
        turn = s.turn
        if kind == "stream_event" and turn is not None:
            event = message.get("event") or {}
            delta = event.get("delta") or {}
            if event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                text = str(delta.get("text", ""))
                if text:
                    await turn.on_delta(text)
        elif kind == "result" and turn is not None:
            if not turn.done.done():
                if message.get("is_error") or message.get("subtype") != "success":
                    reason = message.get("result") or message.get("errors") or message.get("subtype")
                    turn.done.set_exception(StudyAdapterError(f"Claude Code turn failed: {reason}"))
                else:
                    turn.done.set_result(message.get("subtype"))
        elif kind == "control_response":
            response = message.get("response") or {}
            fut = s.controls.pop(str(response.get("request_id", "")), None)
            if fut is not None and not fut.done():
                fut.set_result(response)
        elif kind == "control_request":
            # never grant anything the CLI asks for (it has no tools anyway)
            await self._write(s, {"type": "control_response", "response": {
                "subtype": "error", "request_id": message.get("request_id"),
                "error": "Study does not support requests from Claude Code"}})

    # ------------------------------------------------------------ StudyAdapter
    async def start_session(self, workdir: Path, instructions: str) -> str:
        thread_id = uuid.uuid4().hex
        s = _Session(workdir=workdir, instructions=instructions)
        await self._spawn(s)
        self._sessions[thread_id] = s
        return thread_id

    async def ask(self, thread_id: str, text: str, image_path: Path,
                  on_delta: Callable[[str], Awaitable[None]]) -> str:
        s = self._sessions.get(thread_id)
        if s is None:
            raise StudyAdapterError("unknown Claude Code session")
        if not self._alive(s):
            await self._stop(s)
            await self._spawn(s)
            s.restarted = True
        image = base64.b64encode(image_path.read_bytes()).decode("ascii")
        turn = _Turn(on_delta=on_delta, done=asyncio.get_running_loop().create_future(),
                     turn_id=uuid.uuid4().hex)
        s.turn = turn
        try:
            if s.restarted:
                s.restarted = False
                await on_delta(RESTARTED_NOTE)
            await self._write(s, {"type": "user", "message": {"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image}},
                {"type": "text", "text": text},
            ]}})
            # shielded: a cancelled ask must not cancel this future, so that
            # cancel() can wait for the interrupted turn's own result line
            # (otherwise that late line could end the next question)
            await asyncio.shield(turn.done)
            return turn.turn_id
        except asyncio.CancelledError:
            await asyncio.shield(self.cancel(thread_id, turn.turn_id))
            raise
        finally:
            if s.turn is turn:
                s.turn = None

    async def cancel(self, thread_id: str, turn_id: str | None = None) -> None:
        s = self._sessions.get(thread_id)
        if s is None or not self._alive(s):
            return
        turn = s.turn
        if turn is None or (turn_id and turn.turn_id != turn_id):
            return
        request_id = uuid.uuid4().hex
        fut = asyncio.get_running_loop().create_future()
        s.controls[request_id] = fut
        try:
            async with asyncio.timeout(self.cleanup_timeout_s):
                await self._write(s, {"type": "control_request", "request_id": request_id,
                                      "request": {"subtype": "interrupt"}})
                await fut
                # the interrupted turn still ends with its own result line
                await asyncio.gather(turn.done, return_exceptions=True)
        except (StudyAdapterError, TimeoutError):
            # a wedged CLI must not hold the cancel / timeout path: stop it, the
            # next question starts a new conversation
            await self._stop(s)
            s.restarted = True
        finally:
            s.controls.pop(request_id, None)

    async def close_session(self, thread_id: str) -> None:
        s = self._sessions.pop(thread_id, None)
        if s is not None:
            await self._stop(s)

    async def close(self) -> None:
        for thread_id in list(self._sessions):
            await self.close_session(thread_id)
