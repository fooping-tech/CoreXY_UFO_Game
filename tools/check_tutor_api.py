"""学習支援 AI（UFOくん API）への接続テスト。ゲームを動かす PC で実行する（標準ライブラリだけ）。

    python3 tools/check_tutor_api.py --url https://192.168.100.56:8444 \
        --token-file config/secrets/tutor_token.txt --cafile config/secrets/tutor_cert.pem
    （このリポジトリの最上位で。--url などを省くと config の study.tutor_* を使う）

1 つずつ確かめ、だめなところで止まって、原因の候補と直し方を表示する:
  1. TCP 接続（IP・ポート・同じネットワークか・ファイアウォール）
  2. TLS（証明書）
  3. /api/health（認証なし。403 なら接続元の IP が許可されていない）
  4. /v1/models（トークン）
  5. 推論 3 種（layout / 番号を指定した指導 / 発言から対象を決める指導）と応答時間
トークンは画面に出さない。終了コード 0 = すべて OK。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent  # tools/: samples/worksheet_sample.jpg
REPO = HERE.parent


def study_config() -> dict:
    """study.* of config/game_config.json under config/local_settings.json (the settings screen)."""
    out: dict = {}
    for name in ("game_config.json", "local_settings.json"):
        try:
            d = json.loads((REPO / "config" / name).read_text(encoding="utf-8")).get("study", {})
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(d, dict):
            out.update(d)
    return out
OK, NG = "OK", "NG"


def line(mark, name, msg=""):
    print(f"[{mark}] {name}" + (f" … {msg}" if msg else ""))


def main():
    st = study_config()
    under = lambda p: str(REPO / p) if p and not Path(p).is_absolute() else (p or "")  # noqa: E731
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get("TUTOR_API_URL", st.get("tutor_url") or "https://127.0.0.1:8444"))
    ap.add_argument("--token-file", default=os.environ.get("TUTOR_API_TOKEN_FILE", under(st.get("tutor_token_file", ""))))
    ap.add_argument("--cafile", default=os.environ.get("TUTOR_API_CAFILE", under(st.get("tutor_cafile", ""))),
                    help="サーバの cert.pem（https のとき）")
    ap.add_argument("--image", default=str(HERE / "samples" / "worksheet_sample.jpg"))
    ap.add_argument("--timeout", type=float, default=30)
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    token = os.environ.get("TUTOR_API_TOKEN", "")
    if a.token_file:
        if not Path(a.token_file).exists():
            print(f"トークンのファイルがありません: {a.token_file}\n  → 学習支援 AI の PC から受け取ったトークンを、"
                  "このファイルに 1 行で保存する（Git・チャットには貼らない。config/secrets/ は Git に入らない）")
            return 1
        token = Path(a.token_file).read_text(encoding="utf-8").strip()
    if a.cafile and not Path(a.cafile).exists():
        print(f"証明書のファイルがありません: {a.cafile}\n  → 学習支援 AI の PC の server/secrets/cert.pem"
              "（公開してよい方。key.pem は渡さない）をここに置く")
        return 1
    u = urllib.parse.urlparse(a.url)
    host, port = u.hostname, u.port or (443 if u.scheme == "https" else 80)
    print(f"接続先: {u.scheme}://{host}:{port}（トークン: {'あり' if token else 'なし'}、証明書: {a.cafile or 'なし'}）\n")

    # 1. TCP
    try:
        socket.create_connection((host, port), timeout=3).close()
        line(OK, "1. TCP 接続")
    except OSError as e:
        line(NG, "1. TCP 接続", str(e))
        print("  → 確認: 学習支援 AI の PC が起動しているか（uv run python server/tutor_app.py）/ IP アドレスが正しいか"
              "（ネットワークが変わると IP も変わる。サーバの起動時の表示を見る）/ 同じネットワーク（同じ Wi-Fi）か /"
              " サーバの PC のファイアウォールでポートが許可されているか")
        return 1

    # 2. TLS
    ctx = None
    if u.scheme == "https":
        if a.cafile:
            ctx = ssl.create_default_context(cafile=a.cafile)
            ctx.check_hostname = False  # IP で接続し、証明書は cert.pem そのものを信頼する
        else:
            ctx = ssl.create_default_context()
        try:
            with socket.create_connection((host, port), timeout=3) as s, ctx.wrap_socket(s, server_hostname=host):
                pass
            line(OK, "2. TLS（証明書）")
        except ssl.SSLError as e:
            line(NG, "2. TLS（証明書）", str(e)[:160])
            print("  → --cafile にサーバの server/secrets/cert.pem（公開してよい方。key.pem は渡さない）を指定する。"
                  "サーバが証明書を作り直したら、cert.pem も取り直す")
            return 1

    def req(path, body=None, auth=True):
        h = {"Content-Type": "application/json"}
        if auth:
            h["Authorization"] = "Bearer " + token
        r = urllib.request.Request(a.url.rstrip("/") + path, json.dumps(body).encode() if body is not None else None, h)
        t0 = time.time()
        with urllib.request.urlopen(r, timeout=a.timeout, context=ctx) as resp:
            return resp.status, json.load(resp), time.time() - t0

    # 3. health
    try:
        req("/api/health", auth=False)
        line(OK, "3. /api/health")
    except urllib.error.HTTPError as e:
        line(NG, "3. /api/health", f"HTTP {e.code}")
        if e.code == 403:
            print("  → この PC の IP がサーバの許可リストにない。サーバ側で --allow <このPCのIP>/32 を付けて起動し直す"
                  "（既定は、サーバと同じ物理 LAN のサブネットだけ。VPN 経由は不可）")
        return 1
    except Exception as e:  # noqa: BLE001
        line(NG, "3. /api/health", str(e)[:160]); return 1

    # 4. token
    try:
        _, models, _ = req("/v1/models")
        line(OK, "4. トークン（/v1/models）", ", ".join(m["id"] for m in models["data"]))
    except urllib.error.HTTPError as e:
        line(NG, "4. トークン（/v1/models）", f"HTTP {e.code}")
        print("  → 401: トークンが違う（サーバの server/secrets/token.txt と同じか。前後の空白・改行に注意）。"
              "429: 失敗が続いたため 10 分ブロック中。少し待ってから")
        return 1

    # 5. 推論
    img = "data:image/jpeg;base64," + base64.b64encode(Path(a.image).read_bytes()).decode()
    msgs = [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}}]}]
    cases = [("5a. 問題の位置（layout）", {"target_problem": None, "grade": 1, "format": "layout"}),
             ("5b. 番号を指定した指導（4ばん）", {"target_problem": 4, "grade": 1}),
             ("5c. 発言から対象を決める（「4ばんが わからない」）", {"target_problem": None, "grade": 1, "utterance": "4ばんが わからない"})]
    worst, bad = 0.0, 0
    for name, ext in cases:
        try:
            _, d, sec = req("/v1/chat/completions", {"model": "tutor-ufo", "max_tokens": 400, "messages": msgs, "tutor": ext})
            tr = d["tutor_result"]
            worst = max(worst, sec)
            if "layout" in tr:
                line(OK, name, f"{sec:.1f} 秒・写っている問題 {[p['number'] for p in tr['layout']['problems']]}")
            else:
                g = tr["game"]
                line(OK, name, f"{sec:.1f} 秒・{g['action']}（{g['target_problem']}）「{g['message'][:30]}」")
        except urllib.error.HTTPError as e:
            bad += 1
            line(NG, name, f"HTTP {e.code}")
            print("  → 503: 混雑（同時に 4 件以上）。500: サーバの PC で Ollama が動いているか（ollama list に tutor-ufo があるか）")
        except Exception as e:  # noqa: BLE001
            bad += 1
            line(NG, name, str(e)[:160])
            print("  → 時間切れなら、サーバの PC の GPU が省電力モードになっていないか（1 回 2〜5 秒が目安。初回だけ読み込みで 10 秒ほど）")
    print()
    if bad:
        print("推論に失敗したものがあります。ゲームは既存のフォールバック（プリントのヒント）で動きます。")
        return 1
    print(f"すべて OK（いちばん遅い応答 {worst:.1f} 秒）。ゲームの study.tutor_timeout_s は {max(20, round(worst * 3))} 秒以上を推奨。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
