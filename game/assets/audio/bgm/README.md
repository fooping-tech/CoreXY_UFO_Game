# BGM を置くフォルダ

ここに BGM の音源ファイル（`.ogg` / `.mp3` / `.wav`）を置く。

- **このフォルダの中身は Git に入らない。** 入るのはこの `README.md` と `.gitignore` だけ（Godot が作る `.import` も入らない）。
- ほかの PC では、同じファイルを自分でここに置く。
- スコアゲームがこのフォルダの次の 3 つを BGM として鳴らす（#173。ファイル名は `config/game_config.json` の `game_mode.sounds.bgm` で変えられる）:
  - `intro.mp3` — メニュー表示中（起動時のタイトル画面、スコアゲームのタイトル）
  - `game.wav` — ゲーム中（150 秒の時計が動いている間）
  - `ending.mp3` — ゲームが終わった後の結果発表（リザルトとランキング）
- どれもループ再生。ファイルがない・読めないときは今までどおり（ゲーム中は合成の曲、メニューと結果発表は無音）で、エラーにはならない。起動時のログに `[bgm] menu: intro.mp3 (83 s, loops)` のように、使う音源が出る。
- 音量は設定画面の「音楽」（`audio.bgm_enabled` / `audio.bgm_volume_db`）。曲ごとの差は `game_mode.sounds.bgm.gain_db`。
- 置く音源の利用規約（再配布・展示での利用）は自分で確かめる。リポジトリに入れる効果音の出典は `../SOURCES.md` と `../manifest.json`。
