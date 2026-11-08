"""Homework stage 2 (#78): overview camera image <-> CoreXY XY calibration, and looking at a clicked point."""

from __future__ import annotations

import json

import numpy as np
import pytest
import websockets

from corexy_ufo_backend.config import RobotLimits
from corexy_ufo_backend.homework.approach import ApproachPhase, ApproachSequencer, HomeworkSpot
from corexy_ufo_backend.homework.camera_map import (CameraMapError, CameraMapParams, CameraXYMap, apply,
                                                     camera_signature, convex_hull, distance_outside)
from corexy_ufo_backend.robot import RobotCommandError

from test_homework_advice import (_cmd, _server, _stop_tickers, fast_mock, ready_robot,  # noqa: F401
                                  settle, wait_phase)

CAM = {"width": 1280, "height": 720, "flip_h": True, "flip_v": True}
# a made-up camera: perspective (tilted), rotated, scaled; image (u, v) -> XY mm
H_TRUE = np.array([[260.0, 25.0, 60.0], [-15.0, 180.0, 40.0], [0.08, 0.05, 1.0]])
GRID = [(0.15, 0.2), (0.85, 0.15), (0.9, 0.85), (0.1, 0.8), (0.5, 0.5), (0.3, 0.6)]


def calibrated(points=GRID, noise=0.0, params=None, path=None) -> CameraXYMap:
    m = CameraXYMap(params=params or CameraMapParams(), path=path)
    rng = np.random.default_rng(1)
    for u, v in points:
        x, y = apply(H_TRUE, u, v)
        m.add(u, v, x + rng.normal(0, noise), y + rng.normal(0, noise), CAM)
    return m


def test_fit_recovers_a_perspective_map_and_its_inverse():
    m = calibrated()
    assert m.usable and m.max_error < 0.01
    x, y = m.to_xy(0.6, 0.4, CAM)
    tx, ty = apply(H_TRUE, 0.6, 0.4)
    assert abs(x - tx) < 0.05 and abs(y - ty) < 0.05
    u, v = apply(np.array(m.status()["h_inv"]), x, y)  # the panel's marker: XY -> image
    assert abs(u - 0.6) < 1e-4 and abs(v - 0.4) < 1e-4


def test_click_noise_shows_as_error_in_mm():
    m = calibrated(noise=1.0)
    assert m.usable and 0.2 < m.rms_error < 3.0
    bad = calibrated()
    x, y = apply(H_TRUE, 0.6, 0.3)
    bad.add(0.6, 0.3, x + 30, y, CAM)  # a mark clicked 30 mm off
    assert not bad.usable and "誤差" in bad.problem
    with pytest.raises(CameraMapError, match="not usable"):
        bad.to_xy(0.5, 0.5, CAM)


def test_too_few_or_collinear_or_folded_points_are_not_fitted():
    assert "あと 1 点" in calibrated(GRID[:3]).problem
    line = calibrated([(0.1, 0.1), (0.3, 0.3), (0.5, 0.5), (0.7, 0.7), (0.9, 0.9)])
    assert not line.usable and "一直線" in line.problem
    # two clicks swapped (the second mark clicked where the first was, and back): the map folds
    m = CameraXYMap()
    for i, (u, v) in enumerate(GRID[:5]):
        su, sv = GRID[1] if i == 0 else GRID[0] if i == 1 else (u, v)
        m.add(su, sv, *apply(H_TRUE, u, v), CAM)
    assert not m.usable


def test_targets_outside_the_calibrated_area_or_another_camera_are_refused():
    m = calibrated(params=CameraMapParams(margin_mm=10.0))
    with pytest.raises(CameraMapError, match="outside the calibrated area"):
        m.to_xy(0.0, 0.0, CAM)  # a corner far from the points
    with pytest.raises(CameraMapError, match="camera changed"):
        m.to_xy(0.5, 0.5, {**CAM, "flip_h": False})
    with pytest.raises(CameraMapError, match="not inside the image"):
        m.to_xy(1.2, 0.5, CAM)
    with pytest.raises(CameraMapError, match="size or flips changed"):
        m.add(0.4, 0.3, 500, 500, {**CAM, "width": 640})


def test_points_too_close_are_refused_and_undo_clear_save_load(tmp_path):
    path = tmp_path / "camera_xy_calibration.json"
    m = calibrated(path=path)
    x, y = apply(H_TRUE, *GRID[0])
    with pytest.raises(CameraMapError, match="already within"):
        m.add(0.16, 0.21, x + 1, y + 1, CAM)
    d = json.loads(path.read_text())
    assert len(d["points"]) == 6 and d["camera"] == CAM and d["homography"]
    again = CameraXYMap.load(path)
    assert again.usable and again.to_xy(0.5, 0.5, CAM) == m.to_xy(0.5, 0.5, CAM)
    m.undo()
    m.undo()
    m.undo()
    assert len(m.points) == 3 and not m.usable
    m.clear()
    assert CameraXYMap.load(path).points == [] and CameraXYMap.load(path).camera is None


def test_hull_distance():
    hull = convex_hull([(0, 0), (10, 0), (10, 10), (0, 10), (5, 5)])
    assert len(hull) == 4
    assert distance_outside(hull, 5, 5) == 0.0 and distance_outside(hull, 13, 14) == pytest.approx(5.0)


def test_camera_signature_needs_a_size():
    with pytest.raises(CameraMapError):
        camera_signature({"width": 0, "height": 0})
    with pytest.raises(CameraMapError):
        camera_signature(None)


# ------------------------------------------------------------------ approach to a target
async def test_approach_to_a_target_uses_the_spot_height():
    r = await ready_robot()
    seq = ApproachSequencer(r, RobotLimits())
    seq.spot = HomeworkSpot(150, 90, 30)
    await seq.start(target=(220.0, 140.0))
    await wait_phase(seq, ApproachPhase.HOLD)
    s = r.snapshot()
    assert abs(s.x - 220) < 2 and abs(s.y - 140) < 2 and abs(s.z - 30) < 3
    assert seq.status()["target"] == {"x": 220.0, "y": 140.0}
    seq.release()
    await seq.wait()
    assert seq.last_result == "done"
    with pytest.raises(RobotCommandError, match="outside the soft limits"):
        await seq.start(target=(-50.0, 10.0))


# ------------------------------------------------------------------ server
async def test_server_calibrates_from_the_arm_position_and_looks_at_a_click():
    r = await ready_robot()
    srv, port = await _server(r)
    srv.camera_map = CameraXYMap()  # no file in the tests
    srv.approach.spot = HomeworkSpot(100, 100, 40)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            for i, (u, v) in enumerate(GRID):
                x, y = apply(H_TRUE, u, v)
                await r.move_xy(x, y)
                await settle(r)
                m = await _cmd(ws, "camera_map_add", {"u": u, "v": v, "camera": CAM}, rid=f"p{i}")
                assert m["type"] == "ack", m
            st = m["data"]
            assert st["usable"] and len(st["points"]) == 6 and st["max_mm"] < 0.5
            far = await _cmd(ws, "homework_approach", {"u": 0.0, "v": 1.0, "camera": CAM}, rid="far")
            assert far["type"] == "nack" and "outside the calibrated area" in far["data"]["reason"]
            m = await _cmd(ws, "homework_approach", {"u": 0.5, "v": 0.5, "camera": CAM}, rid="look")
            assert m["type"] == "ack", m
            busy = await _cmd(ws, "camera_map_add", {"u": 0.2, "v": 0.2, "camera": CAM}, rid="busy")
            assert busy["type"] == "nack"  # not while the arm approaches
            await wait_phase(srv.approach, ApproachPhase.HOLD)
            tx, ty = apply(H_TRUE, 0.5, 0.5)
            s = r.snapshot()
            assert abs(s.x - tx) < 2 and abs(s.y - ty) < 2 and abs(s.z - 40) < 3
            assert (await _cmd(ws, "homework_approach_release", rid="rel"))["type"] == "ack"
            await srv.approach.wait()
            assert (await _cmd(ws, "camera_map_undo", rid="u"))["data"]["points"][-1]["u"] == GRID[-2][0]
            assert (await _cmd(ws, "camera_map_status", rid="s"))["data"]["usable"]
    finally:
        await srv.stop()


async def test_server_refuses_points_before_homing():
    r = fast_mock()
    await r.connect()
    srv, port = await _server(r)
    srv.camera_map = CameraXYMap()
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "camera_map_add", {"u": 0.5, "v": 0.5, "camera": CAM})
            assert m["type"] == "nack" and "not homed" in m["data"]["reason"]
            m = await _cmd(ws, "homework_approach", {"u": 0.5, "v": 0.5, "camera": CAM}, rid="x")
            assert m["type"] == "nack" and "not usable" in m["data"]["reason"]
    finally:
        await srv.stop()
