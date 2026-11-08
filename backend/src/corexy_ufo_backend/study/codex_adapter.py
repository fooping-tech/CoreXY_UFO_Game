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


from .errors import StudyAdapterError


class CodexAdapterError(StudyAdapterError):
    pass


class CodexStudyAdapter:
    def __init__(self, command: str = "codex app-server --listen stdio://", *,
                 rpc_timeout_s: float = 15.0, cleanup_timeout_s: float = 2.0) -> None:
        self.command = command
        self.rpc_timeout_s = rpc_timeout_s
        self.cleanup_timeout_s = cleanup_timeout_s
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
            # Keep the process cwd stable: a session directory is deleted when
            # its tab closes, while this process can serve later sessions.
            # Only the Codex thread uses the disposable working directory.
            self._proc = await asyncio.create_subprocess_exec(
                *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                # Image-related notifications can exceed asyncio's 64 KiB
                # default line limit. Keep a finite, image-sized bound.
                limit=16 * 1024 * 1024,
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
        try:
            async with asyncio.timeout(self.rpc_timeout_s):
                await self._send({"id": request_id, "method": method, "params": params})
                return await future
        except TimeoutError as exc:
            raise CodexAdapterError(f"Codex RPC timed out: {method}") from exc
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
                    if "method" in message:
                        # Never execute tools or approvals requested by the
                        # server. Respond so it cannot wait indefinitely.
                        await self._send({"id": message["id"], "error": {
                            "code": -32601, "message": "Study does not support server requests"}})
                        continue
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
                turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
                turn_id = str(params.get("turnId") or turn.get("id") or "")
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
        except Exception as exc:
            error = CodexAdapterError(f"Codex protocol reader failed: {exc}")
            for future in list(self._pending.values()) + [entry[1] for entry in self._turns.values()]:
                if not future.done():
                    future.set_exception(error)
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
            # Study runs in a disposable directory and must not inherit the
            # user's project MCP servers.  Besides keeping the feature
            # isolated, this avoids relative MCP commands in config.toml being
            # resolved against the temporary directory.
            "config": {"mcp_servers": {}},
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
        except asyncio.CancelledError:
            # Keep the mapping alive until turn/interrupt has the ID it requires.
            await asyncio.shield(self.cancel(thread_id, turn_id))
            raise
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
            async with asyncio.timeout(self.cleanup_timeout_s):
                await self._request("turn/interrupt", params)
        except (CodexAdapterError, TimeoutError):
            # A wedged server must not hold the caller's timeout/cancel path.
            await self.close()

    async def close_session(self, thread_id: str) -> None:
        # Ephemeral prevents durable history; delete also releases the live
        # app-server thread as soon as the Study tab is left.
        if self._proc is None or self._proc.returncode is not None:
            return
        try:
            async with asyncio.timeout(self.cleanup_timeout_s):
                await self._request("thread/delete", {"threadId": thread_id})
        except (CodexAdapterError, TimeoutError):
            # Ephemeral threads leave no durable history. Closing the process
            # releases live state when this experimental method is absent.
            await self.close()

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
