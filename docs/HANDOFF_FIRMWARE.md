# ファームウェア担当エージェントへのハンドオフ — CoreXY UFO Game から

作成日: 2026-10-24
対象: `CoreXY_UFO`（M5Stack Core2 ファームウェア）リポジトリを担当するエージェント
送り元: `CoreXY_UFO_Game`（https://github.com/fooping-tech/CoreXY_UFO_Game）

## 1. 状況

ゲーム側（Godot + Python バックエンド）は完成し、実機未接続でテスト済み（Godot 物理 26 件、pytest 31 件）。
バックエンドは **現在のファームウェア（HEAD 160742d）のコマンドだけ** で動くよう実装してある。ファームウェア側の変更は必須ではないが、以下 §4 の改善があるとゲーム体験と安全性が大きく上がる。

ゲームの要件: クレーンの XY と Z（アーム高さ）を 10〜30 Hz で追従表示し、UFO キャラクターをロープ物理で揺らす。**実機 Z が上がると画面の UFO は下がる**。

## 2. バックエンドが現在ファームウェアに送っているもの

接続: USB シリアル 115200 8N1、`\n` 終端、1 行 ≤127 文字。常時接続し、`POS` をアイドル時に約 10 Hz でポーリングする（移動中はポーリングしない）。

| ゲーム操作 | 送信 | 期待する応答（ソースで確認済みの形式） |
|---|---|---|
| ホーミング | `HOME` | `ACK QUEUED HOME` → `HOME complete X=.. Y=..` / `HOMING error ...` |
| XY 移動 | `XY <x> <y> <F>` | `ACK QUEUED XY` → `ACK_XY target=(x,y) ...` / `NACK_XY ... reason=...` |
| 位置取得 | `POS` | `POS X=.. Y=.. ... HOMED= MOTION= ALARM= ALARM_REASON="..." TEST_MODE= ...` |
| Z 基準設定 | `SERVO_STATUS 1` | `SERVO_STATUS id=1 result=OK ... abs=<counts> ...`（アーム最上位でのカウントを 0 基準にする） |
| Z 上下 | `TEST_MODE ON`（初回）→ `SERVO_TURN 1 <±turns>`（≤3 回転ずつ分割） | `SERVO_TURN id=1 value=.. result=PASS target=.. actual=..` |
| 掴む / 放す | `SERVO_TURN 2 <±turns>` | 同上 |
| 非常停止 | `ABORT`（ロック外で即送信） | `ABORT complete` |
| アラーム解除 | `ALARM_CLEAR` | `ALARM_CLEAR complete` |

解析ロジック: `backend/src/corexy_ufo_backend/serial_service/protocol.py`（正規表現と行分類）。
実機を模したテスト: `backend/tests/conftest.py` の `FakeFirmware` — **応答形式を変える場合はここを合わせて更新してほしい**。
調査メモ（file:line 付き）: `docs/firmware_protocol.md`。

## 3. 実機で決めてほしい値（`config/game_config.json` の `backend`）

| キー | 意味 | 現在値 |
|---|---|---|
| `z_sign` | `SERVO_TURN 1` に正の回転を与えるとアームが**上がる**なら `1`、下がるなら `-1` | `1`（未確認） |
| `z_counts_per_unit` | サーボカウント / Z 抽象単位（Z は 0..100、100 = アーム最上位）。既定は 3 回転 = 12288 count = 100 単位 | `122.88`（未確認） |
| `arm_open_turns` | 掴む／放すの回転量 | `0.5`（未確認） |
| `xy_feed_mm_min` | XY 移動の F 値 | `900` |

`PlotterConfig.h:240-242` では「正方向 = 時計回り、実機で合わせる」とあり、どちらがアーム上昇かはコードに無い。確認後、値と根拠（実測）を教えてほしい。

## 4. ファームウェアへの改善要望（優先度順）

追加の依頼（シリアルからの速度ジョグ `JOG` と、アラームにしない停止 `STOP`）は [HANDOFF_FIRMWARE_JOG.md](HANDOFF_FIRMWARE_JOG.md) にある。

### 4.1 ホスト通信断で停止する（安全・優先度 高）

現状: ホストウォッチドッグが無い（`JOY_LINK_TIMEOUT_MS` は ESP-NOW ジョイスティック専用）。USB が抜けてもキュー済み動作が続く。
要望: ホストからのハートビート（例: `HB` コマンド、または任意のコマンド受信）が N 秒（1〜2 s 想定、設定可能）途絶えたら `ABORT` 相当の停止を行い、`HOST_TIMEOUT ...` 行を出す。モーション中のみ有効でよい。ゲーム起動時に `HOST_WATCHDOG ON <ms>` で明示的に有効化できる形だと、既存ツール（serial_send.py / WebUI）を壊さない。
バックエンド側はすぐ対応できる（定期送信を 1 行追加するだけ）。

### 4.2 Z / アーム専用コマンド（優先度 高）

現状: `TEST_MODE ON` 中の `SERVO_TURN` のみ。3 回転/回の制限、Z ホーミング無し、絶対位置はサーボ電源投入時基準。
要望例:
- `Z_HOME`（上限スイッチ or トルク検知で最上位を 0 に）— `PLANS.md:2502-2506` の未実装項目
- `Z <mm or counts>` 絶対移動（ソフトリミット付き）、`ARM OPEN` / `ARM CLOSE`
- 完了行は `ACK_Z target=.. actual=..` / `NACK_Z reason=..` のように XY と同じ流儀だと解析が共通化できる
- テストモード不要で使えること（現在は `TEST_MODE ON` を送っている）

### 4.3 移動中の位置通知（体験・優先度 中）

現状: motionTask が逐次実行のため、移動中の `POS` は移動完了後に返る。ゲームは移動中 XY を推定している（`measured:false`）。
要望: 移動中も 10〜20 Hz で現在位置を自動送信する `REPORT ON <ms>` のようなモード、または `?` 系の即時応答。ログキュー（24 行、満杯で破棄）との兼ね合いで、`STATUS X=.. Y=.. Z=.. MOTION=..` を 1 行に収めると取りこぼしに強い。

### 4.4 その他（低）

- `POS` 行にサーボ 1/2 の `abs` を含める（`SERVO_STATUS` の往復を省ける）
- `ABORT` 後に `ALARM_CLEAR` + `HOME` が必須になる仕様はそのままでよいが、`ALARM_REASON="abort requested"` を区別できるようにしてある（ゲームは「E-STOP、再ホーミングが必要」と表示）

## 5. 互換性の約束

- バックエンドは応答行を**先頭一致の正規表現**で待つ（`protocol.py: COMPLETION_PATTERNS`）。既存行の先頭トークン（`ACK QUEUED`, `ACK_XY`, `NACK_XY`, `HOME complete`, `POS `, `SERVO_TURN id=`, `ABORT complete`, `ALARM_CLEAR complete`, `TEST_MODE result=`）が変わると壊れる。フィールド追加は問題ない。
- 新コマンドを追加した場合、対応する `ACK QUEUED <CMD>` と完了行、失敗時の `NACK_*`/`REJECT:` を同じ流儀で出してもらえれば、`COMPLETION_PATTERNS` に 1 行足すだけで取り込める。
- 既存の WebUI (`tools/webui`) と同時に同じポートは開けない（ゲーム使用時は WebUI を止める）。

## 6. 実機なしでゲーム側を動かす方法（確認用）

```bash
# Godot 単体（MockRobot）
cd CoreXY_UFO_Game/game && /Applications/Godot.app/Contents/MacOS/Godot --path .
# バックエンド + Godot（WebSocket 経路、実機なし）
cd CoreXY_UFO_Game/backend && uv sync && uv run corexy-ufo-backend --mock
cd CoreXY_UFO_Game/game && Godot --path . -- --source websocket
# 自動テスト
cd game && Godot --headless --path . res://tests/test_runner.tscn
cd backend && uv run pytest
```

実機を初めてつなぐ手順は `docs/HANDOFF.md` §6 を参照。

## 7. 連絡事項

- ゲーム側の質問・変更依頼は `CoreXY_UFO_Game` の Issue に。応答形式の変更は `backend/tests/conftest.py` を更新して pytest が通る形で PR してもらえると早い。
