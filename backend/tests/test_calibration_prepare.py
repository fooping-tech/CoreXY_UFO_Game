"""#167: the 校正 tab's one-button preparation: motors, the drum's tracking, the last
session's Z points, the arm to the top, the claw open / closed, home."""

from __future__ import annotations

import asyncio

import pytest
import websockets

from conftest import FakeFirmware
from corexy_ufo_backend.robot import RealRobot
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.sequence.prepare import STEPS, PrepareSequencer
from corexy_ufo_backend.serial_service import SerialService
from corexy_ufo_backend.websocket.server import GameServer
from ws_helpers import cmd as _cmd
from test_z_restore import cfg_for, first_session


def states(seq: PrepareSequencer) -> dict[str, str]:
    return {s["key"]: s["state"] for s in seq.status()["steps"]}


async def run(seq: PrepareSequencer) -> dict:
    await seq.start()
    await asyncio.wait_for(seq.wait(), 30)
    return seq.status()


async def test_the_mock_robot_is_prepared(tmp_path):
    robot = MockRobot()
    await robot.connect()
    await robot.arm_set("open")
    robot.arm_deg = 40.0
    await robot.arm_set("closed")
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)
    st = await run(seq)
    s = robot.snapshot()
    assert st["last_result"] == "done" and not st["active"] and st["error"] == ""
    assert s.motors_enabled and s.homed
    assert states(seq) == {"motors": "done", "z_track": "skip", "z_restore": "skip", "z_top": "skip",
                           "claw_open": "done", "claw_close": "done", "home": "done", "center": "skip",
                           "claw_ready": "done", "easy": "skip"}
    assert robot.arm_deg != 40.0 and robot.arm_deg == robot.arm_marks["open"]  # left open, ready to catch (#175)
    assert not seq.lock.locked()


async def test_an_unrecorded_claw_is_skipped(tmp_path):
    robot = MockRobot()
    await robot.connect()
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)
    st = await run(seq)
    assert st["last_result"] == "done" and states(seq)["claw_open"] == "skip"
    assert "未記録" in {s["key"]: s["note"] for s in st["steps"]}["claw_open"]


async def test_the_real_robot_after_a_power_cycle(tmp_path):
    """The drum is not tracked yet: a short jog up starts it, the last points are called back,
    the arm goes to the top, then home."""
    last, top, _ = await first_session(tmp_path)

    def factory(*a, **k):
        t = FakeFirmware(*a, **k)
        t.servo_abs[1] = last
        t.servo_tracking[1] = False
        t.servo_limits[1] = "0/4095"  # a servo just powered up
        return t
    robot = RealRobot(cfg_for(tmp_path), SerialService("fake", transport_factory=factory))
    await robot.connect()
    try:
        seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.05)
        st = await run(seq)
        assert st["last_result"] == "done", st
        assert states(seq) == {"motors": "done", "z_track": "done", "z_restore": "done", "z_top": "done",
                               "claw_open": "skip", "claw_close": "skip", "home": "done", "center": "skip",
                               "claw_ready": "skip", "easy": "skip"}
        sent = robot.serial.transport.sent
        assert any(l.startswith("JOG 0.0 0.0 ") and int(l.split()[3]) > 0 for l in sent)  # up, to start tracking
        s = robot.snapshot()
        assert s.motors_enabled and s.homed and s.z_top_set and s.z_bottom_set
        assert s.z == pytest.approx(100.0, abs=0.5)  # wound up to the top
    finally:
        await robot.disconnect()


async def test_a_drum_turned_too_far_stops_with_what_to_do(tmp_path):
    last, _, _ = await first_session(tmp_path)

    def factory(*a, **k):
        t = FakeFirmware(*a, **k)
        t.servo_abs[1] = last + 2000  # half a turn away: cannot be told from the next turn
        return t
    robot = RealRobot(cfg_for(tmp_path), SerialService("fake", transport_factory=factory))
    await robot.connect()
    try:
        seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)
        st = await run(seq)
        assert st["last_result"] == "fault" and states(seq)["z_restore"] == "fail"
        assert "ここを上に記録" in st["error"] and states(seq)["home"] == "todo"
        assert not robot.snapshot().homed and not seq.lock.locked()
    finally:
        await robot.disconnect()


async def test_a_stop_aborts_it():
    robot = MockRobot()
    await robot.connect()
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)
    await seq.start()
    assert await seq.abort("emergency stop (stop)")
    await asyncio.wait_for(seq.wait(), 5)
    st = seq.status()
    assert st["last_result"] == "fault" and st["error"] == "emergency stop (stop)" and not st["active"]
    assert not robot.snapshot().homed


async def test_a_step_that_takes_too_long_stops_the_robot_before_the_lock_is_let_go():
    """Review on #168: cancelling the wait does not stop the firmware: ABORT first."""
    class SlowHome(MockRobot):
        async def home(self) -> None:
            await asyncio.sleep(10)

    robot = SlowHome()
    await robot.connect()
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0, step_timeout_s=0.05)
    import corexy_ufo_backend.sequence.prepare as prepare_mod
    old = dict(prepare_mod.STEP_TIMEOUT_S)
    prepare_mod.STEP_TIMEOUT_S["home"] = 0.1
    try:
        st = await run(seq)
    finally:
        prepare_mod.STEP_TIMEOUT_S.clear()
        prepare_mod.STEP_TIMEOUT_S.update(old)
    assert st["last_result"] == "fault" and states(seq)["home"] == "fail" and "ABORT" in st["error"]
    assert robot.snapshot().alarm  # the mock's stop = ABORT: alarm
    assert not seq.lock.locked()


async def test_the_tracking_jog_goes_up_whichever_way_z_counts():
    """Review on #168: with z_up_is_positive false, up is a negative Z speed."""
    from corexy_ufo_backend.config import RobotLimits

    class RealLike(MockRobot):
        name = "real"

        def __init__(self) -> None:
            super().__init__(limits=RobotLimits(z_up_is_positive=False))
            self.jogs: list[float] = []
            self.asked = 0

        async def restore_z_points(self, apply, turns=None):
            self.asked += 1
            from corexy_ufo_backend.robot.interface import RobotCommandError
            raise RobotCommandError("巻き上げサーボの回転の追跡がまだ始まっていない: W か S を一瞬押してから、もう一度")

        async def jog(self, vx, vy, vz=0.0, *, z_free=False):
            self.jogs.append(vz)

    robot = RealLike()
    await robot.connect()
    await robot.enable_motors(True)
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), settle_s=0.0)
    note = await seq._do_z_track()
    assert robot.jogs[0] < 0 and robot.jogs[-1] == 0.0 and "巻き上げ" in note


async def test_refused_while_busy():
    robot = MockRobot()
    await robot.connect()
    lock = asyncio.Lock()
    await lock.acquire()
    seq = PrepareSequencer(robot, lock=lock)
    with pytest.raises(Exception, match="busy"):
        await seq.start()
    seq2 = PrepareSequencer(robot, lock=asyncio.Lock(), is_jogging=lambda: True)
    with pytest.raises(Exception, match="jog"):
        await seq2.start()


async def test_the_server_runs_it_and_reports_it():
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "calibration_prepare", rid="p1")
            assert m["type"] == "ack" and [s["key"] for s in m["data"]["steps"]] == [k for k, _ in STEPS]
            await asyncio.wait_for(srv.prepare.wait(), 10)
            st = await _cmd(ws, "calibration_prepare_status", rid="p2")
            assert st["data"]["last_result"] == "done"
            state = await _cmd(ws, "get_state", rid="p3")
            assert state["data"]["calibration_prepare"]["last_result"] == "done" and state["data"]["homed"]
    finally:
        await srv.stop()


async def test_after_homing_the_arm_goes_to_the_middle_of_the_stage(tmp_path):
    """#175: homed in the corner, then on to the centre of the soft limits (or the configured point)."""
    from corexy_ufo_backend.config import BackendConfig
    from corexy_ufo_backend.websocket.server import GameServer
    cfg = BackendConfig()
    assert cfg.home_center() == (195.0, 100.0)
    cfg.home_center_mm = (120.0, 60.0)
    assert cfg.home_center() == (120.0, 60.0)
    cfg.home_center_mm = (999.0, 60.0)  # outside the soft limits: the middle instead
    assert cfg.home_center() == (195.0, 100.0)
    cfg.home_then_center = False
    assert cfg.home_center() is None

    async def settle(robot):
        for _ in range(2000):
            await robot.tick()
            if robot.snapshot().state == "IDLE" and robot.vel[0] == 0.0 and robot.vel[1] == 0.0 and robot._homing_until < 1e12:
                if abs(robot.pos[0] - robot.target[0]) < 1e-3 and abs(robot.pos[1] - robot.target[1]) < 1e-3:
                    return
            await asyncio.sleep(0.001)

    # the home command
    robot = MockRobot()
    await robot.connect()
    cfg = BackendConfig()
    srv = GameServer(robot, "127.0.0.1", 0, backend_cfg=cfg)
    robot.pos[0] = robot.target[0] = 30.0
    assert (await srv.execute("home", {}))["type"] == "nack"  # motors off: no homing, no move
    assert robot.target[0] == 30.0
    await srv.execute("enable_motors", {"enable": True})
    assert (await srv.execute("home", {}))["type"] == "ack"
    robot._homing_until = 0.0
    await settle(robot)
    assert robot.snapshot().homed and robot.pos[0] == pytest.approx(195.0, abs=0.5) and robot.pos[1] == pytest.approx(100.0, abs=0.5)
    # off: it stays in the home corner, as before
    cfg.home_then_center = False
    await srv.execute("move_xy", {"x": 50, "y": 50})
    assert (await srv.execute("home", {}))["type"] == "ack"
    assert (robot.target[0], robot.target[1]) == (0.0, 0.0)
    # the middle cannot be reached (a move refused): the answer says the arm is homed but did not get there
    cfg.home_then_center = True

    async def refuse(x, y, feed=None):
        from corexy_ufo_backend.robot import RobotCommandError
        raise RobotCommandError("XY refused")
    robot.move_xy = refuse
    r = await srv.execute("home", {})
    assert r["type"] == "nack" and "homed, but" in r["data"]["reason"] and robot.snapshot().homed

    # the preparation: its own step after homing
    robot2 = MockRobot()
    await robot2.connect()
    seq = PrepareSequencer(robot2, lock=asyncio.Lock(), settle_s=0.0, center=lambda: (195.0, 100.0))
    st = await run(seq)
    notes = {s["key"]: s["note"] for s in st["steps"]}
    assert st["last_result"] == "done" and states(seq)["center"] == "done" and "X 195" in notes["center"]
    assert (robot2.target[0], robot2.target[1]) == (195.0, 100.0)
    order = [k for k, _ in STEPS]
    assert order.index("home") < order.index("center") < order.index("claw_ready") < order.index("easy")
    # homing refused: the preparation stops there, nothing moves to the middle
    robot3 = MockRobot()
    await robot3.connect()

    async def no_home():
        from corexy_ufo_backend.robot import RobotCommandError
        raise RobotCommandError("home refused")
    robot3.home = no_home
    robot3.pos[0] = robot3.target[0] = 30.0
    seq3 = PrepareSequencer(robot3, lock=asyncio.Lock(), settle_s=0.0, center=lambda: (195.0, 100.0))
    st3 = await run(seq3)
    assert st3["last_result"] == "fault" and states(seq3)["home"] == "fail" and states(seq3)["center"] == "todo"
    assert robot3.target[0] == 30.0


async def test_the_move_to_the_middle_after_homing_uses_the_quick_feed():
    """#179: the move to the middle (the home command and the preparation) is sent with
    backend.xy_fast_feed_mm_min; without one, the usual feed."""
    from corexy_ufo_backend.config import BackendConfig, load_config
    from corexy_ufo_backend.sequence.prepare import PrepareSequencer
    from corexy_ufo_backend.websocket.server import GameServer
    assert load_config().xy_fast_feed_mm_min == 15900.0  # the repository's value: just under the firmware's clamp
    cfg = BackendConfig()
    assert cfg.fast_feed() == cfg.xy_feed_mm_min  # none configured
    cfg.xy_fast_feed_mm_min = 12000.0
    robot = MockRobot()
    await robot.connect()
    feeds = []
    plain = robot.move_xy

    async def spy(x, y, feed=None):
        feeds.append(feed)
        await plain(x, y, feed)
    robot.move_xy = spy
    srv = GameServer(robot, "127.0.0.1", 0, backend_cfg=cfg)
    await srv.execute("enable_motors", {"enable": True})
    assert (await srv.execute("home", {}))["type"] == "ack"
    assert feeds == [12000.0]
    # an ordinary move_xy keeps the usual feed (none given: the robot's own)
    await srv.execute("move_xy", {"x": 50, "y": 50})
    assert feeds == [12000.0, None]
    # the preparation's step
    seq = PrepareSequencer(robot, lock=asyncio.Lock(), center=cfg.home_center, center_feed=cfg.fast_feed)
    await seq._do_center()
    assert feeds[-1] == 12000.0
