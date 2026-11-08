"""Homework watch: Jev answer -> progress (rules from ~/python_ws/jev), client, service, WebSocket."""

from __future__ import annotations

import asyncio
import base64
import io
import json
import threading
import urllib.error

import pytest
import websockets

from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService, JevError, parse
from corexy_ufo_backend.homework.jev import JevClient, JevCredentials, JevResult, load_credentials, read_env_file, unwrap
from corexy_ufo_backend.homework.progress import CRITERIA, ProgressTracker, build_input, score_to_pct
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.websocket import GameServer

JPEG = b"\xff\xd8homework\xff\xd9"
JPEG_B64 = base64.b64encode(JPEG).decode()


def output(probs, visible=0.9, occluded=0.1, tokens=8800):
    """The model output shape measured in the jev repo (keys "0".."5" = 0..100%)."""
    return {"answers": {
        "visible": {"type": "noul", "noul": visible},
        "occluded": {"type": "noul", "noul": occluded},
        "progress": {"type": "score", "score": 2.0, "confidence": 0.7,
                     "probabilities": {str(i): p for i, p in enumerate(probs)}},
    }, "usage": {"input_tokens": tokens, "output_tokens": 0}}


# ------------------------------------------------------------------ progress rules
def test_input_has_three_questions_and_six_levels():
    q = build_input(JPEG_B64)
    assert set(q["questions"]) == {"visible", "occluded", "progress"}
    assert len(CRITERIA) == 6 and CRITERIA[0].startswith("0%:") and CRITERIA[-1].startswith("100%:")
    assert q["assets"]["photo"] == {"type": "image", "format": "jpeg", "data_base64": JPEG_B64}


def test_expected_value_and_the_top_level_rule():
    r = parse(output([0.0, 0.5, 0.5, 0.0, 0.0, 0.0]))
    assert r.progress_pct == pytest.approx(30.0) and not r.held
    finished = parse(output([0.0, 0.0, 0.0, 0.05, 0.35, 0.6]))  # P(100%) >= 0.5 -> 100
    assert finished.progress_pct == 100.0 and finished.progress_ev_pct == pytest.approx(91.0)
    assert parse(output([0, 0, 0, 0.2, 0.4, 0.4])).progress_pct == pytest.approx(84.0)
    assert score_to_pct({"probabilities": {"9": 1.0}}) is None  # unexpected shape: no guess


def test_held_when_not_visible_or_covered():
    assert parse(output([1, 0, 0, 0, 0, 0], visible=0.3)).held_reason == "not_visible"
    assert parse(output([1, 0, 0, 0, 0, 0], occluded=0.35)).held_reason == "occluded"
    assert parse({"answers": {}}).held_reason == "not_visible"


def test_tracker_median_of_updated_readings():
    t = ProgressTracker()
    assert t.add(0, parse(output([0, 1, 0, 0, 0, 0]))) == 20.0
    assert t.add(10, parse(output([0, 0, 1, 0, 0, 0]))) == 30.0
    assert t.add(20, parse(output([0, 0, 0, 0, 0, 1], occluded=0.9))) == 30.0  # held: unchanged
    assert t.add(30, parse(output([0, 0, 0, 0, 0, 1]))) == 40.0  # median(20, 40, 100)
    assert [h["held"] for h in t.history] == ["", "", "occluded", ""]


# ------------------------------------------------------------------ credentials / client
def test_credentials_from_env_file_and_environment(tmp_path, monkeypatch):
    env = tmp_path / ".env"
    env.write_text('# jev\nCF_ACCOUNT_ID=acc\nexport CF_API_TOKEN="tok"\n', encoding="utf-8")
    monkeypatch.delenv("CF_ACCOUNT_ID", raising=False)
    monkeypatch.delenv("CF_API_TOKEN", raising=False)
    assert read_env_file(env) == {"CF_ACCOUNT_ID": "acc", "CF_API_TOKEN": "tok"}
    c = load_credentials(env)
    assert (c.account_id, c.api_token) == ("acc", "tok") and "tok" not in repr(c)
    monkeypatch.setenv("CF_API_TOKEN", "from-env")
    assert load_credentials(env).api_token == "from-env"  # the environment wins
    monkeypatch.delenv("CF_API_TOKEN")
    env.write_text("CF_ACCOUNT_ID=acc\nCF_API_TOKEN=xxxxxxxx\n")
    with pytest.raises(JevError, match="CF_API_TOKEN") as e:
        load_credentials(env)  # the jev .env.example placeholder counts as unset
    assert e.value.kind == "config"
    env.write_text("CF_ACCOUNT_ID=<cloudflare-account-id>\nCF_API_TOKEN=<cloudflare-api-token>\n")
    with pytest.raises(JevError, match="CF_ACCOUNT_ID, CF_API_TOKEN"):
        load_credentials(env)  # and so does this repository's


class _Resp:
    def __init__(self, status, body):
        self.status, self._body = status, body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_client_unwraps_the_envelope_and_sends_the_token():
    seen = {}

    def opener(req, timeout):
        seen["auth"] = req.get_header("Authorization")
        seen["body"] = json.loads(req.data)
        seen["url"] = req.full_url
        return _Resp(200, json.dumps({"result": {"state": "Completed", "result": output([1, 0, 0, 0, 0, 0])},
                                      "success": True, "errors": []}).encode())

    res = JevClient(JevCredentials("acc", "tok"), opener=opener).run(build_input(JPEG_B64))
    assert seen["auth"] == "Bearer tok" and "/accounts/acc/ai/run" in seen["url"]
    assert seen["body"]["model"] == "typesafe/jev-1.14.0"
    assert "answers" in res.output and res.cost_usd == pytest.approx(8800 * 0.042 / 1e6)
    with pytest.raises(JevError, match="完了していません"):
        unwrap({"result": {"state": "Running", "result": {"x": 1}}})


def test_client_http_errors_carry_status_and_codes():
    def opener(req, timeout):
        raise urllib.error.HTTPError(req.full_url, 402, "x", {}, io.BytesIO(
            json.dumps({"success": False, "errors": [{"code": 2021, "message": "credit"}]}).encode()))

    with pytest.raises(JevError) as e:
        JevClient(JevCredentials("a", "t"), opener=opener).run({})
    assert e.value.status == 402 and e.value.kind == "billing" and e.value.codes == [2021] and e.value.fatal
    assert "t" not in e.value.describe().split()  # the token never shows up


# ------------------------------------------------------------------ service
class FakeJev:
    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = 0
        self.gate: threading.Event | None = None

    def run(self, jev_input, timeout=30.0):
        self.calls += 1
        if self.gate is not None:
            self.gate.wait(5)
        a = self.answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return JevResult(output=a, latency_s=0.4)


async def drain(service, sid):
    t = service.sessions[sid].task if sid in service.sessions else None
    if t is not None:
        await asyncio.wait_for(asyncio.gather(t, return_exceptions=True), 5)


async def test_service_progress_skip_and_stop():
    fake = FakeJev([output([0, 1, 0, 0, 0, 0]), output([0, 0, 1, 0, 0, 0])])
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: fake)
    sent = []

    async def emit(m):
        sent.append(m)

    st = await svc.start("s")
    assert st["state"] == "running" and st["interval_s"] == 10.0
    fake.gate = threading.Event()
    assert await svc.frame("s", "r1", JPEG_B64, emit)
    assert not await svc.frame("s", "r2", JPEG_B64, emit)  # one at a time: skipped
    fake.gate.set()
    await drain(svc, "s")
    fake.gate = None
    assert await svc.frame("s", "r3", JPEG_B64, emit)
    await drain(svc, "s")
    assert [m["type"] for m in sent] == ["homework_progress", "homework_progress"]
    d = sent[-1]["data"]
    assert d["progress_pct"] == 40.0 and d["smoothed_pct"] == 30.0 and d["count"] == 2 and d["skipped"] == 1
    assert d["input_tokens"] == 17600 and d["cost_usd"] > 0 and d["elapsed_s"] >= 0
    with pytest.raises(ValueError, match="JPEG"):
        await svc.frame("s", "r4", base64.b64encode(b"not a jpeg").decode(), emit)
    summary = await svc.stop("s")
    assert summary["state"] == "stopped" and len(summary["history"]) == 2 and "s" not in svc.sessions


async def test_service_stops_after_three_4xx_in_a_row():
    err = JevError("auth", "API リクエストが失敗しました", status=401, codes=[10000])
    fake = FakeJev([err, JevError("rate_limit", "x", status=429), err, err, err])
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: fake)
    sent = []

    async def emit(m):
        sent.append(m)

    await svc.start("s")
    for i in range(5):
        if "s" not in svc.sessions:
            break
        await svc.frame("s", f"r{i}", JPEG_B64, emit)
        await drain(svc, "s")
    assert [m["data"].get("stopped", False) for m in sent] == [False, False, False, False, True]
    assert sent[0]["data"]["status"] == 401 and "s" not in svc.sessions  # 429 reset the count


async def test_missing_key_is_reported_at_start(tmp_path, monkeypatch):
    monkeypatch.delenv("CF_ACCOUNT_ID", raising=False)
    monkeypatch.delenv("CF_API_TOKEN", raising=False)
    svc = HomeworkService(HomeworkConfig(enabled=True, env_path=tmp_path / ".env"))
    with pytest.raises(JevError, match="未設定"):
        await svc.start("s")


def test_config_from_raw():
    c = HomeworkConfig.from_raw({"homework": {"enabled": True, "interval_s": 0.5, "camera_role": "focus"}})
    assert c.enabled and c.interval_s == 2.0 and c.camera_role == "focus"  # at least 2 s apart
    assert not HomeworkConfig.from_raw({}).enabled


# ------------------------------------------------------------------ WebSocket
async def _server(homework):
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=homework)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def _recv_type(ws, t):
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 3))
        if m["type"] == t:
            return m


async def test_websocket_homework_flow():
    fake = FakeJev([output([0, 0, 0, 0, 0, 1])])
    srv, port = await _server(HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: fake))
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await _recv_type(ws, "hello")
            assert hello["data"]["homework"] is True
            await ws.send(json.dumps({"type": "homework_start", "data": {"session_id": "h1"}}))
            assert (await _recv_type(ws, "homework_status"))["data"]["state"] == "running"
            await ws.send(json.dumps({"type": "homework_frame", "request_id": "f1",
                                      "data": {"session_id": "h1", "image_jpeg_base64": JPEG_B64}}))
            p = await _recv_type(ws, "homework_progress")
            assert p["request_id"] == "f1" and p["data"]["smoothed_pct"] == 100.0
            await ws.send(json.dumps({"type": "homework_stop", "data": {"session_id": "h1"}}))
            st = await _recv_type(ws, "homework_status")
            while st["data"].get("state") != "stopped":
                st = await _recv_type(ws, "homework_status")
            assert st["data"]["count"] == 1
    finally:
        await srv.stop()


async def test_websocket_homework_disabled():
    srv, port = await _server(None)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            assert (await _recv_type(ws, "hello"))["data"]["homework"] is False
            await ws.send(json.dumps({"type": "homework_start", "data": {"session_id": "h"}}))
            assert (await _recv_type(ws, "homework_error"))["data"]["code"] == "disabled"
    finally:
        await srv.stop()
