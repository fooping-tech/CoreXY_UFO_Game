"""#118: the arm-tip camera's swing cancelled by optical flow, streamed on its own port."""

from __future__ import annotations

import asyncio
import json
import math

import cv2
import numpy as np
import pytest
import websockets

from corexy_ufo_backend.vision_service.focus_stream import FocusStream, FocusStreamParams, pack, unpack
from corexy_ufo_backend.vision_service.stabilizer import Stabilizer, StabilizerParams, correction_matrix

W, H = 640, 360
FPS = 30.0


def scene(seed: int = 1) -> np.ndarray:
    """A desk-like picture bigger than the frame: blobs, strokes, texture."""
    rng = np.random.default_rng(seed)
    img = np.full((H * 2, W * 2, 3), 200, np.uint8)
    for _ in range(400):
        x, y = int(rng.integers(0, W * 2)), int(rng.integers(0, H * 2))
        col = tuple(int(c) for c in rng.integers(0, 255, 3))
        if rng.random() < 0.5:
            cv2.circle(img, (x, y), int(rng.integers(3, 18)), col, -1)
        else:
            cv2.rectangle(img, (x, y), (x + int(rng.integers(5, 40)), y + int(rng.integers(3, 12))), col, -1)
    return cv2.GaussianBlur(img, (3, 3), 0)


def view(big: np.ndarray, x: float, y: float, a: float) -> np.ndarray:
    """The camera's frame when the content is moved by (x, y) and turned by a about the centre."""
    off = np.array([[1.0, 0.0, -W / 2.0], [0.0, 1.0, -H / 2.0], [0.0, 0.0, 1.0]])  # big -> frame
    m = np.vstack([correction_matrix((W, H), x, y, a, 1.0), [0, 0, 1]]) @ off
    return cv2.warpAffine(big, m[:2], (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)


def frame_motion(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ga = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gb = cv2.cvtColor(b, cv2.COLOR_BGR2GRAY).astype(np.float32)
    (dx, dy), _ = cv2.phaseCorrelate(ga, gb)
    return np.array([dx, dy])


def run(path, seconds: float, params: StabilizerParams | None = None):
    big = scene()
    st = Stabilizer(params or StabilizerParams(zoom=1.0))
    raw, out, infos = [], [], []
    for i in range(int(seconds * FPS)):
        t = i / FPS
        x, y, a = path(t)
        f = view(big, x, y, a)
        o, info = st.update(f, t)
        raw.append(f)
        out.append(o)
        infos.append(info)
    return raw, out, infos


def jitter(frames: list[np.ndarray], skip: int) -> float:
    """RMS frame-to-frame motion after `skip` frames (the filter settling)."""
    d = [frame_motion(frames[i - 1], frames[i]) for i in range(skip + 1, len(frames))]
    return float(np.sqrt(np.mean(np.sum(np.square(d), axis=1))))


def test_a_swing_is_mostly_cancelled():
    # a 1.2 Hz swing of 18 px (the arm on its chains) and a smaller sideways one
    swing = lambda t: (18 * math.sin(2 * math.pi * 1.2 * t), 7 * math.sin(2 * math.pi * 0.9 * t + 1), 0.0)  # noqa: E731
    raw, out, infos = run(swing, 4.0)
    j_raw, j_out = jitter(raw, 45), jitter(out, 45)
    assert j_out < j_raw / 3.0, (j_raw, j_out)
    assert all(i["tracking"] for i in infos[1:])
    assert max(abs(i["dx"]) for i in infos[45:]) > 8  # it really moved the frames


def test_a_slow_move_is_followed_not_held():
    # a deliberate move: 120 px to the left over 2 s, then still
    def move(t):
        return (-120.0 * min(t / 2.0, 1.0), 0.0, 0.0)
    raw, out, infos = run(move, 6.0)
    assert abs(infos[-1]["dx"]) < 6.0  # caught up: the view shows where the arm went
    shift = frame_motion(raw[-1], out[-1])
    assert np.hypot(*shift) < 6.0


def test_a_twist_is_cancelled():
    swing = lambda t: (0.0, 0.0, math.radians(3.0) * math.sin(2 * math.pi * 1.0 * t))  # noqa: E731
    raw, out, infos = run(swing, 3.0)
    rots = [i["rot_deg"] for i in infos[45:]]
    assert max(abs(r) for r in rots) > 1.5
    # the correction follows the twist with the opposite sign
    want = [-3.0 * math.sin(2 * math.pi * 1.0 * (k / FPS)) for k in range(45, len(infos))]
    corr = np.corrcoef(rots, want)[0, 1]
    assert corr > 0.9, corr


def test_nothing_to_track_fades_the_correction():
    st = Stabilizer(StabilizerParams(zoom=1.0))
    flat = np.full((H, W, 3), 128, np.uint8)
    for i in range(10):
        out, info = st.update(flat, i / FPS)
    assert not info["tracking"] and info["dx"] == 0.0 and out.shape == flat.shape


def test_params_from_the_config_are_clamped():
    p = FocusStreamParams.from_raw({"camera": {"enabled": True, "focus": {"match": "Inno", "stabilize": {
        "enabled": True, "port": 9000, "fps": 500, "cutoff_hz": -1, "zoom": 3, "max_shift": True}}}})
    assert p.enabled and p.port == 9000 and p.camera == "Inno" and p.fps == 60.0
    assert p.stabilizer.cutoff_hz == 0.02 and p.stabilizer.zoom == 1.5 and p.stabilizer.max_shift == 0.12
    assert not FocusStreamParams.from_raw({"camera": {"enabled": False, "focus": {"stabilize": {"enabled": True}}}}).enabled
    assert not FocusStreamParams.from_raw({}).enabled


def test_the_frame_packet():
    data = pack({"seq": 3, "w": 4}, b"\xff\xd8jpeg")
    head, jpg = unpack(data)
    assert head == {"seq": 3, "w": 4} and jpg == b"\xff\xd8jpeg"
    with pytest.raises(ValueError):
        unpack(b"nope")


class FakeCamera:
    opened = 0
    released = 0

    def __init__(self, p):
        FakeCamera.opened += 1
        self.big = scene(2)
        self.t = 0.0

    def read(self):
        import time
        time.sleep(1 / 60)
        self.t += 1 / 30
        return True, view(self.big, 10 * math.sin(6 * self.t), 0.0, 0.0)

    def release(self):
        FakeCamera.released += 1


async def test_the_stream_opens_the_camera_while_watched():
    FakeCamera.opened = FakeCamera.released = 0
    p = FocusStreamParams(enabled=True, port=0, linger_s=0.1)
    fs = FocusStream(p, opener=FakeCamera)
    await fs.start()
    try:
        assert FakeCamera.opened == 0  # nobody watching: the camera stays closed
        async with websockets.connect(f"ws://127.0.0.1:{fs.port}", max_size=None) as ws:
            got = []
            status = None
            while len(got) < 5:
                m = await asyncio.wait_for(ws.recv(), 5)
                if isinstance(m, str):
                    status = json.loads(m)
                    continue
                got.append(unpack(m))
            assert status is not None and status["type"] == "focus_status"
            head, jpg = got[-1]
            assert head["stabilized"] and head["w"] == W and head["h"] == H and jpg[:2] == b"\xff\xd8"
            assert [h["seq"] for h, _ in got] == sorted(h["seq"] for h, _ in got)
            await ws.send(json.dumps({"stabilize": False}))
            for _ in range(20):
                m = await asyncio.wait_for(ws.recv(), 5)
                if isinstance(m, bytes) and not unpack(m)[0]["stabilized"]:
                    break
            else:
                pytest.fail("stabilize off not applied")
        assert FakeCamera.opened == 1
        for _ in range(50):
            await asyncio.sleep(0.05)
            if FakeCamera.released:
                break
        assert FakeCamera.released == 1  # released after the last client left
    finally:
        await fs.stop()


async def test_a_camera_that_does_not_open_is_reported_and_tried_again():
    """Review on #119: plugged in later (or back), the same connection gets frames."""
    tries = []

    def flaky(p):
        tries.append(1)
        if len(tries) < 3:
            raise OSError("camera 'Innomaker' could not be opened")
        return FakeCamera(p)
    fs = FocusStream(FocusStreamParams(enabled=True, port=0), opener=flaky)
    fs.retry_s = 0.05
    await fs.start()
    try:
        async with websockets.connect(f"ws://127.0.0.1:{fs.port}", max_size=None) as ws:
            states = []
            for _ in range(50):
                m = await asyncio.wait_for(ws.recv(), 5)
                if isinstance(m, bytes):
                    break
                states.append(json.loads(m)["data"])
            else:
                pytest.fail("no frames after the camera came back")
            errors = [s for s in states if s["state"] == "error"]
            assert errors and "could not be opened" in errors[0]["message"] and len(tries) == 3
    finally:
        await fs.stop()


class StallingCamera(FakeCamera):
    """The first one sends 5 frames and then nothing; the next ones work."""
    made = 0

    def __init__(self, p):
        super().__init__(p)
        StallingCamera.made += 1
        self.first = StallingCamera.made == 1
        self.reads = 0

    def read(self):
        self.reads += 1
        if self.first and self.reads > 5:
            import time
            time.sleep(1 / 60)
            return False, None
        return super().read()


async def test_a_camera_that_stops_is_opened_again():
    StallingCamera.made = 0
    opened = []

    def opener(p):
        opened.append(1)
        return StallingCamera(p)
    fs = FocusStream(FocusStreamParams(enabled=True, port=0), opener=opener)
    fs.retry_s = 0.05
    await fs.start()
    try:
        async with websockets.connect(f"ws://127.0.0.1:{fs.port}", max_size=None) as ws:
            seen_error = False
            frames_after = 0
            for _ in range(400):
                m = await asyncio.wait_for(ws.recv(), 10)
                if isinstance(m, str):
                    seen_error = seen_error or json.loads(m)["data"]["state"] == "error"
                elif seen_error:
                    frames_after += 1
                    if frames_after >= 3:
                        break
            assert seen_error and frames_after >= 3 and len(opened) == 2
    finally:
        await fs.stop()
