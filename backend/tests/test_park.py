"""#276: `park` takes the arm out of the way of the screen (the left back corner), slowly."""

import asyncio
import dataclasses

import pytest
import websockets
from corexy_ufo_backend.config import BackendConfig, RobotLimits, load_config
from corexy_ufo_backend.sequence import AutoCatchConfig, AutoCatchParams
from corexy_ufo_backend.sequence.dry_run import make_dry_run_robot
from corexy_ufo_backend.websocket import GameServer
from test_auto_catch import _ready, fast_params
from ws_helpers import cmd_kw as _cmd

LIMITS = RobotLimits()


def test_park_point_is_the_left_back_corner_inside_the_limits():
    cfg = BackendConfig()
    lim = cfg.limits
    x, y = cfg.park_point()
    assert x == pytest.approx(lim.x_min + cfg.park_margin_mm) and y == pytest.approx(lim.y_max - cfg.park_margin_mm)
    assert dataclasses.replace(cfg, park_mm=(100.0, 50.0)).park_point() == (100.0, 50.0)
    assert dataclasses.replace(cfg, park_mm=(9999.0, 50.0)).park_point() == (x, y)  # outside: the corner


def test_park_values_from_the_config():
    cfg = load_config()
    assert 300.0 <= cfg.park_feed_mm_min <= cfg.fast_feed() and cfg.park_feed_mm_min < cfg.fast_feed()  # slowly


@pytest.fixture
async def server():
    params = fast_params()
    robot = make_dry_run_robot(params, LIMITS)
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=50, backend_cfg=load_config(),
                     auto_catch=AutoCatchConfig(real=AutoCatchParams(profile="real"), dry_run=params))
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    yield srv, robot, port
    await srv.stop()


async def test_park_moves_xy_only_at_the_park_feed(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        z0 = robot.snapshot().z
        n = len(robot.commands)
        r = await _cmd(ws, "p1", "park")
        assert r["type"] == "ack", r
        x, y = srv.backend_cfg.park_point()
        assert robot.commands[n:] == [f"XY {x:.3f} {y:.3f} F{srv.backend_cfg.park_feed_mm_min:.0f}"]
        assert robot.target[0] == x and robot.target[1] == y and robot.snapshot().z == z0


async def test_park_is_refused_while_anything_else_moves(server):
    srv, robot, port = server
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await _ready(ws, robot)
        await srv._motion_lock.acquire()  # another motion command running
        try:
            n = len(robot.commands)
            r = await _cmd(ws, "p2", "park")
            assert r["type"] == "nack" and "busy" in r["data"]["reason"] and robot.commands[n:] == []
        finally:
            srv._motion_lock.release()
        robot.travel_height_refusal = lambda: "the arm is not wound up"  # the real robot's check
        n = len(robot.commands)
        r = await _cmd(ws, "p3", "park")
        assert r["type"] == "nack" and "wound up" in r["data"]["reason"] and robot.commands[n:] == []
        await asyncio.sleep(0)
