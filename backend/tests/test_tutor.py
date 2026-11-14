"""The learning support AI (UFOくん API) for the study mode's explanation, and looking again
when the problem is not in the picture (#104). From the handoff's own tests
(integrations/corexy_ufo/tests), with the game's real explain_prompt / parse_explanation."""

from __future__ import annotations

import asyncio
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import numpy as np
import pytest
import websockets

from corexy_ufo_backend.calibration_store import section
from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService
from corexy_ufo_backend.homework.camera_map import apply
from corexy_ufo_backend.study import StudyConfig, make_adapter
from corexy_ufo_backend.study.errors import StudyAdapterError
from corexy_ufo_backend.study.tutor_adapter import TutorStudyAdapter
from corexy_ufo_backend.study_mode import WorksheetCatalog
from corexy_ufo_backend.study_mode.explain import explain_prompt, navigate_of, parse_explanation
from corexy_ufo_backend.study_mode.navigation import (FocusCalibration, NavigationError, estimate_A, phase_shift,
                                                      plan_relative, xy_to_uv)

from test_camera_map import CAM, H_TRUE, calibrated
from test_homework_advice import _cmd, _server, ready_robot  # noqa: F401
from test_study_mode import B64

CAT = WorksheetCatalog.load()


def rot(deg, sx=1.0, sy=1.0):
    t = np.radians(deg)
    return np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]]) @ np.diag([sx, sy])


# ---------------------------------------------------------------- navigation (numbers only)
def test_offset_to_mm_round_trip(tmp_path):
    A = 8.0 * rot(90) @ np.diag([1, -1])  # 1 mm = 8 px, the camera turned 90 degrees and flipped
    p = tmp_path / "focus.json"
    p.write_text(json.dumps({"heights": {"10cm": {"A": A.tolist(), "image": [640, 480]}}}))
    cal = FocusCalibration.load(p)
    d = cal.offset_to_mm([250, -100], "10cm")
    assert np.allclose(-A @ np.array(d), [-160, 48], atol=1.0)  # the problem comes to the centre
    with pytest.raises(NavigationError):
        cal.offset_to_mm([0, 0], "5cm")  # no calibration at that height


def test_focus_calibration_lives_in_calibration_json(tmp_path):
    sec = section(tmp_path, "focus_camera")
    sec.write_text(json.dumps({"heights": {"10cm": {"A": [[8, 0], [0, 8]], "image": [640, 480]}}}))
    section(tmp_path, "z").write_text(json.dumps({"counts_per_unit": 80.0, "sign": 1}))
    assert FocusCalibration.load(sec).offset_to_mm([0, 500], "10cm") == (0.0, 30.0)
    assert set(json.loads((tmp_path / "calibration.json").read_text())) >= {"z", "focus_camera"}


def test_plan_relative_limits():
    assert plan_relative((100, 100), (20, -10)) == (120, 90)
    for cur, d in (((100, 100), (80, 0)), ((380, 100), (20, 0)), ((100, 100), (1, 1)),
                   ((100, 100), (float("nan"), 0))):
        with pytest.raises(NavigationError):
            plan_relative(cur, d)  # too far / outside / too small (already in view) / not a number


def test_xy_to_uv_inverts_the_homography():
    u, v = 0.37, 0.61
    x, y = apply(H_TRUE, u, v)
    uu, vv = xy_to_uv(np.linalg.inv(H_TRUE), x, y)
    assert abs(uu - u) < 1e-5 and abs(vv - v) < 1e-5


def test_calibration_recovers_A():
    rng = np.random.default_rng(0)
    big = np.cumsum(np.cumsum(rng.random((400, 400)), 0), 1)
    big = (big - big.min()) / np.ptp(big) * 255
    A_true = 6.0 * rot(-30) @ np.diag([1, -1])

    def view(cx, cy):
        return big[cy - 100:cy + 100, cx - 100:cx + 100]
    base = view(200, 200)
    moves, shifts = [], []
    for d in ([3.0, 0.0], [0.0, 3.0]):
        s = -A_true @ np.array(d)
        moves.append(tuple(d))
        shifts.append(phase_shift(base, view(200 - round(s[0]), 200 - round(s[1]))))
    assert np.allclose(estimate_A(moves, shifts), A_true, atol=0.6)


def test_navigate_is_checked_before_it_reaches_the_game():
    assert navigate_of({"navigate": {"kind": "move", "d_mm": [0, 45], "offset": [0, 750]}}) == \
        {"kind": "move", "d_mm": [0.0, 45.0], "offset": [0.0, 750.0]}
    assert navigate_of({"navigate": {"kind": "move", "d_mm": ["x", 1]}}) == {"kind": "move"}  # no d_mm: no motion
    assert navigate_of({"navigate": {"kind": "move", "d_mm": [float("inf"), 1]}}) == {"kind": "move"}
    assert navigate_of({"navigate": {"kind": "fly", "d_mm": [1, 1]}}) == {}
    assert navigate_of({}) == {}


def test_grade_from_the_game_prompt():
    from corexy_ufo_backend.study.tutor_adapter import grade_in_prompt
    cases = {"小学4年": 4, "中学1年": 6, "保育園 年長": 1, "": 3}
    for label, want in cases.items():
        text = explain_prompt(3, label, ["10cm"], {"prompt": "2年で 5 cm のびる木"})
        assert grade_in_prompt(text, 3) == want, label


# ---------------------------------------------------------------- the adapter (a fake API)
class _Fake(BaseHTTPRequestHandler):
    got: list = []
    reply: dict = {}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _Fake.got.append((self.headers.get("Authorization"), body))
        out = json.dumps(_Fake.reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


@pytest.fixture()
def fake_api():
    srv = HTTPServer(("127.0.0.1", 0), _Fake)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_port}"
    TutorStudyAdapter._breakers.pop(url + "/v1/chat/completions", None)
    yield url
    srv.shutdown()


MOVE_REPLY = {"tutor_result": {
    "game": {"action": "request_recapture", "message": "3ばんを さがしに いくね！"},
    "corexy": {"problem_number": 3, "recognized_problem": "", "confidence": 0.0, "hint": "", "explanation": "",
               "speech_text": "3ばんを さがしに いくね！ 手を はなして まっててね。", "needs_confirmation": True},
    "navigate": {"kind": "move", "direction": "down", "offset": [0, 750]}}}
HINT_REPLY = {"tutor_result": {"game": {"action": "give_hint", "message": "九九を思い出そう"},
                               "corexy": {"problem_number": 3, "recognized_problem": "24÷3", "confidence": 0.8,
                                          "hint": "九九を思い出そう", "explanation": "", "speech_text": "九九を思い出そう",
                                          "needs_confirmation": False}}}


def test_adapter_with_the_game_prompt(fake_api, tmp_path):
    imgs = []
    for role in ("overview", "10cm", "5cm", "landing"):
        p = tmp_path / f"{role}.jpg"
        p.write_bytes(role.encode())
        imgs.append(p)
    cal = section(tmp_path, "focus_camera")
    cal.write_text(json.dumps({"heights": {"10cm": {"A": [[8, 0], [0, 8]], "image": [640, 480]}}}))
    _Fake.got.clear()
    _Fake.reply = MOVE_REPLY
    ad = TutorStudyAdapter(fake_api, "test-token", focus_calibration=cal)
    chunks: list[str] = []

    async def on_delta(s):
        chunks.append(s)
    text = explain_prompt(3, "小学3年", ["overview", "10cm", "5cm", "landing"], None)
    asyncio.run(ad.ask("t", text, imgs[-1], on_delta, imgs[:-1]))
    auth, body = _Fake.got[0]
    assert auth == "Bearer test-token"
    assert body["tutor"]["target_problem"] is None and body["tutor"]["utterance"] == "3ばんが わからない"
    assert body["tutor"]["grade"] == 3
    assert body["messages"][0]["content"][0]["image_url"]["url"].endswith("MTBjbQ==")  # the 10cm image
    parsed = parse_explanation("".join(chunks), 3)  # the game's own parser
    assert parsed["needs_confirmation"] and parsed["speech_text"].startswith("3ばん")
    assert parsed["navigate"]["kind"] == "move" and parsed["navigate"]["d_mm"] == [0.0, 45.0]  # 360 px / 8


def test_without_the_arm_camera_calibration_there_is_no_motion(fake_api, tmp_path):
    img = tmp_path / "a.jpg"
    img.write_bytes(b"x")
    _Fake.reply = MOVE_REPLY
    broken = section(tmp_path, "focus_camera")
    broken.write_text(json.dumps({"heights": {"10cm": {"A": [[0, 0], [0, 0]], "image": [640, 480]}}}))
    for cal in (None, section(tmp_path / "none", "focus_camera"), broken):
        chunks: list[str] = []

        async def on_delta(s):
            chunks.append(s)
        ad = TutorStudyAdapter(fake_api, "t", focus_calibration=cal)
        asyncio.run(ad.ask("t", explain_prompt(3, "", ["10cm"], None), img, on_delta))
        nav = parse_explanation("".join(chunks), 3)["navigate"]
        assert nav["kind"] == "move" and "d_mm" not in nav


def test_adapter_normal_explanation(fake_api, tmp_path):
    img = tmp_path / "a.jpg"
    img.write_bytes(b"x")
    _Fake.reply = HINT_REPLY
    chunks: list[str] = []

    async def on_delta(s):
        chunks.append(s)
    asyncio.run(TutorStudyAdapter(fake_api, "t").ask("t", explain_prompt(3, "", ["landing"], None), img, on_delta))
    parsed = parse_explanation("".join(chunks), 3)
    assert parsed["hint"] == "九九を思い出そう" and not parsed["needs_confirmation"] and "navigate" not in parsed


def test_breaker_shared_across_new_adapters(tmp_path):
    """The game makes a new adapter per explanation: after two failures in a row, even a new one
    refuses at once (the worksheet's hints meanwhile)."""
    img = tmp_path / "a.jpg"
    img.write_bytes(b"x")
    url = "http://127.0.0.1:9"  # nothing listens there
    TutorStudyAdapter._breakers.pop(url + "/v1/chat/completions", None)
    text = explain_prompt(3, "", ["landing"], None)

    async def on_delta(s):
        pass
    for _ in range(2):
        with pytest.raises(StudyAdapterError):
            asyncio.run(TutorStudyAdapter(url, "t", timeout_s=1).ask("t", text, img, on_delta))
    t0 = time.monotonic()
    with pytest.raises(StudyAdapterError, match="休止中"):
        asyncio.run(TutorStudyAdapter(url, "t", timeout_s=1).ask("t", text, img, on_delta))
    assert time.monotonic() - t0 < 0.5
    assert TutorStudyAdapter(url, "t").health()["ok"] is False


# ---------------------------------------------------------------- config: only the explanation goes there
def _cfg(tmp_path: Path, url: str, token: str | None = "secret-token") -> StudyConfig:
    if token is not None:
        (tmp_path / "config" / "secrets").mkdir(parents=True, exist_ok=True)
        (tmp_path / "config" / "secrets" / "tutor_token.txt").write_text(token + "\n")
    raw = {"study": {"provider": "claude", "explain_provider": "tutor", "tutor_url": url}}
    from dataclasses import replace
    return replace(StudyConfig.from_raw(raw), root=str(tmp_path))


def test_make_adapter_reads_the_token_file_under_the_repository(tmp_path, fake_api):
    cfg = _cfg(tmp_path, fake_api)
    ad = make_adapter(cfg, "tutor")
    assert isinstance(ad, TutorStudyAdapter) and ad.token == "secret-token"
    assert make_adapter(cfg).__class__.__name__ == "ClaudeCodeStudyAdapter"  # provider stays for the rest
    assert "secret-token" not in repr(cfg)
    with pytest.raises(StudyAdapterError, match="トークン"):
        make_adapter(_cfg(tmp_path / "x", fake_api, token=None), "tutor")
    with pytest.raises(StudyAdapterError, match="URL"):
        make_adapter(_cfg(tmp_path, ""), "tutor")


def _explain_service(tmp_path, url, token="t"):
    cfg = _cfg(tmp_path, url, token)
    advice = []
    svc = HomeworkService(HomeworkConfig(enabled=True), advice_factory=lambda: advice.append(1),
                          explain_factory=lambda: make_adapter(cfg, "tutor"), worksheets=CAT)
    return svc, advice


async def _explain(svc):
    sent = []

    async def emit(m):
        sent.append(m)
    imgs = [{"role": r, "image_jpeg_base64": B64} for r in ("overview", "10cm", "5cm", "landing")]
    await svc.explain("e1", imgs, 3, "小学4年", "mon-elem_4-01", emit)
    await svc._explain_task
    return sent[-1]


async def test_the_explanation_goes_to_the_tutor_and_nothing_else(tmp_path, fake_api):
    _Fake.reply = HINT_REPLY
    svc, advice = _explain_service(tmp_path, fake_api)
    m = await _explain(svc)
    assert m["type"] == "homework_explain_result" and m["data"]["hint"] == "九九を思い出そう"
    assert advice == []  # the advice's factory (Claude Code / Codex) was not used


async def test_no_tutor_falls_back_to_the_worksheet_hints(tmp_path):
    url = "http://127.0.0.1:9"
    TutorStudyAdapter._breakers.pop(url + "/v1/chat/completions", None)
    for svc, _ in (_explain_service(tmp_path, url), _explain_service(tmp_path / "notoken", url, token=None)):
        m = await _explain(svc)
        assert m["type"] == "homework_explain_error" and m["data"]["fallback"]["source"] == "worksheet"


# ---------------------------------------------------------------- homework_navigate (never moves)
async def test_navigate_on_the_mock_robot_in_mm():
    r = await ready_robot()
    srv, port = await _server(r)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            before = r.snapshot()
            ok = await _cmd(ws, "homework_navigate", {"xy": [150, 100], "d_mm": [0, 45]}, rid="n1")
            assert ok["type"] == "ack" and ok["data"]["xy"] == [150, 145] and ok["data"]["from"] == [150, 100]
            for d, why in (([0, 70], "大きすぎ"), ([1, 1], "小さすぎ"), ([0, 40], "可動範囲")):
                xy = [150, 180] if why == "可動範囲" else [150, 100]
                m = await _cmd(ws, "homework_navigate", {"xy": xy, "d_mm": d}, rid="n-" + why)
                assert m["type"] == "nack" and why in m["data"]["reason"], m
            big = await _cmd(ws, "homework_navigate", {"xy": [150, 100], "d_mm": [0, 70], "max_step_mm": 500}, rid="n3")
            assert big["type"] == "nack"  # the 60 mm cap is not the game's to raise
            bad = await _cmd(ws, "homework_navigate", {"xy": [150, 100], "d_mm": "down"}, rid="n4")
            assert bad["type"] == "nack"
            after = r.snapshot()
            assert (after.x, after.y, after.z) == (before.x, before.y, before.z) and not srv.approach.active
    finally:
        await srv.stop()


async def test_navigate_in_the_overview_image_needs_the_camera_calibration():
    r = await ready_robot()
    srv, port = await _server(r)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            none = await _cmd(ws, "homework_navigate", {"u": 0.5, "v": 0.5, "camera": CAM, "d_mm": [0, 20]}, rid="a")
            assert none["type"] == "nack"  # no calibration: nowhere to go
            srv.camera_map = calibrated()
            m = await _cmd(ws, "homework_navigate", {"u": 0.5, "v": 0.5, "camera": CAM, "d_mm": [0, 20]}, rid="b")
            assert m["type"] == "ack", m
            x0, y0 = apply(H_TRUE, 0.5, 0.5)
            assert np.allclose(m["data"]["from"], [x0, y0], atol=0.05)
            assert np.allclose(apply(H_TRUE, m["data"]["u"], m["data"]["v"]), [x0, y0 + 20], atol=0.05)
            other = dict(CAM, width=640)
            m = await _cmd(ws, "homework_navigate", {"u": 0.5, "v": 0.5, "camera": other, "d_mm": [0, 20]}, rid="c")
            assert m["type"] == "nack" and "camera changed" in m["data"]["reason"]
    finally:
        await srv.stop()


async def test_navigate_in_mm_is_refused_on_the_real_robot():
    r = await ready_robot()
    r.name = "real"
    srv, port = await _server(r)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "homework_navigate", {"xy": [150, 100], "d_mm": [0, 20]}, rid="r")
            assert m["type"] == "nack" and "only for the mock" in m["data"]["reason"]
    finally:
        await srv.stop()
