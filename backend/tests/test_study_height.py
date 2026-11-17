"""#110: the study mode's capture heights measured in the 校正 tab: z_per_cm from the drum
radius and the measured Z calibration, the desk at the Z calibration's bottom, a grown-up's
confirmation after the test moves."""

from __future__ import annotations

import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.calibration_store import section
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import RealRobot
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.serial_service import SerialService
from corexy_ufo_backend.study_mode.height import HeightCalibration, HeightError, z_per_cm_from_drum
from corexy_ufo_backend.websocket import GameServer

from test_homework_advice import _cmd

LIM = RobotLimits(z_max=100.0, z_up_is_positive=True)
VALUES = {"drum_radius_mm": 15.0, "camera_offset_cm": 3.0, "landing_tip_cm": 1.0, "allow_landing_contact": False}


def test_z_per_cm_from_the_drum():
    # one turn = 2*pi*15 mm = 94.2 mm of rope; one unit = 80.42 / 4096 turns = 1.85 mm
    assert z_per_cm_from_drum(80.42, 15.0) == pytest.approx(5.404, abs=0.001)
    assert z_per_cm_from_drum(80.42, 30.0) == pytest.approx(5.404 / 2, abs=0.001)


def test_measured_values_give_the_stages():
    base = HeightCalibration(profile="real")
    h = base.with_measured({**VALUES, "desk": "bottom", "confirmed": True}, 80.42, LIM)
    st = {s.name: s for s in h.stages(LIM)}
    assert h.z_desk_tip == 0.0  # the Z calibration's bottom: claw tips on the desk
    assert st["10cm"].tip_cm == 7.0 and st["10cm"].z == pytest.approx(7.0 * 5.404, abs=0.01)
    assert st["5cm"].z == pytest.approx(2.0 * 5.404, abs=0.01) and st["landing"].tip_cm == 1.0
    with pytest.raises(HeightError, match="not confirmed"):
        base.with_measured({**VALUES, "desk": "bottom", "confirmed": False}, 80.42, LIM).stages(LIM)
    with pytest.raises(HeightError, match="z_per_cm"):  # the Z calibration not measured: no cm
        base.with_measured({**VALUES, "desk": "bottom", "confirmed": True}, None, LIM).stages(LIM)
    h = base.with_measured({**VALUES, "desk": 12.5, "confirmed": True}, 80.42, LIM)
    assert h.stages(LIM)[0].z == pytest.approx(12.5 + 7.0 * 5.404, abs=0.01)  # a desk recorded higher


def cfg_for(tmp_path) -> BackendConfig:
    cfg = BackendConfig(limits=LIM, z_counts_per_unit=122.88, z_sign=1)
    cfg.z_calibration_path = section(tmp_path, "z")
    cfg.arm_calibration_path = section(tmp_path, "claw")
    cfg.study_height_path = section(tmp_path, "study_height")
    return cfg


# the shipped config (#110): one 10 cm stage of the claw tips, no landing
ONE_STAGE = {"study_mode": {"height": {"capture_heights_cm": [10.0], "landing": False}}}


async def real_server(tmp_path, measured=True, raw=None):
    cfg = cfg_for(tmp_path)
    if raw is not None:
        cfg.raw = raw
    if measured:
        section(tmp_path, "z").write_text(json.dumps({"counts_per_unit": 80.42, "sign": 1, "span_counts": 8042}))
    robot = RealRobot(cfg, SerialService("fake", transport_factory=FakeFirmware))
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, backend_cfg=cfg)
    await srv.start()
    return srv, robot, next(iter(srv._server.sockets)).getsockname()[1]


async def test_the_z_bottom_and_10_cm_are_used_with_nothing_saved_or_confirmed(tmp_path):
    """#165: the desk is the Z bottom record, cm from the measured Z and the 15 mm drum,
    the claw tips 10 cm above the desk: no 保存, no ruler check."""
    srv, robot, port = await real_server(tmp_path, raw=ONE_STAGE)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            st = (await _cmd(ws, "study_height_status", rid="s0"))["data"]
            assert st["usable"] and st["saved"] is None and st["z_calibrated"] and not st["z_changed"], st
            assert st["values"]["z_desk_tip"] == 0.0 and st["values"]["camera_offset_cm"] == 0.0
            assert st["values"]["z_per_cm"] == pytest.approx(z_per_cm_from_drum(80.42, 15.0), abs=1e-4)
            stages = srv.height.stages(srv.approach.limits)
            first = stages[0]
            assert len(stages) == 1 and first.name == "10cm" and first.tip_cm == 10.0
            assert first.z == pytest.approx(10.0 * z_per_cm_from_drum(80.42, 15.0), abs=0.01)
    finally:
        await srv.stop()
    assert not section(tmp_path, "study_height").exists()  # nothing written


async def test_saved_values_are_used_without_a_check(tmp_path):
    srv, robot, port = await real_server(tmp_path)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "study_height_set", {**VALUES, "drum_radius_mm": 30.0, "desk": "bottom"}, rid="set")
            assert m["type"] == "ack", m
            d = m["data"]
            assert d["usable"] and d["values"]["confirmed"] and d["saved"]["drum_radius_mm"] == 30.0
            assert d["values"]["z_per_cm"] == pytest.approx(5.404 / 2, abs=0.001)
            bad = await _cmd(ws, "study_height_set", {**VALUES, "camera_offset_cm": 9.5}, rid="bad1")
            assert bad["type"] == "ack" and not bad["data"]["usable"]  # saved, but the 10 cm stage leaves no clearance
            out = await _cmd(ws, "study_height_set", {**VALUES, "drum_radius_mm": 0.5}, rid="range")
            assert out["type"] == "nack" and "drum_radius_mm" in out["data"]["reason"]
            here = await _cmd(ws, "study_height_set", {**VALUES, "desk": "here"}, rid="here")
            assert here["type"] == "nack" and "上を記録" in here["data"]["reason"]  # no Z reference yet
    finally:
        await srv.stop()


async def test_a_new_z_calibration_keeps_the_bottom_but_not_a_recorded_desk(tmp_path):
    """Review on #111: measuring Z again changes cm per Z. The Z bottom follows it (#165); a desk
    recorded as a Z in the old units must be recorded again."""
    srv, robot, port = await real_server(tmp_path)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _cmd(ws, "study_height_set", {**VALUES, "desk": "bottom"}, rid="set")
            from corexy_ufo_backend.robot.z_calibration import ZCalibration
            robot.z_cal = ZCalibration(counts_per_unit=120.0, sign=1, span_counts=12000)  # measured again
            st = (await _cmd(ws, "study_height_status", rid="st"))["data"]
            assert st["usable"] and not st["z_changed"]
            assert st["values"]["z_per_cm"] == pytest.approx(z_per_cm_from_drum(120.0, 15.0), abs=1e-4)
            saved = json.loads(section(tmp_path, "study_height").read_text())
            saved.update({"desk": 12.5, "z_counts_per_unit": 80.42})  # a desk Z in old units
            section(tmp_path, "study_height").write_text(json.dumps(saved))
            st = (await _cmd(ws, "study_height_status", rid="st2"))["data"]
            assert not st["usable"] and st["z_changed"] and "z_desk_tip" in st["problem"]
    finally:
        await srv.stop()


async def test_without_a_measured_z_calibration_it_cannot_be_confirmed(tmp_path):
    srv, robot, port = await real_server(tmp_path, measured=False)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _cmd(ws, "study_height_set", {**VALUES, "desk": "bottom"}, rid="set")
            m = await _cmd(ws, "study_height_confirm", {"confirmed": True}, rid="ok")
            assert m["type"] == "nack" and "z_per_cm" in m["data"]["reason"]
    finally:
        await srv.stop()


async def test_the_mock_robot_keeps_its_dry_run_values(tmp_path):
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, backend_cfg=cfg_for(tmp_path))
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "study_height_set", {**VALUES, "desk": "bottom"}, rid="set")
            assert m["type"] == "nack" and "dry_run" in m["data"]["reason"]
    finally:
        await srv.stop()
