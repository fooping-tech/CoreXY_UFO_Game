# UFO-DeviceHub の Python コードを使う（#159）

周辺機器のハブ（[UFO-DeviceHub](https://github.com/fooping-tech/UFO-DeviceHub): ESP-NOW ハブ、イルミ、M5Dial ×2）と話す Python コード（ゲートウェイ・プロトコル・模擬ハブ・トレース）は、UFO-DeviceHub のリポジトリにあるものをそのまま使う。このリポジトリにコピーは置かない。

| | |
|---|---|
| コードの正本 | UFO-DeviceHub の `pc/`（Python パッケージ `ufo-devicehub`、import 名 `ufo_devicehub`） |
| 置き場所 | `external/UFO-DeviceHub/`（ふつうの `git clone`。Submodule ではない。`.gitignore` 済みで、このリポジトリにはコミットされない） |
| 依存の宣言 | `backend/pyproject.toml` の `dependencies` と `[tool.uv.sources]`（editable なパス依存）、`backend/uv.lock` |
| 確認済みのコミット | `tools/devicehub.pin`（CI と `tools/setup_devicehub.sh --pinned` が使う） |
| このゲームだけのコード | `backend/src/corexy_ufo_backend/devicehub/service.py`（設定、ロボットのポートを開かない、排他、画面に出す言葉、WebSocket への橋渡し） |

今は Issue #159 の **Phase 1（開発中の形）** にあたる。安定したら Phase 2（バージョンを固定したパッケージ）に移る（§7）。

## 1. 最初の準備（1 回だけ、ネットワークが必要）

```bash
tools/setup_devicehub.sh          # macOS / Linux
.\tools\setup_devicehub.ps1       # Windows
```

- `external/UFO-DeviceHub/` がなければ clone し、確認済みのコミットにして、`backend` で `uv sync` する。
- すでに clone があれば、そのままにする（作業中のブランチや変更を動かさない）。確認済みのコミットと違うときは、そう表示する。
- これをしていないと、バックエンドは起動できない（uv が依存を解決できない）。`./start.sh` / `.\start.ps1` はその場合、何も起動せずにこの手順を表示して止まる。ゲームだけ（`--game-only`）は clone がなくても起動できる。

| やりたいこと | コマンド |
|---|---|
| 今どのコミットかを見る | `tools/setup_devicehub.sh --status` |
| 確認済みのコミットに合わせる（展示用の PC、CI） | `tools/setup_devicehub.sh --pinned` |
| `uv sync` をしない | `--no-sync` を付ける |

`--pinned` は、clone に未コミットの変更があるときは何もせずに止まる（作業を捨てない）。Windows では `-Status` `-Pinned` `-NoSync`。

## 2. 2 つのリポジトリを同時に直す

1. `external/UFO-DeviceHub/` で作業ブランチを作る（`git -C external/UFO-DeviceHub switch -c feat/...`）。
2. そこの Python（`pc/*.py`、`ufo_devicehub/`）を直す。
3. **バックエンドを起動し直す**（`./start.sh` をやり直す、または `uv run pytest`）。直した内容がそのまま使われる。

| 変えたもの | 必要なこと |
|---|---|
| UFO-DeviceHub の Python コード | バックエンド（Python のプロセス）の再起動だけ。`uv sync` もコピーも不要 |
| UFO-DeviceHub の `pyproject.toml`（依存を足した、版を変えた） | `cd backend && uv lock && uv sync`。`backend/uv.lock` の変更はゲーム側の PR に入れる |
| ファームウェア（`firmware/`、`shared/`） | 機器への書き込み（UFO-DeviceHub の README）。Python の依存とは別 |

ゲーム側のコードは `from ufo_devicehub import ...` だけを使う（公開 API は UFO-DeviceHub の `ufo_devicehub/__init__.py` の `__all__`）。`pc` の中の `_` で始まる名前や、模擬ハブの機器クラスに直接依存しない。足りない機能は、ゲーム側にコードを写さず、UFO-DeviceHub に公開の拡張点を足す。

## 3. 2 つのリポジトリにまたがる変更の出し方

1. **UFO-DeviceHub の PR を先に出す。** 本文に、対応するゲーム側の Issue / PR の URL を書く。
2. **ゲーム側の PR** を出す。本文に次を書く。
   - UFO-DeviceHub の PR の URL と、`tools/devicehub.pin` に書いたコミット
   - 互換性の確認結果（`tools/verify.sh` の件数。模擬ハブでの確認か、実機での確認か）
   - 実機で確かめていない項目
3. `tools/devicehub.pin` のコミットは、**UFO-DeviceHub でレビュー済み（main にマージ済み）のコミット**にしてからゲーム側をマージする。開発中は未マージのコミットを試してよいが、そのまま確定しない。
4. プロトコルや LED の契約を変えるときは、`docs/game_mode_spec.md` §13 の表にも 1 行足す。

**ローカルのパスや一時的な変更をコミットしない。** `external/` は `.gitignore` 済み。`backend/pyproject.toml` の `[tool.uv.sources]` を自分の PC だけのパスに書き換えたままコミットしない。

## 4. CI

`.github/workflows/ci.yml` の backend ジョブは、ゲームとは別に UFO-DeviceHub を `external/UFO-DeviceHub/` に取得する（`tools/setup_devicehub.sh --pinned --no-sync`）。取得するのは `tools/devicehub.pin` のコミットで、UFO-DeviceHub の main がその後進んでも、開発者の手元のブランチが何であっても、CI の結果は変わらない。UFO-DeviceHub の更新を取り込むときは、このファイルのコミットを書き換える PR を出す。

手元の `tools/verify.sh` は、手元の clone の**今のコミット**でテストする（どのコミットかを表示する）。CI と同じ条件にするには、先に `tools/setup_devicehub.sh --pinned`。

## 5. ネットワークのない展示用の PC

1. ネットワークのある場所で 1 回、`tools/setup_devicehub.sh --pinned` と、使う形での起動（`./start.sh --mock --no-gesture` など。ジェスチャーを使うならそれも）を済ませる。これで `external/UFO-DeviceHub/`、`backend/.venv`、uv のキャッシュがそろう。
2. そのあとはネットワークなしで起動できる（2026-11-17、macOS で `uv run --offline` と `uv sync --locked --offline` を確認）。
3. clone を別の場所から取るとき（USB メモリなど）は `CXUFO_DEVICEHUB_URL=/path/to/UFO-DeviceHub tools/setup_devicehub.sh`。

Windows の展示用 PC でのオフライン起動は未確認。

## 6. 変えていないこと（安全）

パッケージにしただけで、通信の約束は同じ。

- ACK は処理の完了ではない。完了は `RELEASE_DONE` などのイベントで知る。
- `RELEASE_BALL` は重複して出さない。ACK が失われたときの再送は同じコマンド ID で行われ、機器は 1 回だけ動く。
- セッション ID・サイクル・コマンド ID、イベントの重複排除、`STOP_ALL` の優先、別のシステムのハブの拒否は UFO-DeviceHub のゲートウェイのまま。
- ハブの自動検出はロボット（Core2）のポートを開かない。ハブのポートは排他で開く。
- **USB が抜けたことが分かっても、機器が止まったことにはならない。**

回帰テストは `backend/tests/test_devicehub.py`（模擬ハブ。接続、切断と再接続、ACK とイベント、ACK を失ったときの 1 回だけの排出、二重排出の拒否、`STOP_ALL`、別システムの拒否、ロボットのポートを開かないこと）。**実機のハブ・M5Dial・イルミでは未検証**。

## 7. Phase 2（安定してから）

展示と実機の評価が落ち着いたら、別の PR で行う（Issue #159）。

- UFO-DeviceHub のコードの置き場所を `ufo_devicehub` に移し、バージョンの付け方と変更履歴を決めて wheel を作る（ゲーム側の import は今のまま）。
- `backend/pyproject.toml` の `[tool.uv.sources]` を、Git のタグ・コミット固定の依存か、バージョンを固定した wheel に切り替える。`uv sync --locked` だけで再現でき、`external/` の clone がなくても動くようにする。
- CI から clone の手順を外す。展示用の PC に wheel を先に入れておく手順を確かめる。
- `HELLO` / プロトコル版 / ファームウェア版が合わないときに危険なコマンドを送らない、という互換性の方針を文書にする。
- 変更が多い時期に戻るときは、この文書の形（editable なパス依存）に戻す。
