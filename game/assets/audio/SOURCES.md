# 効果音の出典

効果音は「効果音ラボ」（https://soundeffect-lab.info ）のもの。ゲームの操作音として組み込んで使っている。
クレジット表記は不要。

## 規約の要点

- 利用規約（https://soundeffect-lab.info/agreement/ ）: 効果音ファイル**単体の**再配布・販売は禁止。
  効果音が主役のコンテンツ（効果音を自由に鳴らせるアプリなど）も再配布と同じ扱い。
- FAQ（https://soundeffect-lab.info/faq/ ）: 効果音を組み込んだアプリを GitHub で公開するのは、
  音源ファイルがむき出しでも問題ない（再配布にあたらない）。ただし「できる限り音源ファイルを隠す措置を」とお願いされている。
- そのため、このフォルダの mp3 はゲームの一部としてリポジトリに入れている。
  **ここから素材として持ち出して、配布・転用しないこと。** 使いたい場合は効果音ラボから直接ダウンロードする。

## ファイル

| 用途（設定キー） | 効果音名 | ページ | ファイル名 |
|---|---|---|---|
| アームの上下（Z。上げ・下げとも。`audio.motion_z`） | メニューを開く2（ブォン。重低音） | ボタン・システム音[1] https://soundeffect-lab.info/sound/button/ （配布ファイル `mp3/menu2.mp3`） | `menu2.mp3` |
| XY の移動（`audio.motion_xy`） | メニューを開く3（ブォン。サイバー感強め） | ボタン・システム音[1] https://soundeffect-lab.info/sound/button/ （配布ファイル `mp3/menu3.mp3`） | `menu3.mp3` |
| 手のジョイスティック: パー（開いた手）が見えた（`audio.cue_hand`、#321） | 決定ボタンを押す1 | ボタン・システム音 https://soundeffect-lab.info/sound/button/ | `decide-button1.mp3` |
| 手のジョイスティック: つまんだ（`audio.cue_pinch`、#321） | 決定ボタンを押す3 | ボタン・システム音 https://soundeffect-lab.info/sound/button/ | `decide-button3.mp3` |
| 手のジョイスティック: つまんだあとパーに戻した（指を開いて操縦をやめた。`audio.cue_release`、#332） | キャンセル4（ヒュッ） | ボタン・システム音[1] https://soundeffect-lab.info/sound/button/ （配布ファイル `mp3/cancel4.mp3`） | `cancel4.mp3` |
| かんたんモード: グーで自動キャッチ（「じどうキャッチ！」。練習のグーのステップも。`audio.cue_catch`、#332） | 決定ボタンを押す23（控え目な決定音） | ボタン・システム音[1] https://soundeffect-lab.info/sound/button/ （配布ファイル `mp3/decision23.mp3`） | `decision23.mp3` |

#327: メニューを開く2 / 3 はページの配布ファイルとバイト単位で同じことを確認した（2026-11-26、SHA-1 一致）。

鳴らし方（`game/scripts/ui/sfx.gd`）: 動き始めにすぐ 1 回、動いている間は 1 秒ごとに 1 回。Z と XY が同時に動くときは Z の音だけ。
止まったら（0.2 秒続けて止まっていたら）鳴っている途中の音を 0.3 秒でフェードして消す。音量はそれぞれ `Sfx.VOICE_GAIN_DB`
（`tools/audio_levels.py` で測って、1 秒ごとに繰り返すので普通の効果音より少し小さい約 -27 にそろえた）。

別の音にするときは、同じサイトからダウンロードしてこのフォルダに置き、`config/game_config.json` の
`audio.motion_z` / `audio.motion_xy` をそのファイル名に変える（この表も更新する）。ファイルが無ければゲームは音なしで動く。
音量は `audio.volume_db`、デバッグパネルの「Sound volume dB」。

手のジョイスティックの音（`audio.cue_hand` / `audio.cue_pinch` / `audio.cue_release`）とかんたんモードのグーの音（`audio.cue_catch`）は
`game/scripts/ui/sfx.gd` の `play_cue` で鳴る。同じ音は爪を閉じるとき（`pinch`）、かんたんモードのつかんだ合図・運ぶ合図（`hand` / `pinch`）、
手で爪を開くとき・かんたんモードの運び終わり・キャッチのやめ（`release`）でも使っている。ファイルごとの音量は `audio.cue_gain_db`
（`tools/audio_levels.py` で測って合わせる。#332: キャンセル4 -25.3、決定ボタンを押す23 -23.9 LUFS（瞬間最大）→ どちらも +8 dB で
volume_db -8 のとき約 -25 / -24）。

#332 の 2 つ（キャンセル4・決定ボタンを押す23）はユーザーが効果音ラボからダウンロードしたファイル。ページ（ボタン・システム音[1]）に
同じ名前で載っていることと配布ファイル名は確認した（2026-11-26）。サイトがスクリプトからのダウンロードを断る（403）ため、
バイト単位の照合はしていない。
ファイルが無いときは、ゲームが合成した「ピッ」という音で鳴る。

## 学習モードの効果音（`se/`）

`se/` の `don.mp3`・`pico.mp3`・`jan.mp3` も効果音ラボ（演出・アニメ https://soundeffect-lab.info/sound/anime/ ）のもの。スコアゲームのカプセルの登場音 `magic-*.mp3`（#266。`magic-dark.mp3` = 暗黒魔法は #320）も同じ `se/` にある効果音ラボ（戦闘 https://soundeffect-lab.info/sound/battle/ ）のもの。スコアゲームのカウントダウン（#325）の `electronic-countdown1.mp3`（演出・アニメ）と `info-girl1-countdown2.mp3`（アプリ・音声案内 https://soundeffect-lab.info/sound/voice/ ）も同じ。NEW RECORD! の歓声 `cheer-applause1.mp3`（効果音ラボ「歓声と拍手1」、人の声 https://soundeffect-lab.info/sound/voice/people.html 、#328）も `se/` にある。使っている場面と規約は `se/README.md`。

## スコアゲームの音（`sfx/`）は別

`sfx/` の OGG は Kenney（kenney.nl）の CC0 の音源で、上の効果音ラボの規約とは関係がない（制限なく使える）。出典は `manifest.json`、`licenses/kenney_cc0.md`、`docs/audio_sources.md`。
