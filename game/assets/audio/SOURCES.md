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
| 横移動（`audio.move`） | 魔法使いが空を飛ぶ | 戦闘 https://soundeffect-lab.info/sound/battle/ | `wizard-flight1.mp3` |
| UFO 上昇＝アーム下降（`audio.up`） | ステータス上昇魔法1 | 戦闘 https://soundeffect-lab.info/sound/battle/ | `magic-statusup1.mp3` |
| UFO 下降＝アーム上昇（`audio.down`） | ヒューン | 演出・アニメ https://soundeffect-lab.info/sound/anime/ | `hyun1.mp3` |
| 手のジョイスティック: パー（開いた手）が見えた（`audio.cue_hand`、#321） | 決定ボタンを押す1 | ボタン・システム音 https://soundeffect-lab.info/sound/button/ | `decide-button1.mp3` |
| 手のジョイスティック: つまんだ（`audio.cue_pinch`、#321） | 決定ボタンを押す3 | ボタン・システム音 https://soundeffect-lab.info/sound/button/ | `decide-button3.mp3` |

別の音にするときは、同じサイトからダウンロードしてこのフォルダに置き、`config/game_config.json` の
`audio.move` / `audio.up` / `audio.down` をそのファイル名に変える（この表も更新する）。ファイルが無ければゲームは音なしで動く。
音量は `audio.volume_db`、デバッグパネルの「Sound volume dB」。

手のジョイスティックの音（`audio.cue_hand` / `audio.cue_pinch`）は `game/scripts/ui/sfx.gd` の `play_cue` で鳴る。同じ音は爪を閉じるとき（`pinch`）や
かんたんモードのキャッチ（`hand` / `pinch`）でも使っている。ファイルごとの音量は `audio.cue_gain_db`（`tools/audio_levels.py` で測って合わせる）。
ファイルが無いときは、ゲームが合成した「ピッ」という音で鳴る。

## 学習モードの効果音（`se/`）

`se/` の `don.mp3`・`pico.mp3`・`jan.mp3` も効果音ラボ（演出・アニメ https://soundeffect-lab.info/sound/anime/ ）のもの。スコアゲームのカプセルの登場音 `magic-*.mp3`（#266）も同じ `se/` にある効果音ラボ（戦闘 https://soundeffect-lab.info/sound/battle/ ）のもの。使っている場面と規約は `se/README.md`。

## スコアゲームの音（`sfx/`）は別

`sfx/` の OGG は Kenney（kenney.nl）の CC0 の音源で、上の効果音ラボの規約とは関係がない（制限なく使える）。出典は `manifest.json`、`licenses/kenney_cc0.md`、`docs/audio_sources.md`。
