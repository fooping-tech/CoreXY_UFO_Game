# UFOくん API 仕様書（API を呼ぶ側の PC 向け）

この文書は、UFOくん API サーバ（`server/tutor_app.py`）を、別の PC から呼ぶ人とプログラムのための仕様書です。
この文書だけでクライアントを実装できるように書いています。サーバ側のコードは変更しないでください。

- サーバの中身：ファインチューニングした Gemma 4 E2B を Ollama で動かし、FastAPI のサーバが入力の確認と出力の検証をしています。
- できること：
  1. **会話・指導**（`POST /v1/chat/completions`）：OpenAI 互換。プリントの写真と子どもの発言から、ヒントなどの指導を返す。
  2. **プリントの読み取り**（`POST /v1/sheet`）：プリント 1 枚の写真から、問題ごとの位置と、答えの状態（正解・まちがい・空白など）を返す。
- サーバは、ロボット（UFO・モーター）を動かしません。返すのは「指導の内容」と「動かす提案」だけです。

## 目次

1. [接続に必要なもの](#1-接続に必要なもの)
2. [パスの一覧](#2-パスの一覧)
3. [共通の決まり（認証・エラー・混雑）](#3-共通の決まり認証エラー混雑)
4. [接続の確認](#4-接続の確認)
5. [会話・指導：POST /v1/chat/completions](#5-会話指導post-v1chatcompletions)
6. [プリントの読み取り：POST /v1/sheet](#6-プリントの読み取りpost-v1sheet)
7. [モデルの一覧：GET /v1/models](#7-モデルの一覧get-v1models)
8. [監視用のパス](#8-監視用のパス)
9. [時間・同時実行・タイムアウト](#9-時間同時実行タイムアウト)
10. [結果の信頼度と、データの扱い](#10-結果の信頼度とデータの扱い)
11. [実装が終わったら確かめること](#11-実装が終わったら確かめること)
12. [困ったとき](#12-困ったとき)

---

## 1. 接続に必要なもの

サーバの管理者から、次の 3 つを受け取ってください。この文書には値を書いていません。

| 必要なもの | 内容 | 扱い |
|---|---|---|
| ベース URL | `https://<サーバの IP>:8444`（ポートの既定は 8444） | 設定値にする。コードに埋め込まない |
| トークン | `Authorization: Bearer <トークン>` で送る文字列 | 秘密。環境変数などで渡し、リポジトリやログに書かない |
| `cert.pem` | サーバの自己署名証明書（配ってよいファイル） | TLS の検証に使う |

おすすめの環境変数名：`UFO_API_BASE`、`UFO_API_TOKEN`、`UFO_API_CERT`。

接続の制約：

- **同じ LAN からだけ使えます。** サーバは接続元の IP を見て、許可した範囲（既定はサーバ PC の LAN のサブネット）の外からは、どのパスでも `403 {"detail": "forbidden"}` を返します。別のサブネットから使うときは、管理者に許可の範囲を足してもらってください。
- **HTTPS は自己署名証明書です。** `cert.pem` を「信頼する証明書」として渡してください。証明書に入っている名前は、サーバの IP・ホスト名・`localhost` です。必ずその IP かホスト名で接続してください。
- `verify=False`（検証なし）は使わないでください。
- サーバの IP が変わると、証明書は作り直されます。そのときは新しい `cert.pem` を受け取ってください。

## 2. パスの一覧

| メソッドとパス | 内容 | トークン |
|---|---|---|
| `GET /api/health` | サーバが動いているか | 不要 |
| `GET /api/auth` | トークンが必要な設定か | 不要 |
| `GET /v1/models` | 会話用のモデルの一覧 | 必要 |
| `GET /v1/models/{name}` | 会話用のモデル 1 件 | 必要 |
| `POST /v1/chat/completions` | 会話・指導（OpenAI 互換 + `tutor` 拡張） | 必要 |
| `POST /v1/sheet` | プリント 1 枚の読み取り | 必要 |
| `GET /api/monitor` | CPU・GPU・メモリの使用状況 | 必要 |
| `GET /api/requests` | 受付記録の一覧（新しい順、100 件まで） | 必要 |
| `GET /api/requests/{id}` | 受付記録 1 件のくわしい内容 | 必要 |
| `GET /` | 人が見るための画面（ブラウザ用） | 画面でログイン |

OpenAI の SDK から使うときは、`base_url` を `https://<サーバの IP>:8444/v1`、`api_key` をトークンにします。

## 3. 共通の決まり（認証・エラー・混雑）

### 認証

```
Authorization: Bearer <トークン>
```

- トークンがない・ちがうと `401` です。
- **同じ IP から 10 分間に 10 回まちがえると、その IP は 10 分間 `429` になります。401 が返ったら再試行せず、止めて管理者に確認してください。**
- サーバがトークンなしの設定（`--no-auth`）で動いているときは、`GET /api/auth` が `{"token_required": false}` を返し、`Authorization` は不要です（付けても害はありません）。

### エラーの形

`/v1/` で始まるパスは、OpenAI と同じ形です。

```json
{"error": {"message": "トークンが正しくありません", "type": "authentication_error", "param": null, "code": null}}
```

`/api/` で始まるパスは `{"detail": "..."}` の形です。接続元の IP が許可の外のときは、どのパスでも `403 {"detail": "forbidden"}` です。

| 状態 | `type` | いつ | クライアントの動き |
|---|---|---|---|
| 400 | `invalid_request_error` | 要求の形がちがう（必須のフィールドがない、範囲の外、画像が data URL でない、など）。`message` は `"<フィールド名>: <理由>"` | 要求を直す。再試行しない |
| 401 | `authentication_error` | トークンがない・ちがう | **再試行しない** |
| 403 | （`{"detail": "forbidden"}`） | 接続元の IP が許可の外 | 再試行しない。ネットワークを確認 |
| 404 | `not_found_error` | モデル名・記録の ID がない | — |
| 413 | `invalid_request_error` | 画像が 4MB か 4096×4096 画素をこえた | 縮めて送り直す |
| 429 | `rate_limit_error` | 認証の失敗が続いてブロック中 | 10 分待つ |
| 500 | `server_error` | 生成に失敗 | 1 回だけ再試行してよい |
| 503 | `server_error` | 混んでいる。または、プリント用のモデルがサーバにない | 間をあけて再試行（例：5 秒、10 秒、20 秒） |

### 混雑（503）

会話とプリントの読み取りは、別べつに順番を待ちます。それぞれ、**処理中と待ちを合わせて 4 件まで**で、次の要求は `503`（「混み合っています。しばらくしてから再度お試しください。」）になります。くわしくは「9. 時間・同時実行・タイムアウト」。

### 画像の決まり（会話・プリントで共通）

- `data:image/<形式>;base64,<データ>` の形だけ受け付けます。`http(s)://` の URL は受け付けません（400）。
- デコード後のサイズは **4MB まで**、画素数は **4096×4096 まで**（こえると 413）。
- 形式は JPEG・PNG など。JPEG を推奨します。
- **EXIF の回転はサーバで反映されません。** スマートフォンの写真は、回転を画素に反映してから送ってください（Pillow なら `ImageOps.exif_transpose`）。そのままだと、横倒しの画像として読まれます。
- サーバは最後に約 65 万画素まで縮めてからモデルに送ります。長辺 1,600〜2,000 画素より大きい画像を送っても精度は上がらないので、クライアント側で縮めてから送ってください。

知らないフィールドは、どの要求でも無視されます。

## 4. 接続の確認

```
GET /api/health   →  200 {"ok": true}
GET /api/auth     →  200 {"token_required": true}
```

どちらもトークン不要です。まずこれで、ネットワークと証明書が正しいことを確かめてください。

```bash
curl --cacert cert.pem "$UFO_API_BASE/api/health"
```

---

## 5. 会話・指導：POST /v1/chat/completions

OpenAI の Chat Completions と同じ形で使えます。独自の `tutor` フィールドを付けると、サーバが学習時と同じ指示文を作り、検証ずみの結果（`tutor_result`）を付けて返します。**指導に使うときは、`tutor` を付けてください。**

### 5.1 要求

```json
{
  "model": "tutor-ufo",
  "messages": [
    {"role": "user", "content": [
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}},
      {"type": "text", "text": ""}
    ]}
  ],
  "tutor": {"grade": 3, "target_problem": 2, "mode": "normal", "history": [], "utterance": "わからない"}
}
```

| フィールド | 型 | 既定 | 意味・制限 |
|---|---|---|---|
| `messages` | 配列（必須） | — | 1〜12 件。**最後は `user`** であること |
| `messages[].role` | 文字列 | — | `system` / `developer` / `user` / `assistant` |
| `messages[].content` | 文字列 または 配列 | — | 配列のときは `{"type": "text", "text": "..."}` と `{"type": "image_url", "image_url": {"url": "data:..."}}`。画像は `user` だけ。文字は 1 件あたり 2000 文字まで。画像は全体で **3 枚まで** |
| `model` | 文字列 | — | 無視されます（サーバで決めた 1 つのモデルだけが使われます） |
| `max_tokens` / `max_completion_tokens` | 整数 | 512 | 1〜1024 |
| `temperature` | 数 | 0.0 | 0〜2 |
| `top_p` | 数 | — | 0 より大きく 1 まで |
| `stop` | 文字列 または 配列 | — | 4 つまで |
| `stream` | 真偽 | `false` | `true` で SSE（5.4） |
| `stream_options` | オブジェクト | — | `{"include_usage": true}` で、最後にトークン数を返す |
| `n` | 整数 | 1 | 1 だけ |
| `tutor` | オブジェクト | — | 独自の拡張（5.2） |

`system` を省くと、サーバが学習時の system プロンプトを入れます。ふつうは省いてください。

### 5.2 `tutor` 拡張

| フィールド | 型 | 既定 | 意味 |
|---|---|---|---|
| `grade` | 整数（必須） | — | 学年。1〜6 |
| `target_problem` | 整数 または `null` | `null` | 対象の問題の番号（1〜30）。**省くと、子どもの発言と写っている問題から、モデルが対象を決めます** |
| `format` | 文字列 | `"tutor"` | `"tutor"`：指導。`"layout"`：写っている問題の番号と位置だけ。`"dialog"`：UFOくんのせりふ（ふつうの文）で会話 |
| `mode` | 文字列 | `"normal"` | `"normal"`：答えは教えない。`"reveal_allowed"`：答えの解説をしてよい |
| `history` | 配列 | `[]` | この問題で、これまでに出したヒント。6 件まで。各要素は `{"hint_level": 0〜3, "message": "200 文字まで"}` |
| `utterance` | 文字列 または `null` | `null` | 子どもの発言（音声認識の結果など）。100 文字まで |

`tutor` を付けたときの決まり：

- 最後の `user` メッセージの**文字は、サーバが作る指示文に置きかえられます**（画像はそのまま使います）。文字は空でかまいません。
- `format: "dialog"` のときは、1 つ目の `user`（画像つき）が指示文になり、2 つ目からの `user`（子どもの発言）と `assistant`（UFOくんのせりふ）は、そのまま会話として使われます。会話を続けるときは、それまでのやりとりを `messages` に入れて送ってください（12 件まで）。

### 5.3 応答（`stream` なし）

```json
{
  "id": "chatcmpl-3f9a1c2b7d4e",
  "object": "chat.completion",
  "created": 1795000000,
  "model": "tutor-ufo",
  "choices": [{"index": 0, "message": {"role": "assistant", "content": "{\"observation\": ...}"}, "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 350, "completion_tokens": 120, "total_tokens": 470},
  "tutor_result": { ... }
}
```

（数値は形を示すための例です）

- `choices[0].message.content` は、モデルが出した文字そのままです（`tutor` 形式では JSON の文字列）。
- **`tutor` を付けたときは、`content` ではなく `tutor_result` を使ってください。** `tutor_result` は、サーバが形を確かめ、安全のための直しをした結果です。
- `finish_reason` は `"stop"` か `"length"`（`max_tokens` で切れた）。

#### `tutor_result` の形

`format` と `target_problem` の組み合わせで、入るキーが変わります。

| 要求 | `tutor_result` のキー |
|---|---|
| `format: "tutor"`、`target_problem` あり | `tutor`、`game`、`corexy`、`notes` |
| `format: "tutor"`、`target_problem` なし（自動） | 上に加えて `target`、`utterance_number`。場合により `navigate` |
| `format: "layout"` | `layout`、`notes` |
| `format: "dialog"` | `dialog`、`game`、`notes` |

`notes` は、サーバが直したことの記録（文字列の配列）です。空でなければ、ログに残すことをおすすめします。

**`game`（ゲームや画面でそのまま使う形。ふつうはこれを使ってください）**

| フィールド | 型 | 意味 |
|---|---|---|
| `action` | 文字列 | 下の表のどれか |
| `target_problem` | 整数 または `null` | 対象の問題の番号。自動で決められなかったときは `null` |
| `hint_level` | 整数 | ヒントの強さ。0〜3 |
| `message` | 文字列 | 子どもに伝えることば。80 文字まで（`dialog` は 200 文字まで） |
| `need_recapture` | 真偽 | 撮り直しが必要か |
| `visual_effect` | 文字列 | 演出の種類：`thinking` / `celebrate` / `encourage` / `recapture` / `explain` |
| `target_box` | `[x1, y1, x2, y2]` または `null` | （自動のときだけ）対象の問題の枠。画像の幅と高さをそれぞれ 1000 とした目盛り |
| `visible_problems` | 整数の配列 | （自動のときだけ）写っている問題の番号 |
| `camera_move` | オブジェクト または `null` | （自動のときだけ）カメラを動かす提案 `{"direction", "distance_mm"}`。`action` が `move_camera` のときだけ入る |
| `navigate` | オブジェクト | （場合により）目的の問題が写っていないときの、動く向きの計算。`{"kind", "direction", "offset"}`（下を参照） |

`action` の値：

| 値 | 意味 |
|---|---|
| `give_hint` | ヒントを出す |
| `praise` | ほめる（正解） |
| `prompt_start` | まだ書いていない子に、始め方をうながす |
| `explain_solution` | 答えの解説（`mode: "reveal_allowed"` のときだけ） |
| `request_recapture` | 読めないので、撮り直しをお願いする |
| `clarify` | 子どもの発言の意味を聞き返す |
| `ask_which` | どの問題かを聞き返す（自動のときだけ） |
| `move_camera` | カメラを動かす提案（自動のときだけ） |
| `talk` | 会話のせりふ（`format: "dialog"` のときだけ） |

**`tutor`（モデルの判断のくわしい中身）**

```json
{
  "observation": {"problem_number": 2, "problem_text": "38 + 47", "student_work": "", "student_answer": "75",
                  "solution": "38 + 47 = 85", "correct_answer": "85", "answer_status": "incorrect", "readable": true},
  "diagnosis": {"error_type": "procedural", "misconception": "くり上がりを たしていない", "confidence": 0.8},
  "guidance": {"action": "give_hint", "hint_level": 1, "message": "一のくらいの たし算を もういちど 見てみよう。", "reveal_answer": false}
}
```

（内容は形を示すための例です）

- `answer_status`：`correct` / `incorrect` / `partial`（書きかけ）/ `blank`（空白）/ `unreadable`（読めない）
- `error_type`：`conceptual` / `procedural` / `careless` / `none` / `unknown`
- `solution`・`correct_answer` は、入らないことがあります。**`mode: "normal"` のときは、これらを子どもに見せないでください**（答えが入っています）。子どもに伝えるのは `message` だけです。
- 自動のときは `target` も入ります。対象が決まらなかったときは、`observation` と `diagnosis` はなく、`target` と `guidance` だけです。

**`target`（自動のときだけ）**

| フィールド | 意味 |
|---|---|
| `problem_number` | 決めた問題の番号。決められなかったときは `null` |
| `how` | どう決めたか：`utterance_number`（発言の番号）/ `utterance_position`（「上から 2 つ目」など）/ `only_visible`（1 問だけ写っている）/ `ambiguous`（決められない）/ `camera_request`（カメラへのお願いだった） |
| `visible_problems` | 写っている問題の番号 |
| `box` | 対象の問題の枠（1000 分率）または `null` |

`utterance_number` は、サーバが発言から規則で読み取った番号です（「3 ばん」「(3)」「③」など。なければ `null`）。

**`corexy`（CoreXY UFO Game の解説 JSON に合わせた形）**

`problem_number`、`recognized_problem`、`confidence`、`hint`、`explanation`、`speech_text`（80 文字まで）、`needs_confirmation`、`tutor_action`、`hint_level`、`visual_effect`、`ufo_face`（`normal` / `excited` / `happy` / `worried` / `wink`）、`answer_status`。自動のときは `target_box` も入ります。

**`layout`（`format: "layout"`）**

```json
{"problems": [{"number": 1, "box": [90, 120, 910, 260], "answer_box": [600, 180, 880, 250], "visible": "full"}]}
```

座標は、画像の幅と高さをそれぞれ 1000 とした `[x1, y1, x2, y2]`（左上が原点）。`answer_box` は `null` のことがあります。`visible` は `"full"` か `"partial"`（見切れている）。

**`dialog`（`format: "dialog"`）**

`{"message": "<UFOくんのせりふ>"}`。同じ文が `game.message`（200 文字まで）にも入ります。

**`camera_move` と `navigate`（カメラを動かす提案）**

- `camera_move`：`direction` は `up` / `down` / `left` / `right`（画像の上下左右）/ `winch_up`（はなれる）/ `winch_down`（近づく）。`distance_mm` は 10〜60 の 10 きざみ（`winch_*` のときは `null`）。
- `navigate`：対象の番号は分かっているのに写っていないとき、サーバが同じ画像で問題の位置を調べ、動く向きを計算したもの。
  - `kind`：`move`（`offset` の向きへ動かして撮り直す）/ `uncover`（手や物でかくれている。動かさずに、どけてもらう）/ `zoom_out`（手がかりがない。全体を撮り直す）/ `none`（もう写っている）
  - `offset`：画像の中心から、目的の問題の中心までのずれ `[dx, dy]`（1000 = 画像の幅または高さ）。`direction` は `up` か `down`。
  - `tutor_result.navigate` には、くわしい中身（`estimated_center`、`pitch`、`based_on`、`seen` など）が入ります。
- **どちらも「提案」です。** mm やアームの座標への変換、動かせる範囲と 1 回の移動量の上限の確認、手が近くにないかの確認、実際に動かすかどうかの判断は、受け取った側で行ってください。

#### サーバが行う安全のための直し

- モデルの出力が決まった形でないときは、安全な既定の応答（撮り直しのお願い・聞き返し）に置きかえます。
- `mode: "normal"` で、モデルが答えを教えようとしたときは、ヒントに置きかえます。
- `message` が長いときは、80 文字に切りつめます。
- 子どもがはっきり番号を言ったのに、モデルが別の問題を選んだときは、その番号を指定して聞き直します。
- 何も出さずに終わったときは、1 回だけやり直します。

これらの直しをしたときは、`notes` に理由が入ります。聞き直しややり直しは追加の推論なので、そのぶん時間がかかります。

### 5.4 ストリーミング（`"stream": true`）

応答は `Content-Type: text/event-stream`（SSE）で、OpenAI と同じ形のチャンクが届きます。

```
data: {"id": "chatcmpl-...", "created": 1795000000, "model": "tutor-ufo", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": null}]}

data: {..., "choices": [{"index": 0, "delta": {"content": "一の"}, "finish_reason": null}]}

data: {..., "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}

data: {..., "choices": [], "usage": {"prompt_tokens": 350, "completion_tokens": 120, "total_tokens": 470}}

data: {..., "choices": [], "tutor_result": { ... }}

data: [DONE]
```

- `usage` のチャンクは、`stream_options.include_usage` が `true` のときだけ届きます。
- `tutor_result` のチャンクは、`tutor` を付けたときだけ届きます（`choices` は空の配列）。
- 生成の途中で失敗したときは、`data: {"error": {"message": "生成に失敗しました", "type": "server_error"}}` が届いて終わります（HTTP の状態は 200 のままです）。`[DONE]` が届かずに終わったときも、失敗として扱ってください。
- クライアントが接続を切ると、サーバは生成を止めます。
- **注意：ストリーミングでは、5.3 の「聞き直し」「やり直し」「`navigate` の計算」は行われません**（形の確認と、答えを教えない直しは行われます）。`format: "tutor"` と `"layout"` は JSON が 1 つ返るだけなので、**`stream` なしで使うことをおすすめします。** ストリーミングが役に立つのは、`format: "dialog"` と、`tutor` なしの会話です。

### 5.5 呼び出しの例

```python
import base64, io, os
import httpx
from PIL import Image, ImageOps

BASE = os.environ["UFO_API_BASE"]      # 例: https://192.168.x.x:8444
TOKEN = os.environ["UFO_API_TOKEN"]
CERT = os.environ["UFO_API_CERT"]      # cert.pem のパス
http = httpx.Client(verify=CERT, timeout=180, headers={"Authorization": f"Bearer {TOKEN}"})


def data_url(path: str, long_side: int = 1800) -> str:
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")  # EXIF の回転を画素に反映する
    im.thumbnail((long_side, long_side))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def tutor(path: str, grade: int, utterance: str | None = None, target: int | None = None, history=()) -> dict:
    r = http.post(f"{BASE}/v1/chat/completions", json={
        "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": data_url(path)}}]}],
        "tutor": {"grade": grade, "target_problem": target, "utterance": utterance, "history": list(history)},
    })
    if r.status_code == 401:
        raise RuntimeError("トークンが正しくありません（再試行しないこと）")
    r.raise_for_status()
    return r.json()["tutor_result"]


res = tutor("print.jpg", grade=3, utterance="2ばんが わからない")
print(res["game"]["action"], res["game"]["message"])
```

同じ問題でヒントを重ねるときは、前に返った `game.hint_level` と `game.message` を `history` に足して、次の要求に入れてください。

OpenAI の SDK から使うとき（`tutor` は `extra_body` で渡します）：

```python
import httpx
from openai import OpenAI

client = OpenAI(base_url=f"{BASE}/v1", api_key=TOKEN, http_client=httpx.Client(verify=CERT, timeout=180))
resp = client.chat.completions.create(
    model="tutor-ufo",
    messages=[{"role": "user", "content": [{"type": "image_url", "image_url": {"url": data_url("print.jpg")}}]}],
    extra_body={"tutor": {"grade": 3, "target_problem": 2}},
)
result = resp.model_extra["tutor_result"]
```

---

## 6. プリントの読み取り：POST /v1/sheet

プリント 1 枚の写真から、写っている問題ごとの位置と、答えの状態を返します。会話用とは別のモデル（`tutor-ufo-v6-sheet`）を使います。1 回の呼び出しで、モデルの推論は 1 回です。

### 6.1 要求

```json
{"image": "data:image/jpeg;base64,/9j/4AAQ...", "calc": true, "crop": true, "stream": false}
```

| フィールド | 型 | 既定 | 意味 |
|---|---|---|---|
| `image` | 文字列（必須） | — | 画像 1 枚（data URL）。決まりは「3. 画像の決まり」 |
| `calc` | 真偽 | `true` | モデルが書いた式をサーバが計算し直して、正解・まちがいの判定を確かめる。食いちがったら判定を直し、`notes` に理由を入れる |
| `roi` | `[x1, y1, x2, y2]` | なし | この範囲だけを読む（送る画像の幅と高さを 1000 とした値）。カメラが固定で、プリントを置く場所が決まっているときに使う（6.1.1）。指定すると外形は探さず、範囲をそのまま切り出してモデルに送る。0〜1000 の範囲で `x1 < x2`・`y1 < y2`、幅と高さが 50 以上でないと 400 |
| `crop` | 真偽 | `true` | `roi` がないとき、写真からプリントの外形を見つけ、切り出してからモデルに送る（引きで写した写真で、字が小さくなるのを防ぐ） |
| `stream` | 真偽 | `false` | `true` にすると、読み取れた問題から順に 1 問ずつ返す（6.3） |

プリントが正立し、紙の全体が写っている写真を、1 回に 1 枚送ってください。

#### 6.1.1 固定したカメラから送るとき（このゲームの俯瞰カメラ、#298）

サーバの管理者の手順書（§3.1、Logicool C270 で台を真上から写して確かめた内容）。ゲームはこのとおりに送る。

| 項目 | すること | このゲームでは |
|---|---|---|
| 解像度 | カメラのいちばん大きい 4:3（C270 なら 1280×960 を明示） | 学習モードの間だけ俯瞰カメラに `study.sheet_camera_size`（1280×960）を求め、終わったら元に戻す（ジェスチャーがバックエンドで同じカメラを 640×480 で読むため） |
| 向き | 文字が正しい向き（上が上）に回してから送る（学習した傾きは ±15° まで） | 設定画面のプリントタブの「向き」 |
| 縮小・形式 | 縮めずに、JPEG（品質 90 以上） | 長辺 2000 まではそのまま、品質 0.95→0.92→0.90。WebSocket に入らないときだけ品質 90 のまま小さくする。バックエンドはその JPEG を作り直さずに送る |
| 範囲 | `roi` でプリントを置く場所を指定（上下左右に 5% ほど広め） | プリントタブの「読む範囲」が `roi`。「読む範囲 ＝ おく場所＋5%」ボタンで決められる。返る枠はバックエンドが読む範囲の中の 0〜1000 に直す |
| 送るとき | 映像が落ち着いてから（手が写っていない・前に送った画像から変わっていない） | 32×24 の灰色の縮小で、1 秒動いていないことを確かめてから送る。見守りは前に送った画像と同じなら送らない。答え合わせは最大 6 秒、HELP は最大 3 秒待って、それでも動いていれば送る。止まっている手は見分けられない |
| 置き方 | 台に目印をつけるか、画面で案内して、傾き 15° 以内に置いてもらう | 学習モードの「ここへおいてね！」をプリントタブの「おく場所」に出す |
| カメラを開いた直後 | 最初の数コマ（真っ暗・露出が落ち着く前）は送らない | 映像が来てから 2 秒と、真っ暗な映像は送らない |

`roi` を指定したときは、応答に `roi_px`（その範囲の四隅 `[左上, 右上, 右下, 左下]`、送った画像のピクセル）が入り、`paper_px` は `null`。範囲の決め方はサーバのテストページ `https://<サーバ>:8444/sheetcam` でもできる。

### 6.2 応答（`stream` なし）

```json
{
  "id": "sheet-3f9a1c2b7d4e",
  "object": "sheet.result",
  "created": 1795000000,
  "model": "tutor-ufo-v6-sheet",
  "image": {"width": 1200, "height": 1600},
  "paper_px": [[102, 88], [1100, 95], [1108, 1510], [96, 1502]],
  "problems": [
    {
      "number": 1,
      "box": [90, 120, 910, 260],
      "answer_box": [600, 180, 880, 250],
      "visible": "full",
      "answer_status": "incorrect",
      "student_answer": "42",
      "correct_answer": "45",
      "notes": [],
      "box_px": [108, 192, 1092, 416],
      "answer_box_px": [720, 288, 1056, 400]
    }
  ],
  "counts": {"correct": 0, "incorrect": 1, "blank": 0, "partial": 0, "unreadable": 0},
  "unsolved": {"blank": [], "partial": [], "incorrect": [1], "unreadable": []},
  "notes": [],
  "seconds": 9.8
}
```

（数値は形を示すための例です）

| フィールド | 意味 |
|---|---|
| `image` | サーバが受け取った画像の幅と高さ（ピクセル）。座標の基準 |
| `paper_px` | 切り出したときの、プリントの四隅 `[左上, 右上, 右下, 左下]`（送った画像のピクセル）。切り出さなかったとき（`roi` を指定した、`crop: false`、外形が見つからない、もう画面いっぱいに写っている）は `null` |
| `roi_px` | `roi` を指定したときの、その範囲の四隅 `[左上, 右上, 右下, 左下]`（送った画像のピクセル）。指定しなかったときは `null` |
| `problems` | 写っている問題。番号の小さい順。プリントが写っていない・出力がこわれていたときは空の配列 |
| `counts` | 状態ごとの問題数 |
| `unsolved` | 正解でない問題の番号を、状態ごとに分けたもの |
| `notes` | 1 枚全体についての注記 |
| `seconds` | サーバでかかった秒数 |

`problems` の各要素：

| フィールド | 型 | 意味 |
|---|---|---|
| `number` | 整数 | プリントに印刷された問題の番号 |
| `box` | `[x1, y1, x2, y2]` | 問題の枠。**送った画像の幅と高さをそれぞれ 1000 とした目盛り**（左上が原点） |
| `answer_box` | 同上 または `null` | 答えのらんの枠 |
| `box_px` / `answer_box_px` | `[x1, y1, x2, y2]` または `null` | 同じ枠を、送った画像のピクセルにしたもの。**描画にはこちらを使ってください** |
| `visible` | `"full"` / `"partial"` | 問題が全部写っているか、見切れているか |
| `answer_status` | 文字列 | `correct`（正解）/ `incorrect`（まちがい）/ `blank`（空白）/ `partial`（書きかけ）/ `unreadable`（見切れている・読めない・出力がこわれていた） |
| `student_answer` | 文字列 | 読み取った児童の答え。空白のときは `""` |
| `correct_answer` | 文字列 または `null` | モデルが計算した正答。単位が付くことがある（例：`"12cm"`） |
| `notes` | 文字列の配列 | その問題についての注記（例：計算し直して判定を直した） |

座標について：

- 切り出した場合も、返る座標は**送った画像での値**にもどしてあります。クライアント側で変換する必要はありません。
- 紙がななめに写っているときは、ななめの枠を囲む、まっすぐな四角を返します。
- クライアントで縮めてから送った場合、`box_px` は**縮めた後の画像**のピクセルです。元の写真に描くときは、`box`（1000 分率）に元の写真の幅と高さを掛けてください（`x_px = box[0] * 元の幅 / 1000`）。

### 6.3 1 問ずつ受け取る（`"stream": true`）

応答は `Content-Type: text/event-stream`（SSE）になり、`data: <JSON>` の行が空行で区切られて順に届きます。

```
data: {"id": "sheet-3f9a1c2b7d4e", "created": 1795000000, "model": "tutor-ufo-v6-sheet", "object": "sheet.start", "image": {"width": 1200, "height": 1600}, "paper_px": null}

data: {"id": "sheet-3f9a1c2b7d4e", ..., "object": "sheet.problem", "index": 0, "problem": {"number": 1, "box": [...], "answer_status": "incorrect", ..., "box_px": [...], "answer_box_px": [...]}, "seconds": 2.5}

data: {"id": "sheet-3f9a1c2b7d4e", ..., "object": "sheet.problem", "index": 1, "problem": {...}, "seconds": 4.0}

data: {"id": "sheet-3f9a1c2b7d4e", ..., "object": "sheet.result", "image": {...}, "paper_px": null, "problems": [...], "counts": {...}, "unsolved": {...}, "notes": [], "seconds": 8.6}

data: [DONE]
```

| `object` | いつ | 中身 |
|---|---|---|
| `sheet.start` | 受け付けた直後に 1 回 | `image`、`paper_px`（6.2 と同じ意味） |
| `sheet.problem` | 1 問読み取れるたび | `index`（届いた順。0 から）、`problem`（6.2 の `problems` の要素と同じ形）、`seconds`（受け付けてからの秒数） |
| `sheet.result` | 最後に 1 回 | `stream` なしのときの応答と同じもの |

- **正式な結果は、最後の `sheet.result` です。** `sheet.problem` は途中経過として表示に使い、`sheet.result` が届いたら、その内容で置きかえてください（ふつうは同じ内容ですが、モデルの出力がこわれていたときなどに、途中で届いた問題が最後の結果に入らないことがあります）。
- `sheet.problem` は、モデルが出力した順（ふつうは紙の上から順）に届きます。`sheet.result` の `problems` は番号の小さい順です。
- 生成の途中で失敗したときは、`data: {"error": {"message": "...", "type": "server_error"}}` が届いて終わります（HTTP の状態は 200 のままです）。`sheet.result` が届かずに接続が終わったときも、失敗として扱ってください。
- 400・401・413・503 など、受け付ける前のエラーは、`stream` なしのときと同じく、ふつうの JSON と HTTP の状態で返ります。
- クライアントが接続を切ると、サーバは生成を止めます。結果がいらなくなったら、接続を閉じてください。
- 知らない `object` が届いたら、無視してください。

### 6.4 呼び出しの例

5.5 の `http` と `data_url` を使います。

```python
import json


def read_sheet(path: str) -> dict:
    r = http.post(f"{BASE}/v1/sheet", json={"image": data_url(path)})
    if r.status_code == 401:
        raise RuntimeError("トークンが正しくありません（再試行しないこと）")
    r.raise_for_status()
    return r.json()


def read_sheet_stream(path: str):
    """1 問ずつ yield し、最後にまとめの結果を yield する。"""
    with http.stream("POST", f"{BASE}/v1/sheet", json={"image": data_url(path), "stream": True}) as r:
        if r.status_code != 200:
            r.read()
            r.raise_for_status()
        for line in r.iter_lines():
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            ev = json.loads(line[6:])
            if "error" in ev:
                raise RuntimeError(ev["error"]["message"])
            if ev["object"] in ("sheet.problem", "sheet.result"):
                yield ev


res = read_sheet("print.jpg")
for p in res["problems"]:
    print(p["number"], p["answer_status"], p["student_answer"], p["box_px"], p["answer_box_px"])
```

curl で試すとき（要求の本体をファイルにしておく）：

```bash
curl --cacert cert.pem -H "Authorization: Bearer $UFO_API_TOKEN" -H "Content-Type: application/json" \
     --data-binary @body.json --max-time 180 "$UFO_API_BASE/v1/sheet"
```

---

## 7. モデルの一覧：GET /v1/models

```json
{"object": "list", "data": [{"id": "tutor-ufo", "object": "model", "created": 1795000000, "owned_by": "local"}]}
```

- 出るのは会話用のモデル 1 つだけです（`id` の既定は `tutor-ufo`）。プリント用のモデルは出ません。
- `GET /v1/models/{name}` は、その 1 つのときだけ 200、ほかは 404 です。
- `/v1/sheet` が使えるかどうかを前もって調べる専用のパスはありません。使えないときは、`POST /v1/sheet` が 503 を返します。

## 8. 監視用のパス

サーバの状態を見るためのパスです。ふつうのクライアントは使わなくてかまいません。どれもトークンが必要です。

| パス | 返すもの |
|---|---|
| `GET /api/monitor` | `current`（今の CPU %・メモリ GB・GPU 使用率・VRAM MB・温度・電力）、`history`（2 秒ごと、6 分ぶん）、`ollama`（読み込まれているモデル。会話用の Ollama だけ）、`gpu_name`、`model`、`waiting`（会話の、処理中と待ちの件数） |
| `GET /api/requests` | `{"requests": [...]}`。新しい順、100 件まで。各要素は `id`、`time`、`client`（接続元の IP）、`status`（`running` / `done` / `error`）、`stream`、`images`、`text`、`output`（どちらも先頭 80 文字）、`action`、`seconds`、`tokens_per_s` |
| `GET /api/requests/{id}` | 1 件のくわしい内容（入力、出力、`tutor_result` または `sheet_result`、時間、トークン数、リソースの使用量）。記録がなければ 404 |

- 記録の `id` は、応答の `id`（`chatcmpl-<id>`、`sheet-<id>`）の後ろの部分です。
- 記録はメモリにあり、サーバの再起動で消えます。
- **記録は、同じトークンを持つ人なら、だれの要求のものでも見られます**（入力の縮小画像も入っています）。

## 9. 時間・同時実行・タイムアウト

実測は、サーバ PC（GPU：RTX 4070 Laptop 8GB）でのものです。

| 項目 | 値 |
|---|---|
| プリントの読み取り（1 枚、5 問） | 約 8〜10 秒（1 問あたり 約 1.5 秒） |
| プリントのストリーミング | 最初の 1 問が 約 2.5 秒、以後 約 1.5 秒ごとに 1 問 |
| プリントを 2 枚同時に | それぞれ 約 11 秒 |
| モデルを読み込んだ直後の 1 回 | さらに 10 秒以上かかることがある |
| 会話とプリントを同時に | GPU を分け合うので、どちらも遅くなる（プリントは 約 15 秒） |

- **タイムアウトは 120 秒以上**にしてください。
- **会話（`/v1/chat/completions`）は 1 件ずつ**処理します。2 件目からはサーバの中で順番を待ちます。`tutor` を付けた要求は、聞き直しなどで、中で 2〜3 回の推論になることがあります。
- **プリント（`/v1/sheet`）は 2 件まで同時に**処理します（サーバが `start.ps1` で起動されている場合）。3 件目からは順番を待ちます。
- どちらも、処理中と待ちを合わせて 4 件までで、次は 503 です。**クライアント側で同時に送るのは、会話は 1 件、プリントは 2 件まで**にしてください。
- 503 のときは、間をあけて再試行してください（例：5 秒、10 秒、20 秒）。

## 10. 結果の信頼度と、データの扱い

- **結果はモデルの推定です。** まちがえることがあります。成績や評価のような大事な判断にそのまま使わず、人が確かめられる見せ方にしてください。
- モデルは、このプロジェクトで作ったレイアウトのプリント（合成した画像）で学習しています。ほかの形式のプリントでは、精度が落ちると考えてください。実物のカメラ写真での精度は、まだ十分に測れていません。
- プリントの読み取りで `calc: true` のとき、`correct` と `incorrect` はサーバが式を計算し直して確かめています。`blank`・`partial`・`unreadable` は、モデルの見た目の判断だけです。
- 字が小さいと読めません。紙が写真の大半を占めるように写すか、`crop: true`（既定）のままにしてください。切り出しは「暗い机の上の明るい紙」を前提にしています。明るい机の上や、紙に強い影があるときは、切り出さずに送られます（`paper_px` が `null` になります）。
- `problems` が空のときは、「問題がない」ではなく「読めなかった」として扱ってください。
- `mode: "normal"` のとき、`tutor.observation` の `solution`・`correct_answer`、プリントの `correct_answer` には答えが入っています。子どもに見せる画面には出さないでください。
- 送る画像には児童の手書きが写っています。必要のない個人情報（名前のらんなど）が写らないようにし、クライアント側でも要求の本体（画像）をログに残さないでください。
- サーバは画像をファイルに保存しません。受付記録として、結果と 360 画素の縮小画像をメモリに持ちます（サーバの再起動で消えます）。

## 11. 実装が終わったら確かめること

1. `GET /api/health` が 200 を返す（`cert.pem` での検証つき）。
2. 記入ずみのプリントの写真 1 枚で、`POST /v1/sheet` が 200 を返し、`problems` が空でない。
3. `box_px` を写真に描いて、枠が問題に重なっている（目で見る）。EXIF の回転がある写真でも重なる。
4. `POST /v1/chat/completions`（`tutor` つき）が 200 を返し、`tutor_result.game.message` が入っている。
5. 4MB をこえる画像を、クライアントが送る前に縮めている。
6. 401 のときに再試行していない。503 のときに間をあけて再試行している。
7. `mode: "normal"` のとき、答え（`correct_answer`・`solution`）を子どもに見せていない。
8. トークンと画像が、ログとリポジトリに入っていない。

## 12. 困ったとき

| 起きること | 原因の見当 |
|---|---|
| つながらない（タイムアウト） | サーバが動いていない、別のネットワークにいる、サーバ PC のファイアウォールが 8444 を通していない |
| 証明書のエラー | `cert.pem` を渡していない、証明書にない名前や IP で接続している、サーバの IP が変わって証明書が作り直された（新しい `cert.pem` をもらう） |
| 403 | 接続元の IP が許可の外。管理者に、許可の範囲（サーバの `--allow`）を足してもらう |
| 401 | トークンがちがう。再試行せず、管理者に確認する |
| 429 | 認証の失敗が続いた。10 分待つ |
| 400 `tutor.grade: Field required` など | `message` の先頭が、直すフィールドの名前 |
| `/v1/sheet` の 503 が続く | プリント用のモデルか、それを動かす 2 つ目の Ollama が動いていない。管理者に連絡 |
| 枠が全体にずれる | EXIF の回転を反映していない、縮めた画像の `box_px` を元の写真にそのまま描いている |
| 全部 `unreadable` / `problems` が空 | 紙が小さく写っている、ぼけている、学習したものとちがう形式のプリント |
| `tutor_result` がない | 要求に `tutor` を付けていない |
| いつも `request_recapture` になる | 画像が読めていない（小さい・ぼけている・回転している）。`notes` に「スキーマ不一致」とあれば、モデルの出力がこわれていた |

サーバ側の参考（読むだけ）：`server/README.md`、`server/tutor_app.py`、プリントの読み取りだけをくわしく書いた `docs/HANDOFF_sheet_api.md`。
