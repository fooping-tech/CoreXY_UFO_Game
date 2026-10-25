# 効果音の出典（ファイルはリポジトリに含めない）

効果音は「効果音ラボ」（https://soundeffect-lab.info ）のものを使う。
利用規約（https://soundeffect-lab.info/agreement/ ）で **素材ファイルそのものの再配布が禁止** されているため、
音声ファイルはこの公開リポジトリには入れない（`.gitignore` 済み）。ゲームへの組み込み利用は無料・クレジット不要。

## 置き方

下のページをブラウザで開き、各効果音をダウンロードして、このフォルダ（`game/assets/audio/`）に
**ファイル名を変えずに** 置く。ファイルがなければゲームは音なしで動く。

| 用途（設定キー） | 効果音名 | ページ | ファイル名 |
|---|---|---|---|
| 横移動（`audio.move`） | 魔法使いが空を飛ぶ | 戦闘 https://soundeffect-lab.info/sound/battle/ | `wizard-flight1.mp3` |
| UFO 上昇＝アーム下降（`audio.up`） | ステータス上昇魔法1 | 戦闘 https://soundeffect-lab.info/sound/battle/ | `magic-statusup1.mp3` |
| UFO 下降＝アーム上昇（`audio.down`） | ヒューン | 演出・アニメ https://soundeffect-lab.info/sound/anime/ | `hyun1.mp3` |

別の音にするときは、同じサイトから選んで `config/game_config.json` の `audio.move` / `audio.up` / `audio.down` を
ファイル名に変える（この表も更新する）。音量は `audio.volume_db`、デバッグパネルの「Sound volume dB」。
