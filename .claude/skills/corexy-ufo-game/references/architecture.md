# アーキテクチャ（判断に必要な部分だけ）

ディレクトリ構成とデータの流れの図は `docs/HANDOFF.md` §3-4 にある。ここでは**変更するときに壊しやすい約束**をまとめる。

## 1. 1 フレームの処理順（`game/scripts/game/main.gd`）

```
_physics_process(dt)  ← Godot の物理 tick（既定 60 Hz）
  _handle_keys        ← source == "mock" のときだけ MockRobot.target を動かす
  pose   = RobotState.playback_pose(dt)            # mm。サンプル列を「最新 - 1.5 間隔」で補間（外挿しない）
  anchor = RobotState.anchor_for_xy(pose.x, pose.y) # ワールド cm
  sim.target_rope_length = RobotState.rope_length_for_z(pose.z)
  初回:     sim.reset()（真下に垂らす）
  25cm 超:  sim.translate_all()（teleport。慣性を与えない）
  sim.step(dt)

_process(dt)          ← 描画フレーム
  rope_view.update_rope(sim, proj)                  # 全質点を project()
  ufo.position = proj.project(sim.ufo_position()).screen
  ufo.mood = _mood()                                # GameState.state → mood 文字列
  ufo.update_motion(接線角, 画面速度, 奥行き速度, アンカー画面加速度, 投影スケール, dt)
```

- Autoload の読み込み順は `GameConfig` → `RobotState` → `GameState`（`project.godot`）。`RobotState._ready` は `GameConfig` を使う。
- `project.godot` の作業ツリーには `physics_ticks_per_second` がない（既定値の 60 を使う）。ロープの調整値は 60 Hz を前提にしている。tick を変えるなら物理テストと見た目を確認し直す。
- `main.gd` がすべてを配線する唯一の場所。ノードはコードで生成し、`.tscn` は最小限（`main.tscn`, `ufo.tscn`, `debug.tscn`）。

## 2. 状態の持ち主

| 状態 | 持ち主 | 書いてよいもの |
|---|---|---|
| 実機の位置 (mm)、`machine_state`、`connected`、`homed`、`motors_enabled`、`position_is_measured` | `RobotState` | `MockRobot._report`、`UfoWebSocketClient._handle`、切断時の各ソース |
| ゲームの進行（`BOOT DISCONNECTED HOMING READY MOVING LOWERING GRABBING RAISING RESULT ERROR`） | `GameState` | `GameState.post_event()` 経由のみ（robot、vision、UI、キー） |
| UFO の見た目の mood | `main.gd::_mood()` が毎フレーム決める | `UfoCharacter` は受け取るだけ |
| ロープの質点 | `RopeSimulator` | `main.gd` がアンカーと目標長だけを渡す |

`RobotState.machine_state`（実機の動作状態: `IDLE MOVING_XY Z_LOWERING Z_RAISING GRABBING RELEASING ALARM ESTOP HOMING UNKNOWN`）と `GameState.state` は名前が似ているが別物。`GameState._on_machine_state_changed` が前者を後者に写す。この関数のガード（DISCONNECTED/ERROR 中はアラーム以外を無視、RESULT 中は上書きされる）を変えるときは遷移表を書いてから変える。

## 3. 座標系と単位

| 層 | 単位 | 軸 |
|---|---|---|
| 実機 / `RobotState` | mm（XY）、抽象単位 0..100（Z） | X 右、Y 奥、Z = アームの高さ（`z_up_is_positive` が true なら大きいほど高い） |
| ロープのワールド | cm | +X 右、+Y 上（重力 −Y）、+Z 手前 |
| 画面 | px | `Projection25D` が俯角回転 + ピンホールで変換。奥（−Z）ほど上に小さく映る |

変換（`robot_state.gd`）:
- `anchor_for_xy`: 正規化した X → `(nx-0.5)*travel_x_cm`、Y → `-(ny-0.5)*travel_z_cm`（**実機 Y+ はワールド −Z = 奥**）。
- `arm_height_normalized`: 0 = アーム最下、1 = 最上（`z_up_is_positive` を吸収）。
- `rope_length_for_z`: `lerp(rope_min_cm, rope_max_cm, arm_height)`。**アーム最上 → ロープ最長 → UFO 最下**。

Z に関わる値は 3 層あり、混同しやすい:

| 値 | 場所 | 意味 | 状態 |
|---|---|---|---|
| `robot.z_up_is_positive` | config（Godot と Python） | ゲームの Z 単位が大きいほどアームが高いか | 設計上の約束（true） |
| `backend.z_sign` | config（Python） | `SERVO_TURN 1 +t` でアームが上がるなら 1 | **実機で未確認** |
| `backend.z_counts_per_unit` | config（Python） | サーボの count / Z 単位（ドラム径で決まる） | **実機で未確認** |
| Z 基準 | `RealRobot._z_zero_counts` | `z_zero` 時の `abs=` カウント = アーム最上位 | 起動ごとに手で設定 |

実機の Z が逆に動くときに直すのは `z_sign`。`rope_length_for_z` や `z_up_is_positive` を反転させて辻褄を合わせない（MockRobot やテストと矛盾する）。

## 4. 設定の流れ

- `config/game_config.json` は Godot（`game_config.gd`、`DEFAULTS` にマージ）と Python（`config.py::load_config`）が共有する。キーを足すなら**両方の既定値**を足す。
- Godot はリポジトリ直下の `config/` → 実行ファイル横の `config/` → `res://config/` の順で探す。
- デバッグパネルの変更は実行時のみ。決まった値は手で JSON に書き戻す。

## 5. 2 つの MockRobot

| | GDScript `MockRobot`（既定） | Python `MockRobot`（`--mock`） |
|---|---|---|
| 経路 | `RobotState` に直接書く | WebSocket を通る（実機と同じ経路） |
| アーミング / ホーミング | なし（`homed` は常に true） | `enable_motors`、`home` が必要 |
| E-STOP | 速度 0、目標 = 現在位置。**ALARM にならない** | ALARM + `homed=false`（ファームウェアと同じ） |
| 用途 | 物理・演出・シナリオ・キー操作 | プロトコル・安全手順・UI の配線 |

安全手順や通信に関わる演出は、GDScript の Mock だけで確認して終わりにしない。`./start.sh mock` で確認する。
