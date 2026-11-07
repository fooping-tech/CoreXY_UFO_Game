# 1 ボタン自動キャッチ（Issue #54）

キャッチボタン（ゲームの **C** キー、またはデバッグパネル「実機」タブの「自動キャッチ開始」）を 1 回押すと、
爪を開く → 下降 → 閉じる → 上昇 → 救出ボックスへ移動 → 下降 → 開く → 上昇 → 爪を待機位置へ、を自動で行う。

**状態: ドライラン（仮想クレーン）とテストで確認済み。実機では未検証で、実機用の校正値が未設定のため実機では開始が拒否される。**

## 1. どこで動いているか

| 層 | 実体 | この機能での役割 |
|---|---|---|
| マイコン | M5Stack Core2（ESP32、FreeRTOS）。兄弟リポジトリ `../CoreXY_UFO` | 変更なし。XY は TMC2209 ×2 のステッピング（CoreXY、80 step/mm、加速度 1000 mm/s² 固定）、Z ドラム = STS3020 サーボ ID1、爪 = STS3020 サーボ ID2（2400 counts/s 固定）。リミットスイッチは X=GPIO36 / Y=GPIO35（ホーム側のみ、active LOW、30 ms デバウンス）。タスク: Command / Motion / StepperFeed / Safety / TMC / UI / Log / Joystick |
| 通信 | USB シリアル 115200、行プロトコル（`docs/firmware_protocol.md`） | 既存のコマンドだけを使う（`XY`、`SERVO_TURN`、`SERVO_STATUS`、`POS`、`ABORT`）。新しいファームウェアコマンドはない |
| ホスト | Python バックエンド（`backend/`） | **シーケンスはここで動く**: `sequence/auto_catch.py` の状態機械 |
| ゲーム | Godot（`game/`） | ボタン、手動操作のロック、状態とエラーの表示だけ。実機へは送らず、`auto_catch` コマンドを 1 回送るだけ |

ファームウェアにないもの（前提にしていない）: Z のホーミングとリミット、物理的な非常停止入力、ホストウォッチドッグ、移動中の実測 XY。

## 2. 状態遷移

```
IDLE ─(auto_catch・条件OK)→ OPEN_CLAW → LOWER_TO_CATCH → CLOSE_CLAW → RAISE_WITH_ITEM → MOVE_TO_BOX
     → LOWER_TO_RELEASE → RELEASE → RAISE_EMPTY → CLAW_STANDBY → IDLE（完了）
どの状態からでも ─(異常・stop・soft_stop・切断)→ FAULT（ABORT 送信済み）
```

各状態は「ロボットへの動作を 1 つ非同期タスクとして開始 → 20 ms ごとに監視 → 終了条件を満たしたら次へ」。固定時間の待ちはない。

| 状態 | 開始する動作 | 終了条件 | タイムアウト（キー） |
|---|---|---|---|
| OPEN_CLAW | `arm_goto(open)` | サーボ結果 PASS + `claw_settle_s` 経過 | `open_claw` |
| LOWER_TO_CATCH | `move_z(catch_z)` | 動作が正常終了 かつ Z が `z_tolerance` 内 かつ Z が動いていない | `lower_to_catch` |
| CLOSE_CLAW | `arm_goto(closed)` | PASS + settle | `close_claw` |
| RAISE_WITH_ITEM | `move_z(safe_z)` | 同上（Z） | `raise_with_item` |
| MOVE_TO_BOX | `move_xy(box, feed)` | 正常終了（実機は `ACK_XY`） かつ XY が `xy_tolerance_mm` 内 かつ IDLE | `move_to_box` |
| LOWER_TO_RELEASE | `move_z(release_z)` | 同上（Z） | `lower_to_release` |
| RELEASE | `arm_goto(open)` | PASS + settle | `release` |
| RAISE_EMPTY | `move_z(safe_z)` | 同上（Z） | `raise_empty` |
| CLAW_STANDBY | `arm_goto(claw_standby)`（null なら省略） | PASS + settle | `claw_standby` |

キャッチ位置の XY は「ボタンを押したときの位置」（待機中に手動で合わせた位置）。

## 3. 安全機構と異常時の挙動

**開始できる条件**（1 つでも欠けると NACK、理由を全部返す）: 校正値がすべて設定済みで範囲内（実機は `confirmed` も全部 true）、接続中、モーター有効、アラームなし、**ホーミング済み**、Z 基準（`z_zero`）設定済み、爪の開閉位置が記録済みで弧が `claw_span_min_deg..max_deg` 内、ロボットが IDLE、ほかのモーション・ジョグがない、XY がソフトリミット内、Z が `safe_z` 以上、ホーム外でリミットスイッチが入っていない、前回の押下から `button_debounce_ms` 以上経過。

**排他制御**: シーケンスは実行中ずっとサーバーのモーションロックを持つ。`move_xy` `move_z` `home` `grab` `arm_*` `z_zero` `clear_alarm`、動くジョグ、2 回目の `auto_catch` は `busy` で拒否。受け付けるのは `stop` `soft_stop` `get_state` `auto_catch_status` ゼロのジョグ（キーを離した）・`enable_motors false` だけ。ゲーム側も実行中はキー・ジェスチャー・爪キーを送らない。

**監視（毎ポーリング）**: stop 要求、状態のタイムアウト、全体のタイムアウト、接続、モーター有効、アラーム / ESTOP、ホーミングが外れていないか、位置が数値か、XY がソフトリミット内か、Z が範囲内で `z_floor` より下でないか、ホーム外でリミットスイッチが入っていないか、動作の失敗（サーボ `result=TIMEOUT` など）。

**異常時**: シーケンスを中断して FAULT に入り、`ABORT` を送る（XY も Z・爪のサーボも止まる、アラーム、HOMED 解除）。再開には「アラーム解除」→「原点復帰」が必要なので、自動で再始動しない。

| 入力 | 動き |
|---|---|
| `stop`（デバッグパネル E-STOP） | 先に中断フラグを立て（次の動作を出さない）、すぐ `ABORT`。最優先で、ロックや busy で拒否しない |
| `soft_stop`（Space） | 自動キャッチ中は `ABORT` に格上げ（`STOP` はサーボを止めないため） |
| `enable_motors false` | 中断して `ABORT` |
| 操作していたクライアントの切断 | 中断して `ABORT`（止められる人がいなくなるため） |
| バックエンド終了 | 中断して `ABORT` |

**確認方法**: ゲームのデバッグパネル「実機」タブ「4. 自動キャッチ」と上部の状態行に、現在の状態（何番目か、経過時間）、完了、または異常の原因が出る。ログタブにはバックエンドのログ（`auto_catch: A -> B (動作)`、`FAULT: 原因`）。WebSocket では `robot_state.data.auto_catch` と `{"type": "auto_catch"}`（遷移ごと）、`auto_catch_status` コマンド。

**限界（ソフトウェアの停止は電源遮断ではない）**: USB が抜けるとホストは `ABORT` を送れず、ファームウェアは実行中の 1 コマンドを最後まで続ける（ホストウォッチドッグがない）。実機の移動中はファームウェアが `POS` に答えないので、移動中のリミット・アラームは完了行とタイムアウトでしか分からない（ファームウェア自身はホーム外のリミットでアラームを出す）。電気的に止めるには外部の非常停止スイッチが必要。

## 4. 校正パラメータ（`config/game_config.json` の `auto_catch`）

同じキーで 2 つのプロファイル: `real`（実機。未確認は null）と `dry_run`（`--mock` と `--auto-catch-dry-run` だけが使う仮の値）。
XY の可動範囲と Z の上下端は既存の `robot.x_min_mm..` / `z_min_mm..z_max_mm`（Z 単位、`z_max` = `z_zero` を押したアーム最上位）をそのまま使う。

| キー | 意味 | real の現状 |
|---|---|---|
| `safe_z` | 移動に使う安全高さ | **未設定** |
| `catch_z` / `release_z` | 爪を閉じる / 開く高さ | **未設定** |
| `z_floor` | シーケンスが出してよい最も低い Z（机より上） | **未設定** |
| `max_drop_units` | `safe_z` からの下降量の上限 | **未設定** |
| `max_drum_turns` | 1 回の Z 移動のドラム回転数の上限（巻取り量） | **未設定** |
| `box_x_mm` / `box_y_mm` | 救出ボックスの XY | **未設定** |
| `xy_feed_mm_min` / `xy_feed_max_mm_min` | XY 速度とその上限 | **未設定** |
| `xy_accel_mm_s2` / `z_speed_units_s` / `z_accel_units_s2` | 加速度・Z 速度（ファームウェア固定。ドライランのモデル用） | 未設定（実機には送らない） |
| `claw_open` / `claw_close` / `claw_standby` | 各段で使う爪の位置（`open` / `closed`、待機は null で省略）。角度そのものは実機で記録した `config/arm_calibration.json` | standby **未設定** |
| `claw_span_min_deg` / `claw_span_max_deg` | 記録した閉じ→開きの弧の許容範囲（サーボ角度の上下限） | **未設定** |
| `claw_settle_s` | 爪の動作後の待ち（サーボ動作待ち時間） | **未設定** |
| `timeouts_s.*` / `total_timeout_s` | 状態ごと / 全体のタイムアウト | **未設定** |
| `xy_tolerance_mm` / `z_tolerance` | 到達判定の許容差 | 1.0 / 1.0（ソフトウェアの判定値） |
| `limit_home_zone_mm` | ホーム側でリミットが入っていても異常としない範囲 | **未設定** |
| `button_debounce_ms` | ボタンのチャタリング除去 | 500 |
| `polarity.*` | 入力の極性。リミットはファームウェアが active LOW で読みホストは ACTIVE/OPEN を受け取る（事実）。非常停止の入力線はない。ボタンはキーボード | `limit_active_high: false` のみ |
| `confirmed.*` | `z_direction` `z_scale` `z_positions` `box_xy` `claw_positions` `timeouts` `speeds` を実機で確かめたら true にする | 全部 false |

この機能より前からある未確認値（`backend.z_sign`、`backend.z_counts_per_unit`、`backend.arm_open_turns`）もシーケンスの Z に直接効く。`confirmed.z_direction` / `z_scale` はこれらの確認を指す。

## 5. ドライラン

```bash
cd backend && uv run corexy-ufo-backend --auto-catch-dry-run            # 正常系
uv run corexy-ufo-backend --auto-catch-dry-run stall_z                  # 途中で Z が止まる → タイムアウト
uv run corexy-ufo-backend --auto-catch-dry-run estop                    # 仮想の非常停止入力
uv run corexy-ufo-backend --auto-catch-dry-run stall_xy --fault-at MOVE_TO_BOX
#  故障: stall_xy stall_z claw_stall claw_fail z_glitch disconnect estop limit_x limit_y
./start.sh mock   # ゲームから C キーで（バックエンドは仮想クレーン、実機には何も送らない）
```

仮想クレーン `robot/dry_run.py`（`DryRunRobot`）: XY/Z は速度・加速度付きのモデル、爪は `virtual_claw_move_s` で完了する仮想サーボ、リミットと非常停止は極性とデバウンス付きの仮想入力線、故障注入つき。送ったはずのコマンドは `commands` に残るだけで、どこにも出力しない。

## 6. 実機で動かす前に確認すること

推測した値は使っていない。次を実機で確かめて `auto_catch.real` に書き、項目ごとに `confirmed` を true にするまで、実機では開始されない。

1. **配線**: リミットスイッチ X=GPIO36 / Y=GPIO35 が実際にその端子か、`POS` の `LIMIT_X/LIMIT_Y` が押したときだけ ACTIVE になるか。非常停止はソフトウェア（ABORT）しかないので、モーター電源を切る外部スイッチを手の届く所に付けるか。
2. **軸方向**: `docs/HANDOFF.md` §6 の手順で、Z を少し下げたときに実機のアームが**下がる**か（逆なら `backend.z_sign=-1`）→ `confirmed.z_direction`。
3. **原点**: `HOME` 後の位置が (0,0) で、そこがホーム側のリミットか。Z は `z_zero`（アームを手で最上位）でしか基準がない。
4. **巻取り量**: ドラム 1 回転あたりの昇降量を測り `backend.z_counts_per_unit` を決める → `confirmed.z_scale`。机に当たらない最も低い Z を `z_floor`、そこまでの回転数から `max_drum_turns`、`max_drop_units` を決める。ファームウェアの追従範囲 ±28000 count（約 ±6.8 回転、サーボ電源投入時が 0）に収まるか。
5. **高さ**: `safe_z`（移動中に何にも当たらない）、`catch_z`（物を掴める）、`release_z`（ボックスの縁より上）→ `confirmed.z_positions`。
6. **可動範囲**: `robot.x/y_min/max_mm`（ファームウェアは X 0..390 / Y 0..200）が機械的に安全か。
7. **救出ボックス**: 箱の中心の XY を、手動で移動して `POS` で読む → `box_x_mm` / `box_y_mm`、`confirmed.box_xy`。
8. **爪**: 「実機」タブ 3 で閉じ / 開き位置を記録し直し、弧（現在 -128.6°）を測った許容範囲 `claw_span_min/max_deg` に入れる。待機位置（`claw_standby`）を決める。`claw_settle_s` を実測 → `confirmed.claw_positions`。
9. **速度とタイムアウト**: `xy_feed_mm_min`（ファームウェア上限内）で、各動作の実測時間に余裕を足して `timeouts_s` と `total_timeout_s` → `confirmed.speeds` / `timeouts`。
10. 初回は物を置かず、手を非常停止スイッチ（または E-STOP）に置いて、1 状態ずつログを見ながら実行する。
