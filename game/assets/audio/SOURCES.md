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

別の音にするときは、同じサイトからダウンロードしてこのフォルダに置き、`config/game_config.json` の
`audio.move` / `audio.up` / `audio.down` をそのファイル名に変える（この表も更新する）。ファイルが無ければゲームは音なしで動く。
音量は `audio.volume_db`、デバッグパネルの「Sound volume dB」。
