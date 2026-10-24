# /dev フェーズ別の手順

どのフェーズも、始める前に `python3 .claude/skills/dev/scripts/dev_state.py issue <N>`（または `pr <N>`）で状態を確かめる。
リポジトリ: `fooping-tech/CoreXY_UFO_Game`、既定ブランチ `main`、マージ方式はマージコミット（これまでの PR と同じ）。

## 1. Issue の取得と要件整理

```bash
gh issue view <N> --json number,title,body,labels,state,comments
```

- 本文から**受け入れ条件**を箇条書きで抜き出す。チェックリスト（`- [ ]`）があればそれを使う。
- 受け入れ条件がない・曖昧なときは、自分で案を書いてユーザーに確認する。仕様の重要な分岐（どちらでも実装できて結果が変わるもの）は、推測で進めない。
- Issue が CLOSED なら作業せず、ユーザーに伝える。

**Issue を作る**（「Issueにして」と言われたとき、または作業に Issue がないとき）:

```bash
gh issue create --title "<短い題名>" --label <bug|enhancement|documentation> --body "$(cat <<'EOF'
## 目的
...
## 受け入れ条件
- [ ] ...
## 範囲外
- ...
EOF
)"
```

同じ内容の Issue が既にないか、先に `gh issue list --search "<キーワード>" --state all` で確かめる。

## 2. 調査

- `corexy-ufo-game` スキルの「触るもの」表から、読むべきコードと文書を決める。
- **実機が必要な変更か**を判定する（同スキル §5）。必要なら PR の未解決事項に「実機未検証」と書く前提で進める。
- 変更が `game/`（演出・物理）と `backend/`（実機制御）にまたがる場合は、コミットを分ける。
- 依存する Issue・PR がないかを確認する: `gh pr list --state open`。同じファイルを触る開いた PR があれば、競合の可能性をユーザーに伝える。

## 3. ブランチ作成

```bash
git fetch origin
git status --porcelain            # 未コミットの変更があれば、どのブランチのものか確かめてから動く
git switch --no-track -c <type>/<N>-<slug> origin/main   # 上流を main にしない（push 先の取り違え防止）
```

- `<type>`: `feat`（機能）、`fix`（不具合）、`docs`、`chore`（設定・ツール）、`refactor`、`test`。
- `<slug>`: 英小文字とハイフンで 2〜5 語。
- 既にブランチがあれば作らずに `git switch <branch>`（リモートだけにあるなら `git switch <branch>` で追跡ブランチが作られる）。
- 未コミットの変更が別の作業のものなら、勝手に持ち込まない。ユーザーに確認する。

## 4. 実装とテスト

- 変更は Issue の受け入れ条件の範囲だけにする。ついでの修正は別の Issue にする（未解決事項に書く）。
- 機能を足したら `corexy-ufo-game` スキル（`references/testing.md`）に沿ってテストも足す。
- 検証:

```bash
tools/verify.sh                   # secrets / tooling / backend / godot をすべて
tools/verify.sh --only godot      # 一部だけ
```

- 件数が CLAUDE.md の基準より減ったら原因を調べる。失敗を残したまま次へ進まない。
- 見た目・動きの変更は `--capture` や `--log-motion` で確かめる（`corexy-ufo-game` スキル §6）。

## 5. コミットと push

初回だけ（フックが「検査フックが入っていない」と止めたとき）: `tools/security/setup.sh`。

```bash
tools/security/scan.sh staged     # コミット前（pre-commit フックでも自動実行）
git add <関係するファイルだけ>       # git add -A は使わない（無関係なファイルや秘密情報の混入を防ぐ）
git commit -F - <<'EOF'
<type>: <何をしたか（英語、命令形、50 文字程度）>

<なぜ・どう変えたか。Refs #N>

Co-Authored-By: ...（システムが指定する行）
EOF
tools/security/scan.sh push       # push 前（pre-push フックでも自動実行）
git push -u origin <branch>
```

- フック（`guard_git.py`）や pre-commit / pre-push がコミット・push を止めたら、理由を読んで直す。回避しない（`--no-verify` などは禁止）。
- 秘密情報を検出したら、値をどこにも書かずに（ファイル・ルール・行だけ）ユーザーに報告し、`docs/SECURITY.md` §4 に従う。
- 1 コミット = 1 つの意味のある変更。ゲーム演出と実機制御は分ける。

## 6. PR 作成

先に既存の PR を確認する（冪等性）: `gh pr list --head <branch> --state all`。あれば作らない。

```bash
gh pr create --base main --head <branch> --title "<Issue と対応する題名>" --body "$(cat <<'EOF'
## 概要
...
Closes #<N>

## 変更内容
- ...

## テスト結果
- `tools/verify.sh`: secrets / tooling / backend（pytest 32 件）/ godot（46 件）すべて成功
- 追加したテスト: ...

## 確認方法
1. ...

## 未解決事項・注意
- 実機: 未検証（理由）/ 実機に関係しない
- ...

🤖 Generated with [Claude Code](https://claude.com/claude-code)（システムが指定する署名行）
EOF
)"
```

- テンプレート: `.github/pull_request_template.md`。テスト結果は実際に実行したものだけを書く。
- 作業途中で見せたいときは `--draft` にし、検証が済んだら `gh pr ready <N>`。

## 7. CI とレビューの確認

```bash
gh pr checks <N> --watch --interval 20     # CI が終わるまで待つ（通常 2〜5 分）
python3 .claude/skills/dev/scripts/dev_state.py pr <N>   # CI・未解決の指摘・競合をまとめて確認
```

- CI の失敗ログ: `gh run view <run-id> --log-failed`（run-id は `gh pr checks <N>` の URL から）。
- **Security の必須チェック**（`security: …` の 6 つ）も CI と同じく全部成功が必要。脆弱性（HIGH 以上）で失敗したら依存を更新する。更新できない事情があれば `.trivyignore.yaml` に理由と期限を書いてユーザーに合意を取る（勝手に例外にしない）。
- **自動レビュー**: このリポジトリでは Codex（`chatgpt-codex-connector[bot]`）が PR に行コメントを付ける。重要度バッジ `P0`〜`P3` が付く。`dev_state.py` の「未解決」に一覧が出る。
- **自己レビュー**: PR を作ったら、組み込みの `code-review` スキルで差分をレビューする（`/code-review medium <N>` 相当）。
- **受け入れ条件の独立確認**（変更が大きいとき）: サブエージェントに、自分の結論を渡さずに次を依頼する。

```
CoreXY_UFO_Game の PR #<N> を、Issue #<M> の受け入れ条件に照らしてレビューしてください。
`gh pr diff <N>` と `gh issue view <M>` を読み、設計制約は .claude/skills/corexy-ufo-game/SKILL.md を参照してください。
確認すること: (1) 受け入れ条件を 1 つずつ満たしているか（根拠のファイル:行）、(2) 既存機能を壊していないか、
(3) Issue と無関係な変更が混ざっていないか、(4) セキュリティ上の問題（秘密情報、危険なコマンド、実機の安全機構の弱体化）、
(5) テストが変更に見合って追加されているか。指摘ごとに重要度（必須/推奨/任意）と理由を付けてください。
```

## 8. 修正と再検証

指摘を**重要度別に整理**してから直す。

| 重要度 | 該当するもの | 対応 |
|---|---|---|
| 必須 | CI 失敗、`P0`/`P1`、`CHANGES_REQUESTED`、受け入れ条件の未達、既存機能の破壊、セキュリティ | 必ず直す |
| 推奨 | `P2`、テスト不足、分かりにくい実装 | 原則直す。直さないなら理由を返信する |
| 任意 | `P3`、好みの問題 | 直すか、別 Issue にするかを判断して返信する |

- 指摘が誤りだと判断したら、直さずに根拠を添えて返信する（「指摘が来たから直す」はしない）。
- 直したら `tools/verify.sh` → コミット（`fix: address review on #<PR>` など）→ push。
- 対応した指摘には返信し、スレッドを解決済みにする。

```bash
# 返信（comment_id / thread_id は `dev_state.py pr <N> --json` の pr.threads[] にある）
gh api repos/fooping-tech/CoreXY_UFO_Game/pulls/<N>/comments/<comment_id>/replies -f body="<対応内容とコミット>"
# スレッドを解決済みにする
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread_id>
```

- 返信は同じ内容を二重に投稿しない（投稿前に既存の返信を確認する）。
- main と競合したら `git fetch origin && git merge origin/main` で解消してコミットする（rebase と force push はしない）。

## 9. マージ（ユーザーの承認が必要）

SKILL.md §3 の条件をすべて確認してから:

```bash
gh pr merge <N> --merge          # これまでの PR と同じマージコミット方式
```

- ブランチは消さない（`--delete-branch` を付けない）。片付けたいとユーザーが言ったときだけ消す。
- マージ後、手元を更新する: `git switch main && git pull --ff-only origin main`。

## 10. Issue クローズの確認と報告

```bash
gh issue view <N> --json state,closedByPullRequestsReferences
```

- `Closes #N` があれば Issue は自動で閉じる。閉じていなければ、PR へのリンクを添えて閉じる:
  `gh issue close <N> --comment "PR #<PR> でマージしました"`（閉じてよいかはマージの承認に含まれるとみなす）。
- main の CI（push で実行される）が成功したかも確認する: `gh run list --branch main --limit 1`。
- 報告は SKILL.md §5 の形式で。実機未検証の項目は、実機で確認する手順を添える。

## 付録: よくある状態と対処

| 状態（`dev_state.py` の出力） | 対処 |
|---|---|
| 未コミットの変更がある別ブランチにいる | どの作業のものか確認する。関係なければユーザーに知らせ、勝手にコミット・破棄しない |
| PR の base が `main` でない（積み重ね PR） | 先の PR のマージ後に `gh pr edit <N> --base main`。競合が出たら §8 の方法で解消 |
| CI がない（`checks: none`） | `.github/workflows/ci.yml` が base にあるか確認。ない間は手元の `tools/verify.sh` の結果を PR に書く |
| Issue に PR が複数ある | どれを残すかユーザーに確認する（勝手に閉じない） |
| PR がマージされずに閉じられている | 再開するか新しい PR にするかをユーザーに確認する |
