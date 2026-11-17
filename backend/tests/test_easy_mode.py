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
    saved = {"dial_1": {"x": 10, "y": 50}, "dial_2": {"x": 380, "y": 50}, "release_z": 60, "catch_z": 30}
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


# ---------------------------------------------------------------- the arm left down (#177)
async def _lower(rig, z: float) -> None:
    await rig.robot.move_z(z)
    for _ in range(1000):
        if abs(rig.robot.pos[2] - z) < 1e-3 and rig.robot.snapshot().state == "IDLE":
            break
        await asyncio.sleep(0.005)
    rig.robot.commands.clear()


@pytest.mark.parametrize("z", [40.0, 5.0])  # above the catch height, and below it (lower than the usual floor)
async def test_a_fist_with_the_arm_down_closes_where_it_is_and_comes_up(z):
    async with EasyRig() as rig:
        await _lower(rig, z)
        await rig.seq.start_grab()
        await rig.until_state("WAIT_DESTINATION")
        # nothing went down, the claw was not opened first: closed where it was, then up
        assert rig.robot.commands == ["CLAW -> closed", "Z -> 95.00"]
        assert rig.phases() == ["IDLE", "CLOSE_CLAW", "RAISE_WITH_ITEM", "WAIT_DESTINATION"]
        assert abs(rig.robot.pos[0] - 120.0) < 0.5 and abs(rig.robot.pos[2] - 95.0) < 1.0
        # up: the validated floor and bounds count again for the wait and the carry
        assert rig.seq.active and rig.seq._strict is None and rig.seq.params.z_floor == 20.0
        assert rig.seq.params.max_drop_units == 80.0
        # and from there it is the usual run
        rig.seq.choose(1, rig.seq.grab_id)
        await rig.seq.wait()
        assert rig.seq.status()["last_result"] == "done" and "ABORT" not in rig.robot.commands
        assert rig.seq.params.z_floor == 20.0 and rig.seq._strict is None  # the validated bounds are back


@pytest.mark.parametrize("z", [95.0, 40.0, 5.0])
async def test_reset_opens_the_claw_and_raises_the_arm_from_any_height(z):
    async with EasyRig() as rig:
        await _lower(rig, z)
        await rig.seq.start_reset()
        assert rig.seq.state == "RESET" and rig.lock.locked()
        with pytest.raises(RobotCommandError, match="not waiting"):
            rig.seq.choose(1, rig.seq.grab_id)  # a reset takes no destination
        with pytest.raises(RobotCommandError, match="already running"):
            await rig.seq.start_grab()
        await rig.seq.wait()
        st = rig.seq.status()
        assert st["state"] == "MANUAL_XY" and st["last_result"] == "done" and not rig.lock.locked()
        # opened where it was (not from the top), then up; no XY, no wait
        assert rig.robot.commands == ["CLAW -> open", "Z -> 95.00"]
        assert abs(rig.robot.pos[2] - 95.0) < 1.0 and abs(rig.robot.arm_deg - rig.robot.arm_marks["open"]) < 1e-6
        assert abs(rig.robot.pos[0] - 120.0) < 0.5 and rig.seq._strict is None
        # a catch is possible again
        await rig.seq.start_grab()
        await rig.seq.abort("test over")
        await rig.seq.wait()


async def test_reset_works_without_drop_points_and_is_refused_like_any_run():
    async with EasyRig(easy=easy_params(dials={1: None, 2: None}, release_z=None)) as rig:
        await _lower(rig, 40.0)
        await rig.seq.start_reset()  # the way up needs no Dial
        await rig.seq.wait()
        assert rig.seq.status()["last_result"] == "done"
    for setup, reason in [(lambda r: setattr(r.robot, "homed", False), "not homed"),
                          (lambda r: setattr(r.robot, "motors_enabled", False), "motors not enabled"),
                          (lambda r: setattr(r, "busy_elsewhere", True), "another sequence"),
                          (lambda r: setattr(r, "jogging", True), "jog active")]:
        async with EasyRig() as rig:
            setup(rig)
            with pytest.raises(RobotCommandError, match=reason):
                await rig.seq.start_reset()
            assert rig.robot.commands == [] and not rig.lock.locked()


@pytest.mark.parametrize("run", ["reset", "low_grab"])
async def test_stop_on_the_way_up_aborts(run):
    async with EasyRig() as rig:
        await _lower(rig, 25.0)
        await (rig.seq.start_reset() if run == "reset" else rig.seq.start_grab())
        await rig.until("RAISE_EMPTY" if run == "reset" else "RAISE_WITH_ITEM")  # type: ignore[arg-type]
        n = len(rig.robot.commands)
        assert await rig.seq.abort("emergency stop (stop)")
        await rig.seq.wait()
        assert rig.seq.state == "FAULT" and rig.robot.commands[n:] == ["ABORT"] and not rig.lock.locked()
        assert rig.seq._strict is None and rig.seq.params.z_floor == 20.0


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
        # the move to the middle after homing (#175), _ready's own move and one carry
        assert sum(c.startswith("XY") for c in robot.commands) == 3
        assert abs(robot.pos[0] - DIALS[dest][0]) < 0.5
        assert (await _cmd(ws, "m2", "move_xy", x=100, y=100))["type"] == "ack"  # manual again


async def test_server_emergency_stop_while_waiting_for_the_destination_aborts(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "s", "stop"))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.state == "FAULT" and robot.commands.count("ABORT") == 1 and robot.alarm
        r = await _cmd(ws, "d1", "easy_deliver", destination=1, grab_id=gid)
        assert r["type"] == "nack"  # a sign that was on its way: nothing is carried after a stop
        # (the move to the middle after homing and _ready's own: no carry)
        assert sum(c.startswith("XY") for c in robot.commands) == 2
        r = await _cmd(ws, "g2", "easy_grab")
        assert r["type"] == "nack" and "alarm active" in r["data"]["reason"]


async def test_server_soft_stop_while_waiting_ends_the_run_without_an_alarm(server):
    """#179: the game's stop key while nothing moves: no ABORT, no alarm, homing kept, the claw
    still closed; nothing is carried afterwards. While it moves, the stop key is ABORT as ever."""
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "s", "soft_stop"))["type"] == "ack"
        await srv.easy.wait()
        st = srv.easy.status()
        assert st["state"] == "STOPPED" and st["last_result"] == "stopped" and "nothing was moved" in st["error"]
        assert "ABORT" not in robot.commands and not robot.alarm and robot.snapshot().homed
        assert abs(robot.arm_deg - robot.arm_marks["closed"]) < 1e-6 and not srv._motion_lock.locked()
        r = await _cmd(ws, "d1", "easy_deliver", destination=1, grab_id=gid)
        assert r["type"] == "nack"  # too late: nothing is carried after the stop
        assert (await _cmd(ws, "c1", "easy_cancel", grab_id=gid))["type"] == "nack"
        # the next game's start brings the arm to its start again (the claw open), no clear_alarm needed
        assert (await _cmd(ws, "r1", "easy_reset"))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.status()["last_result"] == "done"
        # while it moves: ABORT, as ever
        assert (await _cmd(ws, "g2", "easy_grab"))["type"] == "ack"
        await asyncio.sleep(0.05)
        assert (await _cmd(ws, "s2", "soft_stop"))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.state == "FAULT" and "ABORT" in robot.commands and robot.alarm


async def test_server_cancel_opens_the_claw_and_gives_the_crane_back(server):
    """#179: the claw came up empty: easy_cancel while it waits opens the claw where it is."""
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        assert (await _cmd(ws, "c0", "easy_cancel", grab_id=gid))["type"] == "nack"  # still catching
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "c1", "easy_cancel", grab_id="another"))["type"] == "nack"
        n = len(robot.commands)
        assert (await _cmd(ws, "c2", "easy_cancel", grab_id=gid))["type"] == "ack"
        assert (await _cmd(ws, "d1", "easy_deliver", destination=1, grab_id=gid))["type"] == "nack"  # given up: not carried
        await srv.easy.wait()
        st = srv.easy.status()
        assert st["state"] == "MANUAL_XY" and st["last_result"] == "cancelled" and st["destination"] == 0
        assert robot.commands[n:] == ["CLAW -> open"] and abs(robot.pos[0] - 120) < 0.5 and abs(robot.pos[2] - 95) < 1.0
        assert not robot.alarm and not srv._motion_lock.locked()
        assert (await _cmd(ws, "c3", "easy_cancel", grab_id=gid))["type"] == "nack"  # a repeat: nothing
        # and again: catch, this time carried
        gid2 = (await _cmd(ws, "g2", "easy_grab"))["data"]["grab_id"]
        await _until_state(ws, "WAIT_DESTINATION")
        assert (await _cmd(ws, "d2", "easy_deliver", destination=2, grab_id=gid2))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.status()["last_result"] == "done"


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


async def test_server_reset_and_the_fist_with_the_arm_down(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "z1", "move_z", z=35))["type"] == "ack"
        for _ in range(500):
            if abs(robot.pos[2] - 35) < 1e-3 and robot.snapshot().state == "IDLE":
                break
            await asyncio.sleep(0.01)
        r = await _cmd(ws, "r1", "easy_reset")
        assert r["type"] == "ack" and r["data"]["state"] == "RESET" and r["data"]["grab_id"]
        r2 = await _cmd(ws, "x1", "move_xy", x=10, y=10)
        assert r2["type"] == "nack" and "busy" in r2["data"]["reason"]  # the lock, as for any run
        await srv.easy.wait()
        st = (await _cmd(ws, "s1", "easy_status"))["data"]
        assert st["state"] == "MANUAL_XY" and st["last_result"] == "done" and abs(robot.pos[2] - 95) < 1.0
        # down again, then a fist: closed there and raised, then the usual wait
        assert (await _cmd(ws, "z2", "move_z", z=35))["type"] == "ack"
        for _ in range(500):
            if abs(robot.pos[2] - 35) < 1e-3 and robot.snapshot().state == "IDLE":
                break
            await asyncio.sleep(0.01)
        n = len(robot.commands)
        gid = (await _cmd(ws, "g1", "easy_grab"))["data"]["grab_id"]
        await _until_state(ws, "WAIT_DESTINATION")
        assert robot.commands[n:] == ["CLAW -> closed", "Z -> 95.00"]
        assert (await _cmd(ws, "d1", "easy_deliver", destination=2, grab_id=gid))["type"] == "ack"
        await srv.easy.wait()
        assert srv.easy.status()["last_result"] == "done"


async def test_server_aborts_a_reset_when_the_game_disconnects(server):
    srv, robot, port = server
    robot.claw_move_s = 0.5
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "r1", "easy_reset"))["type"] == "ack"
    await srv.easy.wait()
    assert srv.easy.state == "FAULT" and "disconnected" in srv.easy.error


async def test_easy_grab_is_refused_while_another_sequence_runs(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "a1", "auto_catch"))["type"] == "ack"
        r = await _cmd(ws, "g1", "easy_grab")
        assert r["type"] == "nack" and "busy" in r["data"]["reason"]
        assert (await _cmd(ws, "s", "stop"))["type"] == "ack"
        await srv.auto.wait()


class FakeReal(MockRobot):
    name = "real"

    class _Cal:
        counts_per_unit = 90.0

        def complete(self) -> bool:
            return True

    z_cal = _Cal()


async def _real_server(tmp_path, saved: dict | None = None):
    robot = FakeReal()
    await robot.connect()
    cfg = load_config()
    cfg.easy_dials_path = tmp_path / "easy_dials.json"
    if saved is not None:
        cfg.easy_dials_path.write_text(json.dumps(saved))
    srv = GameServer(robot, "127.0.0.1", 0, backend_cfg=cfg, auto_catch=AutoCatchConfig.from_raw(cfg.raw))
    await robot.enable_motors(True)
    await robot.home()
    robot._homing_until = 0.0
    return srv, robot, cfg


def _at(robot, x=None, y=None, z=None) -> None:
    for i, v in enumerate((x, y, z)):
        if v is not None:
            robot.pos[i] = robot.target[i] = v


async def test_real_robot_is_refused_until_measured_and_confirmed(tmp_path):
    srv, robot, cfg = await _real_server(tmp_path)
    r = await srv.execute("easy_grab", {})
    assert r["type"] == "nack" and "Dial 1 drop point is not recorded" in r["data"]["reason"]
    assert "the catch height is not recorded" in r["data"]["reason"]
    # recording: where the arm is now, saved unconfirmed; confirming needs all four
    assert (await srv.execute("easy_dial_set", {"which": "nowhere"}))["type"] == "nack"
    _at(robot, 15.0, 90.0)
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "ack" and r["data"]["dials"]["dial_1"] == [15.0, 90.0] and not r["data"]["dials"]["confirmed"]
    assert (await srv.execute("easy_dial_set", {"which": "dial_2"}))["type"] == "ack"  # the same place again
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "nack" and "same place" in r["data"]["reason"]
    _at(robot, 375.0)
    assert (await srv.execute("easy_dial_set", {"which": "dial_2"}))["type"] == "ack"
    robot.z_reference_set = False
    r = await srv.execute("easy_dial_set", {"which": "release_z"})
    assert r["type"] == "nack"  # no Z reference: the reading means nothing
    robot.z_reference_set = True
    _at(robot, z=60.0)
    r = await srv.execute("easy_dial_set", {"which": "release_z"})
    assert r["type"] == "ack" and r["data"]["dials"]["release_z"] == 60.0
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "nack" and "catch height" in r["data"]["reason"]
    _at(robot, z=25.0)
    assert (await srv.execute("easy_dial_set", {"which": "catch_z"}))["type"] == "ack"
    saved = json.loads(cfg.easy_dials_path.read_text())
    assert saved["dial_2"] == {"x": 375.0, "y": 90.0} and saved["confirmed"] is False and saved["catch_z"] == 25.0
    assert saved["z_counts_per_unit"] == 90.0 and saved["saved_at"]
    r = await srv.execute("easy_grab", {})
    assert r["type"] == "nack" and "not confirmed" in r["data"]["reason"]  # recorded is not yet watched
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "ack" and r["data"]["dials"]["confirmed"] and r["data"]["problems"] == []
    # the catch's profile is built from the measurements: the top as the travel height, the
    # recorded heights, the descent bounded by exactly what was recorded
    p = srv.easy.params
    assert p.profile == "real" and p.safe_z == 100.0 and p.catch_z == 25.0 and p.release_z == 60.0 and p.z_floor == 25.0
    assert p.max_drop_units == 76.0 and all(p.confirmed.values()) and p.xy_feed_mm_min == cfg.fast_feed()
    # a change after the confirmation takes it back
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "ack" and not r["data"]["dials"]["confirmed"]
    assert (await srv.execute("easy_dial_set", {"which": "clear"}))["data"]["dials"]["dial_1"] is None


SAVED = {"dial_1": {"x": 15.0, "y": 90.0}, "dial_2": {"x": 375.0, "y": 90.0}, "release_z": 60.0, "catch_z": 25.0,
         "z_counts_per_unit": 90.0, "confirmed": True, "saved_at": "2026-11-17T10:00:00"}


async def test_the_last_sessions_values_are_used_without_recording_again(tmp_path):
    srv, robot, cfg = await _real_server(tmp_path, SAVED)  # a new start: the file is all there is
    st = (await srv.execute("easy_status", {}))["data"]
    assert st["problems"] == [] and st["dials"]["confirmed"] and st["dials"]["saved_at"] == "2026-11-17T10:00:00"
    note = srv._easy_prepare_note()
    assert note.startswith("前回の値を使う") and "X 375" in note and "キャッチ Z 25.0" in note
    # and the real profile really runs with them (the mock stands in for the crane)
    robot.arm_marks = {"closed": 0.0, "open": -120.0}
    _at(robot, 120.0, 100.0, 100.0)
    tick = asyncio.get_running_loop().create_task(_tick_forever(robot))
    try:
        r = await srv.execute("easy_grab", {})
        assert r["type"] == "ack", r
        for _ in range(3000):
            if srv.easy.state == "WAIT_DESTINATION":
                break
            await asyncio.sleep(0.01)
        assert srv.easy.state == "WAIT_DESTINATION", (srv.easy.state, srv.easy.error)
        assert (await srv.execute("easy_deliver", {"destination": 2, "grab_id": srv.easy.grab_id}))["type"] == "ack"
        await asyncio.wait_for(srv.easy.wait(), 60)
        assert srv.easy.status()["last_result"] == "done" and abs(robot.pos[0] - 375.0) < 1.0
    finally:
        tick.cancel()


async def _tick_forever(robot) -> None:
    while True:
        await robot.tick()
        await asyncio.sleep(0.002)


async def test_heights_recorded_before_z_was_measured_again_are_stale(tmp_path):
    srv, robot, cfg = await _real_server(tmp_path, {**SAVED, "z_counts_per_unit": 120.0})
    st = (await srv.execute("easy_status", {}))["data"]
    assert st["dials"]["stale_z"] and any("measured again" in p for p in st["problems"])
    assert srv._easy_prepare_note().startswith("skip: まだ使えない")
    r = await srv.execute("easy_grab", {})
    assert r["type"] == "nack" and "measured again" in r["data"]["reason"]
    # (a file from before the scale was saved with it is stale too)
    older = {k: v for k, v in SAVED.items() if k != "z_counts_per_unit"}
    srv2, _, _ = await _real_server(tmp_path, older)
    assert (await srv2.execute("easy_status", {}))["data"]["dials"]["stale_z"]
    # recording one height again drops the other old one; both again, then confirmed: usable
    _at(robot, z=30.0)
    r = await srv.execute("easy_dial_set", {"which": "catch_z"})
    assert r["type"] == "ack" and r["data"]["dials"]["release_z"] is None and not r["data"]["dials"]["stale_z"]
    _at(robot, z=65.0)
    assert (await srv.execute("easy_dial_set", {"which": "release_z"}))["type"] == "ack"
    r = await srv.execute("easy_dial_confirm", {})
    assert r["type"] == "ack" and r["data"]["problems"] == []


async def test_the_preparation_says_whether_the_easy_values_are_in_use(tmp_path):
    srv, robot, cfg = await _real_server(tmp_path)
    assert srv._easy_prepare_note().startswith("skip: まだ記録していない")
    mock_srv = GameServer(MockRobot(), "127.0.0.1", 0)
    assert mock_srv._easy_prepare_note().startswith("skip: 仮想クレーン")
    assert [k for k, _ in __import__("corexy_ufo_backend.sequence.prepare", fromlist=["STEPS"]).STEPS][-1] == "easy"


async def test_the_dry_run_crane_does_not_record_drop_points(server):
    srv, robot, port = server
    r = await srv.execute("easy_dial_set", {"which": "dial_1"})
    assert r["type"] == "nack" and "仮想クレーン" in r["data"]["reason"]
    assert (await srv.execute("easy_dial_confirm", {}))["type"] == "nack"


async def test_easy_goto_moves_xy_to_a_dial_and_nothing_else(server):
    """#183: the practice's carry: one XY move to the Dial's point at the easy feed, only at
    the travel height, never while a sequence runs."""
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "b", "easy_goto", destination=3))["type"] == "nack"
        z0 = robot.snapshot().z
        n = len(robot.commands)
        r = await _cmd(ws, "g1", "easy_goto", destination=2)
        assert r["type"] == "ack", r
        x, y = srv.easy.easy.dials[2]
        sent = robot.commands[n:]
        assert sent == [f"XY {x:.3f} {y:.3f} F{srv.easy.params.xy_feed_mm_min:.0f}"]
        assert robot.target[0] == x and robot.target[1] == y and robot.snapshot().z == z0
        # the arm lowered: refused, nothing sent
        robot.pos[2] = robot.target[2] = float(srv.easy.params.safe_z) - 40.0
        n = len(robot.commands)
        r = await _cmd(ws, "g2", "easy_goto", destination=1)
        assert r["type"] == "nack" and "travel height" in r["data"]["reason"] and robot.commands[n:] == []
        robot.pos[2] = robot.target[2] = float(srv.easy.params.safe_z)
        # #187: easy_goto ACK is command acceptance, not travel completion. The dry-run
        # XY axis keeps moving after ACK; catching before it stops is correctly refused.
        # Wait for position AND velocity, never use a fixed sleep or bypass safety checks.
        for _ in range(400):
            if (abs(robot.pos[0] - x) < 0.1 and abs(robot.pos[1] - y) < 0.1
                    and max(abs(v) for v in robot.vel[:2]) < 0.01):
                break
            await asyncio.sleep(0.02)
        else:
            raise AssertionError(f"easy_goto never settled: pos={robot.pos}, vel={robot.vel}")
        # while the easy catch runs: busy
        assert (await _cmd(ws, "c", "easy_grab"))["type"] == "ack"
        r = await _cmd(ws, "g3", "easy_goto", destination=1)
        assert r["type"] == "nack" and "busy" in r["data"]["reason"]
        assert (await _cmd(ws, "s", "stop"))["type"] == "ack"
        await srv.easy.wait()
