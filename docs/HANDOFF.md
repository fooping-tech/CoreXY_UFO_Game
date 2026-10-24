# ハンドオフ資料 — CoreXY UFO Game

作成日: 2026-10-24 / 対象: このリポジトリを引き継ぐ開発者

## 1. 何を作ったか（30秒版）

実物の CoreXY クレーン（M5Stack Core2 ファームウェア `CoreXY_UFO`）と連動する Godot 製 2D ピクセルアートゲーム。
画面上端のロープの先に青い UFO がぶら下がり、クレーンの XYZ の動きに合わせて 3D 物理（Verlet/PBD）で揺れる。
Python バックエンドが USB シリアルと WebSocket を仲介する。**実機未接続でも全部動く**（MockRobot）。

| 状態 | 内容 |
|---|---|
| 完了 | Phase 1（ゲーム画面・ロープ物理・UFO・デバッグ UI・MockRobot） |
| 完了（実機未検証） | Phase 2（SerialService / WebSocket / 実機ドライバ）、Phase 3（Vision インターフェース + YOLO/MediaPipe 実装） |
| 未着手 | Phase 4（サウンド、演出強化、UFO の個性） |
| 実機で決める必要あり | `backend.z_sign`, `z_counts_per_unit`, `arm_open_turns`（config/game_config.json） |

## 2. 環境

- macOS / Apple Silicon。Godot 4.7.2（`brew install --cask godot`）、uv 0.9（`brew install uv`、Python 3.12+ 自動取得）
- Godot CLI: `/Applications/Godot.app/Contents/MacOS/Godot`
- ファームウェアのソース: 兄弟ディレクトリ `../CoreXY_UFO`（https://github.com/fooping-tech/CoreXY_UFO）

## 3. ディレクトリと責務

```
game/                       Godot 4 プロジェクト
  scripts/physics/rope_simulator.gd   3D ロープ物理（純粋計算、ノード非依存）
  scripts/physics/projection.gd       3D → 2D 投影（俯角 + ピンホール）
  scripts/physics/rope_view.gd        ロープ描画
  scripts/character/ufo_character.gd  UFO 表情・ポーズ（物理とは分離）
  scripts/robot/robot_state.gd        [Autoload] 実機/モックの状態。Z 逆マッピングとアンカー変換
  scripts/robot/mock_robot.gd         仮想クレーン + テストシナリオ
  scripts/network/websocket_client.gd WebSocket クライアント（request_id, ACK/NACK, timeout, 再接続）
  scripts/game/game_state.gd          [Autoload] ゲーム演出状態機械（イベント駆動）
  scripts/game/game_config.gd         [Autoload] config/game_config.json 読み込み
  scripts/game/main.gd                配線: RobotState → sim → projection → view/UFO
  scripts/ui/debug_ui.gd              デバッグパネル（コードで構築、tscn 編集不要）
  tests/run_tests.gd                  ヘッドレス物理テスト（26 件）
backend/                    Python（uv）
  src/corexy_ufo_backend/serial_service/   protocol.py（行解析）, transport.py（pyserial スレッド）, service.py（ACK/完了待ち）
  src/corexy_ufo_backend/robot/            interface.py, mock_robot.py, real_robot.py, state.py
  src/corexy_ufo_backend/websocket/        server.py（JSON ブリッジ）
  src/corexy_ufo_backend/vision_service/   base.py, service.py, yolo_detector.py, mediapipe_hands.py, cloudflare_detector.py（抽象のみ）
  tests/                                   32 件（conftest.py の FakeFirmware が実機応答を再現）
config/game_config.json     Godot と Python が共有する設定（可動範囲、物理初期値、投影、通信）
docs/firmware_protocol.md   実機のシリアル仕様（ソースから確認した事実のみ）
docs/test_report.md         検証済み / 未検証 / 既知課題
```

## 4. データの流れ

```
実機 (USB serial 115200) ──pyserial──▶ SerialService ──▶ RealRobot.snapshot()
MockRobot(Python) ───────────────────────────────────────▶ (同じ RobotInterface)
                                                              │ robot_state JSON 30Hz
                                                              ▼
Godot WebSocketClient ──▶ RobotState(Autoload) ◀── MockRobot(GDScript, デフォルト)
                              │ playback_pose(dt)
                              ▼
            anchor_for_xy(x,y) → sim.anchor      rope_length_for_z(z) → sim.target_rope_length
                              ▼
                    RopeSimulator.step(1/60)  →  Projection25D.project()  →  RopeView / UfoCharacter
                              ▼
            GameState(Autoload) が RobotState と vision_event から演出状態を決める → UFO.mood
```

設計上の約束:
- 物理演算の結果は**実機に送らない**（表示専用）。
- `RobotState`（実機の物理状態）と `GameState`（演出状態）は別物。
- UFO の座標を直接書かない。アンカーを動かし、物理で遅れて追従させる。
- 実機 Z が上がる → 画面ロープが長くなる → UFO が下がる（逆マッピング）。
- 座標系: ワールド +X 右、+Y 上（重力 −Y）、+Z 手前。実機 X → ワールド X、実機 Y（奥）→ ワールド −Z、実機 Z → ロープ長。単位 cm。実機は mm、Z は 0..100 の抽象単位。

## 5. 実機なしでテストする方法

### A. Godot 単体（最も手軽）

```bash
cd game
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

起動直後から MockRobot に接続済み。右側のデバッグパネルで:
- X / Y / Z スライダー、`XYZ random`、`E-STOP`、`Mock disconnect` / `reconnect`
- 物理・投影パラメータをその場で変更
- 「Test scenarios」の 1〜10 ボタン（X往復 / Y往復 / XY斜め / 急停止 / Z下降上昇 / XYZ同時 / 通信切断 / 再接続 / 上下限 / ロープ長急変）+ Grab cycle
- 表情の固定（Character のドロップダウン）、Success / Failure / Error ボタン

キー: ←→ X、↑↓ Y、W/S Z、Space 急停止、G/F 成功/失敗、F1 パネル非表示。

コマンドラインからシナリオ再生とフレーム保存:
```bash
Godot --path . -- --scenario sudden_stop
Godot --path . -- --scenario xyz_together --capture /tmp/frames   # 0.5 秒毎に PNG、終了時に FPS 表示
Godot --path . -- --scenario xy_diagonal --log-motion /tmp/motion.csv --quit-after 10   # 物理 tick / 描画フレームごとの値を CSV に記録
```

### B. 自動テスト

```bash
cd game && /Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://tests/test_runner.tscn   # 26 件、終了コードで合否
cd backend && uv sync && uv run pytest                                                                     # 32 件
```

### C. バックエンド込み（WebSocket 経路の確認）

```bash
cd backend && uv run corexy-ufo-backend --mock          # ターミナル 1
cd game && Godot --path . -- --source websocket          # ターミナル 2（またはパネルで Robot source を切替）
```
パネルで `Backend: enable motors` → `home` → `z_zero` → スライダー操作。ログ欄に `ack` / `nack` が出る。
`stop` を押すと ALARM（ファームウェア仕様を再現）になり、`clear_alarm` → `home` が必要。
Python から直接叩く例は `websockets` で `{"type":"command","request_id":"1","data":{"name":"home","params":{}}}` を送るだけ（README 参照）。

### D. FakeFirmware で実機応答を増やす

`backend/tests/conftest.py` の `FakeFirmware.write_line()` にコマンド分岐を足すと、実機の行形式のまま挙動を再現できる。行形式は `docs/firmware_protocol.md` に一覧。

## 6. 実機を初めてつなぐときの手順

1. 既存 WebUI（`CoreXY_UFO/tools/webui`）を止める（同じポートは同時に開けない）。
2. `uv run corexy-ufo-backend --list-ports` → `--port /dev/cu.usbserial-XXXX` で起動。
3. Godot を `--source websocket` で起動。`enable motors` → `home`。
4. **アームを手で最上位にして `z_zero`**（ファームウェアに Z ホーミングは無い）。
5. Z スライダーを少し下げ、実機のアームが「下がる」ことを確認。逆なら `config/game_config.json` の `backend.z_sign` を `-1` にして再起動。
6. ドラム 1 回転あたりの実際の上下量から `z_counts_per_unit` を決める（4096 count/回転、既定は 3 回転 = 100 単位）。
7. アーム開閉量 `arm_open_turns` を合わせる。
8. デバッグパネルで重力・減衰・揺れ誇張を実機の見た目に合わせ、値を `config/game_config.json` に書き戻す。

## 7. 知っておくべき制約（ファームウェア由来）

- Z/アーム専用コマンドは無い。`TEST_MODE ON` 中の `SERVO_TURN <id> <turns>`（≤3 回転/回）のみ。
- 移動中は `POS` に応答しない → 移動中 XY は推定（`measured:false`）。
- ホストウォッチドッグ無し → USB を抜いても実機は止まらない。バックエンド終了時は `ABORT` を送るが、物理的な抜去には無力。ファームウェア側のハートビート監視追加を推奨。
- `ABORT` はアラーム + HOMED 解除。

## 8. 次のタスク候補

1. 実機接続と §6 のパラメータ確定。
2. ファームウェアにホストハートビート（例: N 秒無通信で ABORT）を追加する提案。
3. Phase 4: サウンド、成功時の演出強化、UFO の台詞/個性、待機中のアイドル演出。
4. 物体検出結果（`vision_event: objects`）から成功判定を出す `GameState` の遷移（現在は `result_success` / `result_failure` イベントを手動/外部から投げる形）。
5. Godot エクスポート（macOS .app）と `config/` 同梱の確認（`game_config.gd` は実行ファイル横の `config/` も探す）。
