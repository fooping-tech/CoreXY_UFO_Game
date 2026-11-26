# 効果音（学習モード・スコアゲームのカプセルの登場）

このフォルダの効果音は「効果音ラボ」のもの（`don` / `pico` / `jan` は **演出・アニメ**、`magic-*` は **戦闘** のページ）。

- 出典: https://soundeffect-lab.info/sound/anime/ 、https://soundeffect-lab.info/sound/battle/
- クレジット表記は不要。

| ファイル | 使っている場面（`game/scripts/study_mode/study_sounds.gd` の `OWN_FILES` と `CUES`） |
|---|---|
| `don.mp3` | 答え合わせで「せいかい」を出すとき、プリントを見つけたとき（ドン） |
| `pico.mp3` | 答え合わせで「せいかい」を出すとき、プリントを見つけたとき（ピコーン） |
| `jan.mp3` | ファンファーレ（ジャーン）: 答え合わせのあとの報酬の発表、ゲームの準備ができたとき。スコアゲームの結果発表の FINAL SCORE（クラッカーが飛ぶ瞬間）と NEW RECORD!（`game_mode_sounds.gd` の `result_jan`、#328） |
| `cheer-applause1.mp3` | 歓声と拍手1: スコアゲームの NEW RECORD!（TOP10 に入ったとき。`cheer`、#328） |

スコアゲームのカプセルの登場（#266、「カプセル回収！」でアップになる瞬間。`game/scripts/game_mode/game_mode_sounds.gd` の `OWN_FILES`）:

| ファイル | 効果音名 | 使っている場面 |
|---|---|---|
| `magic-thunder1.mp3` | 雷魔法1 | ふつうのカプセル（`reveal`） |
| `magic-fire2.mp3` | 火炎魔法2 | ファイヤーボールカプセル（`reveal_fire`） |
| `magic-ice2.mp3` | 氷魔法2 | ウォーターボールカプセル（`reveal_water`） |
| `magic-wind1.mp3` | 風魔法1 | グリーンボールカプセル（`reveal_green`） |
| `magic-thunder1.mp3` | 雷魔法1 | サンダーボールカプセル（`reveal_thunder`、#320。ふつうと同じファイル） |
| `magic-dark.mp3` | 暗黒魔法 | ダークボールカプセル（`reveal_dark`、#320） |

ファイルが無いときは、ゲームが合成した音で代わりに鳴らす（止まらない）。

## 規約の要点（`../SOURCES.md` と同じ）

- 利用規約（https://soundeffect-lab.info/agreement/ ）: 効果音ファイル**単体の**再配布・販売は禁止。効果音が主役のコンテンツも再配布と同じ扱い。
- FAQ（https://soundeffect-lab.info/faq/ ）: 効果音を組み込んだアプリを GitHub で公開するのは問題ない（再配布にあたらない）。ただし「できる限り音源ファイルを隠す措置を」とお願いされている。
- そのため、ゲームの一部としてリポジトリに入れている。**ここから素材として持ち出して、配布・転用しないこと。** 使いたい場合は効果音ラボから直接ダウンロードする。

別の音にするときは、効果音ラボからダウンロードしてこのフォルダに同じ名前で置き、この表を更新する。
