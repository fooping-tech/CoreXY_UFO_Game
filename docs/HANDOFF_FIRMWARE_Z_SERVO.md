# ファームウェア担当エージェントへのハンドオフ（3）— サーボだけ電源が切れたあとの JOG

作成日: 2026-11-08
対象: `CoreXY_UFO`（M5Stack Core2 ファームウェア）リポジトリを担当するエージェント
送り元: `CoreXY_UFO_Game`（https://github.com/fooping-tech/CoreXY_UFO_Game）Issue #62
前提資料: [HANDOFF_FIRMWARE_JOG.md](HANDOFF_FIRMWARE_JOG.md)（シリアル JOG の依頼）、[firmware_protocol.md](firmware_protocol.md)
調査したファームウェア: `../CoreXY_UFO` HEAD `bf70657`

> **状況（2026-11-08）:** ファームウェア側 Issue #11 で対応済み。§3.1 は (a) を採用（`tracking=RESET`）、§3.2 は `SERVO_STATUS` の `tracking=LOST`。ゲーム側は Issue #64 で対応した（LOST の検知、LOST なら Z の JOG を拒否しない、RESET で Z の記録点・爪の基準を捨てる）。応答行は [firmware_protocol.md](firmware_protocol.md) §2。

## 1. 依頼の要点

運用では、**STS3020 サーボ（特に巻き上げの ID 1）だけ電源が切れる（切る）ことがある**。M5 は動き続けるため、ファームウェアは「多回転で追跡中」（`Track::valid = true`）のままになる。ところがサーボ側は角度の制限が電源投入時の値（`MIN=0 / MAX=4095`、1 回転）に戻っている。

この状態で JOG（シリアル `JOG` とジョイスティックの両方）を始めると、**何も動かず、エラーも出ない**。サーボは 1 回転分の端（0 か 4095）で止まり、ホスト側からは「押しているのに動かない」としか見えない。

**依頼:** `beginJog()` でも、`moveRelative()` と同じように角度の制限を確かめてほしい。制限が戻っていれば追跡を無効にし、その場で多回転を設定し直すか、理由付きで拒否してほしい（§3）。

## 2. 現状（ソースで確認した事実と、実機で見えたこと）

| 項目 | 現状 | 出典 |
|---|---|---|
| JOG の開始 | `beginJog()` → `checkReady()`（ping・エラーフラグ・位置モードだけを見る）→ `state.valid` が false のときだけ `enableTracking()`（ここで `MAX_ANGLE_LIMIT` に 0 を書いて多回転にする） | `StsServoBus.cpp` `beginJog` / `checkReady` / `enableTracking` |
| 制限が戻ったことの検知 | `moveRelative()` だけが行う: `MIN/MAX != 0/0` なら `state.valid = false` にして `result=REJECTED reason=multi_turn_lost (retry)`（**動かす前**に） | `StsServoBus.cpp` `moveRelative` |
| JOG 中のゴール | `abs_counts ± lead` をゴールに書く。サーボが 1 回転モードなので 0 未満 / 4095 超のゴールは端に丸められ、動かない | `StsServoBus.cpp` `updateJog` |
| 暴走検知 | `abs - goal` が lead + 余裕を超えたときだけ。端で止まっていても差は lead 程度なので**検知されない** | 同上 |
| `SERVO_STATUS` | `tracking=YES` と `limits=0/4095` を同時に出す（矛盾した状態がそのまま見える） | `MotionTask.cpp` / `StsServoBus::readStatus` |

実機（2026-11-08）で ▼（Z を下げる JOG）を押したときのログ:

```
TX JOG 0.0 0.0 -1843 0
RX JOG start vx=0.0 vy=0.0 z=-1843 arm=0 src=SERIAL HOMED=YES
RX JOG servo id=1 begin_ms=212 (hold check; XY waits)
...
RX JOG end reason=zero
RX SERVO_STATUS id=1 result=OK flags=0x00 mode=0 torque=1 raw=0 goal=0 limits=0/4095 tracking=YES abs=0 turns=0.00 voltage=7.6 temp=24 moving=0
```

その前の操作では、巻き上げ点から約 2100 カウント下げたところ（raw が 0 に達したところ）で止まった。上げる側も途中で止まった（4095 に達したと考えられる）。

## 3. 変更案

### 3.1 必須: `beginJog()` で制限を確かめる

`moveRelative()` の確認を関数にまとめ、`beginJog()` でも `state.valid` のときに呼ぶ。

```cpp
// 例: 追跡中なのにサーボが 1 回転モードに戻っていたら、追跡を捨てる
bool StsServoBus::trackingStillMultiTurn(uint8_t id) {
  int min_limit = -1, max_limit = -1;
  return readWordOk(id, SMS_STS_MIN_ANGLE_LIMIT_L, min_limit) &&
         readWordOk(id, SMS_STS_MAX_ANGLE_LIMIT_L, max_limit) &&
         min_limit == 0 && max_limit == 0;
}

bool StsServoBus::beginJog(...) {
  ...
  if (!checkReady(id, detail, detail_size)) return false;
  Track& state = track(id);
  if (state.valid && !trackingStillMultiTurn(id)) {
    state.valid = false;   // サーボだけ電源が切れた: 回転数は失われている
    // 次の行のどちらか:
    // (a) その場で多回転に戻して続ける（abs_counts は現在の raw から振り直し）
    // (b) snprintf(detail, ..., "reason=multi_turn_lost (retry)"); return false;
  }
  if (!state.valid && !enableTracking(id, detail, detail_size)) return false;
  ...
}
```

- (a) なら、押し直すだけで動く。ただし**回転数（絶対位置）は失われている**。そのため `JOG servo id=1 ...` の行に `tracking=RESET` のような印を付け、ホストが Z の基準を捨てられるようにしてほしい。
- (b) なら、`JOG servo id=1 disabled reason=multi_turn_lost (retry)` が出る。次の押下で `enableTracking()` が走る（今の `moveRelative()` と同じ流れ）。
- ゲーム側はどちらにも対応できる。**(a) を推奨**。運用で頻繁に起きるので、押し直し 1 回で済むほうがよい。

### 3.2 推奨: 状態報告の矛盾をなくす

`SERVO_STATUS` で `tracking=YES` かつ `limits` が `0/0` でないときは、`tracking=LOST` と出すか、その時点で `state.valid = false` にしてほしい。ホストが行の解釈に頼らず判断できるようになる。

### 3.3 同じ問題がありうる箇所

- 爪（ID 2）の JOG: 同じ `beginJog()` を通るので、3.1 で一緒に直る。
- `moveToAngle()`（`SERVO_ANGLE`）: 1 回転モード前提の関数なので、逆向きの確認があるか見てほしい。

## 4. ゲーム側の暫定対応（Issue #62、ファームウェア変更なしで動く）

- バックエンドは `SERVO_STATUS` の `tracking=YES` と `limits≠0/0` の組み合わせを「巻き上げサーボのリセット」として検知する。検知すると、Z の記録点を捨て、エラーを表示し、Z の JOG を拒否する。
- 新しいコマンド `z_servo_recover`: リセットを検知しているときだけ `SERVO_TURN 1 0.01` を送る。`moveRelative()` が動かす前に `multi_turn_lost` で拒否して追跡を無効にするので、次の JOG で `enableTracking()` が走って多回転に戻る。
- 3.1 の変更が入れば、`z_servo_recover` を押す手間がなくなる。(a) の場合は、ホスト側で `tracking=RESET` を見て Z の基準を捨てる処理を追加する。

## 5. 受け入れ確認（実機）

1. Z を何回転か下げる。
2. サーボだけ電源を切って入れる（M5 はそのまま）。
3. `SERVO_STATUS 1` が矛盾しない状態を返す（3.2）。
4. ▼ / ▲ の JOG を押すと、1 回転の端で止まらずに動く（3.1 (a)）。または理由付きで拒否され、押し直すと動く（3.1 (b)）。
5. 爪（ID 2）でも同じ。
