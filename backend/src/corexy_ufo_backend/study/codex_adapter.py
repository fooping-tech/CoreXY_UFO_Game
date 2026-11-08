"""Small JSON-RPC adapter around the experimental ``codex app-server``.

Nothing outside this module depends on app-server's wire format.  That keeps
the optional study feature replaceable and lets the game run when Codex is not
installed or not signed in.
"""

from __future__ import annotations

import asyncio
import json
import shlex
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any


class CodexAdapterError(RuntimeError):
    pass


class CodexStudyAdapter:
    def __init__(self, command: str = "codex app-server --listen stdio://") -> None:
        self.command = command
        self._proc: asyncio.subprocess.Process | None = None
        self._reader_task: asyncio.Task | None = None
        self._pending: dict[int, asyncio.Future] = {}
        self._turns: dict[str, tuple[Callable[[str], Awaitable[None]], asyncio.Future[str]]] = {}
        self._active_turn_by_thread: dict[str, str] = {}
        self._next_id = 0
        self._write_lock = asyncio.Lock()
        self._workdir: Path | None = None

    async def _ensure_started(self, workdir: Path) -> None:
        if self._proc is not None and self._proc.returncode is None:
            return
        argv = shlex.split(self.command)
        if not argv:
            raise CodexAdapterError("codex_command is empty")
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, cwd=workdir,
            )
        except FileNotFoundError as exc:
            raise CodexAdapterError(f"Codex CLI not found: {argv[0]}") from exc
        self._workdir = workdir
        self._reader_task = asyncio.create_task(self._read_loop())
        try:
            await self._request("initialize", {
                "clientInfo": {"name": "corexy-ufo-study", "version": "1"},
                "capabilities": {"experimentalApi": True},
            })
            await self._notify("initialized", {})
        except Exception:
            await self.close()
            raise

    async def _send(self, message: dict[str, Any]) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.returncode is not None:
            raise CodexAdapterError("codex app-server is not running")
        wire = (json.dumps(message, ensure_ascii=False) + "\n").encode()
        async with self._write_lock:
            proc.stdin.write(wire)
            await proc.stdin.drain()

    async def _request(self, method: str, params: dict[str, Any]) -> Any:
        self._next_id += 1
        request_id = self._next_id
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        await self._send({"id": request_id, "method": method, "params": params})
        try:
            return await future
        finally:
            self._pending.pop(request_id, None)

    async def _notify(self, method: str, params: dict[str, Any]) -> None:
        await self._send({"method": method, "params": params})

    async def _read_loop(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        try:
            while line := await self._proc.stdout.readline():
                try:
                    message = json.loads(line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if "id" in message:
                    future = self._pending.get(message["id"])
                    if future is not None and not future.done():
                        if message.get("error"):
                            future.set_exception(CodexAdapterError(str(message["error"])))
                        else:
                            future.set_result(message.get("result"))
                    # Let the requester register a turn before already-buffered
                    # delta/completion notifications are consumed.
                    await asyncio.sleep(0)
                    continue
                method, params = message.get("method"), message.get("params") or {}
                turn_id = str(params.get("turnId", ""))
                tracked = self._turns.get(turn_id)
                if method == "item/agentMessage/delta" and tracked:
                    await tracked[0](str(params.get("delta", "")))
                elif method == "turn/completed" and tracked:
                    future = tracked[1]
                    turn = params.get("turn") or {}
                    status = str(turn.get("status", params.get("status", "completed")))
                    if not future.done():
                        if status in ("completed", "success"):
                            future.set_result(status)
                        else:
                            future.set_exception(CodexAdapterError(f"Codex turn ended: {status}"))
        except asyncio.CancelledError:
            return
        finally:
            error = CodexAdapterError("codex app-server stopped unexpectedly")
            for future in list(self._pending.values()):
                if not future.done():
                    future.set_exception(error)
            for _, future in list(self._turns.values()):
                if not future.done():
                    future.set_exception(error)

    async def start_session(self, workdir: Path, instructions: str) -> str:
        await self._ensure_started(workdir)
        result = await self._request("thread/start", {
            "cwd": str(workdir), "ephemeral": True, "approvalPolicy": "never",
            "sandbox": "read-only", "environments": [], "dynamicTools": [],
            "developerInstructions": instructions,
        })
        thread = (result or {}).get("thread") or {}
        thread_id = str(thread.get("id", ""))
        if not thread_id:
            raise CodexAdapterError("thread/start returned no thread id")
        return thread_id

    async def ask(self, thread_id: str, text: str, image_path: Path,
                  on_delta: Callable[[str], Awaitable[None]]) -> str:
        result = await self._request("turn/start", {"threadId": thread_id, "input": [
            {"type": "text", "text": text},
            {"type": "localImage", "path": str(image_path), "detail": "high"},
        ]})
        turn = (result or {}).get("turn") or {}
        turn_id = str(turn.get("id", ""))
        if not turn_id:
            raise CodexAdapterError("turn/start returned no turn id")
        done: asyncio.Future[str] = asyncio.get_running_loop().create_future()
        self._turns[turn_id] = (on_delta, done)
        self._active_turn_by_thread[thread_id] = turn_id
        try:
            await done
            return turn_id
        finally:
            self._turns.pop(turn_id, None)
            self._active_turn_by_thread.pop(thread_id, None)

    async def cancel(self, thread_id: str, turn_id: str | None = None) -> None:
        if self._proc is None or self._proc.returncode is not None:
            return
        turn_id = turn_id or self._active_turn_by_thread.get(thread_id)
        if not turn_id:
            return
        params: dict[str, Any] = {"threadId": thread_id, "turnId": turn_id}
        try:
            await self._request("turn/interrupt", params)
        except CodexAdapterError:
            pass

    async def close_session(self, thread_id: str) -> None:
        # Ephemeral prevents durable history; delete also releases the live
        # app-server thread as soon as the Study tab is left.
        if self._proc is None or self._proc.returncode is not None:
            return
        try:
            await self._request("thread/delete", {"threadId": thread_id})
        except CodexAdapterError:
            # Older experimental servers may not expose delete. The process is
            # still closed with the service and no local image remains.
            pass

    async def close(self) -> None:
        if self._reader_task:
            self._reader_task.cancel()
            await asyncio.gather(self._reader_task, return_exceptions=True)
        proc, self._proc = self._proc, None
        if proc is not None and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 2.0)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
        self._reader_task = None
