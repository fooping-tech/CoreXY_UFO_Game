# BGM を置くフォルダ

ここに BGM の音源ファイル（`.ogg` / `.mp3` / `.wav`）を置く。

- **このフォルダの中身は Git に入らない。** 入るのはこの `README.md` と `.gitignore` だけ（Godot が作る `.import` も入らない）。
- ほかの PC では、同じファイルを自分でここに置く。
- ゲームがこのフォルダの次のファイルを鳴らす（#173、#181。ファイル名は `config/game_config.json` の `game_mode.sounds.bgm` で変えられる）:
  - `title.mp3` — トップメニュー（起動時のタイトル画面 = モードの選択）。元のファイル名 `iwashiro_pocket.mp3`（前は `top.wav`）
  - `Intro Jingle.wav` — トップメニューで種類を選んだときの効果音（1 回だけ。鳴り終わってから次の曲が始まる）
  - `intro.mp3` — スコアゲームのタイトル
  - `practice.mp3` — 練習（チュートリアル）の間。元のファイル名 `iwashiro_tuto_and_rial.mp3`（前は `tutorial.mp3`）
  - `game.wav` — ゲーム中（150 秒の時計が動いている間）
  - `ending.mp3` — ゲームが終わった後の結果発表（リザルトとランキング）
  - `study.mp3` — 勉強モードの間（#237。元のファイル名 `iwashiro_intelli_kun.mp3`）。`config/game_config.json` の `study_mode.bgm.study`
  - `study_check.mp3` — 勉強モードの答え合わせ（採点）が始まってから（元のファイル名 `iwashiro_daifugo_yusuri.mp3`）。`study_mode.bgm.check`。音量は `study_mode.bgm.gain_db`
- 設定画面の校正タブを開いている間は、どの曲も鳴らない。
- 曲はフェードしない（すぐ始まり、すぐ止まる）。声が話している間だけ小さくなる。
- 曲ごとの音量は `game_mode.sounds.bgm.gain_db` でそろえてある（-18 LUFS）。ファイルを替えたら `ffmpeg -i ファイル -af ebur128 -f null -` の最後に出る `I:`（LUFS）を見て、`gain_db = -18 - その値` にする。
- どれもループ再生。ファイルがない・読めないときは今までどおり（ゲーム中は合成の曲、メニューと結果発表は無音）で、エラーにはならない。起動時のログに `[bgm] menu: intro.mp3 (83 s, loops)` のように、使う音源が出る。
- 音量は設定画面の「音楽」（`audio.bgm_enabled` / `audio.bgm_volume_db`）。曲ごとの差は `game_mode.sounds.bgm.gain_db`。
- 置く音源の利用規約（再配布・展示での利用）は自分で確かめる。リポジトリに入れる効果音の出典は `../SOURCES.md` と `../manifest.json`。
