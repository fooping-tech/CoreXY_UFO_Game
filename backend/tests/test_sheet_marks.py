"""#116: the worksheet's four corner marks in an overview frame (OpenCV, no AI)."""

from __future__ import annotations

import cv2
import numpy as np
import pytest

from corexy_ufo_backend.study_mode.sheet_marks import CENTRES_MM, find_marks, find_marks_jpeg

PX = 4.0  # px per mm of the drawn page


def page(marks: bool = True) -> np.ndarray:
    img = np.full((int(297 * PX), int(210 * PX)), 250, np.uint8)
    rng = np.random.default_rng(3)
    for _ in range(40):  # text-like strokes and boxes: not marks
        x, y = rng.integers(40, 160), rng.integers(40, 260)
        cv2.rectangle(img, (int(x * PX), int(y * PX)), (int((x + rng.integers(5, 30)) * PX), int((y + 3) * PX)), 40, -1)
    for y0 in (52, 128, 204):  # answer boxes (outlined squares)
        cv2.rectangle(img, (int(150 * PX), int((y0 + 30) * PX)), (int(185 * PX), int((y0 + 50) * PX)), 30, 3)
    if marks:
        for cx, cy in CENTRES_MM.values():
            cv2.rectangle(img, (int((cx - 6) * PX), int((cy - 6) * PX)), (int((cx + 6) * PX), int((cy + 6) * PX)), 0, -1)
            cv2.rectangle(img, (int((cx - 2) * PX), int((cy - 2) * PX)), (int((cx + 2) * PX), int((cy + 2) * PX)), 255, -1)
    return img


def photo(img: np.ndarray, dst: list[tuple[float, float]], size=(1280, 720)) -> tuple[np.ndarray, np.ndarray]:
    """The page seen by the overview camera: page corners -> dst (a perspective), on a darker desk."""
    h, w = img.shape
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    m = cv2.getPerspectiveTransform(src, np.float32(dst))
    desk = np.full((size[1], size[0]), 90, np.uint8)
    warped = cv2.warpPerspective(img, m, size, borderValue=0)
    mask = cv2.warpPerspective(np.full_like(img, 255), m, size, borderValue=0)
    desk[mask > 0] = warped[mask > 0]
    return desk, m


def expected(m: np.ndarray, size=(1280, 720)) -> dict:
    out = {}
    for name, (cx, cy) in CENTRES_MM.items():
        p = m @ np.array([cx * PX, cy * PX, 1.0])
        out[name] = (p[0] / p[2] / size[0], p[1] / p[2] / size[1])
    return out


@pytest.mark.parametrize("dst", [
    [(470, 60), (800, 70), (840, 650), (430, 640)],     # upright, a bit of perspective
    [(300, 120), (620, 40), (760, 520), (420, 640)],    # turned about 25 degrees
])
def test_marks_found_in_an_oblique_photo(dst):
    frame, m = photo(page(), dst)
    got = find_marks(frame)
    assert got is not None, "no marks"
    want = expected(m)
    for name in ("tl", "tr", "bl", "br"):
        assert np.allclose(got["corners"][name], want[name], atol=0.006), (name, got["corners"][name], want[name])


def test_the_page_turned_upside_down_reads_with_its_top_up():
    # the page's top edge at the bottom of the image: the marks are alike, the nearer short side is the top
    frame, m = photo(page(), [(840, 650), (430, 640), (470, 60), (800, 70)])
    got = find_marks(frame)
    assert got is not None and got["corners"]["tl"][1] < got["corners"]["bl"][1]
    assert got["corners"]["tl"][0] < got["corners"]["tr"][0]


def test_no_marks_no_answer_and_the_jpeg_path():
    frame, _ = photo(page(marks=False), [(470, 60), (800, 70), (840, 650), (430, 640)])
    assert find_marks(frame) is None
    ok, jpg = cv2.imencode(".jpg", photo(page(), [(470, 60), (800, 70), (840, 650), (430, 640)])[0])
    assert find_marks_jpeg(jpg.tobytes()) is not None
    with pytest.raises(ValueError):
        find_marks_jpeg(b"not a jpeg")


async def test_the_server_finds_the_marks():
    import base64
    import websockets
    from corexy_ufo_backend.robot.mock_robot import MockRobot
    from corexy_ufo_backend.websocket import GameServer
    from test_homework_advice import _cmd
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    ok, jpg = cv2.imencode(".jpg", photo(page(), [(470, 60), (800, 70), (840, 650), (430, 640)])[0])
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await _cmd(ws, "worksheet_find", {"image_jpeg_base64": base64.b64encode(jpg.tobytes()).decode()}, rid="f")
            assert m["type"] == "ack" and m["data"]["found"] and set(m["data"]["corners"]) == {"tl", "tr", "bl", "br"}
            bad = await _cmd(ws, "worksheet_find", {"image_jpeg_base64": "!!"}, rid="b")
            assert bad["type"] == "nack"
    finally:
        await srv.stop()


def test_a_big_mark_like_thing_is_not_a_mark():
    # #130: the real top-right mark is hidden (a cable), and a much bigger dark square with a hole
    # (a tape dispenser) sits near it: a rectangle of marks would fit, the size does not
    dst = [(470, 60), (800, 70), (840, 650), (430, 640)]

    def frame_with(half: int, hole: int) -> tuple[np.ndarray, int, int]:
        frame, m = photo(page(), dst)
        tr = expected(m)["tr"]
        x, y = int(tr[0] * 1280), int(tr[1] * 720)
        cv2.rectangle(frame, (x - 16, y - 16), (x + 16, y + 16), 250, -1)  # the real mark covered
        bx, by = x - 35, y + 35
        cv2.rectangle(frame, (bx - half, by - half), (bx + half, by + half), 0, -1)
        cv2.rectangle(frame, (bx - hole, by - hole), (bx + hole, by + hole), 255, -1)
        return frame, bx, by

    big, _, _ = frame_with(25, 8)
    assert find_marks(big) is None
    # the same at a mark's size is taken (the check is the size, not the place)
    small, bx, by = frame_with(10, 3)
    got = find_marks(small)
    assert got is not None and np.allclose(got["corners"]["tr"], (bx / 1280, by / 720), atol=0.01)
