"""学習支援 AI（UFOくん API: server/tutor_app.py）を、CoreXY UFO Game の StudyAdapter として使う見本。

CoreXY UFO Game の backend/src/corexy_ufo_backend/study/ に置き、service.py の PROVIDERS と make_adapter に "tutor" を足す
（README.md 参照）。依存は標準ライブラリだけ（urllib・ssl）。

ゲームの解説（homework_explain）は、全体・10cm・5cm・いちばん近く の画像と、explain_prompt の文を ask() に渡す。
このアダプタは:
  - 文から「問題の番号」と「学年」を読み取る（explain_prompt の決まった書き方）
  - 画像は 10cm の 1 枚を使う（学習支援 AI は 1 枚の画像で学習しているため。設定で変えられる）
  - 対象の問題は指定せず「{番号}ばんが わからない」という発言として渡す（写っていなければ API が移動の提案を返す）
  - 返事をゲームの解説 JSON（explain.FIELDS）に直して on_delta で返す。移動の提案があれば "navigate" を足す
    （d_mm: 今の撮影位置からの移動量 [mm]。先端カメラのキャリブレーションがあるときだけ）
"""
from __future__ import annotations

import asyncio
import base64
import json
import re
import ssl
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Awaitable, Callable, Sequence

from .errors import StudyAdapterError

# explain_prompt が画像の説明に使う言葉（順番を読み取って、10cm の画像がどれかを決める）
ROLE_WORDS = {"overview": "机の上から撮ったプリント全体", "10cm": "アームのカメラで 10cm 上から",
              "5cm": "アームのカメラで 5cm 上から", "landing": "アームのカメラでいちばん近くから"}


def roles_in_prompt(text: str) -> list[str]:
    found = [(text.find(w), r) for r, w in ROLE_WORDS.items() if w in text]
    return [r for _, r in sorted(found)]


def problem_in_prompt(text: str) -> int | None:
    m = re.search(r"問題\s*(\d{1,2})\s*で困っています", text)
    return int(m.group(1)) if m else None


def grade_in_prompt(text: str, default: int) -> int:
    """The grade from the prompt's grade label (小学N年 -> N). The API knows grades 1..6: a junior
    high sheet asks as 6, a nursery one as 1 (#104)."""
    head = text.split("の宿題プリント", 1)[0]  # only the grade label: the problem text may say "年" too
    if "中学" in head:
        return 6
    if "保育園" in head or any(w in head for w in ("年少", "年中", "年長")):
        return 1
    m = re.search(r"([1-6１-６])\s*年", head)
    return int(m.group(1).translate(str.maketrans("１２３４５６", "123456"))) if m else default


# where a streamed sentence ends (UFOくん's lines: 。！？ and line breaks)
SENTENCE_END = re.compile(r"[。！？!?]+[」』）)]*|\n+")
# "こたえは 5" / "答えは5だよ": giving the answer away (mode normal never should)
REVEAL = re.compile(r"(こたえ|答え)\s*(は|が|も)\s*[「（(]?\s*[0-9０-９一二三四五六七八九十]")


def split_sentences(text: str) -> list[str]:
    out, start = [], 0
    for m in SENTENCE_END.finditer(text):
        part = text[start:m.end()].strip()
        if part:
            out.append(part)
        start = m.end()
    tail = text[start:].strip()
    if tail:
        out.append(tail)
    return out


def gives_answer(sentence: str, answers: Sequence[str] = ()) -> bool:
    """A sentence that seems to say the answer: "こたえは 5", or a known answer said as one
    ("= 85", "85 だよ", "85 になる")."""
    s = sentence.translate(str.maketrans("０１２３４５６７８９", "0123456789"))
    if REVEAL.search(s):
        return True
    for a in answers:
        a = str(a).strip().translate(str.maketrans("０１２３４５６７８９", "0123456789"))
        if not a:
            continue
        num = re.escape(a)
        if re.search(rf"=\s*{num}(?![0-9])", s) or re.search(rf"(?<![0-9]){num}\s*(だよ|です|になる|だね|が こたえ|がこたえ)", s):
            return True
    return False


class TutorStudyAdapter:
    _breakers: dict[str, dict] = {}  # 接続先 URL → {"fails", "open_until"}

    def __init__(self, base_url: str, token: str, *, model: str = "tutor-ufo", grade: int = 3, image_role: str = "10cm",
                 cafile: str | None = None, timeout_s: float = 20.0, focus_calibration: str | None = None,
                 fail_limit: int = 2, cooldown_s: float = 120.0) -> None:
        # token "" = none (#128: a server started without one); then no Authorization header
        self.url = base_url.rstrip("/") + "/v1/chat/completions"
        self.token, self.model, self.grade, self.image_role, self.timeout_s = token, model, grade, image_role, timeout_s
        if base_url.startswith("https://"):
            # 自己署名証明書: サーバの cert.pem だけを信頼する（検証を切らない）。IP で接続するのでホスト名の照合はしない
            self.ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
            if cafile:
                self.ctx.check_hostname = False
        else:
            self.ctx = None
        # つながらないときのフォールバック: 続けて fail_limit 回失敗したら cooldown_s 秒は呼ばずにすぐエラーにする
        # （StudyAdapterError → ゲームの既存の処理が、プリントのヒント fallback_explanation に切り替える）
        # ゲームは解説のたびにアダプタを作り直す（advice_factory）ので、失敗の記録は接続先ごとにクラスで共有する
        self.fail_limit, self.cooldown_s = fail_limit, cooldown_s
        self.breaker = TutorStudyAdapter._breakers.setdefault(self.url, {"fails": 0, "open_until": 0.0})
        # 先端カメラのキャリブレーション（calibration.json の focus_camera か、そのファイル）。
        # ないか壊れていれば d_mm を付けない = アームは動かない
        self.calib = None
        if focus_calibration:
            from ..study_mode.navigation import FocusCalibration, NavigationError
            src = focus_calibration if hasattr(focus_calibration, "read_text") else Path(focus_calibration)
            try:
                if src.exists():
                    self.calib = FocusCalibration.load(src)
            except (OSError, ValueError, KeyError, TypeError, NavigationError):
                self.calib = None

    async def start_session(self, workdir: Path, instructions: str) -> str:
        return uuid.uuid4().hex

    def _post(self, body: dict) -> dict:
        if time.monotonic() < self.breaker["open_until"]:
            raise StudyAdapterError(f"学習支援 AI は休止中（続けて失敗したため、あと {self.breaker['open_until'] - time.monotonic():.0f} 秒）")
        req = urllib.request.Request(self.url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", **self._auth()})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s, context=self.ctx) as r:
                out = json.load(r)
        except urllib.error.HTTPError as e:
            self._failed()
            detail = ""
            try:
                detail = json.load(e).get("error", {}).get("message", "")
            except Exception:  # noqa: BLE001
                pass
            if e.code == 401:
                raise StudyAdapterError(self.auth_problem() + (f": {detail}" if detail else "")) from e
            raise StudyAdapterError(f"学習支援 AI がエラーを返しました（HTTP {e.code}）: {detail}") from e
        except Exception as e:  # noqa: BLE001  つながらない・時間切れ・証明書など
            self._failed()
            raise StudyAdapterError(f"学習支援 AI に接続できません: {e}") from e
        if not isinstance(out, dict) or "tutor_result" not in out:
            self._failed()
            raise StudyAdapterError("学習支援 AI の返事の形が違います")
        self.breaker["fails"] = 0
        return out

    def _auth(self) -> dict[str, str]:
        return {"Authorization": "Bearer " + self.token} if self.token else {}

    def auth_problem(self) -> str:
        """What a 401 means: no token here but the server wants one, or the token is wrong."""
        if not self.token:
            return "学習支援 AI のサーバがトークンを求めている（config/secrets/tutor_token.txt に置くか、サーバをトークンなしで起動する）"
        return "学習支援 AI のトークンが違う（config/secrets/tutor_token.txt とサーバのトークン）"

    def _failed(self) -> None:
        self.breaker["fails"] += 1
        if self.breaker["fails"] >= self.fail_limit:
            self.breaker["open_until"] = time.monotonic() + self.cooldown_s
            self.breaker["fails"] = 0

    def health(self) -> dict:
        """接続の確認（起動時や設定画面で使う）。/api/health（認証なし）と /v1/models（トークンの確認。
        トークンがないときは、サーバがトークンなしで受け付けるかの確認）。"""
        base = self.url.rsplit("/v1/", 1)[0]
        res = {}
        for name, path, auth in (("health", "/api/health", False), ("auth", "/v1/models", True)):
            req = urllib.request.Request(base + path, headers=self._auth() if auth else {})
            try:
                with urllib.request.urlopen(req, timeout=5, context=self.ctx) as r:
                    res[name] = {"ok": True, "status": r.status}
            except urllib.error.HTTPError as e:
                res[name] = {"ok": False, "status": e.code}
            except Exception as e:  # noqa: BLE001
                res[name] = {"ok": False, "error": str(e)[:200]}
        res["ok"] = all(v["ok"] for v in res.values() if isinstance(v, dict))
        return res

    def build_request(self, text: str, images: list[Path]) -> tuple[dict, int, str]:
        roles = roles_in_prompt(text)
        role = self.image_role if self.image_role in roles else (roles[-1] if roles else "")
        idx = roles.index(role) if role in roles and len(roles) == len(images) else len(images) - 1
        n = problem_in_prompt(text)
        if n is None:
            raise StudyAdapterError("問題の番号が分かりません")
        url = "data:image/jpeg;base64," + base64.b64encode(Path(images[idx]).read_bytes()).decode()
        body = {"model": self.model, "max_tokens": 400,
                "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": url}}]}],
                "tutor": {"target_problem": None, "grade": grade_in_prompt(text, self.grade), "mode": "normal",
                          "history": [], "utterance": f"{n}ばんが わからない"}}
        return body, n, role

    def to_explanation(self, resp: dict, n: int, role: str) -> dict:
        tr = resp.get("tutor_result") or {}
        c, g = tr.get("corexy") or {}, tr.get("game") or {}
        msg = c.get("speech_text") or g.get("message") or ""
        out = {"problem_number": c.get("problem_number") or n, "recognized_problem": c.get("recognized_problem", ""),
               "confidence": c.get("confidence", 0.0), "hint": c.get("hint", ""), "explanation": c.get("explanation") or msg,
               "speech_text": msg, "needs_confirmation": bool(c.get("needs_confirmation", True))}
        nav = tr.get("navigate")
        if nav and nav.get("kind") in ("move", "uncover", "zoom_out"):
            out["needs_confirmation"] = True
            out["navigate"] = {"kind": nav["kind"], "target": n, "offset": nav.get("offset"), "height": role}
            if nav["kind"] == "move" and self.calib is not None and nav.get("offset"):
                try:
                    out["navigate"]["d_mm"] = list(self.calib.offset_to_mm(nav["offset"], role))
                except Exception as e:  # noqa: BLE001  キャリブレーションがない高さなど → 動かさない
                    out["navigate"]["error"] = str(e)
        return out

    def converse_stream(self, image: bytes, utterance: str, *, turns: Sequence[dict] = (), target: int | None = None,
                        grade: int | None = None, on_sentence: Callable[[str], None] | None = None,
                        answers: Sequence[str] = ()) -> dict:
        """One turn of the voice dialogue, streamed (docs/ufo_api_spec.md §5.2 format "dialog", §5.4): UFOくん's
        words come as they are made, and each finished sentence goes to `on_sentence` at once (the
        game says it while the rest is still coming). The conversation is in the messages: the
        worksheet's picture first, then the turns so far ([{role: user|assistant, content}]), then
        what the child just said. Blocking; StudyAdapterError when it fails.

        A streamed sentence has not been checked by the server yet (the stream skips its checks
        but the answer's): a sentence that seems to give the answer away (`answers`, or "こたえは 5")
        is held back, and nothing more is streamed after it. The end compares with the server's
        checked text: `rest` is what is still to be said (all of it when it differs from what was
        streamed and nothing was said yet).
        -> {message, rest, spoken, action, target_problem, need_recapture, visual_effect}"""
        msgs: list[dict] = [{"role": "user", "content": [{"type": "image_url", "image_url": {
            "url": "data:image/jpeg;base64," + base64.b64encode(image).decode()}}]}]
        for t in [t for t in turns if isinstance(t, dict)][-10:]:  # 12 messages at most (§5.1)
            role = "assistant" if t.get("role") == "assistant" else "user"
            text = str(t.get("content", "")).strip()[:400]
            if text:
                msgs.append({"role": role, "content": text})
        msgs.append({"role": "user", "content": utterance.strip()[:100]})
        body = {"model": self.model, "max_tokens": 300, "stream": True, "messages": msgs,
                "tutor": {"grade": max(min(int(grade or self.grade), 6), 1), "format": "dialog", "mode": "normal",
                          "target_problem": target if isinstance(target, int) and target > 0 else None}}
        spoken: list[str] = []
        held = False
        buf = ""

        def flush(final: bool) -> None:
            nonlocal buf, held
            while True:
                m = SENTENCE_END.search(buf)
                if m is None and not final:
                    return
                cut = m.end() if m is not None else len(buf)
                sentence, buf = buf[:cut].strip(), buf[cut:]
                if sentence and not held:
                    if gives_answer(sentence, answers):
                        held = True  # the server's checked text decides the rest
                    else:
                        spoken.append(sentence)
                        if on_sentence is not None:
                            on_sentence(sentence)
                if m is None:
                    return

        def delta(text: str) -> None:
            nonlocal buf
            buf += text
            flush(False)
        tr = self._post_stream(body, delta)
        g = tr.get("game") or {}
        message = str((tr.get("dialog") or {}).get("message") or g.get("message") or "").strip()
        if not message:
            raise StudyAdapterError("学習支援 AI の返事に、話すことばがありません")
        checked = split_sentences(message)
        if checked[:len(spoken)] == spoken:
            rest = checked[len(spoken):]
        else:
            rest = [] if spoken else checked  # what was said cannot be unsaid
        return {"message": message, "rest": rest, "spoken": spoken, "held_back": held,
                "action": str(g.get("action", "")), "need_recapture": bool(g.get("need_recapture", False)),
                "visual_effect": str(g.get("visual_effect", "")), "notes": [str(n) for n in tr.get("notes") or []]}

    def _post_stream(self, body: dict, on_text: Callable[[str], None]) -> dict:
        """POST with "stream": true; the content deltas go to on_text; -> tutor_result."""
        if time.monotonic() < self.breaker["open_until"]:
            raise StudyAdapterError(f"学習支援 AI は休止中（続けて失敗したため、あと {self.breaker['open_until'] - time.monotonic():.0f} 秒）")
        req = urllib.request.Request(self.url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", **self._auth()})
        result: dict | None = None
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s, context=self.ctx) as r:
                for raw in r:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    ev = json.loads(payload)
                    if "error" in ev:
                        raise StudyAdapterError("学習支援 AI の返事が途中で失敗しました: "
                                                + str((ev.get("error") or {}).get("message", ""))[:200])
                    for ch in ev.get("choices") or []:
                        text = (ch.get("delta") or {}).get("content")
                        if text:
                            on_text(text)
                    if isinstance(ev.get("tutor_result"), dict):
                        result = ev["tutor_result"]
        except StudyAdapterError:
            self._failed()
            raise
        except urllib.error.HTTPError as e:
            self._failed()
            if e.code == 401:
                raise StudyAdapterError(self.auth_problem()) from e
            raise StudyAdapterError(f"学習支援 AI がエラーを返しました（HTTP {e.code}）") from e
        except Exception as e:  # noqa: BLE001  つながらない・時間切れ・証明書・こわれた JSON
            self._failed()
            raise StudyAdapterError(f"学習支援 AI に接続できません: {e}") from e
        if result is None:
            self._failed()
            raise StudyAdapterError("学習支援 AI の返事が途中で終わりました")
        self.breaker["fails"] = 0
        return result

    async def ask(self, thread_id: str, text: str, image_path: Path, on_delta: Callable[[str], Awaitable[None]],
                  more_images: Sequence[Path] = ()) -> str:
        body, n, role = self.build_request(text, list(more_images) + [image_path])
        resp = await asyncio.to_thread(self._post, body)
        await on_delta(json.dumps(self.to_explanation(resp, n, role), ensure_ascii=False))
        return uuid.uuid4().hex

    async def cancel(self, thread_id: str, turn_id: str | None = None) -> None:
        return None

    async def close_session(self, thread_id: str) -> None:
        return None

    async def close(self) -> None:
        return None
