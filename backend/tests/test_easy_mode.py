"""The score game's easy mode (#169): catch here, wait for the destination, carry to a Dial.

The dry-run crane only (no hardware): both destinations to the end, the one-shot choice, the
expiry that moves nothing, every stop, and the server's commands and lock."""

import asyncio
import dataclasses
import json

import pytest
import websockets

from corexy_ufo_backend.config import RobotLimits, load_config
from corexy_ufo_backend.robot import MockRobot, RobotCommandError
from corexy_ufo_backend.sequence import AutoCatchConfig, AutoCatchParams, EasyParams, EasySequencer
from corexy_ufo_backend.sequence.dry_run import make_dry_run_robot
from corexy_ufo_backend.websocket import GameServer

from test_auto_catch import Rig, _cmd, _ready, fast_params

LIMITS = RobotLimits()
DIALS = {1: (20.0, 100.0), 2: (370.0, 100.0)}
GRAB = ["IDLE", "OPEN_CLAW", "LOWER_TO_CATCH", "CLOSE_CLAW", "RAISE_WITH_ITEM", "WAIT_DESTINATION"]
DELIVER = ["MOVE_TO_DIAL", "LOWER_TO_RELEASE", "RELEASE", "RAISE_EMPTY", "IDLE"]


def easy_fast(**over) -> AutoCatchParams:
    """The sped-up dry-run profile, with time for the carry across the whole X range."""
    p = fast_params()
    return dataclasses.replace(p, timeouts_s={**p.timeouts_s, "move_to_box": 6.0}, total_timeout_s=20.0, **over)


def easy_params(**over) -> EasyParams:
    return dataclasses.replace(EasyParams(profile="dry_run", dials=dict(DIALS), release_z=70.0,
                                          wait_destination_s=1.0, confirmed=True), **over)


class EasyRig(Rig):
    def __init__(self, params: AutoCatchParams | None = None, easy: EasyParams | None = None) -> None:
        super().__init__(params or easy_fast())
        self.busy_elsewhere = False
        self.seq = EasySequencer(self.robot, self.params, LIMITS, load_config(), easy=easy or easy_params(),
                                 lock=self.lock, is_jogging=lambda: self.jogging,
                                 other_active=lambda: self.busy_elsewhere, poll_s=0.005)

    async def until_state(self, state: str, timeout: float = 3.0) -> None:
        for _ in range(int(timeout / 0.002)):
            if self.seq.state == state:
                return
            await asyncio.sleep(0.002)
        raise AssertionError(f"never reached {state} (at {self.seq.state} / {self.seq.phase}: {self.seq.error})")


def test_repo_dry_run_values_are_usable_and_the_real_ones_are_refused():
    cfg = load_config()
    ac = AutoCatchConfig.from_raw(cfg.raw)
    dry = EasyParams.from_raw(cfg.raw, "dry_run")
    assert dry.problems(ac.dry_run, cfg.limits) == []
    assert dry.dials[1][0] < dry.dials[2][0]  # Dial 1 is the left one, Dial 2 the right (#138)
    # the real crane: nothing of the config stands in for a measurement
    real = EasyParams.from_raw(cfg.raw, "real", None)
    errs = real.problems(ac.real, cfg.limits)
    assert any("Dial 1" in e for e in errs) and any("Dial 2" in e for e in errs) and any("release height" in e for e in errs)
    # measured but not confirmed is still refused; confirmed is taken
    saved = {"dial_1": {"x": 10, "y": 50}, "dial_2": {"x": 380, "y": 50}, "release_z": 60}
    assert any("not confirmed" in e for e in EasyParams.from_raw(cfg.raw, "real", saved).problems(ac.dry_run, cfg.limits))
    assert EasyParams.from_raw(cfg.raw, "real", {**saved, "confirmed": True}).problems(ac.dry_run, cfg.limits) == []


@pytest.mark.parametrize("over, reason", [
    (dict(dials={1: (-5.0, 100.0), 2: DIALS[2]}), "outside the XY soft limits"),
    (dict(dials={1: DIALS[1], 2: None}), "Dial 2 drop point is not recorded"),
    (dict(release_z=10.0), "below z_floor"),
    (dict(release_z=99.0), "above safe_z"),
    (dict(release_z=None), "release height is not recorded"),
    (dict(wait_destination_s=0.0), "wait_destination_s"),
])
async def test_unusable_drop_points_refuse_the_catch_before_anything_moves(over, reason):
    async with EasyRig(easy=easy_params(**over)) as rig:
        with pytest.raises(RobotCommandError, match=reason):
            await rig.seq.start_grab()
        assert rig.robot.commands == [] and not rig.lock.locked() and rig.seq.state == "MANUAL_XY"


@pytest.mark.parametrize("dest", [1, 2])
async def test_catch_then_the_chosen_dial_runs_to_the_end(dest):
    async with EasyRig() as rig:
        await rig.seq.start_grab()
        assert rig.seq.state == "AUTO_GRAB" and rig.lock.locked()
        await rig.until_state("WAIT_DESTINATION")
        # caught: the claw closed and the arm is up again, still where it was; nothing carried yet
        assert rig.robot.commands == ["CLAW -> open", "Z -> 30.00", "CLAW -> closed", "Z -> 95.00"]
        assert rig.lock.locked() and rig.seq.status()["wait_left_s"] > 0
        rig.seq.choose(dest, rig.seq.grab_id)
        await rig.seq.wait()
        st = rig.seq.status()
        assert st["last_result"] == "done" and st["state"] == "MANUAL_XY" and st["destination"] == dest
        assert rig.phases() == GRAB + DELIVER
        x, y = DIALS[dest]
        # XY only at the safe height, then down, open, up
        assert rig.robot.commands[4:] == [f"XY {x:.3f} {y:.3f} F9000", "Z -> 70.00", "CLAW -> open", "Z -> 95.00"]
        assert abs(rig.robot.pos[0] - x) < 0.5 and abs(rig.robot.pos[1] - y) < 0.5
        assert not rig.lock.locked() and "ABORT" not in rig.robot.commands


async def test_a_choice_counts_once_only_while_waiting_and_only_for_this_catch():
    async with EasyRig() as rig:
        with pytest.raises(RobotCommandError, match="not waiting"):
            rig.seq.choose(1, "x")  # nothing caught
        await rig.seq.start_grab()
        first = rig.seq.grab_id
        with pytest.raises(RobotCommandError, match="not waiting"):
            rig.seq.choose(1, first)  # still catching
        with pytest.raises(RobotCommandError, match="already running"):
            await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        for bad in (0, 3, "1", True, None):
            with pytest.raises(RobotCommandError, match="destination must be"):
                rig.seq.choose(bad, first)
        with pytest.raises(RobotCommandError, match="stale"):
            rig.seq.choose(1, "an-older-catch")
        with pytest.raises(RobotCommandError, match="stale"):
            rig.seq.choose(1, "")
        rig.seq.choose(2, first)
        with pytest.raises(RobotCommandError, match="already chosen"):
            rig.seq.choose(1, first)  # a second sign changes nothing
        await rig.seq.wait()
        assert rig.seq.destination == 2 and sum(c.startswith("XY") for c in rig.robot.commands) == 1
        with pytest.raises(RobotCommandError, match="not waiting"):
            rig.seq.choose(1, first)  # a late repeat after the delivery: nothing
        # the next catch has its own id; the old one is stale for it
        await rig.move_xy(120.0, 100.0)
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        assert rig.seq.grab_id != first
        with pytest.raises(RobotCommandError, match="stale"):
            rig.seq.choose(1, first)
        await rig.seq.abort("test over")
        await rig.seq.wait()


async def test_no_choice_in_time_ends_expired_and_nothing_moves_or_opens():
    async with EasyRig(easy=easy_params(wait_destination_s=0.15)) as rig:
        await rig.seq.start_grab()
        await rig.seq.wait()
        st = rig.seq.status()
        assert st["state"] == "EXPIRED" and st["last_result"] == "expired" and "nothing was moved" in st["error"]
        # the claw is still closed at the safe height, where it caught; no ABORT, no alarm, homing kept
        assert rig.robot.commands == ["CLAW -> open", "Z -> 30.00", "CLAW -> closed", "Z -> 95.00"]
        assert abs(rig.robot.pos[0] - 120.0) < 0.5 and abs(rig.robot.arm_deg - rig.robot.arm_marks["closed"]) < 1e-6
        assert not rig.robot.alarm and rig.robot.homed and not rig.lock.locked()
        with pytest.raises(RobotCommandError, match="not waiting"):
            rig.seq.choose(1, rig.seq.grab_id)  # too late: it does not start by itself afterwards


@pytest.mark.parametrize("at", ["LOWER_TO_CATCH", "WAIT_DESTINATION", "MOVE_TO_DIAL", "LOWER_TO_RELEASE", "RELEASE"])
async def test_stop_in_every_part_aborts_and_nothing_follows(at):
    slow = easy_fast(virtual_claw_move_s=0.3) if at == "RELEASE" else None
    async with EasyRig(slow) as rig:
        await rig.seq.start_grab()
        if at != "LOWER_TO_CATCH":
            await rig.until_state("WAIT_DESTINATION")
        if at not in ("LOWER_TO_CATCH", "WAIT_DESTINATION"):
            rig.seq.choose(1, rig.seq.grab_id)
        await rig.until(at)  # type: ignore[arg-type]
        n = len(rig.robot.commands)
        assert await rig.seq.abort("emergency stop (stop)")
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and rig.seq.status()["last_result"] == "fault"
        assert rig.robot.commands[n:] == ["ABORT"]  # the stop, and no step after it
        assert rig.robot.alarm and not rig.robot.homed and not rig.lock.locked()
        if at == "RELEASE":
            # stopped just as the claw was to open: it did not get to "open"
            assert abs(rig.robot.arm_deg - rig.robot.arm_marks["open"]) > 1.0
        with pytest.raises(RobotCommandError, match="alarm active"):
            await rig.seq.start_grab()  # nothing restarts by itself: clear_alarm + home first


async def test_stop_right_before_the_claw_opens_never_sends_the_open():
    async with EasyRig() as rig:
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        rig.seq.choose(2, rig.seq.grab_id)
        await rig.until("LOWER_TO_RELEASE")  # type: ignore[arg-type]
        rig.seq.request_abort("emergency stop (stop)")  # the flag first, as the server's stop does
        await rig.seq.wait()
        assert rig.robot.commands.count("CLAW -> open") == 1  # the catch's own; the release's never went out


@pytest.mark.parametrize("fault, part, reason", [
    ("disconnect", "WAIT_DESTINATION", "disconnected"),
    ("stall_xy", "DELIVER", "MOVE_TO_DIAL timeout"),
    ("stall_z", "AUTO_GRAB", "LOWER_TO_CATCH timeout"),
    ("z_glitch", "WAIT_DESTINATION", "not a number"),
    ("claw_fail", "AUTO_GRAB", "OPEN_CLAW failed"),
])
async def test_a_fault_in_any_part_ends_in_fault(fault, part, reason):
    async with EasyRig(fast_params(timeouts_s={k: 0.4 for k in fast_params().timeouts_s})) as rig:
        if part == "AUTO_GRAB":
            rig.robot.inject(fault)
        await rig.seq.start_grab()
        if part != "AUTO_GRAB":
            await rig.until_state("WAIT_DESTINATION")
            rig.robot.inject(fault)
            if part == "DELIVER":
                rig.seq.choose(1, rig.seq.grab_id)
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and reason in rig.seq.error, rig.seq.error
        assert not rig.lock.locked()


async def test_motors_off_or_homing_lost_while_waiting_faults():
    async with EasyRig() as rig:
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        await rig.robot.enable_motors(False)
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and "motors disabled" in rig.seq.error


async def test_the_carry_starts_only_from_the_safe_height():
    async with EasyRig() as rig:
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        rig.robot.pos[2] = 60.0  # the reading says the arm sank while it waited
        rig.robot.target[2] = 60.0
        rig.seq.choose(1, rig.seq.grab_id)
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and "safe height" in rig.seq.error
        assert not any(c.startswith("XY") for c in rig.robot.commands)  # no XY travel below it


@pytest.mark.parametrize("setup, reason", [
    (lambda r: setattr(r.robot, "homed", False), "not homed"),
    (lambda r: setattr(r.robot, "motors_enabled", False), "motors not enabled"),
    (lambda r: setattr(r, "jogging", True), "jog active"),
    (lambda r: setattr(r, "busy_elsewhere", True), "another sequence"),
    (lambda r: r.robot.arm_marks.clear(), "claw open / closed"),
])
async def test_preconditions_refuse_the_catch(setup, reason):
    async with EasyRig() as rig:
        setup(rig)
        with pytest.raises(RobotCommandError, match=reason):
            await rig.seq.start_grab()
        assert rig.robot.commands == [] and not rig.lock.locked()


async def test_refused_while_another_motion_holds_the_lock_and_start_is_not_the_easy_start():
    async with EasyRig() as rig:
        async with rig.lock:
            with pytest.raises(RobotCommandError, match="busy"):
                await rig.seq.start_grab()
        with pytest.raises(RobotCommandError, match="easy_grab"):
            await rig.seq.start()  # the auto catch's whole run is never run through this


# ---------------------------------------------------------------- through the WebSocket server
@pytest.fixture
async def server():
    params = easy_fast()
    robot = make_dry_run_robot(params, LIMITS)
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=50, backend_cfg=load_config(),
                     auto_catch=AutoCatchConfig(real=AutoCatchParams(profile="real"), dry_run=params),
                     easy=easy_params(wait_destination_s=2.0))
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    yield srv, robot, port
    await srv.stop()


async def _until_state(ws, state: str) -> dict:
    for _ in range(600):
        msg = json.loads(await asyncio.wait_for(ws.recv(), 3))
        if msg["type"] == "robot_state" and msg["data"]["easy_mode"]["state"] == state:
            return msg["data"]["easy_mode"]
    raise AssertionError(f"never saw {state}")


@pytest.mark.parametrize("dest", [1, 2])
async def test_server_runs_catch_and_delivery_and_locks_manual_control(server, dest):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        r = await _cmd(ws, "g1", "easy_grab")
        assert r["type"] == "ack" and r["data"]["active"] and r["data"]["state"] == "AUTO_GRAB"
        gid = r["data"]["grab_id"]
        st = await _until_state(ws, "WAIT_DESTINATION")
        assert st["grab_id"] == gid
        # the lock is held through the wait: no manual move, no jog, no other sequence, no second catch
        for rid, name, params in [("x1", "move_xy", dict(x=10, y=10)), ("x2", "jog", dict(vx=10, vy=0)),
                                  ("x3", "move_z", dict(z=50)), ("x4", "arm_goto", dict(which="open")),
                                  ("x5", "auto_catch", {}), ("x6", "easy_grab", {}), ("x7", "calibration_prepare", {}),
                                  ("x8", "clear_alarm", {})]:
            r = await _cmd(ws, rid, name, **params)
            assert r["type"] == "nack" and "busy" in r["data"]["reason"], (name, r)
        assert (await _cmd(ws, "z0", "jog", vx=0, vy=0, vz=0))["type"] == "ack"  # key release is fine
        r = await _cmd(ws, "d0", "easy_deliver", destination=dest, grab_id="not-this-one")
        assert r["type"] == "nack" and "stale" in r["data"]["reason"]
        r = await _cmd(ws, "d1", "easy_deliver", destination=dest, grab_id=gid)
        assert r["type"] == "ack"
        # the same request again (a resend) is answered from the cache, not run again
        await ws.send(json.dumps({"type": "command", "request_id": "d1",
                                  "data": {"name": "easy_deliver", "params": {"destination": dest, "grab_id": gid}}}))
        r = await _cmd(ws, "d2", "easy_deliver", destination=3 - dest, grab_id=gid)
        assert r["type"] == "nack"  # the other Dial after the choice: refused
        await srv.easy.wait()
        st = (await _cmd(ws, "s1", "easy_status"))["data"]
        assert st["last_result"] == "done" and st["destination"] == dest and st["state"] == "MANUAL_XY"
        assert st["problems"] == [] and st["dials"]["dial_1"] == [20.0, 100.0]
        assert sum(c.startswith("XY") for c in robot.commands) == 2  # _ready's own move and one carry
        assert abs(robot.pos[0] - DIALS[dest][0]) < 0.5
        assert (await _cmd(ws, "m2", "move_xy", x=100, y=100))["type"] == "ack"  # manual again


@pytest.mark.parametrize("stop", ["stop", "soft_stop"])
async def test_server_stop_while_waiting_for_the_destination_aborts(server, stop):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "s", stop))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.state == "FAULT" and robot.commands.count("ABORT") == 1 and robot.alarm
        r = await _cmd(ws, "d1", "easy_deliver", destination=1, grab_id=gid)
        assert r["type"] == "nack"  # a sign that was on its way: nothing is carried after a stop
        assert not any(c.startswith("XY") for c in robot.commands[1:])
        r = await _cmd(ws, "g2", "easy_grab")
        assert r["type"] == "nack" and "alarm active" in r["data"]["reason"]


@pytest.mark.parametrize("when", ["AUTO_GRAB", "WAIT_DESTINATION", "DELIVER_DIAL_1"])
async def test_server_aborts_when_the_game_disconnects(server, when):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        if when != "AUTO_GRAB":
            await _until_state(ws, "WAIT_DESTINATION")
        if when == "DELIVER_DIAL_1":
            assert (await _cmd(ws, "d1", "easy_deliver", destination=1, grab_id=gid))["type"] == "ack"
    await srv.easy.wait()
    assert srv.easy.state == "FAULT" and "disconnected" in srv.easy.error
    assert robot.commands[-1] == "ABORT"  # nothing went on, nothing was released after it


async def test_server_motors_off_while_waiting_aborts(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        await _cmd(ws, "g1", "easy_grab")
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "e0", "enable_motors", enable=False))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.state == "FAULT" and "ABORT" in robot.commands


async def test_easy_grab_is_refused_while_another_sequence_runs(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "a1", "auto_catch"))["type"] == "ack"
        r = await _cmd(ws, "g1", "easy_grab")
        assert r["type"] == "nack" and "busy" in r["data"]["reason"]
        assert (await _cmd(ws, "s", "stop"))["type"] == "ack"
        await srv.auto.wait()


async def test_real_robot_is_refused_until_measured_and_confirmed(tmp_path):
    class FakeReal(MockRobot):
        name = "real"

    robot = FakeReal()
    await robot.connect()
    cfg = load_config()
    cfg.easy_dials_path = tmp_path / "easy_dials.json"
    srv = GameServer(robot, "127.0.0.1", 0, backend_cfg=cfg, auto_catch=AutoCatchConfig.from_raw(cfg.raw))
    await robot.enable_motors(True)
    await robot.home()
    robot._homing_until = 0.0
    r = await srv.execute("easy_grab", {})
    assert r["type"] == "nack" and "Dial 1 drop point is not recorded" in r["data"]["reason"]
    assert "not confirmed on the real machine" in r["data"]["reason"] or "is not set" in r["data"]["reason"]
    # recording: where the arm is now, saved unconfirmed; confirming needs all three
    assert (await srv.execute("easy_dial_set", {"which": "nowhere"}))["type"] == "nack"
    robot.pos[0], robot.pos[1] = 15.0, 90.0
    robot.target[0], robot.target[1] = 15.0, 90.0
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "ack" and r["data"]["dials"]["dial_1"] == [15.0, 90.0] and not r["data"]["dials"]["confirmed"]
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "nack" and "Dial 2" in r["data"]["reason"]
    robot.pos[0] = robot.target[0] = 375.0
    assert (await srv.execute("easy_dial_set", {"which": "dial_2"}))["type"] == "ack"
    robot.z_reference_set = False
    r = await srv.execute("easy_dial_set", {"which": "release_z"})
    assert r["type"] == "nack"  # no Z reference: the reading means nothing
    saved = json.loads(cfg.easy_dials_path.read_text())
    assert saved["dial_2"] == {"x": 375.0, "y": 90.0} and saved["confirmed"] is False and "release_z" not in saved
    robot.z_reference_set = True
    robot.pos[2] = robot.target[2] = 60.0
    r = await srv.execute("easy_dial_set", {"which": "release_z"})
    assert r["type"] == "ack" and r["data"]["dials"]["release_z"] == 60.0
    # the catch's own profile is unmeasured (auto_catch.real): its heights cannot be checked
    # against, so the drop points are confirmed on their own and the catch stays refused
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "ack" and r["data"]["dials"]["confirmed"] and r["data"]["problems"]
    assert json.loads(cfg.easy_dials_path.read_text())["confirmed"] is True
    r = await srv.execute("easy_grab", {})
    assert r["type"] == "nack" and "easy catch refused" in r["data"]["reason"]
    # a change after the confirmation takes it back
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "ack" and not r["data"]["dials"]["confirmed"]
    assert (await srv.execute("easy_dial_set", {"which": "clear"}))["data"]["dials"]["dial_1"] is None


async def test_the_dry_run_crane_does_not_record_drop_points(server):
    srv, robot, port = server
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "nack" and "仮想クレーン" in r["data"]["reason"]
    assert (await srv.execute("easy_dial_confirm", {}))["type"] == "nack"
