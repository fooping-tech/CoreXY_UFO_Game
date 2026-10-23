# テスト・検証報告（2026-10-24）

環境: macOS (Darwin 25.1, Apple M4), Godot 4.7.2.stable, uv 0.9.20 / CPython 3.13.11。

## 1. 成功した項目

### Godot 物理テスト `game/tests/run_tests.gd` — 26/26 PASS

| 項目 | 結果 |
|---|---|
| 静止: UFO がアンカー直下に垂れ、距離 = ロープ長、自発振動なし、セグメント伸び < 1% | PASS |
| 高速 XZ 掃引中: セグメント伸び < 5%、UFO がロープ長を超えない、NaN なし | PASS |
| 加速: UFO が慣性で遅れる / 急停止: 振り子運動 → 減衰（後半振幅 < 前半 60%）/ ロープ長以内 | PASS |
| XY 斜め: X と奥行き両方に遅れ、奥行き方向の揺れが出る | PASS |
| ロープ短縮: 目標到達、UFO 上昇、伸びなし / 急伸長: 新ロープ長で安定 / 最大長クランプ | PASS |
| Z 逆マッピング: アーム最上位 → ロープ最長、単調 / アンカー: X+ → 右, Y+ → 奥 | PASS |
| 投影: ロープ末端と UFO が同一スクリーン座標、遠い物は小さく上に、原点一致 | PASS |
| 性能: 16 セグメント × 8 反復で 1 ステップ平均 約 170 µs | PASS |

### 描画・実行（`--capture` で PNG 保存して目視確認）

- シナリオ sudden_stop / xyz_together / WebSocket 経由の home→XY→Z→ABORT→切断 でフレームを確認。
- ロープはアンカー移動で斜めにたわみ、停止後に振り子運動。UFO はロープ接線方向に傾き `move_left/right` ポーズ、急加速時 `panic` ポーズ、Z 下降中 `strain_up`、Z 上昇中 `straining`、ALARM で `surprised`、切断で `worried` に切り替わる。
- FPS: 平均 90〜110（キャプチャ中、vsync あり）。物理 150〜190 µs/ステップ。
- 最近傍補間（プロジェクト設定 `default_texture_filter=0`）でドット絵がぼやけない。
- ヘッドレス起動 300 フレームでスクリプトエラーなし。

### Python バックエンド `backend/tests` — 31/31 PASS（約 6 秒）

- プロトコル解析: POS 行（ALARM_REASON 内の空白含む）、SERVO_TURN 結果、SERVO_STATUS、失敗行判定、行長・改行バリデーション。
- SerialService（FakeFirmware）: POS 往復、HOME→XY、未ホーミング NACK、`CommandQueue full` リトライ、不明コマンド拒否、タイムアウト、コマンド直列化、ABORT→ALARM→ALARM_CLEAR、切断時の待機中コマンド失敗。
- RealRobot: 起動時モーター無効、HOME/XY、ホスト側ソフトリミット、ファームウェア NACK の伝搬、Z 基準未設定の拒否、Z の 3 回転チャンク分割、ABORT 後の alarm/homed 解除と復帰手順、アーム開閉。
- WebSocket: hello と状態ストリーム、モーター無効時の NACK、`request_id` 重複の非再実行、不正パラメータ、stop の常時受付、ソフトリミット NACK、ALARM 状態通知。
- Vision: Detection/DetectionResult、ジェスチャ規則、Cloudflare がインターフェースのみであること。

### エンドツーエンド

`corexy-ufo-backend --mock` + Godot `--source websocket` + Python クライアントで `move_xy`(NACK: motors not enabled) → `enable_motors` → `home` → `move_xy` → `move_z` → `stop` を実行し、Godot 側でロープ長・表情・ALARM・切断表示が追従することを確認。

## 2. 未検証の項目

- **実機 M5Stack Core2 との接続**（本セッションでは実機を接続していない）。FakeFirmware はソースから読み取った行形式を再現しているが、実機のタイミング・ログ取りこぼし（24 行キュー）は未検証。
- **Z サーボの回転方向**（`backend.z_sign`）と `z_counts_per_unit`（ドラム径による）。実機で合わせる必要がある。
- **アームの開閉量**（`arm_open_turns`）。
- **USB 切断時の実機停止**: 調査の結果、ファームウェアにホストウォッチドッグがなく、切断時に自動停止しない（docs/firmware_protocol.md §4）。バックエンドは自プロセス終了時に `ABORT` を送るが、ケーブル抜去には対応できない。ファームウェア側にホストハートビート監視を追加することを推奨（既存機能の変更になるため本作業では未実施）。
- カメラ実機・YOLO・MediaPipe の実行（オプション依存のため環境に入れていない。インターフェースと単体テストのみ）。
- Godot の実機モードでの長時間安定性、Godot エディタからのエクスポート。

## 3. 既知の課題・今後

- 移動中の XY は推定（線形 smoothstep）。実機の実際の加減速プロファイルと合わないと、停止タイミングで UFO の揺れが実物と少しずれる。ファームウェアが移動中に位置を返せるようになれば `measured` に置き換わる。
- `ABORT` はアラーム + HOMED 解除のため、E-STOP 後は毎回 `clear_alarm` → `home` が必要（ファームウェア仕様）。
- Z は電源投入からの相対値。`z_zero` を忘れると `move_z` は NACK になる（意図的）。
- デバッグパネル表示中は描画領域が狭くなる。大きく揺らすとパネルの下に入ることがある（F1 で非表示にすれば発生しない）。
- Phase 4（サウンド、パーティクル強化、UFO の個性づけ）は未着手。成功/失敗演出はスプライトアニメ + 簡易パーティクルのみ。
