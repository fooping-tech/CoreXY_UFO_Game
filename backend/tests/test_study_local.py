"""#232: the study mode with the local LLM server only: the watch and the locate read the
worksheet with POST /v1/sheet (a fake reader here), and nothing calls Jev or Claude / Codex."""

from __future__ import annotations

import base64

import cv2
import numpy as np
import pytest

from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService
from corexy_ufo_backend.homework.sheet_watch import (answers_from_sheet, locate_in_sheet, questions_from_sheet,
                                                     reading_from_sheet)
from corexy_ufo_backend.study import StudyConfig
from corexy_ufo_backend.study.sheet_client import SheetError, parse_result, prepare_image
from corexy_ufo_backend.study_mode import WorksheetCatalog

CAT = WorksheetCatalog.load()
WS = CAT.get("mon-elem_1-01")
JPEG = cv2.imencode(".jpg", np.full((240, 320, 3), 200, np.uint8))[1].tobytes()
B64 = base64.b64encode(JPEG).decode()


def prob(n, status, visible="full", box=(100, 100, 900, 300), answer_box=(600, 150, 880, 280)):
    return {"number": n, "answer_status": status, "student_answer": "5", "correct_answer": "7", "visible": visible,
            "box": list(box) if box else None, "answer_box": list(answer_box) if answer_box else None, "notes": []}


# ------------------------------------------------------------------ the rules


def test_answer_states_become_the_watch_questions():
    qs = questions_from_sheet([prob(1, "correct"), prob(2, "blank"), prob(3, "partial")], WS)
    assert qs == [{"number": 1, "filled_prob": 0.95}, {"number": 2, "filled_prob": 0.05},
                  {"number": 3, "filled_prob": 0.5}]
    qs = questions_from_sheet([prob(1, "incorrect"), prob(2, "unreadable"), prob(3, "correct", visible="partial"),
                               prob(9, "correct")], WS)
    assert [q["filled_prob"] for q in qs] == [0.95, None, None]  # unreadable, cut off, not on this sheet: no reading


def test_the_progress_counts_written_problems_and_holds_when_nothing_was_read():
    r = reading_from_sheet([prob(1, "correct"), prob(2, "incorrect"), prob(3, "blank")], WS)
    assert r.progress_pct == pytest.approx(200 / 3) and not r.held
    r = reading_from_sheet([], WS)
    assert r.held and r.held_reason == "not_visible" and r.progress_pct is None
    r = reading_from_sheet([prob(1, "unreadable")], WS)
    assert r.held and r.held_reason == "no_answer"


def test_answers_never_carry_the_right_answer():
    a = answers_from_sheet([prob(1, "incorrect"), prob(8, "correct"), prob(2, "correct", visible="partial")], WS)
    assert a == [{"number": 1, "answer_status": "incorrect", "student_answer": "5", "visible": "full"},
                 {"number": 2, "answer_status": "correct", "student_answer": "5", "visible": "partial"}]


def test_locate_takes_the_answer_box_else_the_problem_box():
    f = locate_in_sheet([prob(2, "blank")], 2)
    assert f["which"] == "answer_box" and f["box"] == [0.6, 0.15, 0.88, 0.28] and (f["u"], f["v"]) == (0.74, 0.215)
    f = locate_in_sheet([prob(2, "blank", answer_box=None)], 2)
    assert f["which"] == "box" and (f["u"], f["v"]) == (0.5, 0.2)
    assert locate_in_sheet([prob(2, "blank")], 3) is None
    assert locate_in_sheet([prob(2, "blank", box=None, answer_box=None)], 2) is None


# ------------------------------------------------------------------ the service


class FakeReader:
    def __init__(self, problems=None, error=None):
        self.problems, self.error, self.calls = problems or [], error, 0

    def read(self, photo, calc=True, crop=True, long_side=1800, on_problem=None):
        self.calls += 1
        self.streamed = on_problem is not None
        if self.error:
            raise self.error
        problems = self.problems
        if on_problem is not None:  # the stream: one by one, maybe stopped early
            got = []
            for p in self.problems:
                got.append(p)
                if on_problem(p):
                    problems = got
                    break
            self.seen = len(problems)
        raw = {"problems": problems, "paper_px": None, "image": {"width": 320, "height": 240}}
        return parse_result(raw, prepare_image(photo))


def nothing_else(*a, **k):
    raise AssertionError("the local study mode called Jev or an assistant")


def local_service(reader):
    return HomeworkService(HomeworkConfig(enabled=True), client_factory=nothing_else, advice_factory=nothing_else,
                           worksheets=CAT, sheet_factory=lambda: reader)


async def test_a_local_study_session_watches_with_the_reader_only():
    reader = FakeReader([prob(1, "correct"), prob(2, "partial"), prob(3, "blank")])
    svc = local_service(reader)
    sent = []

    async def emit(m):
        sent.append(m)
    assert svc.study_local
    await svc.start("s", "mon-elem_1-01")  # no Jev key is needed: client_factory would raise
    assert svc.sessions["s"].client is None
    await svc.frame("s", "r1", B64, emit)
    await svc.sessions["s"].task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_progress" and d["source"] == "sheet"
    assert [q["filled_prob"] for q in d["questions"]] == [0.95, 0.5, 0.05]
    assert d["progress_pct"] == pytest.approx(100 / 3) and not d["held"] and d["worksheet_id"] == "mon-elem_1-01"
    assert "correct_answer" not in str(d["answers"]) and reader.calls == 1
    await svc.close()


async def test_a_local_session_stops_after_refused_tokens():
    svc = local_service(FakeReader(error=SheetError("auth", "トークンが違う", 401)))
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_1-01")
    for i in range(3):
        await svc.frame("s", f"r{i}", B64, emit)
        await svc.sessions["s"].task if "s" in svc.sessions else None
    assert [m["type"] for m in sent] == ["homework_error"] * 3 and sent[-1]["data"].get("stopped")
    assert sent[0]["data"]["code"] == "auth" and "s" not in svc.sessions
    await svc.close()


async def test_a_local_locate_reads_the_problem_box():
    reader = FakeReader([prob(2, "blank"), prob(3, "blank", answer_box=(300, 600, 500, 700))])
    svc = local_service(reader)
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_1-01")
    await svc.locate("s", "l1", "problem", B64, emit, problem=3, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_locate_result" and d["usable"] and d["verified"] and d["source"] == "sheet"
    assert (d["u"], d["v"]) == (0.4, 0.65) and d["problem_number"] == 3 and d["box_kind"] == "answer_box"
    assert reader.streamed and reader.seen == 2  # streamed, and stopped at problem 3
    # a problem the reader does not see: no move
    await svc.locate("s", "l2", "problem", B64, emit, problem=1, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    assert sent[-1]["type"] == "homework_locate_error" and sent[-1]["data"]["code"] == "not_found"
    assert "2, 3" in sent[-1]["data"]["message"]
    # a box as big as the sheet is not trusted
    reader.problems = [prob(1, "blank", answer_box=None, box=(0, 0, 1000, 1000))]
    await svc.locate("s", "l3", "problem", B64, emit, problem=1, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    assert sent[-1]["type"] == "homework_locate_result" and not sent[-1]["data"]["usable"]
    # the reader failing is said, never a move
    reader.error = SheetError("busy", "混んでいる", 503)
    await svc.locate("s", "l4", "problem", B64, emit, problem=1, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    assert sent[-1]["type"] == "homework_locate_error" and sent[-1]["data"]["code"] == "busy"
    await svc.close()


async def test_a_local_study_session_refuses_what_would_go_to_the_cloud():
    """Review on #234: the F1 helper's buttons with the study mode's session id never reach Claude / Jev."""
    svc = local_service(FakeReader([prob(1, "blank")]))
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_1-01")
    for kind in ("stuck", "next"):
        with pytest.raises(ValueError, match="ローカル"):
            await svc.locate("s", "l", kind, B64, emit)
    with pytest.raises(ValueError, match="ローカル"):
        await svc.advise("s", "a", B64, False, emit)
    assert sent == [] and svc._locate_task is None and svc._advice_task is None
    await svc.close()


async def test_without_a_worksheet_the_assistant_watch_still_uses_jev():
    used = []

    class Jev:
        def run(self, jev_input, timeout=30.0):
            used.append(1)
            raise AssertionError("not reached in this test")
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: (used.append("made"), Jev())[1],
                          worksheets=CAT, sheet_factory=lambda: FakeReader())
    await svc.start("helper")  # the F1 panel's homework watch: no worksheet, not the study mode
    assert used == ["made"] and svc.sessions["helper"].client is not None
    await svc.close()


def test_the_setting_is_local_unless_cloud_is_asked_for(tmp_path):
    assert StudyConfig.from_raw({}).ai == "local"
    assert StudyConfig.from_raw({"study": {"ai": "cloud"}}).ai == "cloud"
    assert StudyConfig.from_raw({"study": {"ai": "something"}}).ai == "local"


async def test_the_hello_says_which(monkeypatch):
    import json
    import websockets
    from corexy_ufo_backend.robot.mock_robot import MockRobot
    from corexy_ufo_backend.websocket import GameServer
    for svc, want in ((local_service(FakeReader()), "local"),
                      (HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT), "cloud")):
        robot = MockRobot()
        await robot.connect()
        srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=svc)
        await srv.start()
        port = next(iter(srv._server.sockets)).getsockname()[1]
        try:
            async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
                hello = json.loads(await ws.recv())
                while hello["type"] != "hello":
                    hello = json.loads(await ws.recv())
                assert hello["data"]["study_ai"] == want
        finally:
            await srv.stop()
            await svc.close()
