"""Are the outside services there? (#114) The 校正 tab asks when it opens (services_check):

- Jev (Cloudflare Workers AI): the .env keys, and the token's own verify call (free: no inference)
- the learning support AI (UFOくん API, #104): /api/health and the token (/v1/models)
- Claude Code / Codex (study.provider and the explanation's provider): the command and --version
- VOICEVOX (#112): /version

`ask=True` also sends one short question with the sample worksheet (tools/samples) through the
explanation's adapter, to see a real answer come back, and (with a tutor URL) reads that worksheet
with the worksheet reader, POST /v1/sheet (#230; it has no check of its own: only a real call shows
whether the server runs its model). Secrets (tokens) never go into a result.
Every check has a timeout; each one is "ok", "ng" (with the reason) or "skip" (not used here).
"""

from __future__ import annotations

import asyncio
import json
import logging
import shlex
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import replace
from pathlib import Path
from typing import Any, Callable

from .config import REPO_ROOT
from .homework.jev import JevError, load_credentials
from .homework.speech import SpeechConfig
from .study import StudyConfig, make_adapter, make_sheet_client
from .study.claude_adapter import resolve_claude

log = logging.getLogger(__name__)

SAMPLE = REPO_ROOT / "tools" / "samples" / "worksheet_sample.jpg"
VERIFY_URLS = ("https://api.cloudflare.com/client/v4/user/tokens/verify",
               "https://api.cloudflare.com/client/v4/accounts/{account_id}/tokens/verify")
LABELS = {"jev": "Jev（Cloudflare）", "tutor": "学習支援 AI（ローカル LLM）", "claude": "Claude Code",
          "codex": "Codex", "voicevox": "VOICEVOX", "ask": "AI に試しに質問",
          "sheet": "プリント読み取り（/v1/sheet）"}


def result(name: str, status: str, detail: str, t0: float | None = None) -> dict:
    out = {"name": name, "label": LABELS.get(name, name), "status": status, "detail": detail[:300]}
    if t0 is not None:
        out["ms"] = int((time.monotonic() - t0) * 1000)
    return out


def _get_json(url: str, headers: dict, timeout: float, opener: Callable | None = None) -> tuple[int, dict]:
    req = urllib.request.Request(url, headers=headers)
    try:
        with (opener or urllib.request.urlopen)(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8") or "{}")
        except ValueError:
            return e.code, {}


def check_jev(env_path: Path, opener: Callable | None = None) -> dict:
    t0 = time.monotonic()
    try:
        cred = load_credentials(env_path)
    except JevError as e:
        return result("jev", "ng", str(e), t0)
    last = ""
    for tmpl in VERIFY_URLS:
        try:
            status, body = _get_json(tmpl.format(account_id=cred.account_id),
                                     {"Authorization": "Bearer " + cred.api_token}, 8.0, opener)
        except (OSError, ValueError) as e:
            return result("jev", "ng", f"Cloudflare につながらない: {e}", t0)
        state = (body.get("result") or {}).get("status") if isinstance(body.get("result"), dict) else None
        if status == 200 and body.get("success") and state == "active":
            return result("jev", "ok", "鍵あり・トークン有効（推論はしていない）", t0)
        if status == 200 and state:
            return result("jev", "ng", f"トークンの状態: {state}", t0)
        last = f"HTTP {status}"
    return result("jev", "ng", f"トークンを確かめられない（{last}。.env の CF_API_TOKEN / CF_ACCOUNT_ID）", t0)


def _version(argv: list[str], timeout: float = 15.0) -> tuple[bool, str]:
    try:
        p = subprocess.run(argv + ["--version"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    text = (p.stdout or p.stderr).strip().splitlines()
    return p.returncode == 0, (text[0] if text else f"exit {p.returncode}")


def check_claude(command: str) -> dict:
    t0 = time.monotonic()
    argv = shlex.split(command or "claude")
    program = resolve_claude(argv[0]) if argv else "claude"
    if not (Path(program).is_file() or shutil.which(program)):
        return result("claude", "ng", "Claude Code（claude）が見つからない（PATH・~/.local/bin・Homebrew・VS Code の拡張を探した）", t0)
    ok, text = _version([program])
    return result("claude", "ok" if ok else "ng", f"{text}（{program}）" if ok else f"--version が失敗: {text}", t0)


def check_codex(command: str) -> dict:
    t0 = time.monotonic()
    argv = shlex.split(command or "codex")
    program = shutil.which(argv[0]) if argv else None
    if not program:
        return result("codex", "ng", "Codex（codex）が見つからない", t0)
    ok, text = _version([program])
    return result("codex", "ok" if ok else "ng", text if ok else f"--version が失敗: {text}", t0)


def check_tutor(cfg: StudyConfig) -> dict:
    t0 = time.monotonic()
    try:
        adapter = make_adapter(cfg, "tutor")
        h = adapter.health()
    except Exception as e:  # noqa: BLE001 - the reason is the answer (no URL / token / cert)
        return result("tutor", "ng", str(e), t0)
    if h.get("ok"):
        return result("tutor", "ok", f"{cfg.tutor_url} につながる・" + ("トークン有効" if adapter.token else "トークンなし"), t0)
    parts = []
    for k, what in (("health", "サーバ"), ("auth", "トークン")):
        v = h.get(k) or {}
        if not v.get("ok"):
            if k == "auth" and v.get("status") == 401:
                parts.append(adapter.auth_problem())  # #128: none here / a wrong one
                continue
            parts.append(f"{what}: " + (f"HTTP {v['status']}" if "status" in v else str(v.get("error", "?"))[:120]))
    return result("tutor", "ng", f"{cfg.tutor_url}: " + "、".join(parts), t0)


def check_voicevox(sp: SpeechConfig, opener: Callable | None = None) -> dict:
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(sp.voicevox_url + "/version")
        with (opener or urllib.request.urlopen)(req, timeout=3.0) as r:
            v = r.read().decode("utf-8").strip().strip('"')
        return result("voicevox", "ok", f"VOICEVOX {v}（{sp.voicevox_url}）", t0)
    except (OSError, ValueError) as e:
        return result("voicevox", "ng", f"{sp.voicevox_url} につながらない（./start.sh が Docker で起動する。準備中ならしばらく待つ）: {e}", t0)


async def ask_once(cfg: StudyConfig, provider: str, timeout_s: float = 90.0) -> dict:
    """One short question with the sample worksheet through the explanation's adapter."""
    from .study_mode.explain import explain_prompt
    t0 = time.monotonic()
    chunks: list[str] = []

    async def collect(text: str) -> None:
        chunks.append(text)
    adapter = thread = None
    try:
        adapter = make_adapter(cfg, provider)
        with tempfile.TemporaryDirectory(prefix="corexy-ufo-check-") as d:
            img = Path(d) / "0-10cm.jpg"
            img.write_bytes(SAMPLE.read_bytes())
            thread = await adapter.start_session(Path(d), "接続の確認です。短く答えてください。")
            prompt = (explain_prompt(4, "小学1年", ["10cm"], None) if provider == "tutor"
                      else "接続の確認です。画像に数字の問題が写っていれば「OK」とだけ答えてください。")
            await asyncio.wait_for(adapter.ask(thread, prompt, img, collect), timeout_s)
        text = "".join(chunks).strip().replace("\n", " ")
        if not text:
            return result("ask", "ng", f"{provider}: 返事が空", t0)
        return result("ask", "ok", f"{provider} が答えた: {text[:80]}", t0)
    except asyncio.TimeoutError:
        return result("ask", "ng", f"{provider}: {timeout_s:.0f} 秒で返事がない", t0)
    except Exception as e:  # noqa: BLE001
        return result("ask", "ng", f"{provider}: {e}", t0)
    finally:
        try:
            if adapter is not None and thread is not None:
                await adapter.close_session(thread)
            if adapter is not None:
                await adapter.close()
        except Exception:  # pragma: no cover
            log.exception("services_check: closing the adapter")


def check_sheet(cfg: StudyConfig, image: Path = SAMPLE) -> dict:
    """Reads the sample worksheet once with POST /v1/sheet (~10 s; a 401 is never sent twice)."""
    from .study.sheet_client import SheetError
    t0 = time.monotonic()
    try:
        client = make_sheet_client(cfg)
        res = client.read(image.read_bytes())
    except SheetError as e:
        return result("sheet", "ng", str(e), t0)
    except Exception as e:  # noqa: BLE001
        return result("sheet", "ng", f"{type(e).__name__}: {e}", t0)
    if not res.read_anything:
        return result("sheet", "ng", "つながったが、見本のプリントを読めなかった（problems が空）", t0)
    return result("sheet", "ok", f"見本のプリントを読んだ: {res.summary()}", t0)


async def check_all(raw: dict[str, Any], *, ask: bool = False, env_path: Path | None = None,
                    root: Path = REPO_ROOT, focus_calibration: Any = None) -> list[dict]:
    cfg = replace(StudyConfig.from_raw(raw), root=str(root), focus_calibration=focus_calibration)
    explain = cfg.explain_provider or cfg.provider
    providers = {cfg.provider, explain}
    sp = SpeechConfig.from_raw(raw)
    jobs: list[Any] = [asyncio.to_thread(check_jev, env_path or (root / ".env"))]
    names = ["jev"]
    if "tutor" in providers or cfg.tutor_url:
        jobs.append(asyncio.to_thread(check_tutor, cfg))
        names.append("tutor")
    if "claude" in providers:
        jobs.append(asyncio.to_thread(check_claude, cfg.claude_command))
        names.append("claude")
    if "codex" in providers:
        jobs.append(asyncio.to_thread(check_codex, cfg.codex_command))
        names.append("codex")
    if sp.enabled and "voicevox" in sp.engines:
        jobs.append(asyncio.to_thread(check_voicevox, sp))
        names.append("voicevox")
    out = list(await asyncio.gather(*jobs))
    if "tutor" not in names:
        out.append(result("tutor", "skip", "使っていない（設定の「学習モードの解説」と「学習支援 AI の URL」）"))
    if ask:
        out.append(await ask_once(cfg, explain))
        if cfg.tutor_url:  # after the question: the server works one request at a time
            out.append(await asyncio.to_thread(check_sheet, cfg))
    return out
