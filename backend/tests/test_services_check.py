"""#114: the 校正 tab's つながり checks (Jev / the tutor AI / Claude Code / Codex / VOICEVOX), with
fakes only: no network, no real CLI, and never a secret in a result."""

from __future__ import annotations

import io
import json
import os
import stat
import urllib.error

import pytest
import websockets

from corexy_ufo_backend import services_check as sc
from corexy_ufo_backend.homework.speech import SpeechConfig
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.websocket import GameServer

from ws_helpers import cmd as _cmd

TOKEN = "cf-secret-token-123"


class FakeResp(io.BytesIO):
    def __init__(self, body: bytes, status: int = 200):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def env_file(tmp_path, token=TOKEN):
    p = tmp_path / ".env"
    p.write_text(f"CF_ACCOUNT_ID=acc123\nCF_API_TOKEN={token}\n")
    return p


@pytest.fixture(autouse=True)
def no_env_keys(monkeypatch):
    monkeypatch.delenv("CF_ACCOUNT_ID", raising=False)
    monkeypatch.delenv("CF_API_TOKEN", raising=False)


def test_jev_token_active_inactive_and_missing(tmp_path):
    seen = []

    def active(req, timeout):
        seen.append((req.full_url, req.headers.get("Authorization")))
        return FakeResp(json.dumps({"success": True, "result": {"status": "active"}}).encode())
    r = sc.check_jev(env_file(tmp_path), opener=active)
    assert r["status"] == "ok" and TOKEN not in json.dumps(r) and seen[0][1] == "Bearer " + TOKEN
    assert seen[0][0].endswith("/user/tokens/verify")

    def account_only(req, timeout):  # an account token: the user endpoint refuses it
        if "/user/" in req.full_url:
            raise urllib.error.HTTPError(req.full_url, 401, "no", {}, io.BytesIO(b'{"success": false}'))
        return FakeResp(json.dumps({"success": True, "result": {"status": "active"}}).encode())
    assert sc.check_jev(env_file(tmp_path), opener=account_only)["status"] == "ok"

    def expired(req, timeout):
        return FakeResp(json.dumps({"success": True, "result": {"status": "expired"}}).encode())
    r = sc.check_jev(env_file(tmp_path), opener=expired)
    assert r["status"] == "ng" and "expired" in r["detail"]
    r = sc.check_jev(tmp_path / "none.env", opener=active)
    assert r["status"] == "ng" and "CF_ACCOUNT_ID" in r["detail"]


def fake_cli(tmp_path, name, out="1.2.3 (Fake)", code=0):
    p = tmp_path / name
    p.write_text(f"#!/bin/sh\necho '{out}'\nexit {code}\n")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return str(p)


def test_claude_and_codex_commands(tmp_path, monkeypatch):
    assert sc.check_claude(fake_cli(tmp_path, "claude"))["status"] == "ok"
    bad = sc.check_claude(fake_cli(tmp_path, "claude2", code=3))
    assert bad["status"] == "ng" and "--version" in bad["detail"]
    monkeypatch.setattr(sc, "resolve_claude", lambda p: "/nowhere/claude")
    assert sc.check_claude("claude")["status"] == "ng"
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    fake_cli(tmp_path, "codex", out="codex-cli 0.9")
    r = sc.check_codex("codex app-server --listen stdio://")
    assert r["status"] == "ok" and "0.9" in r["detail"]
    assert sc.check_codex("no-such-codex-cmd")["status"] == "ng"


def test_voicevox(tmp_path):
    sp = SpeechConfig()
    r = sc.check_voicevox(sp, opener=lambda req, timeout: FakeResp(b'"0.26.0"'))
    assert r["status"] == "ok" and "0.26.0" in r["detail"]

    def down(req, timeout):
        raise urllib.error.URLError("refused")
    assert sc.check_voicevox(sp, opener=down)["status"] == "ng"


def test_the_tutor_without_url_or_token_says_why(tmp_path):
    from dataclasses import replace
    from corexy_ufo_backend.study import StudyConfig
    cfg = replace(StudyConfig.from_raw({"study": {"explain_provider": "tutor"}}), root=str(tmp_path))
    r = sc.check_tutor(cfg)
    assert r["status"] == "ng" and "URL" in r["detail"]
    # #128: no token is no longer a reason by itself: the server is asked (nothing listens on :9)
    cfg = replace(StudyConfig.from_raw({"study": {"tutor_url": "http://127.0.0.1:9"}}), root=str(tmp_path))
    r = sc.check_tutor(cfg)
    assert r["status"] == "ng" and "サーバ" in r["detail"]


def test_the_tutor_check_with_and_without_a_token(tmp_path, monkeypatch):
    from dataclasses import replace
    from corexy_ufo_backend.study import StudyConfig
    from corexy_ufo_backend.study.tutor_adapter import TutorStudyAdapter
    cfg = replace(StudyConfig.from_raw({"study": {"tutor_url": "http://127.0.0.1:9"}}), root=str(tmp_path))
    from corexy_ufo_backend.study.sheet_client import SheetClient
    monkeypatch.setattr(SheetClient, "health", lambda self: None)  # the worksheet reader's way too (#285)
    ok = {"ok": True, "health": {"ok": True, "status": 200}, "auth": {"ok": True, "status": 200}}
    monkeypatch.setattr(TutorStudyAdapter, "health", lambda self: ok)
    r = sc.check_tutor(cfg)
    assert r["status"] == "ok" and "トークンなし" in r["detail"]
    wants = {"ok": False, "health": {"ok": True, "status": 200}, "auth": {"ok": False, "status": 401}}
    monkeypatch.setattr(TutorStudyAdapter, "health", lambda self: wants)
    r = sc.check_tutor(cfg)
    assert r["status"] == "ng" and "トークンを求めている" in r["detail"]
    (tmp_path / "config" / "secrets").mkdir(parents=True)
    (tmp_path / "config" / "secrets" / "tutor_token.txt").write_text("tok\n")
    monkeypatch.setattr(TutorStudyAdapter, "health", lambda self: ok)
    r = sc.check_tutor(cfg)
    assert r["status"] == "ok" and "トークン有効" in r["detail"] and "tok" not in r["detail"].replace("トークン", "")


def test_the_tutor_check_also_tries_the_worksheet_readers_way(tmp_path, monkeypatch):
    """#285: the study mode reads the sheet with its own client (its own TLS): when that one cannot
    reach the server, the check says so although the explanation's way works."""
    from dataclasses import replace
    from corexy_ufo_backend.study import StudyConfig
    from corexy_ufo_backend.study.sheet_client import SheetClient, SheetError
    from corexy_ufo_backend.study.tutor_adapter import TutorStudyAdapter
    ok = {"ok": True, "health": {"ok": True, "status": 200}, "auth": {"ok": True, "status": 200}}
    monkeypatch.setattr(TutorStudyAdapter, "health", lambda self: ok)
    asked = []

    def bad(self):
        asked.append(self.base)
        raise SheetError("network", "証明書を確かめられません（テスト）")
    monkeypatch.setattr(SheetClient, "health", bad)
    cfg = replace(StudyConfig.from_raw({"study": {"tutor_url": "https://192.0.2.10:8444"}}), root=str(tmp_path))
    r = sc.check_tutor(cfg)
    assert r["status"] == "ng" and "プリントの読み取り" in r["detail"] and "証明書" in r["detail"]
    assert asked == ["https://192.0.2.10:8444"]
    # study.ai cloud: the study mode does not read with it, so it is not asked
    cloud = replace(StudyConfig.from_raw({"study": {"tutor_url": "https://192.0.2.10:8444", "ai": "cloud"}}),
                    root=str(tmp_path))
    assert sc.check_tutor(cloud)["status"] == "ok" and len(asked) == 1


async def test_check_all_picks_the_checks_in_use(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(sc, "check_jev", lambda env: (calls.append("jev"), sc.result("jev", "ok", "x"))[1])
    monkeypatch.setattr(sc, "check_claude", lambda c: (calls.append("claude"), sc.result("claude", "ok", "x"))[1])
    monkeypatch.setattr(sc, "check_codex", lambda c: (calls.append("codex"), sc.result("codex", "ok", "x"))[1])
    monkeypatch.setattr(sc, "check_tutor", lambda c: (calls.append("tutor"), sc.result("tutor", "ok", "x"))[1])
    monkeypatch.setattr(sc, "check_voicevox", lambda s: (calls.append("voicevox"), sc.result("voicevox", "ok", "x"))[1])
    raw = {"study": {"provider": "claude"}, "homework": {"speech": {"enabled": True, "engines": ["voicevox", "say"]}}}
    out = await sc.check_all(raw, root=tmp_path)
    assert sorted(calls) == ["claude", "jev", "voicevox"]
    assert {r["name"]: r["status"] for r in out}["tutor"] == "skip"
    calls.clear()
    raw = {"study": {"provider": "codex", "explain_provider": "tutor", "tutor_url": "https://x:8444"},
           "homework": {"speech": {"enabled": False}}}
    await sc.check_all(raw, root=tmp_path)
    assert sorted(calls) == ["codex", "jev", "tutor"]


async def test_ask_once_reports_the_answer_or_why(tmp_path, monkeypatch):
    from dataclasses import replace
    from corexy_ufo_backend.study import StudyConfig

    class Fake:
        def __init__(self, text="OK", fail=None):
            self.text, self.fail = text, fail

        async def start_session(self, workdir, instructions):
            return "t"

        async def ask(self, thread, text, image_path, on_delta, more_images=()):
            assert image_path.read_bytes() == sc.SAMPLE.read_bytes()
            if self.fail:
                raise self.fail
            await on_delta(self.text)

        async def close_session(self, t):
            pass

        async def close(self):
            pass
    cfg = replace(StudyConfig.from_raw({}), root=str(tmp_path))
    monkeypatch.setattr(sc, "make_adapter", lambda c, p=None: Fake())
    r = await sc.ask_once(cfg, "claude")
    assert r["status"] == "ok" and "OK" in r["detail"]
    monkeypatch.setattr(sc, "make_adapter", lambda c, p=None: Fake(fail=RuntimeError("not signed in")))
    r = await sc.ask_once(cfg, "claude")
    assert r["status"] == "ng" and "not signed in" in r["detail"]


async def test_the_server_answers_services_check(monkeypatch):
    async def fake_all(raw, *, ask=False, env_path=None, focus_calibration=None, **k):
        return [sc.result("jev", "ok", "x")] + ([sc.result("ask", "ok", "OK")] if ask else [])
    monkeypatch.setattr(sc, "check_all", fake_all)
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "services_check", rid="a")
            assert m["type"] == "ack" and [r["name"] for r in m["data"]["results"]] == ["jev"]
            m = await _cmd(ws, "services_check", {"ask": True}, rid="b")
            assert [r["name"] for r in m["data"]["results"]] == ["jev", "ask"]
    finally:
        await srv.stop()


async def test_a_disconnect_does_not_wait_for_a_slow_check(monkeypatch):
    """Review on #115: the disconnect's safety aborts must not wait for an AI's answer."""
    import asyncio
    import time

    started = asyncio.Event()

    async def slow_all(raw, *, ask=False, env_path=None, focus_calibration=None, **k):
        started.set()
        await asyncio.sleep(30)
        return []
    monkeypatch.setattr(sc, "check_all", slow_all)
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        ws = await websockets.connect(f"ws://127.0.0.1:{port}")
        await ws.send(json.dumps({"type": "command", "request_id": "s", "data": {"name": "services_check",
                                                                              "params": {"ask": True}}}))
        await asyncio.wait_for(started.wait(), 5)
        t0 = time.monotonic()
        await ws.close()
        for _ in range(100):
            if not srv.clients:
                break
            await asyncio.sleep(0.02)
        assert not srv.clients and time.monotonic() - t0 < 2.0  # handled at once, not after 30 s
    finally:
        await srv.stop()

