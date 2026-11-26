# 効果音（学習モード・スコアゲームのカプセルの登場とカウントダウン）

このフォルダの効果音は「効果音ラボ」のもの（`don` / `pico` / `jan` / `electronic-countdown1` は **演出・アニメ**、`magic-*` は **戦闘**、`info-girl1-countdown2` は **アプリ・音声案内（元気な女の子）** のページ）。

- 出典: https://soundeffect-lab.info/sound/anime/ 、https://soundeffect-lab.info/sound/battle/ 、https://soundeffect-lab.info/sound/voice/
- クレジット表記は不要。

| ファイル | 使っている場面（`game/scripts/study_mode/study_sounds.gd` の `OWN_FILES` と `CUES`） |
|---|---|
| `don.mp3` | 答え合わせで「せいかい」を出すとき、プリントを見つけたとき（ドン） |
| `pico.mp3` | 答え合わせで「せいかい」を出すとき、プリントを見つけたとき（ピコーン） |
| `jan.mp3` | ファンファーレ（ジャーン）: 答え合わせのあとの報酬の発表、ゲームの準備ができたとき |

スコアゲームのカプセルの登場（#266、「カプセル回収！」でアップになる瞬間。`game/scripts/game_mode/game_mode_sounds.gd` の `OWN_FILES`）:

| ファイル | 効果音名 | 使っている場面 |
|---|---|---|
| `magic-thunder1.mp3` | 雷魔法1 | ふつうのカプセル（`reveal`） |
| `magic-fire2.mp3` | 火炎魔法2 | ファイヤーボールカプセル（`reveal_fire`） |
| `magic-ice2.mp3` | 氷魔法2 | ウォーターボールカプセル（`reveal_water`） |
| `magic-wind1.mp3` | 風魔法1 | グリーンボールカプセル（`reveal_green`） |

ファイルが無いときは、ゲームが合成した音で代わりに鳴らす（止まらない）。

スコアゲームのカウントダウン（#325、`game_mode_sounds.gd` の `CUE_FILES`。画面の数字に合わせて途中から再生する。測った数字の位置は `docs/game_mode_spec.md` §3）:

| ファイル | 効果音名・ページ | 使っている場面 |
|---|---|---|
| `electronic-countdown1.mp3` | カウントダウン電子音（プッ、プッ、プッ、ピー）、演出・アニメ https://soundeffect-lab.info/sound/anime/ （対戦演出） | 開始のカウントダウン 3・2・1・GO!（`countdown_start`） |
| `info-girl1-countdown2.mp3` | 「10、9、8、7、6、5、4、3、2、1、0」、アプリ・音声案内（元気な女の子）https://soundeffect-lab.info/sound/voice/ （カウントダウン） | 残り 10 秒から TIME UP まで（`countdown_end`） |

この 2 つは無いとき、これまでの音（`count` / `go` / `warning`）で鳴らす。ファイル名はサイトのダウンロード名のまま。

## 規約の要点（`../SOURCES.md` と同じ）

- 利用規約（https://soundeffect-lab.info/agreement/ ）: 効果音ファイル**単体の**再配布・販売は禁止。効果音が主役のコンテンツも再配布と同じ扱い。
- FAQ（https://soundeffect-lab.info/faq/ ）: 効果音を組み込んだアプリを GitHub で公開するのは問題ない（再配布にあたらない）。ただし「できる限り音源ファイルを隠す措置を」とお願いされている。
- そのため、ゲームの一部としてリポジトリに入れている。**ここから素材として持ち出して、配布・転用しないこと。** 使いたい場合は効果音ラボから直接ダウンロードする。

別の音にするときは、効果音ラボからダウンロードしてこのフォルダに同じ名前で置き、この表を更新する。
