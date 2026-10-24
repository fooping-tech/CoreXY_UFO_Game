# テストとデバッグ

## 1. コマンド

```bash
# Godot（リポジトリ直下から）。基準 53 件。終了コード 0 = 全件成功
godot --headless --path game res://tests/test_runner.tscn
# godot が PATH にない場合: /Applications/Godot.app/Contents/MacOS/Godot（検証済み 4.7.2）
# クリーンなチェックアウト（game/.godot/ がない）では先に:
godot --headless --path game --import

# Python。基準 48 件（約 17 秒）
cd backend && unset VIRTUAL_ENV && uv sync && uv run pytest
```

- 他プロジェクトの venv が有効だと uv が警告を出すので `unset VIRTUAL_ENV`（`start.sh` と同じ）。
- 性能テスト（`perf: one 60Hz step well under 2 ms`）は初回起動で 1.9 ms 近くまでばらつくことがある（通常は 200〜450 µs）。失敗したら再実行し、安定して遅い場合だけ調べる。
- zsh では `${PIPESTATUS[0]}` が使えない。終了コードはパイプを通さずに `$?` で確認する。

## 2. 現在のテストの範囲

**Godot `game/tests/run_tests.gd`**（Node シーンの runner。`_ok(cond, name, detail)` で数え、最後に `get_tree().quit(1 if 失敗)`）

| 関数 | 検証内容 |
|---|---|
| `_test_rest_state` | 真下に垂れる、距離 = ロープ長、自発振動なし、伸び < 1% |
| `_test_inextensible_under_motion` | 高速 XZ 掃引で伸び < 5%、ロープ長を超えない、NaN なし |
| `_test_sudden_stop_swing_and_decay` | 加速で遅れる、急停止で振り子、減衰、振幅 < ロープ長 |
| `_test_xy_diagonal_3d` | X と奥行きの両方で遅れる、奥行き方向の揺れ |
| `_test_pendulum_and_taut_rope` | 巡航中ロープがまっすぐ（折れ < 2°）、UFO が上下に跳ねない、急停止後の周期 ≈ 2π√(L/g)（±10%） |
| `_test_playback_smoothing` | tick がまとめて実行されてもアンカーが等間隔で動く、最新サンプルを越えない、外挿しない |
| `_test_playback_30hz_acceleration` | 30 Hz の加速中サンプルで加速度が脈打たない（直線補間だと失敗する） |
| `_test_mock_robot_settles` | MockRobot が目標でぴたりと止まる、行き過ぎない、IDLE に戻る |
| `_test_rope_length_change` | 巻き取りで目標長、UFO が上がる、伸びなし、急伸長で安定、最大長クランプ |
| `_test_z_inverse_mapping` | アーム最上 → ロープ最長、単調、アンカー X+ → 右 / Y+ → 奥 |
| `_test_projection_consistency` | ロープ端と UFO が同じ画面座標、奥ほど小さく上、原点の一致 |
| `_test_performance` | 16 セグメント × 8 反復で 1 ステップ < 2 ms |
| `_test_game_assets_in_sync` | `assets/{ufo,rope,effects}` の png/json が `game/assets/` とバイト単位で一致 |
| `_test_ufo_metadata` | metadata が読める、全シートのテクスチャが存在、`action_effects` と `action_poses` のセル数が一致 |
| `_test_ufo_faces_and_pose_effects` | mood → 表情（ERROR/DISCONNECTED/Z_LOWERING）、ポーズのときだけオーバーレイ表示、位置・スケールが本体と一致、オフにできる |

**Python `backend/tests/`**（`asyncio_mode = auto`、`conftest.py` の `FakeFirmware` がファームウェアの行形式を再現）

| ファイル | 検証内容 |
|---|---|
| `test_protocol.py` | POS（ALARM_REASON に空白）、SERVO_TURN/STATUS の解析、行の分類、コマンド組み立てと検証 |
| `test_serial_service.py` | POS 往復、HOME→XY、未ホーミングの NACK、`CommandQueue full` の再試行、不明コマンド、タイムアウト、直列化、ABORT→ALARM_CLEAR、切断時に待機中のコマンドが失敗 |
| `test_real_robot.py` | 起動時モーター無効、HOME/XY、ホスト側ソフトリミット、NACK の伝搬、Z 基準未設定の拒否、3 回転ずつの分割、stop 後の alarm/homed、アーム開閉 |
| `test_server.py` | hello と状態ストリーム、モーター無効時の NACK、`request_id` の重複を再実行しない、不正パラメータ、stop は常に受け付ける、ソフトリミット |
| `test_vision_base.py` | Detection、ジェスチャ規則、Cloudflare がインターフェースのみ |

## 3. 検証すべき条件と、テストを足す場所

| 条件 | 現状 | 足すなら |
|---|---|---|
| XYZ 移動とロープの対応 | アンカー変換と Z 逆マッピングは検証済み | `RobotState.push_pose` → `anchor_for_xy` / `rope_length_for_z` → `sim.step` を通した統合テスト（Godot） |
| Z 逆マッピング | 済み | `z_up_is_positive=false` の場合（`GameConfig.data` を一時的に書き換えて元に戻す） |
| ロープの拘束長 | 済み | ソルバーを変えたら既存の閾値のまま通すこと |
| 急停止後の振動・減衰 | 済み | `swing_gain` を変えたときの上限（ロープ長を超えない） |
| 奥行き方向の表現 | 済み（物理 + 投影） | 投影パラメータを変えたら `far/near` テストを確認 |
| 表情状態の遷移 | 一部（ERROR / DISCONNECTED / Z_LOWERING） | `_test_ufo_faces_and_pose_effects` に追加。`mood` を設定し `update_motion(..., dt)` を呼んで `current_face()` を確認 |
| 通信切断と復帰 | Python 側のみ（シリアル切断） | Godot: `RobotState.connected=false` → `GameState.state == "DISCONNECTED"`、復帰で READY/HOMING |
| E-STOP / ALARM | Python 側のみ | Godot: `machine_state = "ALARM"` → `GameState` が ERROR、mood ERROR。復帰の仕様を決めたらそのテストも |
| Mock と実機のインターフェース整合 | なし | pytest: Python `MockRobot` と `RealRobot(FakeFirmware)` の `snapshot().to_message()["data"]` のキーが同じこと、Godot の `_handle` が読むキーを含むこと。新しいコマンドは両方で ACK/NACK を確認 |
| 物理の計算時間と FPS | 1 ステップの時間のみ | FPS は `--capture` の出力（`avg FPS / min FPS / physics us`）で確認して報告 |

Godot テストの注意:
- Autoload（`GameConfig` `RobotState` `GameState`）は 1 回の実行で共有される。状態を変えたテストは最後に元に戻す（例: `GameState.set_state("DISCONNECTED")`、`RobotState.connected` の復元）。テストの順番に依存させない。
- 新しいテストは `_test_xxx()` を作って `_ready()` から呼ぶ。`assert()` は使わない（失敗すると quit されずに止まる）。
- `await` を使うテストは避ける。時間依存の処理は dt を直接渡して進める。

Python テストの注意:
- 実機の応答を増やすときは `FakeFirmware.write_line()` に分岐を足す。行形式は `docs/firmware_protocol.md` と同じにする。
- FakeFirmware で通ることは、実機で通ることの証明にならない（タイミング、24 行ログキューの取りこぼしは未検証）。

## 4. 目で見る確認

```bash
cd game
godot --path . -- --scenario sudden_stop
godot --path . -- --scenario xyz_together --capture /tmp/frames   # 0.5 秒ごとに PNG を 16 枚、終了時に FPS と物理時間を表示
godot --path . -- --scenario xy_diagonal --log-motion /tmp/motion.csv --quit-after 10
#   P 行 = 物理 tick（生サンプル、再生位置、アンカー、加速度、再生時計 play_ms / newest_ms / delay_ms）
#   R 行 = 描画フレーム（UFO の画面位置、画面速度、傾き、表情）
godot --path . -- --source websocket --hide-debug
```

シナリオ: `x_sweep y_sweep xy_diagonal sudden_stop z_down_up xyz_together disconnect reconnect limits rope_snap grab_cycle`（`mock_robot.gd::run_scenario`）。新しい演出を足したら、それを再現するシナリオも足すと確認が早い。

- キャプチャはウィンドウが必要（headless では画像が空になる）。保存先はスクラッチの場所にし、リポジトリに入れない。
- PNG は Read ツールで開いて目視できる。

デバッグパネル（F1/Tab）: 物理・投影の値の変更、表情の固定、Mock の切断/再接続、シナリオ、FPS と物理時間、状態チップ（`[source] conn machine= game= motors=`）、WebSocket のログ。

## 5. end-to-end（実機なし）

```bash
./start.sh mock          # Python --mock バックエンド + Godot（--source websocket）
```

パネルで `Backend: enable motors` → `home` → `z_zero` → スライダー → `E-STOP` → ALARM 表示を確認。ログに `ack` / `nack` が出る。

## 6. 報告のテンプレート

```
- Godot: 36 → NN passed, 0 failed（コマンド）
- pytest: 31 → NN passed（コマンド）
- 目視: シナリオ名 / キャプチャで確認した内容（または未実施）
- 実機: 未検証（理由: 未接続）/ 確認する手順: ...
```

実機がつながっていない環境では、実機テストに成功したと書かない。
