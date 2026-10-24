# 実機プロトコルと安全

一次資料は `docs/firmware_protocol.md`（ファームウェアのソースで確認した事実、file:line 付き）と、兄弟リポジトリ `../CoreXY_UFO`（https://github.com/fooping-tech/CoreXY_UFO、HEAD 160742d で調査済み）。ここでは**ゲーム側で設計するときの判断**だけを書く。行の形式は複製しないので、必要になったら一次資料を開くこと。

## 1. 経路（これ以外でモーターを動かさない）

```
Godot UI/キー ─ UfoWebSocketClient.send_command(name, params)   # request_id = "g<ms>-<seq>"
   ─ WS JSON {"type":"command","request_id",data:{name,params}}
   ─ GameServer._handle_command   # request_id キャッシュ（500 件）、重複は再実行せず結果を返す
   ─ GameServer.execute           # COMMANDS 検査、モーションロック（busy は NACK）
   ─ RobotInterface (MockRobot | RealRobot)
   ─ SerialService.send           # 直列化、ACK QUEUED 待ち、完了行待ち、タイムアウト
   ─ USB シリアル 115200 → M5Stack Core2 ファームウェア
```

戻り: `robot_state` を 30 Hz でブロードキャスト（`RobotSnapshot.to_message()`）。Godot は `connected homed motors_enabled state x y z measured error` を読む（`alarm test_mode z_reference_set` は今は読んでいない）。

## 2. 安全上の制約と、それを壊さない設計

| 制約 | 実装場所 | 設計上の注意 |
|---|---|---|
| 起動時はモーター無効 | `RealRobot.motors_enabled=False`、`_require()` | 起動時に自動で `enable_motors` を送る UI を作らない |
| アーミングが必要 | `enable_motors`（何も送信しない、バックエンド側の状態） | 解除すると動作中なら `stop` |
| XY 前のホーミング | `_require(homed=True)`、ファームウェアも拒否 | `ABORT` 後は HOMED が外れる |
| Z の基準 | `set_z_zero`（アームを手で最上位にしてから） | 未設定の `move_z` は NACK（意図的）。自動で `z_zero` しない |
| ソフトリミット | ホスト側 `RobotLimits.xy_inside`、ファームウェア X 0..390 / Y 0..200 mm | Z はクランプのみ。範囲外の XY はクランプせず NACK |
| ACK/NACK・タイムアウト | `SerialService`（Python）、`_check_timeouts`（Godot、既定 3000 ms） | タイムアウトは「失敗」であって「止まった」ではない |
| `request_id` による重複防止 | `GameServer._handled` | クライアントはモーションを自動再送しない。再送するなら同じ `request_id` を使う |
| 切断検知 | `state_timeout_ms` 1500 ms で `connected=false`、シリアル切断で `motors_enabled=False` | 検知 ≠ 停止 |
| `stop` は常に受け付ける | `execute` でロックの外、`SerialService.abort` はロック外で即送信 | `stop` の前に条件チェックや確認ダイアログを足さない |
| ABORT とアラーム解除 | `ABORT` → ALARM + HOMED 解除 → `ALARM_CLEAR` → `HOME` | 復帰手順を UI で案内する |
| 実測と推定の区別 | `measured`（Python）→ `RobotState.position_is_measured` | 移動中 XY は smoothstep の推定。演出で「実測」と表示しない |

### ファームウェアにできないこと（前提にしない）
- 移動中の実測 XY の連続送信（移動中は `POS` に応答しない）。
- ホストウォッチドッグ。USB が抜けてもキュー済みの動作は続く。バックエンド終了時の `ABORT` はケーブル抜去には効かない。
- Z ホーミング、Z/アーム専用コマンド（`TEST_MODE ON` 中の `SERVO_TURN` のみ、1 回 ≤3 回転）。
- 物理的な非常停止入力。TMC2209 の EN は常時有効なので、電気的に止めるには外部スイッチが必要。

ここにない機能が必要なら、ゲーム側で偽装せず `docs/HANDOFF_FIRMWARE.md` §4 の形でファームウェアへの要望として書く。

## 3. Z 軸の同期作業

1. **ゲーム側は正しい前提で触らない**: `rope_length_for_z` と `z_up_is_positive` は Godot のテスト（`Z inverse`）で固定されている。
2. **換算は `RealRobot`**: `move_z` は `delta_units * z_counts_per_unit / 4096 * z_sign` 回転を 3 回転ずつに分けて送り、`SERVO_TURN ... actual=` から `_z_units_est` を更新する。
3. **実機での確認手順**（`docs/HANDOFF.md` §6）: `enable_motors` → `home` → アームを手で最上位にして `z_zero` → Z を少し下げる → 実機のアームが**下がる**ことを確認。逆なら `z_sign=-1`。ドラム 1 回転あたりの昇降量から `z_counts_per_unit` を決める。
4. 値を確定したら `config/game_config.json` の `_note` と `docs/test_report.md` に根拠（実測）を書く。確認するまでは「未校正」と書いておく。
5. 移動中の Z は `move_z` の完了まで更新されない（サーボの結果行で更新）。画面のロープ長は `rope_length_rate` で滑らかに追従する。

## 4. 変更時のチェックリスト

- [ ] 送るコマンドはファームウェアのソースで実在を確認したか
- [ ] `COMMANDS` / `MOTION_COMMANDS`、`RobotInterface`、Python `MockRobot`、`RealRobot`、`FakeFirmware` を揃えたか
- [ ] 完了行の判定は先頭一致のまま厳密か（`protocol.py: COMPLETION_PATTERNS`）
- [ ] `stop` の即時性を落としていないか（ロック、await、busy チェック）
- [ ] 失敗時に `self.error` が設定され、NACK の reason として返るか
- [ ] ゲーム演出の変更とコミットを分けたか
- [ ] 「実機未検証」を報告に書いたか

## 5. 既知のずれとギャップ（2026-10-24 時点、未修正）

修正するときは独立した変更として扱い、テストを追加すること。

| 項目 | 現状 | 影響 |
|---|---|---|
| GDScript Mock の E-STOP | ALARM にならず、`homed` も外れない | Mock で作った E-STOP 演出が実機の復帰手順と合わない |
| `GameState` の ERROR | `error_cleared`（デバッグパネル Clear）でしか抜けない。`clear_alarm` → `home` 後も ERROR のまま | 実機モードで演出が戻らない |
| `RELEASING` | `GameState._on_machine_state_changed` に対応がない | 放す動作のリアクションがない |
| `alarm` / `z_reference_set` | Python は送るが Godot は読んでいない | UI で「Z 基準未設定」を出せない |
