"""#242: the arm-tip camera's calibration from the 校正 tab (focus_calibrate / focus_status), the
tutor's camera_move as an arm move, and what UFOくん says when the arm cannot move."""

from __future__ import annotations

import asyncio
import base64
import json

import cv2
import numpy as np
import pytest
import websockets

from corexy_ufo_backend.calibration_store import section
from corexy_ufo_backend.config import BackendConfig
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.study.tutor_adapter import NO_CALIBRATION, TutorStudyAdapter
from corexy_ufo_backend.study_mode.explain import parse_explanation
from corexy_ufo_backend.study_mode.navigation import (FocusCalibration, NavigationError, calibrate_from_jpegs,
                                                      px_per_mm)
from ws_helpers import cmd as _cmd
from ws_helpers import start_server

A_TRUE = np.array([[0.0, 6.0], [-6.0, 0.0]])  # the camera turned 90°, 6 px per mm


def _paper(seed=3, size=(900, 700)) -> np.ndarray:
    """A worksheet-like texture larger than the camera's view."""
    rng = np.random.default_rng(seed)
    img = np.full((size[1], size[0]), 235, np.uint8)
    for _ in range(260):
        x, y = int(rng.integers(0, size[0] - 40)), int(rng.integers(0, size[1] - 20))
        cv2.putText(img, str(int(rng.integers(0, 99))), (x, y + 20), cv2.FONT_HERSHEY_SIMPLEX, 0.7, 30, 2)
    return img


def _view(paper: np.ndarray, d_mm=(0.0, 0.0), A=A_TRUE, w=480, h=360) -> bytes:
    """The camera's picture after the arm moved d_mm: the paper shifts by s = -A·d px."""
    s = -A @ np.asarray(d_mm, float)
    cx, cy = paper.shape[1] / 2 - s[0], paper.shape[0] / 2 - s[1]
    M = np.float32([[1, 0, -(cx - w / 2)], [0, 1, -(cy - h / 2)]])
    crop = cv2.warpAffine(paper, M, (w, h), flags=cv2.INTER_LINEAR)
    ok, buf = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, 92])
    assert ok
    return buf.tobytes()


MOVES = [(10, 0), (0, 10), (-10, 0), (0, -10)]


def test_calibration_from_pictures_finds_the_cameras_turn_and_scale():
    paper = _paper()
    out = calibrate_from_jpegs(_view(paper), [(_view(paper, d), *d) for d in MOVES])
    assert np.allclose(out["A"], A_TRUE, atol=0.15)
    assert out["px_per_mm"] == pytest.approx(6.0, abs=0.1) and max(out["residual_px"]) < 1.0
    assert out["image"] == [480, 360]
    cal = FocusCalibration({"10cm": {"A": out["A"], "image": out["image"]}})
    # a problem at the picture's right edge: the arm goes where A says (A·d = p)
    d = cal.offset_to_mm([300, 0], "10cm")
    assert np.allclose(np.asarray(out["A"]) @ d, [144, 0], atol=1.0)


def test_a_still_picture_or_a_moved_sheet_is_not_kept():
    paper = _paper()
    still = _view(paper)
    with pytest.raises(NavigationError, match="ほとんど動きません"):
        calibrate_from_jpegs(still, [(still, *d) for d in MOVES])
    # the sheet slid during one shot: the shifts do not fit one A
    other = _paper(seed=9)
    moves = [(_view(paper, d), *d) for d in MOVES[:3]] + [(_view(other, MOVES[3]), *MOVES[3])]
    with pytest.raises(NavigationError):
        calibrate_from_jpegs(_view(paper), moves)
    with pytest.raises(NavigationError, match="読めません"):
        calibrate_from_jpegs(b"not a jpeg", [(still, 10, 0), (still, 0, 10)])


def test_px_per_mm():
    assert px_per_mm([[0, 6], [-6, 0]]) == 6.0
    assert px_per_mm([1, 2]) is None and px_per_mm("x") is None


async def test_focus_calibrate_over_the_websocket_saves_what_the_tool_saves(tmp_path):
    cfg = BackendConfig()
    cfg.focus_camera_path = section(tmp_path, "focus_camera")
    robot = MockRobot()
    await robot.connect()
    srv, port = await start_server(robot, backend_cfg=cfg)
    paper = _paper()
    b64 = lambda b: base64.b64encode(b).decode()  # noqa: E731
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            st = await _cmd(ws, "focus_status", rid="s0")
            assert st["type"] == "ack" and st["data"]["heights"] == {}
            ok = await _cmd(ws, "focus_calibrate", {"height": "10cm", "base_jpeg_base64": b64(_view(paper)), "moves": [
                {"image_jpeg_base64": b64(_view(paper, d)), "dx": d[0], "dy": d[1]} for d in MOVES]}, rid="c1")
            assert ok["type"] == "ack" and ok["data"]["px_per_mm"] == pytest.approx(6.0, abs=0.1)
            saved = json.loads(cfg.focus_camera_path.read_text())["heights"]["10cm"]
            assert set(saved) == {"A", "image", "residual_px"}  # tools/calibrate_focus.py's format
            assert FocusCalibration.load(cfg.focus_camera_path).heights["10cm"]["image"] == [480, 360]
            st = await _cmd(ws, "focus_status", rid="s1")
            assert st["data"]["heights"]["10cm"]["px_per_mm"] == pytest.approx(6.0, abs=0.1)
            # refused: too few pictures, not base64, a still picture (nothing saved over the good one)
            bad = await _cmd(ws, "focus_calibrate", {"base_jpeg_base64": b64(_view(paper)), "moves": []}, rid="c2")
            assert bad["type"] == "nack"
            bad = await _cmd(ws, "focus_calibrate", {"base_jpeg_base64": "%%%", "moves": [{"image_jpeg_base64": "a", "dx": 1, "dy": 0}] * 2}, rid="c3")
            assert bad["type"] == "nack"
            still = b64(_view(paper))
            bad = await _cmd(ws, "focus_calibrate", {"base_jpeg_base64": still, "moves": [
                {"image_jpeg_base64": still, "dx": d[0], "dy": d[1]} for d in MOVES]}, rid="c4")
            assert bad["type"] == "nack" and "動き" in bad["data"]["reason"]
            assert json.loads(cfg.focus_camera_path.read_text())["heights"]["10cm"] == saved
    finally:
        await srv.stop()


# ---------------------------------------------------------------- the tutor's answer -> the game
def _resp(game=None, nav=None, speech="3ばんを さがしに いくね！ 手を はなして まっててね。"):
    tr = {"game": {"action": "request_recapture", "message": speech, **(game or {})},
          "corexy": {"problem_number": 3, "speech_text": speech, "explanation": "", "hint": "", "needs_confirmation": True}}
    if nav is not None:
        tr["navigate"] = nav
    return {"tutor_result": tr}


def _adapter(tmp_path, A=((6, 0), (0, 6))):
    cal = None
    if A is not None:
        cal = section(tmp_path, "focus_camera")
        cal.write_text(json.dumps({"heights": {"10cm": {"A": [list(r) for r in A], "image": [640, 480]}}}))
    return TutorStudyAdapter("https://192.0.2.1:8444", "t", focus_calibration=cal)


def test_camera_move_becomes_an_arm_move_through_the_calibration(tmp_path):
    ad = _adapter(tmp_path, A=((0, 6), (-6, 0)))  # turned: the picture's "right" is the arm's +Y (A·d = right)
    out = ad.to_explanation(_resp({"action": "move_camera", "camera_move": {"direction": "right", "distance_mm": 20}}), 3, "10cm")
    assert out["navigate"]["kind"] == "move" and out["navigate"]["d_mm"] == [0.0, 20.0]
    assert out["speech_text"].startswith("3ばんを さがしに")  # the arm moves: the server's words stand
    parsed = parse_explanation(json.dumps(out, ensure_ascii=False), 3)
    assert parsed["navigate"]["d_mm"] == [0.0, 20.0]
    # winch_up / winch_down: words only
    out = ad.to_explanation(_resp({"action": "move_camera", "camera_move": {"direction": "winch_up", "distance_mm": None}}), 3, "10cm")
    assert "navigate" not in out


def test_without_a_calibration_ufo_never_says_it_goes_to_look(tmp_path):
    for ad in (_adapter(tmp_path, A=None),):
        for resp in (_resp(nav={"kind": "move", "direction": "down", "offset": [0, 750]}),
                     _resp({"action": "move_camera", "camera_move": {"direction": "down", "distance_mm": 30}})):
            out = ad.to_explanation(resp, 3, "10cm")
            assert out["navigate"]["kind"] == "move" and "d_mm" not in out["navigate"]
            assert out["navigate"]["error"] == NO_CALIBRATION
            assert "さがしに" not in out["speech_text"] and "ずらして" in out["speech_text"]
            parsed = parse_explanation(json.dumps(out, ensure_ascii=False), 3)
            assert parsed["navigate"]["error"] == NO_CALIBRATION and "さがしに" not in parsed["speech_text"]
    ad = _adapter(tmp_path)
    out = ad.to_explanation(_resp(nav={"kind": "uncover"}), 3, "10cm")
    assert "かくれて" in out["speech_text"] and "d_mm" not in out["navigate"]
    out = ad.to_explanation(_resp(nav={"kind": "zoom_out"}), 3, "10cm")
    assert "わからなかった" in out["speech_text"]
    # a height without a calibration: the error says so, the words too
    out = ad.to_explanation(_resp(nav={"kind": "move", "offset": [0, 750]}), 3, "5cm")
    assert "5cm" in out["navigate"]["error"] and "さがしに" not in out["speech_text"]


def test_direction_to_mm():
    cal = FocusCalibration({"10cm": {"A": [[6, 0], [0, 6]], "image": [640, 480]}})
    assert cal.direction_to_mm("down", 30) == (0.0, 30.0)
    assert cal.direction_to_mm("left", 10) == (-10.0, 0.0)
    with pytest.raises(NavigationError):
        cal.direction_to_mm("winch_up", 10)
    with pytest.raises(NavigationError):
        cal.direction_to_mm("up", 10, "5cm")
