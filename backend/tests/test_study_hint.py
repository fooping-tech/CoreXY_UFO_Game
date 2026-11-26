"""#334: the study mode's finger hint: after the answer check the child shows a problem's number
with the fingers and the tutor (UFOくん API §5, format "tutor", mode "normal") gives a hint for it.
A fake API checks the request built, the retries (401 never, 503 later, 500 once) and that only
the game's message comes back (never the answer)."""

from __future__ import annotations

import asyncio
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
import websockets

from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService
from corexy_ufo_backend.study import StudyConfig, make_adapter
from corexy_ufo_backend.study.errors import StudyAdapterError
from corexy_ufo_backend.study.tutor_adapter import TutorHTTPError, TutorStudyAdapter, hint_history
from corexy_ufo_backend.study_mode import WorksheetCatalog

from test_study_mode import B64

CAT = WorksheetCatalog.load()
JPEG = base64.b64decode(B64)

HINT_REPLY = {"tutor_result": {
    "tutor": {"observation": {"problem_number": 2, "problem_text": "38 + 47", "student_answer": "75",
                              "solution": "38 + 47 = 85", "correct_answer": "85", "answer_status": "incorrect"},
              "diagnosis": {"error_type": "procedural"},
              "guidance": {"action": "give_hint", "hint_level": 1, "message": "一のくらいを もういちど 見てみよう。"}},
    "game": {"action": "give_hint", "target_problem": 2, "hint_level": 1, "message": "一のくらいを もういちど 見てみよう。",
             "need_recapture": False, "visual_effect": "encourage"},
    "corexy": {"speech_text": "一のくらいを もういちど 見てみよう。"}, "notes": []}}


class _Api(BaseHTTPRequestHandler):
    got: list = []
    statuses: list = []  # HTTP statuses to answer with, in turn (then 200 with `reply`)
    reply: dict = HINT_REPLY

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _Api.got.append((self.headers.get("Authorization"), body))
        status = _Api.statuses.pop(0) if _Api.statuses else 200
        out = json.dumps(_Api.reply if status == 200 else {"error": {"message": f"status {status}", "type": "x"}},
                         ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


@pytest.fixture()
def api():
    _Api.got, _Api.statuses, _Api.reply = [], [], HINT_REPLY
    srv = HTTPServer(("127.0.0.1", 0), _Api)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_port}"
    TutorStudyAdapter._breakers.pop(url + "/v1/chat/completions", None)
    yield url
    srv.shutdown()


def adapter(url, waits=(5.0, 10.0, 20.0)):
    slept: list[float] = []
    a = TutorStudyAdapter(url, "tok", grade=3, busy_retry_s=waits, sleep=slept.append, fail_limit=5)
    return a, slept


def test_the_hint_request_names_the_problem_the_history_and_never_reveals(api):
    a, _ = adapter(api)
    history = [{"hint_level": 9, "message": "x" * 300}] + [{"hint_level": 1, "message": f"h{i}"} for i in range(7)] + ["bad"]
    res = a.hint(JPEG, 2, grade=4, history=history, utterance="2ばんが わからない")
    auth, body = _Api.got[-1]
    assert auth == "Bearer tok" and body["model"] == "tutor-ufo"
    content = body["messages"][-1]["content"]
    assert body["messages"][-1]["role"] == "user" and content[0]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert base64.b64decode(content[0]["image_url"]["url"].split(",", 1)[1]) == JPEG
    t = body["tutor"]
    assert t["grade"] == 4 and t["target_problem"] == 2 and t["format"] == "tutor" and t["mode"] == "normal"
    assert t["utterance"] == "2ばんが わからない"
    # §5.2: 6 at most (the last ones), levels 0..3, messages 200 characters at most
    assert len(t["history"]) == 6 and t["history"][-1] == {"hint_level": 1, "message": "h6"}
    assert hint_history(history)[0]["message"] == "h1" and hint_history([{"hint_level": 9, "message": "y"}])[0]["hint_level"] == 3
    assert len(hint_history([{"message": "z" * 300}])[0]["message"]) == 200
    # only the game's words come back: the observation (the answer) stays here
    assert res["message"] == "一のくらいを もういちど 見てみよう。" and res["hint_level"] == 1 and res["target_problem"] == 2
    assert "85" not in json.dumps(res, ensure_ascii=False) and "solution" not in res and "correct_answer" not in res
    with pytest.raises(StudyAdapterError):
        a.hint(JPEG, 0)  # the API knows problems 1..30


def test_a_hint_that_says_the_answer_is_refused(api):
    a, _ = adapter(api)
    leak = json.loads(json.dumps(HINT_REPLY))
    leak["tutor_result"]["game"]["message"] = "こたえは 85 だよ。"
    _Api.reply = leak
    with pytest.raises(StudyAdapterError) as e:
        a.hint(JPEG, 2)
    assert getattr(e.value, "kind", "") == "held_back"
    leak["tutor_result"]["game"]["message"] = "85 になるね。"
    with pytest.raises(StudyAdapterError):
        a.hint(JPEG, 2, answers=["85"])  # the answer read on the print, said as one
    leak["tutor_result"]["game"]["message"] = ""
    with pytest.raises(StudyAdapterError):
        a.hint(JPEG, 2)  # nothing to say


def test_401_is_never_asked_again_503_waits_and_500_once(api):
    a, slept = adapter(api)
    _Api.statuses = [401]
    with pytest.raises(TutorHTTPError) as e:
        a.hint(JPEG, 2)
    assert e.value.status == 401 and e.value.kind == "auth" and len(_Api.got) == 1 and slept == []
    # busy twice, then the hint: asked again after 5 s and 10 s
    _Api.got.clear()
    _Api.statuses = [503, 503]
    assert a.hint(JPEG, 2)["message"] and len(_Api.got) == 3 and slept == [5.0, 10.0]
    # always busy: 4 tries (3 waits), then the game's fallback
    _Api.got.clear()
    slept.clear()
    _Api.statuses = [503] * 9
    with pytest.raises(TutorHTTPError) as e:
        a.hint(JPEG, 2)
    assert e.value.kind == "busy" and len(_Api.got) == 4 and slept == [5.0, 10.0, 20.0]
    assert a.breaker["open_until"] == 0.0  # busy is not a broken link: the tutor is not rested
    # 500: once more only
    _Api.got.clear()
    _Api.statuses = [500]
    assert a.hint(JPEG, 2)["message"] and len(_Api.got) == 2
    _Api.got.clear()
    _Api.statuses = [500, 500, 500]
    with pytest.raises(TutorHTTPError):
        a.hint(JPEG, 2)
    assert len(_Api.got) == 2
    # 400 (a bad request): never again
    _Api.got.clear()
    _Api.statuses = [400]
    with pytest.raises(TutorHTTPError):
        a.hint(JPEG, 2)
    assert len(_Api.got) == 1


def test_no_server_is_an_error_quickly():
    a = TutorStudyAdapter("http://127.0.0.1:9", "", timeout_s=1.0, sleep=lambda s: None)
    TutorStudyAdapter._breakers.pop(a.url, None)
    with pytest.raises(StudyAdapterError):
        a.hint(JPEG, 1)
    TutorStudyAdapter._breakers.pop(a.url, None)


def test_the_busy_waits_come_from_the_config():
    cfg = StudyConfig.from_raw({"study": {"tutor_url": "http://127.0.0.1:9", "tutor_busy_retry_s": [1, 2]}})
    assert cfg.tutor_busy_retry_s == (1.0, 2.0)
    assert StudyConfig.from_raw({"study": {"tutor_busy_retry_s": "x"}}).tutor_busy_retry_s == (5.0, 10.0, 20.0)
    assert make_adapter(cfg, "tutor").busy_retry_s == (1.0, 2.0)


class FakeHinter:
    def __init__(self, fail: Exception | None = None, message: str = "一のくらいを 見てみよう。"):
        self.fail, self.message, self.calls = fail, message, []

    def hint(self, image, target, *, grade=None, history=(), utterance="", answers=()):
        self.calls.append({"target": target, "grade": grade, "history": list(history), "utterance": utterance,
                           "answers": list(answers)})
        if self.fail is not None:
            raise self.fail
        return {"message": self.message, "hint_level": min(len(history) + 1, 3), "action": "give_hint",
                "target_problem": target, "need_recapture": False, "visual_effect": "encourage", "notes": []}


async def test_the_service_answers_with_the_hint_or_an_error_for_the_fallback():
    fh = FakeHinter()
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, hint_factory=lambda: fh)
    sent: list[dict] = []

    async def emit(m):
        sent.append(m)
    assert svc.hint_available
    await svc.hint("h1", B64, 2, emit, history=[{"hint_level": 1, "message": "まえの ヒント"}], worksheet_id="mon-elem_4-01")
    await svc._hint_task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_hint_result" and sent[-1]["request_id"] == "h1"
    assert d["problem"] == 2 and d["message"] == "一のくらいを 見てみよう。" and d["hint_level"] == 2 and d["source"] == "tutor"
    c = fh.calls[-1]
    assert c["target"] == 2 and c["grade"] == 4 and c["utterance"] == "2ばんが わからない"
    assert c["history"] == [{"hint_level": 1, "message": "まえの ヒント"}] and c["answers"]  # the sample's answers held back
    # a real print (#287): its own answers as read, never the sample's
    svc._sheet_factory = lambda: None
    svc.note_sheet([{"number": 2, "correct_answer": "85"}])
    await svc.hint("h2", B64, 2, emit, grade_label="小学3年")
    await svc._hint_task
    assert fh.calls[-1]["answers"] == ["85"] and fh.calls[-1]["grade"] == 3
    # the tutor failed: an error the game falls back on (the worksheet's hints)
    svc._hint_factory = lambda: FakeHinter(TutorHTTPError("busy", 503))
    await svc.hint("h3", B64, 3, emit)
    await svc._hint_task
    assert sent[-1]["type"] == "homework_hint_error" and sent[-1]["data"]["code"] == "busy" and sent[-1]["data"]["problem"] == 3
    for bad in (0, 31):
        with pytest.raises(ValueError):
            await svc.hint("h4", B64, bad, emit)
    with pytest.raises(ValueError):
        await svc.hint("h5", "notjpeg", 2, emit)
    with pytest.raises(ValueError):
        await HomeworkService(HomeworkConfig(enabled=True)).hint("h6", B64, 2, emit)  # no tutor
    await svc.close()


async def test_the_service_times_out_into_the_fallback():
    class Slow(FakeHinter):
        def hint(self, *a, **k):
            import time
            time.sleep(0.3)
            return super().hint(*a, **k)
    svc = HomeworkService(HomeworkConfig(enabled=True, explain_timeout_s=0.05), hint_factory=lambda: Slow())
    sent: list[dict] = []

    async def emit(m):
        sent.append(m)
    await svc.hint("h1", B64, 1, emit)
    await svc._hint_task
    assert sent[-1]["type"] == "homework_hint_error" and sent[-1]["data"]["code"] == "timeout"
    await svc.close()


async def test_over_the_websocket():
    from corexy_ufo_backend.robot.mock_robot import MockRobot
    from corexy_ufo_backend.websocket import GameServer
    fh = FakeHinter()
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, hint_factory=lambda: fh)
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=svc)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]

    async def until(ws, kind):
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 5))
            if m["type"] == kind or m["type"].endswith("error"):
                return m
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await until(ws, "hello")
            assert hello["data"]["homework_hint"] is True
            await ws.send(json.dumps({"type": "homework_hint", "request_id": "sm-hint-1", "data": {
                "image_jpeg_base64": B64, "problem": 3, "history": [{"hint_level": 1, "message": "x"}],
                "worksheet_id": "mon-elem_1-01", "grade_label": ""}}))
            r = await until(ws, "homework_hint_result")
            assert r["request_id"] == "sm-hint-1" and r["data"]["problem"] == 3 and r["data"]["message"]
            assert fh.calls[-1]["history"] == [{"hint_level": 1, "message": "x"}] and fh.calls[-1]["grade"] == 1
            await ws.send(json.dumps({"type": "homework_hint", "request_id": "sm-hint-2", "data": {
                "image_jpeg_base64": B64, "problem": "x"}}))
            e = await until(ws, "homework_hint_result")
            assert e["type"] == "homework_error" and e["request_id"] == "sm-hint-2"
    finally:
        await srv.stop()
        await svc.close()
