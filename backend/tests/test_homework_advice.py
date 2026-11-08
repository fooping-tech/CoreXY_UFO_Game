"""Homework stage 1 (#76): stall detection, the approach to a recorded spot and back, advice."""

from __future__ import annotations

import asyncio
import base64
import json
from pathlib import Path

import pytest
import websockets

from corexy_ufo_backend.config import RobotLimits
from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService, parse
from corexy_ufo_backend.homework.approach import ApproachParams, ApproachPhase, ApproachSequencer, HomeworkSpot
from corexy_ufo_backend.homework.jev import JevResult
from corexy_ufo_backend.homework.progress import ProgressTracker
from corexy_ufo_backend.homework.service import advice_prompt
from corexy_ufo_backend.robot import RobotCommandError
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.websocket import GameServer

JPEG = b"\xff\xd8homework\xff\xd9"
JPEG_B64 = base64.b64encode(JPEG).decode()


def output(pct_level: int, occluded=0.1):
    probs = [0.0] * 6
    probs[pct_level] = 1.0
    return {"answers": {"visible": {"type": "noul", "noul": 0.9}, "occluded": {"type": "noul", "noul": occluded},
                        "progress": {"type": "score", "probabilities": {str(i): p for i, p in enumerate(probs)}}},
            "usage": {"input_tokens": 100, "output_tokens": 0}}


# ------------------------------------------------------------------ stall
def test_stall_after_three_minutes_without_five_points():
    t = ProgressTracker(stall_s=180, stall_min_gain=5)
    t.add(0, parse(output(1)))       # 20%
    assert not t.stalled(170)
    t.add(170, parse(output(1)))
    assert t.stalled(180) and t.stalled_for(200) == 200  # 3 min at 20%
    t.add(200, parse(output(2)))     # median(20, 20, 40) = 20: not a gain yet
    t.add(210, parse(output(2)))     # median(20, 40, 40) = 40: a gain, the clock restarts
    assert not t.stalled(380) and t.stalled(390)
    t.reset_stall(400)               # an advice was given: wait again
    assert not t.stalled(570) and t.stalled(580)


def test_no_stall_at_100_or_while_a_hand_covers_the_sheet():
    t = ProgressTracker(stall_s=60)
    for i in range(3):
        t.add(i, parse(output(5)))
    assert t.smoothed_pct == 100 and not t.stalled(1000)
    t = ProgressTracker(stall_s=60)
    t.add(0, parse(output(1)))
    t.add(100, parse(output(1, occluded=0.9)))  # writing, probably
    assert not t.stalled(100)
    t.add(110, parse(output(1)))
    assert t.stalled(110)


async def test_progress_messages_carry_the_stall():
    class Fake:
        def run(self, jev_input, timeout=30.0):
            return JevResult(output=output(1), latency_s=0.1)

    svc = HomeworkService(HomeworkConfig(enabled=True, stall_s=10), client_factory=Fake)
    sent = []

    async def emit(m):
        sent.append(m)

    await svc.start("s")
    svc.sessions["s"].started -= 20  # 20 s in
    await svc.frame("s", "r", JPEG_B64, emit)
    await svc.sessions["s"].task
    d = sent[-1]["data"]
    assert d["stalled"] and d["stalled_for_s"] >= 20
    await svc.close()


# ------------------------------------------------------------------ approach
_TICKERS: list[asyncio.Task] = []


def fast_mock() -> MockRobot:
    """A quick virtual crane, ticked in the background (the server's poll loop does it otherwise)."""
    r = MockRobot(speed_xy=3000.0, accel_xy=60000.0, speed_z=2000.0, accel_z=40000.0)

    async def ticker():
        while True:
            await r.tick()
            await asyncio.sleep(0.005)

    _TICKERS.append(asyncio.get_running_loop().create_task(ticker()))
    return r


@pytest.fixture(autouse=True)
async def _stop_tickers():
    yield
    for t in _TICKERS:
        t.cancel()
    await asyncio.gather(*_TICKERS, return_exceptions=True)
    _TICKERS.clear()


async def settle(r: MockRobot, timeout=3.0):
    r._homing_until = 0.0  # no 1.5 s homing animation in the tests
    t_end = asyncio.get_running_loop().time() + timeout
    await asyncio.sleep(0.02)
    while any(abs(v) > 0.01 for v in r.vel) or any(abs(a - b) > 0.01 for a, b in zip(r.pos, r.target)):
        assert asyncio.get_running_loop().time() < t_end
        await asyncio.sleep(0.01)


async def ready_robot() -> MockRobot:
    r = fast_mock()
    await r.connect()
    await r.enable_motors(True)
    await r.home()
    await r.move_z(100.0)
    await settle(r)
    return r


async def wait_phase(seq: ApproachSequencer, phase: ApproachPhase, timeout=5.0):
    t_end = asyncio.get_running_loop().time() + timeout
    while seq.phase != phase:
        assert asyncio.get_running_loop().time() < t_end, f"stuck in {seq.phase} ({seq.error})"
        await asyncio.sleep(0.01)


async def test_spot_record_and_refusals(tmp_path):
    r = fast_mock()
    await r.connect()
    seq = ApproachSequencer(r, RobotLimits(), spot_path=tmp_path / "homework_spot.json")
    with pytest.raises(RobotCommandError, match="not homed"):
        seq.set_spot()
    errs = seq.preconditions()
    assert any("no homework spot" in e for e in errs) and any("motors" in e for e in errs)
    await r.enable_motors(True)
    await r.home()
    await r.move_xy(120, 80)
    await r.move_z(40)
    await settle(r)
    spot = seq.set_spot()
    assert (spot.x, spot.y, spot.z) == (120, 80, 40)
    assert HomeworkSpot.load(tmp_path / "homework_spot.json") == spot  # kept for the next start
    assert ApproachSequencer(r, RobotLimits(), spot_path=tmp_path / "homework_spot.json").spot == spot


async def test_approach_goes_down_waits_for_the_capture_and_comes_back():
    r = await ready_robot()
    await r.move_xy(10, 10)
    await settle(r)
    lock = asyncio.Lock()
    seq = ApproachSequencer(r, RobotLimits(), lock=lock)
    seq.spot = HomeworkSpot(150, 90, 30)
    phases = []
    seq.on_change = lambda st: phases.append(st["phase"])
    await seq.start()
    assert lock.locked()  # manual moves are refused meanwhile
    await wait_phase(seq, ApproachPhase.HOLD)
    s = r.snapshot()
    assert abs(s.x - 150) < 2 and abs(s.y - 90) < 2 and abs(s.z - 30) < 3
    assert seq.release()
    await seq.wait()
    s = r.snapshot()
    assert seq.last_result == "done" and abs(s.z - 100) < 3 and abs(s.x - 10) < 2 and not lock.locked()
    order = [p for i, p in enumerate(phases) if i == 0 or phases[i - 1] != p]
    assert order == ["RAISE", "MOVE_XY", "LOWER", "HOLD", "RAISE_BACK", "RETURN_XY", "IDLE"]


async def test_hold_times_out_and_still_goes_back_up():
    r = await ready_robot()
    seq = ApproachSequencer(r, RobotLimits(), ApproachParams(hold_timeout_s=0.2, return_xy=False))
    seq.spot = HomeworkSpot(50, 50, 50)
    await seq.start()
    await seq.wait()
    assert seq.last_result == "done" and abs(r.snapshot().z - 100) < 3


async def test_abort_ends_in_fault_with_the_robot_stopped():
    r = await ready_robot()
    seq = ApproachSequencer(r, RobotLimits())
    seq.spot = HomeworkSpot(200, 100, 20)
    await seq.start()
    await wait_phase(seq, ApproachPhase.MOVE_XY)
    await seq.abort("emergency stop (stop)")
    await seq.wait()
    assert seq.phase == ApproachPhase.FAULT and seq.last_result == "fault" and "stop" in seq.error
    assert not r.snapshot().homed  # the stop (ABORT) clears homing: home again before moving


async def test_motors_disabled_mid_way_is_a_fault():
    r = await ready_robot()
    seq = ApproachSequencer(r, RobotLimits())
    seq.spot = HomeworkSpot(200, 100, 20)
    await seq.start()
    await wait_phase(seq, ApproachPhase.MOVE_XY)
    await r.enable_motors(False)
    await seq.wait()
    assert seq.phase == ApproachPhase.FAULT and "motors disabled" in seq.error


# ------------------------------------------------------------------ server
async def _server(robot, homework=None):
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=homework)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def _cmd(ws, name, params=None, rid="r"):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params or {}}}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 5))
        if m.get("request_id") == rid:
            return m


async def test_server_approach_is_exclusive_and_stop_aborts_it():
    r = await ready_robot()
    srv, port = await _server(r)
    srv.approach.spot = HomeworkSpot(300, 150, 20)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            assert (await _cmd(ws, "homework_approach", rid="a"))["type"] == "ack"
            m = await _cmd(ws, "move_xy", {"x": 1, "y": 1}, rid="b")
            assert m["type"] == "nack" and "approaching" in m["data"]["reason"]
            assert (await _cmd(ws, "auto_catch", rid="c"))["type"] == "nack"
            assert (await _cmd(ws, "stop", rid="d"))["type"] == "ack"
            await srv.approach.wait()
            st = (await _cmd(ws, "homework_approach_status", rid="e"))["data"]
            assert st["phase"] == "FAULT" and not st["active"]
    finally:
        await srv.stop()


async def test_server_approach_release_and_state_broadcast():
    r = await ready_robot()
    srv, port = await _server(r)
    srv.approach.spot = HomeworkSpot(60, 60, 60)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            assert (await _cmd(ws, "homework_approach", rid="a"))["type"] == "ack"
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 5))
                if m["type"] == "homework_approach" and m["data"]["phase"] == "HOLD":
                    break
            assert (await _cmd(ws, "homework_approach_release", rid="b"))["type"] == "ack"
            await srv.approach.wait()
            assert srv.approach.last_result == "done"
    finally:
        await srv.stop()


# ------------------------------------------------------------------ advice
class FakeAdapter:
    def __init__(self, fail: str = ""):
        self.fail = fail
        self.asked = []
        self.closed = False

    async def start_session(self, workdir: Path, instructions: str) -> str:
        assert "答えそのものは言わず" in instructions
        return "t1"

    async def ask(self, thread_id, text, image_path, on_delta):
        assert image_path.read_bytes() == JPEG
        self.asked.append(text)
        if self.fail:
            raise RuntimeError(self.fail)
        await on_delta("3番の問題で")
        await on_delta("止まっています。")
        return "turn"

    async def close_session(self, thread_id):
        pass

    async def close(self):
        self.closed = True


async def test_advice_streams_and_resets_the_stall():
    class Fake:
        def run(self, jev_input, timeout=30.0):
            return JevResult(output=output(1), latency_s=0.1)

    adapter = FakeAdapter()
    svc = HomeworkService(HomeworkConfig(enabled=True, stall_s=10), client_factory=Fake,
                          advice_factory=lambda: adapter)
    sent = []

    async def emit(m):
        sent.append(m)

    await svc.start("s")
    svc.sessions["s"].started -= 600
    await svc.frame("s", "f", JPEG_B64, emit)
    await svc.sessions["s"].task
    assert sent[-1]["data"]["stalled"]
    await svc.advise("s", "a1", JPEG_B64, True, emit)
    with pytest.raises(ValueError, match="already"):
        await svc.advise("s", "a2", JPEG_B64, True, emit)  # one at a time
    await svc._advice_task
    kinds = [m["type"] for m in sent if m["request_id"] == "a1"]
    assert kinds == ["homework_advice_delta", "homework_advice_delta", "homework_advice_result"]
    assert "左は机の上から撮った全体" in adapter.asked[0] and "約10分" in adapter.asked[0] and adapter.closed
    assert not svc.sessions["s"].summary()["stalled"]  # wait stall_s again before the next notice
    await svc.close()


async def test_advice_errors_and_without_a_session():
    svc = HomeworkService(HomeworkConfig(enabled=True), advice_factory=lambda: FakeAdapter(fail="not signed in"))
    sent = []

    async def emit(m):
        sent.append(m)

    await svc.advise("", "a", JPEG_B64, False, emit)  # works without a running watch
    await svc._advice_task
    assert sent[-1]["type"] == "homework_advice_error" and "not signed in" in sent[-1]["data"]["message"]
    with pytest.raises(ValueError, match="no assistant"):
        await HomeworkService(HomeworkConfig(enabled=True)).advise("", "a", JPEG_B64, False, emit)


def test_advice_prompt_without_context():
    p = advice_prompt({"composite": False})
    assert "止まっている問題:" in p and "全体" not in p
