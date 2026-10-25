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
| G / F | 成功 / 失敗演出 |
| F1 / Tab | デバッグパネル表示切替 |

デバッグパネルでできること: 仮想 XYZ 目標、XYZ ランダム同時移動、モック速度・加速度・通信レート、重力・減衰・UFO 質量・セグメント数・反復回数・ロープ巻き取り速度・最短/最長・揺れ誇張、カメラ俯角・奥行き倍率・XY 表示倍率・ロープ太さ・ピクセルスケール、表情の固定、Mock 切断/再接続、FPS と物理演算時間、テストシナリオ 1〜10 + 掴みサイクル。USB カメラ 2 台（俯瞰 / アーム先のフォーカス）の全画角表示と、どのカメラをどの役割に使うかの選択。

### USB カメラとスコープ

- カメラは 2 台。**俯瞰カメラ**（机の上を見下ろす。将来のジェスチャー検出用）と、**フォーカスカメラ**（アームの先）。`config/game_config.json` の `camera.overview.match` / `camera.focus.match` にカメラ名の一部を書くと自動で割り当てる（デバッグパネルでも選べる）。初回は mac のカメラ許可を求められる。
- 横移動が止まって少し静止したとき、アームの上下中、`LOWERING` 中に、UFO が望遠鏡を覗くポーズをとり、UFO の右隣（右に余裕がなければ左隣）に丸いスコープが開く。中身はフォーカスカメラ（無ければ俯瞰カメラ、どちらも無ければ砂嵐）。横に動き出すと閉じる。`camera.scope.*` で秒数やズームを変えられる。
- 映像は画面に描くだけ。保存も送信もしない。実機の制御にも使わない。

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
