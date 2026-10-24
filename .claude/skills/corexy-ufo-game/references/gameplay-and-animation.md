# ゲーム体験・UFO のキャラクター演出・アセット

## 1. 体験設計の原則

- このゲームの核は「**操作 → 工夫 → 結果 → リアクション**」の繰り返し。子供が掴もうとして失敗し、操作を工夫して成功する。その過程で UFO が生きているように反応する。
- リアクションは**実際の物理と実機の状態から生まれる**ものを優先する。急停止で揺れて驚く、巻き取りで力を込める、など。物理と食い違う作り物の動き（ロープと関係なく UFO が跳ねるなど）は避ける。
- 誇張してよいが、`swing_gain` などの設定値か、描画側（傾き、スケール、エフェクト）で行う。
- 画面には UFO とロープと天井のアンカー板（`rope_view.gd`）だけを置く。クレーンアームを描かない。
- 別のミニゲームを足すことは目的ではない。機能を足す前に、その機能が上の繰り返しのどこを良くするかを書く。

## 2. 現在の UFO の状態と見た目（コードの事実）

流れ: `GameState.state` → `main.gd::_mood()` → `UfoCharacter.mood` → `_on_mood_changed()`（アニメの開始）と `_tick_face()`（毎フレーム）。

優先順位: `manual_expression`（デバッグで固定）> **panic**（アンカーの画面加速度 > `panic_accel_threshold` 2600 px/s²、mood が IDLE/MOVING_* のときだけ、0.7 秒）> mood。
傾きは mood と関係なく常にロープ末端の接線に追従する（`tilt_follow`、`tilt_from_velocity`、`max_tilt_deg`）。投影スケールで奥のときは小さくなる。

| GameState | mood | 見た目 |
|---|---|---|
| READY など | `IDLE` | `idle` アニメ、2〜4.5 秒ごとにまばたき、横速度 > 120 で `move_left/right` |
| MOVING / HOMING（横） | `MOVING_XY` | 横速度 > 40 で `move_left/right`、それ以外は `normal` |
| MOVING（前後が主） | `MOVING_FORWARD` / `MOVING_BACKWARD` | `move` アニメ |
| LOWERING（**アームが下がる = ロープが短くなる = UFO が上がる**） | `Z_LOWERING` | `strain_up` ポーズ |
| RAISING（**アームが上がる = ロープが伸びる = UFO が下がる**） | `Z_RAISING` | `straining` 表情 |
| GRABBING | `GRABBING` | `pull` アニメ |
| RESULT（成功） | `SUCCESS` | `success` アニメ + `sparkles` |
| RESULT（失敗） | `FAILURE` | `failure` → `recover` アニメ + `motion_lines` |
| ERROR | `ERROR` | `surprised` |
| DISCONNECTED / BOOT | `DISCONNECTED` | `worried` |

**mood 名の Z_LOWERING / Z_RAISING は実機アームの向き**であって、画面の UFO の向きではない。取り違えると逆のリアクションになる。

### 未使用の既存アセット（新しい絵を頼む前に使う）

| 種類 | 未使用 | 合いそうな場面（案） |
|---|---|---|
| 表情 | `happy` `sad` `wink` `sleepy` `excited` | 掴む前の期待、失敗の落胆、長い待機、成功直前 |
| ポーズ | `resist_side` `release_stretch` `exhausted` | 横揺れに耐える、ロープ送り出しのたるみ、連続失敗の後 |
| アニメ | `swing` `release` | 急停止後の振り子、放す（`RELEASING`、今は GameState に対応がない） |

### 目標の状態とのギャップ（実装案を考えるときの出発点）

| 目標 | 現状 |
|---|---|
| 待機: 浮遊・まばたき | 実装済み |
| XY 移動: 傾き | 実装済み（接線 + 速度） |
| 加速: 慣性の姿勢 | 傾きのみ。強い加速で panic |
| 急停止: 驚き・振り子 | panic ポーズ + 物理の振り子。`swing` は未使用 |
| 巻き上げ: 力を込める | `strain_up` |
| 送り出し: たるみへのリアクション | `straining` のみ。たるみ量（`rope_length - anchor_to_ufo_distance()`）は未使用 |
| 掴む: 期待と緊張 | `pull` アニメのみ |
| 成功 / 失敗 | 実装済み（簡易パーティクル） |
| 通信切断: 困惑 | `worried` |
| アラーム: 異常の明示 | ERROR と同じ `surprised`。ALARM・E-STOP・タイムアウトを見分けられない。復帰手順の表示もない |

## 3. 新しい表情・状態を追加する手順

1. 体験の目的を 1 行で書く（どの操作・結果に対するリアクションか）。
2. 既存のフレームで表現できるか確認する（上の表）。
3. **状態の出どころを決める**:
   - 実機の状態から → `RobotState.machine_state` → `GameState._on_machine_state_changed`（GameState の状態を増やすか、既存の状態を使う）。
   - 物理から（揺れの大きさ、たるみ、急停止） → `main.gd` で値を計算し `update_motion()` の引数を増やす。`UfoCharacter` は `RopeSimulator` を直接参照しない。
   - 外部イベントから（vision、プレイヤー） → `GameState.post_event(name, payload)`。
4. `main.gd::_mood()` に mood を足し、`ufo_character.gd` の `mood` の doc コメントの一覧を更新する。
5. `_on_mood_changed`（開始時に 1 回）か `_tick_face`（継続）に見た目を足す。`_want` / `_want_pose` / `_want_anim` を使い、毎フレームの再設定を避ける（`_last_expr_shown` で判定）。
6. panic などの割り込みとの優先順位を決める。
7. デバッグパネルの Character の一覧は `available_expressions()` から自動で作られる。
8. headless テストで状態遷移を確認する（[testing.md](testing.md) §3）。

## 4. 未実装の企画要素（既存機能と混同しない）

- **成功判定の自動化**: `GameState` は `prize_detected` / `prize_dropped` / `result_success` / `result_failure` を受け付けるが、今は G/F キーとデバッグボタンからしか届かない。vision は `objects` `object_appeared` `object_disappeared` `hands` `gesture` を送るが、`GameState` はこれらを状態遷移に使っていない。
- **机の片付け量のスコア化**: 構想のみ。コードはない。
- **Phase 4**: サウンド、パーティクルの強化、UFO の台詞・個性。未着手。
- これらを提案・実装するときは「新規」と明記し、既存の操作・結果・リアクションの流れを壊さない。

## 5. アセットのパイプライン

- 元画像: `assets/source/ufo_expression_master.png`（5×2 の 10 表情）、`ufo_action_master.png`（4×2 の 8 ポーズ）。Codex 製。画風を勝手に置き換えない。
- 生成: `python3 tools/build_ufo_assets.py assets/source/ufo_expression_master.png assets/source/ufo_action_master.png`（Pillow が必要。backend の依存には入っていない）。出力先は `assets/ufo`、`assets/preview`、`assets/rope`、`assets/effects`。
- **ゲームが読むのは `game/assets/`**。生成後に `assets/{ufo,rope,effects}` を `game/assets/` にコピーし、`godot --headless --path game --import` で取り込む。コピーを忘れるのが一番多いミス。作業前に `diff -r assets/ufo game/assets/ufo` で差分を確認する（2026-10-24 時点で、作業ツリーの `assets/` だけが新しくなっている）。
- metadata（`ufo_metadata.json`）の約束: フレーム 64×64、`texture_filter: nearest`、既定の接続点 `rope_attachment_local` = (32,5)（ポーズはフレームごとに上書き可）。`UfoCharacter` が読むシートは `idle` / `expressions` / `actions`（`animations{name:{frames,fps,loop}}`）/ `action_poses`。`all_sprites` は生成されるがゲームは使っていない。
- 接続点がずれると UFO がロープの端から浮く。新しいフレームを足したら、ロープの結び目（`rope_connector.png`、anchor (8,13)）と重なることをキャプチャで確認する。
- 汎用のアセット制作手順は `create-game-assets` スキル。このプロジェクトでは上の画風・サイズ・接続点を優先する。
