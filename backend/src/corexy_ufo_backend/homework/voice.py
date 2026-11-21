"""The study mode's voice input (#233): push to talk, then Whisper on this Mac.

The game says when the child holds the talk key (or the microphone button) and when they let
go: `homework_listen_start` / `homework_listen_stop`. Meanwhile this records the default
microphone (sounddevice, 16 kHz mono), never longer than `max_s`, and then turns it into text
with mlx-whisper (Apple Silicon; the model is downloaded once, then loaded at start when
`preload`). The sound is kept in memory only, never written to a file, never sent anywhere; the
text goes back to the game only. A recording too short or too quiet is "not heard" (Whisper
makes up words on silence), and so is a text Whisper is known to make up.

Nothing here touches the robot.
"""

from __future__ import annotations

import asyncio
import logging
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol

import numpy as np

log = logging.getLogger(__name__)

RATE = 16000
# opening the microphone may wait for macOS's permission dialog: never longer than this, and never
# on the backend's event loop (the robot's commands go through it)
OPEN_TIMEOUT_S = 5.0
# what Whisper says on silence or noise (Japanese video endings): never a child's question
MADE_UP = ("ご視聴ありがとうございました", "ご視聴ありがとうございます", "チャンネル登録", "最後までご視聴",
           "字幕", "次回もお楽しみに")


class VoiceError(Exception):
    """kind: off / busy / not_listening / not_heard / mic / stt"""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


@dataclass(frozen=True)
class VoiceConfig:
    enabled: bool = True
    model: str = "mlx-community/whisper-large-v3-turbo"
    language: str = "ja"
    max_s: float = 20.0
    min_s: float = 0.4
    min_rms: float = 0.004  # quieter than this is no voice (a float32 signal, full scale 1.0)
    device: str = ""  # "" = the default input; else part of the device's name
    preload: bool = True
    # the tutor's model is unloaded when idle (the first answer then takes ~10 s): a tiny turn keeps
    # it loaded while a study session runs, at the session's start and after this long without one
    warm_every_s: float = 240.0

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "VoiceConfig":
        sm = raw.get("study_mode") if isinstance(raw.get("study_mode"), dict) else {}
        d = sm.get("voice") if isinstance(sm.get("voice"), dict) else {}
        return cls(enabled=bool(d.get("enabled", True)), model=str(d.get("model", cls.model)),
                   language=str(d.get("language", "ja")), max_s=min(max(float(d.get("max_s", 20.0)), 1.0), 60.0),
                   min_s=max(float(d.get("min_s", 0.4)), 0.0), min_rms=max(float(d.get("min_rms", 0.004)), 0.0),
                   device=str(d.get("device", "")), preload=bool(d.get("preload", True)),
                   warm_every_s=max(float(d.get("warm_every_s", 240.0)), 0.0))


class Recorder(Protocol):
    def start(self) -> None: ...
    def stop(self) -> np.ndarray: ...  # float32 mono at RATE


class Transcriber(Protocol):
    def load(self) -> None: ...
    def transcribe(self, audio: np.ndarray) -> str: ...


class MicRecorder:
    """The microphone through sounddevice (PortAudio), into memory, at most max_s."""

    def __init__(self, max_s: float, device: str = "") -> None:
        self.max_samples = int(max_s * RATE)
        self.device = device
        self._chunks: list[np.ndarray] = []
        self._count = 0
        self._stream = None
        self._lock = threading.Lock()

    def _device(self):
        if not self.device:
            return None
        import sounddevice as sd
        for i, d in enumerate(sd.query_devices()):
            if d.get("max_input_channels", 0) > 0 and self.device.lower() in str(d.get("name", "")).lower():
                return i
        raise VoiceError("mic", f"マイク「{self.device}」が見つかりません（study_mode.voice.device）")

    def start(self) -> None:
        try:
            import sounddevice as sd
        except (ImportError, OSError) as e:
            raise VoiceError("mic", f"マイクを使えません（sounddevice）: {e}") from e

        def callback(indata, frames, _time, _status) -> None:
            with self._lock:
                room = self.max_samples - self._count
                if room > 0:
                    chunk = indata[:room, 0].copy()
                    self._chunks.append(chunk)
                    self._count += len(chunk)
        self._chunks, self._count = [], 0
        try:
            self._stream = sd.InputStream(samplerate=RATE, channels=1, dtype="float32", device=self._device(),
                                          callback=callback)
            self._stream.start()
        except VoiceError:
            raise
        except Exception as e:  # PortAudio: no microphone, no permission
            self._stream = None
            raise VoiceError("mic", f"マイクを開けません（マイクの許可・つないだマイク）: {e}") from e

    def stop(self) -> np.ndarray:
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:  # pragma: no cover - the sound so far is still good
                log.exception("voice: closing the microphone")
        with self._lock:
            audio = np.concatenate(self._chunks) if self._chunks else np.zeros(0, np.float32)
            self._chunks, self._count = [], 0
        return audio


class WhisperTranscriber:
    """mlx-whisper (Apple Silicon). The model is fetched from Hugging Face the first time."""

    def __init__(self, model: str, language: str) -> None:
        self.model, self.language = model, language
        self.loaded = False

    def load(self) -> None:
        import mlx_whisper
        # one tiny pass loads (and the first time downloads) the model; mlx_whisper keeps it
        mlx_whisper.transcribe(np.zeros(RATE // 2, np.float32), path_or_hf_repo=self.model, language=self.language)
        self.loaded = True

    def transcribe(self, audio: np.ndarray) -> str:
        import mlx_whisper
        r = mlx_whisper.transcribe(audio, path_or_hf_repo=self.model, language=self.language, temperature=0.0,
                                   condition_on_previous_text=False)
        self.loaded = True
        segs = [s for s in r.get("segments", []) if float(s.get("no_speech_prob", 0.0)) < 0.6]
        return "".join(str(s.get("text", "")) for s in segs).strip() if r.get("segments") else str(r.get("text", "")).strip()


def _close_late(rec: Recorder) -> None:
    """A microphone that opened after its time was up is closed again."""
    try:
        rec.stop()
    except Exception:  # pragma: no cover
        log.exception("voice: closing a late microphone")


def stt_available() -> str:
    """"" when mlx-whisper and the microphone library are there, else why not."""
    try:
        import mlx_whisper  # noqa: F401
    except Exception as e:  # ImportError, or mlx on a machine without Metal
        return f"mlx-whisper を使えません（Apple Silicon の Mac だけ）: {type(e).__name__}"
    try:
        import sounddevice  # noqa: F401
    except Exception as e:
        return f"マイクのライブラリ（sounddevice）を使えません: {type(e).__name__}"
    return ""


def clean_text(text: str) -> str:
    t = re.sub(r"\s+", " ", text).strip()
    if not t or (any(m in t for m in MADE_UP) and len(t) <= 30):
        return ""
    return t


class VoiceService:
    """One recording at a time; whoever started it stops it (or it is dropped)."""

    def __init__(self, config: VoiceConfig, recorder: Callable[[], Recorder] | None = None,
                 transcriber: Transcriber | None = None) -> None:
        self.config = config
        self._recorder_factory = recorder or (lambda: MicRecorder(config.max_s, config.device))
        self.transcriber = transcriber or WhisperTranscriber(config.model, config.language)
        self._recorder: Recorder | None = None
        self._owner: object | None = None
        self._started = 0.0
        self._busy = False  # transcribing
        self._opening = False  # the microphone is being opened
        self.problem = "" if transcriber is not None or recorder is not None else stt_available()
        self.load_error = ""

    @property
    def available(self) -> bool:
        return self.config.enabled and self.problem == ""

    def why_not(self) -> str:
        if not self.config.enabled:
            return "声の入力は無効です（study_mode.voice.enabled）"
        return self.problem

    async def preload(self) -> None:
        """Load (the first time: download) the model before the first question."""
        if not self.available or not self.config.preload:
            return
        t0 = time.monotonic()
        try:
            await asyncio.to_thread(self.transcriber.load)
            log.info("voice: Whisper %s ready (%.1f s)", self.config.model, time.monotonic() - t0)
        except Exception as e:  # the first question tries again
            self.load_error = str(e)[:200]
            log.warning("voice: Whisper could not be loaded yet: %s", e)

    @property
    def listening(self) -> bool:
        return self._recorder is not None

    async def start(self, owner: object) -> dict[str, Any]:
        if not self.available:
            raise VoiceError("off", self.why_not())
        if self._recorder is not None or self._busy or self._opening:
            raise VoiceError("busy", "いまは聞けません（前の声を聞いているところ）")
        rec = self._recorder_factory()
        self._opening = True
        try:  # VoiceError("mic") when the microphone cannot be opened
            await asyncio.wait_for(asyncio.to_thread(rec.start), OPEN_TIMEOUT_S)
        except asyncio.TimeoutError:
            # the thread may still be waiting for the permission; whatever it opens is closed
            asyncio.get_running_loop().run_in_executor(None, _close_late, rec)
            raise VoiceError("mic", "マイクを開けません（macOS の「設定 → プライバシーとセキュリティ → マイク」で、"
                                    "./start.sh を動かしているターミナルを許可する）") from None
        finally:
            self._opening = False
        self._recorder, self._owner, self._started = rec, owner, time.monotonic()
        return {"state": "listening", "max_s": self.config.max_s}

    def cancel(self, owner: object | None = None) -> bool:
        """Drop the recording (the client went away, or the game took it back). The microphone is
        closed on a worker thread (never on the event loop)."""
        if self._recorder is None or (owner is not None and owner is not self._owner):
            return False
        rec, self._recorder, self._owner = self._recorder, None, None
        try:
            asyncio.get_running_loop().run_in_executor(None, rec.stop)
        except RuntimeError:  # no loop (closing down): close it here
            rec.stop()
        return True

    async def stop(self, owner: object) -> dict[str, Any]:
        """Stop recording and turn it into text: {text, seconds, stt_ms}. VoiceError("not_heard")
        when there was no voice in it."""
        if self._recorder is None or owner is not self._owner:
            raise VoiceError("not_listening", "聞いていません")
        rec, self._recorder, self._owner = self._recorder, None, None
        audio = await asyncio.to_thread(rec.stop)
        secs = len(audio) / RATE
        rms = float(np.sqrt(np.mean(np.square(audio)))) if len(audio) else 0.0
        if secs < self.config.min_s or rms < self.config.min_rms:
            raise VoiceError("not_heard", "声が聞こえませんでした（短い・小さい）")
        self._busy = True
        t0 = time.monotonic()
        try:
            text = await asyncio.to_thread(self.transcriber.transcribe, audio)
        except Exception as e:
            raise VoiceError("stt", f"声を文字にできませんでした: {e}") from e
        finally:
            self._busy = False
        text = clean_text(text)
        if not text:
            raise VoiceError("not_heard", "ことばが聞き取れませんでした")
        log.info("voice: heard %.1f s -> %d characters (%d ms)", secs, len(text), (time.monotonic() - t0) * 1000)
        return {"text": text, "seconds": round(secs, 1), "stt_ms": round((time.monotonic() - t0) * 1000)}
