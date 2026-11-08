"""Cloudflare Workers AI `typesafe/jev-1.14.0` over REST (standard library only).

Ported from ~/python_ws/jev/test_jev.py (verified there on 2026-10-19 / 2026-11-09):
- POST https://api.cloudflare.com/client/v4/accounts/{account}/ai/run
  {"model": "typesafe/jev-1.14.0", "input": {state, assets, questions}}
- the REST answer is wrapped twice: {"result": {"state": "Completed", "result": <model output>},
  "success": true, ...}; the model output carries "answers" and "usage"
- 400 code 7003 = too many tokens, 401 code 10000 = token expired, 402 code 2021 = no credit

The key comes from the environment or the repository's `.env` (never committed:
.gitignore, the guard hook and the secret scanners stop it). It is never logged.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

MODEL_ID = "typesafe/jev-1.14.0"
API_URL = "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run"
# USD per 1M tokens (Cloudflare's model page, checked in the jev repo 2026-10-19)
PRICE_INPUT_PER_M = 0.042
PRICE_OUTPUT_PER_M = 0.0
KEYS = ("CF_ACCOUNT_ID", "CF_API_TOKEN")


class JevError(Exception):
    """A failed Jev call. `status` is the HTTP status (None before an answer)."""

    def __init__(self, kind: str, message: str, status: int | None = None,
                 codes: list[Any] | None = None) -> None:
        super().__init__(message)
        self.kind = kind
        self.status = status
        self.codes = codes or []

    @property
    def fatal(self) -> bool:
        """4xx other than 429: retrying the same request will not help."""
        return self.status is not None and 400 <= self.status < 500 and self.status != 429

    def describe(self) -> str:
        parts = [str(self)]
        if self.status is not None:
            parts.append(f"HTTP {self.status}")
        if self.codes:
            parts.append("code " + ",".join(str(c) for c in self.codes))
        return " / ".join(parts)


@dataclass
class JevCredentials:
    account_id: str
    api_token: str = field(repr=False)


def read_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE lines of a .env file (quotes stripped, comments and blanks skipped)."""
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip().removeprefix("export ").strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out[key] = value
    return out


def load_credentials(env_path: Path | None) -> JevCredentials:
    """The environment wins over the .env file. Raises JevError("config") when unset."""
    file_values = read_env_file(env_path) if env_path is not None else {}
    values = {k: (os.environ.get(k) or file_values.get(k) or "").strip() for k in KEYS}
    # placeholders (.env.example's <...>, jev's xxxx) count as unset
    missing = [k for k, v in values.items() if not v or v.lower().startswith("xxxx") or v.startswith("<")]
    if missing:
        where = f"{env_path}" if env_path is not None else "the environment"
        raise JevError("config", f"Jev の鍵が未設定です: {', '.join(missing)}（{where} に書く。"
                                 ".env.example を参照）")
    return JevCredentials(values["CF_ACCOUNT_ID"], values["CF_API_TOKEN"])


@dataclass
class JevResult:
    output: dict
    latency_s: float

    @property
    def usage(self) -> dict:
        return self.output.get("usage") or {}

    @property
    def cost_usd(self) -> float | None:
        u = self.usage
        if u.get("input_tokens") is None or u.get("output_tokens") is None:
            return None
        return (u["input_tokens"] * PRICE_INPUT_PER_M + u["output_tokens"] * PRICE_OUTPUT_PER_M) / 1_000_000


def _classify(status: int) -> str:
    return {400: "bad_request", 401: "auth", 402: "billing", 403: "auth",
            404: "model_unavailable", 429: "rate_limit"}.get(status, "server" if status >= 500 else "http")


def unwrap(body: Any) -> dict:
    """The model output (with "answers") out of Cloudflare's envelope."""
    output = body
    while isinstance(output, dict) and "answers" not in output and isinstance(output.get("result"), dict):
        state = output.get("state")
        if state is not None and state != "Completed":
            raise JevError("json", f"推論が完了していません: state={state}")
        output = output["result"]
    if not isinstance(output, dict) or "answers" not in output:
        raise JevError("json", "Jev の出力に answers がありません")
    return output


class JevClient:
    """Blocking client: call `run` from a thread (asyncio.to_thread)."""

    def __init__(self, credentials: JevCredentials, *, opener=None) -> None:
        self.credentials = credentials
        self._open = opener or urllib.request.urlopen

    def run(self, jev_input: dict, timeout: float = 30.0) -> JevResult:
        url = API_URL.format(account_id=self.credentials.account_id)
        data = json.dumps({"model": MODEL_ID, "input": jev_input}).encode()
        req = urllib.request.Request(url, data=data, method="POST", headers={
            "Authorization": f"Bearer {self.credentials.api_token}",
            "Content-Type": "application/json"})
        t0 = time.perf_counter()
        try:
            with self._open(req, timeout=timeout) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
        except TimeoutError as e:
            raise JevError("timeout", f"API がタイムアウトしました（{timeout:.0f} 秒）") from e
        except (urllib.error.URLError, OSError) as e:
            raise JevError("network", f"通信エラー: {type(e).__name__}") from e
        latency = time.perf_counter() - t0
        try:
            body = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as e:
            raise JevError("json", "レスポンスの JSON 解析に失敗しました", status=status) from e
        codes = [e.get("code") for e in (body.get("errors") or [])] if isinstance(body, dict) else []
        if status != 200 or (isinstance(body, dict) and body.get("success") is False):
            raise JevError(_classify(status), "API リクエストが失敗しました", status=status, codes=codes)
        try:
            output = unwrap(body)
        except JevError as e:
            e.status = status
            raise
        return JevResult(output=output, latency_s=latency)
