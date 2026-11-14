"""#106: after a power cycle the last session's Z top / bottom are called back (z_restore),
from the drum counts kept at rest in calibration.json#z_points."""

from __future__ import annotations

import json

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.calibration_store import section
from corexy_ufo_backend.config import BackendConfig, RobotLimits
from corexy_ufo_backend.robot import RealRobot, RobotCommandError
from corexy_ufo_backend.serial_service import SerialService

CPU = 80.0  # counts per Z unit (as measured)


def cfg_for(tmp_path) -> BackendConfig:
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True), z_counts_per_unit=CPU, z_sign=1)
    cfg.z_calibration_path = section(tmp_path, "z")
    cfg.z_points_path = section(tmp_path, "z_points")
    cfg.arm_calibration_path = section(tmp_path, "claw")
    return cfg


async def robot_with(tmp_path, abs_counts: int, tracking: bool = True) -> RealRobot:
    fw: dict = {}

    def factory(*a, **k):
        t = FakeFirmware(*a, **k)
        t.servo_abs[1] = abs_counts
        t.servo_tracking[1] = tracking
        if not tracking:
            t.servo_limits[1] = "0/4095"  # a servo just powered up: one turn, not tracked yet
        fw["t"] = t
        return t
    r = RealRobot(cfg_for(tmp_path), SerialService("fake", transport_factory=factory))
    await r.connect()
    return r


async def rest_poll(r: RealRobot) -> None:
    r._last_z_poll = r._last_poll = r._z_saved_t = 0.0
    await r.tick()


async def first_session(tmp_path) -> tuple[int, int, float]:
    """Top at 9000 counts, bottom 8000 counts lower; the arm left 3200 counts below the top."""
    r = await robot_with(tmp_path, 9000)
    try:
        await r.set_z_point("top")
        r.serial.transport.servo_abs[1] = 1000
        await r.set_z_point("bottom")
        r.serial.transport.servo_abs[1] = 5800
        await rest_poll(r)
        z = r.snapshot().z
    finally:
        await r.disconnect()
    saved = json.loads(section(tmp_path, "z_points").read_text())
    assert saved["top"] == 9000 and saved["bottom"] == 1000 and saved["last"] == 5800
    return 5800, 9000, z


async def test_backend_restart_same_counts(tmp_path):
    last, _, z_before = await first_session(tmp_path)
    r = await robot_with(tmp_path, last)
    try:
        assert not r.snapshot().z_reference_set  # nothing is trusted until a grown-up says so
        est = await r.restore_z_points(False)
        assert est["turns"] == 0 and est["drift_counts"] == 0 and est["z"] == pytest.approx(z_before, abs=0.1)
        assert not r.snapshot().z_reference_set  # the estimate changes nothing
        done = await r.restore_z_points(True, est["turns"])
        s = r.snapshot()
        assert done["applied"] and s.z_top_set and s.z_bottom_set and s.z == pytest.approx(z_before, abs=0.1)
    finally:
        await r.disconnect()


async def test_power_cycle_counts_restart_in_the_turn(tmp_path):
    last, top, z_before = await first_session(tmp_path)
    # the servo powered up: tracking starts from the angle in the turn (5800 mod 4096 = 1704),
    # and the first W tap moved it 150 counts up
    r = await robot_with(tmp_path, last % 4096 + 150)
    try:
        est = await r.restore_z_points(False)
        assert est["turns"] == -1 and est["drift_counts"] == 150
        assert est["z"] == pytest.approx(z_before + 150 / CPU, abs=0.1)
        await r.restore_z_points(True, -1)
        assert r._z_top_counts == top - 4096 and r.snapshot().z == pytest.approx(z_before + 150 / CPU, abs=0.1)
        # kept again in today's counts
        assert json.loads(section(tmp_path, "z_points").read_text())["top"] == top - 4096
    finally:
        await r.disconnect()


async def test_refused_when_it_cannot_be_trusted(tmp_path):
    last, _, _ = await first_session(tmp_path)
    r = await robot_with(tmp_path, last, tracking=False)  # powered up, no jog yet
    try:
        with pytest.raises(RobotCommandError, match="一瞬押して"):
            await r.restore_z_points(False)
    finally:
        await r.disconnect()
    r = await robot_with(tmp_path, last + 1800)  # turned almost half a turn while off
    try:
        est = await r.restore_z_points(False)
        assert est["too_far"]
        with pytest.raises(RobotCommandError, match="ずれている"):
            await r.restore_z_points(True, est["turns"])
        assert not r.snapshot().z_reference_set
    finally:
        await r.disconnect()
    r = await robot_with(tmp_path, last)
    try:
        with pytest.raises(RobotCommandError, match="回った"):
            await r.restore_z_points(True, 3)  # not the turn shift the grown-up saw
        assert not r.snapshot().z_reference_set
    finally:
        await r.disconnect()


async def test_nothing_kept_nothing_called_back_and_clear_forgets(tmp_path):
    r = await robot_with(tmp_path, 4000)
    try:
        with pytest.raises(RobotCommandError, match="記録がありません"):
            await r.restore_z_points(False)
        await rest_poll(r)  # no point in this session: nothing kept
        assert not section(tmp_path, "z_points").exists()
        await r.set_z_point("top")
        assert section(tmp_path, "z_points").exists()
        await r.set_z_point("clear")
        assert not section(tmp_path, "z_points").exists() and r._z_saved == {}
    finally:
        await r.disconnect()


async def test_a_new_session_without_call_back_does_not_overwrite_the_kept_points(tmp_path):
    await first_session(tmp_path)
    r = await robot_with(tmp_path, 300)  # powered up and moved, nothing recorded or called back
    try:
        await rest_poll(r)
        assert json.loads(section(tmp_path, "z_points").read_text())["top"] == 9000  # still the last session's
    finally:
        await r.disconnect()


async def test_server_z_restore(tmp_path):
    from test_homework_advice import _cmd, _server
    last, _, z_before = await first_session(tmp_path)
    r = await robot_with(tmp_path, last)
    srv, port = await _server(r)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "z_restore", {"apply": False}, rid="a")
            assert m["type"] == "ack" and m["data"]["restore"]["turns"] == 0 and not m["data"]["z_reference_set"]
            m = await _cmd(ws, "z_restore", {"apply": True, "turns": 0}, rid="b")
            assert m["type"] == "ack" and m["data"]["restore"]["applied"] and m["data"]["z_reference_set"]
            assert m["data"]["z"] == pytest.approx(z_before, abs=0.1)
    finally:
        await srv.stop()
