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


class TutorStudyAdapter:
    _breakers: dict[str, dict] = {}  # 接続先 URL → {"fails", "open_until"}

    def __init__(self, base_url: str, token: str, *, model: str = "tutor-ufo", grade: int = 3, image_role: str = "10cm",
                 cafile: str | None = None, timeout_s: float = 20.0, focus_calibration: str | None = None,
                 fail_limit: int = 2, cooldown_s: float = 120.0) -> None:
        if not token:
            raise StudyAdapterError("学習支援 AI のトークンがありません（study.tutor_token_file）")
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
        req = urllib.request.Request(self.url, json.dumps(body).encode(), {"Content-Type": "application/json",
                                                                              "Authorization": "Bearer " + self.token})
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
            raise StudyAdapterError(f"学習支援 AI がエラーを返しました（HTTP {e.code}）: {detail}") from e
        except Exception as e:  # noqa: BLE001  つながらない・時間切れ・証明書など
            self._failed()
            raise StudyAdapterError(f"学習支援 AI に接続できません: {e}") from e
        if not isinstance(out, dict) or "tutor_result" not in out:
            self._failed()
            raise StudyAdapterError("学習支援 AI の返事の形が違います")
        self.breaker["fails"] = 0
        return out

    def _failed(self) -> None:
        self.breaker["fails"] += 1
        if self.breaker["fails"] >= self.fail_limit:
            self.breaker["open_until"] = time.monotonic() + self.cooldown_s
            self.breaker["fails"] = 0

    def health(self) -> dict:
        """接続の確認（起動時や設定画面で使う）。/api/health（認証なし）と /v1/models（トークンの確認）。"""
        base = self.url.rsplit("/v1/", 1)[0]
        res = {}
        for name, path, auth in (("health", "/api/health", False), ("auth", "/v1/models", True)):
            req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + self.token} if auth else {})
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
