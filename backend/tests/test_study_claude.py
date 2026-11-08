"""The Claude Code study adapter, against a fake CLI that prints the real stream-json lines."""

from __future__ import annotations

import asyncio
import json
import shlex
import sys
from pathlib import Path

import pytest
import websockets

from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.study import (ClaudeCodeStudyAdapter, CodexStudyAdapter, StudyAdapterError, StudyConfig,
                                      StudyService, make_adapter)
from corexy_ufo_backend.study import claude_adapter
from corexy_ufo_backend.study.claude_adapter import RESTARTED_NOTE, claude_argv, find_claude, resolve_claude
from corexy_ufo_backend.websocket import GameServer

FAKE = Path(__file__).with_name("fake_claude_cli.py")
FAKE_CMD = f"{shlex.quote(sys.executable)} -I {shlex.quote(str(FAKE))}"
JPEG = b"\xff\xd8study-test\xff\xd9"


@pytest.fixture
def image(tmp_path):
    p = tmp_path / "shot.jpg"
    p.write_bytes(JPEG)
    return p


async def ask(adapter, thread, text, image):
    got: list[str] = []

    async def on_delta(t):
        got.append(t)

    await adapter.ask(thread, text, image, on_delta)
    return "".join(got)


def test_command_line_has_no_tools_mcp_settings_or_history():
    argv = claude_argv("claude", "教える")
    assert Path(argv[0]).name == "claude" and argv[argv.index("--tools") + 1] == ""
    assert argv[argv.index("--setting-sources") + 1] == ""
    assert argv[argv.index("--mcp-config") + 1] == '{"mcpServers":{}}'
    for flag in ("-p", "--strict-mcp-config", "--no-session-persistence", "--include-partial-messages"):
        assert flag in argv
    assert argv[argv.index("--input-format") + 1] == "stream-json"
    assert argv[argv.index("--system-prompt") + 1] == "教える"
    assert "--model" not in argv
    assert claude_argv("/path/to/claude", "x", "sonnet")[-2:] == ["--model", "sonnet"]
    with pytest.raises(StudyAdapterError):
        claude_argv("  ", "x")


async def test_answers_stream_and_the_session_keeps_one_process(tmp_path, image, monkeypatch):
    argv_log = tmp_path / "argv.jsonl"
    monkeypatch.setenv("FAKE_CLAUDE_ARGV", str(argv_log))
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD)
    try:
        thread = await adapter.start_session(tmp_path, "system")
        assert await ask(adapter, thread, "この本は？", image) == "turn1:この本は？"
        assert await ask(adapter, thread, "続き", image) == "turn2:続き"  # same process: context kept
        runs = [json.loads(l) for l in argv_log.read_text().splitlines()]
        assert len(runs) == 1 and runs[0][runs[0].index("--tools") + 1] == ""
    finally:
        await adapter.close()


async def test_an_error_result_is_an_error(tmp_path, image):
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD)
    try:
        thread = await adapter.start_session(tmp_path, "system")
        with pytest.raises(StudyAdapterError, match="not signed in"):
            await ask(adapter, thread, "fail", image)
        assert await ask(adapter, thread, "ok", image) == "turn2:ok"
    finally:
        await adapter.close()


async def test_cancel_interrupts_and_the_conversation_goes_on(tmp_path, image):
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD)
    try:
        thread = await adapter.start_session(tmp_path, "system")
        task = asyncio.create_task(ask(adapter, thread, "slow", image))
        await asyncio.sleep(0.5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        # the interrupted turn's own result did not end the next question
        assert await ask(adapter, thread, "next", image) == "turn2:next"
    finally:
        await adapter.close()


async def test_a_wedged_cli_is_stopped_and_the_next_question_restarts(tmp_path, image, monkeypatch):
    argv_log = tmp_path / "argv.jsonl"
    monkeypatch.setenv("FAKE_CLAUDE_ARGV", str(argv_log))
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD, cleanup_timeout_s=0.3)
    try:
        thread = await adapter.start_session(tmp_path, "system")
        task = asyncio.create_task(ask(adapter, thread, "wedge", image))
        await asyncio.sleep(0.5)
        task.cancel()
        await asyncio.wait_for(asyncio.gather(task, return_exceptions=True), 5)  # bounded
        answer = await ask(adapter, thread, "again", image)
        assert answer == RESTARTED_NOTE + "turn1:again"  # a new process, said so
        assert len(argv_log.read_text().splitlines()) == 2
    finally:
        await adapter.close()


async def test_a_cli_that_exits_fails_the_turn_then_restarts(tmp_path, image):
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD)
    try:
        thread = await adapter.start_session(tmp_path, "system")
        with pytest.raises(StudyAdapterError, match="stopped unexpectedly"):
            await ask(adapter, thread, "exit", image)
        assert await ask(adapter, thread, "hi", image) == RESTARTED_NOTE + "turn1:hi"
    finally:
        await adapter.close()


async def test_a_missing_cli_is_a_clear_error(tmp_path):
    adapter = ClaudeCodeStudyAdapter(str(tmp_path / "no-such-claude"))
    with pytest.raises(StudyAdapterError, match="Claude Code CLI not found"):
        await adapter.start_session(tmp_path, "system")
    await adapter.close()


async def test_study_service_timeout_with_claude(tmp_path):
    import base64
    adapter = ClaudeCodeStudyAdapter(FAKE_CMD, cleanup_timeout_s=1.0)
    service = StudyService(StudyConfig(enabled=True, timeout_s=1.0), adapter)
    sent: list[dict] = []

    async def emit(m):
        sent.append(m)

    try:
        await service.start_session("s")
        await service.ask("s", "r1", "slow", base64.b64encode(JPEG).decode(), emit)
        await asyncio.wait_for(service.sessions["s"].task, 5)
        assert sent[-1]["type"] == "study_error" and sent[-1]["data"]["code"] == "timeout"
        await service.ask("s", "r2", "after", base64.b64encode(JPEG).decode(), emit)
        await asyncio.wait_for(service.sessions["s"].task, 5)
        assert sent[-1]["type"] == "study_result"
        assert "".join(m["data"]["text"] for m in sent if m["request_id"] == "r2" and m["type"] == "study_delta") == "turn2:after"
    finally:
        await service.close()


def test_provider_picks_the_adapter():
    raw = {"study": {"provider": "Claude", "claude_command": "/opt/claude", "claude_model": "sonnet"}}
    cfg = StudyConfig.from_raw(raw)
    a = make_adapter(cfg)
    assert isinstance(a, ClaudeCodeStudyAdapter) and a.command == "/opt/claude" and a.model == "sonnet"
    assert StudyConfig.from_raw({}).provider == "claude"  # the default
    assert isinstance(make_adapter(StudyConfig.from_raw({"study": {"provider": "codex"}})), CodexStudyAdapter)
    with pytest.raises(ValueError, match="study.provider"):
        make_adapter(StudyConfig.from_raw({"study": {"provider": "gpt"}}))


async def test_hello_names_the_provider():
    robot = MockRobot()
    await robot.connect()
    service = StudyService(StudyConfig(enabled=True, provider="claude"), ClaudeCodeStudyAdapter(FAKE_CMD))
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, study=service)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = json.loads(await asyncio.wait_for(ws.recv(), 2))
            assert hello["type"] == "hello" and hello["data"]["study"] is True
            assert hello["data"]["study_provider"] == "claude"
    finally:
        await srv.stop()


def _exe(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


def test_find_claude_takes_the_newest_editor_copy(tmp_path, monkeypatch):
    monkeypatch.setattr(claude_adapter, "_SYSTEM_CANDIDATES", ())
    ext = tmp_path / ".vscode/extensions"
    assert find_claude(tmp_path) is None
    _exe(ext / "anthropic.claude-code-2.1.9-darwin-arm64/resources/native-binary/claude")
    newest = _exe(ext / "anthropic.claude-code-2.1.319-darwin-arm64/resources/native-binary/claude")
    stale = ext / "anthropic.claude-code-2.2.0-darwin-arm64/resources/native-binary/claude"
    stale.parent.mkdir(parents=True)
    stale.write_text("")  # not executable (a half-removed update): skipped
    assert find_claude(tmp_path) == str(newest)  # 319 > 9: by number, not by text
    installed = _exe(tmp_path / ".local/bin/claude")
    assert find_claude(tmp_path) == str(installed)  # an installed CLI comes first


def test_resolve_claude(monkeypatch):
    monkeypatch.setattr(claude_adapter.shutil, "which", lambda _p: None)
    monkeypatch.setattr(claude_adapter, "find_claude", lambda: "/found/claude")
    assert resolve_claude("claude") == "/found/claude"  # not on PATH: looked for
    assert resolve_claude("/opt/x/claude") == "/opt/x/claude"  # a path is kept as written
    assert resolve_claude("~/bin/claude") == str(Path.home() / "bin/claude")  # no user name in config
    assert resolve_claude("other-cli") == "other-cli"
    monkeypatch.setattr(claude_adapter.shutil, "which", lambda _p: "/usr/bin/claude")
    assert resolve_claude("claude") == "claude"  # on PATH: left to the OS
