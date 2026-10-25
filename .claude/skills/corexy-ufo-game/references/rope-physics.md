# ロープ物理と 2.5D 投影

実装: `game/scripts/physics/rope_simulator.gd`（純粋計算、`RefCounted`）、`projection.gd`、`rope_view.gd`。
入力: `RobotState.playback_pose(dt)`（`robot_state.gd`）。
コードの doc コメントが正確なので、変更前に必ず全文を読むこと。

## 1. 1 ステップでやっていること（`RopeSimulator.step`）

1. **ロープ長**: `target_rope_length` を `[min,max]` にクランプし、`rope_length_rate`（cm/s）で近づける。長さが変わったら全質点を**アンカー中心に拡大縮小**する（巻き取り。形を保って折り畳まない）。
2. **アンカーの運動学**: 速度と加速度を差分で求める（`anchor_velocity()` / `anchor_acceleration()`。演出の手がかりにも使う）。
3. **サブステップ**（`substeps`、既定 16）。各サブステップで:
   1. アンカーを前 tick の位置から今の位置へ線形に進める（tick ごとに一度だけ跳ばない）。
   2. **Verlet 積分**: 減衰 `exp(-damping*h)`、UFO 点は `damping + ufo_drag`。移動量を `max_step / substeps` で制限。`swing_gain != 1` のときは `-anchor_accel*(swing_gain-1)` を擬似力として加える。
   3. **アンカー固定**（kinematic、inv_mass 0）。
   4. **距離拘束（PBD、直接解法）**: 全セグメントの拘束を三重対角の連立方程式 `(J W Jᵀ) λ = -C` として Thomas 法で一度に解く（`_solve_chain`、O(n)）。Gauss-Seidel と違い質量比に関係なく 1 回で収束する。
   5. **長距離拘束（LRA）**: 各点のアンカーからの距離を弧長 `i*seg` 以下に射影する（不等式。たるみは許す）。**UFO がロープ長を超えないことはこれが保証する**。
4. UFO の速度を記録し、`points` に結果を写し、`last_step_usec` に計測時間を残す。

内部は `PackedVector3Array`（`_pos`, `_prev`, `_w`）で計算し、`points` は読み取り用の写し。外から `points` を書き換えても反映されない。

**以前の実装で起きていた不具合（2026-10-24 に作り直し）**: 1 tick に Gauss-Seidel 8 回 + 先頭からの厳密パス（follow-the-leader）では、質量比 25:1 で拘束が収束せず、厳密パスの位置補正が速度として残ってエネルギーを注入していた。結果、ロープがうねり（隣接セグメントの折れ最大 34°）、UFO が上下に跳ね（最大 96 cm/s）、振り子の周期が物理の約半分（0.64 s、期待 1.27 s）だった。厳密パスや Gauss-Seidel の反復回数で直そうとしないこと。

質量: ロープの質点 = 1、UFO = `ufo_mass`（既定 25）。`set_ufo_mass()` を使う（`ufo_mass` を直接書くと inv_mass が更新されない）。
`segment_count` を変えると `_rebuild()` が走り、真下に垂れた状態に戻る。

## 2. パラメータ（`config/game_config.json` の `physics` / `world` / `projection`）

| 値 | 効果 | 調整の目安 |
|---|---|---|
| `damping` | 全体の減衰 | 揺れが長すぎる/短すぎる |
| `ufo_drag` | UFO だけの空気抵抗 | 先端の振り子だけ落ち着かせたい |
| `ufo_mass` | ロープに対する UFO の重さ | ロープのたわみ方 |
| `swing_gain` | 加減速の慣性の誇張（1 = 物理どおり） | 急停止の「おっとっと」を強める。**演出の誇張はここで行う** |
| `substeps`, `segment_count` | 精度と滑らかさ（16 × 16 で約 0.2 ms） | 性能テストとセットで変える |
| `rope_length_rate` | ロープ長の追従速度 | Z の巻き取り/送り出しの見た目 |
| `world.rope_min_cm` / `rope_max_cm` | Z の範囲 → ロープ長（`main.gd` が sim の min/max を上書き） | UFO の上下の可動幅 |
| `world.fit_travel_x_to_screen` | true: 実機 X の全範囲がプレイ領域（デバッグパネルを除く）の端から端に収まるよう、ワールドの X 可動幅を自動で決める（UFO の絵、`projection.edge_margin_px`、実機の最高速度で止まったときの揺れ v·√(L/g) の分を残す） | 画面の端まで行かない／はみ出す。投影で横だけ伸ばすとロープがゆがむので、幅はワールド側で決める |
| `world.travel_x_cm` / `travel_z_cm` | 実機 XY の可動域 → ワールドの幅（X は自動調整が off のときだけ使う） | 画面上の移動量 |
| `projection.*` | 俯角、倍率、遠近、奥行きの強さ | 前後方向の見え方 |

決まった値はデバッグパネルで探し、JSON に書き戻す。コード内の既定値（`rope_simulator.gd` と `game_config.gd::DEFAULTS`）を変えるなら両方を揃える。

## 3. 投影（`Projection25D.project`）

- XZ に `xy_display_scale`、Z にさらに `depth_scale` を掛けてから、X 軸まわりに `pitch_deg` だけ回転し、`1/(1 - vd*perspective)` で遠近を付ける（分母は 0.2 以上）。
- 戻り値の `scale` を UFO とエフェクトのスケールに、`depth` を描画順に使う。
- `origin_px` は `main.gd::_update_origin` が毎フレーム決める（デバッグパネルの幅と、最も奥の位置が画面に入る持ち上げ量）。
- **ロープの全質点と UFO は必ずこの関数を通す。** 接続点が一致することはテストで固定されている。

## 4. 変更してよいこと / いけないこと

**してよい**: パラメータの調整、`swing_gain` などの設定による誇張、新しい観測値（張力、たるみ量など）を読み取る関数の追加、描画側の工夫（太さ、影、テクスチャ）、性能の改善（テストを通したうえで）。

**いけない**:
- `RigidBody3D` / `Joint3D` / `PinJoint2D` などのエンジン物理への置き換え。
- UFO の位置・速度を直接書く（`translate_all` は teleport 専用）。
- テストを通すために LRA を外す、閾値を緩める。
- 物理の値から実機へのコマンドを作る。
- 可変の dt で `step()` を呼ぶ（`_physics_process` の外から呼ばない）。

## 5. 揺れの改善の進め方

1. `--scenario sudden_stop`、`xy_diagonal`、`z_down_up`、`xyz_together` を再生し、`--capture <dir>` でフレームを残す。
2. 原因を切り分ける:
   - **入力**: `playback_pose` の遅延とサンプル間隔、実機の推定位置（smoothstep、`measured:false`）、ポーリングの粗さ（`MockRobot.report_hz` を下げて再現できる）、25 cm 超の teleport。
   - **物理**: 減衰、質量比、`swing_gain`、反復回数。
   - **見た目**: 投影（奥行きの強さ）、UFO の傾き（`ufo_character.gd` の `tilt_follow`、`tilt_from_velocity`、`max_tilt_deg`）。
3. 1 つずつ変え、物理テストと性能を確認し、値を JSON に書き戻す。
4. 実機の動きに合わせる調整（停止のタイミング、加減速）は実機で見ないと完了にできない。

## 6. 物理の性質として守るもの（テストで固定）

静止で真下に垂れる、自発的に振動しない、伸び < 1%（静止）/ < 5%（高速移動）、UFO はロープ長を超えない、NaN にならない、加速で遅れる、急停止で振り子 → 減衰（後半の振幅 < 前半の 60%）、斜め移動で奥行き方向の揺れ、巻き取りで目標長に到達して UFO が上がる、急な伸長で安定、最大長のクランプ、16 セグメント × 8 反復で 1 ステップ < 2 ms。詳細は [testing.md](testing.md)。

## 7. 入力の平滑化（`RobotState.playback_pose`）

ロープはアンカー位置を 2 回微分して加速度として受け取るので、入力のタイミングの小さなずれが大きな加速度になる。以前は物理 tick の中で壁時計（ms）から 2 サンプル間を補間・最大 120 ms 外挿していたため、Godot が tick をまとめて実行すると tick ごとの移動量が 0.15/0.96 cm と交互にばらつき、アンカー加速度が最大約 10 万 cm/s²（≈100 G）になっていた。停止のたびに外挿の行き過ぎから引き戻され、ロープが鞭のように振れていた。

現在の約束:
- サンプルの時刻は**送り手の時計**（バックエンドの `timestamp`、MockRobot は物理 dt で進む `_clock_ms`）。受信時刻と「今」は `RobotState._local_ms`（物理 dt で進む時計）で測る。壁時計は使わない（tick がまとめて実行されると壊れる）。
- 送り手と自分の時計の差はサンプルごとの差のゆっくりした平均（`OFFSET_SMOOTHING`）。最大値の保持は 1 tick 分の量子化と外れ値を拾って先走るので使わない。
- 再生時計は物理 tick ごとにちょうど `dt` 進み、「送り手の今 − 遅延」へ ±25% 以内でゆっくり寄せる。遅延 = max(平均間隔 × 2.2, 最近のピーク間隔 × 1.3)（20〜200 ms）。ピーク間隔は送り手側の間隔と受信側の間隔の大きい方で、ゆっくり減衰する。30 Hz のバックエンドでは 75〜200 ms、Mock では約 37 ms。
- サンプル間は**単調 3 次エルミート補間**（軸ごと）。速度が連続になり、行き過ぎない。最新区間では直前 2 区間からの外挿で終点の接線を決める。
- 外挿はしない。送り手が止まったら、最新サンプルの手前（遅延の 15%）から滑らかに減速して止まる。500 ms 以上の間隔（切断・再接続・ソース切替）でバッファを捨てて新しいサンプルへ跳ぶ（大きければ `main.gd` の teleport 処理が受ける）。間隔が平均の 30% 未満のサンプル（送信の詰まりの直後）は最新サンプルの更新として扱う。
- `playback_pose(dt)` は `main.gd::_physics_process` から tick ごとに 1 回だけ呼ぶ。

## 8. 描画と物理の分離（`main.gd`）

描画は物理（60 Hz）より速く回る（macOS で約 110 FPS）。
- 描画は直前と最新の物理 tick の点列を `Engine.get_physics_interpolation_fraction()` で補間して描く（`_prev_points` / `_cur_points`）。ロープと UFO は同じ補間済みの点列から投影する。
- キャラクターへの手がかり（画面速度、アンカーの画面加速度、奥行き速度）は `_store_tick` で物理 tick ごとに固定 dt で計算する。`_process` で差分を取ると、新しい tick がないフレームで 0、次で 2 倍になり、表情（`move_right` ↔ `normal`）・傾き・`panic` がチャタリングする（修正前は 9 秒で 398 回切り替わっていた）。
