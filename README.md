# CoreXY UFO Game

実物の CoreXY 方式 UFO キャッチャー（M5Stack Core2 ファームウェア: `CoreXY_UFO`）と連動する、macOS 向け 2D ピクセルアートゲームです。
画面上端から垂れ下がるロープの先に青い UFO がつながっていて、現実のクレーンの XYZ の動きに合わせて 3D 物理シミュレーションで揺れます。

```
CoreXY_UFO_Game/
├── game/        Godot 4 プロジェクト（ゲーム画面・ロープ物理・UFO・デバッグUI・MockRobot）
├── backend/     Python 3.12+ / uv（USBシリアル・WebSocket・カメラ認識）
├── config/      game_config.json（Godot と Python で共有）
├── assets/      元画像とスプライトシート（Codex 製作、game/assets にコピー済み）
├── tools/       スプライトシート生成スクリプト
└── docs/        firmware_protocol.md（実機通信仕様）, test_report.md（検証結果）
```

## 必要なもの（macOS / Apple Silicon）

- Godot 4.4 以上（検証: 4.7.2）: `brew install --cask godot`
- uv: `brew install uv`（Python 3.12+ は uv が自動取得）
- 実機接続時のみ: M5Stack Core2 + USB ケーブル（CP210x/CH9102 ドライバ）

## Phase 1: 実機なしでゲームを起動する

```bash
cd CoreXY_UFO_Game/game
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

または Godot エディタで `game/project.godot` を開いて ▶ を押します。
起動時は **MockRobot**（仮想クレーン）に接続された状態で、右側にデバッグパネルが出ます。

操作:

| キー | 動作 |
|---|---|
| ← → | X 移動（左右）。実機接続中は押している間だけ動く（JOG、40 mm/s） |
| ↑ ↓ | Y 移動（奥 / 手前）。実機接続中は同上 |
| W / S | Z（アーム上昇 / 下降 → 画面の UFO は下降 / 上昇）。実機接続中は押している間だけ動く（原点復帰前でも可）。最初に W でアームを一番上まで上げて、デバッグパネルの「z_zero」を押す |
| Space | 停止（Mock は即停止。実機接続中は減速停止 `STOP`、アラームにならない） |
| V | スコープ（望遠鏡ビュー）を手動で開閉 |
| H | ハンドジェスチャー操作の ON / OFF |
| G / F | 成功 / 失敗演出 |
| F1 / Tab | デバッグパネル表示切替 |

デバッグパネルでできること: 仮想 XYZ 目標、XYZ ランダム同時移動、モック速度・加速度・通信レート、重力・減衰・UFO 質量・セグメント数・反復回数・ロープ巻き取り速度・最短/最長・揺れ誇張、カメラ俯角・奥行き倍率・XY 表示倍率・ロープ太さ・ピクセルスケール、表情の固定、Mock 切断/再接続、FPS と物理演算時間、テストシナリオ 1〜10 + 掴みサイクル。USB カメラ 2 台（俯瞰 / アーム先のフォーカス）の全画角表示と、どのカメラをどの役割に使うかの選択。

### USB カメラとスコープ

- カメラは 2 台。**俯瞰カメラ**（机の上を見下ろす。ハンドジェスチャーの認識にも使う。C270）と、**フォーカスカメラ**（アームの先。Innomaker U20CAM）。`config/game_config.json` の `camera.overview.match` / `camera.focus.match` にカメラ名の一部を書くと自動で割り当てる（デバッグパネルでも選べる）。初回は mac のカメラ許可を求められる。
- 横移動が止まって少し静止したとき、アームの上下中、`LOWERING` 中に、UFO が望遠鏡を覗くポーズをとり、UFO の右隣（右に余裕がなければ左隣）に丸いスコープが開く。中身はフォーカスカメラ（無ければ俯瞰カメラ、どちらも無ければ砂嵐）。横に動き出すと閉じる。`camera.scope.*` で秒数やズームを変えられる。
- 映像は画面に描くだけ。保存も送信もしない。スコープの映像は実機の制御に使わない（ジェスチャー認識は下記）。

### ハンドジェスチャー・ジョイスティック

親指と人差し指をつまむと、**つまんだ位置が中心の仮想ジョイスティック**になり、手を前後左右に動かした分だけクレーンの XY が**速度で**動く。指を離すと止まる。UFO とロープはこれまでどおり実機（Mock）の状態から物理で描く（手の位置で UFO を動かすことはしない）。

```bash
./start.sh gesture                      # Python の MockRobot + C270 で認識 + ゲーム（ジェスチャー ON）
./start.sh game --gesture-demo          # カメラなし: 決まった手の動きを流してゲーム内 Mock を操縦
./start.sh real /dev/cu.usbserial-XXXX --gesture   # 実機（ゲームもジェスチャー ON で起動。enable motors → home の後に操縦）
```

- 初回は `backend/models/hand_landmarker.task`（MediaPipe の公式モデル、Apache-2.0、約 7.8 MB）を自動でダウンロードする。依存は `uv sync --extra vision --extra hands`（`start.sh` が `--gesture` を見て入れる）。
- ゲーム内の MockRobot でもカメラ操作を試せる: `./start.sh backend --mock --gesture` を別に起動し、`./start.sh game` で H を押す（ゲームはバックエンドからジェスチャーだけを受け取る）。カメラが無ければデバッグパネルの「Sim hand (mouse)」で、プレイ画面上のマウス（左ボタン = つまむ）が手の代わりになる。
- 操作: H で ON → 手をカメラに見せる → つまむ（「操縦開始！」）→ 手を動かす方向に進む（中心に戻すと止まる）→ 離すと止まる。手を動かせる範囲が足りなくなったら、離して手を戻し、もう一度つまむ（クラッチ）。クレーンの位置はそのまま。
- 止まる条件（どれも速度を即ゼロにし、**指を離して新しくつまむまで再開しない**）: 指を離す、手を見失う、手が 2 つ写る、認識イベントが `gesture.stale_ms`（250 ms）より古い、カメラが外れる、WebSocket が切れる、ゲームのウィンドウが非アクティブ、Space、アラーム、キーボード操作（キーが優先）、ジェスチャー OFF、実機の準備ができていない。認識が途切れたときなどは、ゼロ JOG に加えて減速停止（`soft_stop`）も送る。
- 実機の条件: 接続済み・モーター有効・原点復帰済み・アラームなし・ほかの移動コマンドが動いていない。ジェスチャーがホーミングやモーター有効化を始めることはない。`gesture.allow_real_robot` が false なら実機ではジェスチャーで動かさない（Mock での確認後、true にした）。
- 実機を止める仕組み: ファームウェアと Mock は最後の JOG から 250 ms で止まる。加えてバックエンドは、JOG を送っていたクライアントが切断したときと、JOG の更新が 300 ms 途絶えたとき（ゲームが固まった）にゼロ JOG を送る。**カメラによる接触・挟み込みの検出は安全機能ではない**。手をクレーンの可動範囲に入れない運用と、物理的な非常停止を前提にすること。操作領域を可動範囲の外に限るには `gesture.roi` / `roi_enabled`（デバッグパネルでも調整可）。
- ゲーム画面左下の HUD に、ジェスチャー用カメラの小さなライブ映像と、手のひら中心（灰 / 水色 / 金 = 未検出 / 検出 / つまみ中）・スティックの輪を表示する。手が画角の端（10% 以内）に近づくと枠が黄色に、端から外へ出て見失うと赤く点滅して「カメラの外に出たよ」と、戻す方向の矢印を出す。
- デバッグパネルの俯瞰カメラの映像に、検出状態を重ねて表示する: 手のひら中心（灰 = 未検出、水色 = 検出、金 = つまみ中）、つまんだ中心とスティックの輪、ROI、状態の 1 行。手の骨格はバックエンドを `--gesture-landmarks` 付きで起動したとき（`./start.sh gesture` は付ける）。
- 効果音: パーの手を検出したら小さく「ポン」（0.6 秒に 1 回まで）、つまみを検出したら「ピポッ」、ピンチをやめて手を開いたら「ポピッ」、操縦が途切れたら（見失い・2 つの手・期限切れ・カメラ外れ・切断）「ブブー」。ゲーム内で合成する 8bit 風の音で、`audio.cue_pinch` / `audio.cue_lost` に mp3 のファイル名を書けば差し替えられる。
- 向きの合わせ方: 手を右へ動かして UFO が左へ行くなら「Invert X」、奥 / 手前が逆なら「Invert Y」、前後と左右が入れ替わっていれば「Swap XY」（デバッグパネル）。決まった値は `gesture.joystick.invert_x` などに書く。
- 主な初期値（`config/game_config.json` の `gesture`）: ピンチ開始 1.0 / 解除 1.5（指先の距離 ÷ 手の大きさ = 人差し指〜小指の付け根の幅と 0.75 × 手首〜中指の付け根の長さの大きいほう。C270 で手で調整した値。解除には手を大きく開く必要があるので、パーで比率が 1.5 を超えることを確かめておく）、確定 0 ms、見失いの猶予 300 ms（素早く動かした手のブレ対策）、MediaPipe の追跡の信頼度 0.3（いずれもデバッグパネルのスライダーで、動かしながら調整できる）、スティック半径 = 画像短辺の 15%、デッドゾーン 12%、最大速度に達する位置 80%、最大 30 mm/s、カーブ 1.5 乗、スムージング 80 ms、期限 250 ms、ARMED の表示 120 ms。

コマンドラインから直接シナリオを再生することもできます。

```bash
Godot --path . -- --scenario sudden_stop          # x_sweep y_sweep xy_diagonal sudden_stop z_down_up xyz_together disconnect reconnect limits rope_snap grab_cycle
Godot --path . -- --scenario xyz_together --capture /tmp/frames   # 0.5秒毎に PNG 保存して FPS を表示後に終了
Godot --path . -- --scenario xy_diagonal --log-motion /tmp/motion.csv --quit-after 10   # 動きのログ（チャタリング調査用 CSV）
```

### 物理テスト（ヘッドレス）

```bash
cd game
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://tests/test_runner.tscn
```

36 項目（ロープが伸びない・UFO がロープ長を超えない・静止で発散しない・急停止で振り子になり減衰する・斜め移動で前後揺れが出る・Z 逆マッピング・投影でロープ端と UFO が一致・1 ステップの計算時間・`game/assets` と `assets` の同期・スプライト metadata・表情とポーズのエフェクト表示）を検証します。

### スプライトの再生成

```bash
python3 tools/build_ufo_assets.py assets/source/ufo_expression_master.png assets/source/ufo_action_character_master.png
```

`assets/` に書き出して `game/assets/` に同期します（Pillow が必要）。アクションポーズはキャラクターのみで、スピード線や汗は `assets/effects/ufo_action_effects.png` のオーバーレイとして重ねて描画します。

## Phase 2: 実機（バックエンド経由）

```bash
cd backend
uv sync                      # 基本（pyserial, websockets, numpy）
uv run pytest                # 31 テスト（ファームウェア応答を模した FakeFirmware で検証）

uv run corexy-ufo-backend --mock                 # 実機なし。WebSocket だけ立ち上げる
uv run corexy-ufo-backend --list-ports
uv run corexy-ufo-backend --port /dev/cu.usbserial-XXXX
```

Godot 側はデバッグパネルの「Robot source」を **WebSocket backend** に切り替えるか、`-- --source websocket` で起動します。
接続後の手順（安全のため起動時はモーター操作無効）:

1. `Backend: enable motors`（アーミング）
2. `home`（`HOME` → `HOME complete` 待ち）
3. アームを手で最上位に合わせて `z_zero`（Z 基準。ファームウェアに Z ホーミングはない）
4. X / Y / Z スライダー → `XY` / `SERVO_TURN 1` が送られ、`ACK`/`NACK` がログに出ます
5. `E-STOP` → `ABORT`。以後は `clear_alarm` と `home` が必要です

WebSocket メッセージ例:

```json
{"type":"robot_state","timestamp":1730000000000,"data":{"connected":true,"homed":true,"motors_enabled":true,"state":"MOVING_XY","x":120.0,"y":80.0,"z":100.0,"measured":false,"alarm":false,"error":""}}
{"type":"command","request_id":"g12-3","data":{"name":"move_xy","params":{"x":120,"y":80}}}
{"type":"ack","request_id":"g12-3","timestamp":1730000000100,"data":{"command":"move_xy","x":120.0,"y":80.0}}
```

コマンド: `enable_motors{enable}`, `home`, `move_xy{x,y,feed?}`, `move_z{z}`, `z_zero`, `grab{close}`, `stop`, `clear_alarm`, `get_state`, `list_ports`。同じ `request_id` の再送はキャッシュ済み結果を返し、二重実行しません。

実機の座標系・コマンド・制約の詳細は [docs/firmware_protocol.md](docs/firmware_protocol.md) を参照してください。
特に **`backend.z_sign`（どちらの回転でアームが上がるか）は実機で確認して `config/game_config.json` に設定**してください。

## Phase 3: カメラ・認識（インターフェース + 実装）

```bash
uv sync --extra vision                       # opencv
uv sync --extra vision --extra hands         # + MediaPipe
uv sync --extra vision --extra yolo          # + ultralytics
uv run corexy-ufo-backend --mock --camera 0:objects --camera 1:hands --detector yolo --hands
uv run corexy-ufo-backend --mock --camera 0:objects,hands --detector yolo --hands   # 1台共有
```

認識結果は `vision_event`（`objects`, `object_appeared`, `object_disappeared`, `hands`, `gesture`）として Godot に届き、`GameState.post_event()` に流れます。
Cloudflare API は仕様が既存リポジトリで確認できなかったため、`CloudflareDetector` は抽象インターフェースのみで架空のエンドポイントは持ちません。

## 設計の要点

- **ロープ物理**（`game/scripts/physics/rope_simulator.gd`）: 3D Verlet + 距離拘束（PBD）。上端は実機 XY から決まる可動アンカー、下端に UFO 質量。1 tick を 16 サブステップに分け、各サブステップで全セグメントを三重対角の直接解法で一度に拘束し、長距離拘束（アンカーからの距離 ≤ 弧長）で伸びない。ロープ長変更時はアンカー中心に形状をスケーリング（巻き取り）。
- **投影**（`projection.gd`）: 固定カメラを X 軸まわりに俯角回転 → ピンホール分割。ロープ全質点と UFO が同じ関数を通る。
- **Z 逆マッピング**（`robot_state.gd: rope_length_for_z`）: アーム最上位 → ロープ最長 → UFO 最下位。
- **状態分離**: `RobotState`（実機/モックの物理状態） と `GameState`（演出状態、イベント駆動）。物理演算結果は実機に送らない。
- **安全**: 起動時モーター無効、`enable_motors` 必須、ホスト側ソフトリミット、`stop` は常時受付、`request_id` 重複排除、応答タイムアウト、切断検知。ファームウェアの安全機構は変更していない。

## 既知の制約

- ファームウェアは移動中に位置を返さないため、移動中の XY は推定値（`measured:false`）。
- ファームウェアにホストウォッチドッグがなく、USB 切断時に実機が自動停止しない（docs/test_report.md 参照）。
- Z はサーボ絶対カウントの相対値で、`z_zero` を起動ごとに行う必要がある。
