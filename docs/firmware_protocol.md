# CoreXY_UFO ファームウェア シリアル通信仕様（調査結果）

対象: `https://github.com/fooping-tech/CoreXY_UFO`（ローカル: `../CoreXY_UFO`, HEAD 160742d）。
以下はファームウェアのソースから確認した事実です。推測で作ったコマンドはありません。

## 1. トランスポート

| 項目 | 値 | 出典 |
|---|---|---|
| ボーレート | 115200 8N1 | `include/PlotterConfig.h:145` `SERIAL_BAUD` |
| 行終端 | `\r` または `\n`（送信は `\n` で十分） | `src/tasks/CommandTask.cpp:37-91` |
| 最大行長 | 127文字。超過は `ERROR: input line too long` | 同上 |
| 大文字小文字 | 先頭1文字のみ大文字化。名前付きコマンドは実質大文字のみ | `src/CommandDispatcher.cpp:74` |
| 応答 | プレーンテキスト行。JSONなし、プレフィックスなし、タイムスタンプなし | `src/tasks/LogTask.cpp` |
| ログキュー | 24行、満杯時は**黙って捨てる** | `main.cpp:34-43`, `TaskConfig.h:18` |
| 起動バナー | `CoreXY plotter ready. Type HELP.` | `main.cpp:92` |

## 2. ハンドシェイク

1. コマンド送信 → `ACK QUEUED <CMD>`（キュー投入）または `ERROR: <msg>` / `ERROR: CommandQueue full`
2. motionTask が**逐次**実行（一度に1コマンド）
3. 完了行（コマンド別）

| コマンド | 完了行 |
|---|---|
| `XY x y [F]` | `ACK_XY target=(x,y) A=.. B=.. F=..` / `NACK_XY target=(x,y) reason=rejected\|abort\|alarm\|...`（直前に `REJECT: ...` 行） |
| `HOME` / `G28` | `HOME complete X=.. Y=.. A=.. B=.. limitX=ON\|OFF limitY=..` / `HOMING error ...` |
| `POS` / `M114` | `POS X=.. Y=.. ... HOMED=YES\|NO ... MOTION=YES\|NO ... ALARM=YES\|NO ALARM_REASON="..." TMC=READY\|NO LIMIT_X=.. TEST_MODE=ON\|OFF JOY=..` |
| `SERVO_TURN id turns` | `SERVO_TURN id=N value=V result=PASS\|TIMEOUT\|ABORTED\|REJECTED\|FAILED target=.. actual=.. error=.. ms=..` |
| `SERVO_STATUS id` | `SERVO_STATUS id=N result=OK ... abs=<counts> turns=<t> ... moving=0\|1` / `result=NO_REPLY` |
| `TEST_MODE ON\|OFF` | `TEST_MODE result=ON (...)` / `result=OFF ...` / `result=REJECTED reason=..` |
| `ABORT` | `ABORT complete`（アラーム発生 + HOMED解除） |
| `ALARM_CLEAR` | `ALARM_CLEAR complete` |

**重要な制約**

- 移動中は `POS` に応答しない（移動完了後に応答）。**移動中のリアルタイム位置は取得できない**。バックエンドは移動中を「推定位置（measured=false）」として補間する。
- 定期的な自動ステータス送信はない。ホストがポーリングする。
- `ABORT` はアラームをセットし HOMED を解除する。復帰は `ALARM_CLEAR` → `HOME`。

## 3. Z軸（紐とドラム）とアーム

- Z = STS3020 サーボ ID 1、アーム = ID 2（`README.md:78-79`, `SPEC.md:1268`）。
- **専用の Z 上下 / アーム開閉コマンドは存在しない**。`TEST_MODE ON` 中のみ `SERVO_TURN <id> <turns>`（±3回転/コマンドまで、4096 count/回転）または `SERVO_ANGLE <id> <deg>` で動かす。
- 絶対位置はサーボ電源投入時からの相対値（`abs=` カウント）。**Zのホーミング・リミットスイッチは未実装**（`PLANS.md:2502-2506`）。
- 正方向＝時計回り。**どちらの符号でアームが上がるかはコードに記述がなく「実機で合わせる」**（`PlotterConfig.h:240-242`）。`config/game_config.json` の `backend.z_sign` で設定する。
- 追従範囲: ±28000 count（約 ±6.8 回転）。速度 2400 count/s。
- `TEST_MODE ON` は HOMED を解除しないため、`HOME` → `TEST_MODE ON` → `XY` と `SERVO_TURN` を併用できる（`SafetyManager.cpp:21-62`）。`TEST_JOG` は HOMED を解除するので使わない。

## 4. 可動範囲・安全機構（ファームウェア側）

- ソフトリミット: X 0..390 mm, Y 0..200 mm（`PlotterConfig.h:116-119`）。HOMED 後の `XY` のみ適用。
- リミットスイッチ: X=GPIO36, Y=GPIO35, active LOW, 30ms デバウンス。ホーム側のみ。
- アラーム中は `XY`/`HOME` 拒否。`ALARM_CLEAR` で解除。
- **ホストウォッチドッグは存在しない**。USB が切れてもファームウェアはキュー済みの動作を続ける。ジョイスティックの 250ms リンク断停止は ESP-NOW ジョイスティック専用。
- 物理的な非常停止入力はない（`ABORT` コマンド、LCD、ジョイスティック右ボタンのみ）。
- TMC2209 の EN は GND 固定で常時 active。電気的遮断には外部スイッチが必要。

## 5. バックエンドでの対応付け

| ゲームコマンド | 送信内容 | 備考 |
|---|---|---|
| `enable_motors` | （送信なし） | バックエンド側のアーミング。これ以前の動作コマンドは NACK |
| `home` | `HOME` | `HOME complete` 待ち |
| `move_xy {x,y}` | `XY x y F` | ホスト側でもソフトリミット検査 |
| `z_zero` | `SERVO_STATUS 1` | 現在の `abs=` を「アーム最上位」基準に設定 |
| `move_z {z}` | `TEST_MODE ON`（初回）→ `SERVO_TURN 1 ±t`（≤3回転ずつ） | `z` は 0..100 の抽象単位。`z_counts_per_unit`, `z_sign` で換算 |
| `grab {close}` | `SERVO_TURN 2 ±arm_open_turns` | |
| `stop` | `ABORT` | ロック外で即送信。以後 `clear_alarm` と `home` が必要 |
| `clear_alarm` | `ALARM_CLEAR` | |

## 6. 既存ツールとの関係

- `tools/serial_tool/serial_send.py`（キューモードの ACK/完了待ち、`SYNC_COMPLETION_BY_COMMAND`）と `tools/webui/server.py` の正規表現（`POS_RE` 等）を参考に `backend/src/corexy_ufo_backend/serial_service/protocol.py` を実装した。
- 既存の WebUI はコマンド毎にポートを開閉するが、本バックエンドは常時接続してポーリングする。両方を同時に同じポートへ接続することはできない。
