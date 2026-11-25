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
    # #306: where the problem and its answer box are (the ○ of the check right after the print is found)
    boxes = {"box": [100, 100, 900, 300], "answer_box": [600, 150, 880, 280]}
    assert a == [{"number": 1, "answer_status": "incorrect", "student_answer": "5", "visible": "full", **boxes},
                 {"number": 2, "answer_status": "correct", "student_answer": "5", "visible": "partial", **boxes}]
    assert all("correct_answer" not in x for x in a)


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

    def read(self, photo, calc=True, crop=True, long_side=1800, on_problem=None, deadline_s=None, label=""):
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
    # #244: 20 s by default, the reader told so; a reader that never answers is cut off too
    reader.error = None
    got = {}
    orig = reader.read

    def spy(*a, **k):
        got.update(k)
        return orig(*a, **k)
    reader.read = spy
    await svc.locate("s", "l5", "problem", B64, emit, problem=3, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    assert got["deadline_s"] == 20.0 and got["label"] == "locate 3"

    def hangs(*a, **k):
        import time
        time.sleep(1.5)
    reader.read = hangs
    from dataclasses import replace as _replace
    svc.config = _replace(svc.config, locate_timeout_s=3.0)  # the smallest allowed
    import asyncio as _a
    real_wait_for = _a.wait_for

    async def quick(aw, t):  # 3 s + 5 s of guard is long for a test: cut the guard to 1 s
        return await real_wait_for(aw, 1.0)
    import corexy_ufo_backend.homework.service as hs
    hs.asyncio.wait_for, saved = quick, hs.asyncio.wait_for
    try:
        await svc.locate("s", "l6", "problem", B64, emit, problem=3, worksheet_id="mon-elem_1-01")
        await svc._locate_task
    finally:
        hs.asyncio.wait_for = saved
    assert sent[-1]["type"] == "homework_locate_error" and sent[-1]["data"]["code"] == "timeout"
    assert "混んでいる" in sent[-1]["data"]["message"]
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


async def test_a_real_print_has_its_own_problems():
    """#237: the watch reports every problem the reader saw (not the sample sheet's 1..3), and a
    problem that is not on the sample sheet can still be located."""
    reader = FakeReader([prob(3, "correct"), prob(4, "blank"), prob(5, "partial", visible="partial")])
    svc = local_service(reader)
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_1-01")
    await svc.frame("s", "r", B64, emit)
    await svc.sessions["s"].task
    d = sent[-1]["data"]
    assert [q["number"] for q in d["questions"]] == [3, 4, 5] and d["problem_numbers"] == [3, 4, 5]
    assert [q["filled_prob"] for q in d["questions"]] == [0.95, 0.05, None]
    assert [a["visible"] for a in d["answers"]] == ["full", "full", "partial"]
    reader.problems = [prob(5, "blank", answer_box=(100, 800, 300, 900))]
    await svc.locate("s", "l", "problem", B64, emit, problem=5, worksheet_id="mon-elem_1-01")
    await svc._locate_task
    assert sent[-1]["type"] == "homework_locate_result" and sent[-1]["data"]["problem_number"] == 5
    assert questions_from_sheet([prob(7, "correct"), prob(2, "blank")], None) == [
        {"number": 2, "filled_prob": 0.05}, {"number": 7, "filled_prob": 0.95}]
    await svc.close()


class PromptSpy:
    """An explanation adapter that keeps the question and then fails (so a fallback would show)."""

    def __init__(self):
        self.prompt = ""

    async def start_session(self, workdir, instructions):
        return "t"

    async def ask(self, thread_id, text, image_path, on_delta, more_images=()):
        self.prompt = text
        raise RuntimeError("つながらない")

    async def close_session(self, thread_id):
        pass

    async def close(self):
        pass


async def test_a_real_print_never_gets_the_sample_sheets_problems():
    """#287: with the local reader the sheet on the desk is a real print: the sample sheet's text,
    hints and answer (小学3年 2: "56 ÷ 7") go nowhere: not to the explanation, its fallback or a locate."""
    sample = CAT.get("mon-elem_3-01")
    two = WorksheetCatalog.problem(sample, 2)
    spy = PromptSpy()
    reader = FakeReader([prob(2, "incorrect", answer_box=(300, 600, 500, 700))])
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=nothing_else, advice_factory=nothing_else,
                          explain_factory=lambda: spy, worksheets=CAT, sheet_factory=lambda: reader)
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_3-01")
    assert svc._problem(sample, 2) == {"number": 2, "prompt": "", "description_en": "problem 2"}
    assert svc._problem(sample, 2, known_only=True) is None
    await svc.explain("e", [{"role": "10cm", "image_jpeg_base64": B64}], 2, "", "mon-elem_3-01", emit)
    await svc._explain_task
    assert spy.prompt and two["prompt"] not in spy.prompt and "56" not in spy.prompt
    assert "小学3年" in spy.prompt  # the grade set still goes
    err = sent[-1]
    assert err["type"] == "homework_explain_error" and "fallback" not in err["data"]  # the game's own (any problem)
    await svc.locate("s", "l", "problem", B64, emit, problem=2, worksheet_id="mon-elem_3-01")
    await svc._locate_task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_locate_result" and d["description_en"] == "problem 2"
    assert svc.read_answers == ["7"]  # the print's own answer, read by the locate (prob() says 7)
    # the cloud (the sample sheet printed): its problem as before
    cloud = HomeworkService(HomeworkConfig(enabled=True), client_factory=nothing_else, advice_factory=nothing_else,
                            worksheets=CAT)
    assert cloud._problem(sample, 2)["prompt"] == two["prompt"]
    await svc.close()
    await cloud.close()


async def test_the_watch_and_the_locate_pass_the_roi_to_the_reader():
    """#298: the game sends the whole frame with where the sheet lies; the reader gets it."""
    reader = FakeReader([prob(1, "correct"), prob(3, "blank")])
    got = []
    orig = reader.read

    def spy(*a, **k):
        got.append(k.get("roi"))
        return orig(*a, **{x: v for x, v in k.items() if x != "roi"})
    reader.read = spy
    svc = local_service(reader)
    sent = []

    async def emit(m):
        sent.append(m)
    await svc.start("s", "mon-elem_1-01")
    await svc.frame("s", "r1", B64, emit, roi=[100, 0, 900, 1000])
    await svc.sessions["s"].task
    await svc.locate("s", "l1", "problem", B64, emit, problem=3, worksheet_id="mon-elem_1-01", roi=[100, 0, 900, 1000])
    await svc._locate_task
    await svc.frame("s", "r2", B64, emit)  # none: the reader is called as before
    await svc.sessions["s"].task
    assert got == [[100, 0, 900, 1000], [100, 0, 900, 1000], None]
    with pytest.raises(ValueError):
        await svc.frame("s", "r3", B64, emit, roi=[0, 0, 10, 10])
    await svc.close()
