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
./start.sh --game-only -- --study-demo simulated  # simulated / camera を指定して開始
./start.sh --study-mode                           # 実機 + ジェスチャー（demo.source が camera のときだけアームを動かす）
```

起動時のタイトル画面で「勉強モード」を選ぶか、ゲームの中ではいつでも **F5** で勉強モードの開始・終了。

| キー | 働き |
|---|---|
| Enter | 次へ・大人の確認（プリントを置いた / 全問書けたことの確認 / ジグをつかめた / 片付け失敗の確認 / ゲームで遊ぶ） |
| Y | HELP（`study_mode.help.key`。宿題アシスタントの「止まっている問題」キーと同じ） |
| Space | 止める（ゲームの停止キー。勉強モードの動きも止める） |
| 1 / 2 / 3 | 模擬デモ: その問題に記入した（記入中 → 次の読み取りで記入済み） |
| , / . | 学年を変える（最初の画面とプリント待ちのとき） |
| F6 / F7 / F8 | 状態のスキップ / 失敗の注入（位置特定・アーム停止・AI・音声・手で隠れる・片付けを順に） / 最初から |
| Esc | タイトル画面に戻る（勉強モードを止める） |

勉強モード中は F1 のデバッグパネルを閉じて始めます（F1 で再表示）。ゲームの他のキーはそのまま。
HELP と片付けの間は、矢印・W/S・ジェスチャーによる手動操作を受け付けません。

## 3. 何を使うか（`study_mode.demo.source`）と、どのロボットか（start.sh）

config で決めるのは「模擬か、カメラと AI を使うか」だけです。**アームは start.sh がつないだロボット**に従います（`./start.sh` = 実機、`--mock` = バックエンドの仮想クレーン、`--game-only` = ゲーム内蔵の Mock）。

| `demo.source` | プリント・記入 | 位置 | 解説 | 外部への送信 |
|---|---|---|---|---|
| `simulated`（既定） | 模擬（`worksheet_wait_s` 秒で発見。記入は 1/2/3 キー、`auto_answer` で 1・2 問を自動） | プリントデータから | プリントのヒント | **なし** |
| `camera` | 俯瞰カメラ + Jev（HomeworkClient の見守りにワークシートを付ける） | Claude/Codex + Jev + 基準マーク + camera_map | Claude / Codex | 俯瞰と近接の画像を Jev（Cloudflare）と Claude / Codex へ |

| つないだロボット | `simulated` | `camera` |
|---|---|---|
| ゲーム内蔵の Mock（`--game-only`） | 動く | 動かさない（バックエンドが要る） |
| バックエンドの仮想クレーン（`--mock`） | 動く | 動く |
| 実機（`./start.sh`） | **動かさない**（模擬の位置はプリントのデータで、机の上の本物の位置ではないため） | 動く。ただし高さ校正と確認がないとバックエンドが拒否する |

前の `study_mode.demo.mode`（`mock` / `camera` / `real`）と `--study-demo mock|real` も読めます（`mock` = `simulated`、`camera` / `real` = `camera`）。

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
  - 学習支援 AI（#104、§8）: `study.explain_provider: "tutor"` のとき、解説だけを学習支援 AI（UFOくん API）に頼みます。問題が写っていなければ、もう一度見に行きます（最大 2 回）。
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
| 俯瞰カメラ ↔ XY | 宿題タブの校正（`config/calibration.json` の `camera_xy`） | 既存（#78）。4 点以上 |
| 高さ | `study_mode.height.real` | `z_desk_tip`（爪先が机に触れる Z）、`z_per_cm`（高さ 1 cm あたりの Z。既知の高さの台で測る）、`camera_offset_cm`（爪先からレンズまで）、`landing_tip_cm`。接触する着地は `allow_landing_contact` を実機で確かめてから。全部の `confirmed` を手で true にするまで実機の段階下降は拒否 |
| 片付け | `study_mode.cleanup.real` と `enabled_real` | ジグの保管位置・把持高さ・爪の開閉・経路・回収位置・禁止領域・速度・タイムアウト。`enabled_real` と全部の `confirmed` が要る |
| 前提 | — | `z_sign` / `z_counts_per_unit` / `arm_open_turns` は実機で未確認のまま |

## 7. 安全

- 実機では、HELP と片付けのアームを動かす前に**大人の Enter** が必要です（Mock の準備＝モーター ON・原点復帰も Enter）。
- カメラによる人の検出は安全の保証として扱いません。動作中は子どもの手が可動範囲に入らない運用にしてください。
- ジグの把持は自動で判定しません（センサーがない）。大人が Enter で確認し、`grip_confirm_timeout_s` で FAULT。
- 回収はクリップなど磁石につく安全なテスト用の物だけ。鉛筆や消しゴムは回収できません。磁石の誤飲・電子機器への接近に注意。
- 通信が切れたことの検知は、実機が止まったことの保証ではありません（ファームウェアにホストウォッチドッグはない）。

## 8. 学習支援 AI（UFOくん API、#104）

解説を、別の PC（Windows・RTX）で動く学習支援 AI に頼めます。答えを教えずに段階的なヒントを出し、目的の問題が写っていなければ、どちらにどれだけずれているかを返します。引き継ぎ資料と見本のコードは学習支援 AI 側の `integrations/corexy_ufo/`（`HANDOFF.md`、`PATCHES.md`）。

### つなぎ方

1. 学習支援 AI の PC で `uv run python server/tutor_app.py`（起動時に `https://<IP>:8444/` と許可する接続元を表示）。
2. この Mac に置く（**Git にもチャットにも出さない**。`config/secrets/` は Git に入らない）:
   - `config/secrets/tutor_token.txt`: トークン（1 行）
   - `config/secrets/tutor_cert.pem`: サーバの自己署名証明書（公開してよい方。`key.pem` は受け取らない）。この証明書だけを信頼し、IP で接続するのでホスト名は照合しない（検証そのものは切らない）
3. 設定画面（歯車 → 設定 → Study タブ）で「勉強モードの解説」を「学習支援 AI」、「学習支援 AI の URL」を `https://192.168.x.x:8444` にして保存し、`./start.sh` で起動し直す（`config/local_settings.json` の `study.explain_provider` / `study.tutor_url`）。
4. 接続テスト: `python3 tools/check_tutor_api.py`（URL・トークン・証明書は config から。TCP → TLS → 許可 IP → トークン → 推論 3 種の順に確かめ、だめなところで直し方を出す）。

`study.provider`（Claude Code / Codex）は今までどおり、アドバイス・問題の位置の判定（#79）・Study タブに使います。学習支援 AI のアダプタは解説の文（「子どもは問題 N で困っています」）しか読めないので、`provider` を `tutor` にはしません。

### 何を送るか

- 10cm の近接画像 1 枚と「N ばんが わからない」、学年（`tutor_grade`、プリントの学年が読めればそれ）。俯瞰・5cm・いちばん近くの画像は送りません。サーバは画像をディスクに保存しません。
- 子どものプリントには名前などが写ることがあります。実際の子どものプリントで評価データを集めるときは、保護者の同意と個人情報の除去が必要です。

### つながらないとき

ゲームも勉強モードも止まらず、アームも動かさず、プリントのヒントで解説します（今までの `fallback`）。2 回続けて失敗すると（`tutor_fail_limit`）、`tutor_cooldown_s`（120 秒）は呼ばずにすぐプリントのヒントにします。トークン・URL がないときも同じです。

### 写っていない問題を探しに行く

1. 学習支援 AI が `navigate {kind: "move", offset}`（画像の中心から目的の問題までのずれ。画像の幅・高さを 1000）を返す。
2. アダプタが先端カメラの校正（`config/calibration.json` の `focus_camera`）で mm に直す（`d_mm`）。**校正がなければ `d_mm` を付けない = アームは動かない**（AI の言葉だけ）。
3. ゲームは「あれっ、ここじゃないみたい。さがしに いくね！ 手を はなして まっててね。」と言い、**アームが前の撮影から戻り終わってから** `homework_navigate {u, v, camera, d_mm}` を送る。バックエンドは、前の撮影位置 + `d_mm` を全体カメラの u, v に直して返すだけ（**動かさない**）。1 回 60 mm を超える・3 mm 未満・可動範囲の外・全体カメラの校正が信用できる範囲の外は断る。実機では mm の目標は使わない。
4. いつもの段階撮影（`homework_approach`）をもう一度。実機では毎回、大人の Enter が要る（HELP と同じ）。
5. 最大 2 回（`MAX_NAV`）。見つからなければプリントのヒント。Space で止めると、もう探しに行かない。

`uncover`（手で隠れている）・`zoom_out` は、AI の言葉を話すだけでアームは動かしません。

### 先端カメラの校正（実機・高さごとに 1 回。未実施）

10cm の高さで先端カメラの画像を保存（`base.jpg`）→ 同じ高さのまま X に +10 mm 動かして `x10.jpg` → 戻して Y に +10 mm 動かして `y10.jpg`（紙や手を動かさない）。

```bash
cd backend && uv run python ../tools/calibrate_focus.py --height 10cm --base base.jpg --move x10.jpg 10 0 --move y10.jpg 0 10
```

`config/calibration.json` の `focus_camera` に保存されます。誤差（`residual_px`）が数 px 以内で、「1 mm あたり ○ px」がカメラの高さから見て妥当かを確かめます。

### 未確認（実機未検証）

- 実機・本物の API・先端カメラの校正での動作。確かめたのは、偽の API と Mock のロボット、ゲームの本物のプロンプト・パーサとの組み合わせだけ。
- 学習支援 AI の評価（学習に使っていない問題）: 番号で言われた問題を選ぶ 100%、位置で 74%、写っていない番号への対応 96%、問題の枠の位置 87%、**正誤判定は約 70%**（正しい答えを「まちがい」と言うことがある）。`needs_confirmation` と大人の確認の表示は残す。
