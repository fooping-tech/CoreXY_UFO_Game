from __future__ import annotations

import asyncio
import base64
import json
from pathlib import Path

import pytest
import websockets

from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.study import CodexStudyAdapter, StudyConfig, StudyService
from corexy_ufo_backend.websocket import GameServer


JPEG = b"\xff\xd8study-test\xff\xd9"


class FakeAdapter:
    def __init__(self, *, wait: bool = False) -> None:
        self.wait = wait
        self.started: list[Path] = []
        self.asked: list[tuple[str, str, Path]] = []
        self.cancelled: list[str] = []
        self.closed = False

    async def start_session(self, workdir: Path, _instructions: str) -> str:
        self.started.append(workdir)
        return "thread-1"

    async def ask(self, thread_id: str, text: str, image_path: Path, on_delta) -> str:
        self.asked.append((thread_id, text, image_path))
        assert image_path.read_bytes() == JPEG
        await on_delta("まず図を")
        if self.wait:
            await asyncio.Event().wait()
        await on_delta("確認します")
        return "turn-1"

    async def cancel(self, thread_id: str, _turn_id=None) -> None:
        self.cancelled.append(thread_id)

    async def close_session(self, _thread_id: str) -> None:
        return

    async def close(self) -> None:
        self.closed = True


@pytest.mark.asyncio
async def test_study_service_streams_and_removes_temporary_image():
    adapter = FakeAdapter()
    service = StudyService(StudyConfig(enabled=True), adapter)
    events = []
    async def emit(event):
        events.append(event)
    await service.start_session("s1")
    temp_root = adapter.started[0]
    await service.ask("s1", "r1", "この問題を説明して", base64.b64encode(JPEG).decode(), emit)
    await service.sessions["s1"].task
    assert [e["type"] for e in events] == ["study_delta", "study_delta", "study_result"]
    assert not list(temp_root.glob("*.jpg"))
    await service.end_session("s1")
    assert not temp_root.exists()


@pytest.mark.asyncio
async def test_study_validation_busy_cancel_and_close():
    adapter = FakeAdapter(wait=True)
    service = StudyService(StudyConfig(enabled=True, max_image_bytes=32), adapter)
    await service.start_session("s1")
    async def discard(_event):
        return
    with pytest.raises(ValueError, match="unknown"):
        await service.ask("missing", "r", "q", base64.b64encode(JPEG).decode(), discard)
    with pytest.raises(ValueError, match="base64"):
        await service.ask("s1", "r", "q", "not base64", discard)
    events = []
    async def emit(event):
        events.append(event)
    await service.ask("s1", "r1", "q", base64.b64encode(JPEG).decode(), emit)
    await asyncio.sleep(0)
    with pytest.raises(ValueError, match="another"):
        await service.ask("s1", "r2", "q", base64.b64encode(JPEG).decode(), emit)
    assert await service.cancel("r1")
    assert adapter.cancelled == ["thread-1"]
    assert events[-1]["data"]["code"] == "cancelled"
    await service.close()
    assert adapter.closed


async def _recv_type(ws, wanted: str) -> dict:
    while True:
        message = json.loads(await asyncio.wait_for(ws.recv(), 2.0))
        if message.get("type") == wanted:
            return message


@pytest.mark.asyncio
async def test_study_websocket_is_separate_from_robot_commands():
    robot = MockRobot()
    await robot.connect()
    service = StudyService(StudyConfig(enabled=True), FakeAdapter())
    server = GameServer(robot, "127.0.0.1", 0, study=service)
    await server.start()
    port = server._server.sockets[0].getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await _recv_type(ws, "hello")
            assert hello["data"]["study"] is True
            await ws.send(json.dumps({"type": "study_session_start", "data": {"session_id": "s1"}}))
            status = await _recv_type(ws, "study_status")
            assert status["data"]["state"] == "ready"
            await ws.send(json.dumps({"type": "study_request", "request_id": "r1", "data": {
                "session_id": "s1", "question": "説明して",
                "image_jpeg_base64": base64.b64encode(JPEG).decode()}}))
            assert (await _recv_type(ws, "study_delta"))["data"]["text"] == "まず図を"
            assert (await _recv_type(ws, "study_result"))["request_id"] == "r1"
            assert robot.snapshot().connected
    finally:
        await server.stop()
        await robot.disconnect()


@pytest.mark.asyncio
async def test_disabled_server_reports_study_error():
    robot = MockRobot()
    await robot.connect()
    server = GameServer(robot, "127.0.0.1", 0)
    await server.start()
    port = server._server.sockets[0].getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await _recv_type(ws, "hello")
            assert hello["data"]["study"] is False
            await ws.send(json.dumps({"type": "study_session_start", "data": {"session_id": "s"}}))
            error = await _recv_type(ws, "study_error")
            assert error["data"]["code"] == "disabled"
    finally:
        await server.stop()
        await robot.disconnect()


@pytest.mark.asyncio
async def test_codex_completion_uses_nested_turn_id():
    adapter = CodexStudyAdapter()
    reader = asyncio.StreamReader()
    adapter._proc = type("Proc", (), {"stdout": reader})()
    deltas = []
    async def on_delta(text):
        deltas.append(text)
    done = asyncio.get_running_loop().create_future()
    adapter._turns["turn-nested"] = (on_delta, done)
    reader.feed_data(json.dumps({"method": "turn/completed", "params": {
        "turn": {"id": "turn-nested", "status": "completed"}}}).encode() + b"\n")
    reader.feed_eof()
    await adapter._read_loop()
    assert done.result() == "completed"


@pytest.mark.asyncio
async def test_codex_cancel_keeps_active_turn_until_interrupt():
    class CancelAdapter(CodexStudyAdapter):
        def __init__(self):
            super().__init__()
            self.interrupted = None

        async def _request(self, method, _params):
            assert method == "turn/start"
            return {"turn": {"id": "turn-1"}}

        async def cancel(self, thread_id, turn_id=None):
            self.interrupted = (thread_id, turn_id, self._active_turn_by_thread.get(thread_id))

    adapter = CancelAdapter()
    async def on_delta(_text):
        return
    task = asyncio.create_task(adapter.ask("thread-1", "q", Path("/tmp/image.jpg"), on_delta))
    await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert adapter.interrupted == ("thread-1", "turn-1", "turn-1")
    assert "thread-1" not in adapter._active_turn_by_thread
