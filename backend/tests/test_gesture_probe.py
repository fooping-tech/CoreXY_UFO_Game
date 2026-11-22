"""Gesture probe (#256): per-frame measurements and the summary per label (no camera)."""

import json

import pytest

from corexy_ufo_backend.vision_service import gesture_probe as gp
from corexy_ufo_backend.vision_service.hand_control import HandControl, HandControlConfig
from test_hand_control import H, W, shaped_hand

ALL = ("index", "middle", "ring", "pinky")


def world_hand(folded=()):
    """World landmarks (metres) of a flat hand; a folded finger curls 90 degrees at
    the MCP, PIP and DIP each (a fist), a straight one goes on in line."""
    pts = [(0.0, 0.0, 0.0)] * 21
    pts[0] = (0.0, 0.09, 0.0)
    for x, (mcp, pip, dip, tip) in zip((-0.03, -0.01, 0.01, 0.03), gp.CHAINS.values()):
        pts[mcp] = (x, 0.0, 0.0)
        if mcp in {gp.CHAINS[f][0] for f in folded}:
            pts[pip] = (x, 0.0, 0.03)       # 90 degrees at the MCP (towards the palm)
            pts[dip] = (x, 0.02, 0.03)      # 90 degrees at the PIP
            pts[tip] = (x, 0.02, 0.01)      # 90 degrees at the DIP
        else:
            pts[pip] = (x, -0.03, 0.0)
            pts[dip] = (x, -0.05, 0.0)
            pts[tip] = (x, -0.07, 0.0)
    pts[4] = (-0.08, 0.03, 0.0)
    return pts


def test_finger_extension_and_the_3d_bend_tell_straight_from_folded():
    ext = gp.finger_extension(shaped_hand(), W, H)
    assert all(v > 1.0 for v in ext.values())
    ext = gp.finger_extension(shaped_hand(folded=ALL), W, H)
    assert all(v < 1.0 for v in ext.values())
    bend = gp.finger_bend3d(world_hand())
    assert all(v < 25.0 for v in bend.values())  # only the splay from the wrist line
    bend = gp.finger_bend3d(world_hand(folded=("ring", "pinky")))
    assert bend["ring"] == pytest.approx(270.0) and bend["index"] < 25.0


def test_pose_from_folded_follows_the_games_rule():
    f = lambda *names: {k: k in names for k in ALL}  # noqa: E731
    assert gp.pose_from_folded(f(), False) == "open"
    assert gp.pose_from_folded(f(*ALL), False) == "fist"
    assert gp.pose_from_folded(f(*ALL), True) == "thumb"
    assert gp.pose_from_folded(f("ring", "pinky"), False) == "peace"
    assert gp.pose_from_folded(f("middle", "ring", "pinky"), False) == "point"
    assert gp.pose_from_folded(f("pinky"), False) == "three"
    assert gp.pose_from_folded(f("index"), False) == "other"


def test_a_record_carries_the_decision_and_the_measurements():
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    lm = shaped_hand()
    ev = ctrl.update([lm], [0.9], W, H, 0.0)
    rec = gp.frame_record(i=0, t=0.0, label="open", ev=ev, hands=[lm], world=[world_hand()], scores=[0.9],
                          handedness=["Right"], w=W, h=H, latency_ms=12.3, gap_ms=0.0, bright=100.0, blur=50.0)
    assert rec["pose"] == "open" and rec["pose3d"] == "open" and rec["hands"] == 1
    assert set(rec["ext"]) == set(ALL) and len(rec["lm"]) == 21 and len(rec["wlm"]) == 21
    assert rec["hand_px"] > 0 and rec["bright"] == 100.0
    json.dumps(rec)  # one JSONL line
    ev = HandControl().update([], [], W, H, 1000.0)
    rec = gp.frame_record(i=1, t=1.0, label="open", ev=ev, hands=[], world=[], scores=[], handedness=[],
                          w=W, h=H, latency_ms=10.0, gap_ms=33.0)
    assert rec["hands"] == 0 and rec["reason"] == "no_hand" and "ext" not in rec and "pose3d" not in rec


def rec(t, label, hands=1, pose="open", pinch=False, reason="", ext=None, **kw):
    r = {"t": t, "label": label, "hands": hands, "pose": pose if hands == 1 else "", "pinch": pinch,
         "reason": reason or ("" if hands == 1 else "no_hand"), "gap_ms": 33.0, "latency_ms": 20.0}
    if ext is not None:
        r["ext"] = ext
    r.update(kw)
    return r


def test_pinch_ends_are_told_apart_shape_lost_and_opened():
    recs = [rec(0.0, "pinch", pinch=True), rec(0.03, "pinch", pose="fist"),          # cut by a fist frame
            rec(0.06, "pinch", pinch=True), rec(0.1, "pinch", hands=0),              # lost
            rec(0.5, "pinch", pinch=True), rec(0.53, "pinch", pose="open"),          # opened
            rec(0.56, "pinch", pinch=True), rec(0.6, "pinch", hands=2, reason="multiple_hands")]
    ends = gp.pinch_ends(recs)
    assert ends == {"shape:fist": 1, "lost:no_hand": 1, "opened": 1, "lost:multiple_hands": 1}
    m = gp.key_metrics(gp.summarize(recs))["pinch"]
    assert m["cut_by_shape"] == 1 and m["right"] == pytest.approx(4 / 8)


def test_lost_runs_only_count_a_hand_that_was_seen_first():
    recs = [rec(0.0, "x", hands=0), rec(0.1, "x"), rec(0.2, "x", hands=0), rec(0.25, "x", hands=0), rec(0.6, "x"),
            rec(0.7, "x", hands=0), rec(0.8, "x", hands=0)]
    assert gp.lost_runs(recs) == pytest.approx([400.0, 100.0])
    assert gp.lost_runs([rec(0.0, "x", hands=0), rec(0.1, "x", hands=0)]) == []


def test_fist_segments_record_whether_the_hand_was_already_tracked():
    folded = {k: 0.8 for k in ALL}
    recs = [rec(0.0, "open"), rec(0.1, "open"),                     # open, tracked
            rec(0.2, "fist", pose="fist", ext=folded),              # fist straight from an open hand
            rec(0.3, "fist", pose="fist", ext=folded),
            rec(0.4, "", hands=0), rec(0.5, "", hands=0),           # hand away
            rec(0.6, "fist", hands=0), rec(0.7, "fist", hands=0),   # a fist from nothing: not found...
            rec(0.9, "fist", pose="other", ext={"index": 1.1, "middle": 0.8, "ring": 0.8, "pinky": 0.8})]
    s = gp.summarize(recs)["fist"]
    assert s.segments == 2 and s.frames == 5 and s.seen == 3
    tracked = [x for x in s.seg_tracked if x[0]]
    fresh = [x for x in s.seg_tracked if not x[0]]
    assert tracked[0][1] == 1.0 and tracked[0][2] == pytest.approx(0.0)
    assert fresh[0][1] == pytest.approx(1 / 3) and fresh[0][2] == pytest.approx(300.0)
    assert s.blocking_fingers == {"index": 1}
    text = gp.report(gp.summarize(recs))
    assert "直前から手を追跡していた区間" in text and "手が見えていない状態から始めた区間" in text
    assert "グー（fist）" in text and "パー（open）" in text


def test_open_hand_blocked_by_a_folded_finger_is_named():
    recs = [rec(0.0, "open", pose="other", ext={"index": 1.3, "middle": 1.3, "ring": 1.2, "pinky": 0.9}),
            rec(0.03, "open", pose="other", ext={"index": 1.3, "middle": 1.3, "ring": 0.95, "pinky": 0.9}),
            rec(0.06, "open", pose="open", ext={"index": 1.3, "middle": 1.3, "ring": 1.2, "pinky": 1.1})]
    s = gp.summarize(recs)["open"]
    assert s.blocking_fingers == {"pinky": 2, "ring": 1}
    assert gp.key_metrics({"open": s})["open"]["right"] == pytest.approx(1 / 3)
    assert "pinky 2" in gp.report({"open": s})


def test_the_games_pipeline_through_records_and_jsonl():
    ctrl = HandControl(HandControlConfig(pinch_confirm_ms=0, pinch_start=1.0, pinch_release=1.5))
    lines = [json.dumps({"type": "meta", "gesture": {"lost_grace_ms": 300}})]
    shapes = [("open", shaped_hand(), world_hand())] * 5 + [("fist", shaped_hand(folded=ALL, thumb_at="index"), world_hand(ALL))] * 5 \
        + [("pinch", shaped_hand(thumb_at="index"), world_hand())] * 5
    for i, (label, lm, wl) in enumerate(shapes):
        ev = ctrl.update([lm], [0.9], W, H, i * 33.0)
        lines.append(json.dumps(gp.frame_record(i=i, t=i * 0.033, label=label, ev=ev, hands=[lm], world=[wl],
                                                scores=[0.9], handedness=["Right"], w=W, h=H, latency_ms=10.0,
                                                gap_ms=33.0)))
    meta, recs = gp.read_jsonl(lines)
    assert meta["gesture"]["lost_grace_ms"] == 300 and len(recs) == 15
    m = gp.key_metrics(gp.summarize(recs))
    assert m["open"]["right"] == 1.0 and m["open"]["right3d"] == 1.0
    assert m["fist"]["right"] == 1.0 and m["fist"]["right3d"] == 1.0
    assert m["pinch"]["right"] == 1.0 and m["pinch"]["seen"] == 1.0
