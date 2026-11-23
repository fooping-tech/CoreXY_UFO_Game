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


async def test_a_short_quiet_word_in_a_long_silence_is_heard():
    """#246: 3 s held, 0.6 s of words at the MacBook's level from a little away, room noise around:
    the whole recording's mean (0.0028) was under the old 0.004; the loudest part is the voice."""
    from corexy_ufo_backend.homework.voice import loudness
    rng = np.random.default_rng(0)
    t = np.arange(int(RATE * 0.6)) / RATE
    words = (0.006 * np.sin(2 * np.pi * 220 * t) * (1 + 0.5 * np.sin(2 * np.pi * 3 * t))).astype(np.float32)
    audio = (rng.normal(0, 0.0012, RATE * 3)).astype(np.float32)
    audio[RATE: RATE + len(words)] += words
    loud, whole = loudness(audio)
    assert whole < 0.004 and loud > 0.004  # the old check would have dropped it
    w = FakeWhisper()
    v, _ = voice(FakeMic(audio), w)
    o = object()
    await v.start(o)
    assert (await v.stop(o))["text"] == "3ばんが わからない" and w.calls == 1
    # the room alone is still not a voice
    w = FakeWhisper()
    v, _ = voice(FakeMic((rng.normal(0, 0.0012, RATE * 3)).astype(np.float32)), w)
    o = object()
    await v.start(o)
    with pytest.raises(VoiceError) as e:
        await v.stop(o)
    assert e.value.kind == "not_heard" and w.calls == 0
    assert loudness(np.zeros(0, np.float32)) == (0.0, 0.0)


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
    order = []

    class Waiting(FakeMic):
        def start(self):
            gate.wait(2)
            threading.Event().wait(0.05)  # the microphone opens a moment after the permission
            order.append("opened")

        def stop(self):
            order.append("closed")
            return super().stop()
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
    await asyncio.sleep(0.2)
    assert mic.stopped == 1 and order == ["opened", "closed"]  # opened late, closed after it opened


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


class FakeTutor:
    def __init__(self, fail=None, sentences=("いっしょに かんがえよう。", "5こから2こ とると？")):
        self.fail, self.calls, self.sentences = fail, [], sentences

    def converse_stream(self, image, text, turns=(), target=None, grade=None, on_sentence=None, answers=()):
        self.calls.append({"text": text, "turns": turns, "target": target, "grade": grade, "answers": answers})
        if self.fail:
            raise self.fail
        for line in self.sentences:
            on_sentence(line)
        return {"message": "".join(self.sentences) + "のこりは？", "rest": ["のこりは？"], "spoken": list(self.sentences),
                "server_target": getattr(self, "server_target", None),
                "held_back": False, "action": "talk", "need_recapture": False, "visual_effect": "thinking", "notes": []}


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
    assert [m["type"] for m in sent] == ["homework_talk_delta", "homework_talk_delta", "homework_talk_result"]
    assert sent[0]["data"]["text"] == "いっしょに かんがえよう。" and d["rest"] == ["のこりは？"]
    assert ft.calls[0]["grade"] == 1 and ft.calls[0]["target"] == 3 and d["target_problem"] == 3  # said "3ばん"
    assert ft.calls[0]["answers"] and d["first_ms"] is not None
    sent.clear()
    await svc.talk("t1b", "もっと ヒント", B64, emit, target=2, history=[{"role": "user", "content": "x"}])
    await svc._talk_task
    assert ft.calls[-1]["target"] == 2 and ft.calls[-1]["turns"] == [{"role": "user", "content": "x"}]
    # nothing named or talked about: the problem the tutor found is kept (review on #235)
    ft.server_target = 4
    await svc.talk("t1c", "うえから 2つめの もんだい", B64, emit)
    await svc._talk_task
    assert ft.calls[-1]["target"] is None and sent[-1]["data"]["target_problem"] == 4
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
            first = await until(ws, "homework_talk_delta")
            r = await until(ws, "homework_talk_result")
            assert first["request_id"] == "t1" and r["request_id"] == "t1" and r["data"]["target_problem"] == 3
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


# ------------------------------------------------------------------ the streamed dialogue (API_SPEC §5.4)


def sse_body(deltas, result=None, error=None, done=True):
    out = []
    for d in deltas:
        out.append({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": d}}]})
    if error:
        out.append({"error": {"message": error, "type": "server_error"}})
    if result is not None:
        out.append({"choices": [], "tutor_result": result})
    lines = "".join(f"data: {json.dumps(e, ensure_ascii=False)}\n\n" for e in out)
    return (lines + ("data: [DONE]\n\n" if done else "")).encode()


def stream_tutor(monkeypatch, body):
    sent = []

    def fake_urlopen(req, timeout=None, context=None):
        sent.append(json.loads(req.data))
        if isinstance(body, int):
            raise urllib.error.HTTPError(req.full_url, body, "x", {}, io.BytesIO(b"{}"))
        return FakeResp(body)
    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    TutorStudyAdapter._breakers.clear()
    return TutorStudyAdapter("https://192.0.2.1:8444", "tok", grade=3), sent


def result(message, action="talk"):
    return {"dialog": {"message": message}, "game": {"action": action, "target_problem": 1, "message": message,
            "need_recapture": False, "visual_effect": "thinking"}, "notes": []}


def test_converse_stream_says_each_sentence_as_it_comes(monkeypatch):
    msg = "いっしょに 考えよう。「1と1は いくつかな？」 ゆびで かぞえてね"
    t, sent = stream_tutor(monkeypatch, sse_body(["いっしょに 考", "えよう。「1と1は", " いくつかな？」", " ゆびで かぞえてね"],
                                                 result(msg)))
    said = []
    turns = [{"role": "user", "content": "1ばん"}, {"role": "assistant", "content": "うん"}, {"role": "x", "content": ""}]
    r = t.converse_stream(JPEG, "もっと ヒント", turns=turns, target=1, grade=1, on_sentence=said.append)
    body = sent[0]
    assert body["stream"] is True and body["tutor"]["format"] == "dialog" and body["tutor"]["mode"] == "normal"
    assert body["tutor"]["target_problem"] == 1 and body["tutor"]["grade"] == 1
    assert [m["role"] for m in body["messages"]] == ["user", "user", "assistant", "user"]
    assert body["messages"][0]["content"][0]["type"] == "image_url" and body["messages"][-1]["content"] == "もっと ヒント"
    assert said == ["いっしょに 考えよう。", "「1と1は いくつかな？」"]  # the unfinished tail waits for the checked text
    assert r["rest"] == ["ゆびで かぞえてね"] and r["message"] == msg and r["server_target"] == 1


def test_a_sentence_giving_the_answer_away_is_held_back(monkeypatch):
    t, _ = stream_tutor(monkeypatch, sse_body(["がんばったね。", "こたえは 2だよ。", "またね。"],
                                              result("がんばったね。もういちど 考えてみよう。")))
    said = []
    r = t.converse_stream(JPEG, "こたえ おしえて", on_sentence=said.append, answers=["2"])
    assert said == ["がんばったね。"] and r["held_back"] and r["rest"] == ["もういちど 考えてみよう。"]


def test_when_the_checked_text_differs_what_was_said_is_not_repeated(monkeypatch):
    t, _ = stream_tutor(monkeypatch, sse_body(["そうだね。", "つぎへ いこう。"], result("ちがう ことば。")))
    said = []
    r = t.converse_stream(JPEG, "やあ", on_sentence=said.append)
    assert said == ["そうだね。", "つぎへ いこう。"] and r["rest"] == []
    t, _ = stream_tutor(monkeypatch, sse_body(["こたえは 5"], result("いっしょに 考えよう。")))
    r = t.converse_stream(JPEG, "やあ", on_sentence=said.append)
    assert r["rest"] == ["いっしょに 考えよう。"]  # nothing was said: all of the checked text


def test_a_stream_that_fails_or_ends_early_is_an_error(monkeypatch):
    for body, word in ((sse_body(["あ"], error="生成に失敗しました"), "途中"), (sse_body(["あ"], done=False), "途中"),
                       (401, "トークン")):
        t, _ = stream_tutor(monkeypatch, body)
        with pytest.raises(StudyAdapterError, match=word):
            t.converse_stream(JPEG, "やあ")


def test_the_problem_named_by_the_child():
    from corexy_ufo_backend.homework.service import number_in_utterance as n
    assert [n(x) for x in ["3ばんが わからない", "３番", "(2)", "③", "さんばん", "三番", "もんだい 4", "ヒント", "ごはん"]] == \
        [3, 3, 2, 3, 3, 3, 4, None, None]


def test_answers_given_away():
    from corexy_ufo_backend.study.tutor_adapter import gives_answer, split_sentences
    assert gives_answer("こたえは ５だよ") and gives_answer("38+47=85", ["85"]) and gives_answer("85に なるね", ["85"]) is False
    assert gives_answer("ぜんぶで 85 になるね", ["85"]) and not gives_answer("3ばんを みよう", ["3"])
    assert not gives_answer("5こから 2こ とると？", ["3"])
    assert split_sentences("あ。「い？」う\n\nえ") == ["あ。", "「い？」", "う", "え"]


async def test_the_tutor_is_kept_warm_while_a_study_session_runs(monkeypatch):
    import corexy_ufo_backend.homework.service as service_mod
    monkeypatch.setattr(asyncio, "sleep", _fast_sleep)
    ft = FakeTutor()
    v, _ = voice(warm_every_s=1.0)
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=v, talk_factory=lambda: ft,
                          client_factory=lambda: object(), sheet_factory=lambda: object())
    await svc.start("helper")  # no worksheet: not the study mode, nothing warmed
    assert svc._warm_task is None
    await svc.start("s", "mon-elem_1-01")
    for _ in range(20):
        await _real_sleep(0.01)
        if ft.calls:
            break
    assert ft.calls and ft.calls[0]["text"] == "こんにちは"  # the grey picture, never the child's sheet
    await svc.stop("s")
    await asyncio.wait_for(svc._warm_task, 1.0)  # ends with the study session
    off, _ = voice(warm_every_s=0.0)
    quiet = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=off, talk_factory=lambda: ft,
                            sheet_factory=lambda: object())
    await quiet.start("s", "mon-elem_1-01")
    assert quiet._warm_task is None
    await svc.close()
    await quiet.close()


_real_sleep = asyncio.sleep


async def _fast_sleep(secs, *a, **k):
    await _real_sleep(0.001)


async def test_on_a_real_print_the_tutor_is_told_its_own_answers_never_the_sample_sheets():
    """#287: with the local reader the sheet is a real print: the answers the tutor must not say are
    the ones read on it (correct_answer), not the sample sheet's (843, 8, 171cm for 小学3年)."""
    ft = FakeTutor()
    v, _ = voice()
    svc = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=v, talk_factory=lambda: ft,
                          client_factory=lambda: object(), sheet_factory=lambda: object())
    sample = [str(p["answer"]) for p in CAT.get("mon-elem_3-01")["problems"]]

    async def emit(m):
        pass
    await svc.start("s1", "mon-elem_3-01")
    await svc.talk("t1", "わからない", B64, emit, worksheet_id="mon-elem_3-01")
    await svc._talk_task
    assert ft.calls[-1]["answers"] == [] and ft.calls[-1]["grade"] == 3  # nothing read yet; the grade set stays
    svc.note_sheet([{"number": 1, "correct_answer": "2"}, {"number": 2, "correct_answer": "5"},
                    {"number": 3, "correct_answer": None}, {"number": 4, "correct_answer": " "}])
    await svc.talk("t2", "2ばんの ヒント", B64, emit, worksheet_id="mon-elem_3-01")
    await svc._talk_task
    assert ft.calls[-1]["answers"] == ["2", "5"] and not set(sample) & set(ft.calls[-1]["answers"])
    svc.note_sheet([])  # a reading that saw nothing keeps what was read
    assert svc.read_answers == ["2", "5"]
    # review on #288: a partial reading (a locate stopped at problem 1) keeps the others, merged by number
    svc.note_sheet([{"number": 1, "correct_answer": "2"}])
    svc.note_sheet([{"number": 3, "correct_answer": "85"}])
    assert svc.read_answers == ["2", "5", "85"]
    # a new study session: not the last print's
    await svc.stop("s1")
    await svc.start("s2", "mon-elem_3-01")
    assert svc.read_answers == []
    # the cloud (the sample sheet printed and used): its answers as before
    cloud = HomeworkService(HomeworkConfig(enabled=True), worksheets=CAT, voice=v, talk_factory=lambda: ft)
    await cloud.talk("t3", "わからない", B64, emit, worksheet_id="mon-elem_3-01")
    await cloud._talk_task
    assert ft.calls[-1]["answers"] == sample
    await svc.close()
    await cloud.close()
