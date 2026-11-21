"""#233: the voice dialogue: push to talk (a fake microphone and Whisper) and one turn with the
tutor (a fake server). No microphone, no model, no network."""

from __future__ import annotations

import asyncio
import base64
import io
import json
import urllib.error

import cv2
import numpy as np
import pytest
import websockets

from corexy_ufo_backend.homework import HomeworkConfig, HomeworkService
from corexy_ufo_backend.homework.voice import RATE, VoiceConfig, VoiceError, VoiceService, clean_text
from corexy_ufo_backend.study.errors import StudyAdapterError
from corexy_ufo_backend.study.tutor_adapter import TutorStudyAdapter
from corexy_ufo_backend.study_mode import WorksheetCatalog

CAT = WorksheetCatalog.load()
JPEG = cv2.imencode(".jpg", np.full((240, 320, 3), 200, np.uint8))[1].tobytes()
B64 = base64.b64encode(JPEG).decode()
VOICE = 0.1 * np.sin(np.linspace(0, 2000, RATE)).astype(np.float32)  # 1 s, loud enough


class FakeMic:
    def __init__(self, audio=VOICE, fail=None):
        self.audio, self.fail, self.started, self.stopped = audio, fail, 0, 0

    def start(self):
        if self.fail:
            raise VoiceError("mic", self.fail)
        self.started += 1

    def stop(self):
        self.stopped += 1
        return self.audio


class FakeWhisper:
    def __init__(self, text="3ばんが わからない"):
        self.text, self.calls, self.loaded = text, 0, 0

    def load(self):
        self.loaded += 1

    def transcribe(self, audio):
        self.calls += 1
        return self.text


def voice(mic=None, whisper=None, **cfg):
    mic = mic or FakeMic()
    return VoiceService(VoiceConfig(**cfg), recorder=lambda: mic, transcriber=whisper or FakeWhisper()), mic


# ------------------------------------------------------------------ push to talk


async def test_held_then_let_go_gives_the_text():
    v, mic = voice()
    owner = object()
    assert v.available and (await v.start(owner))["state"] == "listening" and v.listening
    with pytest.raises(VoiceError) as e:
        await v.start(object())  # one recording at a time
    assert e.value.kind == "busy"
    with pytest.raises(VoiceError):
        await v.stop(object())  # only who started it stops it
    heard = await v.stop(owner)
    assert heard["text"] == "3ばんが わからない" and heard["seconds"] == 1.0 and not v.listening and mic.stopped == 1


async def test_too_short_or_too_quiet_is_not_heard_and_never_transcribed():
    for audio in (VOICE[: RATE // 10], VOICE * 0.001):
        w = FakeWhisper()
        v, _ = voice(FakeMic(audio), w)
        o = object()
        await v.start(o)
        with pytest.raises(VoiceError) as e:
            await v.stop(o)
        assert e.value.kind == "not_heard" and w.calls == 0


async def test_whispers_made_up_words_are_not_heard():
    assert clean_text("ご視聴ありがとうございました") == "" and clean_text("  ") == ""
    assert clean_text("ありがとう UFOくん") == "ありがとう UFOくん"
    v, _ = voice(whisper=FakeWhisper("ご視聴ありがとうございました。"))
    o = object()
    await v.start(o)
    with pytest.raises(VoiceError) as e:
        await v.stop(o)
    assert e.value.kind == "not_heard"


async def test_off_or_no_microphone_says_why():
    v, _ = voice(enabled=False)
    with pytest.raises(VoiceError) as e:
        await v.start(object())
    assert e.value.kind == "off" and "enabled" in str(e.value)
    v, _ = voice(FakeMic(fail="マイクを開けません"))
    with pytest.raises(VoiceError) as e:
        await v.start(object())
    assert e.value.kind == "mic" and not v.listening


async def test_a_dropped_recording_is_never_transcribed():
    w = FakeWhisper()
    v, mic = voice(whisper=w)
    o = object()
    await v.start(o)
    assert not v.cancel(object()) and v.cancel(o) and not v.listening and w.calls == 0
    await asyncio.sleep(0.05)
    assert mic.stopped == 1


async def test_a_microphone_waiting_for_permission_never_blocks_the_backend(monkeypatch):
    """The permission dialog: opening waits; the event loop (the robot's commands) does not."""
    import threading
    import corexy_ufo_backend.homework.voice as voice_mod
    monkeypatch.setattr(voice_mod, "OPEN_TIMEOUT_S", 0.2)
    gate = threading.Event()

    class Waiting(FakeMic):
        def start(self):
            gate.wait(2)
    mic = Waiting()
    v, _ = voice(mic)
    ticks = 0

    async def heartbeat():
        nonlocal ticks
        for _ in range(10):
            ticks += 1
            await asyncio.sleep(0.01)
    beat = asyncio.create_task(heartbeat())
    with pytest.raises(VoiceError) as e:
        await v.start(object())
    gate.set()
    await beat
    assert e.value.kind == "mic" and "マイク" in str(e.value) and ticks == 10 and not v.listening
    await asyncio.sleep(0.05)
    assert mic.stopped == 1  # opened late, closed again


async def test_preload_loads_the_model_once_and_survives_a_failure():
    w = FakeWhisper()
    v, _ = voice(whisper=w)
    await v.preload()
    assert w.loaded == 1

    class Broken(FakeWhisper):
        def load(self):
            raise RuntimeError("no network")
    v, _ = voice(whisper=Broken())
    await v.preload()
    assert v.load_error == "no network" and v.available


def test_the_settings():
    c = VoiceConfig.from_raw({"study_mode": {"voice": {"max_s": 999, "model": "m", "enabled": False}}})
    assert c.max_s == 60.0 and c.model == "m" and not c.enabled
    assert VoiceConfig.from_raw({}).model == "mlx-community/whisper-large-v3-turbo"


# ------------------------------------------------------------------ one turn with the tutor


class FakeResp(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


GAME = {"action": "give_hint", "target_problem": 3, "hint_level": 1, "message": "5こから2こ とると いくつかな？",
        "need_recapture": False, "visual_effect": "thinking", "visible_problems": [1, 2, 3]}


def tutor(monkeypatch, answers):
    sent = []

    def fake_urlopen(req, timeout=None, context=None):
        sent.append(json.loads(req.data))
        a = answers.pop(0)
        if isinstance(a, int):
            raise urllib.error.HTTPError(req.full_url, a, "x", {}, io.BytesIO(b'{"error": {"message": "no"}}'))
        return FakeResp(json.dumps(a).encode())
    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    TutorStudyAdapter._breakers.clear()
    return TutorStudyAdapter("https://192.0.2.1:8444", "tok", grade=3), sent


def test_converse_sends_the_turns_in_the_servers_shape(monkeypatch):
    t, sent = tutor(monkeypatch, [{"tutor_result": {"game": GAME, "corexy": {"ufo_face": "normal"}}}])
    history = [{"hint_level": 9, "message": "まえの ヒント"}, {"message": ""}, "bad"]
    r = t.converse(JPEG, "  もっと ヒント  ", history=history, target=3, grade=8)
    ext = sent[0]["tutor"]
    assert ext == {"target_problem": 3, "grade": 6, "mode": "normal", "utterance": "もっと ヒント",
                   "history": [{"hint_level": 5, "message": "まえの ヒント"}]}
    assert sent[0]["messages"][0]["content"][0]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert r["message"].startswith("5こから") and r["action"] == "give_hint" and r["target_problem"] == 3
    assert r["hint_level"] == 1 and r["ufo_face"] == "normal" and r["visible_problems"] == [1, 2, 3]


def test_converse_without_words_or_on_401_is_an_error(monkeypatch):
    t, _ = tutor(monkeypatch, [{"tutor_result": {"game": {**GAME, "message": ""}}}, 401])
    with pytest.raises(StudyAdapterError, match="ことば"):
        t.converse(JPEG, "やあ")
    with pytest.raises(StudyAdapterError, match="トークン"):
        t.converse(JPEG, "やあ")


class FakeTutor:
    def __init__(self, fail=None):
        self.fail, self.calls = fail, []

    def converse(self, image, text, history=(), target=None, grade=None):
        self.calls.append({"text": text, "history": history, "target": target, "grade": grade})
        if self.fail:
            raise self.fail
        return {**GAME, "ufo_face": "normal", "answer_status": "", "target_problem": 3}


async def test_the_service_talks_once_at_a_time_and_says_errors():
    ft = FakeTutor()
    v, _ = voice()
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=v, talk_factory=lambda: ft)
    sent = []

    async def emit(m):
        sent.append(m)
    assert svc.voice_available and svc.voice_problem() == ""
    await svc.talk("t1", "3ばんが わからない", B64, emit, target=None, history=[], worksheet_id="mon-elem_1-01")
    with pytest.raises(ValueError):
        await svc.talk("t2", "もういちど", B64, emit)
    await svc._talk_task
    d = sent[-1]["data"]
    assert sent[-1]["type"] == "homework_talk_result" and d["speech_lines"] and ft.calls[0]["grade"] == 1
    with pytest.raises(ValueError):
        await svc.talk("t3", "   ", B64, emit)
    svc._talk_factory = lambda: FakeTutor(StudyAdapterError("学習支援 AI に接続できません"))
    await svc.talk("t4", "やあ", B64, emit)
    await svc._talk_task
    assert sent[-1]["type"] == "homework_talk_error" and "接続" in sent[-1]["data"]["message"]
    no_talk = HomeworkService(HomeworkConfig(enabled=True), voice=v)
    assert not no_talk.voice_available and "学習支援 AI" in no_talk.voice_problem()
    await svc.close()


async def test_over_the_websocket_and_a_disconnect_drops_the_recording():
    from corexy_ufo_backend.robot.mock_robot import MockRobot
    from corexy_ufo_backend.websocket import GameServer
    w = FakeWhisper()
    v, mic = voice(whisper=w)
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=v, talk_factory=lambda: FakeTutor())
    robot = MockRobot()
    await robot.connect()
    srv = GameServer(robot, "127.0.0.1", 0, state_hz=30, homework=svc)
    await srv.start()
    port = next(iter(srv._server.sockets)).getsockname()[1]

    async def until(ws, kind):
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 5))
            if m["type"] == kind or m["type"].endswith("error"):
                return m
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            hello = await until(ws, "hello")
            assert hello["data"]["study_voice"] is True
            await ws.send(json.dumps({"type": "homework_listen_start", "request_id": "l1", "data": {}}))
            assert (await until(ws, "homework_listen"))["data"]["state"] == "listening"
            await ws.send(json.dumps({"type": "homework_listen_stop", "request_id": "l2", "data": {}}))
            heard = await until(ws, "homework_heard")
            assert heard["request_id"] == "l2" and heard["data"]["text"] == "3ばんが わからない"
            await ws.send(json.dumps({"type": "homework_talk", "request_id": "t1", "data": {
                "text": heard["data"]["text"], "image_jpeg_base64": B64, "target_problem": 3,
                "history": [{"hint_level": 1, "message": "x"}], "worksheet_id": "mon-elem_1-01"}}))
            r = await until(ws, "homework_talk_result")
            assert r["request_id"] == "t1" and r["data"]["target_problem"] == 3
            await ws.send(json.dumps({"type": "homework_listen_start", "request_id": "l3", "data": {}}))
            await until(ws, "homework_listen")
        for _ in range(50):  # the client went away while holding the key
            if not v.listening:
                break
            await asyncio.sleep(0.02)
        assert not v.listening and w.calls == 1
    finally:
        await srv.stop()
        await svc.close()
