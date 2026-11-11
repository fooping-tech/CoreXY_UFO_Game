"""Speech for the homework helper (#79): text -> WAV, played by the game.

Engines are tried in the configured order (`homework.speech.engines`):
- "voicevox": a local VOICEVOX engine over HTTP (POST /audio_query, then /synthesis).
  The VOICEVOX terms ask for a credit such as "VOICEVOX:ずんだもん" wherever the voice
  is used: the credit comes back with the audio (from GET /speakers) and the game shows
  it. Each character has its own terms: check them before using a voice.
- "say": the macOS `say` command (a system voice such as Kyoko), as a fallback.
Standard library only. Nothing here touches the robot.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

ENGINES = ("voicevox", "say")


@dataclass(frozen=True)
class SpeechConfig:
    enabled: bool = True
    engines: tuple[str, ...] = ENGINES
    voicevox_url: str = "http://127.0.0.1:50021"
    voicevox_speaker: int = 3  # a style id (GET /speakers); 3 = ずんだもん ノーマル in VOICEVOX 0.x
    voicevox_sampling_rate: int = 24000
    say_voice: str = "Kyoko"
    timeout_s: float = 15.0
    max_chars: int = 120

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "SpeechConfig":
        hw = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        d = hw.get("speech") if isinstance(hw.get("speech"), dict) else {}
        engines = d.get("engines", list(ENGINES))
        if not isinstance(engines, list):
            engines = list(ENGINES)
        url = str(d.get("voicevox_url", cls.voicevox_url))
        if urllib.parse.urlparse(url).scheme not in ("http", "https"):
            raise ValueError(f"homework.speech.voicevox_url must be http(s): {url!r}")
        return cls(enabled=bool(d.get("enabled", True)),
                   engines=tuple(str(e) for e in engines if str(e) in ENGINES),
                   voicevox_url=url.rstrip("/"),
                   voicevox_speaker=int(d.get("voicevox_speaker", 3)),
                   voicevox_sampling_rate=min(max(int(d.get("voicevox_sampling_rate", 24000)), 8000), 48000),
                   say_voice=str(d.get("say_voice", "Kyoko")),
                   timeout_s=max(float(d.get("timeout_s", 15.0)), 1.0),
                   max_chars=min(max(int(d.get("max_chars", 120)), 1), 400))


class SpeechError(Exception):
    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


@dataclass
class Speech:
    wav: bytes
    engine: str
    credit: str  # "" when none is needed


def _is_wav(data: bytes) -> bool:
    return len(data) > 44 and data[:4] == b"RIFF" and data[8:12] == b"WAVE"


class VoicevoxEngine:
    """Blocking (call from a thread)."""

    def __init__(self, cfg: SpeechConfig, *, opener=None) -> None:
        self.cfg = cfg
        self._open = opener or urllib.request.urlopen
        self._credit: str | None = None

    def _call(self, path: str, query: dict[str, Any], body: bytes | None = None, method: str = "POST") -> bytes:
        url = f"{self.cfg.voicevox_url}{path}" + (f"?{urllib.parse.urlencode(query)}" if query else "")
        req = urllib.request.Request(url, data=body, method=method,
                                     headers={"Content-Type": "application/json"} if body is not None else {})
        try:
            with self._open(req, timeout=self.cfg.timeout_s) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            raise SpeechError("voicevox", f"VOICEVOX が HTTP {e.code} を返しました（{path}）") from e
        except (urllib.error.URLError, OSError) as e:
            raise SpeechError("voicevox_unavailable",
                              f"VOICEVOX のエンジンにつながりません（{self.cfg.voicevox_url}。起動しているか）") from e

    def credit(self) -> str:
        """"VOICEVOX:<character>" for the configured style (the terms ask for it)."""
        if self._credit is None:
            name = ""
            try:
                for sp in json.loads(self._call("/speakers", {}, method="GET")):
                    if any(int(st.get("id", -1)) == self.cfg.voicevox_speaker for st in sp.get("styles", [])):
                        name = str(sp.get("name", ""))
                        break
            except (SpeechError, ValueError, TypeError, AttributeError) as e:
                log.warning("VOICEVOX speakers: %s", e)
            self._credit = f"VOICEVOX:{name}" if name else "VOICEVOX"
        return self._credit

    def synthesize(self, text: str) -> Speech:
        speaker = {"speaker": self.cfg.voicevox_speaker}
        try:
            query = json.loads(self._call("/audio_query", {"text": text, **speaker}))
        except ValueError as e:
            raise SpeechError("voicevox", "VOICEVOX の audio_query が JSON ではありません") from e
        if isinstance(query, dict):
            query["outputSamplingRate"] = self.cfg.voicevox_sampling_rate
            query["outputStereo"] = False
        wav = self._call("/synthesis", speaker, json.dumps(query).encode())
        if not _is_wav(wav):
            raise SpeechError("voicevox", "VOICEVOX の音声が WAV ではありません")
        return Speech(wav=wav, engine="voicevox", credit=self.credit())


class SayEngine:
    """macOS `say` to a 16-bit WAV. The text goes through a file, never the argument list."""

    def __init__(self, cfg: SpeechConfig) -> None:
        self.cfg = cfg

    async def synthesize(self, text: str) -> Speech:
        say = shutil.which("say")
        if say is None:
            raise SpeechError("say_unavailable", "say コマンドがありません（macOS 以外）")
        with tempfile.TemporaryDirectory(prefix="corexy-ufo-say-") as d:
            src, out = Path(d) / "text.txt", Path(d) / "out.wav"
            src.write_text(text, encoding="utf-8")
            proc = await asyncio.create_subprocess_exec(
                say, "-v", self.cfg.say_voice, "--file-format=WAVE", "--data-format=LEI16@24000",
                "-o", str(out), "-f", str(src),
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
            try:
                _, err = await asyncio.wait_for(proc.communicate(), self.cfg.timeout_s)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                raise SpeechError("say", "say がタイムアウトしました") from None
            if proc.returncode != 0 or not out.exists():
                raise SpeechError("say", f"say が失敗しました: {err.decode(errors='replace')[:200]}")
            wav = out.read_bytes()
        if not _is_wav(wav):
            raise SpeechError("say", "say の出力が WAV ではありません")
        return Speech(wav=wav, engine="say", credit="")


class SpeechService:
    def __init__(self, cfg: SpeechConfig, *, voicevox: VoicevoxEngine | None = None,
                 say: SayEngine | None = None) -> None:
        self.cfg = cfg
        self.voicevox = voicevox or VoicevoxEngine(cfg)
        self.say = say or SayEngine(cfg)

    @property
    def available(self) -> bool:
        return self.cfg.enabled and bool(self.cfg.engines)

    async def synthesize(self, text: str) -> Speech:
        text = " ".join(str(text).split())
        if not text:
            raise SpeechError("invalid_request", "読み上げる文がありません")
        if len(text) > self.cfg.max_chars:
            raise SpeechError("invalid_request", f"読み上げる文が長すぎます（{self.cfg.max_chars} 文字まで）")
        if not self.available:
            raise SpeechError("disabled", "音声は無効です（config の homework.speech）")
        errors: list[str] = []
        for name in self.cfg.engines:
            try:
                if name == "voicevox":
                    return await asyncio.to_thread(self.voicevox.synthesize, text)
                return await self.say.synthesize(text)
            except SpeechError as e:
                errors.append(str(e))
        raise SpeechError("unavailable", "音声を作れませんでした: " + " / ".join(errors))
