"""Homework watch sessions: frames from the game -> Jev -> progress messages.

The game captures the overview camera every `interval_s` while a session runs and
sends the JPEG (`homework_frame`); this service runs one Jev call at a time per
session (a frame arriving while one runs is skipped, as in the jev repo) and
answers with `homework_progress` / `homework_error`. Nothing here touches the
robot. Frames are never written to disk; a session keeps in memory only the frame
at the last progress gain (the first readable one until then), to compare with the
frame now when locating the problem the child is stuck on (#79).

Stage 3 (#79): `locate` (which problem, where its answer box is: locate.py) and
`say` (text -> WAV: speech.py) for the game's "手伝おうか？" helper.

Study mode (#86): a session may name a sample worksheet (`worksheet_id`): every frame's
Jev call then also asks, per problem, whether its answer box holds a handwritten answer
(questions.py) and the progress carries `questions`. `locate` kind "problem" finds a
given problem of that worksheet (also checked against the page layout from its corner
marks), and `explain` sends the overview and the arm camera's close-ups to the study
assistant in one question for a structured explanation (study_mode/explain.py).
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import logging
import tempfile
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from .jev import JevClient, JevError, JevResult, load_credentials
from .locate import (LOCATE_SYSTEM_PROMPT, LocateError, LocateParams, agrees, centre, jev_box, jev_box_input,
                     jpeg_size, locate_prompt, parse_answer)
from .progress import STALL_MIN_GAIN, STALL_S, ProgressTracker, build_input, parse
from .questions import add_questions, parse_questions
from .speech import SpeechError, SpeechService
from ..study_mode.explain import (EXPLAIN_SYSTEM_PROMPT, ExplainError, compare_with_known, explain_prompt,
                                  fallback_explanation, parse_explanation, split_speech)
from ..study_mode.worksheets import (MARKS, WorksheetCatalog, WorksheetError, box_in_image, paper_to_image,
                                     point_inside)

log = logging.getLogger(__name__)

Emit = Callable[[dict[str, Any]], Awaitable[None]]
# 4xx answers in a row (other than 429) before a session stops by itself
FATAL_LIMIT = 3

ADVICE_SYSTEM_PROMPT = (
    "あなたは小学生の宿題を見守る、やさしい家庭教師です。答えそのものは言わず、"
    "考え方のヒントを、小学生にわかる短い日本語で伝えてください。画像から読み取れないことは推測と明記してください。")


def advice_prompt(context: dict[str, Any]) -> str:
    parts = ["宿題プリントの画像です。"]
    if context.get("composite"):
        parts.append("左は机の上から撮った全体、右はアームのカメラで近づいて撮った拡大です。")
    if context.get("elapsed_s") is not None:
        parts.append(f"始めてから約{int(context['elapsed_s'] // 60)}分")
        if context.get("progress_pct") is not None:
            parts.append(f"、進み具合は約{int(context['progress_pct'])}%")
        if context.get("stalled_for_s"):
            parts.append(f"で、ここ{max(int(context['stalled_for_s'] // 60), 1)}分ほど進んでいません")
        parts.append("。")
    parts.append(
        "\n1. 手が止まっていそうな問題を特定してください（途中まで書いてある問題。なければ最初の空欄の問題）。"
        "\n2. その問題の内容を読み取ってください。"
        "\n3. 答えは言わずに、考え方のヒントを2〜3文で伝えてください。"
        "\n最後の行に「止まっている問題: （番号や位置）」と書いてください。")
    return "".join(parts)


class JevRunner(Protocol):
    def run(self, jev_input: dict, timeout: float = 30.0) -> JevResult: ...


@dataclass(frozen=True)
class HomeworkConfig:
    enabled: bool = False
    interval_s: float = 10.0
    timeout_s: float = 30.0
    max_image_edge: int = 1024  # the jev repo measured tokens at 1024 px (about 8.8k per call)
    max_image_bytes: int = 700_000
    camera_role: str = "overview"
    stall_s: float = STALL_S
    stall_min_gain: float = STALL_MIN_GAIN
    advice_timeout_s: float = 120.0
    explain_timeout_s: float = 150.0
    env_path: Path | None = None

    @classmethod
    def from_raw(cls, raw: dict[str, Any], env_path: Path | None = None) -> "HomeworkConfig":
        d = raw.get("homework") if isinstance(raw.get("homework"), dict) else {}
        return cls(enabled=bool(d.get("enabled", False)),
                   interval_s=max(float(d.get("interval_s", 10.0)), 2.0),
                   timeout_s=max(float(d.get("timeout_s", 30.0)), 1.0),
                   max_image_edge=max(int(d.get("max_image_edge", 1024)), 64),
                   max_image_bytes=max(int(d.get("max_image_bytes", 700_000)), 1024),
                   camera_role=str(d.get("camera_role", "overview")),
                   stall_s=max(float(d.get("stall_s", STALL_S)), 10.0),
                   stall_min_gain=max(float(d.get("stall_min_gain", STALL_MIN_GAIN)), 0.0),
                   advice_timeout_s=max(float(d.get("advice_timeout_s", 120.0)), 5.0),
                   explain_timeout_s=max(float(d.get("explain_timeout_s", 150.0)), 5.0),
                   env_path=env_path)


@dataclass
class _Session:
    client: JevRunner
    tracker: ProgressTracker
    started: float = field(default_factory=time.monotonic)
    task: asyncio.Task | None = None
    count: int = 0
    skipped: int = 0
    errors: int = 0
    fatal_in_row: int = 0
    input_tokens: int = 0
    cost_usd: float = 0.0
    stopped: str = ""  # why it stopped by itself
    # the frame at the last progress gain (the first readable one until then), in memory only
    before_frame: bytes | None = None
    # the study mode's sample worksheet (#86): per-problem questions in every Jev call
    worksheet: dict | None = None

    def elapsed(self) -> float:
        return time.monotonic() - self.started

    def summary(self) -> dict[str, Any]:
        t = self.elapsed()
        return {"elapsed_s": round(t, 1), "count": self.count, "skipped": self.skipped,
                "errors": self.errors, "input_tokens": self.input_tokens,
                "cost_usd": round(self.cost_usd, 6), "smoothed_pct": self.tracker.smoothed_pct,
                "stalled": self.tracker.stalled(t), "stalled_for_s": round(self.tracker.stalled_for(t), 1)}


def decode_jpeg(value: str, limit: int) -> bytes:
    if len(value) > (limit * 4 // 3) + 16:
        raise ValueError("image is too large")
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError("invalid base64 image") from exc
    if len(raw) > limit:
        raise ValueError("image is too large")
    if len(raw) < 4 or raw[:2] != b"\xff\xd8" or raw[-2:] != b"\xff\xd9":
        raise ValueError("image is not a JPEG")
    return raw


class HomeworkService:
    def __init__(self, config: HomeworkConfig,
                 client_factory: Callable[[], JevRunner] | None = None,
                 advice_factory: Callable[[], Any] | None = None,
                 explain_factory: Callable[[], Any] | None = None,
                 locate: LocateParams | None = None, speech: SpeechService | None = None,
                 worksheets: WorksheetCatalog | None = None) -> None:
        self.config = config
        self.worksheets = worksheets
        self._explain_task: asyncio.Task | None = None
        self.locate_params = locate or LocateParams()
        self.speech = speech
        self._locate_task: asyncio.Task | None = None
        self._speech_tasks: set[asyncio.Task] = set()
        # credentials are read when a session starts, so a fixed .env needs no restart
        self._client_factory = client_factory or (lambda: JevClient(load_credentials(config.env_path)))
        # a study adapter (Claude Code / Codex, study.provider): start_session / ask / close_session / close
        self._advice_factory = advice_factory
        # the study mode's explanation (#104): study.explain_provider (e.g. the tutor AI), else the advice's
        self._explain_factory = explain_factory or advice_factory
        self._advice_task: asyncio.Task | None = None
        self.sessions: dict[str, _Session] = {}

    def worksheet(self, worksheet_id: str) -> dict:
        if not worksheet_id:
            raise ValueError("worksheet_id is required")
        if self.worksheets is None:
            raise ValueError("no worksheets loaded (config/worksheets.json)")
        try:
            return self.worksheets.get(worksheet_id)
        except WorksheetError as e:
            raise ValueError(str(e)) from e

    async def start(self, session_id: str, worksheet_id: str = "") -> dict[str, Any]:
        if not session_id or len(session_id) > 128:
            raise ValueError("invalid session_id")
        ws = self.worksheet(worksheet_id) if worksheet_id else None
        if session_id not in self.sessions:
            self.sessions[session_id] = _Session(  # JevError("config") if no key
                client=self._client_factory(),
                tracker=ProgressTracker(stall_s=self.config.stall_s, stall_min_gain=self.config.stall_min_gain))
            log.info("homework session %s started", session_id)
        s = self.sessions[session_id]
        if ws is not None:
            s.worksheet = ws
        return {"session_id": session_id, "state": "running", "interval_s": self.config.interval_s,
                "camera_role": self.config.camera_role, "elapsed_s": round(s.elapsed(), 1),
                "worksheet_id": s.worksheet["worksheet_id"] if s.worksheet else ""}

    async def frame(self, session_id: str, request_id: str, image_b64: str, emit: Emit) -> bool:
        """Start a Jev call for this frame; False when one is still running (skipped)."""
        s = self.sessions.get(session_id)
        if s is None:
            raise ValueError("unknown homework session")
        if s.task is not None and not s.task.done():
            s.skipped += 1
            return False
        image = decode_jpeg(image_b64, self.config.max_image_bytes)
        jev_input = build_input(base64.b64encode(image).decode("ascii"))
        if s.worksheet is not None:
            jev_input = add_questions(jev_input, s.worksheet)
        s.task = asyncio.create_task(self._run(session_id, s, request_id, jev_input, emit, image))
        return True

    async def _run(self, session_id: str, s: _Session, request_id: str, jev_input: dict, emit: Emit,
                   image: bytes = b"") -> None:
        try:
            res = await asyncio.wait_for(asyncio.to_thread(s.client.run, jev_input, self.config.timeout_s),
                                         self.config.timeout_s + 5.0)
        except asyncio.CancelledError:
            raise
        except (JevError, asyncio.TimeoutError) as e:
            err = e if isinstance(e, JevError) else JevError("timeout", "Jev の応答がタイムアウトしました")
            s.errors += 1
            s.fatal_in_row = s.fatal_in_row + 1 if err.fatal else 0
            data: dict[str, Any] = {"code": err.kind, "message": err.describe(), "status": err.status,
                                    **s.summary()}
            if s.fatal_in_row >= FATAL_LIMIT:
                s.stopped = f"{FATAL_LIMIT} errors in a row"
                data["stopped"] = True
                self.sessions.pop(session_id, None)
                log.warning("homework session %s stopped: %s", session_id, err.describe())
            await emit({"type": "homework_error", "request_id": request_id, "data": data})
            return
        s.fatal_in_row = 0
        s.count += 1
        s.input_tokens += int(res.usage.get("input_tokens") or 0)
        s.cost_usd += res.cost_usd or 0.0
        reading = parse(res.output)
        gains = s.tracker.gains
        smoothed = s.tracker.add(s.elapsed(), reading)
        if image and (s.tracker.gains != gains or (s.before_frame is None and not reading.held)):
            s.before_frame = image
        data = {"progress_pct": reading.progress_pct, "smoothed_pct": smoothed, "held": reading.held,
                "held_reason": reading.held_reason, "visible_prob": reading.visible_prob,
                "occluded_prob": reading.occluded_prob, "top_level_prob": reading.top_level_prob,
                "latency_ms": round(res.latency_s * 1000), **s.summary()}
        if s.worksheet is not None:
            data["worksheet_id"] = s.worksheet["worksheet_id"]
            data["questions"] = parse_questions(res.output, s.worksheet)
        await emit({"type": "homework_progress", "request_id": request_id, "data": data})

    # ------------------------------------------------------------------ advice
    @property
    def advice_available(self) -> bool:
        return self._advice_factory is not None

    async def advise(self, session_id: str, request_id: str, image_b64: str, composite: bool, emit: Emit) -> None:
        """Ask the study assistant which problem the child is stuck on and for a hint.
        The answer streams as homework_advice_delta, then homework_advice_result /
        homework_advice_error. One at a time."""
        if self._advice_factory is None:
            raise ValueError("no assistant for advice (study.provider)")
        if self._advice_task is not None and not self._advice_task.done():
            raise ValueError("an advice is already being written")
        if not request_id:
            raise ValueError("request_id is required")
        image = decode_jpeg(image_b64, self.config.max_image_bytes * 2)
        s = self.sessions.get(session_id)
        context: dict[str, Any] = {"composite": composite}
        if s is not None:
            t = s.elapsed()
            context.update(elapsed_s=t, progress_pct=s.tracker.smoothed_pct, stalled_for_s=s.tracker.stalled_for(t))
        self._advice_task = asyncio.create_task(self._advise(s, request_id, image, context, emit))

    async def _advise(self, s: _Session | None, request_id: str, image: bytes, context: dict, emit: Emit) -> None:
        temp = tempfile.TemporaryDirectory(prefix="corexy-ufo-homework-")
        path = Path(temp.name) / f"{uuid.uuid4().hex}.jpg"
        path.write_bytes(image)
        adapter = None
        thread = None

        async def delta(text: str) -> None:
            if text:
                await emit({"type": "homework_advice_delta", "request_id": request_id, "data": {"text": text}})

        try:
            adapter = self._advice_factory()  # type: ignore[misc]  # a bad study.provider fails here
            thread = await adapter.start_session(Path(temp.name), ADVICE_SYSTEM_PROMPT)
            await asyncio.wait_for(adapter.ask(thread, advice_prompt(context), path, delta),
                                   self.config.advice_timeout_s)
            if s is not None:
                s.tracker.reset_stall(s.elapsed())
            await emit({"type": "homework_advice_result", "request_id": request_id, "data": context})
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            await emit({"type": "homework_advice_error", "request_id": request_id,
                        "data": {"code": "timeout", "message": "アドバイスの作成がタイムアウトしました"}})
        except Exception as e:
            await emit({"type": "homework_advice_error", "request_id": request_id,
                        "data": {"code": "assistant_error", "message": str(e)}})
        finally:
            try:
                if adapter is not None and thread is not None:
                    await adapter.close_session(thread)
                if adapter is not None:
                    await adapter.close()
            except Exception:  # pragma: no cover - cleanup must not hide the answer
                log.exception("homework advice cleanup")
            temp.cleanup()

    # ------------------------------------------------------------------ locate (#79)
    async def locate(self, session_id: str, request_id: str, kind: str, image_b64: str, emit: Emit,
                     problem: int = 0, worksheet_id: str = "") -> None:
        """Which problem ("stuck" / "next", or "problem" = number `problem` of a known worksheet)
        and where its answer box is in this overview image. Answers with homework_locate_result
        {kind, problem, u, v, box, jev_box, verified, usable, page_check} or homework_locate_error.
        One at a time."""
        if self._advice_factory is None:
            raise ValueError("no assistant to read the worksheet (study.provider)")
        if self._locate_task is not None and not self._locate_task.done():
            raise ValueError("a problem is already being located")
        if not request_id:
            raise ValueError("request_id is required")
        s = self.sessions.get(session_id)
        target: dict | None = None
        if kind == "problem":
            ws = self.worksheet(worksheet_id) if worksheet_id else (s.worksheet if s is not None else None)
            if ws is None:
                raise ValueError("kind problem needs a worksheet_id")
            try:
                prob = WorksheetCatalog.problem(ws, int(problem))
            except (WorksheetError, TypeError, ValueError) as e:
                raise ValueError(str(e)) from e
            target = {"worksheet": ws, "problem": prob}
        locate_prompt(kind, 1, 1, False, self._target_text(target))  # an unknown kind fails here
        image = decode_jpeg(image_b64, self.config.max_image_bytes)
        width, height = jpeg_size(image)
        self._locate_task = asyncio.create_task(self._locate(s, request_id, kind, image, width, height, emit,
                                                             target))

    @staticmethod
    def _target_text(target: dict | None) -> str:
        if target is None:
            return ""
        p = target["problem"]
        return f"プリントの問題 {p['number']}「{p['prompt']}」（{p['number']} と書かれた丸の問題）"

    async def _locate(self, s: _Session | None, request_id: str, kind: str, image: bytes,
                      width: int, height: int, emit: Emit, target: dict | None = None) -> None:
        p = self.locate_params
        temp = tempfile.TemporaryDirectory(prefix="corexy-ufo-locate-")
        now_path = Path(temp.name) / "now.jpg"
        now_path.write_bytes(image)
        before = s.before_frame if s is not None and s.before_frame not in (None, image) else None
        more: list[Path] = []
        if before is not None:
            more.append(Path(temp.name) / "before.jpg")
            more[0].write_bytes(before)
        adapter = None
        thread = None
        chunks: list[str] = []

        async def collect(text: str) -> None:
            chunks.append(text)

        async def fail(code: str, message: str) -> None:
            await emit({"type": "homework_locate_error", "request_id": request_id,
                        "data": {"kind": kind, "code": code, "message": message}})

        try:
            adapter = self._advice_factory()  # type: ignore[misc]
            thread = await adapter.start_session(Path(temp.name), LOCATE_SYSTEM_PROMPT)
            prompt = locate_prompt(kind, width, height, before is not None, self._target_text(target))
            if more:
                await asyncio.wait_for(adapter.ask(thread, prompt, now_path, collect, more_images=more), p.timeout_s)
            else:
                await asyncio.wait_for(adapter.ask(thread, prompt, now_path, collect), p.timeout_s)
            found = parse_answer("".join(chunks), width, height, p.max_box_area)
            if target is not None:
                found["description_en"] = target["problem"]["description_en"]
                found["problem"] = found["problem"] or f"問題 {target['problem']['number']}"
            data: dict[str, Any] = {"kind": kind, "problem": found["problem"],
                                    "description_en": found["description_en"],
                                    "box": [round(v, 4) for v in found["box"]], "compared": before is not None,
                                    "jev_box": None, "jev_confidence": None, "verified": False, "reason": ""}
            data["u"], data["v"] = (round(v, 4) for v in centre(found["box"]))
            try:
                client = s.client if s is not None else self._client_factory()
                jev_input = jev_box_input(base64.b64encode(image).decode("ascii"), found["description_en"],
                                          marks=target is not None)
                res = await asyncio.wait_for(asyncio.to_thread(client.run, jev_input, p.jev_timeout_s),
                                             p.jev_timeout_s + 5.0)
                if s is not None:
                    s.input_tokens += int(res.usage.get("input_tokens") or 0)
                    s.cost_usd += res.cost_usd or 0.0
                jb = jev_box(res.output)
                if jb is None:
                    data["reason"] = "Jev が解答欄を見つけられませんでした"
                else:
                    data["jev_box"] = [round(v, 4) for v in jb[0]]
                    data["jev_confidence"] = jb[1]
                    data["verified"] = agrees(found["box"], jb[0], p.jev_margin)
                    if not data["verified"]:
                        data["reason"] = "Claude と Jev の解答欄の位置が合いませんでした"
                if target is not None:
                    data["page_check"] = self._page_check(res.output, target, data["u"], data["v"], p.jev_margin)
            except (JevError, asyncio.TimeoutError) as e:
                data["reason"] = "Jev で確かめられませんでした: " + (
                    e.describe() if isinstance(e, JevError) else "タイムアウト")
            data["usable"] = data["verified"] or not p.require_jev
            pc = data.get("page_check")
            if isinstance(pc, dict) and pc.get("agrees") is False:
                data["usable"] = False
                data["reason"] = "プリントの基準マークから見た問題の位置と合いませんでした"
            if target is not None:
                data["problem_number"] = target["problem"]["number"]
                data["worksheet_id"] = target["worksheet"]["worksheet_id"]
            if kind == "stuck" and s is not None:
                s.tracker.reset_stall(s.elapsed())  # help was given: wait stall_s before the next offer
            await emit({"type": "homework_locate_result", "request_id": request_id, "data": data})
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            await fail("timeout", "問題の読み取りがタイムアウトしました")
        except LocateError as e:
            await fail(e.kind, str(e))
        except Exception as e:
            await fail("assistant_error", str(e))
        finally:
            try:
                if adapter is not None and thread is not None:
                    await adapter.close_session(thread)
                if adapter is not None:
                    await adapter.close()
            except Exception:  # pragma: no cover - cleanup must not hide the answer
                log.exception("homework locate cleanup")
            temp.cleanup()

    def _page_check(self, output: dict, target: dict, u: float, v: float, margin: float) -> dict[str, Any]:
        """Where the worksheet's layout puts the problem, from the corner marks Jev found:
        agrees None when not all 4 were found (not checked), else whether (u, v) is inside."""
        from .locate import jev_marks
        marks = jev_marks(output)
        out: dict[str, Any] = {"marks_found": sorted(marks), "agrees": None, "region": None}
        if self.worksheets is None or sorted(marks) != sorted(MARKS):
            out["reason"] = f"基準マーク {len(marks)} / 4 個（ページの位置では確かめていない）"
            return out
        try:
            h = paper_to_image(self.worksheets, marks)
            region = box_in_image(h, target["problem"]["region_mm"])
        except (WorksheetError, ValueError) as e:
            out["reason"] = f"ページの位置を計算できませんでした: {e}"
            return out
        out["region"] = [round(x, 4) for x in region]
        out["agrees"] = point_inside(region, u, v, margin)
        return out

    # ------------------------------------------------------------------ explain (#86)
    async def explain(self, request_id: str, images: list[dict], problem: int, grade_label: str,
                      worksheet_id: str, emit: Emit) -> None:
        """images: [{role: overview|10cm|5cm|landing, image_jpeg_base64}] -> homework_explain_result
        (structured, speech_lines) or homework_explain_error. One at a time."""
        if self._explain_factory is None:
            raise ValueError("no assistant to explain (study.provider)")
        if self._explain_task is not None and not self._explain_task.done():
            raise ValueError("an explanation is already being written")
        if not request_id:
            raise ValueError("request_id is required")
        if not isinstance(images, list) or not 1 <= len(images) <= 5:
            raise ValueError("1 to 5 images are needed")
        decoded = []
        for item in images:
            if not isinstance(item, dict):
                raise ValueError("bad image entry")
            decoded.append((str(item.get("role", "")), decode_jpeg(str(item.get("image_jpeg_base64", "")),
                                                                   self.config.max_image_bytes)))
        known = None
        if worksheet_id:
            ws = self.worksheet(worksheet_id)
            try:
                known = WorksheetCatalog.problem(ws, int(problem))
            except (WorksheetError, TypeError, ValueError) as e:
                raise ValueError(str(e)) from e
            grade_label = grade_label or str(ws.get("grade_label", ""))
        self._explain_task = asyncio.create_task(
            self._explain(request_id, decoded, int(problem), grade_label, known, emit))

    async def _explain(self, request_id: str, images: list[tuple[str, bytes]], problem: int, grade_label: str,
                       known: dict | None, emit: Emit) -> None:
        temp = tempfile.TemporaryDirectory(prefix="corexy-ufo-explain-")
        paths = []
        for i, (role, data) in enumerate(images):
            path = Path(temp.name) / f"{i}-{role or 'image'}.jpg"
            path.write_bytes(data)
            paths.append(path)
        adapter = None
        thread = None
        chunks: list[str] = []

        async def collect(text: str) -> None:
            chunks.append(text)

        try:
            adapter = self._explain_factory()  # type: ignore[misc]
            thread = await adapter.start_session(Path(temp.name), EXPLAIN_SYSTEM_PROMPT)
            prompt = explain_prompt(problem, grade_label, [r for r, _ in images],
                                    {"prompt": known["prompt"]} if known else None)
            more, last = paths[:-1], paths[-1]
            if more:
                await asyncio.wait_for(adapter.ask(thread, prompt, last, collect, more_images=more),
                                       self.config.explain_timeout_s)
            else:
                await asyncio.wait_for(adapter.ask(thread, prompt, last, collect), self.config.explain_timeout_s)
            result = parse_explanation("".join(chunks), problem)
            if known is not None:
                result = compare_with_known(result, known["prompt"])
            result["source"] = "assistant"
            result["speech_lines"] = split_speech(result["speech_text"])
            await emit({"type": "homework_explain_result", "request_id": request_id, "data": result})
        except asyncio.CancelledError:
            raise
        except (asyncio.TimeoutError, ExplainError, Exception) as e:
            code = "timeout" if isinstance(e, asyncio.TimeoutError) else getattr(e, "kind", "assistant_error")
            message = "解説の作成がタイムアウトしました" if code == "timeout" else str(e)
            data: dict[str, Any] = {"code": code, "message": message}
            if known is not None:  # the game can still explain with the worksheet's own hints
                fb = fallback_explanation(known, problem, message)
                fb["speech_lines"] = split_speech(fb["speech_text"])
                data["fallback"] = fb
            await emit({"type": "homework_explain_error", "request_id": request_id, "data": data})
        finally:
            try:
                if adapter is not None and thread is not None:
                    await adapter.close_session(thread)
                if adapter is not None:
                    await adapter.close()
            except Exception:  # pragma: no cover - cleanup must not hide the answer
                log.exception("homework explain cleanup")
            temp.cleanup()

    # ------------------------------------------------------------------ speech (#79)
    @property
    def speech_available(self) -> bool:
        return self.speech is not None and self.speech.available

    async def say(self, request_id: str, text: str, emit: Emit) -> None:
        """Text -> homework_speech {text, engine, credit, wav_base64} or homework_speech_error."""
        if self.speech is None:
            raise ValueError("speech is off (config homework.speech)")
        task = asyncio.create_task(self._say(request_id, text, emit))
        self._speech_tasks.add(task)
        task.add_done_callback(self._speech_tasks.discard)

    async def _say(self, request_id: str, text: str, emit: Emit) -> None:
        try:
            speech = await self.speech.synthesize(text)  # type: ignore[union-attr]
        except SpeechError as e:
            await emit({"type": "homework_speech_error", "request_id": request_id,
                        "data": {"code": e.kind, "message": str(e), "text": text}})
            return
        await emit({"type": "homework_speech", "request_id": request_id, "data": {
            "text": text, "engine": speech.engine, "credit": speech.credit,
            "wav_base64": base64.b64encode(speech.wav).decode("ascii")}})

    async def stop(self, session_id: str) -> dict[str, Any] | None:
        s = self.sessions.pop(session_id, None)
        if s is None:
            return None
        if s.task is not None and not s.task.done():
            s.task.cancel()
            await asyncio.gather(s.task, return_exceptions=True)
        log.info("homework session %s stopped: %s", session_id, s.summary())
        return {"session_id": session_id, "state": "stopped", **s.summary(),
                "history": s.tracker.history}

    async def close(self) -> None:
        for session_id in list(self.sessions):
            await self.stop(session_id)
        tasks = [t for t in (self._advice_task, self._locate_task, self._explain_task, *self._speech_tasks)
                 if t is not None and not t.done()]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
