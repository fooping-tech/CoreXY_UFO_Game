"""Homework stage 3 (#79): locating the problem to look at, and the helper's voice."""

from __future__ import annotations

import asyncio
import base64
import io
import json
import shutil
import sys
import urllib.error
from pathlib import Path

import pytest
import websockets

from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService, LocateParams, SpeechConfig, SpeechService
from corexy_ufo_backend.homework.jev import JevError, JevResult
from corexy_ufo_backend.homework.locate import (LocateError, agrees, jev_box, jev_box_input, jpeg_size,
                                                 locate_prompt, parse_answer)
from corexy_ufo_backend.homework.speech import SayEngine, Speech, SpeechError, VoicevoxEngine
from corexy_ufo_backend.robot.mock_robot import MockRobot
from corexy_ufo_backend.websocket import GameServer


def jpeg(width: int, height: int, tag: bytes = b"") -> bytes:
    """A JPEG with a real SOF0 header (enough for jpeg_size and decode_jpeg)."""
    app0 = b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0\x00\x11\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big") + b"\x03" + b"\x00" * 9
    return b"\xff\xd8" + app0 + sof + b"\xff\xda\x00\x02" + tag + b"\xff\xd9"


NOW = jpeg(1024, 768, b"now")
NOW_B64 = base64.b64encode(NOW).decode()
WAV = b"RIFF" + (100).to_bytes(4, "little") + b"WAVEfmt " + b"\x00" * 60


def progress_output(level: int):
    probs = [0.0] * 6
    probs[level] = 1.0
    return {"answers": {"visible": {"type": "noul", "noul": 0.9}, "occluded": {"type": "noul", "noul": 0.1},
                        "progress": {"type": "score", "probabilities": {str(i): p for i, p in enumerate(probs)}}},
            "usage": {"input_tokens": 100, "output_tokens": 0}}


def box_output(l, t, r, b, conf=0.8):
    return {"answers": {"box": {"type": "box", "box": {"left": l, "top": t, "right": r, "bottom": b},
                                "confidence": conf}}, "usage": {"input_tokens": 50, "output_tokens": 0}}


# ------------------------------------------------------------------ pure parts
def test_jpeg_size_reads_the_sof_header():
    assert jpeg_size(NOW) == (1024, 768)
    assert jpeg_size(jpeg(640, 480)) == (640, 480)
    with pytest.raises(LocateError):
        jpeg_size(b"\xff\xd8nothing\xff\xd9")


def test_locate_prompt_kinds():
    stuck = locate_prompt("stuck", 1024, 768, True)
    assert "2 枚目は今の写真（1024×768" in stuck and "手が止まっている" in stuck and "書き足された" in stuck
    nxt = locate_prompt("next", 640, 480, False)
    assert "次に解く問題" in nxt and "1 枚目" not in nxt and "640×480" in nxt
    with pytest.raises(LocateError):
        locate_prompt("later", 1, 1, False)


def test_parse_answer():
    a = parse_answer('考えました。\n{"found": true, "problem": "(3) 4×12", "description_en": "problem (3)", '
                     '"box": [356, 443, 446, 462]}', 1024, 768)
    assert a["problem"] == "(3) 4×12" and a["description_en"] == "problem (3)"
    assert a["box"] == pytest.approx((356 / 1024, 443 / 768, 446 / 1024, 462 / 768))
    swapped = parse_answer('{"found": true, "box": [446, 462, 356, 443]}', 1024, 768)
    assert swapped["box"] == a["box"] and swapped["description_en"] == "the problem"
    with pytest.raises(LocateError, match="全部"):
        parse_answer('{"found": false, "reason": "全部解き終わっている"}', 1024, 768)
    with pytest.raises(LocateError) as e:
        parse_answer('{"found": true, "box": [900, 700, 1200, 760]}', 1024, 768)
    assert e.value.kind == "out_of_image"
    with pytest.raises(LocateError, match="大きすぎ"):
        parse_answer('{"found": true, "box": [0, 0, 1000, 700]}', 1024, 768)  # the whole sheet
    for junk in ("わかりません", '{"found": true, "box": [1, 2]}', '{"found": true, "box": [1, 2, "x", 4]}'):
        with pytest.raises(LocateError):
            parse_answer(junk, 1024, 768)


def test_jev_box_and_agreement():
    q = jev_box_input("AAAA", 'problem (3) "4 × 12 =" in section 2')
    assert q["state"] == {"photo": "photo"} and q["questions"]["box"]["type"] == "box"
    assert "problem (3)" in q["questions"]["box"]["instructions"]
    jb = jev_box(box_output(0.45, 0.6, 0.35, 0.58))  # sides swapped: sorted
    assert jb == ((0.35, 0.58, 0.45, 0.6), 0.8)
    assert jev_box({"answers": {}}) is None
    claude = (0.36, 0.58, 0.43, 0.6)
    assert agrees(claude, jb[0], 0.0)
    assert not agrees((0.6, 0.58, 0.7, 0.6), jb[0], 0.02)
    assert agrees((0.45, 0.58, 0.47, 0.6), jb[0], 0.02)  # centre 0.46: inside the widened box


def test_locate_and_speech_config():
    p = LocateParams.from_raw({"homework": {"locate": {"jev_margin": 5, "require_jev": False}}})
    assert p.jev_margin == 0.2 and not p.require_jev
    c = SpeechConfig.from_raw({"homework": {"speech": {"engines": ["say", "bogus"], "voicevox_url": "http://h:1/"}}})
    assert c.engines == ("say",) and c.voicevox_url == "http://h:1"
    with pytest.raises(ValueError):
        SpeechConfig.from_raw({"homework": {"speech": {"voicevox_url": "file:///etc/passwd"}}})
    repo = json.loads((Path(__file__).resolve().parents[2] / "config/game_config.json").read_text())
    assert LocateParams.from_raw(repo).require_jev and SpeechConfig.from_raw(repo).engines == ("voicevox", "say")


# ------------------------------------------------------------------ locate (service)
class LocateAdapter:
    def __init__(self, answer: str):
        self.answer = answer
        self.asked: list[tuple[str, list[bytes]]] = []
        self.closed = False

    async def start_session(self, workdir, instructions):
        assert "JSON だけ" in instructions
        return "t"

    async def ask(self, thread_id, text, image_path, on_delta, more_images=()):
        self.asked.append((text, [p.read_bytes() for p in (*more_images, image_path)]))
        half = len(self.answer) // 2
        await on_delta(self.answer[:half])
        await on_delta(self.answer[half:])
        return "turn"

    async def close_session(self, thread_id):
        pass

    async def close(self):
        self.closed = True


class ScriptedJev:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.inputs = []

    def run(self, jev_input, timeout=30.0):
        self.inputs.append(jev_input)
        out = self.outputs.pop(0)
        if isinstance(out, Exception):
            raise out
        return JevResult(output=out, latency_s=0.1)


ANSWER = '{"found": true, "problem": "大問2の(3)", "description_en": "problem (3) in section 2", ' \
         '"box": [356, 443, 446, 462]}'


async def _locate(svc, session_id, kind, image_b64=NOW_B64):
    sent = []

    async def emit(m):
        sent.append(m)

    await svc.locate(session_id, "L1", kind, image_b64, emit)
    await svc._locate_task
    return sent[-1]


async def test_locate_compares_with_the_frame_at_the_last_gain_and_checks_with_jev():
    first, gained = jpeg(1024, 768, b"first"), jpeg(1024, 768, b"gain")
    jev = ScriptedJev([progress_output(1), progress_output(1), progress_output(3), progress_output(3),
                       box_output(0.34, 0.57, 0.44, 0.61)])
    adapter = LocateAdapter(ANSWER)
    svc = HomeworkService(HomeworkConfig(enabled=True, stall_s=10, stall_min_gain=5), client_factory=lambda: jev,
                          advice_factory=lambda: adapter)
    await svc.start("s")

    async def emit(m):
        pass

    for i, frame in enumerate((first, jpeg(1024, 768, b"same"), jpeg(1024, 768, b"60 once"), gained)):
        await svc.frame("s", "f", base64.b64encode(frame).decode(), emit)
        await svc.sessions["s"].task
        if i == 2:  # median(20, 20, 60) = 20: no gain yet, still the first readable frame
            assert svc.sessions["s"].before_frame == first
    assert svc.sessions["s"].before_frame == gained  # median(20, 60, 60) = 60: a gain
    svc.sessions["s"].started -= 600
    m = await _locate(svc, "s", "stuck")
    assert m["type"] == "homework_locate_result"
    d = m["data"]
    assert d["verified"] and d["usable"] and d["compared"] and d["problem"] == "大問2の(3)"
    assert d["u"] == pytest.approx(401 / 1024, abs=1e-3) and d["v"] == pytest.approx(452.5 / 768, abs=1e-3)
    text, images = adapter.asked[0]
    assert images == [gained, NOW] and "2 枚目は今の写真" in text  # before first, then now
    assert "problem (3) in section 2" in jev.inputs[-1]["questions"]["box"]["instructions"]
    assert adapter.closed and not svc.sessions["s"].summary()["stalled"]  # helped: wait again
    await svc.close()


async def test_locate_refuses_to_move_when_jev_disagrees_or_is_missing():
    adapter = LocateAdapter(ANSWER)
    jev = ScriptedJev([box_output(0.7, 0.1, 0.8, 0.15)])
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: jev, advice_factory=lambda: adapter)
    d = (await _locate(svc, "", "next"))["data"]  # no watch running: the image now only
    assert not d["verified"] and not d["usable"] and "合いません" in d["reason"] and not d["compared"]
    assert len(adapter.asked[0][1]) == 1

    def no_key():
        raise JevError("config", "Jev の鍵が未設定です")

    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=no_key, advice_factory=lambda: adapter)
    d = (await _locate(svc, "", "next"))["data"]
    assert not d["usable"] and "鍵が未設定" in d["reason"]
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=no_key, advice_factory=lambda: adapter,
                          locate=LocateParams(require_jev=False))
    d = (await _locate(svc, "", "next"))["data"]
    assert d["usable"] and not d["verified"]  # require_jev false: the assistant's box alone


async def test_locate_errors():
    svc = HomeworkService(HomeworkConfig(enabled=True), advice_factory=lambda: LocateAdapter('{"found": false, '
                                                                                          '"reason": "見えない"}'))
    m = await _locate(svc, "", "stuck")
    assert m["type"] == "homework_locate_error" and m["data"]["code"] == "not_found" and "見えない" in m["data"]["message"]
    with pytest.raises(ValueError):
        await svc.locate("", "L", "later", NOW_B64, None)
    with pytest.raises(ValueError, match="大きさ"):
        await svc.locate("", "L", "next", base64.b64encode(b"\xff\xd8x\xff\xd9").decode(), None)
    with pytest.raises(ValueError, match="no assistant"):
        await HomeworkService(HomeworkConfig(enabled=True)).locate("", "L", "next", NOW_B64, None)


# ------------------------------------------------------------------ speech
class FakeResponse:
    def __init__(self, body: bytes):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def voicevox_opener(calls):
    def opener(req, timeout=0):
        calls.append((req.get_method(), req.full_url, req.data))
        if "/audio_query" in req.full_url:
            return FakeResponse(json.dumps({"accent_phrases": [], "speedScale": 1.0}).encode())
        if "/synthesis" in req.full_url:
            return FakeResponse(WAV)
        if req.full_url.endswith("/speakers"):
            return FakeResponse(json.dumps([{"name": "四国めたん", "styles": [{"id": 2}]},
                                            {"name": "ずんだもん", "styles": [{"id": 1}, {"id": 3}]}]).encode())
        raise AssertionError(req.full_url)
    return opener


def test_voicevox_engine_query_synthesis_and_credit():
    calls = []
    eng = VoicevoxEngine(SpeechConfig(voicevox_sampling_rate=16000), opener=voicevox_opener(calls))
    sp = eng.synthesize("手伝おうか？")
    assert sp.wav == WAV and sp.engine == "voicevox" and sp.credit == "VOICEVOX:ずんだもん"
    method, url, _ = calls[0]
    assert method == "POST" and "/audio_query?" in url and "speaker=3" in url and "%E6%89%8B" in url
    query = json.loads(calls[1][2])
    assert query["outputSamplingRate"] == 16000 and query["outputStereo"] is False
    eng.synthesize("もう一回")
    assert sum(u.endswith("/speakers") for _, u, _ in calls) == 1  # the credit is looked up once


def test_voicevox_engine_down():
    def opener(req, timeout=0):
        raise urllib.error.URLError("refused")

    with pytest.raises(SpeechError) as e:
        VoicevoxEngine(SpeechConfig(), opener=opener).synthesize("こんにちは")
    assert e.value.kind == "voicevox_unavailable"


class FakeSay:
    def __init__(self):
        self.texts = []

    async def synthesize(self, text):
        self.texts.append(text)
        return Speech(wav=WAV, engine="say", credit="")


async def test_speech_falls_back_and_checks_the_text():
    def down(req, timeout=0):
        raise urllib.error.URLError("refused")

    say = FakeSay()
    svc = SpeechService(SpeechConfig(max_chars=10), voicevox=VoicevoxEngine(SpeechConfig(), opener=down), say=say)
    sp = await svc.synthesize("  手伝おうか？\n ")
    assert sp.engine == "say" and say.texts == ["手伝おうか？"]
    for text in ("", "あ" * 11):
        with pytest.raises(SpeechError):
            await svc.synthesize(text)
    off = SpeechService(SpeechConfig(engines=("voicevox",)), voicevox=VoicevoxEngine(SpeechConfig(), opener=down))
    with pytest.raises(SpeechError, match="つながりません"):
        await off.synthesize("こんにちは")
    with pytest.raises(SpeechError) as e:
        await SpeechService(SpeechConfig(enabled=False)).synthesize("こんにちは")
    assert e.value.kind == "disabled"


@pytest.mark.skipif(sys.platform != "darwin" or shutil.which("say") is None, reason="macOS say only")
async def test_say_engine_makes_a_wav():
    sp = await SayEngine(SpeechConfig()).synthesize("-v テスト")  # an option-like text is only text
    assert sp.wav[:4] == b"RIFF" and sp.wav[8:12] == b"WAVE" and sp.engine == "say"


# ------------------------------------------------------------------ WebSocket
async def _recv_type(ws, t):
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 3))
        if m["type"] == t:
            return m


async def test_websocket_say_and_locate():
    jev = ScriptedJev([box_output(0.34, 0.57, 0.44, 0.61)])
    svc = HomeworkService(HomeworkConfig(enabled=True), client_factory=lambda: jev,
                          advice_factory=lambda: LocateAdapter(ANSWER),
                          speech=SpeechService(SpeechConfig(engines=("say",)), say=FakeSay()))
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=svc)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await _recv_type(ws, "hello")
            assert hello["data"]["homework_speech"] is True
            await ws.send(json.dumps({"type": "homework_say", "request_id": "v1", "data": {"text": "手伝おうか？"}}))
            sp = await _recv_type(ws, "homework_speech")
            assert sp["request_id"] == "v1" and base64.b64decode(sp["data"]["wav_base64"]) == WAV
            await ws.send(json.dumps({"type": "homework_say", "request_id": "v2", "data": {"text": ""}}))
            assert (await _recv_type(ws, "homework_speech_error"))["data"]["code"] == "invalid_request"
            await ws.send(json.dumps({"type": "homework_locate", "request_id": "L1", "data": {
                "session_id": "", "kind": "next", "image_jpeg_base64": NOW_B64}}))
            st = await _recv_type(ws, "homework_status")
            assert st["data"]["state"] == "locating"
            res = await _recv_type(ws, "homework_locate_result")
            assert res["request_id"] == "L1" and res["data"]["usable"]
    finally:
        await srv.stop()
        await svc.close()


async def test_websocket_without_speech():
    srv = GameServer(MockRobot(), "127.0.0.1", 0, state_hz=30, homework=HomeworkService(HomeworkConfig(enabled=True)))
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            assert (await _recv_type(ws, "hello"))["data"]["homework_speech"] is False
            await ws.send(json.dumps({"type": "homework_say", "request_id": "v", "data": {"text": "やあ"}}))
            assert "speech is off" in (await _recv_type(ws, "homework_error"))["data"]["message"]
    finally:
        await srv.stop()
