# UFOくん 勉強モード（#86）

子どもが宿題に取り組むのを、青い UFO の「UFOくん」が見守り、難問ではアームで近くまで見に行って解説し、
終わったらお祝いして片付けまで手伝う体験です。Godot のメイン画面で動きます（別アプリではありません）。

## 1. 体験の流れ

| 段階 | 画面と UFOくん | 中身 |
|---|---|---|
| 1. 勉強の時間 | 「そろそろ勉強の時間だよ！」「今日は月曜日！宿題をチェックしよう！」。右に月曜日の宿題チェック表 | `INTRO`。曜日は `study_mode.weekday_label` |
| 2. 宿題開始 | 「席について、プリントを置いてね！」→ プリントを見つけたら「宿題スタート！」 | `WAITING_FOR_WORKSHEET` → `STUDYING`。学習タイマー開始。学年は `,` / `.`（または ◀ ▶） |
| 3. HELP | Y キーで「困ったの？」「ぼくが近くで見てみるよ！」 | `HELP_LOCATING` → `HELP_MOVING`。問題 3（チャレンジ）を見に行く |
| 4. 撮影と解説 | 丸いスコープに 10cm → 5cm → いちばん近く。シャッター音と光。解説を吹き出しと声で | `CAPTURE_10CM` → `CAPTURE_5CM` → `CAPTURE_LANDING` → `AI_EXPLAINING` → `RESUME_STUDY` |
| 5. 宿題完了 | 「やったー！！！」。紙吹雪の波・左右のクラッカー・フラッシュ・ファンファーレ・「宿題完了！！」 | `HOMEWORK_COMPLETE` → `CELEBRATION`（1 回だけ） |
| 6. 片付け | 「最後にお片付けをするよ！」。今日のお勉強時間を大きく表示 | `CLEANUP`（失敗は `CLEANUP_FAILED`） |
| 7. ゲーム解放 | MISSION COMPLETE! / GAME MODE UNLOCKED! /「ゲームで遊ぶ」ボタン | `GAME_UNLOCKED` → 既存の UFO キャッチャーへ |

止めたとき（Space）やアームの異常は `ERROR`（Enter で宿題に戻る。勝手に動き直さない）。

## 2. 起動と操作

```bash
./start.sh --mock --no-gesture --study-mode       # バックエンド --mock + ゲーム（勉強モードで開始）
./start.sh --game-only --study-mode               # ゲームだけ（Godot 内蔵の Mock でアームを再現）
./start.sh --game-only -- --study-demo mock       # mock / camera / real を指定して開始
```

ゲームの中ではいつでも **F5** で勉強モードの開始・終了。

| キー | 働き |
|---|---|
| Enter | 次へ・大人の確認（プリントを置いた / 全問書けたことの確認 / ジグをつかめた / 片付け失敗の確認 / ゲームで遊ぶ） |
| Y | HELP（`study_mode.help.key`。宿題アシスタントの「止まっている問題」キーと同じ） |
| Space | 止める（ゲームの停止キー。勉強モードの動きも止める） |
| 1 / 2 / 3 | Mock デモ: その問題に記入した（記入中 → 次の読み取りで記入済み） |
| , / . | 学年を変える（最初の画面とプリント待ちのとき） |
| F6 / F7 / F8 | 状態のスキップ / 失敗の注入（位置特定・アーム停止・AI・音声・手で隠れる・片付けを順に） / 最初から |

勉強モード中は F1 のデバッグパネルを閉じて始めます（F1 で再表示）。ゲームの他のキーはそのまま。
HELP と片付けの間は、矢印・W/S・ジェスチャーによる手動操作を受け付けません。

## 3. デモモード（`study_mode.demo.mode`）

| モード | プリント・記入 | 位置 | 解説 | アーム |
|---|---|---|---|---|
| `mock` | 模擬（`worksheet_wait_s` 秒で発見。記入は 1/2/3 キー、`auto_answer` で 1・2 問を自動） | プリントデータから | プリントのヒント | バックエンドの Mock（`./start.sh --mock --no-gesture --study-mode`）か、ゲーム内蔵の Mock |
| `camera` | 俯瞰カメラ + Jev（HomeworkClient の見守りにワークシートを付ける） | Claude/Codex + Jev + 基準マーク + camera_map | Claude / Codex | Mock のみ（バックエンドが実機なら動かさない） |
| `real` | 同上 | 同上 | 同上 | 実機（高さ校正と確認がないと拒否） |

声は `homework.speech`（VOICEVOX → macOS `say`）。バックエンドがないとき・声が作れないときは文字だけで進みます（行ごとの読み時間で次へ）。

## 4. 設計

- **体験と機械を分ける。** `StudyModeController`（Godot）は体験の状態機械だけ。`RobotState` を書かず、ロボットへのコマンドも自分では送りません。動きは `StudyServices` に頼み、`StudyServices` はバックエンドの**シーケンス 1 本**（モーションロックを持つ）を始めるか、ゲーム内蔵の Mock に目標を渡すだけです。JOG は送りません。
- **バックエンドの動き。**
  - HELP: 既存の `ApproachSequencer` に段階撮影を追加。`homework_approach {xy|u,v, stages: "study"}` で、ひとつのモーションロックのまま RAISE → MOVE_XY → (LOWER → SETTLE → HOLD) × 3 → RAISE_BACK → RETURN_XY。各 HOLD はゲームの撮影後 `homework_approach_release {stage}` で次へ（別の段の release は無視）。
  - 片付け: `sequence/cleanup.py` の `CleanupSequencer`（同じ安全の枠）。`study_cleanup_start` / `study_cleanup_confirm` / `study_cleanup_status`。
  - STOP / soft_stop / モーター OFF / 操作者の切断で FAULT（ロボットの stop = ABORT）。再接続しても自動では再開しません。
- **認識と AI（既存の再利用）。**
  - 進捗: `HomeworkService` の Jev 呼び出しに、問題ごとの「解答欄に手書きの答えがあるか」の質問を 3 つ追加（同じ 1 回の呼び出し）。`homework_progress.questions`。
  - 判定（ゲーム側 `StudyQuestionTracker`）: 未着手 / 記入中 / 記入済み / 判定保留。記入済みは 2 回続けて（`confirm_readings`）、完了は全問が `complete_readings` 回続けて記入済みのときか、大人の Enter。手で隠れているときは更新しません。**正解かどうかは判定しません。**
  - 位置: `homework_locate {kind: "problem", problem: 3, worksheet_id}`。Claude/Codex が解答欄を答え、Jev が同じ解答欄を探し（一致しないと動かさない）、さらに Jev が見つけた四隅の基準マークからページの位置を計算して、問題 3 の領域と合わないときも動かしません。動く先は camera_map（ホモグラフィ校正）で XY に変換し、校正が使えないとバックエンドが拒否します。
  - 解説: `homework_explain` で俯瞰 + 3 枚の近接画像を 1 回の質問で渡し、構造化 JSON（`problem_number, recognized_problem, confidence, hint, explanation, speech_text, needs_confirmation`）を受け取ります。プリントデータの問題文と照合し、違えば `needs_confirmation`。失敗時はプリントのヒントで解説します（`fallback`）。
- **演出。** GameState のイベント `study_*` を `vfx_director.gd` が受けて既存の PixelFX（`success_confetti`、`success_sparkle`、`start_energy`、`grab_burst`、`fail_poof`）を出します。クラッカー・フラッシュ・バナーは HUD（`ui/study_hud.gd`）。効果音は `study_mode/study_sounds.gd` がその場で合成（音声ファイルなし）。

| ファイル | 役割 |
|---|---|
| `game/scripts/study_mode/study_mode_controller.gd` | 体験の状態機械、キー、大人の確認 |
| `game/scripts/study_mode/study_services.gd` | モードごとの外部（Mock / Jev / AI / ロボット）との窓口 |
| `game/scripts/study_mode/question_tracker.gd` | 問題ごとの状態と完了の判定 |
| `game/scripts/study_mode/study_speech.gd`, `study_sounds.gd` | 吹き出しと声の同期、効果音 |
| `game/scripts/study_mode/worksheet_catalog.gd` | プリントデータ（Godot） |
| `game/scripts/ui/study_hud.gd` ほか `study_*_view.gd`, `study_crackers.gd` | 画面 |
| `backend/.../study_mode/` | プリントデータ（Python）、高さ校正、解説 |
| `backend/.../homework/questions.py` | 問題ごとの Jev 質問 |
| `backend/.../sequence/cleanup.py` | 片付けシーケンス |
| `tools/build_worksheets.py` → `config/worksheets.json`, `docs/worksheets/` | プリント（12 学年 × 3 問）と印刷用 A4 SVG |

## 5. プリント

`python3 tools/build_worksheets.py` が `config/worksheets.json`（データ）と `docs/worksheets/*.svg`（印刷用 A4、
`index.html` から開く）を作ります。内容を変えるときはスクリプトを直して再生成（`--check` でずれを検出。テストでも確認）。

- 学年: 保育園 年少・年中・年長（数・形・絵）、小学 1〜6 年、中学 1〜3 年（算数・数学）。
- 各プリント 3 問: 1・2 はやさしい、3 はチャレンジ（HELP の対象）。正答・解法・段階的なヒント・英語の説明（Jev 用）付き。
- 座標は A4 のミリメートル（左上原点）。四隅の黒い基準マーク（中心座標は `fiducials`）から紙 → 画像のホモグラフィを計算できます。印刷は倍率 100%。

## 6. 実機で必要な校正（すべて未実施・実機未検証）

| 項目 | 設定 | 内容 |
|---|---|---|
| 俯瞰カメラ ↔ XY | 宿題タブの校正（`config/camera_xy_calibration.json`） | 既存（#78）。4 点以上 |
| 高さ | `study_mode.height.real` | `z_desk_tip`（爪先が机に触れる Z）、`z_per_cm`（高さ 1 cm あたりの Z。既知の高さの台で測る）、`camera_offset_cm`（爪先からレンズまで）、`landing_tip_cm`。接触する着地は `allow_landing_contact` を実機で確かめてから。全部の `confirmed` を手で true にするまで実機の段階下降は拒否 |
| 片付け | `study_mode.cleanup.real` と `enabled_real` | ジグの保管位置・把持高さ・爪の開閉・経路・回収位置・禁止領域・速度・タイムアウト。`enabled_real` と全部の `confirmed` が要る |
| 前提 | — | `z_sign` / `z_counts_per_unit` / `arm_open_turns` は実機で未確認のまま |

## 7. 安全

- 実機では、HELP と片付けのアームを動かす前に**大人の Enter** が必要です（Mock の準備＝モーター ON・原点復帰も Enter）。
- カメラによる人の検出は安全の保証として扱いません。動作中は子どもの手が可動範囲に入らない運用にしてください。
- ジグの把持は自動で判定しません（センサーがない）。大人が Enter で確認し、`grip_confirm_timeout_s` で FAULT。
- 回収はクリップなど磁石につく安全なテスト用の物だけ。鉛筆や消しゴムは回収できません。磁石の誤飲・電子機器への接近に注意。
- 通信が切れたことの検知は、実機が止まったことの保証ではありません（ファームウェアにホストウォッチドッグはない）。
