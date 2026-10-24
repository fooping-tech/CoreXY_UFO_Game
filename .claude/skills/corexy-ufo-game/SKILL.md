---
name: corexy-ufo-game
description: >
  CoreXY_UFO_Game（実機 CoreXY クレーンと連動する Godot 4 製のロープ+青い UFO ピクセルアートゲームと
  Python WebSocket/シリアルバックエンド）専用の設計制約・作業手順・テスト手順。このリポジトリの
  game/ backend/ config/ tools/ assets/ を変更・調査・デバッグ・テストするときは最初に読む。
  対象: UFO の表情/ポーズ/アニメーション、ロープの揺れ・3D Verlet 物理・2.5D 投影、RobotState/GameState、
  MockRobot、WebSocket・request_id・ACK/NACK、実機同期（XY、Z 軸、z_sign、z_zero、ロープ長の逆マッピング）、
  E-STOP/ABORT/ALARM、通信切断、game_config.json、スプライトシート、演出・ゲーム体験、headless テスト。
  例:「UFOの表情を増やして」「ロープの揺れを改善して」「実機のZ軸と同期して」「急停止の演出」
  「切断時の表示」「バックエンドにコマンド追加」。汎用の Godot / game-feel / physics の知識は
  このスキルを読んだ後に該当 gamedev スキルへ。
---

# CoreXY UFO Game — プロジェクト専用スキル

**画面上のピクセルアート UFO が、現実のロボットを通して机の上の物に働きかけるゲーム。**
現実の CoreXY（XY）とドラム式 Z を、画面上端から垂れるロープとその先の青い UFO で表現する。
画面にクレーンアームは描かない。ロープは飾りではなく、実機の XYZ に追従する 3D 物理。

体験の優先順位は常に **操作 → 工夫 → 結果 → リアクション**。
企画にある「片付けスコア」などの未実装要素を既存機能として扱わないこと（[gameplay-and-animation.md](references/gameplay-and-animation.md) §4）。

## 0. 作業を始める前に（毎回）

1. 依頼を分類する。**ゲーム演出・物理の変更**か**実機制御の変更**か。両方にまたがる依頼は分けて実装・報告する。
2. 下の表から触るコンポーネントの行を読み、該当ファイルと文書を開く。
3. `git status` で未コミットの作業（特に `assets/` と `game/assets/` の差異）を確認する。他人の作業中の変更を巻き込まない。
4. 変更前に回帰テストを一度走らせて基準を取る（§6）。

| 触るもの | まず読むコード | 文書 / reference |
|---|---|---|
| 全体・データの流れ | `game/scripts/game/main.gd` | [references/architecture.md](references/architecture.md), `docs/HANDOFF.md` §3-4 |
| ロープ・揺れ・投影 | `physics/rope_simulator.gd`, `physics/projection.gd`, `main.gd::_physics_process` | [references/rope-physics.md](references/rope-physics.md) |
| UFO 表情・演出 | `character/ufo_character.gd`, `main.gd::_mood`, `game/scripts/game/game_state.gd`, `assets/ufo/ufo_metadata.json` | [references/gameplay-and-animation.md](references/gameplay-and-animation.md) |
| 実機・通信・安全 | `backend/src/corexy_ufo_backend/robot/real_robot.py`, `serial_service/`, `websocket/server.py`, `network/websocket_client.gd` | [references/robot-protocol.md](references/robot-protocol.md), `docs/firmware_protocol.md` |
| Z 軸・座標変換 | `robot/robot_state.gd`, `config/game_config.json`, `real_robot.py::move_z` | [references/architecture.md](references/architecture.md) §3, [robot-protocol.md](references/robot-protocol.md) §3 |
| テスト | `game/tests/run_tests.gd`, `backend/tests/conftest.py` | [references/testing.md](references/testing.md), `docs/test_report.md` |

パスの省略: ゲーム側は `game/scripts/`、バックエンド側（`serial_service/` など）は `backend/src/corexy_ufo_backend/` からの相対。

## 1. 絶対に守る設計原則

1. **状態の分離。** `RobotState`（実機/モックの位置・接続・動作状態）と `GameState`（進行・演出・イベント）は別物。演出コードから `RobotState` の位置を書かない。`RobotState` に書いてよいのは `MockRobot` と `UfoWebSocketClient` だけ。
2. **物理は表示専用。** `RopeSimulator` の結果をモーター指令に変換しない。実機へのコマンドは `UfoWebSocketClient.send_command()` → `GameServer.execute()` → `RobotInterface` の経路だけを使う。
3. **UFO の座標を直接書かない。** アンカー（`sim.anchor`）とロープ長（`sim.target_rope_length`）を動かし、UFO は物理で遅れて追従させる。演出の誇張は描画側（スプライトの回転・スケール・エフェクト）か設定値（`swing_gain` など）で行う。
4. **Z は逆マッピング。** アームが上がる → ロープが長くなる → UFO は下がる。アームが下がる → ロープが短くなる → UFO は上がる。変換は `RobotState.rope_length_for_z()` だけが担う。
5. **同一投影。** ロープの全質点と UFO は必ず `Projection25D.project()` を通す。別の変換で UFO を置かない。
6. **ロープは自前の 3D Verlet/PBD。** 60 Hz 固定ステップ、可動アンカー、長さ可変、距離拘束、3 次元の揺れ。`RigidBody` や `Joint` に置き換えない。
7. **安全機構を弱めない。** 起動時はモーター無効、`enable_motors` が必要、ホスト側ソフトリミット、`stop` は常に受け付ける、`request_id` で重複を排除、モーションコマンドは自動再送しない。
8. **切断を検知しても停止は保証されない。** ファームウェアにホストウォッチドッグはない。ソフトウェアの `stop`/`ABORT` は電源遮断とは違う。UI や報告でこれらを同一視しない。
9. **アセットの画風を守る。** Codex 製のスプライトシート（64×64、ニアレスト、接続点 (32,5)）を使い続ける。画面にクレーンアームを追加しない。
10. **事実・設定値・未校正を区別する。** `z_sign` / `z_counts_per_unit` / `arm_open_turns` は**実機で未確認**。ファームウェアにないコマンドを作らない。

## 2. コンポーネントの責務と変更禁止事項

| コンポーネント | 責務 | やってはいけないこと |
|---|---|---|
| `RobotState`（Autoload） | 実機のサンプルの保持、補間、mm→ワールド変換（`anchor_for_xy`, `rope_length_for_z`） | 演出のために値を書き換える。変換を他の場所に複製する |
| `GameState`（Autoload） | 演出状態機械。イベント駆動（`post_event`） | 実機へコマンドを送る。`machine_state` を上書きする |
| `RopeSimulator` | 純粋計算のロープ物理（ノード非依存） | 描画・ノード・`RobotState` を参照する。テストを通すために定数を緩める |
| `Projection25D` | 3D→画面座標 | UFO だけ別の投影にする |
| `RopeView` / `UfoCharacter` / `effects.gd` | 描画とリアクション | 物理や実機の状態に書き戻す |
| `MockRobot`（GDScript） | 実機なしでの仮想クレーンとテストシナリオ | 実機にない能力（移動中の実測位置など）を前提にした演出を作る |
| `UfoWebSocketClient` | WS 接続、`robot_state` の取り込み、コマンド送信、タイムアウト | モーションコマンドを自動で再送する |
| Python `GameServer` | JSON ブリッジ、`request_id` キャッシュ、モーションロック | `stop` をロックや busy で拒否する |
| `RealRobot` / `SerialService` | ファームウェアの行プロトコルへの対応付け | ファームウェアにないコマンドを送る。完了行の正規表現を緩めて失敗を成功扱いにする |
| `config/game_config.json` | Godot と Python が共有する設定 | 実機で未確認の値を「確定」とコメントする |

## 3. 典型的な改修パターン

### A. 「UFO の表情・リアクションを増やして」
1. **まず既存フレームを使う。** 未使用のフレームがある: 表情 `happy` `sad` `wink` `sleepy` `excited`、ポーズ `resist_side` `release_stretch` `exhausted`、アニメ `swing` `release`。
2. 状態を足すなら `GameState`（ゲームの状態）→ `main.gd::_mood()`（mood への対応付け）→ `ufo_character.gd::_tick_face / _on_mood_changed`（見た目）の順に配線する。物理から作る手がかり（加速度、張力など）は `update_motion()` の引数として渡す。
3. 新しい絵が必要なら `tools/build_ufo_assets.py` を通す（`game/assets/` への同期まで自動）。ポーズの絵はキャラクターだけにし、スピード線や汗は `action_effects` のオーバーレイに描く（[gameplay-and-animation.md](references/gameplay-and-animation.md) §5）。
4. テスト: デバッグパネルの Character で固定表示して確認し、状態遷移は `_test_ufo_faces_and_pose_effects` に追加する。

### B. 「ロープの揺れを改善して」
1. 症状を物理（`rope_simulator.gd`）、入力の質（`RobotState.playback_pose` のサンプル列、推定位置、teleport）、見た目（投影・`rope_view.gd`・UFO の傾き）のどれかに切り分ける。多くは物理ではなく入力か見た目が原因。
2. まずデバッグパネルの値（`damping`, `ufo_drag`, `swing_gain`, `substeps`, 投影）で調整し、決まった値を `config/game_config.json` に書き戻す。
3. ソルバーを変えるなら伸びなし・UFO がロープ長を超えない・減衰・性能のテストを全部通す。詳細は [rope-physics.md](references/rope-physics.md)。

### C. 「実機の Z 軸と同期して」
1. 3 つの層を混同しない: **ゲームの Z 単位**（0..100、`z_up_is_positive`）、**サーボの回転方向**（`z_sign`）、**基準点**（`z_zero` = アーム最上位、ファームウェアに Z ホーミングなし）。
2. ゲーム側の逆マッピング（`rope_length_for_z`）は正しい前提で触らない。ずれは backend の換算（`z_sign`, `z_counts_per_unit`）か基準設定の手順で直す。
3. 実機での確認が必要（§5）。手順は `docs/HANDOFF.md` §6。詳細は [robot-protocol.md](references/robot-protocol.md) §3。

### D. 「急停止・切断・アラームの演出」
1. E-STOP は `ABORT` を送る → ALARM になり HOMED が解除される → `clear_alarm` → `home` が必要。演出は「止まったように見える」ことと「実機が止まった」ことを区別して表示する。
2. 切断時の表示は困惑（`worried`）。「安全に停止しました」のような保証する文言は出さない。
3. 既知のずれ（GDScript の Mock と実機の違い、Space キーの挙動、ERROR からの復帰）を [robot-protocol.md](references/robot-protocol.md) §5 で確認してから設計する。

### E. 「バックエンドにコマンドを追加・プロトコル変更」
1. `docs/firmware_protocol.md` と兄弟リポジトリ `../CoreXY_UFO` のソースで、そのコマンドが実在するかを確認する。なければファームウェア側への要望にとどめる（`docs/HANDOFF_FIRMWARE.md` の流儀）。
2. `COMMANDS` / `MOTION_COMMANDS`（`server.py`）、`RobotInterface`、`MockRobot`、`RealRobot`、`FakeFirmware`（`conftest.py`）を一緒に更新する。
3. この作業はゲーム演出の変更と別のコミットにする。

## 4. 発生しやすい不具合と診断

| 症状 | まず疑う場所 | 診断 |
|---|---|---|
| UFO がロープの端からずれる | 投影を通っていない描画、`rope_attachment_local` | `projection: rope end and UFO coincide` テスト、フレームごとの接続点（metadata） |
| Z を上げたら UFO も上がる | 逆マッピングを迂回した、`z_up_is_positive` か `z_sign` の取り違え | `Z inverse` テスト。実機なら `z_sign` を確認 |
| ロープが伸びる・暴れる・NaN | ソルバー変更、`max_step`、teleport の処理 | `_max_stretch`、`motion:`・`pendulum:` テスト。`--scenario rope_snap` |
| ロープがガタつく・振り子が速すぎる | 入力のタイミング（壁時計で補間・外挿していないか）、サブステップ数 | `playback:` テスト。`--log-motion` でアンカーの tick ごとの移動量が一定か |
| 表情・傾きがチャタリングする | `_process` で差分を取っていないか（描画 ~110 FPS > 物理 60 Hz） | 手がかりは `main.gd::_store_tick`（物理 tick）で計算する。`--log-motion` の R 行で face の切り替わり回数 |
| 止まったはずの値が細かく振れる | MockRobot の軸制御（目標の周りで振動） | `mock:` テスト、Python の `test_mock_robot_settles_on_target` |
| 停止後の揺れが実物と合わない | 移動中 XY は推定（`measured:false`、smoothstep） | `RobotState.position_is_measured` を表示する。物理ではなく入力の問題 |
| 再接続でロープが鞭のように振れる | 25 cm 超の teleport 判定（`main.gd`） | `--scenario reconnect` |
| 表情が変わらない | `manual_expression` 固定、mood の優先順位（panic > mood）、`_last_expr_shown` | デバッグパネル Character を `(auto)` に戻す |
| 実機モードで ERROR から戻らない | `GameState` は `error_cleared` でしか ERROR を抜けない | 既知の制約。[robot-protocol.md](references/robot-protocol.md) §5 |
| `move_z` が NACK になる | `z_zero` を送っていない（意図的） | ログの `Z reference not set` |
| 新しいスプライトが出ない | `--no-sync` で生成した、手で `assets/` だけ編集した、新しいファイルの `.import` がない | `assets: game/assets matches assets/` テスト。`godot --headless --path game --import` |
| ポーズのスピード線・汗が出ない / ずれる | `action_effects` が無い・セル数が `action_poses` と違う、`show_pose_effects=false` | `metadata: action_effects aligned 1:1`、`pose fx:` テスト |
| perf テストが 2 ms に近い | 初回起動のばらつき | 再実行する。安定して遅い場合のみ調べる |

## 5. 実機接続が必要かの判断

**実機が必要**（Mock でのテストだけでは「完了」にしない）:
- `serial_service/`、`real_robot.py`、完了行の正規表現、タイムアウトやポーリング間隔
- `z_sign` / `z_counts_per_unit` / `arm_open_turns` / `xy_feed_mm_min` / ソフトリミット
- 停止・アラーム・切断時に実機がどう動くかに関わる変更
- 実機の加減速と揺れのタイミングを合わせる調整

**Mock で完結する**: ロープ物理、投影、UFO の表情・アニメーション、エフェクト、`GameState` の遷移、デバッグ UI、GDScript の MockRobot とシナリオ。

**報告のルール**: 実機がつながっていない環境では「実機テスト成功」と書かない。「Mock/FakeFirmware で確認済み・実機未検証」と明記し、実機で確認する手順を添える。

## 6. 変更後のテスト

```bash
# Godot 物理・マッピング・アセット・表情（基準 46 件、終了コードで合否）
godot --headless --path game res://tests/test_runner.tscn
#   brew の godot が無ければ /Applications/Godot.app/Contents/MacOS/Godot（検証済み 4.7.2）
#   クリーンなチェックアウトでは先に: godot --headless --path game --import

# Python バックエンド（基準 32 件）
cd backend && unset VIRTUAL_ENV && uv run pytest
```

- 件数が基準より減っていないことと、終了コード 0 を確認する。機能を追加したらテストも追加する（どこに何を足すかは [testing.md](references/testing.md)）。
- 見た目の変更は `--scenario <name> --capture <dir>` でフレームを保存して確認する。
- 動きの不具合（チャタリング、ガタつき、表情のちらつき）は**推測で直さず**、まず実際にウィンドウで動かして `--log-motion <csv> --quit-after <秒>` でログを取る。ヘッドレスでは描画フレームが物理と同期してしまい、描画側の不具合が出ない。WebSocket 経路は `./start.sh mock` 相当でバックエンドを起動して取る。
- WebSocket 経路の変更は `./start.sh mock` で end-to-end を確認する。`start.sh` は WebSocket のポート（`network.websocket_url`、`--ws-port`）が使用中なら起動前に止まる（起動したままの実機用バックエンドにつながるのを防ぐため）。ゲームを起動せずに起動確認だけするなら `START_SH_NO_GAME=1 ./start.sh mock --ws-port 8799`。
- 報告には、実行したコマンド、件数、未実行の項目（実機など）を書く。

## 7. 外部 Agent Skills との使い分け

このリポジトリの `.claude/skills/` には awesome-gamedev-agent-skills が入っている。**設計判断はこのスキルが優先**し、汎用の技法だけを借りる。

| 状況 | 使うスキル | このプロジェクトでの注意 |
|---|---|---|
| GDScript の書き方 | `godot-gdscript` | 既存コードの流儀（`##` doc コメント、型付き var、Dictionary の config）に合わせる |
| headless テストの仕組み | `godot-gdscript-headless-testing` | 既存の runner は Node シーン（`test_runner.tscn`）+ `_ok()`。`--script` 方式へ移行しない |
| 演出の「気持ちよさ」 | `game-feel` | シェイクやヒットストップは**投影の後**（スプライト、エフェクト、画面オフセット）で行う。`sim.anchor` や質点を揺らさない。時間停止で物理ステップを止めない |
| 揺れの安定性・時間刻み | `physics-tuning` | 原則の参照のみ。ロープは自前の Verlet。`godot-physics` の RigidBody/Joint は使わない |
| スプライト・アセット | `create-game-assets` | 既存の Codex シートの画風・64×64・接続点を守る。`tools/build_ufo_assets.py` を通す |
| アニメーションの仕組み | `godot-animation` | UFO は metadata 駆動のコード再生。AnimationPlayer へ移行するなら理由を示してから |
| HUD・メニュー | `game-ui-ux`, `godot-ui-control` | デバッグパネルはコードで構築（`debug_ui.gd`）。プレイ画面にクレーンアームを描かない |
| 性能 | `performance-optimization` | `physics_usec`、`--capture` の FPS で計測してから直す |
| 音（Phase 4） | `audio-design`, `godot-audio` | 音は `GameState` のイベントか mood に結びつける |
| カメラ | `camera-systems` | 基本は不要。固定カメラの投影（`origin_px`）を壊す追従カメラを入れない |
| どれか分からない | `router` | このスキルを読んだ後に使う |
