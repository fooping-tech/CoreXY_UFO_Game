"""#339: XY stays out of the home limit switches' reach (jog and programmed moves), and a stop
at a switch near the home edge (CoreXY_UFO #33) is a stop, not the crane's error."""

import asyncio
import math

import pytest

from conftest import FakeFirmware
from corexy_ufo_backend.config import BackendConfig, RobotLimits, load_config
from corexy_ufo_backend.robot import MockRobot, RealRobot, RobotCommandError
from corexy_ufo_backend.robot.jog_edges import JogEdgeGuard
from corexy_ufo_backend.robot.state import MachineState
from corexy_ufo_backend.serial_service import protocol as P
from corexy_ufo_backend.serial_service.service import SerialService
from corexy_ufo_backend.websocket import GameServer

SWITCH_MM = 0.715  # where the Y switch was pressed on 2026-11-26 (JOG end reason=limit_y Y=0.715)


# ------------------------------------------------------------------ a simulated lagging carriage
def simulate(guard_step, speed: float, *, pos_lag: float, deliver: float = 0.03, period: float = 0.05,
             accel: float = 600.0, start: float = 150.0, seconds: float = 6.0) -> float:
    """The closest the carriage comes to 0 on one axis while a jog of `speed` towards 0 is held.

    The carriage follows the speed the backend wrote, `deliver` s later, at the firmware's serial
    jog acceleration (600 mm/s^2). The backend decides every `period` s (the game's JOG refresh)
    from a position `pos_lag` s old, as JOG_POS gives it (one every 50 ms)."""
    dt = 0.001
    t, pos, vel, target, next_jog = 0.0, start, 0.0, 0.0, 0.0
    hist: list[tuple[float, float]] = [(0.0, start)]
    pending: list[tuple[float, float]] = []
    lowest = start
    while t < seconds:
        if t >= next_jog:
            seen_at = math.floor((t - pos_lag) / 0.05) * 0.05  # the last JOG_POS sample it can know
            known = start
            for ht, hp in hist:
                if ht > seen_at:
                    break
                known = hp
            pending.append((t + deliver, guard_step(t, -speed, known)))
            next_jog = t + period
        while pending and pending[0][0] <= t:
            target = pending.pop(0)[1]
        step = accel * dt
        vel += max(-step, min(step, target - vel))
        pos += vel * dt
        t += dt
        hist.append((t, pos))
        if len(hist) > 2000:
            hist = hist[-1000:]
        lowest = min(lowest, pos)
    return lowest


def repo_guard() -> tuple[JogEdgeGuard, BackendConfig]:
    """The guard with the values the repository's config gives the real robot."""
    cfg = load_config()
    lim = cfg.limits
    return JogEdgeGuard(margin_min=max(cfg.jog_edge_margin_mm, lim.home_margin), margin_max=cfg.jog_edge_margin_mm,
                        lag_s=cfg.jog_edge_lag_s, react_s=cfg.jog_edge_react_s,
                        brake_mm_s2=cfg.jog_edge_brake_mm_s2), cfg


@pytest.mark.parametrize("speed", [60.0, 100.0])  # the hand stick's top speed and the SPEED UP's (#188)
@pytest.mark.parametrize("axis", ["x", "y"])
@pytest.mark.parametrize("period", [0.05, 0.1])  # the game's JOG refresh, and a slow one
def test_a_full_speed_jog_towards_home_stops_well_before_the_switch(speed, axis, period):
    guard, cfg = repo_guard()
    assert cfg.limits.home_margin == 15.0 and cfg.jog_edge_lag_s == 0.25

    def step(now, v, known):
        x, y = (known, 100.0) if axis == "x" else (200.0, known)
        vx, vy = (v, 0.0) if axis == "x" else (0.0, v)
        out = guard.limit(vx, vy, x, y, now, 0.0, 390.0, 0.0, 200.0)
        guard.note_sent(now, *out)
        return out[0] if axis == "x" else out[1]

    lowest = simulate(step, speed, pos_lag=0.2, period=period)
    margin = guard.margin_min
    assert lowest >= margin / 2, f"{axis} {speed} mm/s stopped at {lowest:.2f} mm"
    assert lowest <= margin + 0.5  # and it does get there (the stick is not stopped far away)


@pytest.mark.parametrize("speed", [60.0, 100.0])
def test_the_old_rule_ran_into_the_switch(speed):
    """What #185 did (5 mm, speed <= distance / 0.25 s): with the measured lag it presses the
    switch, as on the machine on 2026-11-26."""
    def step(now, v, known):
        left = known - 5.0
        return 0.0 if left <= 0 else -min(abs(v), left / 0.25)

    assert simulate(step, speed, pos_lag=0.2) < SWITCH_MM


def test_the_guard_only_slows_the_way_towards_an_edge():
    g = JogEdgeGuard(margin_min=15.0, margin_max=5.0, lag_s=0.25, react_s=0.15, brake_mm_s2=300.0)
    lim = (0.0, 390.0, 0.0, 200.0)
    assert g.limit(-60.0, 0.0, 200.0, 100.0, 0.0, *lim) == (-60.0, 0.0)  # far away: as asked
    assert g.limit(0.0, -60.0, 100.0, 15.0, 0.0, *lim) == (0.0, 0.0)  # on the line: nothing towards it
    assert g.limit(0.0, 60.0, 100.0, 3.0, 0.0, *lim) == (0.0, 60.0)  # inside it: the way back is free
    vx, _ = g.limit(-60.0, 0.0, 25.0, 100.0, 0.0, *lim)
    assert -60.0 < vx < 0.0  # 10 mm before the line: slowed
    # what was sent and does not show in the position yet counts: the same place, already moving
    g.note_sent(0.0, -60.0, 0.0)
    vx2, _ = g.limit(-60.0, 0.0, 25.0, 100.0, 0.2, *lim)
    assert vx2 == 0.0  # 0.2 s at 60 mm/s = 12 mm: the carriage is already past the line
    g.note_sent(0.2, 0.0, 0.0)
    assert g.travel(0.2 + g.lag_s + 0.01) == (0.0, 0.0)  # a stop is forgotten after lag_s
    # the far side keeps its own (smaller) margin
    assert g.limit(60.0, 0.0, 385.0, 100.0, 1.0, *lim) == (0.0, 0.0)


# ------------------------------------------------------------------ the limits' home margin
def test_home_edge_refusal_and_clamp():
    lim = RobotLimits(home_margin=15.0)
    assert lim.home_edge_refusal(43.19, 146.44) == ""  # the easy mode's Dial 1 as calibrated
    assert lim.home_edge_refusal(15.0, 15.0) == ""
    why = lim.home_edge_refusal(100.0, 3.0)
    assert "within 15 mm of the home limit switches" in why and "Y >= 15" in why
    assert lim.clamp_home_edge(5.0, 3.0) == (15.0, 15.0)
    assert lim.clamp_home_edge(100.0, 50.0) == (100.0, 50.0)
    assert lim.clamp_home_edge(-1.0, 3.0) == (-1.0, 15.0)  # outside the soft limits: still refused later
    assert RobotLimits().home_edge_refusal(0.0, 0.0) == ""  # a bare RobotLimits: no margin


def test_repo_config_and_the_points_in_use():
    cfg = load_config()
    assert cfg.limits.home_margin == 15.0 and cfg.jog_edge_margin_mm == 5.0
    park, center = cfg.park_point(), cfg.home_center()
    assert park == (20.0, 180.0) and not cfg.limits.home_edge_refusal(*park)
    assert center is None  # #342: homing stays in the home corner by default
    cfg.home_then_center = True  # switched on: the middle, outside the home margin
    assert cfg.home_center() == (195.0, 100.0)
    cfg.park_mm, cfg.home_center_mm = (5.0, 100.0), (100.0, 10.0)  # inside the margin: not used
    assert cfg.park_point() == (20.0, 180.0) and cfg.home_center() == (195.0, 100.0)
    cfg.park_margin_mm = 0.0
    assert cfg.park_point() == (15.0, 200.0)
    # the calibrated points of the machine (config/calibration.json in the main checkout, 2026-11-26)
    for xy in [(43.19, 146.44), (144.4, 102.97)]:  # easy_dials.dial_1, homework_spot
        assert cfg.limits.home_edge_refusal(*xy) == ""


def test_the_home_margin_is_never_below_the_jog_margin(tmp_path):
    import json
    p = tmp_path / "game_config.json"
    p.write_text(json.dumps({"backend": {"jog_edge_margin_mm": 20.0, "xy_home_edge_margin_mm": 2.0}}))
    assert load_config(p).limits.home_margin == 20.0
    p.write_text(json.dumps({"backend": {}}))
    assert load_config(p).limits.home_margin == 15.0


# ------------------------------------------------------------------ RealRobot + FakeFirmware
@pytest.fixture
async def robot():
    cfg = BackendConfig(limits=RobotLimits(z_max=100.0, z_up_is_positive=True, home_margin=15.0))
    svc = SerialService("fake", transport_factory=FakeFirmware)
    r = RealRobot(cfg, svc)
    await r.connect()
    yield r
    await r.disconnect()


def fw(robot) -> FakeFirmware:
    return robot.serial.transport


def last_jog(robot) -> tuple[float, float]:
    l = [l for l in fw(robot).sent if l.startswith("JOG ")][-1]
    return float(l.split()[1]), float(l.split()[2])


async def settle():
    await asyncio.sleep(0.02)


async def test_real_robot_jog_keeps_the_home_margin(robot):
    await robot.enable_motors(True)
    await robot.home()  # at (0, 0), on the switches: only the way out
    await robot.jog(-30, -30)
    assert last_jog(robot) == (0.0, 0.0)
    await robot.jog(30, 30)
    assert last_jog(robot) == (30.0, 30.0)
    await robot.jog(0, 0)
    await settle()
    await robot.move_xy(100, 15)  # on the 15 mm line: nothing towards Y = 0, along it is free
    await robot.jog(30, -30)
    vx, vy = last_jog(robot)
    assert vx == 30.0 and abs(vy) <= 1.0
    await robot.jog(0, 0)
    await settle()
    await robot.move_xy(100, 40)  # 25 mm before the line at 60 mm/s: already slowed
    await robot.jog(0, -60)
    _, vy = last_jog(robot)
    assert -60.0 < vy < 0.0
    await robot.jog(0, -60)  # 0.25 s of it are not in the position yet: slower again
    assert abs(last_jog(robot)[1]) <= abs(vy)
    await robot.jog(0, 0)


async def test_programmed_moves_keep_out_of_the_home_margin(robot):
    await robot.enable_motors(True)
    await robot.home()
    with pytest.raises(RobotCommandError, match="within 15 mm of the home limit switches"):
        await robot.move_xy(100, 10)
    with pytest.raises(RobotCommandError, match="within 15 mm"):
        await robot.move_xy(3, 100)
    assert not [l for l in fw(robot).sent if l.startswith("XY ")]
    await robot.move_xy(43.19, 146.44)  # the Dial as calibrated
    m = MockRobot(RobotLimits(home_margin=15.0))
    await m.connect()
    await m.enable_motors(True)
    await m.home()
    with pytest.raises(RobotCommandError, match="within 15 mm"):
        await m.move_xy(100, 10)


async def test_a_move_xy_asked_for_inside_the_margin_goes_to_its_line():
    lim = RobotLimits(home_margin=15.0)
    robot = MockRobot(lim)
    await robot.connect()
    srv = GameServer(robot, host="127.0.0.1", port=0)
    await robot.enable_motors(True)
    await robot.home()
    reply = await srv.execute("move_xy", {"x": 100, "y": 4})
    assert reply["type"] == "ack", reply
    assert robot.target[:2] == [100.0, 15.0]
    reply = await srv.execute("move_xy", {"x": 100, "y": -4})
    assert reply["type"] == "nack" and "outside soft limits" in reply["data"]["reason"]


async def test_a_jog_stopped_by_a_home_switch_is_a_stop_not_an_error(robot):
    """CoreXY_UFO #33: `JOG end reason=limit_y`, then POS with ALARM=NO LIMIT_Y=ON."""
    await robot.enable_motors(True)
    await robot.home()
    await robot.move_xy(100, 50)
    robot.error = ""  # the fake's boot banner on connect ("firmware rebooted")
    await robot.jog(0, 30)
    await settle()
    f = fw(robot)
    f.y, f.jogging, f.limit_on["Y"] = 0.715, False, True
    f._emit("LIMIT edge axis=Y Y=0.715 (no alarm)")
    f._emit("JOG end reason=limit_y X=100.000 Y=0.715 HOMED=YES src=SERIAL")
    await settle()
    await robot.refresh_status()
    s = robot.snapshot()
    assert s.error == "" and not s.alarm and s.homed and s.state == MachineState.IDLE
    assert s.limit_y and s.y == pytest.approx(0.715)
    assert not P.is_failure_line("LIMIT edge axis=Y Y=0.715 (no alarm)")
    assert not P.is_failure_line("LIMIT edge released axis=Y Y=1.200 moved=0.485")
    await robot.jog(0, 30)  # the way out is free
    assert last_jog(robot) == (0.0, 30.0)


async def test_the_older_firmware_alarm_at_a_switch_stays_a_fault(robot):
    await robot.enable_motors(True)
    await robot.home()
    await robot.move_xy(100, 50)
    robot.error = ""  # the fake's boot banner on connect ("firmware rebooted")
    f = fw(robot)
    f.y, f.limit_on["Y"] = 0.715, True
    f.alarm, f.alarm_reason = True, "hard limit active away from home x=OFF y=ON x_raw=OFF y_raw=ON"
    f._emit("JOG end reason=limit_y X=100.000 Y=0.715 HOMED=YES src=SERIAL")
    await settle()
    await robot.refresh_status()
    s = robot.snapshot()
    assert s.alarm and "hard limit" in s.error
    with pytest.raises(RobotCommandError, match="alarm active"):
        await robot.jog(0, 30)


async def test_an_xy_move_stopped_at_a_home_switch_fails_without_an_error(robot):
    """CoreXY_UFO #33: `NACK_XY target=(..) reason=limit_y X= Y=` (no alarm): the move did not
    reach its target, the position is the line's, and nothing is left as the crane's error."""
    await robot.enable_motors(True)
    await robot.home()
    await robot.move_xy(100, 50)
    robot.error = ""  # the fake's boot banner on connect ("firmware rebooted")
    fw(robot).limit_next_xy = "limit_y"
    with pytest.raises(RobotCommandError, match="stopped at the limit switch"):
        await robot.move_xy(100, 20)
    s = robot.snapshot()
    assert s.error == "" and not s.alarm and s.homed and s.state == MachineState.IDLE
    assert (s.x, s.y) == pytest.approx((100.0, 0.7))
    assert P.xy_limit_stop("NACK_XY target=(1.000,2.000) reason=limit_x X=0.700 Y=2.000") == "limit_x"
    assert P.xy_limit_stop("NACK_XY target=(1.000,2.000) reason=stopped X=5.000 Y=2.000") == ""
    await robot.move_xy(100, 50)  # and it goes on
