# SUMMON THE UFO ゲームモード仕様（v0.3）

150 秒のスコアゲームの**ゲーム仕様の正本**（Issue #138）。ルール、画面の配置、時間の流れ、得点、状態遷移、例外、機器とのやり取りをここで決める。

- 機器（M5Dial ×2・イルミ・ハブ）との**通信と LED の契約の正本**は UFO-DeviceHub の `docs/game-mode-interface.md`（[UFO-DeviceHub #8](https://github.com/fooping-tech/UFO-DeviceHub/issues/8) で作成予定。**この版の時点ではまだ無い**）。それまでは同リポジトリの `docs/protocol.md`（プロトコル版 1）が契約。
- 仕様を変える PR は、この文書を直し、Issue #138 と DeviceHub #8 の両方にコメントする。
- ここに書いた数値は**すべて調整値**（未確定）。プレイテストと実機の計測で決める。値は `config/game_config.json` の `game_mode` 節にある。

実装の状況は §11、未検証の項目は §12。

## 1. 体験

プレイヤーは実物のクレーンでカプセルを掴み、画面の**左外側**にある 1 号機（Dial 1）か**右外側**にある 2 号機（Dial 2）に入れる。入れたカプセルは画面の中に転送されたように見え、画面上を左右に往復する UFOくんから落とされ、ピンボールの盤面を転がって得点になる。盤面の下まで落ちると、入れたのと同じ側の Dial に戻る演出とともに、実物のカプセルが Dial から排出される。これを 150 秒くり返して得点を競う。

- クレーンの操作（キー・ジェスチャー・自動キャッチ）は「ゲームモード」と同じで、スコアゲームの間もそのまま使える。
- スコアゲームの画面は、クレーンの画面（ロープと UFO）の上に重ねる別の画面。**画面上の UFOくんはスコアゲームの絵で、実機の位置とは関係ない**（`RobotState` を読まない・書かない）。
- スコアゲームはクレーンにコマンドを送らない。機器へは周辺機器のハブ（UFO-DeviceHub）経由だけ。

## 2. 機器の配置

| 画面の側 | 機器 | デバイス ID | 画面のポート | 画面の色（初期提案） |
|---|---|---|---|---|
| 左 | 1 号機 = Dial 1 | `0x20` | 左下 | シアン `0,229,255` |
| 右 | 2 号機 = Dial 2 | `0x21` | 右下 | マゼンタ `255,64,208` |

色は `game_mode.dials.<side>.color`（RGB）で変えられる。Dial 本体の LED を同じ色にする命令は DeviceHub #8 の契約待ち（§8）。

## 3. 時間の流れ

| 段階（phase） | 内容 |
|---|---|
| `IDLE` | タイトルで「3 スコアゲーム」を選んだ直後。Enter で開始 |
| `COUNTDOWN` | 3 秒（`countdown_s`）。両 Dial を `SET_MODE GAME` にする。**まだ受け取らない** |
| `PLAYING` | 150 秒（`duration_s`）。開始と同時に両 Dial へ `ARM_RECEIVER`。右上に残り時間、左上に得点 |
| `SETTLING` | 0 秒になった。**新しいカプセルは受け付けない**。プレイ中のカプセルは最後まで得点し、排出する。最大 30 秒（`settle_max_s`） |
| `RESULT` | 得点、カプセル数、最大コンボ、ジャックポット数、異常のあった Dial。Enter でもう一回、Esc でタイトル |
| `STOPPED` | Space（停止）で止めた。Enter でやり直し |

- 残り 30 秒（`hurry_s`）: 音楽を速くし、イルミを速くする。残り 10 秒（`warning_s`）: 毎秒の警告音、時計が赤く点滅。
- 0 秒の境界: 0 秒より前に `BALL_RECEIVED` が届いたカプセルはプレイする。0 秒の時点で空いている Dial には `DISARM_RECEIVER` を送る。それでも 0 秒の直前に入って後から届いたカプセル（遅れカプセル）は、**盤面に出さず・得点せず**、そのまま排出する。
- `SETTLING` が 30 秒で終わらないとき: まだ終わっていない側を `FAULT` にして `RESULT` に進む（その Dial は係の人が確かめる）。

## 4. 画面の配置（1280 × 720 の固定座標）

| もの | 位置 |
|---|---|
| 得点 | 左上 |
| 残り時間 | 右上（`2:30` から） |
| UFOくん | y = 92。盤面の幅の 10 %〜90 %（x = 248〜1032）を片道 6 秒で往復（`game_mode.ufo`） |
| 盤面 | x = 150〜1130、y = 140〜652。左右は壁 |
| 転送ポート | 左下 (75, 640)、右下 (1205, 640) |
| スイッチ ×3 | y = 185、x = 444 / 640 / 836 |
| ピン | 3 段（y = 230 / 285 / 340）、98 px 間隔の千鳥、計 29 本 |
| バンパー ×3 | (395, 430) (640, 415) (885, 430) |
| 回転ギミック ×2 | (500, 520) (780, 520)。十字が互いに逆向きに回る |
| スター | (640, 505)。取ると 8 秒消える |
| ゴール | 下端。左（x < 570）・中央（570〜710）・右（> 710） |

盤面は Godot の 2D 物理（カプセルは `RigidBody2D`）。**ロープの物理（自前の Verlet）とは別物で、ロープには使わない**。カプセル同士は衝突しない（初期版）。

- **停滞対策**: 速さ 14 px/s 未満が 1.2 秒続いたカプセルは小さく突く。
- **最大滞在**: 盤面に 15 秒（`field.max_stay_s`）いたカプセルは取り出して排出に進む。このときゴールの得点はない（それまでの得点は残る）。

## 5. カプセルと Dial ごとの状態

カプセル 1 個 = 実物 1 個。Dial 1 台につき 1 個、**同時に最大 2 個**。各カプセルは次を持ち、**入れた Dial からだけ排出する**。

| 項目 | 内容 |
|---|---|
| `capsule_id` | `c<session>-<dial 16進>-<cycle>-<通し番号>` |
| `source_dial` | `0x20` / `0x21` |
| `session` | ハブのセッション ID（`BALL_RECEIVED` を受けたときのもの） |
| `cycle` | Dial の受取サイクル番号（`ARM_RECEIVER` のたびに増える） |
| `drop_x` | 投下する X。**`BALL_RECEIVED` を受けた瞬間の UFO の X で固定**し、その後のアニメーション中に変えない |

Dial ごと（左右独立）の状態:

```
OFFLINE → ARMING → READY → ABSORBING → DROPPING → SIMULATING → RETURNING → RELEASING → VERIFYING → READY
                     └（0 秒）→ CLOSING → CLOSED            どこからでも異常 → FAULT
```

| 状態 | 画面 | 機器 | 次へ |
|---|---|---|---|
| `OFFLINE` | じゅんび中 | Dial が応えない。3 秒ごとに `SET_MODE GAME` からやり直す | 応答 → `ARMING` |
| `ARMING` | じゅんび中 | `SET_MODE GAME` → （`PLAYING` になってから）`ARM_RECEIVER` | ACK → `READY` |
| `READY` | ここに入れてね | 受取待ち | `BALL_RECEIVED` → `ABSORBING` |
| `ABSORBING` | ポートが開き、カプセルがポートから投下点へ飛ぶ（0.85 秒） | — | 時間 → `DROPPING` |
| `DROPPING` | 投下点に現れる（0.25 秒） | — | 時間 → `SIMULATING` |
| `SIMULATING` | 盤面を転がって得点 | — | ゴール / 15 秒 → `RETURNING` |
| `RETURNING` | 出口から自分の側のポートへ吸い込まれ、光が Dial の方向へ流れる | 0.6 秒後（同期点、`release_sync_s`）に `RELEASE_BALL` | 送信 → `RELEASING` |
| `RELEASING` | `RELEASE_STARTED` で排出の演出 | `RELEASE_DONE` を待つ（8 秒まで） | `RELEASE_DONE` → `VERIFYING` |
| `VERIFYING` | — | `GET_STATUS`。`dial_state` が `COMPLETE` / `READY` で、スイッチが OFF であること（0.5 秒おきに 4 回まで） | 確認 → `ARM_RECEIVER` → `READY`（0 秒後なら `CLOSED`） |
| `CLOSING` / `CLOSED` | — | 0 秒: `DISARM_RECEIVER`。`RESULT` で `SET_MODE STANDBY` | — |
| `FAULT` | 係の人を呼んでね＋理由 | **何も送らない** | 次のラウンドまでそのまま |

取り込み（スイッチ → 投下）は合計 1.1 秒が初期目標（`absorb_s` + `drop_s`）。実機で計測して調整する。

## 6. 得点（調整値）

| 対象 | 得点 | 補足 |
|---|---|---|
| ピン | 10 | コンボの倍率はかかるが、コンボは増やさない |
| バンパー | 100 | はじき返す |
| 回転ギミック | 200 | |
| スター | 500 | 取ると 8 秒消える |
| スイッチ | 50 | 3 つ全部点くと **+1500**（3 連スイッチ）。点灯は全カプセルで共有し、そろうと消える |
| 左 / 右ゴール | 100 | |
| 中央ゴール | 1000 | |
| ジャックポット | 3000 | 3 連スイッチ完成から 20 秒以内の中央ゴール（中央ゴールの 1000 の代わり。1 回で消える） |

- **コンボ**: バンパー・回転・スター・スイッチに 2.5 秒以内に続けて当てると連鎖が増える。連鎖 2 以上で ×1.5、4 以上で ×2、6 以上で ×3。ゴールとピンにも倍率がかかる。
- **連打の抑制**: 同じカプセルが同じ対象で得点するのは 0.4 秒に 1 回。
- **重複の抑制**: カプセルのゴール得点は 1 回だけ。出口の通知が重なっても、後から古いイベントが来ても二重に得点しない。
- UFO の位置で落とす場所が変わるので、どのタイミングで Dial に入れるかがねらいどころ（スイッチの真上、中央ゴールの真上）。

## 7. 機器とのやり取り（プロトコル版 1。既存のコマンドとイベントだけを使う）

| 場面 | 送る | 待つ |
|---|---|---|
| 開始 | 両 Dial に `SET_MODE {mode: GAME}`、`PLAYING` で `ARM_RECEIVER` | ACK |
| 受取 | — | イベント `BALL_RECEIVED {cycle}` |
| 排出 | `RELEASE_BALL`（カプセル 1 個につき 1 回だけ） | ACK、イベント `RELEASE_STARTED` → `RELEASE_DONE` / `RELEASE_FAILED` |
| 確認 | `GET_STATUS` | STATUS（`dial_state`、`switch_on`） |
| 0 秒 | 空いている Dial に `DISARM_RECEIVER` | ACK |
| 終了 | `SET_MODE {mode: STANDBY}`（`FAULT` の Dial には送らない） | — |
| 停止（Space、Esc） | 全機器に `STOP_ALL` | — |

言葉の意味（混同しない）:

- **ACK** = 機器が命令を**受け取った**。動作が終わったことではない。
- **`RELEASE_DONE`** = サーボの動作シーケンスが**終わった**。**カプセルが実際に出たことの証明ではない**（排出を確かめるセンサーは今はない）。そのため `VERIFYING` でスイッチが OFF に戻ったかを確かめ、戻らなければ次の受け取りを始めない。

重複と古いイベント:

- イベントはセッション ID・送信元・イベント ID で重複を捨てる（ハブのゲートウェイも捨てているが、ゲームでも捨てる）。
- `BALL_RECEIVED` は、同じセッションで `cycle` が前回以下なら捨てる（スイッチのチャタリング、再送）。
- 今のセッションと違うセッション ID のイベントは捨てる（古いセッションのイベントが遅れて届いても、投下・得点・排出をしない）。
- `RELEASE_STARTED` / `RELEASE_DONE` / `RELEASE_FAILED` は、その Dial が `RELEASING` のときだけ使う（`command_id` が分かっていれば照合する）。

ゲームから機器への経路: Godot `GameModeController` → `GameModeDevices` → （バックエンド）WebSocket の `devicehub_command` / `devicehub_status` / `devicehub_stop_all` → `DeviceHubService` → UFO-DeviceHub の `DeviceGateway`（セッション・ACK・再送）。イベントは `devicehub_event` で届く。体験と得点は Godot、命令・セッション・ACK は Python。

## 8. 光（イルミと LED）

**光は飾り。送って忘れる**: 送信に失敗しても、応答がなくても、ゲームと排出は止めない。

| 場面 | イルミ（`0x10`、今ある命令） |
|---|---|
| カウントダウン | `SET_LIGHT_MODE GAME_READY` |
| 開始 | `SET_LIGHT_MODE GAME_PLAY`、`TRIGGER_EFFECT GAME_START` |
| 受取 | `TRIGGER_EFFECT BALL_RECEIVED` |
| 排出開始 | `TRIGGER_EFFECT BALL_RELEASED` |
| 3 連スイッチ・ジャックポット | `TRIGGER_EFFECT SCORE` |
| 残り 30 秒 | `SET_LIGHT_MODE GAME_PLAY`（明るく・速く） |
| 結果 | `SET_LIGHT_MODE RESULT`、`TRIGGER_EFFECT GAME_CLEAR` |

**Dial 本体と、画面と Dial をつなぐ外部 LED はまだ制御していない。** 色・方向（画面へ `TO_SCREEN` / Dial へ `TO_DIAL`）・時間を指定する命令が今のプロトコルに無く、外部 LED の配線と制御元も未確定（DeviceHub #8）。それまで:

- 画面側は、ポートと画面の端（Dial の方向）の間をその側の色の光が流れる（取り込みは Dial → 画面、排出は画面 → Dial）。左右は独立で、同時・逆方向も出る。
- Dial は自分の状態の LED（受取待ち・検出・排出）を出す。
- ゲームは、送りたかった LED 命令をトレースの `led_command` に書くだけ（例 `TO_DIAL rgb=0,229,255 (not sent: DeviceHub #8)`）。契約が決まったら、ここを実際の命令に置き換える（`game_mode_controller.gd` の `_led`）。

## 9. 例外

| 起きたこと | ゲームの動き |
|---|---|
| `RELEASE_BALL` が拒否された・応答がない | その側を `FAULT`。**送り直さない** |
| `RELEASE_FAILED` | `FAULT` |
| `RELEASE_DONE` が 8 秒来ない | `FAULT`（排出できたか分からない） |
| 排出後も Dial がカプセルありのまま | `FAULT`（次の受け取りを始めない） |
| ハブとの通信が切れて、つながり直した（新しいセッション） | プレイ中のカプセルは得点を続けるが、**自動では排出しない**（Dial はもうそのカプセルを覚えていない）→ `FAULT`。排出の途中だった側も `FAULT`。空いていた側は受け取りをやり直す |
| Dial が一時的にオフライン | 空いていた側は `OFFLINE` で待ち、戻ったら受け取りをやり直す |
| Dial にカプセルが残ったまま開始（か、Dial が本体の設定モード） | `ARM_RECEIVER` が拒否され、その側は「じゅんび中」のまま理由を出す。係の人が取り出すと進む |
| 0 秒 | §3 |
| 15 秒たっても盤面にいる | §4 |
| Space（停止） | クレーンを止め（これまでどおり）、スコアゲームを止め、全機器に `STOP_ALL`。**その後は得点も排出も受け取りもしない**。カプセルが Dial に残っていたら係の人が取り出す |
| Esc（タイトルへ） | プレイ中なら Space と同じように止めてから戻る |
| イルミ・LED の失敗 | 無視して進む |

**安全は演出より優先**。復帰のあとの自動再排出はしない。`STOP_ALL` はソフトウェアの停止で、電源を切るのとは違う。通信が切れたことが分かっても、機器が止まったことは保証されない。

`FAULT` になった Dial を元に戻すのは人の作業: カプセルを取り出し、必要なら設定画面の「テスト」タブ（#108）で Dial を確かめる。

## 10. トレース

1 行 1 イベントの JSON Lines。`game_mode.trace` がオンのとき、ラウンドごとに `user://game_mode/trace_<日時>.jsonl`（mac では `~/Library/Application Support/Godot/app_userdata/CoreXY UFO/game_mode/`）。個人情報・鍵は入らない（ID・状態・数値だけ）。

項目: `t_ms`（単調時計）、`game_t`（開始からの秒）、`session_id`、`source_dial`、`cycle`、`capsule_id`、`event`、`command_id`、`result`（ACK の結果・無視した理由）、`game_state`（phase）、`lane_state`、`physics_position`、`score_delta`、`effect_id`（命令名・イベント名・得点の対象）、`led_command`、`release_status`。

`event` の種類: `game_start` `hurry` `time_up` `result` `stopped` `session` `lane_state` `command` `ack` `event` `event_ignored` `ball_ignored` `capsule_created` `score` `stay_timeout` `release` `led` `fault`。

DeviceHub 側のトレースとは `session_id`・`source_dial`・`cycle`・`command_id` で突き合わせる。スイッチが入った時刻と受信時刻の差は、バックエンドがイベントに付ける `received_at`（単調時計）とこの `t_ms` から測る（機器側の時刻との対応付けは未実装）。

## 11. 実装

| もの | 場所 |
|---|---|
| 進行（時計・左右の状態機械・例外） | `game/scripts/game_mode/game_mode_controller.gd`（`GameModeController`） |
| 得点・コンボ・ジャックポット | `score_manager.gd`（`ScoreManager`） |
| カプセルの記録 | `capsule_manager.gd`（`CapsuleManager`） |
| UFO の往復と投下点 | `ufo_drop_controller.gd`（`UfoDropController`） |
| 盤面（物理） | `pinball_field.gd`（`PinballField`） |
| 演出 | `game_mode_vfx.gd`（`GameModeVFX`）。シートは pixelfx（`VFXManager` 経由。下の表）。ポートの枠と光はコードで描く |
| 音 | `game_mode_sounds.gd`（合成。音源ファイルなし） |
| HUD | `game_mode_hud.gd` |
| 機器の窓口 | `game_mode_devices.gd`、ゲーム内の模擬 `mock_dial_hub.gd`、バックエンド経由 `backend_dial_hub.gd` |
| トレース | `game_mode_trace.gd` |
| バックエンド | `devicehub/service.py::mock_ball`、`websocket/server.py` の `devicehub_mock_ball`（模擬ハブのときだけ） |
| 設定 | `config/game_config.json` の `game_mode` |
| テスト | `game/tests/run_tests.gd` の `_test_game_mode_*`、`backend/tests/test_devicehub.py` |

演出のシート（pixelfx 0.3.0 で焼いたもの。`game/assets/vfx/catalog.json`、作り方は `pixelfx-vfx` スキル）:

| 場面 | シート id | pixelfx の元 | 使いどころ |
|---|---|---|---|
| ポートが開く | `capsule_portal_open` | `arcane/portal` | ポートが開いている間ループ（取り込み中・排出中） |
| 吸い込み | `capsule_absorb` | `shadow/black-hole` | カプセルがポートを通る間、ポートの後ろ |
| 軌跡 | `capsule_transfer_trail` | `pickups/xp-orb` | ポート ⇔ 投下点・出口を飛ぶカプセルに追従 |
| 出現 | `capsule_materialize` | `arcane/mana-burst` | 投下点 |
| 排出 | `capsule_release_burst` | `explosions/firework-burst` | `RELEASE_STARTED` で、Dial 側の画面の端 |
| ポートが閉じる | `capsule_portal_close` | `explosions/implosion` | 投下の瞬間・排出の完了 |

6 枚とも**灰色で焼いてあり、ゲームがその側の色を掛ける**（左右で同じシートを使う。色を変えても焼き直さない）。異常（`capsule_fault`）と得点（バンパー・スター・ボーナス）は既存のシート（`fail_poof` `grab_burst` `success_sparkle` `success_confetti`）。ポートの枠と Dial 方向への光はコードで描く。人の輪郭が残る `arcane/blink-in` / `blink-out`、`spawn/respawn-beam` は使わない。

### 動かし方（実機なし）

```bash
# ゲームだけ（Dial はゲーム内の模擬）。タイトルで 3、Enter で開始、Z = 左に入れる、M = 右に入れる
./start.sh --game-only
# すぐ始める。--game-mode-demo は模擬の Dial に自動でカプセルを入れる
./start.sh --game-only -- --game-mode --game-mode-devices mock --game-mode-demo
# バックエンドの模擬ハブ経由（WebSocket・DeviceGateway を通す）。-- の後ろはバックエンドの引数。
# ゲームではタイトルで 3、Enter、Z / M（模擬ハブのときだけ devicehub_mock_ball が効く）
./start.sh --mock --no-gesture -- --devicehub mock
```

| ゲームの引数 | 内容 |
|---|---|
| `--game-mode` | スコアゲームをすぐ始める |
| `--game-mode-devices mock\|backend\|auto` | Dial をゲーム内の模擬にするか、バックエンドのハブにするか（既定は `game_mode.devices`） |
| `--game-mode-seconds <秒>` | ラウンドの長さ（確認用） |
| `--game-mode-demo` | 模擬の Dial に自動でカプセルを入れる |

## 12. 検証の状況

| 項目 | Mock | 実機 |
|---|---|---|
| 1 号機だけ / 2 号機だけ / 両側同時 / 逆方向同時 | 確認済み（自動テスト） | 未検証 |
| スイッチのチャタリング、イベントの再送、古いセッションのイベント | 確認済み | 未検証 |
| 通信断とつなぎ直し、Dial のオフライン | 確認済み | 未検証 |
| 排出の拒否・失敗・完了が来ない・カプセルが残る | 確認済み | 未検証 |
| 0 秒の境界、遅れカプセル、清算の上限 | 確認済み | 未検証 |
| 停止（Space / Esc）、15 秒の時間超過 | 確認済み | 未検証 |
| 盤面の物理（落下してゴールに届く） | 確認済み | — |
| バックエンドの模擬ハブでの受取 → 排出（左右） | 確認済み（pytest） | — |
| 150 秒を通したプレイ | ゲーム内の模擬で確認（`--game-mode-demo`） | 未検証 |
| 左右の配線、受取スイッチ、サーボ、Dial の LED | — | **未検証** |
| スイッチ → 画面の遅れ、`RELEASE_BALL` の同期点、演出の長さ | 初期値のまま | **未計測** |
| Dial・外部 LED の色と方向の同期 | 未実装（DeviceHub #8 の契約待ち） | **未検証** |
| 得点表・難易度 | 初期値のまま | プレイテスト未実施 |

実機で最初に確かめる手順:

1. 設定画面の「テスト」タブで、両 Dial が一覧に出ること、GAME・受取待ち・排出が 1 台ずつ動くことを確かめる。
2. `--game-mode-seconds 30` でスコアゲームを始め、左にカプセルを入れる。左下のポートから取り込まれ、落ちたあと**左の Dial から**排出されることを見る。右も同じ。
3. 両方に続けて入れ、互いに邪魔しないことを見る。
4. プレイ中に Space を押し、Dial が止まり、そのあと何も動かないことを見る。
5. トレースから、スイッチ → 取り込み開始、`RELEASE_BALL` → `RELEASE_STARTED` → `RELEASE_DONE` の時間を読み、`game_mode.timing` を合わせる。

## 13. 相手リポジトリとの記録

| 日付（JST） | この文書の版 | UFO-DeviceHub のコミット | プロトコル版 | 内容 |
|---|---|---|---|---|
| 2026-11-16 | v0.3（初版） | `f98999f`（`pc/` のコピー元。`__init__.py` に記録） | 1 | 既存のコマンド・イベントだけで実装。`pc/protocol.py` を `1302bac` → `f98999f` に更新（`DialState.SETTINGS` の追加だけ）。LED の契約（`docs/game-mode-interface.md`）は未作成 |
