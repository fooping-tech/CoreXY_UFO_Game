---
name: corexy-ufo-game
description: >
  CoreXY_UFO_Game（実機 CoreXY クレーンと連動する Godot 4 製のロープ+青い UFO ピクセルアートゲームと
  Python WebSocket/シリアルバックエンド）専用の設計制約・作業手順・テスト手順。このリポジトリの
  game/ backend/ config/ tools/ assets/ を変更・調査・デバッグ・テストするときは最初に読む。
  対象: UFO の表情/ポーズ/アニメーション、ロープの揺れ・3D Verlet 物理・2.5D 投影、RobotState/GameState、
  MockRobot、WebSocket・request_id・ACK/NACK、実機同期（XY、Z 軸、z_sign、z_set、ロープ長の逆マッピング）、
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
| 自動キャッチ（1 ボタン） | `backend/.../sequence/auto_catch.py`（状態機械）, `sequence/params.py`（校正値・範囲検査）, `robot/dry_run.py`（仮想クレーン・故障注入）, `main.gd::request_auto_catch` | `docs/auto_catch.md`。シーケンスはバックエンドがモーションロックを持って実行し、ゲームは表示と手動ロックだけ。異常は必ず FAULT + ABORT。`auto_catch.real` は実機で測って `confirmed` を立てるまで null のまま（推測で埋めない） |
| Z 軸・座標変換 | `robot/robot_state.gd`, `config/game_config.json`, `real_robot.py::move_z` | [references/architecture.md](references/architecture.md) §3, [robot-protocol.md](references/robot-protocol.md) §3 |
| ハンドジェスチャー | `backend/.../vision_service/hand_control.py`, `mediapipe_hands.py`（Tasks API）, `input/gesture_control.gd`（安全の枠）, `input/gesture_scheme.gd` / `input/pinch_joystick_scheme.gd` / `input/pose_direction_scheme.gd`（方式）, `input/hand_joystick.gd`, `input/control_arbiter.gd`, `ui/gesture_hud.gd`, `main.gd::_handle_input` | README「ハンドジェスチャー・ジョイスティック」。JOG を送るのは `_send_jog` だけ（調停の後）。強制停止はラッチ（指を離して新しくつまむまで再開しない）。鮮度は受信側の単調時計と sequence で判定。`gesture.allow_real_robot` は実機で確かめるまで false。認識の不具合は推測で直さず、まず `tools/gesture_probe.py`（#256、`docs/gesture_probe.md`）で記録して「見失い」か「形の誤判定」かを切り分け、replay で設定を比べる |
| 設定画面（#93、タイトルの歯車） | `ui/settings_screen.gd`, `game_config.gd::save_local / load_local`, backend `config.py::local_overrides`, `game_config.json` の `settings_screen` 節 | 保存先は Git に入らない `config/local_settings.json`。ゲームとバックエンドはスキーマにある項目・値だけを重ねる。**校正・安全の値をスキーマに足さない**。テストは `GameConfig.drop_local()` / `CXUFO_NO_LOCAL_SETTINGS=1` で手元のファイルを無視する |
| 校正タブ（#98、設定画面） | `ui/calibration_panel.gd`, `settings_screen.gd::calibrating`, `main.gd::calibrating / homework_for_calibration / CALIBRATION_KEYS` | 校正タブの間だけ `_handle_input` の title の halt を外し、[ ] Q A を通す。ジェスチャー・自動キャッチは止めたまま。ボタンは既存のコマンド（z_set / arm_set / homework_spot_set / camera_map_*）を送るだけで、関門はバックエンド。実機での校正は未検証 |
| 起動時のタイトル（#90） | `ui/title_screen.gd`, `main.gd::show_title / _on_title_chosen` | README「タイトル画面」。演出だけ（RobotState を書かない、コマンドを送らない）。表示中は `_handle_input` が halt、キーはタイトルが受け取る（Space・F1 / Tab は通す）。ヘッドレスでは出さない |
| 周辺機器のテストタブ（#108） | UFO-DeviceHub の Python パッケージ `ufo_devicehub`（`external/UFO-DeviceHub/` の clone を editable な依存にしたもの。#159。コピーを作らない。足りない機能は UFO-DeviceHub 側に足す）, backend `devicehub/service.py`（このゲームだけのコード: 設定・ロボットのポートを開かない・排他・画面の言葉）, `websocket/server.py::_devicehub`, `ui/device_test_panel.gd`, `ui/settings_screen.gd`（`TEST_TAB`） | README「テストタブ」、`docs/devicehub_dependency.md`（clone の準備 `tools/setup_devicehub.sh`、確認済みのコミット `tools/devicehub.pin`、2 リポジトリにまたがる変更の出し方）。`devicehub_*` はロボットに触れず、ほかのコマンドの後ろに並ばず、シーケンス中も受け付ける。ハブの自動検出は Core2 のポートを開かない。テストタブの Space は STOP_ALL も送る。実機未検証 |
| 縦画面（#157、9:16、720×1280） | `game/project.godot`（`viewport_width / height`、`stretch/aspect = keep`）, `game_mode/game_mode_layout.gd`（スコアゲームの座標はここだけ）, `game_mode/pinball_field.gd`（縦長の盤面の定数）, `main.gd::apply_window_mode`（`render.fullscreen`、`--fullscreen`、F11） | `docs/display_setup.md`、`docs/game_mode_spec.md` §4。モニタの回転は OS 側（ゲームの中で回さない）。ドットは設計 2 px（1080×1920 で 3 px）。新しい表示物は `GameModeLayout` の定数から置く（数字を各ファイルに書かない）。画面の形は表示だけ: `RobotState` の変換、ソフトリミット、JOG の向きは変えない。盤面を変えたら `_test_game_mode_physics`（24 個がゴールに届く）と滞在時間・得点の計測を取り直す |
| スコアゲームのハイスコアランキング（#155） | `game_mode/ranking_manager.gd`（TOP10、同点は先の記録が上、`user://game_mode/rankings.tsv`、壊れたファイル・書けないファイルでも止まらない）, `game_mode/game_mode_ranking_hud.gd`・`game_mode/game_mode_show_screen.gd`（結果画面と共通の土台: キャンバス上の絵の層・中央のラベル・シート・光の筋）（NEW RECORD! と HIGH SCORES）, `game_mode/game_mode_ranking_flow.gd`（#222: 登録と画面の切り替え `tick` / `register_score` / `excluded`、今日のベスト。画面が読む状態 `ranking_view` などは `game_mode_controller.gd` に残る） | `docs/game_mode_spec.md` §3.3。名前は聞かない・保存しない・表示しない。登録はリザルト演出が終わった tick に自動で 1 回（ラウンドの ID で二重登録を防ぐ）。STOPPED・練習・デモ・短いラウンド・0 点・圏外は登録しない。phase は `RESULT` のまま（`ranking_view` で画面を表す）。テストは `ctl.ranking.path` を差し替える（`_gm_game()` は空 = ファイルに触らない） |
| スコアゲームの終了のリザルト演出（#153） | `game_mode/result_bonus.gd`（終了ボーナスの計算。`ScoreManager.score` は変えない）, `game_mode/result_show.gd`（1 本の時刻表。合図 cue を出すだけ）, `game_mode/game_mode_result_screen.gd`（画面）, `game_mode_controller.gd::_result / _on_result_cue` | `docs/game_mode_spec.md` §3.2。内訳は `RESULT` に入るとき一度だけ確定し、表示の数字（`ResultShow.shown`）とは別。音・シェイク・光は同じ cue の中で始める（個別の Tween・タイマーを足さない）。音の終わりを待たない。演出のために機器へ命令を送らない。値は `game_mode.result_bonus` / `result_show` |
| スコアゲームの開始前の練習（#149） | `tutorial/gesture_tutorial_steps.gd`（ステップの定義）, `tutorial/gesture_tutorial_controller.gd`（判定。何も送らない）, `tutorial/gesture_tutorial_hud.gd`（画面）, `game_mode/game_mode_controller.gd`（phase `TUTORIAL`、練習カプセル `practice_begin`、スタッフ用 F6 / F7 / F8）, `game_mode/game_mode_tutorial_voice.gd`（#222: 声の取り次ぎ。リンク待ち・依頼・返事） | `docs/game_mode_spec.md` §3.1。練習は手の操作の結果（`GestureControl` の状態・`claw_requested`）を見るだけで、ロボットにも Dial にも自分では送らない。練習カプセルは本番と同じ状態機械を時計なしで動かし、本番は全部を初期化してから始める。声の完了を進行の条件にしない。かんたんモードのステップ（グー。#200 で指 2 本、#266 で指 1 本をなくした: つかんだら自動で運ぶ）は手の形だけを判定し、練習カプセルは本番の操作で入れる |
| スコアゲームのかんたんモード（#169） | `game_mode/easy_mode_control.gd`（手の形の意味。main が持つ）, `game_mode/easy_mode_hud.gd`, `main.gd::_tick_easy / _easy_send / easy_problem`, `game_mode_controller.gd::difficulty / easy_on / easy_delivered`, backend `sequence/easy.py`（`EasySequencer`）, `websocket/server.py`（`easy_*`） | `docs/game_mode_spec.md` §3.4。動かすのはバックエンドのシーケンス 1 本（キャッチ → 行き先待ち → 投入までモーションロックを持つ）。ゲームは 1 合図 1 回だけ頼み、`RobotState.easy_mode` の報告に従う。合図の後はパーを見るまで次を数えない。時間切れ（EXPIRED）は動かさず・開かず・ABORT も送らない。投入の完了は Dial の受取ではない（模擬どうしのときだけ模擬カプセル）。実機の値（Dial 1 の XY、キャッチと投入の高さ。#200: 行き先は Dial 1 だけ）は `calibration.json#easy_dials`（校正タブの 8 で記録・確認、次の起動でも使う、Z を測り直したら高さは無効）。実機のキャッチの設定は測った値だけから組み立て（`real_catch_params`）、機体の事実でない値は `game_mode.easy.real`。`auto_catch.real` は使わない。推測で埋めない。実機未検証 |
| 学習モード（#86） | `study_mode/study_mode_controller.gd`（体験の状態機械）, `study_mode/study_services.gd`（Mock / Jev / AI / ロボットの窓口）, `ui/study_hud.gd`, backend `study_mode/`・`homework/approach.py`（段階撮影）・`sequence/cleanup.py` | `docs/study_mode.md`。体験の状態は RobotState と別。動きはバックエンドのシーケンス 1 本（モーションロック）かゲーム内 Mock だけ、JOG は送らない。`study_mode.height.real` / `cleanup.real` は実機で測って `confirmed` を立てるまで null（推測で埋めない）。config の `demo.source` は simulated / camera だけで、ロボットは start.sh がつないだもの（#92: simulated は実機を動かさない）。#232: `study.ai` が local（既定）なら camera の見守り・場所探しは `/v1/sheet`（`homework/sheet_watch.py`）、解説は学習支援 AI で、Jev・Claude・Codex を呼ばない。俯瞰カメラの画像はプリントタブの向きと範囲で整え（`study/sheet_frame.gd`）、場所はゲームが元の画像の座標に戻す |
| スコアゲームのカプセルの種類（#266） | `game_mode/capsule_kinds.gd`（種類の値・色の判定 `classify`・票 `Reader`・絵 `draw`）, `game_mode_controller.gd::decide_kind / _read_colours / _kind_particles`, `pinball_field.gd::spawn_capsule`（種類の物理）, `game_mode_particles.gd::kind_trail / kind_hit`, `game_mode_vfx.gd::_draw_collect`（名前の帯）, `tools/build_capsule_sprites.py`（ドット絵。`game/assets/capsules/`） | `docs/game_mode_spec.md` §3.6。色はアームカメラ（focus）のフレームから読み、ポータルに入った瞬間に決める。演出と得点だけで、クレーンにも Dial にも送らない。判定できなければ `normal`。模擬 Dial でカメラがないときだけ `mock_kind`（テストの `_gm_game()` は `normal`）。しきい値は実機未検証 |
| スコアゲーム（#138、タイトルの 3） | `game_mode/game_mode_controller.gd`（時計・Dial の状態機械・例外。#200: ポータルは左の Dial 1 だけで、`SIDES` は `["left"]`。Dial 2 には何も送らない）, `game_mode/score_manager.gd`, `game_mode/pinball_field.gd`（盤面。カプセルだけ Godot の RigidBody2D）, `game_mode/pinball_field_art.gd`・`game_mode_backdrop.gd`（絵。640×360 のキャンバス `pixel_view` に描き 2 倍で映す = UFO と同じドット。物理の状態を読むだけ）, `game_mode/game_mode_vfx.gd`, `game_mode/mock_dial_hub.gd` / `backend_dial_hub.gd`（機器の窓口）, backend `devicehub/service.py::mock_ball` | `docs/game_mode_spec.md`（仕様の正本）。体験の状態は RobotState と別で、クレーンに何も送らない（画面の UFO は絵で、アームの位置を読まない）。機器へは `GameModeDevices` 経由だけ。`RELEASE_BALL` はカプセル 1 個に 1 回で、失敗・通信断のあとに自動で送り直さない（FAULT）。`RELEASE_DONE` は排出の証明ではない。光（イルミ・Dial の LED）は失敗しても進む。Dial の LED は UFO-DeviceHub の `docs/game-mode-interface.md` の名前付きアニメーション（`LED_ANIMATIONS`）。数値は調整値。実機未検証 |
| 学習支援 AI（#104） | backend `study/tutor_adapter.py`（provider `tutor`）, `study_mode/navigation.py`（ずれ → mm、範囲の確認、XY → u, v）, `study_mode/explain.py::navigate_of`, `websocket/server.py::_homework_navigate`, `study_services.gd::navigate_help`, `study_mode_controller.gd`（`MAX_NAV`）, `tools/check_tutor_api.py`, `tools/calibrate_focus.py` | `docs/study_mode.md` §8。解説だけ（`study.explain_provider`）。`homework_navigate` は動かさず u, v を返すだけで、動かすのは既存の段階撮影。60 mm・2 回・アームが戻ってから・Space で取り消し。トークン・証明書は `config/secrets/`（Git に入れない）、先端カメラの校正は `calibration.json` の `focus_camera`。実機未検証 |
| USB カメラ・スコープ | `camera/camera_hub.gd`, `camera/scope_trigger.gd`, `ui/scope_view.gd`, `shaders/camera_feed.gdshader`, `main.gd::_update_scope` | README「USB カメラとスコープ」。mac の feed は YCbCr 2 面で、テクスチャの実体が途中で差し替わる（変換マテリアルに毎フレーム設定し直す）。映像は表示専用 |
| スタッフ操作（#260、F6〜F10） | `game/scripts/game/staff_control.gd`（`StaffControl`: next / skip / menu / recover / switch / stop。画面ごとの意味は `describe`、実行は `run`）, `main.gd::_unhandled_input`（画面のキーより先に通す。Shift は開発者用） | `docs/staff_operations.md`。新しいスタッフ向けの操作は画面ごとのキーを足さず、この 6 つの意味に入れる。外部デバイスも `run()` を呼ぶだけにする。アームが動くのは recover だけ（既存の clear_alarm → calibration_prepare）。スタッフ用リモコン M5StopWatch（UFO-DeviceHub 0x30）は `input/staff_remote.gd`（`StaffRemote`）: `devicehub_event` の STAFF_ACTION → `run()`、REMOTE_INPUT → `hand_control` として `GestureControl` へ（カメラの手と同じゲート・ラッチ。来ている間はカメラの手を使わない）。`main.gd::_on_remote_message / feed_remote_hand` |
| スコアゲームのクレーン異常での自動停止（#292） | `game_mode/robot_fault_watch.gd`（`RobotFaultWatch`: 変化だけを異常とみなす・`problems`）, `game/robot_fault_guard.gd`（`RobotFaultGuard`: 停止・確認・スタッフの操作）, `ui/staff_recovery_panel.gd`, `game_mode_controller.gd::robot_halt / robot_fault / clear_robot_fault`, `main.gd::halt_motion_requests / prepare_arm`, `staff_control.gd::_recover` | `docs/game_mode_spec.md` §9。ラッチはバックエンドの `get_state` の返事で確かめてからだけ外す（ACK だけで復旧扱いにしない）。アラームの上に命令を足さない。`soft_stop` は 1 回だけ。まとめて準備は 2 回押し。模擬とデモでは見ない。実機未検証 |
| テスト | `game/tests/run_tests.gd`（実行順）と `game/tests/test_*.gd`（分野ごと）, `backend/tests/conftest.py` | [references/testing.md](references/testing.md), `docs/test_report.md` |

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
1. 3 つの層を混同しない: **ゲームの Z 単位**（0..100、`z_up_is_positive`）、**サーボの回転方向**（`z_sign`）、**基準点**（`z_set top` = アーム最上位、`z_set bottom` = 最下位。ファームウェアに Z ホーミングなし。上下 2 点で `z_counts_per_unit`・`z_sign` を実測し `config/calibration.json` の `z` に保存、設定値より優先）。
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
| 実機モードで ERROR から戻らない（驚き顔のまま、望遠鏡が出ない） | `GameState` は実機が正常な状態を報告したときか `error_cleared` で ERROR を抜ける。実機の状態が変わらないと残る | デバッグパネルの game= を見る。[robot-protocol.md](references/robot-protocol.md) §5 |
| ▲ / ▼ を押しても巻き上げが動かない・途中で止まる（エラーなし） | 巻き上げサーボだけ電源が切れて 1 回転モードに戻った（`SERVO_STATUS` が `tracking=YES limits=0/4095`）。ファームウェアの `beginJog` はこれを見ない | `robot_state.z_servo_reset`。新ファームウェア（CoreXY_UFO #11、`tracking=LOST`）なら `z_servo_jog_recovers` が立ち、▲ / ▼ を押せば `JOG servo ... tracking=RESET` で戻る。旧ファームウェアはデバッグパネル「巻き上げサーボを復帰」（`z_servo_recover`）。どちらも点を記録し直す。`docs/HANDOFF_FIRMWARE_Z_SERVO.md` |
| W / S（や爪のキー）が無反応、ログに `JOG servo id=N disabled reason=unknown_turn_count ... (power-cycle servo)` | Core2 だけが再起動（USB の挿し直しなど）して、サーボは電源が入ったまま多回転・トルク OFF。重みでドラムが最後の goal から 5 カウント超ずれると、ファームウェアが回転数を決められず拒否する（CoreXY_UFO `StsServoBus::enableTracking`） | `robot_state.z_servo_power_cycle` / `arm_servo_power_cycle`（#163）。そのサーボの電源を入れ直す（`SERVO_STATUS` が `limits=0/4095` に戻れば解除）。Z の点を記録し直す |
| `move_z` が NACK になる | Z の点（`z_set top` / `bottom`）を記録していない。ファームウェアの再起動・再接続でも消える（意図的） | ログの `Z reference not set` |
| 起動やテストで `Parse Error: Identifier "…" not declared in the current scope`、ヘッドレスのテストが終わらない | `class_name` を持つスクリプトが増えたコミットを取り込んだ後で、Git に入らないキャッシュ `game/.godot/global_script_class_cache.cfg` が古い（Godot は実行時に作り直さない） | `godot --headless --path game --import`。`./start.sh` と `tools/verify.sh` は起動前に `tools/godot_refresh.sh` で作り直す（#228）。`godot` を直接起動するときは手で |
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
# Godot 物理・マッピング・アセット・表情（基準 621 件、終了コードで合否）
godot --headless --path game res://tests/test_runner.tscn
#   brew の godot が無ければ /Applications/Godot.app/Contents/MacOS/Godot（検証済み 4.7.2）
#   クリーンなチェックアウトや、class_name を持つスクリプトが増えた pull / ブランチ切り替えの後は先に:
#   godot --headless --path game --import（./start.sh と tools/verify.sh は tools/godot_refresh.sh で自動。#228）

# Python バックエンド（基準 609 件）
cd backend && unset VIRTUAL_ENV && uv run pytest
```

- 件数が基準より減っていないことと、終了コード 0 を確認する。機能を追加したらテストも追加する（どこに何を足すかは [testing.md](references/testing.md)）。
- 見た目の変更は `--scenario <name> --capture <dir>` でフレームを保存して確認する。
- 動きの不具合（チャタリング、ガタつき、表情のちらつき）は**推測で直さず**、まず実際にウィンドウで動かして `--log-motion <csv> --quit-after <秒>` でログを取る。ヘッドレスでは描画フレームが物理と同期してしまい、描画側の不具合が出ない。WebSocket 経路は `./start.sh --mock --no-gesture` 相当でバックエンドを起動して取る。
- WebSocket 経路の変更は `./start.sh --mock --no-gesture` で end-to-end を確認する（引数なしの `./start.sh` は**実機** + ジェスチャーなので、確認に使わない）。`start.sh` は WebSocket のポート（`network.websocket_url`、`--ws-port`）が使用中なら起動前に止まる（起動したままの実機用バックエンドにつながるのを防ぐため）。ゲームを起動せずに起動確認だけするなら `START_SH_NO_GAME=1 ./start.sh --mock --no-gesture -- --ws-port 8799`（何も起動せずコマンドだけ見るなら `START_SH_DRY_RUN=1`）。
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
| ピクセル VFX（pixelfx） | `pixelfx-vfx`（このリポジトリ専用） | カタログ → `tools/build_vfx.py` → `VFXManager.spawn_fx`。場面は `vfx_director.gd` |
| 音 | `audio-design`, `godot-audio` | 動きの効果音は `scripts/ui/sfx.gd`（移動・上昇・下降、`main.gd::motion_intensities` の強さで鳴らす）。音源は効果音ラボで、ゲームの一部としてリポジトリに入れている。単体での再配布は規約で禁止（`game/assets/audio/SOURCES.md`）。イベント音を足すなら `GameState` のイベントか mood に結びつける。スコアゲームの音は `game_mode/game_mode_sounds.gd`（Kenney の CC0 のファイル + 合成音のフォールバック、`assets/audio/manifest.json`）とバス `ui/audio_buses.gd`。出典は `docs/audio_sources.md`。音源を足すときは配布元でライセンスを確かめ、マニフェストと文書に記録する（確認できないものは入れない） |
| カメラ | `camera-systems` | 基本は不要。固定カメラの投影（`origin_px`）を壊す追従カメラを入れない |
| どれか分からない | `router` | このスキルを読んだ後に使う |
