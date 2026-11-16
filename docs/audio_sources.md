# 音源の出典と権利（スコアゲーム、#143）

スコアゲーム（SUMMON THE UFO）の効果音とジングルの出典、ライセンス、選んだ理由、確認できたこと・できていないことの記録。ファイルごとの正確な情報（SHA-256 を含む）の正本は `game/assets/audio/manifest.json`。

## まとめ

- 採用した音源ファイルは **27 個、すべて Kenney（https://kenney.nl ）、ライセンスは CC0 1.0**。クレジット表記は不要で、ゲームへの同梱と公開リポジトリへの収録ができる。
- ファイルは変更していない（形式は配布のままの OGG、名前も元のまま）。合計 約 280 KB。
- **聴感は未検証**。この作業環境では音を聴けないので、ファイル名・長さ・音量（ピークと平均）で選んだ。実際に聴いて合わない音は、`manifest.json` の `file` を差し替えれば変えられる。
- 音楽（BGM）は、確認できる CC0 のループ音源を入手できなかったので、**ゲーム内で合成する曲のまま**にした（下の「採用しなかったもの」）。残り 30 秒用は、同じ曲の速度を上げるのではなく、ベースと拍を足した別のテイクを合成している。

## 入手と確認の方法

| 項目 | 内容 |
|---|---|
| ライセンスの確認 | 各パックの配布ページ（kenney.nl）を 2026-11-16 に読み、4 パックとも「Creative Commons CC0」と書かれていることを確認 |
| 入手元 | GitHub の索引リポジトリ https://github.com/Mcamento8/open-game-sfx-index （Kenney の CC0 パックをファイル単位で置いている）。コミット `34bbe8b525b5ceff3804915ea745532af11f6055` から、選んだファイルだけを 1 個ずつ取得。パックの一括収録はしていない |
| 取得日 | 2026-11-16 |
| **確認できていないこと** | Kenney の配布ページの zip は、この環境からは取得できなかった（自動のクライアントは 403）。そのため、**索引リポジトリのファイルが配布元の zip の中身とバイト単位で同じであることは照合していない**。ファイル名とパックの構成は配布ページの記載（ファイル数）と合っている |
| 中身の確認 | 全ファイルを ffprobe / ffmpeg で読み、OGG Vorbis・44.1 kHz・長さ 0.02〜1.8 秒・ピーク −5.7〜0.0 dB であることを確認 |

## 採用した音

`key` は `GameModeSounds.play()` に渡す名前。音量の差は `manifest.json` の `gain_db` で整えている。

| key | 場面 | ファイル（`game/assets/audio/`） | Kenney のパック | 長さ（秒） |
|---|---|---|---|---|
| `pin` | ピンに当たる（軽いクリック） | `sfx/tick_002.ogg` | interface-sounds | 0.023 |
| `bumper` | バンパー（弾む電子音） | `sfx/pepSound3.ogg` | digital-audio | 0.444 |
| `pop` | 小バンパー | `sfx/pepSound1.ogg` | digital-audio | 0.522 |
| `spinner` | 回転ギミック | `sfx/phaseJump1.ogg` | digital-audio | 0.47 |
| `switch` | スイッチ（2 音） | `sfx/twoTone1.ogg` | digital-audio | 0.724 |
| `target` | 壁のターゲット | `sfx/tone1.ogg` | digital-audio | 0.661 |
| `sling` | スリングショット（弾く音） | `sfx/pluck_001.ogg` | interface-sounds | 0.102 |
| `gem` | 宝石（ガラスの音） | `sfx/glass_001.ogg` | interface-sounds | 0.278 |
| `alien` | 宇宙人をつかまえる | `sfx/zapThreeToneUp.ogg` | digital-audio | 1.202 |
| `warp` | ワープホールに入る | `sfx/phaserUp4.ogg` | digital-audio | 0.366 |
| `star` | スター（獲得音） | `sfx/powerUp3.ogg` | digital-audio | 1.149 |
| `bonus` | 3 連スイッチのボーナス | `sfx/jingles_NES05.ogg` | music-jingles | 0.906 |
| `jackpot` | ジャックポット（ファンファーレ） | `sfx/jingles_NES00.ogg` | music-jingles | 1.758 |
| `goal` | ゴール | `sfx/confirmation_002.ogg` | interface-sounds | 0.539 |
| `combo` | コンボの段が上がる（段ごとに高くなる） | `sfx/highUp.ogg` | digital-audio | 0.549 |
| `absorb` | Dial が受け取り、吸い込む（上昇スイープ） | `sfx/phaserUp1.ogg` | digital-audio | 0.496 |
| `drop` | UFO から落とす（実体化） | `sfx/phaserDown1.ogg` | digital-audio | 0.47 |
| `return` | カプセルが戻る（戻るワープ） | `sfx/phaserDown3.ogg` | digital-audio | 0.496 |
| `release` | 排出の開始（機械の音） | `sfx/doorOpen_000.ogg` | sci-fi-sounds | 0.532 |
| `count` | カウントダウン 3-2-1 | `sfx/bong_001.ogg` | interface-sounds | 0.123 |
| `go` | GO!（開始のジングル） | `sfx/jingles_NES03.ogg` | music-jingles | 0.604 |
| `hurry` | 残り 30 秒 | `sfx/lowThreeTone.ogg` | digital-audio | 1.019 |
| `warning` | 残り 10 秒の毎秒（控えめ） | `sfx/highDown.ogg` | digital-audio | 0.522 |
| `timeup` | TIME UP | `sfx/jingles_NES08.ogg` | music-jingles | 0.621 |
| `result` | 結果のジングル | `sfx/jingles_NES13.ogg` | music-jingles | 1.048 |
| `fault` | Dial の異常（騒がしくない） | `sfx/error_006.ogg` | interface-sounds | 0.5 |
| `stop` | 停止 | `sfx/lowDown.ogg` | digital-audio | 0.784 |

パックのページ: Interface Sounds https://kenney.nl/assets/interface-sounds 、Digital Audio https://kenney.nl/assets/digital-audio 、Sci-fi Sounds https://kenney.nl/assets/sci-fi-sounds 、Music Jingles https://kenney.nl/assets/music-jingles

選び方: レトロなアーケードに合う Digital Audio を中心にした。当たる音は短い電子音、取り込みは上がるスイープ（phaserUp）、戻りは下がるスイープ（phaserDown）、開始・TIME UP・結果・ボーナス・ジャックポットは Music Jingles の 8bit 調（NES）のジングル、異常は Interface Sounds の控えめなエラー音。

## 採用しなかったもの

| 候補 | 理由 |
|---|---|
| Meta Open Sound / Oculus Audio Pack（https://github.com/facebookincubator/Meta-open-sound ） | Oculus Audio Pack は CC BY 4.0 でクレジット表記が要る。Kenney の CC0 で必要な音がそろったので使っていない |
| OpenGameArt の CC0 パック（索引リポジトリの `oga-*`） | OpenGameArt のページがこの環境から読めず（403）、ライセンスを配布元で確認できなかった |
| SubspaceAudio「5 Chiptunes (Action)」（8bit のループ BGM、https://opengameart.org/content/5-chiptunes-action ） | カタログ（TMHSDigital/Free-Game-Dev-Assets）には CC0 とあるが、配布元の OpenGameArt のページを読めず、ファイルも取得できなかった。**確認できないものは入れない** |
| Tallbeard「Abstraction Music Loop Bundle」（長いループ BGM） | 配布が itch.io で、この環境から取得できなかった。ライセンスも配布元で確認できていない |
| eturner58/game-assets | 索引だけで音源の実体の権利表記がなく、内容は同じ Kenney のパック |
| Kenney のパックの一括収録 | Issue の方針どおり、使うファイルだけにした |

BGM を実音源にするときは、人が配布元からダウンロードしてライセンスを確かめ、`game/assets/audio/bgm/` に OGG で置き、この文書に追記する（再生側は `GameModeSounds` の `_bgm` / `_bgm_fast` のストリームを差し替える）。

## 既存の音との関係

- 通常ゲームの移動音（`game/assets/audio/*.mp3`、効果音ラボ）は別の規約で、今回は変更していない。`game/assets/audio/SOURCES.md` を参照。**効果音ラボの mp3 は素材として持ち出せない**が、`sfx/` の Kenney の音は CC0 なので制限はない。
- スコアゲームの合成音は消していない。ファイルがない・読めないときと、`game_mode.sounds.files: false` のときに使う。
- 勉強モードの合成音と VOICEVOX の声は変更していない。声は `Voice` バスに流すようにした（声が出ている間、スコアゲームの音楽を 10 dB 下げる）。

## 再生の仕組み（`GameModeSounds` / `AudioBuses`）

| 項目 | 内容 |
|---|---|
| バス | `SFX`（効果音）、`SFX Left` / `SFX Right`（左右の Dial の音。`SFX` へ）、`BGM`、`Voice`。起動時にコードで作る |
| 音量・ミュート | `audio.volume_db`（効果音の基準）、`audio.sfx_volume_db` / `audio.bgm_volume_db`（バス）、`audio.sfx_enabled` / `audio.bgm_enabled`、`audio.enabled`（全部）。設定画面の「画面と音」に音楽のオン・オフと大きさ |
| 左右 | 取り込み・投下・戻り・排出・異常の音は、その Dial の側へ寄せる（`game_mode.sounds.pan`、既定 0.6）。ほかは中央 |
| 同時発音 | 8 個。全部鳴っているとき、優先度 0（ピン・スリングショット）は鳴らさず、高い優先度の音はいちばん優先度の低い音を止めて鳴る |
| 連打の抑制 | 同じ音は `min_gap_ms` に 1 回（ピン 60 ms、バンパー 40 ms など） |
| ピッチ | 当たる音に ±4〜8 % のゆらぎ。コンボの音は段が上がるほど高い |
| 停止 | `stop` の音は、鳴っている効果音を全部止めてから鳴る。音楽はフェードで消える |
| 音楽 | 開始でフェードイン、残り 30 秒で別テイクへクロスフェード、TIME UP・停止・タイトルへ戻るときフェードアウト（0.6 秒） |

音は表示と同じ「演出」で、得点・時計・物理・機器の状態機械・排出・安全の条件に使っていない。音の再生の完了を待つ処理もない。
