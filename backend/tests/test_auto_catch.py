"""One-button auto catch: state machine, safety checks and the dry run (no hardware)."""

import asyncio
import contextlib
import dataclasses
import json

import pytest
import websockets

from corexy_ufo_backend.config import BackendConfig, RobotLimits, load_config
from corexy_ufo_backend.robot import MockRobot, RobotCommandError
from corexy_ufo_backend.robot.dry_run import DebouncedInput
from corexy_ufo_backend.robot.real_robot import RealRobot
from corexy_ufo_backend.sequence import AutoCatchConfig, AutoCatchParams, AutoCatchSequencer, Phase, validate
from corexy_ufo_backend.sequence.dry_run import make_dry_run_robot
from corexy_ufo_backend.serial_service import protocol as P
from corexy_ufo_backend.websocket import GameServer

LIMITS = RobotLimits()
NORMAL = ["IDLE", "OPEN_CLAW", "LOWER_TO_CATCH", "CLOSE_CLAW", "RAISE_WITH_ITEM", "MOVE_TO_BOX",
          "LOWER_TO_RELEASE", "RELEASE", "RAISE_EMPTY", "CLAW_STANDBY", "IDLE"]


def fast_params(**over) -> AutoCatchParams:
    """The repo's dry_run profile, sped up so a whole run takes well under a second."""
    p = AutoCatchConfig.from_raw(load_config().raw).dry_run
    p = dataclasses.replace(p, xy_feed_mm_min=9000.0, xy_feed_max_mm_min=12000.0, xy_accel_mm_s2=20000.0, z_speed_units_s=400.0,
                            z_accel_units_s2=8000.0, virtual_claw_move_s=0.03, claw_settle_s=0.03,
                            timeouts_s={k: 1.5 for k in p.timeouts_s}, total_timeout_s=10.0, button_debounce_ms=200.0)
    return dataclasses.replace(p, **over)


class Rig:
    def __init__(self, params: AutoCatchParams | None = None) -> None:
        self.params = params or fast_params()
        self.robot = make_dry_run_robot(self.params, LIMITS)
        self.lock = asyncio.Lock()
        self.jogging = False
        self.seq = AutoCatchSequencer(self.robot, self.params, LIMITS, load_config(), lock=self.lock,
                                      is_jogging=lambda: self.jogging, poll_s=0.005)
        self._tick: asyncio.Task | None = None

    async def __aenter__(self) -> "Rig":
        await self.robot.connect()
        self._tick = asyncio.get_running_loop().create_task(self._ticker())
        await self.robot.enable_motors(True)
        await self.robot.home()
        self.robot._homing_until = 0.0  # skip the mock's 1.5 s "HOMING" display
        await self.move_xy(120.0, 100.0)
        self.robot.commands.clear()
        return self

    async def __aexit__(self, *exc) -> None:
        self._tick.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._tick

    async def _ticker(self) -> None:
        while True:
            await self.robot.tick()
            await asyncio.sleep(0.002)

    async def move_xy(self, x: float, y: float) -> None:
        await self.robot.move_xy(x, y)
        for _ in range(500):
            if (abs(self.robot.pos[0] - x) < 1e-3 and abs(self.robot.pos[1] - y) < 1e-3
                    and self.robot.snapshot().state == "IDLE"):
                return
            await asyncio.sleep(0.005)
        raise AssertionError("virtual crane did not reach the start")

    async def until(self, phase: Phase, timeout: float = 3.0) -> None:
        for _ in range(int(timeout / 0.002)):
            if self.seq.phase == phase:
                return
            await asyncio.sleep(0.002)
        raise AssertionError(f"never reached {phase} (at {self.seq.phase}: {self.seq.error})")

    def phases(self) -> list[str]:
        return [self.seq.history[0]["from"]] + [h["to"] for h in self.seq.history]


# ---------------------------------------------------------------- normal run
async def test_normal_sequence_runs_every_state_in_order():
    async with Rig() as rig:
        await rig.seq.start()
        assert rig.seq.active and rig.lock.locked()
        await rig.seq.wait()
        assert rig.seq.last_result == "done" and rig.seq.error == ""
        assert rig.phases() == NORMAL
        assert rig.robot.commands == ["CLAW -> open", "Z -> 30.00", "CLAW -> closed", "Z -> 95.00",
                                      "XY 30.000 170.000 F9000", "Z -> 70.00", "CLAW -> open", "Z -> 95.00",
                                      "CLAW -> closed"]
        assert not rig.seq.active and not rig.lock.locked()
        s = rig.robot.snapshot()
        assert (round(s.x), round(s.y), round(s.z)) == (30, 170, 95) and s.homed and not s.alarm


async def test_each_state_waits_for_the_move_to_complete():
    # Z is only "done" when the virtual axis is there: the next state never starts early
    async with Rig(fast_params(z_speed_units_s=100.0)) as rig:
        seen: list[tuple[str, float]] = []
        rig.seq.on_change = lambda st: seen.append((st["phase"], rig.robot.pos[2]))
        await rig.seq.start()
        await rig.seq.wait()
        z_at = dict(seen)
        assert abs(z_at["CLOSE_CLAW"] - 30.0) <= 1.0  # entered CLOSE_CLAW only once Z reached 30
        assert abs(z_at["MOVE_TO_BOX"] - 95.0) <= 1.0


async def test_no_standby_step_when_not_configured():
    async with Rig(fast_params(claw_standby=None)) as rig:
        await rig.seq.start()
        await rig.seq.wait()
        assert rig.phases()[-2:] == ["RAISE_EMPTY", "IDLE"] and rig.seq.last_result == "done"


# ---------------------------------------------------------------- exclusion / button
async def test_double_start_and_button_chatter_are_refused():
    async with Rig() as rig:
        await rig.seq.start()
        with pytest.raises(RobotCommandError, match="debounced"):
            await rig.seq.start()  # a bounce right after the press
        await asyncio.sleep(0.25)  # past the debounce: a real second press while running
        with pytest.raises(RobotCommandError, match="already running"):
            await rig.seq.start()
        await rig.seq.wait()
        assert rig.robot.commands.count("CLAW -> open") == 2  # ran exactly once


async def test_rapid_presses_start_one_sequence_only():
    async with Rig() as rig:
        results = await asyncio.gather(*(rig.seq.start() for _ in range(10)), return_exceptions=True)
        assert sum(r is None for r in results) == 1
        await rig.seq.wait()
        assert rig.phases() == NORMAL


async def test_refused_while_another_motion_or_jog_runs():
    async with Rig() as rig:
        async with rig.lock:  # e.g. a move_xy of the server
            with pytest.raises(RobotCommandError, match="another motion command"):
                await rig.seq.start()
        rig.jogging = True
        rig.seq._last_press = -1e9
        with pytest.raises(RobotCommandError, match="jog active"):
            await rig.seq.start()
        assert not rig.seq.active and rig.robot.commands == []


# ---------------------------------------------------------------- preconditions
@pytest.mark.parametrize("setup, reason", [
    (lambda r: setattr(r.robot, "homed", False), "not homed"),
    (lambda r: setattr(r.robot, "motors_enabled", False), "motors not enabled"),
    (lambda r: setattr(r.robot, "alarm", True), "alarm active"),
    (lambda r: setattr(r.robot, "z_reference_set", False), "Z reference not set"),
    (lambda r: r.robot.arm_marks.clear(), "claw open / closed positions not recorded"),
    (lambda r: r.robot.pos.__setitem__(2, 50.0), "below safe_z"),
])
async def test_preconditions_refuse_to_start(setup, reason):
    async with Rig() as rig:
        rig.robot.target = list(rig.robot.pos)
        setup(rig)
        rig.robot.target = list(rig.robot.pos)
        with pytest.raises(RobotCommandError, match=reason):
            await rig.seq.start()
        assert not rig.seq.active and rig.robot.commands == []


async def test_claw_span_outside_servo_limits_is_refused():
    async with Rig(fast_params(claw_span_max_deg=90.0)) as rig:  # recorded span 128.6
        with pytest.raises(RobotCommandError, match="claw span"):
            await rig.seq.start()


# ---------------------------------------------------------------- parameter checks
def test_repo_dry_run_profile_is_valid_and_real_profile_is_refused():
    cfg = load_config()
    ac = AutoCatchConfig.from_raw(cfg.raw)
    assert validate(ac.dry_run, cfg.limits, cfg) == []
    errs = validate(ac.real, cfg.limits, cfg)
    assert any("catch_z is not set" in e for e in errs)
    assert any("box_x_mm is not set" in e for e in errs)
    assert any("not confirmed on the real machine" in e for e in errs)


def test_real_profile_needs_every_confirmation_even_with_values():
    p = dataclasses.replace(fast_params(), profile="real", confirmed={"z_direction": True})
    errs = validate(p, LIMITS, load_config())
    assert len(errs) == 1 and "z_scale" in errs[0] and "box_xy" in errs[0]
    p.confirmed = {k: True for k in ("z_direction", "z_scale", "z_positions", "box_xy", "claw_positions",
                                     "timeouts", "speeds")}
    assert validate(p, LIMITS, load_config()) == []


@pytest.mark.parametrize("over, reason", [
    (dict(catch_z=10.0), "below z_floor"),
    (dict(catch_z=120.0), "outside Z range"),
    (dict(release_z=99.0), "above safe_z"),
    (dict(box_x_mm=500.0), "outside the XY soft limits"),
    (dict(box_y_mm=-5.0), "outside the XY soft limits"),
    (dict(max_drop_units=40.0), "descent"),
    (dict(max_drum_turns=1.0), "drum turn"),
    (dict(xy_feed_mm_min=15000.0), "xy_feed_mm_min"),
    (dict(claw_standby="half"), "claw_standby"),
    (dict(safe_z=None), "safe_z is not set"),
])
def test_out_of_range_parameters_are_rejected(over, reason):
    errs = validate(fast_params(**over), LIMITS, load_config())
    assert any(reason in e for e in errs), errs


def test_missing_timeout_is_rejected():
    p = fast_params()
    p.timeouts_s = {k: v for k, v in p.timeouts_s.items() if k != "move_to_box"}
    assert any("timeouts_s.move_to_box" in e for e in validate(p, LIMITS))


async def test_out_of_range_parameters_never_reach_the_robot():
    async with Rig(fast_params(box_x_mm=999.0)) as rig:
        with pytest.raises(RobotCommandError, match="outside the XY soft limits"):
            await rig.seq.start()
        assert rig.robot.commands == []


# ---------------------------------------------------------------- emergency stop
async def test_stop_mid_sequence_aborts_at_once_and_starts_nothing_more():
    async with Rig(fast_params(z_speed_units_s=60.0)) as rig:
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        assert await rig.seq.abort("emergency stop (stop)")
        assert rig.robot.commands[-1] == "ABORT"  # sent before abort() returned
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and rig.seq.error == "emergency stop (stop)"
        assert rig.robot.commands.count("ABORT") == 1
        assert rig.robot.commands == ["CLAW -> open", "Z -> 30.00", "ABORT"]
        s = rig.robot.snapshot()
        assert s.alarm and not s.homed and not rig.lock.locked()
        z = rig.robot.pos[2]
        await asyncio.sleep(0.05)
        assert rig.robot.pos[2] == z  # the virtual drum stopped
        # cannot run again before clear_alarm + home
        rig.seq._last_press = -1e9
        with pytest.raises(RobotCommandError, match="alarm active"):
            await rig.seq.start()


async def test_estop_input_with_active_low_polarity():
    async with Rig() as rig:
        assert not rig.robot.inputs["estop"].active_high
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        rig.robot.set_input("estop", False)  # active LOW: pressed
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and "emergency stop input" in rig.seq.error
        assert rig.robot.snapshot().alarm


async def test_stop_during_a_claw_move_aborts_the_servo():
    async with Rig(fast_params(virtual_claw_move_s=0.5)) as rig:
        await rig.seq.start()
        await rig.until(Phase.OPEN_CLAW)
        await asyncio.sleep(0.05)
        await rig.seq.abort("emergency stop (stop)")
        await rig.seq.wait()
        deg = rig.robot.arm_deg
        await asyncio.sleep(0.05)
        assert rig.robot.arm_deg == deg and not rig.robot._claw_moving


# ---------------------------------------------------------------- timeouts
@pytest.mark.parametrize("fault, at, phase", [
    ("stall_z", Phase.LOWER_TO_CATCH, "LOWER_TO_CATCH timeout"),
    ("stall_xy", Phase.MOVE_TO_BOX, "MOVE_TO_BOX timeout"),
    ("claw_stall", Phase.OPEN_CLAW, "CLOSE_CLAW timeout"),
])
async def test_state_timeout_faults_and_stops(fault, at, phase):
    async with Rig(fast_params(timeouts_s={k: 0.4 for k in fast_params().timeouts_s})) as rig:
        await rig.seq.start()
        await rig.until(at)
        rig.robot.inject(fault)
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and phase in rig.seq.error, rig.seq.error
        assert rig.robot.commands[-1] == "ABORT" and rig.robot.snapshot().alarm


async def test_total_timeout():
    async with Rig(fast_params(total_timeout_s=0.15, z_speed_units_s=100.0)) as rig:
        await rig.seq.start()
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and "total timeout" in rig.seq.error


# ---------------------------------------------------------------- limit switches / sensors
async def test_limit_switch_away_from_home_faults():
    async with Rig() as rig:
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        rig.robot.press_input("limit_x")
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and "X limit switch" in rig.seq.error


async def test_limit_switch_glitch_shorter_than_debounce_is_ignored():
    async with Rig() as rig:
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        rig.robot.press_input("limit_y")
        await asyncio.sleep(0.005)  # < 30 ms debounce
        rig.robot.release_input("limit_y")
        await rig.seq.wait()
        assert rig.seq.last_result == "done"


async def test_limit_switch_at_home_is_normal():
    # right after HOME the switches are pressed: not a fault inside limit_home_zone_mm
    async with Rig(fast_params(box_x_mm=1.0, box_y_mm=1.0)) as rig:
        await rig.move_xy(0.0, 0.0)
        rig.robot.press_input("limit_x")
        rig.robot.press_input("limit_y")
        await asyncio.sleep(0.05)
        await rig.seq.start()
        await rig.seq.wait()
        assert rig.seq.last_result == "done", rig.seq.error


async def test_start_refused_with_a_limit_switch_active_away_from_home():
    async with Rig() as rig:
        rig.robot.press_input("limit_y")
        await asyncio.sleep(0.05)
        with pytest.raises(RobotCommandError, match="Y limit switch"):
            await rig.seq.start()


@pytest.mark.parametrize("fault, reason", [
    ("z_glitch", "position is not a number"),
    ("disconnect", "robot disconnected"),
    ("claw_fail", "CLOSE_CLAW failed"),
])
async def test_sensor_or_device_fault_mid_sequence(fault, reason):
    async with Rig() as rig:
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        rig.robot.inject(fault)
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and reason in rig.seq.error, rig.seq.error
        assert "ABORT" in rig.robot.commands


async def test_position_reported_out_of_range_faults():
    async with Rig() as rig:
        await rig.seq.start()
        await rig.until(Phase.LOWER_TO_CATCH)
        rig.robot.pos[0] = 450.0  # e.g. lost steps / a bad reading
        await rig.seq.wait()
        assert "outside the soft limits" in rig.seq.error


async def test_motors_disabled_mid_sequence_faults():
    async with Rig() as rig:
        await rig.seq.start()
        await rig.until(Phase.RAISE_WITH_ITEM)
        await rig.robot.enable_motors(False)
        await rig.seq.wait()
        assert rig.seq.phase == Phase.FAULT and "motors disabled" in rig.seq.error


# ---------------------------------------------------------------- inputs
def test_debounced_input_polarity_and_chatter():
    lo = DebouncedInput(active_high=False, debounce_s=0.03)
    lo.set_raw(True, 0.0)
    assert not lo.update(1.0)  # high = released for an active-low input
    lo.set_raw(False, 1.0)
    assert not lo.update(1.01)  # not yet debounced
    lo.set_raw(True, 1.02)  # bounce back
    assert not lo.update(1.1)
    lo.set_raw(False, 1.2)
    assert lo.update(1.25)
    hi = DebouncedInput(active_high=True, debounce_s=0.0)
    hi.set_raw(True, 0.0)
    assert hi.update(0.0)


# ---------------------------------------------------------------- real robot
def test_real_robot_reports_limit_switches_from_pos():
    cfg = BackendConfig()
    r = RealRobot(cfg)
    line = ("POS X=0.000 Y=50.000 A=0 B=0 F=900.000 EN=HARDWIRED_ACTIVE HOMED=YES X_HOMED=YES Y_HOMED=YES "
            "HOMING=Idle MOTION=NO JOB=IDLE PEN=UP ALARM=NO ALARM_REASON=\"none\" TMC=READY LIMIT_X=ACTIVE "
            "LIMIT_Y=OPEN LIMIT_X_RAW=ACTIVE LIMIT_Y_RAW=OPEN TEST_MODE=OFF JOY=NONE")
    r._apply_pos(P.parse_pos_line(line))
    s = r.snapshot()
    assert s.limit_x and not s.limit_y


# ---------------------------------------------------------------- through the WebSocket server
@pytest.fixture
async def server():
    params = fast_params()
    robot = make_dry_run_robot(params, LIMITS)
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=50,
                     auto_catch=AutoCatchConfig(real=AutoCatchParams(profile="real"), dry_run=params))
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    yield srv, robot, port
    await srv.stop()


async def _cmd(ws, rid, name, **params):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), 3))
        if msg["type"] in ("ack", "nack") and msg.get("request_id") == rid:
            return msg


async def _ready(ws, robot):
    assert (await _cmd(ws, "e", "enable_motors", enable=True))["type"] == "ack"
    assert (await _cmd(ws, "h", "home"))["type"] == "ack"
    assert (await _cmd(ws, "m", "move_xy", x=120, y=100))["type"] == "ack"
    for _ in range(300):
        if abs(robot.pos[0] - 120) < 1e-3 and robot.snapshot().state == "IDLE":
            break
        await asyncio.sleep(0.01)
    await asyncio.sleep(0.25)  # past the mock's homing display time


async def test_server_runs_the_sequence_and_locks_manual_control(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        r = await _cmd(ws, "a1", "auto_catch")
        assert r["type"] == "ack" and r["data"]["active"]
        for rid, name, params in [("x1", "move_xy", dict(x=10, y=10)), ("x2", "jog", dict(vx=10, vy=0)),
                                  ("x3", "move_z", dict(z=50)), ("x4", "arm_goto", dict(which="open")),
                                  ("x5", "z_zero", {}), ("x6", "clear_alarm", {}), ("x7", "auto_catch", {})]:
            if name == "auto_catch":
                await asyncio.sleep(0.25)  # past the button debounce: a real second press
            r = await _cmd(ws, rid, name, **params)
            assert r["type"] == "nack" and "busy" in r["data"]["reason"], (name, r)
        assert (await _cmd(ws, "z0", "jog", vx=0, vy=0, vz=0))["type"] == "ack"  # key release is fine
        st = await _cmd(ws, "s1", "auto_catch_status")
        assert st["data"]["active"] and st["data"]["profile"] == "dry_run"
        phases = set()
        for _ in range(400):
            msg = json.loads(await asyncio.wait_for(ws.recv(), 3))
            if msg["type"] == "robot_state":
                ac = msg["data"]["auto_catch"]
                phases.add(ac["phase"])
                if not ac["active"]:
                    break
        assert ac["last_result"] == "done" and "MOVE_TO_BOX" in phases
        assert (await _cmd(ws, "m2", "move_xy", x=100, y=100))["type"] == "ack"  # manual again


async def test_server_stop_aborts_the_sequence(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "a1", "auto_catch"))["type"] == "ack"
        await asyncio.sleep(0.05)
        assert (await _cmd(ws, "s", "stop"))["type"] == "ack"
        await srv.auto.wait()
        assert srv.auto.phase == Phase.FAULT and "emergency stop" in srv.auto.error
        assert robot.commands.count("ABORT") == 1 and robot.alarm and not robot.homed
        await asyncio.sleep(0.25)  # past the button debounce
        r = await _cmd(ws, "a2", "auto_catch")
        assert r["type"] == "nack" and "alarm active" in r["data"]["reason"]


async def test_server_soft_stop_during_auto_catch_escalates_to_abort(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "a1", "auto_catch"))["type"] == "ack"
        await asyncio.sleep(0.05)
        assert (await _cmd(ws, "s", "soft_stop"))["type"] == "ack"
        await srv.auto.wait()
        assert srv.auto.phase == Phase.FAULT and "ABORT" in robot.commands


async def test_server_aborts_when_the_operator_disconnects(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        assert (await _cmd(ws, "a1", "auto_catch"))["type"] == "ack"
    await srv.auto.wait()
    assert srv.auto.phase == Phase.FAULT and "disconnected" in srv.auto.error


async def test_server_refuses_the_real_profile_until_configured():
    class FakeReal(MockRobot):
        name = "real"

    robot = FakeReal()
    await robot.connect()
    cfg = load_config()
    srv = GameServer(robot, "127.0.0.1", 0, auto_catch=AutoCatchConfig.from_raw(cfg.raw), backend_cfg=cfg)
    await robot.enable_motors(True)
    await robot.home()
    r = await srv.execute("auto_catch", {})
    assert r["type"] == "nack" and "is not set" in r["data"]["reason"] and "not confirmed" in r["data"]["reason"]
    assert srv.auto.params.profile == "real" and not srv.auto.active
