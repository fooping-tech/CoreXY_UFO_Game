"""The worksheet reader of the learning support AI (UFOくん API): POST /v1/sheet (#230).

One photo of a worksheet in, per problem out: the problem's box and its answer box, the answer's
state (correct / incorrect / blank / partial / unreadable), the child's answer as read and the
model's own answer. The same server and settings as the tutor adapter (study.tutor_url,
tutor_token_file, tutor_cafile): `make_sheet_client` in service.py builds one.

Nothing here touches the robot, and nothing in the game uses it yet: this is the client and the
校正 tab's check only (where the study mode uses it is a later issue).

How it calls the server (the server's hand-off document):
  - the image goes as a data URL: decoded with EXIF orientation applied (cv2.imdecode does), shrunk
    to a long side of 1800 px (more does not help: the server shrinks to ~0.65 MP), JPEG <= 4 MB
  - the server's cert.pem is trusted (never verify=False); the hostname check stays on
  - one request at a time per server (it works one by one and answers 503 past 4 waiting)
  - 401: never again with that token in this process (10 wrong ones block the IP for 10 minutes);
    429: wait 10 minutes; 400 / 403 / 413: no retry; 500: once more; 503: again after 5, 10, 20 s
  - neither the token nor the image goes into a log or an error message
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import ssl
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable

import cv2
import numpy as np

log = logging.getLogger(__name__)

STATUSES = ("correct", "incorrect", "blank", "partial", "unreadable")
MAX_BYTES = 4 * 1024 * 1024  # the server's limit on the decoded image
MAX_SIDE = 4096
LONG_SIDE = 1800
MIN_TIMEOUT_S = 120.0  # ~10 s a sheet, more with the chat API busy or the model just loaded
BUSY_WAITS_S = (5.0, 10.0, 20.0)  # 503: wait, then try again
BLOCK_S = 600.0  # 429: the server blocks the IP for 10 minutes


class SheetError(Exception):
    """kind: config / image / auth / bad_request / forbidden / too_large / blocked / busy / server /
    network / response. The message is for people (Japanese) and never holds the token."""

    def __init__(self, kind: str, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.kind, self.status = kind, status


@dataclass(frozen=True)
class SheetImage:
    """The JPEG sent, and the photo it came from (to put the boxes back on the photo)."""
    jpeg: bytes
    width: int  # the image sent (what box_px is in)
    height: int
    source_width: int  # the photo given (after EXIF rotation)
    source_height: int

    @property
    def data_url(self) -> str:
        return "data:image/jpeg;base64," + base64.b64encode(self.jpeg).decode("ascii")


def prepare_image(data: bytes, long_side: int = LONG_SIDE, quality: int = 90) -> SheetImage:
    """Any image OpenCV reads -> an upright JPEG with its long side at most `long_side`, <= 4 MB."""
    arr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)  # applies EXIF orientation
    if arr is None:
        raise SheetError("image", "画像として読めません")
    sh, sw = arr.shape[:2]
    long_side = max(min(int(long_side), MAX_SIDE), 64)
    scale = min(1.0, long_side / max(sw, sh))
    if scale < 1.0:
        arr = cv2.resize(arr, (max(round(sw * scale), 1), max(round(sh * scale), 1)), interpolation=cv2.INTER_AREA)
    h, w = arr.shape[:2]
    for q in (quality, 80, 70, 60):
        ok, buf = cv2.imencode(".jpg", arr, [cv2.IMWRITE_JPEG_QUALITY, q])
        if ok and len(buf) <= MAX_BYTES:
            return SheetImage(buf.tobytes(), w, h, sw, sh)
    raise SheetError("image", "画像を 4MB 以下にできません")


def box_to_pixels(box: Any, width: int, height: int) -> tuple[int, int, int, int] | None:
    """A box on the server's 0..1000 scale ([x1, y1, x2, y2]) -> pixels of an image of this size.
    Use the photo's own size to draw on the photo (the aspect ratio is kept when shrinking)."""
    if not (isinstance(box, (list, tuple)) and len(box) == 4 and all(isinstance(v, (int, float)) for v in box)):
        return None
    x1, y1, x2, y2 = box
    return (round(x1 * width / 1000), round(y1 * height / 1000), round(x2 * width / 1000), round(y2 * height / 1000))


@dataclass
class SheetResult:
    raw: dict[str, Any]
    image: SheetImage
    problems: list[dict[str, Any]] = field(default_factory=list)

    @property
    def counts(self) -> dict[str, int]:
        c = {s: 0 for s in STATUSES}
        for p in self.problems:
            c[p["answer_status"]] = c.get(p["answer_status"], 0) + 1
        return c

    @property
    def read_anything(self) -> bool:
        """An empty `problems` means "could not read", not "no problems"."""
        return bool(self.problems)

    @property
    def cropped(self) -> bool:
        """False when the server did not find the paper's outline (paper_px is null)."""
        return self.raw.get("paper_px") is not None

    def boxes_on_source(self, p: dict[str, Any]) -> tuple[tuple | None, tuple | None]:
        """(box, answer_box) of a problem in the pixels of the photo given (before shrinking)."""
        w, h = self.image.source_width, self.image.source_height
        return box_to_pixels(p.get("box"), w, h), box_to_pixels(p.get("answer_box"), w, h)

    def summary(self) -> str:
        if not self.problems:
            return "問題を読めなかった"
        c = self.counts
        names = {"correct": "正解", "incorrect": "まちがい", "blank": "空白", "partial": "書きかけ", "unreadable": "読めない"}
        parts = "・".join(f"{names[s]} {c[s]}" for s in STATUSES if c.get(s))
        return f"{len(self.problems)} 問（{parts}）"


def sheet_payload(res: SheetResult) -> dict[str, Any]:
    """What the game's プリント tab shows: per problem, the boxes on the 0..1000 scale of the
    image sent (so of the camera frame), and the paper's corners as 0..1 of it."""
    keys = ("number", "answer_status", "student_answer", "correct_answer", "visible", "notes", "box", "answer_box")
    paper = None
    corners, size = res.raw.get("paper_px"), res.raw.get("image") or {}
    w, h = size.get("width") or res.image.width, size.get("height") or res.image.height
    if isinstance(corners, list) and len(corners) == 4 and w and h:
        try:
            paper = [[float(x) / w, float(y) / h] for x, y in corners]
        except (TypeError, ValueError):
            paper = None
    return {"problems": [{k: p.get(k) for k in keys} for p in res.problems], "counts": res.counts,
            "summary": res.summary(), "read_anything": res.read_anything, "paper": paper,
            "notes": [str(n) for n in res.raw.get("notes") or [] if isinstance(n, str)],
            "seconds": res.raw.get("seconds"), "model": str(res.raw.get("model", "")),
            "image": {"width": res.image.width, "height": res.image.height}}


def parse_result(raw: Any, image: SheetImage) -> SheetResult:
    """Checks the answer's shape; a problem with an unknown state counts as unreadable."""
    if not isinstance(raw, dict) or not isinstance(raw.get("problems"), list):
        raise SheetError("response", "プリント読み取りの返事の形が違います")
    problems = []
    for p in raw["problems"]:
        if not isinstance(p, dict) or not isinstance(p.get("number"), int):
            continue
        q = dict(p)
        if q.get("answer_status") not in STATUSES:
            q["answer_status"] = "unreadable"
        q["student_answer"] = str(q.get("student_answer") or "")
        q["notes"] = [str(n) for n in q.get("notes") or [] if isinstance(n, str)]
        problems.append(q)
    problems.sort(key=lambda q: q["number"])
    return SheetResult(raw, image, problems)


def _token_key(url: str, token: str) -> str:
    return url + "#" + hashlib.sha256(token.encode()).hexdigest()[:16]


class SheetClient:
    # per server: one request at a time, a token the server refused, the time a 429 block ends
    _locks: dict[str, threading.Lock] = {}
    _refused: set[str] = set()
    _blocked_until: dict[str, float] = {}
    _guard = threading.Lock()

    def __init__(self, base_url: str, token: str, *, cafile: str | None = None, timeout_s: float = 180.0,
                 busy_waits_s: tuple[float, ...] = BUSY_WAITS_S, sleep: Callable[[float], None] = time.sleep,
                 opener: Callable[..., Any] | None = None) -> None:
        base = base_url.rstrip("/")
        if not base.startswith(("https://", "http://")):
            raise SheetError("config", "学習支援 AI の URL が https:// で始まっていません（study.tutor_url）")
        self.base, self.url = base, base + "/v1/sheet"
        self.token = token  # "" = none (a server started without one, #128)
        self.timeout_s = max(float(timeout_s), MIN_TIMEOUT_S)
        self.busy_waits_s, self.sleep, self.opener = tuple(busy_waits_s), sleep, opener
        self.ctx: ssl.SSLContext | None = None
        if base.startswith("https://"):
            # the server's self-signed cert.pem only; it names the server's IP and host name
            self.ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
        with SheetClient._guard:
            self.lock = SheetClient._locks.setdefault(self.base, threading.Lock())

    def _open(self, req: urllib.request.Request):
        if self.opener is not None:
            return self.opener(req, timeout=self.timeout_s)
        return urllib.request.urlopen(req, timeout=self.timeout_s, context=self.ctx)

    def _headers(self) -> dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        return h

    def read(self, photo: bytes, *, calc: bool = True, crop: bool = True, long_side: int = LONG_SIDE) -> SheetResult:
        """One photo -> the sheet's problems. Blocking (~10 s; call it in a thread from async code)."""
        image = prepare_image(photo, long_side)
        self._may_send()  # fail fast before waiting for the lock...
        body = json.dumps({"image": image.data_url, "calc": bool(calc), "crop": bool(crop)}).encode()
        with self.lock:
            self._may_send()  # ...and again: a request ahead of this one may have got a 401 / 429
            return parse_result(self._send(body), image)

    def _may_send(self) -> None:
        if _token_key(self.base, self.token) in SheetClient._refused:
            raise SheetError("auth", self.auth_problem() + "（このトークンは前に断られたので、直すまで送らない）", 401)
        wait = SheetClient._blocked_until.get(self.base, 0.0) - time.monotonic()
        if wait > 0:
            raise SheetError("blocked", f"認証の失敗が続いたためサーバがブロック中（あと約 {wait / 60:.0f} 分）", 429)

    def _send(self, body: bytes) -> Any:
        busy = list(self.busy_waits_s)
        server_retry = True
        while True:
            req = urllib.request.Request(self.url, body, self._headers(), method="POST")
            try:
                with self._open(req) as r:
                    return json.loads(r.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                err = self._http_error(e)
                if err.kind == "busy" and busy:
                    w = busy.pop(0)
                    log.info("sheet: the server is busy (503); again in %.0f s", w)
                    self.sleep(w)
                    continue
                if err.kind == "server" and server_retry:
                    server_retry = False
                    log.info("sheet: the server failed (HTTP %s); once more", err.status)
                    continue
                raise err from None
            except (OSError, ValueError) as e:  # cannot connect / timeout / certificate / not JSON
                if isinstance(e, ssl.SSLError) or isinstance(getattr(e, "reason", None), ssl.SSLError):
                    raise SheetError("network", f"証明書を確かめられません（config/secrets/tutor_cert.pem と、URL の IP）: {e}") from None
                if isinstance(e, ValueError):
                    raise SheetError("response", "プリント読み取りの返事が JSON ではありません") from None
                raise SheetError("network", f"学習支援 AI に接続できません: {e}") from None

    def _http_error(self, e: urllib.error.HTTPError) -> SheetError:
        detail = ""
        try:
            data = json.loads(e.read().decode("utf-8") or "{}")
            detail = str((data.get("error") or {}).get("message", "") or data.get("detail", ""))[:200]
        except Exception:  # noqa: BLE001 - the status says enough
            pass
        tail = f": {detail}" if detail else ""
        code = e.code
        if code == 401:
            SheetClient._refused.add(_token_key(self.base, self.token))
            return SheetError("auth", self.auth_problem() + tail, code)
        if code == 403:
            return SheetError("forbidden", "この PC の IP がサーバに許可されていない（サーバの --allow）" + tail, code)
        if code == 413:
            return SheetError("too_large", "画像が大きすぎる（4MB か 4096×4096 まで）" + tail, code)
        if code == 429:
            SheetClient._blocked_until[self.base] = time.monotonic() + BLOCK_S
            return SheetError("blocked", "認証の失敗が続いたためサーバがブロック中（10 分待つ）" + tail, code)
        if code == 503:
            return SheetError("busy", "サーバが混んでいるか、プリント用のモデルが動いていない（HTTP 503）" + tail, code)
        if code >= 500:
            return SheetError("server", f"プリントの読み取りに失敗（HTTP {code}）" + tail, code)
        return SheetError("bad_request", f"要求がまちがっている（HTTP {code}）" + tail, code)

    def auth_problem(self) -> str:
        if not self.token:
            return "学習支援 AI のサーバがトークンを求めている（config/secrets/tutor_token.txt に置く）"
        return "学習支援 AI のトークンが違う（config/secrets/tutor_token.txt とサーバのトークン）"

    @classmethod
    def forget(cls) -> None:
        """Tests: start again with no refused token, no block and no locks."""
        cls._refused.clear()
        cls._blocked_until.clear()
        cls._locks.clear()
