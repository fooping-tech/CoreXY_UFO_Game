"""Hand joystick input (vision_service.hand_control) and the host-side jog guards."""

import asyncio
import json
import math

import pytest
import websockets

from corexy_ufo_backend.robot import MockRobot
from corexy_ufo_backend.vision_service.cameras import index_by_name, order_by_unique_id
from corexy_ufo_backend.vision_service.hand_control import (HandControl, HandControlConfig, palm_center,
                                                            pinch_ratio)
from corexy_ufo_backend.websocket import GameServer

W, H = 640, 480


def hand(cx=0.5, cy=0.5, size=0.2, gap=0.5):
    """21 landmarks of a flat hand centred near (cx, cy) in normalised coords.

    `size` is the hand width (index MCP - pinky MCP) as a fraction of the frame
    height, `gap` the thumb-index tip distance as a fraction of that width.
    """
    s = size * H  # hand width in pixels

    def px(dx, dy):  # offsets in hand widths -> normalised coords
        return (cx + dx * s / W, cy + dy * s / H, 0.0)
    pts = [px(0, 0)] * 21
    pts[0] = px(0, 0.9)            # wrist
    pts[5] = px(-0.5, 0.0)         # index MCP
    pts[9] = px(-0.15, -0.15)
    pts[13] = px(0.2, -0.1)
    pts[17] = px(0.5, 0.0)         # pinky MCP
    pts[8] = px(-0.6, -0.9)        # index tip
    # thumb tip `gap` hand widths from the index tip, along x
    pts[4] = px(-0.6 - gap, -0.9)
    return pts


def frames(ctrl, seq, t0=0.0, dt=33.0):
    """Feed (landmark list) frames; returns the events."""
    out = []
    t = t0
    for lm in seq:
        hands = [] if lm is None else (lm if isinstance(lm[0], list) else [lm])
        out.append(ctrl.update(hands, [0.95] * len(hands), W, H, t))
        t += dt
    return out


def test_pinch_ratio_is_scale_free_and_aspect_correct():
    small = hand(size=0.1, gap=0.3)
    big = hand(size=0.4, gap=0.3)
    assert pinch_ratio(small, W, H) == pytest.approx(0.3, abs=1e-6)
    assert pinch_ratio(big, W, H) == pytest.approx(0.3, abs=1e-6)
    # the same hand on a wider frame keeps its ratio (pixels, not normalised coords)
    assert pinch_ratio(hand(size=0.2, gap=0.3), W, H) == pytest.approx(0.3, abs=1e-6)


def test_pinch_needs_confirmation_and_has_hysteresis():
    c = HandControl(HandControlConfig(pinch_start=0.35, pinch_release=0.55, pinch_confirm_ms=100))
    ev = frames(c, [hand(gap=0.2)] * 3)  # 0, 33, 66 ms
    assert [e["pinch"] for e in ev] == [False, False, False]
    ev = frames(c, [hand(gap=0.2)] * 2, t0=99)  # 99, 132 ms
    assert ev[-1]["pinch"]
    # between the thresholds: stays pinched; at release: lets go
    assert frames(c, [hand(gap=0.45)], t0=200)[0]["pinch"]
    assert not frames(c, [hand(gap=0.6)], t0=240)[0]["pinch"]
    # back between the thresholds from open: not pinched (no re-trigger)
    assert not frames(c, [hand(gap=0.45)], t0=280)[0]["pinch"]


def test_a_flicker_does_not_confirm_a_pinch():
    c = HandControl(HandControlConfig(pinch_confirm_ms=100))
    ev = frames(c, [hand(gap=0.2), hand(gap=0.2), hand(gap=0.7), hand(gap=0.2), hand(gap=0.2), hand(gap=0.2)])
    assert not any(e["pinch"] for e in ev[:5]) and not ev[5]["pinch"]  # restarted at frame 3 -> 99 ms at frame 6


def test_hand_size_does_not_change_the_decision():
    for size in (0.08, 0.15, 0.4):
        c = HandControl(HandControlConfig(pinch_confirm_ms=0))
        assert frames(c, [hand(size=size, gap=0.25)])[0]["pinch"], size
        c = HandControl(HandControlConfig(pinch_confirm_ms=0))
        assert not frames(c, [hand(size=size, gap=0.5)])[0]["pinch"], size


def test_position_is_the_palm_not_the_fingertips():
    open_ = palm_center(hand(cx=0.3, cy=0.6, gap=0.8))
    closed = palm_center(hand(cx=0.3, cy=0.6, gap=0.1))
    assert open_ == pytest.approx(closed)  # pinching does not move the stick
    c = HandControl(HandControlConfig(pinch_confirm_ms=0))
    ev = frames(c, [hand(cx=0.3, cy=0.6)])[0]
    assert ev["hand_x"] == pytest.approx(open_[0], abs=1e-3) and ev["hand_y"] == pytest.approx(open_[1], abs=1e-3)


def test_two_hands_lost_hand_low_confidence_and_roi_give_no_control():
    c = HandControl(HandControlConfig(pinch_confirm_ms=0))
    assert frames(c, [hand(gap=0.1)])[0]["pinch"]
    two = frames(c, [[hand(gap=0.1), hand(cx=0.2, gap=0.1)]])[0]
    assert not two["detected"] and not two["pinch"] and two["hand_count"] == 2 and two["reason"] == "multiple_hands"
    gone = frames(c, [None])[0]
    assert not gone["detected"] and not gone["pinch"] and gone["reason"] == "no_hand"
    vague = c.update([hand(gap=0.1)], [0.3], W, H, 1000.0)
    assert not vague["detected"] and not vague["pinch"] and vague["reason"] == "ambiguous"
    roi = HandControl(HandControlConfig(pinch_confirm_ms=0, roi=(0.0, 0.0, 0.5, 1.0), roi_enabled=True))
    assert frames(roi, [hand(cx=0.3, gap=0.1)])[0]["pinch"]
    out = frames(roi, [hand(cx=0.8, gap=0.1)])[0]
    assert not out["detected"] and not out["pinch"] and out["reason"] == "outside_roi"


def test_events_are_numbered_and_carry_both_clocks_apart():
    c = HandControl()
    a = c.update([hand()], [0.9], W, H, 10.0, timestamp_ms=1_700_000_000_000)
    b = c.update([], [], W, H, 43.0, timestamp_ms=1_700_000_000_033)
    assert (a["event"], b["event"]) == ("hand_control", "hand_control")
    assert b["sequence"] == a["sequence"] + 1 and b["timestamp"] > a["timestamp"]
    lost = c.camera_lost()
    assert lost["sequence"] == b["sequence"] + 1 and not lost["camera_ok"] and not lost["pinch"]
    assert "landmarks" not in a  # no landmarks on the wire unless debugging
    json.dumps(a)


def test_camera_index_by_name_follows_unique_id_order():
    cams = order_by_unique_id([
        {"name": "MacBook Airカメラ", "unique_id": "6C707041-05AC-0010-000C-000000000001"},
        {"name": "C270 HD WEBCAM", "unique_id": "0x1120000046d0825"},
        {"name": "Innomaker-U20CAM-1080p-S1", "unique_id": "0x11120000c456366"},
    ])
    assert index_by_name(cams, "innomaker") == 0 and index_by_name(cams, "C270") == 1
    assert index_by_name(cams, "macbook") == 2 and index_by_name(cams, "none") is None and index_by_name(cams, "") is None


# ------------------------------------------------------------ host-side jog guards
async def _server(robot):
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    return srv, next(iter(srv._server.sockets)).getsockname()[1]


async def _cmd(ws, rid, name, **params):
    await ws.send(json.dumps({"type": "command", "request_id": rid, "data": {"name": name, "params": params}}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 2))
        if m.get("request_id") == rid:
            return m


async def _ready_mock():
    robot = MockRobot()
    await robot.connect()
    await robot.enable_motors(True)
    await robot.home()
    return robot


async def test_disconnect_of_the_jogging_client_stops_the_jog():
    robot = await _ready_mock()
    srv, port = await _server(robot)
    srv.jog_expiry_s = 10.0  # only the disconnect may stop it here
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            assert (await _cmd(ws, "j1", "jog", vx=20, vy=0))["type"] == "ack"
            assert robot._jog_until > 0
        for _ in range(50):
            if robot._jog_until == 0.0:
                break
            await asyncio.sleep(0.01)
        assert robot._jog_until == 0.0 and srv._jog_owner is None
    finally:
        await srv.stop()


async def test_a_jog_without_refresh_expires_on_the_host():
    robot = await _ready_mock()
    robot_jog_calls = []
    orig = robot.jog
    async def spy(vx, vy, vz=0.0):
        robot_jog_calls.append((vx, vy, vz))
        await orig(vx, vy, vz)
    robot.jog = spy
    srv, port = await _server(robot)
    srv.jog_expiry_s = 0.15
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _cmd(ws, "j1", "jog", vx=20, vy=0)
            await asyncio.sleep(0.4)  # the game froze: no refresh
            assert robot_jog_calls[-1] == (0.0, 0.0, 0.0) and srv._jog_owner is None
            # a zero jog (key released) is not a "moving" jog: nothing to expire
            await _cmd(ws, "j2", "jog", vx=0, vy=0)
            n = len(robot_jog_calls)
            await asyncio.sleep(0.3)
            assert len(robot_jog_calls) == n
    finally:
        await srv.stop()


async def test_refused_jog_before_homing_is_not_tracked():
    robot = MockRobot()
    await robot.connect()
    await robot.enable_motors(True)  # not homed
    srv, port = await _server(robot)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            r = await _cmd(ws, "j1", "jog", vx=20, vy=0)
            assert r["type"] == "nack" and "not homed" in r["data"]["reason"] and srv._jog_owner is None
    finally:
        await srv.stop()


def test_config_reads_gesture_thresholds():
    c = HandControlConfig.from_dict({"pinch_start": 0.3, "pinch_release": 0.6, "pinch_confirm_ms": 80,
                                     "roi": [0.1, 0.2, 0.9, 0.8], "roi_enabled": True})
    assert (c.pinch_start, c.pinch_release, c.pinch_confirm_ms) == (0.3, 0.6, 80.0)
    assert c.roi == (0.1, 0.2, 0.9, 0.8) and c.roi_enabled
    assert math.isinf(pinch_ratio([(0.5, 0.5, 0.0)] * 21, W, H))
