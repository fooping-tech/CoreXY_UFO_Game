# SUMMON THE UFO ゲームモード仕様（v0.3）

150 秒のスコアゲームの**ゲーム仕様の正本**（Issue #138）。ルール、画面の配置、時間の流れ、得点、状態遷移、例外、機器とのやり取りをここで決める。

- 機器（M5Dial ×2・イルミ・ハブ）との**通信と LED の契約の正本**は UFO-DeviceHub の [`docs/game-mode-interface.md`](https://github.com/fooping-tech/UFO-DeviceHub/blob/main/docs/game-mode-interface.md)（[UFO-DeviceHub #8](https://github.com/fooping-tech/UFO-DeviceHub/issues/8)。プロトコル版 1、ファームウェア 0.3）。この文書はそれに合わせてある（§7・§8・§13）。
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
| 左 | 1 号機 = Dial 1 | `0x20` | 左下 | シアン `0,255,255` |
| 右 | 2 号機 = Dial 2 | `0x21` | 右下 | マゼンタ `255,0,255` |

色は Dial の**号機色**と同じにする（初期値は UFO-DeviceHub の既定色）。`game_mode.dials.<side>.color`（RGB）で変えると、ゲームがセッションごとに `SET_DIAL_COLOR` で Dial にも同じ色を送るので、画面のポートと Dial の LED がそろう（§8）。

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
- 0 秒の境界: 0 秒より前に `BALL_RECEIVED` が届いたカプセルはプレイする。0 秒の時点で空いている Dial には `DISARM_RECEIVER` を送る（受取待ちにする途中・応答待ちの Dial にも送る）。それでも 0 秒の直前に入って後から届いたカプセル（遅れカプセル）は、**盤面に出さず・得点せず**、そのまま排出する。
- `SETTLING` が 30 秒で終わらないとき: まだ終わっていない側を `FAULT` にして `RESULT` に進む（その Dial は係の人が確かめる）。

## 4. 画面の配置（1280 × 720 の固定座標）

| もの | 位置 |
|---|---|
| 得点 | 左上（x = 8〜172）。その下にコンボ（連鎖数・倍率・残り時間の棒） |
| 残り時間 | 右上（x = 1108〜1272、`2:30` から） |
| ハンド操作の表示 | 左の柱（x = 2〜135、y = 124〜360）に縦長で置く: カメラ映像、スティック、手の状態、速度。盤面・ゴール・ポート・得点に重ならない（スコアゲームの外では従来の横長） |
| アームカメラのスコープ | 右の柱（x = 1145〜1278、y = 124〜360）。丸く切り抜いたアーム先端のカメラ（`camera.focus`。なければ俯瞰カメラ。カメラが 1 台もなければ出さず、惑星が見える） |
| UFOくん | y = 92。盤面の幅の 10 %〜90 %（x = 248〜1032）を片道 6 秒で往復（`game_mode.ufo`） |
| 盤面 | x = 150〜1130、y = 140〜652。左右は壁 |
| 転送ポート | 左下 (75, 640)、右下 (1205, 640) |
| スイッチ ×3 | y = 185、x = 444 / 640 / 836 |
| ピン | 3 段（y = 230 / 285 / 340）、98 px 間隔の千鳥、計 29 本 |
| バンパー ×3 | (395, 430) (640, 415) (885, 430) |
| 回転ギミック ×2 | (500, 520) (780, 520)。十字が互いに逆向きに回る |
| スター | (640, 505)。取ると 8 秒消える |
| 小バンパー ×2 | (262, 440) (1018, 440)。壁ぎわの緑の小さいバンパー |
| 壁のターゲット ×4 | 左右の壁の y = 400 / 480。当たると 6 秒点灯（表示だけ） |
| スリングショット ×2 | 下の左右の斜面（壁の y = 530 から内側 110 px、y = 605 まで）。当たると斜め上・内向きにはじく |
| 宝石 ×4 | y = 312、x = 297 / 493 / 787 / 983（ピンの最下段のすぐ上）。当たり判定だけで、カプセルを止めない。取ると 10 秒消える |
| 宇宙人 | y = 372 付近を x = 230〜1050 で 9 秒かけて往復する。当たり判定だけ。つかまえると 5 秒消える |
| ワープホール ×2 | (350, 588) (930, 588)。左右のゴールの上。落ちたカプセルを 0.7 秒とどめて、上・内向きに打ち上げる。**1 個のカプセルにつき 1 回だけ**（必ず 15 秒以内に落ちる） |
| カプセル | 半径 18 px |
| ゴール | 下端。左（x < 570）・中央（570〜710）・右（> 710） |

### 見た目（#140 / #141）

ネオンレトロ × ピクセルアート。濃紺を地に、シアン・マゼンタ・黄・紫をアクセントにする。

**ドットの大きさ**: UFOくんのスプライトは 64×64 ドットで、2 倍で表示する（1 ドット = 画面の 2 px）。背景・盤面の絵・エフェクトは、これと同じ大きさのドットになるよう、**640×360 のキャンバス**（`GameModeController.pixel_view`）に描いて 2 倍で映す。丸・斜めの線・回るものも同じドットになる。座標は 1280×720 のまま（太さ 2 = 1 ドット）。物理（`PinballField`）はキャンバスの外で、絵（`PinballFieldArt`）は物理の状態を読むだけ。得点・時計のパネルと日本語の文字はキャンバスの上に重ねる（ドット文字は 2 px の倍数の大きさ）。

絵はコードで描く（素材ファイルなし）: 暗い 1 ドットの輪郭、ハイライトと影、少ない色数。数字と英字は 5×7 のドット文字 `PixelText`、日本語は #134 のフォント（大きい字は DotGothic16、本文は M PLUS Rounded 1c）。

| もの | 見た目 |
|---|---|
| 背景（`GameModeBackdrop`） | 濃紺の帯、斜めに横切る遠い星の帯、淡い星雲、3 層の星、光の粒、流れ星、下から立ちのぼる光の柱、右に輪のある惑星、左に月。盤面の両脇の下に、各 Dial のポートから伸びる短い導管とランプ |
| 盤面の床 | 星が少し透ける暗いパネル。軌道の輪、スイッチから下へのレーン線、バンパーと中央ゴールを指す矢印ランプ、スターの後ろの放射、両脇を流れるランプ、うっすら `UFO` の文字 |
| 盤面の枠 | 左の壁は Dial 1 の色、右の壁は Dial 2 の色のネオン管（暗い輪郭、ボルト、上の角の金具）。上に UFO が動くレールと流れるランプ |
| ねらう場所 | 得点するものは**呼吸するように光る**（バンパー・小バンパー・スター・ターゲットの輪、消えているスイッチの矢印、中央ゴール）。それぞれの**得点を横に書く**。スイッチの間に「LAMPS（点いた数）→ JACKPOT 3000」 |
| 宝石・宇宙人・ワープホール | 宝石は色違いのカット石（上下に揺れ、きらめく。取ると輪郭だけ残る）。宇宙人は一つ目の小さなドット絵で、足を動かし、進む方を見る。ワープホールは光の腕が回り込む黒い穴で、カプセルを吸うと速く回り、打ち上げるとき白く光る。絵は文字の並びで定義したドット絵（`PinballFieldArt.GEM` / `ALIEN`）で、1 文字 = 1 ドット |
| 当たった瞬間 | ピンは輪、バンパーは膨らんで白く、回転ギミックは残像、スリングショットはゴムが飛び出す、ターゲットは点灯 |
| ゴール | 下へ流れる矢印。中央はジャックポットのとき黄色く点滅 |
| カプセル | 暗い縁、上半分がその Dial の色、下半分は白。通った跡に**光の軌跡**（直前の 12 点。コンボで太くなる） |
| 得点の一時表示 | 得点した場所にドット文字で `+100 x1.5`。跳ねて出て、上がって、点滅して消える（約 1.1 秒）。大きい得点とコンボ 2 段目以上は大きい字 |
| スコア・時計 | 左上と右上のパネル。得点が増えている間は数字が黄色く弾む。時計は残り 30 秒で黄、10 秒で赤の点滅 |
| スコアゲームのタイトル画面（開始待ち） | 大きな `SUMMON THE UFO` のロゴ、大きな UFOくん、点滅する START、遊び方の 3 枚のカード。**プレイ中は出さない** |

### アームカメラのスコープ（`ArmScope`、#141）

ねらいを定める照準の見た目で、右の柱にアーム先端のカメラを丸く出す（左の柱のハンド操作の表示と対）。

- 円の上に、十字線、30 度ごとの目盛り、回る破線の輪、掃引線、四隅のブラケット。
- **オプティカルフロー**: 映像がどちらへ動いているかを、5×5 のマスごとの矢印（止まっているマスは点）と、中央からの白い矢印（全体の動き）で描く。矢印の色は速さ（水色 → 黄 → 桃）。
- 円の下に `ARM CAM`、状態、速さの棒、`FLOW x y`。状態は `MOVE`（動いている。桃色）、`LOCK`（0.6 秒止まっている。ブラケットが閉じて黄色）、`SCAN`（手がかりになる模様がない）。
- フローはゲームの中で測る（`OpticalFlow`: 映像を 48×48 の白黒にした写しを約 0.1 秒ごとに取り、ブロックの位置合わせで動きを求める）。バックエンドなしでも動く。
- **表示だけ**。映像もフローも保存せず、どこにも送らず、ロボットの動きや得点の判定に使わない。
- `--game-mode-demo` では、動いて止まる机の絵がカメラの代わりになる（カメラなしで確認できる）。
- 設定は `game_mode.scope`（`enabled`、`optical_flow`、`zoom` 1〜4）。

プレイの状況で変わるもの（どれも表示だけ）:

| 状況 | 変化 |
|---|---|
| 残り時間 | 空の色が濃紺から少しずつ紫へ。残り 30 秒で紫と桃色の光、残り 10 秒で赤く脈打つ（`backdrop.urgency` / `time_k`） |
| 得点 | 画面全体が数ドット沈んで戻る（ピンは弾まない。バンパーなど小、ゴール中、スターと中央ゴール大、ボーナスとジャックポット最大。コンボで強くなる。上限 16 px）|
| コンボ | 段が上がると中央に `COMBO x1.5` と背景の光。段が高いほど星が流れ、光の柱が強く、盤面のランプが速く、得点の字と軌跡が大きい。連鎖が切れると元に戻る |

見た目は状態を映すだけで、得点・物理・判定・機器とのやり取りは変えない（画面の弾みや演出の終わりを、物理・時計・通信は待たない）。`game_mode.visual_quality` を `low` にすると、背景が動かない簡素なものになる。`game_mode.effects` を `false` にすると、弾み・軌跡・呼吸する光を止める（確認用。ゲームは同じ）。

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
| `READY` | ここに入れてね | 受取待ち | `BALL_RECEIVED` → `ABSORBING`（`ARM_RECEIVER` の ACK より先に届いた・ACK が失われた場合も、新しい cycle の `BALL_RECEIVED` なら `ARMING` / `OFFLINE` から受け取る） |
| `ABSORBING` | ポートが開き、カプセルがポートから投下点へ飛ぶ（0.85 秒） | — | 時間 → `DROPPING` |
| `DROPPING` | 投下点に現れる（0.25 秒） | — | 時間 → `SIMULATING` |
| `SIMULATING` | 盤面を転がって得点 | — | ゴール / 15 秒 → `RETURNING` |
| `RETURNING` | 出口から自分の側のポートへ吸い込まれ、光が Dial の方向へ流れる | 0.6 秒後（同期点、`release_sync_s`）に `RELEASE_BALL` | 送信 → `RELEASING` |
| `RELEASING` | `RELEASE_STARTED` で排出の演出 | `RELEASE_DONE` を待つ（8 秒まで） | `RELEASE_DONE` → `VERIFYING`。8 秒来なければ、送り直さずに `VERIFYING` で Dial の状態を確かめる |
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
| 小バンパー | 50 | はじき返す（#141 で追加） |
| 壁のターゲット | 150 | #141 で追加 |
| スリングショット | 30 | コンボは増やさない（#141 で追加） |
| 宝石 | 100 | 取ると 10 秒消える（#141 で追加） |
| 宇宙人 | 400 | つかまえると 5 秒消える（#141 で追加） |
| ワープホール | 300 | 入ったときに得点。カプセル 1 個につき 1 回（#141 で追加） |
| スイッチ | 50 | 3 つ全部点くと **+1500**（3 連スイッチ）。点灯は全カプセルで共有し、そろうと消える |
| 左 / 右ゴール | 100 | |
| 中央ゴール | 1000 | |
| ジャックポット | 3000 | 3 連スイッチ完成から 20 秒以内の中央ゴール（中央ゴールの 1000 の代わり。1 回で消える） |

- **コンボ**: バンパー・回転・スター・スイッチ・小バンパー・壁のターゲット・宝石・宇宙人・ワープホールに 2.5 秒以内に続けて当てると連鎖が増える。連鎖 2 以上で ×1.5、4 以上で ×2、6 以上で ×3。ゴールとピンにも倍率がかかる。
- **連打の抑制**: 同じカプセルが同じ対象で得点するのは 0.4 秒に 1 回。
- **重複の抑制**: カプセルのゴール得点は 1 回だけ。出口の通知が重なっても、後から古いイベントが来ても二重に得点しない。
- UFO の位置で落とす場所が変わるので、どのタイミングで Dial に入れるかがねらいどころ（スイッチの真上、中央ゴールの真上）。

## 7. 機器とのやり取り（プロトコル版 1）

| 場面 | 送る | 待つ |
|---|---|---|
| 開始 | 両 Dial に `SET_MODE {mode: GAME}`、`PLAYING` で `ARM_RECEIVER` | ACK |
| 受取 | — | イベント `BALL_RECEIVED {cycle}` |
| 排出 | `RELEASE_BALL`（カプセル 1 個につき 1 回だけ） | ACK、イベント `RELEASE_STARTED` → `RELEASE_DONE` / `RELEASE_FAILED` |
| 確認 | `GET_STATUS` | STATUS（`dial_state`、`switch_on`） |
| 0 秒 | 空いている Dial に `DISARM_RECEIVER` | ACK |
| 終了 | `SET_MODE {mode: STANDBY}`（`FAULT` の Dial には送らない） | — |
| 停止（Space、Esc） | 全機器に `STOP_ALL` | — |
| Dial の LED（§8） | `SET_DIAL_COLOR`、`SET_DIAL_EFFECT`（ファームウェア 0.3 から） | 待たない |

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

### Dial の LED（転送の光）

Dial 1 台に LED が 2 系統ある（前面 G1 と、G15。どちらもその Dial が駆動し、命令の `target: BOTH` で両方に出す）。ゲームは UFO-DeviceHub の契約（`docs/game-mode-interface.md` §5）の名前付きアニメーションを、その Dial の号機色で送る（`game_mode.dial_leds`）。

| いつ（ゲーム） | アニメーション | `SET_DIAL_EFFECT` |
|---|---|---|
| `SET_MODE GAME` が通ったとき（セッションごと） | — | `SET_DIAL_COLOR`（その側の色） |
| `BALL_RECEIVED` を受けて取り込みを始めるとき | `INTAKE` | CHASE / `TO_SCREEN` / 1500 ms / NORMAL |
| `RETURNING` を始めるとき（`RELEASE_BALL` の 0.6 秒前） | `RETURN_FLOW` | COMET / `TO_DIAL` / 0（続く）/ NORMAL |
| `RELEASE_STARTED` を受けたとき | `RELEASING` | CHASE / `TO_DIAL` / 0 / NORMAL |
| `FAULT` になったとき | `FAULT` | FLASH 赤 / 1500 ms / HIGH |
| `RESULT`（正常に閉じた Dial） | — | NONE / HIGH（Dial 自身の表示に戻す） |

- 画面側は同じ色・同じ向きで、ポートと画面の端（Dial の方向）の間を光が流れる（取り込みは Dial → 画面、排出は画面 → Dial）。左右は独立で、同時・逆方向も出る。
- Dial は検出した瞬間に自分で「白 → 号機色で画面方向」を光らせる。ゲームの `INTAKE` は同じ色・同じ向きなので、後から届いても見た目がつながる。
- 演出の終わりは Dial が自分で決める（カプセルの検出、排出シーケンスの終了、`STOP_ALL`、セッションの変更、通信断）。ゲームは後始末の命令に頼らない。
- **結果を待たない**: `IGNORED_PRIORITY`・`NOT_CONFIGURED`（G15 の LED がない機体）・タイムアウトは無視する。`RELEASE_BALL` を LED の応答で遅らせない。
- **古いファームウェア**（Dial 0.2 は `UNSUPPORTED`、Hub 0.2 は `BAD_REQUEST`）: その Dial にはそのラウンドの間 LED 命令を送らない。Dial は自分の状態の LED を出し、ゲームは同じに進む。
- `ATTRACT`（受取待ちの呼び込み）は送っていない（Dial 自身の受取待ち表示が出る）。
- 画面と Dial の間にさらに別の LED テープを足す場合の配線・制御は未定（DeviceHub 側の文書 §3）。

## 9. 例外

| 起きたこと | ゲームの動き |
|---|---|
| `RELEASE_BALL` が拒否された・応答がない | その側を `FAULT`。**送り直さない** |
| `RELEASE_FAILED` | `FAULT` |
| `RELEASE_DONE` が 8 秒来ない | 送り直さず、`GET_STATUS` で確かめる。Dial が `COMPLETE` でスイッチが OFF なら（通知だけが失われた）次へ進む。そうでなければ `FAULT`（排出できたか分からない） |
| 排出後も Dial がカプセルありのまま | `FAULT`（次の受け取りを始めない） |
| ハブとの通信が切れて、つながり直した（新しいセッション） | プレイ中のカプセルは得点を続けるが、**自動では排出しない**（Dial はもうそのカプセルを覚えていない）→ `FAULT`。排出の途中だった側も `FAULT`。空いていた側は受け取りをやり直す |
| ハブにつながらない | 両側とも「じゅんび中」で待ち、盤面の上に理由を出す（バックエンドが返す: 別のシステムのハブ（システム番号の違い）／ポートが見つからない／開けない／ハブとして応答しない／バックエンドがない・ハブを使っていない）。つながれば受け取りを始める |
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

DeviceHub 側のトレース（`pc/trace.py`。バックエンドの `--devicehub-trace <file>` か config の `devicehub.trace` で、ハブに送った命令・ACK・イベントを 1 行ずつ書く）とは `session_id`・`source_dial`・`cycle`・`command_id` で突き合わせる。受取は `(session_id, source_dial, cycle)`、排出は `RELEASE_BALL` の `command_id`。スイッチが入った時刻と受信時刻の差は、バックエンドがイベントに付ける `received_at`（単調時計）とこの `t_ms` から測る（機器側の時刻との対応付けは未実装）。

## 11. 実装

| もの | 場所 |
|---|---|
| 進行（時計・左右の状態機械・例外） | `game/scripts/game_mode/game_mode_controller.gd`（`GameModeController`） |
| 得点・コンボ・ジャックポット | `score_manager.gd`（`ScoreManager`） |
| カプセルの記録 | `capsule_manager.gd`（`CapsuleManager`） |
| UFO の往復と投下点 | `ufo_drop_controller.gd`（`UfoDropController`） |
| 盤面（物理） | `pinball_field.gd`（`PinballField`） |
| 背景・ドット文字 | `game_mode_backdrop.gd`（`GameModeBackdrop`）、`pixel_text.gd`（`PixelText`） |
| 演出 | `game_mode_vfx.gd`（`GameModeVFX`）。シートは pixelfx（`VFXManager` 経由。下の表）。ポートの枠と光はコードで描く |
| 音 | `game_mode_sounds.gd`（合成。音源ファイルなし） |
| HUD | `game_mode_hud.gd` |
| 機器の窓口 | `game_mode_devices.gd`、ゲーム内の模擬 `mock_dial_hub.gd`、バックエンド経由 `backend_dial_hub.gd` |
| トレース | `game_mode_trace.gd` |
| バックエンド | `devicehub/service.py::mock_ball`、`websocket/server.py` の `devicehub_mock_ball`（模擬ハブのときだけ）、`devicehub/` の UFO-DeviceHub `pc/` のコピー（`trace.py`・`game_mode.py` を含む） |
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
| `--game-mode-title` | スコアゲームのタイトル画面（開始待ち）で止める（画面の確認用） |

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
| Dial の LED の色と方向の同期（`SET_DIAL_COLOR` / `SET_DIAL_EFFECT`）、優先度での拒否、古いファームウェア | 確認済み（ゲーム内の模擬と UFO-DeviceHub の模擬ハブ） | **未検証**（LED の上下の向き、G15 の LED の個数、2 系統同時点灯の電流は DeviceHub 側でも未確認） |
| `RELEASE_DONE` が来ないときの状態確認 | 確認済み | 未検証 |
| 得点表・難易度 | 初期値のまま | プレイテスト未実施 |

実機で最初に確かめる手順:

1. 設定画面の「テスト」タブで、両 Dial が一覧に出ること、GAME・受取待ち・排出が 1 台ずつ動くことを確かめる。
2. `--game-mode-seconds 30` でスコアゲームを始め、左にカプセルを入れる。左下のポートから取り込まれ、落ちたあと**左の Dial から**排出されることを見る。右も同じ。
3. 両方に続けて入れ、互いに邪魔しないことを見る。
4. プレイ中に Space を押し、Dial が止まり、そのあと何も動かないことを見る。
5. Dial の LED が画面のポートと同じ色で、取り込みは画面の方向へ、排出は Dial の方向へ流れることを見る（逆なら DeviceHub 側の `DIAL_LED_REVERSED`）。Hub と Dial はどちらもファームウェア 0.3 にする（片方だけ新しいと STATUS が読めない）。
6. トレースから、スイッチ → 取り込み開始、`RELEASE_BALL` → `RELEASE_STARTED` → `RELEASE_DONE` の時間を読み、`game_mode.timing` を合わせる。

## 13. 相手リポジトリとの記録

| 日付（JST） | この文書の版 | UFO-DeviceHub のコミット | プロトコル版 | 内容 |
|---|---|---|---|---|
| 2026-11-16 | v0.3（初版） | `f98999f`（`pc/` のコピー元。`__init__.py` に記録） | 1 | 既存のコマンド・イベントだけで実装。`pc/protocol.py` を `1302bac` → `f98999f` に更新（`DialState.SETTINGS` の追加だけ）。LED の契約（`docs/game-mode-interface.md`）は未作成 |
| 2026-11-16 | v0.3（LED 契約の取り込み） | `e965cdf`（UFO-DeviceHub PR #9。`pc/` 一式をコピーし直し: `protocol.py` `device_gateway.py` `mock_hub.py`、新規 `trace.py` `game_mode.py`） | 1（追加のみ。ファームウェア 0.3） | `SET_DIAL_COLOR` / `SET_DIAL_EFFECT` を §8 の表のとおり送る。号機色の初期値を DeviceHub の既定色に合わせた。`RELEASE_DONE` が来ないときは契約 §7 のとおり `GET_STATUS` で確かめる。既存コマンド・イベントの意味は変わっていない。Mock のみ・実機未検証 |
