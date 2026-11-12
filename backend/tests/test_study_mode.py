"""Study mode (#86): worksheets, per-problem watch, capture heights, staged capture,
the structured explanation and the magnet-jig tidy-up (all against the mock robot)."""

from __future__ import annotations

import asyncio
import base64
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
import websockets

from corexy_ufo_backend.config import REPO_ROOT, BackendConfig, RobotLimits
from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService, LocateParams
from corexy_ufo_backend.homework.approach import ApproachParams, ApproachPhase, ApproachSequencer
from corexy_ufo_backend.homework.camera_map import apply
from corexy_ufo_backend.homework.jev import JevResult
from corexy_ufo_backend.homework.questions import add_questions, parse_questions
from corexy_ufo_backend.homework.progress import build_input
from corexy_ufo_backend.robot import RobotCommandError
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.sequence.cleanup import CleanupPhase, CleanupProfile, CleanupSequencer, segment_hits_rect
from corexy_ufo_backend.study_mode import (HeightCalibration, HeightError, WorksheetCatalog, fallback_explanation,
                                           parse_explanation, split_speech)
from corexy_ufo_backend.study_mode.explain import ExplainError, compare_with_known, explain_prompt, similarity
from corexy_ufo_backend.study_mode.worksheets import box_in_image, paper_to_image, point_inside
from corexy_ufo_backend.websocket import GameServer

RAW = json.loads((REPO_ROOT / "config" / "game_config.json").read_text(encoding="utf-8"))
CAT = WorksheetCatalog.load()
LIMITS = RobotLimits()


def jpeg(width: int = 640, height: int = 480, tag: bytes = b"") -> bytes:
    app0 = b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0\x00\x11\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big") + b"\x03" + b"\x00" * 9
    return b"\xff\xd8" + app0 + sof + b"\xff\xda\x00\x02" + tag + b"\xff\xd9"


B64 = base64.b64encode(jpeg()).decode()


# ------------------------------------------------------------------ worksheets
def test_every_grade_has_three_problems_with_the_challenge_last():
    assert CAT.problems() == []
    assert len(CAT.grades) == 12
    labels = [g["label"] for g in CAT.grades]
    assert labels[:3] == ["保育園 年少", "保育園 年中", "保育園 年長"] and labels[-1] == "中学3年"
    for g in CAT.grades:
        ws = CAT.for_grade(g["id"])
        probs = ws["problems"]
        assert [p["number"] for p in probs] == [1, 2, 3]
        assert [p["difficulty"] for p in probs] == ["easy", "easy", "challenge"]
        assert ws["help_problem"] == 3
        for p in probs:
            assert p["answer"] and p["solution"] and len(p["hints"]) >= 2 and p["description_en"]
            x0, y0, x1, y1 = p["answer_box_mm"]
            r = p["region_mm"]
            assert r[0] <= x0 < x1 <= r[2] and r[1] <= y0 < y1 <= r[3]  # the answer box is inside its problem
    for g in ("nursery_1", "nursery_2", "nursery_3"):  # no reading needed: pictures, shapes, counts
        assert CAT.for_grade(g)["reading"] == "picture"
        assert all(p["figure"] is not None for p in CAT.for_grade(g)["problems"])


def test_generated_files_are_up_to_date():
    r = subprocess.run([sys.executable, str(REPO_ROOT / "tools" / "build_worksheets.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    svg = (REPO_ROOT / "docs" / "worksheets" / "mon-elem_3-01.svg").read_text(encoding="utf-8")
    assert 'width="210.0mm" height="297.0mm"' in svg and svg.count('fill="#000"') == 4  # A4, 4 corner marks


def test_page_marks_map_a_problem_into_the_image():
    # a made-up camera: page mm -> image, rotated a little and in perspective
    true_h = np.array([[0.0040, 0.0003, 0.08], [-0.0002, 0.0030, 0.05], [0.0001, 0.0002, 1.0]])
    marks = {k: apply(true_h, *c) for k, c in CAT.mark_centres().items()}
    h = paper_to_image(CAT, marks)
    ws = CAT.for_grade("elem_2")
    region = box_in_image(h, ws["problems"][2]["region_mm"])
    cx, cy = apply(true_h, 105.0, 52 + 76 * 2 + 35)  # the middle of problem 3 on the page
    assert point_inside(region, cx, cy)
    ox, oy = apply(true_h, 105.0, 52 + 35)  # problem 1 is elsewhere
    assert not point_inside(region, ox, oy)


# ------------------------------------------------------------------ per-problem watch
def test_one_jev_call_asks_about_every_answer_box():
    ws = CAT.for_grade("elem_1")
    inp = add_questions(build_input("AAAA"), ws)
    assert set(inp["questions"]) == {"visible", "occluded", "progress", "answer_1", "answer_2", "answer_3"}
    assert "3 + 4" in inp["questions"]["answer_1"]["instructions"]
    out = {"answers": {"answer_1": {"type": "noul", "noul": 0.9}, "answer_2": {"type": "noul", "noul": 0.2}}}
    assert parse_questions(out, ws) == [{"number": 1, "filled_prob": 0.9}, {"number": 2, "filled_prob": 0.2},
                                        {"number": 3, "filled_prob": None}]


def _progress_output(q):
    probs = {str(i): 0.0 for i in range(6)}
    probs["2"] = 1.0
    answers = {"visible": {"type": "noul", "noul": 0.95}, "occluded": {"type": "noul", "noul": 0.05},
               "progress": {"type": "score", "probabilities": probs}}
    for i, v in enumerate(q):
        answers[f"answer_{i + 1}"] = {"type": "noul", "noul": v}
    return {"answers": answers, "usage": {"input_tokens": 10, "output_tokens": 0}}


async def test_session_with_a_worksheet_reports_each_problem():
    seen = []

    class Fake:
        def run(self, jev_input, timeout=30.0):
            seen.append(sorted(jev_input["questions"]))
            return JevResult(output=_progress_output([0.9, 0.1, 0.5]), latency_s=0.1)

    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=Fake, worksheets=CAT)
    sent = []

    async def emit(m):
        sent.append(m)

    st = await svc.start("s", "mon-elem_1-01")
    assert st["worksheet_id"] == "mon-elem_1-01"
    await svc.frame("s", "r", B64, emit)
    await svc.sessions["s"].task
    d = sent[-1]["data"]
    assert "answer_3" in seen[0]
    assert [q["filled_prob"] for q in d["questions"]] == [0.9, 0.1, 0.5] and d["worksheet_id"] == "mon-elem_1-01"
    with pytest.raises(ValueError):
        await svc.start("t", "no-such-sheet")
    await svc.close()


# ------------------------------------------------------------------ capture heights
def test_real_heights_are_refused_until_measured_and_confirmed():
    real = HeightCalibration.from_raw(RAW, "real")
    with pytest.raises(HeightError, match="not measured"):
        real.stages(LIMITS)
    measured = HeightCalibration(z_desk_tip=20, z_per_cm=4, camera_offset_cm=3, landing_tip_cm=1.5, profile="real")
    with pytest.raises(HeightError, match="not confirmed"):
        measured.stages(LIMITS)
    st = HeightCalibration.from_raw(RAW, "dry_run").stages(LIMITS)
    assert [s.name for s in st] == ["10cm", "5cm", "landing"]
    assert st[0].z > st[1].z > st[2].z  # going down (z_up_is_positive)
    assert st[0].z == pytest.approx(20 + 7 * 4) and st[1].z == pytest.approx(20 + 2 * 4)


def test_landing_contact_needs_an_explicit_allowance_and_limits_hold():
    touch = HeightCalibration(z_desk_tip=20, z_per_cm=4, camera_offset_cm=3, landing_tip_cm=0.0, profile="dry_run")
    with pytest.raises(HeightError, match="touches"):
        touch.stages(LIMITS)
    ok = HeightCalibration(z_desk_tip=20, z_per_cm=4, camera_offset_cm=3, landing_tip_cm=0.0,
                           allow_landing_contact=True, profile="dry_run")
    assert ok.stages(LIMITS)[-1].z == pytest.approx(20)
    with pytest.raises(HeightError, match="outside"):
        HeightCalibration(z_desk_tip=80, z_per_cm=4, camera_offset_cm=3, landing_tip_cm=1.5,
                          profile="dry_run").stages(LIMITS)
    with pytest.raises(HeightError, match="claw tips"):  # camera 5 cm with a 4.5 cm offset: tips 0.5 cm
        HeightCalibration(z_desk_tip=20, z_per_cm=4, camera_offset_cm=4.5, landing_tip_cm=0.2,
                          profile="dry_run").stages(LIMITS)
    down = RobotLimits(z_up_is_positive=False)
    st = HeightCalibration(z_desk_tip=80, z_per_cm=4, camera_offset_cm=3, landing_tip_cm=1.5,
                           profile="dry_run").stages(down)
    assert st[0].z < st[1].z < st[2].z  # smaller Z = higher


# ------------------------------------------------------------------ explanation
def test_explanation_json_is_parsed_and_checked_against_the_worksheet():
    text = ('前置き {"problem_number": 3, "recognized_problem": "45cm の テープを 4本 つなぎます", '
            '"confidence": 1.7, "hint": "図をかこう", "explanation": "1. 4本の長さ", "speech_text": "", '
            '"needs_confirmation": false}')
    r = parse_explanation(text, 3)
    assert r["confidence"] == 1.0 and r["speech_text"] == "図をかこう" and not r["needs_confirmation"]
    known = CAT.problem(CAT.for_grade("elem_3"), 3)["prompt"]
    assert compare_with_known(r, known)["matches_worksheet"]
    other = compare_with_known({**r, "recognized_problem": "7 × 6 ="}, known)
    assert not other["matches_worksheet"] and other["needs_confirmation"]
    assert parse_explanation(text.replace('"problem_number": 3', '"problem_number": 2'), 3)["needs_confirmation"]
    with pytest.raises(ExplainError):
        parse_explanation("読めませんでした", 3)
    assert similarity("3 + 4 =", "３＋４＝") == 1.0


def test_fallback_and_speech_lines():
    p = CAT.problem(CAT.for_grade("elem_4"), 3)
    fb = fallback_explanation(p, 3, "AI なし")
    assert fb["source"] == "worksheet" and fb["hint"] == p["hints"][0] and p["answer"] not in fb["speech_text"]
    lines = split_speech("なるほど、ここが難しいんだね！こんなふうに考えてみよう。" + "あ" * 90 + "。", 40)
    assert lines[0] == "なるほど、ここが難しいんだね！" and all(len(x) <= 40 for x in lines)
    prompt = explain_prompt(3, "小学3年", ["overview", "10cm", "5cm", "landing"], {"prompt": "45cm の テープ"})
    assert "4 枚" in prompt and "10cm 上" in prompt and "45cm の テープ" in prompt and "JSON" in prompt


class FakeAdapter:
    def __init__(self, answer: str = "", fail: bool = False):
        self.answer, self.fail = answer, fail
        self.images: list[Path] = []
        self.prompt = ""

    async def start_session(self, workdir, instructions):
        return "t"

    async def ask(self, thread_id, text, image_path, on_delta, more_images=()):
        self.images = [*more_images, image_path]
        self.prompt = text
        if self.fail:
            raise RuntimeError("CLI がありません")
        await on_delta(self.answer)
        return "turn"

    async def close_session(self, thread_id):
        pass

    async def close(self):
        pass


async def test_explain_sends_every_image_in_one_question_and_falls_back():
    answer = json.dumps({"problem_number": 3, "recognized_problem": "長さ 48m の 道 に 6m おき に 木",
                         "confidence": 0.9, "hint": "間の数を考えよう", "explanation": "1. 間 2. 木",
                         "speech_text": "なるほど、ここが難しいんだね！間がいくつあるか考えよう。",
                         "needs_confirmation": False}, ensure_ascii=False)
    adapter = FakeAdapter(answer)
    svc = HomeworkService(HomeworkConfig(enabled=True), advice_factory=lambda: adapter, worksheets=CAT)
    sent = []

    async def emit(m):
        sent.append(m)

    imgs = [{"role": r, "image_jpeg_base64": B64} for r in ("overview", "10cm", "5cm", "landing")]
    await svc.explain("e1", imgs, 3, "", "mon-elem_4-01", emit)
    await svc._explain_task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_explain_result" and len(adapter.images) == 4
    assert [p.name.split("-", 1)[1] for p in adapter.images] == ["overview.jpg", "10cm.jpg", "5cm.jpg", "landing.jpg"]
    assert d["matches_worksheet"] and d["speech_lines"][0] == "なるほど、ここが難しいんだね！"
    failing = HomeworkService(HomeworkConfig(enabled=True), advice_factory=lambda: FakeAdapter(fail=True),
                              worksheets=CAT)
    await failing.explain("e2", imgs, 3, "", "mon-elem_4-01", emit)
    await failing._explain_task
    assert sent[-1]["type"] == "homework_explain_error"
    assert sent[-1]["data"]["fallback"]["source"] == "worksheet" and "CLI" in sent[-1]["data"]["message"]
    with pytest.raises(ValueError):
        await svc.explain("e3", [], 3, "", "", emit)


async def test_locate_a_known_problem_checks_the_page_marks():
    true_h = np.array([[0.0040, 0.0, 0.05], [0.0, 0.0030, 0.03], [0.0, 0.0, 1.0]])
    ws = CAT.for_grade("elem_3")
    region = box_in_image(true_h, ws["problems"][2]["answer_box_mm"])
    w, h = 640, 480

    def mark_box(k):
        u, v = apply(true_h, *CAT.mark_centres()[k])
        return {"type": "box", "box": {"left": u - 0.01, "right": u + 0.01, "top": v - 0.01, "bottom": v + 0.01}}

    class Jev:
        def __init__(self, with_marks=True):
            self.with_marks = with_marks

        def run(self, jev_input, timeout=30.0):
            assert "mark_tl" in jev_input["questions"] and "45cm" not in jev_input["questions"]["box"]["instructions"]
            answers = {"box": {"type": "box", "confidence": 0.9, "box": {
                "left": region[0], "top": region[1], "right": region[2], "bottom": region[3]}}}
            if self.with_marks:
                answers.update({f"mark_{k}": mark_box(k) for k in ("tl", "tr", "bl", "br")})
            return JevResult(output={"answers": answers, "usage": {}}, latency_s=0.1)

    def claude(box):
        return json.dumps({"found": True, "problem": "問題3", "description_en": "x",
                           "box": [box[0] * w, box[1] * h, box[2] * w, box[3] * h]})

    async def run(adapter_answer, jev):
        svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: jev,
                              advice_factory=lambda: FakeAdapter(adapter_answer), worksheets=CAT,
                              locate=LocateParams())
        sent = []

        async def emit(m):
            sent.append(m)
        await svc.locate("none", "L", "problem", base64.b64encode(jpeg(w, h)).decode(), emit, problem=3,
                         worksheet_id=ws["worksheet_id"])
        await svc._locate_task
        return sent[-1]

    good = await run(claude(region), Jev())
    assert good["type"] == "homework_locate_result" and good["data"]["usable"]
    assert good["data"]["page_check"]["agrees"] is True and good["data"]["problem_number"] == 3
    # Claude points at problem 1 and Jev agrees with it, but the page marks say problem 3 is elsewhere
    wrong = box_in_image(true_h, ws["problems"][0]["answer_box_mm"])

    class JevWrong(Jev):
        def run(self, jev_input, timeout=30.0):
            r = super().run(jev_input, timeout)
            r.output["answers"]["box"]["box"] = {"left": wrong[0], "top": wrong[1], "right": wrong[2],
                                                 "bottom": wrong[3]}
            return r
    bad = await run(claude(wrong), JevWrong())
    assert bad["data"]["verified"] and not bad["data"]["usable"] and "基準マーク" in bad["data"]["reason"]
    unmarked = await run(claude(region), Jev(with_marks=False))
    assert unmarked["data"]["usable"] and unmarked["data"]["page_check"]["agrees"] is None


# ------------------------------------------------------------------ the robot
_TICKERS: list[asyncio.Task] = []


@pytest.fixture(autouse=True)
async def _stop_tickers():
    yield
    for t in _TICKERS:
        t.cancel()
    await asyncio.gather(*_TICKERS, return_exceptions=True)
    _TICKERS.clear()


async def ready_robot() -> MockRobot:
    r = MockRobot(speed_xy=3000.0, accel_xy=60000.0, speed_z=2000.0, accel_z=40000.0)

    async def ticker():
        while True:
            await r.tick()
            await asyncio.sleep(0.005)
    _TICKERS.append(asyncio.get_running_loop().create_task(ticker()))
    await r.connect()
    await r.enable_motors(True)
    await r.home()
    r._homing_until = 0.0  # no 1.5 s homing animation in the tests
    await r.move_z(100.0)
    await r.arm_set("closed")
    await r.arm_step(60.0)
    await r.arm_set("open")
    await r.arm_goto("closed")
    await wait_for(lambda: r.snapshot().state.value == "IDLE" and abs(r.snapshot().z - 100.0) < 0.5, what="settle")
    return r


async def wait_for(cond, timeout=5.0, what=""):
    t_end = asyncio.get_running_loop().time() + timeout
    while not cond():
        assert asyncio.get_running_loop().time() < t_end, what
        await asyncio.sleep(0.01)


STAGES = [(s.name, s.z) for s in HeightCalibration.from_raw(RAW, "dry_run").stages(LIMITS)]


async def test_staged_capture_goes_down_in_order_under_one_lock():
    r = await ready_robot()
    lock = asyncio.Lock()
    seq = ApproachSequencer(r, LIMITS, ApproachParams(settle_s=0.05), lock=lock)
    holds = []
    await seq.start((200.0, 100.0), STAGES, open_claw=False)
    assert lock.locked()
    for name, z in STAGES:
        await wait_for(lambda: seq.holding and seq.stage == name, what=f"hold {name}")
        assert abs(r.snapshot().z - z) <= 3.0 and lock.locked()
        holds.append(seq.stage)
        assert not seq.release("5cm" if name == "10cm" else "10cm")  # a late / wrong release does nothing
        assert seq.release(name)
    await seq.wait()
    assert holds == ["10cm", "5cm", "landing"] and seq.last_result == "done" and not lock.locked()
    assert r.snapshot().z == pytest.approx(100.0, abs=3.0)  # back up


async def test_staged_capture_refuses_bad_stages_and_faults_on_stop():
    r = await ready_robot()
    seq = ApproachSequencer(r, LIMITS, ApproachParams(settle_s=0.05))
    with pytest.raises(RobotCommandError, match="go down"):
        await seq.start((200.0, 100.0), list(reversed(STAGES)), open_claw=False)
    with pytest.raises(RobotCommandError, match="target"):
        await seq.start(None, STAGES, open_claw=False)
    await seq.start((200.0, 100.0), STAGES, open_claw=False)
    await wait_for(lambda: seq.holding and seq.stage == "10cm")
    await seq.abort("emergency stop (stop)")
    await seq.wait()
    assert seq.phase == ApproachPhase.FAULT and r.snapshot().alarm


# ------------------------------------------------------------------ tidy-up
def test_cleanup_profiles_and_route_checks():
    real = CleanupProfile.from_raw(RAW, "real")
    errs = real.problems(LIMITS)
    assert any("enabled_real" in e for e in errs) and any("not confirmed" in e for e in errs)
    dry = CleanupProfile.from_raw(RAW, "dry_run")
    assert dry.problems(LIMITS) == []
    assert segment_hits_rect((0, 0), (10, 10), (4, 4, 6, 6)) and not segment_hits_rect((0, 0), (10, 0), (4, 4, 6, 6))
    import dataclasses
    through = dataclasses.replace(dry, keep_out=((150.0, 30.0, 160.0, 50.0),))  # on the first sweep line
    assert any("keep-out" in e for e in through.problems(LIMITS))
    outside = dataclasses.replace(dry, route_xy=((500.0, 40.0),))
    assert any("soft limits" in e for e in outside.problems(LIMITS))


def _dry(**kw):
    import dataclasses
    base = CleanupProfile.from_raw(RAW, "dry_run")
    return dataclasses.replace(base, collect_dwell_s=0.05, **kw)


async def test_cleanup_runs_the_route_after_a_confirmed_grip():
    r = await ready_robot()
    lock = asyncio.Lock()
    seq = CleanupSequencer(r, LIMITS, _dry(), lock=lock)
    phases = []
    seq.on_change = lambda st: phases.append(st["phase"]) if not phases or phases[-1] != st["phase"] else None
    assert not seq.confirm()  # nothing to confirm yet
    await seq.start()
    await wait_for(lambda: seq.confirming, what="waiting for the grip confirmation")
    assert seq.phase == CleanupPhase.CONFIRM_GRIP and lock.locked()
    assert seq.confirm()
    await seq.wait()
    assert seq.last_result == "done", seq.error
    assert phases.index("SWEEP") < phases.index("TO_COLLECT") < phases.index("RELEASE_JIG") < phases.index("PARK")
    s = r.snapshot()
    assert (s.x, s.y) == pytest.approx((195.0, 190.0), abs=2.0)


async def test_cleanup_grip_timeout_and_stop_end_in_fault():
    r = await ready_robot()
    seq = CleanupSequencer(r, LIMITS, _dry(grip_confirm_timeout_s=0.3))
    await seq.start()
    await seq.wait()
    assert seq.phase == "FAULT" and "not confirmed" in seq.error and r.snapshot().alarm
    r2 = await ready_robot()
    seq2 = CleanupSequencer(r2, LIMITS, _dry(auto_confirm_grip_s=0.05))
    await seq2.start()
    await wait_for(lambda: seq2.phase == CleanupPhase.SWEEP, what="sweeping")
    await seq2.abort("emergency stop (stop)")
    await seq2.wait()
    assert seq2.phase == "FAULT" and r2.snapshot().alarm and seq2.last_result == "fault"


async def test_real_cleanup_is_refused_by_default():
    r = await ready_robot()
    seq = CleanupSequencer(r, LIMITS, CleanupProfile.from_raw(RAW, "real"))
    with pytest.raises(RobotCommandError, match="enabled_real"):
        await seq.start()


# ------------------------------------------------------------------ server
async def _server(robot):
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, backend_cfg=BackendConfig(raw=RAW))
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def _cmd(ws, name, params=None, rid="r"):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params or {}}}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if m.get("request_id") == rid:
            return m


async def test_server_staged_help_and_cleanup_on_the_mock():
    r = await ready_robot()
    srv, port = await _server(r)
    srv.approach.params = ApproachParams(settle_s=0.05)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            h = (await _cmd(ws, "study_height_status", rid="h"))["data"]
            assert h["usable"] and [s["name"] for s in h["stages"]] == ["10cm", "5cm", "landing"]
            m = await _cmd(ws, "homework_approach", {"xy": [200, 100], "stages": "study"}, rid="a")
            assert m["type"] == "ack", m
            jog = await _cmd(ws, "jog", {"vx": 10, "vy": 0}, rid="j")
            assert jog["type"] == "nack"  # no manual moves while HELP holds the arm
            for i, stage in enumerate(("10cm", "5cm", "landing")):
                await wait_for(lambda: srv.approach.holding and srv.approach.stage == stage, what=stage)
                late = await _cmd(ws, "homework_approach_release", {"stage": "nope"}, rid=f"x{i}")
                assert late["type"] == "nack"
                assert (await _cmd(ws, "homework_approach_release", {"stage": stage}, rid=f"r{i}"))["type"] == "ack"
            await srv.approach.wait()
            assert srv.approach.last_result == "done"
            assert (await _cmd(ws, "study_cleanup_start", rid="c"))["type"] == "ack"
            busy = await _cmd(ws, "move_xy", {"x": 1, "y": 1}, rid="b")
            assert busy["type"] == "nack" and "tidying" in busy["data"]["reason"]
            await wait_for(lambda: srv.cleanup.confirming, what="confirm")
            assert (await _cmd(ws, "study_cleanup_confirm", rid="cc"))["type"] == "ack"
            await wait_for(lambda: srv.cleanup.phase == CleanupPhase.SWEEP, what="sweep")
            assert (await _cmd(ws, "stop", rid="s"))["type"] == "ack"  # STOP works during the tidy-up
            await srv.cleanup.wait()
            st = (await _cmd(ws, "study_cleanup_status", rid="st"))["data"]
            assert st["phase"] == "FAULT" and st["last_result"] == "fault"
    finally:
        await srv.stop()


async def test_server_refuses_mm_targets_and_unmeasured_heights_on_the_real_robot():
    r = await ready_robot()
    r.name = "real"  # the server picks the real profiles by the robot's name
    srv, port = await _server(r)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "homework_approach", {"xy": [200, 100], "stages": "study"}, rid="a")
            assert m["type"] == "nack" and "mock robot" in m["data"]["reason"]
            m = await _cmd(ws, "homework_approach", {"u": 0.5, "v": 0.5, "stages": "study",
                                                     "camera": {"width": 640, "height": 480}}, rid="b")
            assert m["type"] == "nack"  # no camera calibration (and no measured heights)
            assert not (await _cmd(ws, "study_height_status", rid="h"))["data"]["usable"]
            c = await _cmd(ws, "study_cleanup_start", rid="c")
            assert c["type"] == "nack" and "enabled_real" in c["data"]["reason"]
            assert r.snapshot().z == pytest.approx(100.0, abs=1.0)  # nothing moved
    finally:
        await srv.stop()


# ------------------------------------------------------------------ review fixes
async def test_a_staged_hold_that_times_out_goes_back_up_not_further_down():
    r = await ready_robot()
    seq = ApproachSequencer(r, LIMITS, ApproachParams(settle_s=0.05, hold_timeout_s=0.3))
    lowest = []
    await seq.start((200.0, 100.0), STAGES, open_claw=False)
    while seq.active:
        lowest.append(r.snapshot().z)
        await asyncio.sleep(0.01)
    assert seq.last_result == "done"
    assert min(lowest) > STAGES[1][1] + 3.0  # never went to 5 cm (nor the landing) after 10 cm timed out
    assert r.snapshot().z == pytest.approx(100.0, abs=3.0)


async def test_cleanup_refuses_a_first_leg_through_a_keep_out_area():
    r = await ready_robot()
    await r.move_xy(300.0, 20.0)
    await wait_for(lambda: abs(r.snapshot().x - 300.0) < 0.5 and r.snapshot().state.value == "IDLE")
    seq = CleanupSequencer(r, LIMITS, _dry(keep_out=((150.0, 10.0, 160.0, 30.0),)))  # between here and the jig
    with pytest.raises(RobotCommandError, match="way from"):
        await seq.start()
    assert not seq.active


def test_json_is_found_with_braces_in_the_prose():
    text = ('式は {x + 1} のように書きます。\n{"problem_number": 3, "recognized_problem": "x + y = 10", '
            '"confidence": 0.8, "hint": "足してみよう", "explanation": "1. 式", "speech_text": "やってみよう", '
            '"needs_confirmation": false}\n以上 {おわり}')
    assert parse_explanation(text, 3)["hint"] == "足してみよう"


async def test_the_mock_backend_robot_can_tidy_up_without_a_claw_calibration():
    """./start.sh study runs --mock = DryRunRobot: its virtual claw has both positions."""
    from corexy_ufo_backend.sequence import AutoCatchConfig
    from corexy_ufo_backend.sequence.dry_run import make_dry_run_robot
    r = make_dry_run_robot(AutoCatchConfig.from_raw(RAW).dry_run, LIMITS, speed_model=False)
    s = r.snapshot()
    assert s.arm_closed_deg is not None and s.arm_open_deg is not None
    seq = CleanupSequencer(r, LIMITS, CleanupProfile.from_raw(RAW, "dry_run"))
    assert not any("claw" in e for e in seq.preconditions(need_spot=False, need_claw=True))
