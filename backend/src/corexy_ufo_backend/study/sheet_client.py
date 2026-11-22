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
  - at most 2 requests at a time per server (docs/ufo_api_spec.md §9: it reads 2 sheets at once, 503 past 4)
  - `on_problem` (docs/ufo_api_spec.md §6.3, stream): the problems come one by one (the first after ~2.5 s);
    returning True from it closes the connection (the server then stops) and keeps what came
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
from dataclasses import dataclass, field, replace
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
# The answer check's second look: when the server did not cut the paper out (paper_px null: a
# light desk, shadows) and the problems take less than ZOOM_MAX_SPAN of the photo's width or
# height, the photo is cut to them (ZOOM_MARGIN of their size around) and read again: the
# handwriting is too small for the reader in a whole overview frame (26 read as "159").
ZOOM_MAX_SPAN = 0.7
ZOOM_MARGIN = 0.15


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
    image sent (so of the camera frame), the paper's corners as 0..1 of it, and the server's
    whole answer (`response`) to show as it is."""
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
            "image": {"width": res.image.width, "height": res.image.height},
            "response": res.raw}  # the server's answer as it came (no secret, no image in it)


def problems_region(problems: list[dict[str, Any]]) -> tuple[float, float, float, float] | None:
    """The problems' boxes together (0..1000 of the image read), or None without any."""
    boxes = [p.get("box") for p in problems]
    boxes = [b for b in boxes if isinstance(b, (list, tuple)) and len(b) == 4
             and all(isinstance(v, (int, float)) for v in b) and b[2] > b[0] and b[3] > b[1]]
    if not boxes:
        return None
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def zoom_region(problems: list[dict[str, Any]], margin: float = ZOOM_MARGIN,
                max_span: float = ZOOM_MAX_SPAN) -> tuple[float, float, float, float] | None:
    """Where to look again (0..1000 of the photo): the problems with a margin around, or None
    when they already fill the photo (or there are none)."""
    r = problems_region(problems)
    if r is None:
        return None
    x1, y1, x2, y2 = r
    w, h = x2 - x1, y2 - y1
    if w >= max_span * 1000 and h >= max_span * 1000:
        return None
    m = margin * max(w, h)
    return (max(x1 - m, 0.0), max(y1 - m, 0.0), min(x2 + m, 1000.0), min(y2 + m, 1000.0))


def crop_photo(data: bytes, region: tuple[float, float, float, float]) -> tuple[bytes, tuple[int, int, int, int], int, int]:
    """The photo cut to `region` (0..1000) -> (JPEG, the pixel rect, photo width, photo height)."""
    arr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if arr is None:
        raise SheetError("image", "画像として読めません")
    h, w = arr.shape[:2]
    x1, y1 = int(region[0] * w / 1000), int(region[1] * h / 1000)
    x2, y2 = int(round(region[2] * w / 1000)), int(round(region[3] * h / 1000))
    x2, y2 = max(x2, x1 + 1), max(y2, y1 + 1)
    part = arr[y1:y2, x1:x2]
    # enlarged to the long side the reader is sent at: the handwriting gets more of the
    # model's picture than in the small piece of the frame
    ph, pw = part.shape[:2]
    up = LONG_SIDE / max(pw, ph)
    if up > 1.0:
        part = cv2.resize(part, (round(pw * up), round(ph * up)), interpolation=cv2.INTER_CUBIC)
    ok, buf = cv2.imencode(".jpg", part, [cv2.IMWRITE_JPEG_QUALITY, 95])
    if not ok:
        raise SheetError("image", "画像を切り出せません")
    return buf.tobytes(), (x1, y1, x2, y2), w, h


def _boxes_back(res: SheetResult, to_frame: Callable[[float, float], tuple[float, float]], frame: SheetImage) -> list[dict[str, Any]]:
    """The problems of `res` with their boxes put on `frame`: each corner of a box (0..1000 of
    the image read) through `to_frame` (-> pixels of the photo), the box around them on the
    0..1000 scale of the photo, and its pixels in the image the photo is sent as."""
    sw, sh = frame.source_width, frame.source_height

    def back(b: Any) -> Any:
        if not (isinstance(b, (list, tuple)) and len(b) == 4 and all(isinstance(v, (int, float)) for v in b)):
            return b
        pts = [to_frame(x, y) for x in (b[0], b[2]) for y in (b[1], b[3])]
        xs, ys = [min(max(p[0], 0.0), sw) for p in pts], [min(max(p[1], 0.0), sh) for p in pts]
        return [round(min(xs) * 1000 / sw, 1), round(min(ys) * 1000 / sh, 1),
                round(max(xs) * 1000 / sw, 1), round(max(ys) * 1000 / sh, 1)]

    problems = []
    for p in res.problems:
        q = dict(p)
        for k in ("box", "answer_box"):
            q[k] = back(q.get(k))
            px = box_to_pixels(q[k], frame.width, frame.height)
            if f"{k}_px" in q and px is not None:
                q[f"{k}_px"] = list(px)
        problems.append(q)
    return problems


def map_zoomed(first: SheetResult, zoomed: SheetResult, rect: tuple[int, int, int, int],
               photo_w: int, photo_h: int) -> SheetResult:
    """The second look's answer put back on the first photo: its boxes on the 0..1000 scale
    (and in pixels) of the image first read, so whoever draws them needs to know nothing."""
    x0, y0, x1, y1 = rect
    cw, ch = x1 - x0, y1 - y0
    img = replace(first.image, source_width=photo_w, source_height=photo_h)
    problems = _boxes_back(zoomed, lambda x, y: (x0 + x * cw / 1000, y0 + y * ch / 1000), img)
    raw = dict(zoomed.raw)
    raw["problems"] = problems
    raw["image"] = first.raw.get("image") or {"width": img.width, "height": img.height}
    raw["paper_px"] = None
    raw["zoom"] = {"region": [round(x0 * 1000 / photo_w, 1), round(y0 * 1000 / photo_h, 1),
                              round(x1 * 1000 / photo_w, 1), round(y1 * 1000 / photo_h, 1)],
                   "first_counts": first.counts}
    return SheetResult(raw, first.image, problems)


# ------------------------------------------------------------------ the paper itself (#252)
# The overview camera sees the sheet small, on a desk that is dark in places and light in others
# (the server's own cut-out wants a dark desk: paper_px null). The sheet is the brightest, least
# coloured thing on the desk: found here, turned straight (a perspective warp) to the reader's long
# side and its contrast evened out (CLAHE), it is read like a scan. Measured on the real camera
# (2026-11-22): the whole frame 1 of 5 right, this 4 or 5 of 5.
PAPER_MIN_AREA = 0.03   # of the frame
PAPER_MAX_AREA = 0.95
PAPER_MIN_FILL = 0.88   # the outline's area / the rectangle around it: a sheet, not a blob
PAPER_ASPECT = (0.5, 0.95)  # short side / long side (A4 = 0.71)


def find_paper(arr: np.ndarray) -> np.ndarray | None:
    """The sheet's four corners (tl, tr, br, bl; pixels of `arr`), or None when nothing on the
    picture looks like one."""
    h, w = arr.shape[:2]
    hsv = cv2.cvtColor(arr, cv2.COLOR_BGR2HSV)
    score = hsv[..., 2].astype(np.float32) - 1.5 * hsv[..., 1].astype(np.float32)
    mask = (score >= np.percentile(score, 99.5) - 45.0).astype(np.uint8) * 255
    # only the outer outline counts (the print inside the sheet does not matter); opening cuts a
    # hand or a light floor touching it off
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((7, 7), np.uint8))
    cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cs:
        return None
    c = max(cs, key=cv2.contourArea)
    area = cv2.contourArea(c)
    if not PAPER_MIN_AREA <= area / float(w * h) <= PAPER_MAX_AREA:
        return None
    (_, _), (rw, rh), _ = cv2.minAreaRect(c)
    if rw <= 0 or rh <= 0 or area / (rw * rh) < PAPER_MIN_FILL:
        return None
    if not PAPER_ASPECT[0] <= min(rw, rh) / max(rw, rh) <= PAPER_ASPECT[1]:
        return None
    hull = cv2.convexHull(c)
    quad = None
    for eps in (0.02, 0.03, 0.04, 0.05):
        q = cv2.approxPolyDP(hull, eps * cv2.arcLength(hull, True), True)
        if len(q) == 4:
            quad = q.reshape(4, 2).astype(np.float32)
            break
    if quad is None:
        quad = cv2.boxPoints(cv2.minAreaRect(c)).astype(np.float32)
    ssum, sdiff = quad.sum(1), np.diff(quad, axis=1).ravel()
    return np.array([quad[np.argmin(ssum)], quad[np.argmin(sdiff)], quad[np.argmax(ssum)], quad[np.argmax(sdiff)]],
                    np.float32)


def paper_view(data: bytes, long_side: int = LONG_SIDE) -> tuple[bytes, np.ndarray, np.ndarray, int, int] | None:
    """The sheet straightened -> (JPEG, its corners in the photo, the warp's inverse (the sent
    image's pixels -> the photo's), photo width, photo height); None without a sheet."""
    arr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if arr is None:
        return None
    corners = find_paper(arr)
    if corners is None:
        return None
    tl, tr, br, bl = corners
    wide = (np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2.0
    tall = (np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2.0
    k = long_side / max(wide, tall)
    W, H = max(round(wide * k), 1), max(round(tall * k), 1)
    dst = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    m = cv2.getPerspectiveTransform(corners, dst)
    out = cv2.warpPerspective(arr, m, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
    lab = cv2.cvtColor(out, cv2.COLOR_BGR2LAB)
    lab[..., 0] = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(lab[..., 0])
    out = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    ok, buf = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, 95])
    if not ok:
        return None
    h, w = arr.shape[:2]
    return buf.tobytes(), corners, cv2.getPerspectiveTransform(dst, corners), w, h


def frame_image(data: bytes, long_side: int = LONG_SIDE) -> SheetImage:
    """The photo's sizes as prepare_image would send it (no JPEG: nothing is sent of it)."""
    arr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if arr is None:
        raise SheetError("image", "画像として読めません")
    sh, sw = arr.shape[:2]
    scale = min(1.0, max(min(int(long_side), MAX_SIDE), 64) / max(sw, sh))
    return SheetImage(b"", max(round(sw * scale), 1), max(round(sh * scale), 1), sw, sh)


def map_paper(res: SheetResult, frame: SheetImage, corners: np.ndarray, inverse: np.ndarray) -> SheetResult:
    """The straightened sheet's answer put on the photo (boxes, and the sheet's corners as the
    server's paper_px would be: pixels of the image the photo is sent as)."""
    pw, ph = res.image.width, res.image.height

    def to_frame(x: float, y: float) -> tuple[float, float]:
        p = cv2.perspectiveTransform(np.float32([[[x * pw / 1000, y * ph / 1000]]]), inverse)[0][0]
        return float(p[0]), float(p[1])

    problems = _boxes_back(res, to_frame, frame)
    k = frame.width / frame.source_width
    raw = dict(res.raw)
    raw["problems"] = problems
    raw["image"] = {"width": frame.width, "height": frame.height}
    raw["paper_px"] = [[round(float(x) * k, 1), round(float(y) * k, 1)] for x, y in corners]
    raw["straightened"] = {"width": pw, "height": ph}
    return SheetResult(raw, frame, problems)


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


def _cut(r: Any) -> None:
    """Ends a response being read in another thread: shuts its socket down (a blocked recv
    returns), or closes it when there is no socket to reach (a test's fake)."""
    import socket
    try:
        sock = r.fp.raw._sock  # http.client.HTTPResponse -> SocketIO -> socket
        sock.shutdown(socket.SHUT_RDWR)
        return
    except Exception:  # noqa: BLE001
        pass
    try:
        r.close()
    except Exception:  # noqa: BLE001
        pass


class SheetClient:
    # per server: at most CONCURRENCY requests at a time, a token the server refused, the time a 429 block ends
    CONCURRENCY = 2
    _locks: dict[str, threading.BoundedSemaphore] = {}
    _refused: set[str] = set()
    _blocked_until: dict[str, float] = {}
    _guard = threading.Lock()

    def __init__(self, base_url: str, token: str, *, cafile: str | None = None, timeout_s: float = 180.0,
                 busy_waits_s: tuple[float, ...] = BUSY_WAITS_S, sleep: Callable[[float], None] = time.sleep,
                 opener: Callable[..., Any] | None = None, concurrency: int | None = None) -> None:
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
            self.lock = SheetClient._locks.setdefault(
                self.base, threading.BoundedSemaphore(max(int(concurrency or SheetClient.CONCURRENCY), 1)))

    def _open(self, req: urllib.request.Request, timeout: float | None = None):
        t = self.timeout_s if timeout is None else timeout
        if self.opener is not None:
            return self.opener(req, timeout=t)
        return urllib.request.urlopen(req, timeout=t, context=self.ctx)

    def _headers(self) -> dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        return h

    def read(self, photo: bytes, *, calc: bool = True, crop: bool = True, long_side: int = LONG_SIDE,
             on_problem: Callable[[dict], bool] | None = None, deadline_s: float | None = None,
             label: str = "read") -> SheetResult:
        """One photo -> the sheet's problems. Blocking (~10 s; call it in a thread from async code).
        With `on_problem` the answer streams: it gets each problem as read; True from it ends the
        reading there (the result then has the problems so far and `raw["stopped_early"]`).
        `deadline_s` (#244): give up after that long in all, the wait for a free slot (another
        reading may hold it) included -> SheetError "timeout"; without it the socket's timeout_s."""
        image = prepare_image(photo, long_side)
        self._may_send()  # fail fast before waiting for the lock...
        body = {"image": image.data_url, "calc": bool(calc), "crop": bool(crop)}
        if on_problem is not None:
            body["stream"] = True
        data = json.dumps(body).encode()
        t0 = time.monotonic()
        end = t0 + deadline_s if deadline_s is not None else None
        got = self.lock.acquire() if end is None else self.lock.acquire(timeout=max(end - time.monotonic(), 0.0))
        if not got:
            log.info("sheet: %s gave up after %.1f s waiting for a free slot (the server is reading others)",
                     label, time.monotonic() - t0)
            raise SheetError("timeout", self.timeout_text(deadline_s))
        waited = time.monotonic() - t0
        try:
            self._may_send()  # ...and again: a request ahead of this one may have got a 401 / 429
            try:
                raw = self._send(data, on_problem, end)
            except SheetError as e:
                log.info("sheet: %s failed after %.1f s (%.1f s waiting for a slot): %s", label,
                         time.monotonic() - t0, waited, e.kind)
                if e.kind == "timeout":
                    raise SheetError("timeout", self.timeout_text(deadline_s)) from None
                raise
            log.info("sheet: %s answered in %.1f s (%.1f s waiting for a slot)", label, time.monotonic() - t0, waited)
            return parse_result(raw, image)
        finally:
            self.lock.release()

    def read_sheet(self, photo: bytes, *, calc: bool = True, crop: bool = True,
                   label: str = "read") -> SheetResult:
        """The answer check's read of a camera frame (#252): the sheet found on it, straightened
        and read alone; without one (or reading nothing) read_zoomed. Boxes on the frame."""
        view = paper_view(photo) if crop else None
        if view is not None:
            jpeg, corners, inverse, _, _ = view
            try:
                res = self.read(jpeg, calc=calc, crop=False, label=label + " (the sheet straightened)")
            except SheetError as e:
                if e.kind not in ("response",):
                    raise
                res = None
            if res is not None and res.read_anything:
                return map_paper(res, frame_image(photo), corners, inverse)
            log.info("sheet: the straightened sheet read nothing: the whole frame is read")
        return self.read_zoomed(photo, calc=calc, crop=crop, label=label)

    def read_zoomed(self, photo: bytes, *, calc: bool = True, crop: bool = True,
                    label: str = "read") -> SheetResult:
        """read(), then once more on the problems cut out of the photo when the server could not
        cut the paper out and they are small in it (see ZOOM_MAX_SPAN). The answer is on the
        first photo either way. A second look that reads nothing (or fails) keeps the first."""
        first = self.read(photo, calc=calc, crop=crop, label=label)
        region = None if first.cropped else zoom_region(first.problems)
        if region is None:
            return first
        try:
            jpeg, rect, w, h = crop_photo(photo, region)
            zoomed = self.read(jpeg, calc=calc, crop=False, label=label + " (zoomed)")
        except SheetError as e:
            log.info("sheet: the zoomed look failed (%s): the first answer is kept", e.kind)
            return first
        if not zoomed.read_anything:
            log.info("sheet: the zoomed look read nothing: the first answer is kept")
            return first
        log.info("sheet: zoomed to %s of the photo: %s -> %s", [round(v) for v in region],
                 first.summary(), zoomed.summary())
        return map_zoomed(first, zoomed, rect, w, h)

    @staticmethod
    def timeout_text(deadline_s: float | None) -> str:
        if deadline_s is None:
            return "AI が混んでいるみたい（返事が間に合わない）"
        return f"AI が混んでいるみたい（{deadline_s:g} 秒たっても返事がない）"

    def _may_send(self) -> None:
        if _token_key(self.base, self.token) in SheetClient._refused:
            raise SheetError("auth", self.auth_problem() + "（このトークンは前に断られたので、直すまで送らない）", 401)
        wait = SheetClient._blocked_until.get(self.base, 0.0) - time.monotonic()
        if wait > 0:
            raise SheetError("blocked", f"認証の失敗が続いたためサーバがブロック中（あと約 {wait / 60:.0f} 分）", 429)

    def _send(self, body: bytes, on_problem: Callable[[dict], bool] | None = None, end: float | None = None) -> Any:
        busy = list(self.busy_waits_s)
        server_retry = True
        while True:
            req = urllib.request.Request(self.url, body, self._headers(), method="POST")
            left = None if end is None else end - time.monotonic()
            if left is not None and left <= 0:
                raise SheetError("timeout", "AI が混んでいるみたい（返事が間に合わない）")
            try:
                with self._open(req, left) as r:
                    # review on #245: a read blocks between lines (or on bytes without a newline) past
                    # the socket's timeout: at the deadline the connection is cut, which ends the read
                    timer = threading.Timer(max(end - time.monotonic(), 0.0), _cut, (r,)) if end is not None else None
                    if timer is not None:
                        timer.daemon = True
                        timer.start()
                    try:
                        if on_problem is not None:
                            return self._events(r, on_problem, end)
                        return json.loads(r.read().decode("utf-8"))
                    finally:
                        if timer is not None:
                            timer.cancel()
            except urllib.error.HTTPError as e:
                err = self._http_error(e)
                if err.kind == "busy" and busy and (end is None or time.monotonic() + busy[0] < end):
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
                if end is not None and time.monotonic() >= end - 0.05 and not isinstance(e, ssl.SSLError):
                    raise SheetError("timeout", "AI が混んでいるみたい（返事が間に合わない）") from None
                if isinstance(e, ssl.SSLError) or isinstance(getattr(e, "reason", None), ssl.SSLError):
                    raise SheetError("network", f"証明書を確かめられません（config/secrets/tutor_cert.pem と、URL の IP）: {e}") from None
                if isinstance(e, ValueError):
                    raise SheetError("response", "プリント読み取りの返事が JSON ではありません") from None
                raise SheetError("network", f"学習支援 AI に接続できません: {e}") from None

    @staticmethod
    def _events(r: Any, on_problem: Callable[[dict], bool], end: float | None = None) -> dict:
        """The SSE answer (docs/ufo_api_spec.md §6.3): sheet.start, sheet.problem..., sheet.result, [DONE].
        The final sheet.result is the answer; a reading stopped early answers with what came."""
        start: dict = {}
        seen: list[dict] = []
        for raw_line in r:
            if end is not None and time.monotonic() > end:  # coming, but too slowly
                raise SheetError("timeout", "AI が混んでいるみたい（返事が間に合わない）")
            line = raw_line.decode("utf-8", "replace").strip() if isinstance(raw_line, bytes) else str(raw_line).strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            ev = json.loads(payload)
            if "error" in ev:
                msg = str((ev.get("error") or {}).get("message", ""))[:200]
                raise SheetError("server", "プリントの読み取りに失敗（途中）" + (f": {msg}" if msg else ""))
            kind = ev.get("object")
            if kind == "sheet.start":
                start = ev
            elif kind == "sheet.problem" and isinstance(ev.get("problem"), dict):
                seen.append(ev["problem"])
                if on_problem(ev["problem"]):
                    return {**start, "object": "sheet.partial", "problems": seen, "stopped_early": True,
                            "seconds": ev.get("seconds")}
            elif kind == "sheet.result":
                return ev
        raise SheetError("response", "プリント読み取りの返事が途中で終わりました（sheet.result がない）")

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
