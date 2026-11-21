"""#230: the worksheet reader's client (POST /v1/sheet) with a fake server: no network."""

from __future__ import annotations

import io
import json
import logging
import struct
import urllib.error
from dataclasses import replace

import cv2
import numpy as np
import pytest

from corexy_ufo_backend import services_check as sc
from corexy_ufo_backend.study import StudyConfig, make_sheet_client
from corexy_ufo_backend.study.sheet_client import (MAX_BYTES, SheetClient, SheetError, box_to_pixels, parse_result,
                                                   prepare_image)

TOKEN = "sheet-secret-token-456"
URL = "https://192.0.2.10:8444"


@pytest.fixture(autouse=True)
def _fresh():
    SheetClient.forget()
    yield
    SheetClient.forget()


def jpeg(w: int, h: int) -> bytes:
    img = np.full((h, w, 3), 200, np.uint8)
    img[: h // 4, : w // 4] = 0
    return cv2.imencode(".jpg", img)[1].tobytes()


def with_orientation(data: bytes, orientation: int) -> bytes:
    """An EXIF APP1 segment with Orientation, as phones write it."""
    tiff = (b"MM\x00\x2a\x00\x00\x00\x08" + struct.pack(">H", 1)
            + struct.pack(">HHII", 0x0112, 3, 1, orientation << 16) + b"\x00\x00\x00\x00")
    app1 = b"\xff\xe1" + struct.pack(">H", 2 + 6 + len(tiff)) + b"Exif\x00\x00" + tiff
    return data[:2] + app1 + data[2:]


ANSWER = {
    "id": "sheet-1", "object": "sheet.result", "model": "tutor-ufo-v6-sheet",
    "image": {"width": 900, "height": 1200}, "paper_px": [[10, 10], [890, 12], [888, 1190], [12, 1188]],
    "problems": [
        {"number": 2, "box": [100, 500, 900, 600], "answer_box": [600, 520, 880, 590], "visible": "full",
         "answer_status": "blank", "student_answer": "", "correct_answer": "7", "notes": []},
        {"number": 1, "box": [100, 100, 900, 200], "answer_box": [600, 120, 880, 190], "visible": "full",
         "answer_status": "incorrect", "student_answer": "42", "correct_answer": "45", "notes": ["計算し直した"],
         "box_px": [90, 120, 810, 240], "answer_box_px": [540, 144, 792, 228]},
        {"number": 3, "box": [100, 700, 900, 800], "answer_box": None, "visible": "partial",
         "answer_status": "something-new", "student_answer": None, "correct_answer": None},
    ],
    "counts": {}, "unsolved": {}, "notes": [], "seconds": 9.8,
}


class FakeResp(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeServer:
    """Answers each call with the next item: a dict (200) or an int (that HTTP error)."""

    def __init__(self, *answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, req, timeout):
        self.calls.append({"url": req.full_url, "headers": dict(req.header_items()), "body": json.loads(req.data),
                           "timeout": timeout, "method": req.get_method()})
        a = self.answers.pop(0)
        if isinstance(a, int):
            body = json.dumps({"error": {"message": f"fake {a}", "type": "x"}}).encode()
            raise urllib.error.HTTPError(req.full_url, a, "x", {}, io.BytesIO(body))
        if isinstance(a, Exception):
            raise a
        return FakeResp(json.dumps(a).encode())


def client(server, token=TOKEN, sleeps=None, **kw):
    return SheetClient(URL, token, opener=server, sleep=(sleeps.append if sleeps is not None else lambda s: None), **kw)


# ------------------------------------------------------------------ the image


def test_a_big_photo_is_shrunk_to_1800_and_stays_under_4mb():
    im = prepare_image(jpeg(4000, 3000))
    assert (im.width, im.height) == (1800, 1350) and (im.source_width, im.source_height) == (4000, 3000)
    assert len(im.jpeg) <= MAX_BYTES and im.data_url.startswith("data:image/jpeg;base64,")


def test_a_small_photo_is_not_enlarged():
    im = prepare_image(jpeg(800, 600))
    assert (im.width, im.height) == (800, 600)


def test_exif_rotation_is_applied_to_the_pixels():
    im = prepare_image(with_orientation(jpeg(400, 200), 6))  # a phone held upright: rotate 90°
    assert (im.width, im.height) == (200, 400) == (im.source_width, im.source_height)
    sent = cv2.imdecode(np.frombuffer(im.jpeg, np.uint8), cv2.IMREAD_COLOR)
    assert sent.shape[:2] == (400, 200)


def test_not_an_image_is_refused_before_sending():
    server = FakeServer()
    with pytest.raises(SheetError) as e:
        client(server).read(b"not a jpeg")
    assert e.value.kind == "image" and server.calls == []


def test_box_to_pixels():
    assert box_to_pixels([100, 200, 500, 1000], 4000, 3000) == (400, 600, 2000, 3000)
    assert box_to_pixels(None, 10, 10) is None and box_to_pixels([1, 2, 3], 10, 10) is None


# ------------------------------------------------------------------ a call


def test_a_read_sends_the_photo_and_parses_the_problems():
    server = FakeServer(ANSWER)
    res = client(server).read(jpeg(3600, 4800), calc=True, crop=False)
    call = server.calls[0]
    assert call["url"] == URL + "/v1/sheet" and call["method"] == "POST"
    assert call["headers"]["Authorization"] == "Bearer " + TOKEN
    assert call["body"]["image"].startswith("data:image/jpeg;base64,")
    assert call["body"]["calc"] is True and call["body"]["crop"] is False
    assert call["timeout"] >= 120
    assert [p["number"] for p in res.problems] == [1, 2, 3]
    assert res.problems[2]["answer_status"] == "unreadable" and res.problems[2]["student_answer"] == ""
    assert res.counts == {"correct": 0, "incorrect": 1, "blank": 1, "partial": 0, "unreadable": 1}
    assert res.read_anything and res.cropped
    assert "3 問" in res.summary() and "まちがい 1" in res.summary()
    # the 0..1000 boxes on the photo given (3600x4800), not on the 1350x1800 image sent
    assert res.image.width == 1350
    assert res.boxes_on_source(res.problems[0]) == ((360, 480, 3240, 960), (2160, 576, 3168, 912))
    assert res.boxes_on_source(res.problems[2])[1] is None


def test_no_token_sends_no_authorization_header():
    server = FakeServer(ANSWER)
    client(server, token="").read(jpeg(100, 100))
    assert "Authorization" not in server.calls[0]["headers"]


def test_an_empty_sheet_means_could_not_read():
    res = parse_result({**ANSWER, "problems": [], "paper_px": None}, prepare_image(jpeg(100, 100)))
    assert not res.read_anything and not res.cropped and res.summary() == "問題を読めなかった"


def test_a_wrong_shape_is_an_error():
    with pytest.raises(SheetError) as e:
        client(FakeServer({"error": "x"})).read(jpeg(100, 100))
    assert e.value.kind == "response"


def test_the_timeout_is_at_least_120_seconds():
    assert SheetClient(URL, TOKEN, timeout_s=20).timeout_s == 120
    with pytest.raises(SheetError):
        SheetClient("192.0.2.10:8444", TOKEN)


# ------------------------------------------------------------------ errors and retries


def test_401_is_not_retried_and_that_token_is_not_sent_again():
    server = FakeServer(401)
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))
    assert e.value.kind == "auth" and e.value.status == 401 and len(server.calls) == 1
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))  # a new client, the same token: still not sent
    assert e.value.kind == "auth" and len(server.calls) == 1
    # a corrected token goes out
    server.answers.append(ANSWER)
    client(server, token="another").read(jpeg(100, 100))
    assert len(server.calls) == 2


def test_a_request_waiting_behind_a_401_is_not_sent():
    """Review on #231: the check runs again once the server's lock is free."""
    import threading
    gate, entered = threading.Event(), threading.Event()
    calls = []

    def slow_401(req, timeout):
        calls.append(1)
        entered.set()
        gate.wait(5)
        raise urllib.error.HTTPError(req.full_url, 401, "x", {}, io.BytesIO(b"{}"))
    errors: list[SheetError] = []

    def run():
        try:
            client(slow_401, concurrency=1).read(jpeg(100, 100))
        except SheetError as e:
            errors.append(e)
    first = threading.Thread(target=run)
    first.start()
    assert entered.wait(5)
    second = threading.Thread(target=run)
    second.start()  # passes the early check (no 401 yet) and waits for the lock
    second.join(0.2)
    gate.set()
    first.join(5)
    second.join(5)
    assert len(calls) == 1 and [e.kind for e in errors] == ["auth", "auth"]


@pytest.mark.parametrize("code,kind", [(400, "bad_request"), (403, "forbidden"), (413, "too_large")])
def test_client_errors_are_not_retried(code, kind):
    server = FakeServer(code, ANSWER)
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))
    assert e.value.kind == kind and len(server.calls) == 1


def test_429_waits_ten_minutes_without_sending():
    server = FakeServer(429)
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))
    assert e.value.kind == "blocked"
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))
    assert e.value.kind == "blocked" and len(server.calls) == 1


def test_503_is_tried_again_after_5_10_20_seconds():
    sleeps: list[float] = []
    server = FakeServer(503, 503, ANSWER)
    assert client(server, sleeps=sleeps).read(jpeg(100, 100)).problems
    assert sleeps == [5, 10] and len(server.calls) == 3
    sleeps.clear()
    server = FakeServer(503, 503, 503, 503)
    with pytest.raises(SheetError) as e:
        client(server, sleeps=sleeps).read(jpeg(100, 100))
    assert e.value.kind == "busy" and sleeps == [5, 10, 20] and len(server.calls) == 4


def test_500_is_tried_once_more():
    server = FakeServer(500, ANSWER)
    assert client(server).read(jpeg(100, 100)).problems and len(server.calls) == 2
    server = FakeServer(500, 500, ANSWER)
    with pytest.raises(SheetError) as e:
        client(server).read(jpeg(100, 100))
    assert e.value.kind == "server" and len(server.calls) == 2


def test_no_connection_is_a_network_error():
    with pytest.raises(SheetError) as e:
        client(FakeServer(urllib.error.URLError("refused"))).read(jpeg(100, 100))
    assert e.value.kind == "network"


def test_the_token_and_the_image_never_reach_an_error_or_the_log(caplog):
    caplog.set_level(logging.DEBUG)
    photo = jpeg(100, 100)
    for answers in ((401,), (503, 503, 503, 503), (500, 500), (403,)):
        SheetClient.forget()
        with pytest.raises(SheetError) as e:
            client(FakeServer(*answers)).read(photo)
        assert TOKEN not in str(e.value) and "base64" not in str(e.value)
    assert TOKEN not in caplog.text and "base64" not in caplog.text


# ------------------------------------------------------------------ the settings and the 校正 tab


def test_make_sheet_client_uses_the_tutor_settings(tmp_path):
    (tmp_path / "config" / "secrets").mkdir(parents=True)
    (tmp_path / "config" / "secrets" / "tutor_token.txt").write_text(TOKEN + "\n")
    cfg = replace(StudyConfig.from_raw({"study": {"tutor_url": URL + "/", "sheet_timeout_s": 30}}), root=str(tmp_path))
    c = make_sheet_client(cfg)
    assert c.url == URL + "/v1/sheet" and c.token == TOKEN and c.timeout_s == 120
    with pytest.raises(SheetError) as e:
        make_sheet_client(replace(cfg, tutor_url=""))
    assert e.value.kind == "config"


def test_check_sheet_says_what_it_read(monkeypatch, tmp_path):
    cfg = replace(StudyConfig.from_raw({"study": {"tutor_url": URL}}), root=str(tmp_path))
    monkeypatch.setattr(SheetClient, "_open", lambda self, req, timeout=None: FakeResp(json.dumps(ANSWER).encode()))
    r = sc.check_sheet(cfg)
    assert r["name"] == "sheet" and r["status"] == "ok" and "3 問" in r["detail"]
    monkeypatch.setattr(SheetClient, "_open", lambda self, req, timeout=None: FakeResp(json.dumps({**ANSWER, "problems": []}).encode()))
    assert sc.check_sheet(cfg)["status"] == "ng"
    monkeypatch.setattr(sc, "make_sheet_client", lambda c: (_ for _ in ()).throw(SheetError("config", "URL がない")))
    r = sc.check_sheet(cfg)
    assert r["status"] == "ng" and r["detail"] == "URL がない"


async def test_only_an_ask_run_reads_the_sample_sheet(monkeypatch, tmp_path):
    called = []
    monkeypatch.setattr(sc, "check_jev", lambda p: sc.result("jev", "ok", "x"))
    monkeypatch.setattr(sc, "check_tutor", lambda c: sc.result("tutor", "ok", "x"))
    monkeypatch.setattr(sc, "check_sheet", lambda c: (called.append(1), sc.result("sheet", "ok", "x"))[1])

    async def fake_ask(cfg, provider):
        return sc.result("ask", "ok", "x")
    monkeypatch.setattr(sc, "ask_once", fake_ask)
    raw = {"study": {"provider": "claude", "explain_provider": "tutor", "tutor_url": URL}}
    monkeypatch.setattr(sc, "check_claude", lambda c: sc.result("claude", "ok", "x"))
    names = [r["name"] for r in await sc.check_all(raw, root=tmp_path)]
    assert "sheet" not in names and called == []
    names = [r["name"] for r in await sc.check_all(raw, ask=True, root=tmp_path)]
    assert names[-2:] == ["ask", "sheet"] and called == [1]
    raw = {"study": {"provider": "claude"}}
    names = [r["name"] for r in await sc.check_all(raw, ask=True, root=tmp_path)]
    assert "sheet" not in names


# ------------------------------------------------------------------ the 設定 screen's プリント tab


def test_the_tab_payload_keeps_the_boxes_of_the_frame_and_the_paper_as_fractions():
    from corexy_ufo_backend.study.sheet_client import sheet_payload
    res = parse_result(ANSWER, prepare_image(jpeg(900, 1200)))
    d = sheet_payload(res)
    assert [p["number"] for p in d["problems"]] == [1, 2, 3]
    assert d["problems"][0]["box"] == [100, 100, 900, 200] and "box_px" not in d["problems"][0]
    assert d["paper"][0] == pytest.approx([10 / 900, 10 / 1200]) and d["counts"]["incorrect"] == 1
    assert d["read_anything"] and "3 問" in d["summary"] and d["image"] == {"width": 900, "height": 1200}
    json.dumps(d)  # goes over the WebSocket
    assert d["response"] is res.raw  # the server's whole answer, shown as it is
    assert sheet_payload(parse_result({**ANSWER, "paper_px": None}, res.image))["paper"] is None


async def test_the_server_reads_a_frame_with_sheet_read(monkeypatch):
    import base64
    import websockets
    import corexy_ufo_backend.study as study
    from corexy_ufo_backend.robot.mock_robot import MockRobot
    from corexy_ufo_backend.websocket import GameServer
    from ws_helpers import cmd

    seen = []

    class Fake:
        def read(self, data, calc=True, crop=True):
            seen.append((len(data), calc, crop))
            if data == b"refuse":
                raise SheetError("auth", "トークンが違う", 401)
            return parse_result(ANSWER, prepare_image(data))
    monkeypatch.setattr(study, "make_sheet_client", lambda cfg: Fake())
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    frame = jpeg(640, 480)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            m = await cmd(ws, "sheet_read", {"image_jpeg_base64": base64.b64encode(frame).decode(), "crop": False}, rid="a")
            assert m["type"] == "ack" and m["data"]["command"] == "sheet_read"
            assert [p["number"] for p in m["data"]["problems"]] == [1, 2, 3] and seen[-1] == (len(frame), True, False)
            m = await cmd(ws, "sheet_read", {"image_jpeg_base64": base64.b64encode(b"refuse").decode()}, rid="b")
            assert m["type"] == "nack" and "トークン" in m["data"]["reason"]
            m = await cmd(ws, "sheet_read", {"image_jpeg_base64": "!!"}, rid="c")
            assert m["type"] == "nack" and len(seen) == 2
    finally:
        await srv.stop()


# ------------------------------------------------------------------ the stream (API_SPEC §6.3)


def sse(*events, done=True):
    lines = [f"data: {json.dumps(e)}\n\n" for e in events]
    if done:
        lines.append("data: [DONE]\n\n")
    return "".join(lines).encode()


class SSEServer(FakeServer):
    def __call__(self, req, timeout):
        self.calls.append({"body": json.loads(req.data)})
        a = self.answers.pop(0)
        if isinstance(a, int):
            raise urllib.error.HTTPError(req.full_url, a, "x", {}, io.BytesIO(b"{}"))
        return FakeResp(a)


START = {"object": "sheet.start", "image": {"width": 900, "height": 1200}, "paper_px": None}
P1, P2, P3 = ({**ANSWER["problems"][1]}, {**ANSWER["problems"][0]}, {**ANSWER["problems"][2]})


def test_streamed_problems_come_one_by_one_and_the_result_is_the_last_event():
    server = SSEServer(sse(START, {"object": "sheet.problem", "index": 0, "problem": P1},
                           {"object": "sheet.problem", "index": 1, "problem": P2}, {"object": "something.new"},
                           {**ANSWER, "object": "sheet.result"}))
    got = []
    res = client(server).read(jpeg(300, 400), on_problem=lambda p: got.append(p["number"]) and False)
    assert server.calls[0]["body"]["stream"] is True and got == [1, 2]
    assert [p["number"] for p in res.problems] == [1, 2, 3] and not res.raw.get("stopped_early")


def test_a_stream_stops_when_asked_and_keeps_what_came():
    server = SSEServer(sse(START, {"object": "sheet.problem", "index": 0, "problem": P1},
                           {"object": "sheet.problem", "index": 1, "problem": P2},
                           {"object": "sheet.problem", "index": 2, "problem": P3}))
    res = client(server).read(jpeg(300, 400), on_problem=lambda p: p["number"] == 2)
    assert [p["number"] for p in res.problems] == [1, 2] and res.raw["stopped_early"]


def test_a_stream_that_fails_or_breaks_off_is_an_error():
    for body, kind in ((sse(START, {"error": {"message": "生成に失敗しました", "type": "server_error"}}), "server"),
                       (sse(START, {"object": "sheet.problem", "index": 0, "problem": P1}, done=False), "response")):
        SheetClient.forget()
        with pytest.raises(SheetError) as e:
            client(SSEServer(body, body)).read(jpeg(100, 100), on_problem=lambda p: False)
        assert e.value.kind == kind


def test_two_readings_may_run_at_once_a_third_waits():
    import threading
    gate = threading.Event()
    inside = []
    lock = threading.Lock()

    def slow(req, timeout):
        with lock:
            inside.append(1)
        gate.wait(5)
        return FakeResp(json.dumps(ANSWER).encode())
    threads = [threading.Thread(target=lambda: client(slow).read(jpeg(100, 100))) for _ in range(3)]
    for t in threads:
        t.start()
    for _ in range(100):
        if len(inside) >= 2:
            break
        threading.Event().wait(0.01)
    threading.Event().wait(0.1)
    at_once = len(inside)
    gate.set()
    for t in threads:
        t.join(5)
    assert at_once == 2 and len(inside) == 3


# ------------------------------------------------------------------ #244: HELP's locate gives up in time
def test_a_deadline_includes_the_wait_for_a_free_slot():
    import time as _t
    srv = FakeServer(ANSWER)
    c = client(srv, concurrency=1)
    c.lock.acquire()  # the watch's reading holds the only slot
    try:
        t0 = _t.monotonic()
        with pytest.raises(SheetError) as e:
            c.read(jpeg(320, 240), deadline_s=0.3, label="locate 3")
        assert e.value.kind == "timeout" and "混んでいる" in str(e.value) and "0 秒" not in str(e.value)
        assert _t.monotonic() - t0 < 1.0 and srv.calls == []  # never sent
    finally:
        c.lock.release()
    assert c.read(jpeg(320, 240), deadline_s=5).problems  # the slot is free again (and released after)
    assert c.lock.acquire(blocking=False)
    c.lock.release()


def test_a_deadline_caps_the_socket_wait_and_a_slow_stream():
    import time as _t

    class SlowStream(io.BytesIO):
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def __iter__(self):
            for k in range(50):
                _t.sleep(0.05)
                yield b": still reading\n"

    calls = []

    def opener(req, timeout):
        calls.append(timeout)
        return SlowStream()
    c = SheetClient(URL, TOKEN, opener=opener, sleep=lambda s: None)
    t0 = _t.monotonic()
    with pytest.raises(SheetError) as e:
        c.read(jpeg(320, 240), on_problem=lambda p: False, deadline_s=0.4, label="locate 3")
    assert e.value.kind == "timeout" and _t.monotonic() - t0 < 1.0
    assert calls and calls[0] <= 0.4  # the socket waits no longer than what is left
    # a socket timeout at the deadline is "busy", not "cannot connect"

    def timing_out(req, timeout):
        _t.sleep(timeout)
        raise urllib.error.URLError(TimeoutError("timed out"))
    c = SheetClient(URL, TOKEN, opener=timing_out, sleep=lambda s: None)
    with pytest.raises(SheetError) as e:
        c.read(jpeg(320, 240), deadline_s=0.2)
    assert e.value.kind == "timeout"
    # without a deadline nothing changes: the socket's own timeout
    srv = FakeServer(ANSWER)
    client(srv).read(jpeg(320, 240))
    assert srv.calls[0]["timeout"] == 180.0


def test_a_deadline_holds_when_the_server_drips_bytes_without_a_newline():
    """Review on #245: a real socket, bytes every 0.05 s and never a whole line: the read is cut
    at the deadline (not the socket timeout, which each byte resets)."""
    import threading as _th
    import time as _t
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Drip(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                for _ in range(60):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    _t.sleep(0.05)
            except OSError:
                pass

        def log_message(self, *a):
            pass
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Drip)
    th = _th.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    try:
        c = SheetClient(f"http://127.0.0.1:{srv.server_address[1]}", TOKEN, sleep=lambda s: None)
        t0 = _t.monotonic()
        with pytest.raises(SheetError) as e:
            c.read(jpeg(320, 240), on_problem=lambda p: False, deadline_s=0.3)
        assert e.value.kind == "timeout" and _t.monotonic() - t0 < 0.8
        assert c.lock.acquire(blocking=False)  # the slot is free at once
        c.lock.release()
    finally:
        srv.shutdown()
        srv.server_close()
