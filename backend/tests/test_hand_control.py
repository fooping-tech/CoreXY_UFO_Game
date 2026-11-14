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
    # between the thresholds: stays pinched; open for release_confirm_ms: lets go
    assert frames(c, [hand(gap=0.45)], t0=200)[0]["pinch"]
    assert frames(c, [hand(gap=0.6)], t0=240)[0]["pinch"]      # opened 0 ms ago
    assert not frames(c, [hand(gap=0.6)], t0=300)[0]["pinch"]  # 60 ms open
    # back between the thresholds from open: not pinched (no re-trigger)
    assert not frames(c, [hand(gap=0.45)], t0=340)[0]["pinch"]


def test_a_one_frame_jitter_past_release_is_not_a_release():
    c = HandControl(HandControlConfig(pinch_confirm_ms=0, release_confirm_ms=60))
    ev = frames(c, [hand(gap=0.1), hand(gap=0.7), hand(gap=0.1), hand(gap=0.7), hand(gap=0.2)])
    assert all(e["pinch"] for e in ev)


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
    c = HandControl(HandControlConfig(pinch_confirm_ms=0, lost_grace_ms=0))
    assert frames(c, [hand(gap=0.1)])[0]["pinch"]
    two = frames(c, [[hand(gap=0.1), hand(cx=0.2, gap=0.1)]])[0]
    assert not two["detected"] and not two["pinch"] and two["hand_count"] == 2 and two["reason"] == "multiple_hands"
    gone = frames(c, [None])[0]
    assert not gone["detected"] and not gone["pinch"] and gone["reason"] == "no_hand"
    strict = HandControl(HandControlConfig(pinch_confirm_ms=0, lost_grace_ms=0, min_confidence=0.6))
    vague = strict.update([hand(gap=0.1)], [0.3], W, H, 1000.0)
    assert not vague["detected"] and not vague["pinch"] and vague["reason"] == "ambiguous"
    # by default the left/right score does not gate a hand (it drops for a hand seen from above)
    assert HandControl(HandControlConfig(pinch_confirm_ms=0)).update([hand(gap=0.1)], [0.3], W, H, 0.0)["pinch"]
    roi = HandControl(HandControlConfig(pinch_confirm_ms=0, roi=(0.0, 0.0, 0.5, 1.0), roi_enabled=True))
    assert frames(roi, [hand(cx=0.3, gap=0.1)])[0]["pinch"]
    out = frames(roi, [hand(cx=0.8, gap=0.1)])[0]
    assert not out["detected"] and not out["pinch"] and out["reason"] == "outside_roi"


def test_a_short_dropout_holds_the_last_frame_a_long_one_is_a_loss():
    c = HandControl(HandControlConfig(pinch_confirm_ms=0, lost_grace_ms=150))
    first = c.update([hand(cx=0.4, gap=0.1)], [0.9], W, H, 0.0)
    held = c.update([], [], W, H, 66.0)          # 2 frames without the hand
    held2 = c.update([hand(), hand(cx=0.2)], [0.9, 0.9], W, H, 100.0)  # a phantom second hand
    back = c.update([hand(cx=0.41, gap=0.1)], [0.9], W, H, 133.0)
    assert held["held"] and held["detected"] and held["pinch"] and held["hand_x"] == first["hand_x"]
    assert held["reason"] == "held_no_hand" and held2["held"] and held2["reason"] == "held_multiple_hands"
    assert back["pinch"] and "held" not in back
    c.update([], [], W, H, 200.0)
    still = c.update([], [], W, H, 340.0)        # 140 ms: still held
    lost = c.update([], [], W, H, 360.0)         # 160 ms: lost
    assert still["held"] and not lost["detected"] and not lost["pinch"] and lost["reason"] == "no_hand"
    # coming back after a loss starts over: the pinch must be confirmed again
    again = HandControl(HandControlConfig(pinch_confirm_ms=100, lost_grace_ms=150))
    again.update([hand(gap=0.1)], [0.9], W, H, 0.0)
    assert again.update([hand(gap=0.1)], [0.9], W, H, 120.0)["pinch"]
    again.update([], [], W, H, 140.0)
    assert not again.update([], [], W, H, 300.0)["pinch"]
    assert not again.update([hand(gap=0.1)], [0.9], W, H, 330.0)["pinch"]


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
    async def spy(vx, vy, vz=0.0, *, z_free=False):
        robot_jog_calls.append((vx, vy, vz))
        await orig(vx, vy, vz, z_free=z_free)
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


def test_a_hand_turned_on_its_side_still_pinches():
    # width foreshortened to a third (hand on its side): the palm length keeps the scale
    lm = hand(size=0.2, gap=0.3)
    cx = lm[9][0]
    side = [(cx + (p[0] - cx) / 3.0, p[1], p[2]) for p in lm]  # squash x only
    side[4] = (side[8][0] - 0.3 * 0.2 * H / W * 0.9, side[8][1], 0.0)  # tips stay ~0.27 hand widths apart
    flat = pinch_ratio(lm, W, H)
    turned = pinch_ratio(side, W, H)
    assert flat == pytest.approx(0.3, abs=1e-6)
    assert turned < 0.45  # width alone would make it ~0.8: no pinch
    c = HandControl(HandControlConfig(pinch_confirm_ms=0))
    assert c.update([side], [0.9], W, H, 0.0)["pinch"]


def test_thresholds_can_change_at_run_time_within_sane_bounds():
    c = HandControlConfig()
    c.update({"pinch_start": 0.5, "pinch_release": 0.4, "pinch_confirm_ms": -5})
    assert c.pinch_start == 0.5 and c.pinch_release == pytest.approx(0.55) and c.pinch_confirm_ms == 0.0
    assert c.to_dict()["pinch_start"] == 0.5


async def test_gesture_config_command():
    from corexy_ufo_backend.vision_service import CameraConfig, VisionService
    robot = MockRobot()
    await robot.connect()
    ctrl = HandControl()
    vision = VisionService([CameraConfig(roles=("hands",), control=ctrl)])
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, vision=vision)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            r = await _cmd(ws, "g1", "gesture_config", pinch_start=0.5, pinch_release=0.7)
            assert r["type"] == "ack" and r["data"]["pinch_start"] == 0.5 and ctrl.cfg.pinch_release == 0.7
        no_vision = GameServer(robot, "127.0.0.1", 0)
        assert (await no_vision.execute("gesture_config", {"pinch_start": 0.5}))["type"] == "nack"
    finally:
        await srv.stop()


async def test_a_stop_ends_the_jog_expiry_watch():
    robot = await _ready_mock()
    calls = []
    orig = robot.jog
    async def spy(vx, vy, vz=0.0, *, z_free=False):
        calls.append((vx, vy, vz))
        await orig(vx, vy, vz, z_free=z_free)
    robot.jog = spy
    srv, port = await _server(robot)
    srv.jog_expiry_s = 0.15
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await _cmd(ws, "j1", "jog", vx=20, vy=0)
            assert (await _cmd(ws, "s1", "soft_stop"))["type"] == "ack"
            n = len(calls)
            await asyncio.sleep(0.4)
            assert srv._jog_owner is None and len(calls) == n  # no extra zero jog from the expiry
    finally:
        await srv.stop()


def test_the_gpu_landmarker_is_rebuilt_in_the_background_and_swapped():
    # MediaPipe's GPU path holds every frame until the landmarker is closed: the
    # tracker rebuilds it every recreate_s without pausing (built and closed on threads).
    import threading
    import time as _time
    from corexy_ufo_backend.vision_service.mediapipe_hands import MediaPipeHandTracker

    class Fake:
        def __init__(self, n):
            self.n, self.closed = n, threading.Event()

        def close(self):
            self.closed.set()

    made = []

    def create(_delegate):
        _time.sleep(0.05)  # building takes a while
        made.append(Fake(len(made) + 1))
        return made[-1]

    tr = MediaPipeHandTracker.__new__(MediaPipeHandTracker)
    tr._create, tr.delegate, tr.recreate_s, tr.swaps = create, "gpu", 0.1, 0
    tr._landmarker, tr._next, tr._building, tr._lock = Fake(0), None, False, threading.Lock()
    first = tr._landmarker
    tr._born = _time.monotonic()
    tr._maybe_swap()
    assert tr._landmarker is first and not tr._building  # still young
    _time.sleep(0.12)
    tr._maybe_swap()  # starts the build, keeps the old one working meanwhile
    assert tr._building and tr._landmarker is first
    tr._maybe_swap()
    assert tr._landmarker is first  # not ready yet: no pause, no swap
    for _ in range(50):
        if tr._next is not None:
            break
        _time.sleep(0.01)
    tr._maybe_swap()
    assert tr._landmarker is made[0] and tr.swaps == 1
    assert first.closed.wait(1.0)  # the old one is closed (its memory freed)
    cpu = MediaPipeHandTracker.__new__(MediaPipeHandTracker)
    cpu.recreate_s = 0.0
    cpu._maybe_swap()  # the CPU path is never rebuilt


def shaped_hand(folded=(), thumb_at=None, cx=0.5, cy=0.5, size=0.2, palm_up=False):
    """A hand with each finger out or folded (tip nearer the wrist than its PIP);
    the thumb tip next to the tip of `thumb_at` (a finger name) or well away."""
    s = size * H

    def px(dx, dy):  # a right hand: palm up shows it mirrored left-right
        return (cx + (-dx if palm_up else dx) * s / W, cy + dy * s / H, 0.0)
    pts = [px(0, 0)] * 21
    pts[0] = px(0, 0.9)
    mcps = {"index": (5, -0.5), "middle": (9, -0.15), "ring": (13, 0.2), "pinky": (17, 0.5)}
    tips = {}
    for f, (mcp, x) in mcps.items():
        pts[mcp] = px(x, 0.0)
        pts[mcp + 1] = px(x, -0.4)  # PIP
        tip = px(x, 0.1) if f in folded else px(x, -0.8)
        pts[mcp + 3] = tip
        tips[f] = (x, 0.1 if f in folded else -0.8)
    if thumb_at:
        tx, ty = tips[thumb_at]
        pts[4] = px(tx - 0.05, ty)
    else:
        pts[4] = px(-1.2, 0.3)
    return pts


def test_index_middle_or_ring_pinch_and_the_finger_is_kept():
    for finger in ("index", "middle", "ring"):
        ctrl = HandControl(HandControlConfig(pinch_confirm_ms=60, release_confirm_ms=0))
        ev = frames(ctrl, [shaped_hand(thumb_at=finger)] * 4)[-1]
        assert ev["pinch"] and ev["pinch_finger"] == finger and ev["pose"] == "open", finger
    # once pinching with the ring finger, it stays the ring-finger pinch
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, release_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    evs = frames(ctrl, [shaped_hand(thumb_at="ring"), shaped_hand(thumb_at="index")])  # still a pinch for the ring
    assert evs[1]["pinch_finger"] == "ring"


def test_fist_and_peace_are_reported_and_never_start_a_pinch():
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    fist = shaped_hand(folded=("index", "middle", "ring", "pinky"), thumb_at="index")
    ev = frames(ctrl, [fist] * 3)[-1]
    assert ev["pose"] == "fist" and not ev["pinch"]
    peace = shaped_hand(folded=("ring", "pinky"))
    ev = frames(ctrl, [peace] * 3)[-1]
    assert ev["pose"] == "peace" and not ev["pinch"]
    assert frames(ctrl, [shaped_hand(folded=("ring",))])[-1]["pose"] == "other"
    # pinching, then closing into a fist: the pinch ends at once
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, release_confirm_ms=200, pinch_start=1.0, pinch_release=1.5))
    evs = frames(ctrl, [shaped_hand(thumb_at="index"), fist])
    assert evs[0]["pinch"] and not evs[1]["pinch"]


def test_an_open_hand_releases_even_below_a_wide_release_threshold():
    cfg = HandControlConfig(pinch_confirm_ms=0, release_confirm_ms=0, pinch_start=1.0, pinch_release=1.5)
    open_hand = shaped_hand()  # thumb out to the side: ratio about 1.3, under 1.5
    assert 1.0 < pinch_ratio(open_hand, W, H) < 1.5
    for finger in ("index", "ring"):
        ctrl = HandControl(cfg)
        evs = frames(ctrl, [shaped_hand(thumb_at=finger), open_hand])
        assert evs[0]["pinch"] and not evs[1]["pinch"], finger
    # a bent finger with the same gap (blur while pinching) does not release
    ctrl = HandControl(cfg)
    bent = shaped_hand()
    bent[7] = bent[6]  # DIP onto the PIP
    bent[8] = (bent[6][0], bent[6][1] + 0.01, 0.0)  # tip curled back level with the PIP
    bent[4] = (bent[8][0] - 1.2 * 0.2 * H / W, bent[8][1], 0.0)  # thumb 1.2 widths away
    evs = frames(ctrl, [shaped_hand(thumb_at="index"), bent])
    assert evs[0]["pinch"] and evs[1]["pinch"]


def test_palm_facing_up_down_side_and_inverted_for_a_left_hand():
    ctrl = HandControl(HandControlConfig())
    assert frames(ctrl, [shaped_hand()])[-1]["palm"] == "down"  # back of a right hand to the camera
    assert frames(ctrl, [shaped_hand(palm_up=True)])[-1]["palm"] == "up"
    edge = shaped_hand()
    edge[17] = edge[5]  # index and pinky MCPs in line with the wrist: edge on
    assert frames(ctrl, [edge])[-1]["palm"] == "side"
    left = HandControl(HandControlConfig(palm_invert=True))
    assert frames(left, [shaped_hand()])[-1]["palm"] == "up"
    left.cfg.update({"palm_invert": False})  # the debug panel's Swap palm, at run time
    assert frames(left, [shaped_hand()])[-1]["palm"] == "down"
    # palm up or down, the pinch works the same
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0))
    ev = frames(ctrl, [shaped_hand(thumb_at="middle", palm_up=True)])[-1]
    assert ev["pinch"] and ev["palm"] == "up"



def rotated(pts, deg, w=W, h=H):
    """The hand turned by `deg` (clockwise on the screen, image y down) about its wrist, in pixels."""
    a = math.radians(deg)
    ox, oy = pts[0][0] * w, pts[0][1] * h
    out = []
    for x, y, z in pts:
        dx, dy = x * w - ox, y * h - oy
        out.append(((ox + dx * math.cos(a) - dy * math.sin(a)) / w, (oy + dx * math.sin(a) + dy * math.cos(a)) / h, z))
    return out


def test_point_pose_and_where_the_index_finger_points():
    point = shaped_hand(folded=("middle", "ring", "pinky"))
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    ev = frames(ctrl, [point] * 2)[-1]
    # fingers up in the image: pointing up (dy -1); a finger about 0.8 hand widths long
    assert ev["pose"] == "point" and not ev["pinch"]
    assert ev["point_dx"] == pytest.approx(0.0, abs=1e-3) and ev["point_dy"] == pytest.approx(-1.0, abs=1e-3)
    assert 0.5 < ev["point_len"] < 1.5
    # turned: right, down-left (a diagonal), in true pixel angles whatever the aspect
    for deg, want in ((90, (1.0, 0.0)), (225, (-math.sqrt(0.5), math.sqrt(0.5)))):
        ev = frames(HandControl(HandControlConfig()), [rotated(point, deg)])[-1]
        assert ev["pose"] == "point", deg
        assert (ev["point_dx"], ev["point_dy"]) == pytest.approx(want, abs=1e-3), deg
    # other shapes keep their names; a lost camera carries no direction
    assert frames(ctrl, [shaped_hand(folded=("ring", "pinky"))])[-1]["pose"] == "peace"
    assert ctrl.camera_lost()["point_len"] == 0.0


def thumbs_up(cx=0.5, cy=0.5, size=0.2, down=False):
    """A fist with the thumb sticking out towards the top of the image (or the bottom)."""
    s = size * H
    pts = shaped_hand(folded=("index", "middle", "ring", "pinky"), cx=cx, cy=cy, size=size)
    sign = 1.0 if down else -1.0

    def px(dx, dy):
        return (cx + dx * s / W, cy + dy * s / H, 0.0)
    pts[2] = px(-0.8, 0.3)
    pts[3] = px(-0.85, 0.3 + sign * 0.5)
    pts[4] = px(-0.9, 0.3 + sign * 1.0)
    return pts


def test_thumbs_up_is_told_from_a_fist_and_reports_where_the_thumb_points():
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    up = frames(ctrl, [thumbs_up()] * 2)[-1]
    assert up["pose"] == "thumb" and not up["pinch"]
    assert up["thumb_dy"] < -0.9 and abs(up["thumb_dx"]) < 0.2  # towards the top of the image
    down = frames(ctrl, [thumbs_up(down=True)])[-1]
    assert down["pose"] == "thumb" and down["thumb_dy"] > 0.9
    # the thumb tucked over the folded fingers: still a fist
    fist = shaped_hand(folded=("index", "middle", "ring", "pinky"), thumb_at="index")
    assert frames(ctrl, [fist])[-1]["pose"] == "fist"
    assert ctrl.camera_lost()["thumb_dy"] == 0.0
