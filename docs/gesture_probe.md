# ジェスチャー認識の記録と切り分け（#256）

ハンドジェスチャーがうまく認識されないとき、原因はおおきく 2 つに分かれる。

- **手を見失っている**: MediaPipe が手を見つけられない、または追いかけられない（`reason` が `no_hand` など）。
- **手は見えているのに、形の判定で外れている**: 手の 21 点は取れているが、ゲームのルール（指先が第 2 関節より手首に近ければ「折れている」）で別の形になる。

`tools/gesture_probe.py` は、ゲームと同じ設定（`config/game_config.json` の `gesture` と、手元の `local_settings.json`）でカメラだけを使い、フレームごとの判定を記録する。ロボットにもゲームにも何も送らない。

## 準備

- ゲーム（`./start.sh`）を止める。カメラの取り合いを避けるため。
- backend に OpenCV と MediaPipe が入っていること（`cd backend && uv sync --extra vision --extra hands`）。

## 1. 記録する（record）

```bash
cd backend
uv run python ../tools/gesture_probe.py record
```

ウィンドウにカメラの映像（ゲームと同じ向きに反転）、手の点、今の判定が出る。**今どの手を出しているか（正解）** をキーで付ける。

| キー | 正解 |
|---|---|
| 1 | パー |
| 2 | グー |
| 3 | ピンチ（つまんで動かす） |
| 0 | 手を出していない |
| Space | 正解なし（集計に入れない） |
| q / Esc | 終わる |

上の 2 行目の文字は、判定が正解と合っていれば緑、外れていれば赤になる。

おすすめの撮り方（1 回 2〜3 分）:

1. **ピンチ**: 3 を押し、いつもの操作のようにつまんだまま手を動かす（速く・遅く）。20〜30 秒。
2. **パー**: 1 を押し、パーを見せる。向きや高さを少しずつ変える。15 秒。
3. **グー（パーから）**: 1 でパーを見せてから 2 を押してグーにする。5 回ほど。
4. **グー（いきなり）**: 0 を押して手を画面の外へ出し、2 を押してから**グーのまま**画面に入れる。5 回ほど。
5. 終わったら q。

保存先は `logs/gesture_probe/<日時>/`（Git に入らない）。

- `probe.jsonl`: フレームごとの記録（正解、`reason`、判定された形、ピンチ、指ごとの値、手の 21 点と 3D 座標）
- `video.avi`: 元の映像（手と部屋が写る。共有しない）

終わると集計がそのまま表示される。

## 2. 集計する（analyze）

```bash
uv run python ../tools/gesture_probe.py analyze ../logs/gesture_probe/<日時>
```

正解ごとに次を出す。

- 手が 1 つ見えた割合と `reason` の内訳（`no_hand` = 見えていない、`held_*` = 見失ったが直前の手を保持中、`multiple_hands` = 手が 2 つ）
- ゲームの形の判定（2D）の内訳。参考として、3D 座標で指の曲がり（度）を測って同じルールで判定した結果
- 見失いの回数と長さ（`lost_grace_ms` 以上は操作が止まる）
- ピンチ: ピンチが切れた理由（`shape:fist` などは「その 1 フレームがグー・いいね・チョキと判定されてピンチが切れた」、`lost:*` は見失い、`opened` は指を開いた）
- パー・グー: 正解の形にならなかったフレームで、どの指が邪魔をしたか
- グー: 「直前から手を追跡していた区間」と「手が見えていない状態から始めた区間」で、見えた割合と最初に見えるまでの時間を分けて出す
- 手の大きさ（px）、明るさ、くっきり度（小さいほどぶれている）、処理時間

## 3. 設定を変えて比べる（replay）

保存した映像を、設定を変えて判定し直す。同じ手の動きで比べられる。

```bash
uv run python ../tools/gesture_probe.py replay ../logs/gesture_probe/<日時>                       # 基準（変えない）
uv run python ../tools/gesture_probe.py replay ../logs/gesture_probe/<日時> --detection-confidence 0.3
uv run python ../tools/gesture_probe.py replay ../logs/gesture_probe/<日時> --crop 0.2,0.1,0.8,0.9
```

変えられるもの: `--detection-confidence`、`--tracking-confidence`、`--delegate cpu|gpu`、`--crop x0,y0,x1,y1`（0..1 の範囲だけを MediaPipe に渡す。手が大きく写る）、`--pinch-start`、`--pinch-release`、`--lost-grace-ms`。

映像は圧縮して保存しているので、比べるときは記録したときの結果ではなく、**変えない replay（`replay-base.jsonl`）** を基準にする。基準があれば、主な数字（見えた割合・正しく判定された割合・操作が止まる見失い）を並べて表示する。

## 注意

- 記録中の処理時間はゲームを動かしていないときの値。ゲームと同時に動くときは CPU / GPU を取り合うので遅くなる。
- 3D の判定（`pose3d`）は比較の参考で、ゲームの判定は変えていない。
- ゲームの判定のほかに、ゲーム側にも保持時間（`claw_hold_ms`、`pose_confirm_ms`）と鮮度（`stale_ms`）の確認がある。このツールが見るのはバックエンドの判定まで。
