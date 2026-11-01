---
name: pixelfx-vfx
description: CoreXY_UFO_Game にピクセルアートの VFX（pixelfx 製スプライトシート）を追加・差し替え・調整するときの手順。pixelfx からの生成（tools/build_vfx.py とカタログ）、絵の確認、VFXManager.spawn_fx の使い方、ゲームの場面（GameState）との結び付け、デバッグパネルの VFX タブ、テスト、ライセンス。例:「掴んだときのエフェクトを変えて」「新しい演出を足して」「VFX が UFO に重なる」「pixelfx の別のエフェクトを使いたい」。corexy-ufo-game スキルの設計原則（演出は実機に触れない等）の上で使う。
---

# pixelfx VFX — CoreXY UFO Game

画面の演出用ピクセル VFX を、[pixelfx](https://github.com/patch-gg/pixelfx)（MIT）で**事前に**スプライトシートへ焼き、Godot は PNG と JSON だけを読む。Node は生成時だけ。pixelfx 本体はリポジトリに入れない。

まず `corexy-ufo-game` スキルを読むこと（演出は `RobotState` を書かない・実機コマンドを出さない・ロープや UFO の座標を動かさない）。

## 1. 構成

| もの | 場所 | 役割 |
|---|---|---|
| カタログ | `game/assets/vfx/catalog.json` | 使う VFX の一覧。id → pixelfx の `source`、`opts`（`palette` など）、既定の `scale` / `layer` / `alpha` / `loop` |
| シート | `game/assets/vfx/<id>.png` / `.json` | 生成物。JSON は Aseprite 形式＋ `meta.pixelfx`（fps、loop、frames、frameSize、pivot、columns） |
| 生成ツール | `tools/build_vfx.py` | カタログを読み、pixelfx の `tools/render.mjs <source> --sheet --no-actor --opts` を実行してコピー |
| ライセンス | `game/assets/vfx/LICENSE-pixelfx.txt` | pixelfx の MIT と NOTICE の写し。版を上げたら更新 |
| マネージャー | `game/scripts/vfx/vfx_manager.gd`（Autoload `VFXManager`） | シートから SpriteFrames を作り（id×loop ごとに 1 回、共有）、AnimatedSprite2D で再生 |
| 演出の割り当て | `game/scripts/vfx/vfx_director.gd`（`main.vfx`） | GameState の状態とイベント → どの VFX を出すか |
| デバッグ | デバッグパネルの「VFX」タブ（`debug_ui.gd::_build_vfx`） | 一覧・再生・速度・拡大・位置・ループ・場面の模擬・ON/OFF |

## 2. API

```gdscript
VFXManager.spawn_fx("grab_burst", position, {
	"scale": 2.0,          # 画面ピクセル / pixelfx ピクセル（既定はカタログ）
	"speed": 1.0,          # 再生速度
	"loop": false,         # シートの loop を上書き
	"alpha": 1.0, "color": Color.WHITE,   # 色は掛け算
	"layer": "front",      # "back" = UFO とロープの後ろ（z -1）、"front" = 一番手前（z 6）
	"flip_h": false,
	"duration": 0.0,       # 秒。ループを時間で止める
	"follow": node, "offset": Vector2(), # node の位置に毎フレーム追従（追従中だけ _process が動く）
}) # -> AnimatedSprite2D（無効・未知の id は null）
VFXManager.stop_fx(sprite); VFXManager.stop_all(); VFXManager.enabled = false
```

- シートの pivot が `position` に来る（`offset = frameSize/2 - pivot`）。
- 一発物は `animation_finished` で自動解放。ループは `stop_fx` / `duration` / 追従先が消えたときに解放。
- フレームごとの duration は JSON の値を fps 基準の相対値にする（JSON は ms の整数に丸めてあるので、1 ms 以内は 1 フレームとみなす）。
- VFX はメインシーンの子（`VFXManager.layer = main`）なので画面揺れと一緒に動く。カメラ映像やジェスチャーの処理には関わらない。

## 3. 場面との結び付け（vfx_director.gd）

| 場面 | きっかけ | VFX |
|---|---|---|
| ゲーム開始 | `READY` に DISCONNECTED / HOMING / BOOT から | `start_countdown`（プレイ画面中央）＋ `start_energy`（UFO） |
| 待機 | `READY` の間 | `idle_glow`（ループ、UFO に追従） |
| 移動 | `MOVING` | 追加しない（UFO 自身の粒子 `ufo_fx.gd` がある。矢印押しっぱなしで演出過多と言われた経緯） |
| 下降 | `LOWERING` の間 | `lower_charge`（ループ、追従） |
| 掴んだ | `GRABBING` か `claw_closed` イベント（爪を閉じる命令の **ACK** で main が出す。モックは即時） | `grab_burst` |
| 成功 | `RESULT` かつ `result_success`（`result_success` / `prize_detected` イベントだけ。推定で成功にしない） | `success_confetti` ＋ `success_sparkle` |
| 失敗 | `RESULT` かつ失敗 | `fail_poof`（UFO の下。顔を隠さない） |
| ラウンド終了 | `RESULT` を抜けたとき | `end_fade` |

守ること:
- 状態は GameState から取る（GameState は実機の報告に従う）。演出側で状態を推定しない。
- ループは状態ごとに 1 枠。同じ状態に入り直しても積み重ねない。
- 一発物は場面ごとに `COOLDOWN_S`（1.5 秒）。通信の揺れや重複イベントで多重に出さない。
- UFO を隠さない: 大きいものは後ろ（back）、手前（front）は一瞬の小さいものだけ。位置は UFO スプライトのピクセル単位（`× pixel_scale`）で、本体の中心（UFO ノードから下へ 27 px）基準。

## 4. エフェクトを足す・変える

1. pixelfx を**リポジトリの外**に取得する: `git clone https://github.com/patch-gg/pixelfx <dir>`。版はカタログの `pixelfx.version` に合わせる（違うと build_vfx.py が止まる）。
2. 候補を見る: `node tools/render.mjs <category/name> --sheet --no-actor --out <tmp>`。**contact.png は見本のキャラクター込み**なので、判断は生成された PNG のフレームで行う。
3. 使えないもの（実際に当たった例）:
   - 物や体を描くもの: `pickups/key-glint`（鍵）、`scifi/tractor-beam`（自前の UFO）、`scifi/energy-core`（ガラスの容器）
   - キャラクターの体に描くもの（シートに人の輪郭が残る）: `scifi/warp-out`、`holy/blessing`（人型の光の柱）
   - 大きすぎるもの: `weather/fireflies`（320×180 × 360 フレーム = 4800×4320 のシート）
4. 色は青・シアン系が基本。`opts.palette` に暗→明のランプを渡す（例 `["#03101c","#072a40","#0b4a68","#127396","#1fa3c4","#4fd0ec","#a8f2ff","#ffffff"]`）。成功の紙吹雪だけは楽しさ優先で多色。
5. `catalog.json` に足す → `python3 tools/build_vfx.py --pixelfx <dir> [id ...]` → `godot --headless --path game --import`（`.import` もコミットする）。
6. 場面に結び付けるなら `vfx_director.gd` の `play()` / `LOOPS` と、デバッグタブの名前（`_build_vfx` の `names`）を更新。
7. 実際の画面で確かめる（下記）。headless では描画は分からない。

## 5. 確認とテスト

- 自動テスト（`game/tests/run_tests.gd`）: `_test_vfx_manager`（全シートの読み込み・フレーム数・fps・pivot・オプション・自動解放・追従・無効化）、`_test_vfx_follows_the_game`（場面 → VFX、重複イベント 1 回、成功は結果イベントのみ、無効でも進む）。
- 目視: デバッグパネル（F1）の「VFX」タブで各エフェクトと場面を再生する。スクリーンショットが要るときは、一時的なシーンで `main.vfx.play(<moment>, 3.0, true)` を呼んで `get_viewport().get_texture().get_image().save_png()`（窓ありで起動。終わったら一時ファイルを消す）。
- `config/game_config.json` の `render.vfx`（false で全 VFX 無効。ゲームはそのまま動く）。
