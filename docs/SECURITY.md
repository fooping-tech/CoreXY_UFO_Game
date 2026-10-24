# セキュリティ運用（秘密情報・脆弱性・マージ制御）

対象: このリポジトリで開発する人と Claude Code（`/dev` スキル）。

## 1. 仕組みの全体

| いつ | 何が | 何を検査するか | 回避 |
|---|---|---|---|
| Claude がコマンドを実行する前 | `.claude/hooks/guard_git.py`（Claude Code フック） | main への push、force push、破壊的な git 操作、秘密情報を含むコミット、検査の回避、検査フック未導入でのコミット・push | できない（ユーザーが自分のターミナルで行う必要がある） |
| `git commit` の前 | pre-commit → `tools/security/scan.sh staged` | ステージした変更（Gitleaks）、禁止ファイル名 | `--no-verify` などは禁止 |
| `git push` の前 | pre-push → `tools/security/scan.sh push` | まだ origin にないコミット（Gitleaks） | 同上 |
| PR の作成・更新、main への push、毎週 | `.github/workflows/security.yml` | 禁止ファイル、Gitleaks（全履歴）、Trivy（秘密情報・脆弱性・設定不備）、検査ツール自体の自己テスト | — |
| main へのマージ | GitHub ルールセット `main protection`（`.github/rulesets/main.json`） | 上記の必須チェックと CI がすべて成功、未解決のレビューなし、PR 経由のみ、force push・削除の禁止 | 管理者も迂回しない（bypass なし） |

最初に一度だけ: `tools/security/setup.sh`（固定版の Gitleaks / Trivy と pre-commit を入れ、フックを有効にする）。

## 2. 失敗の基準

| 検査 | 失敗にする条件 |
|---|---|
| 秘密情報（Gitleaks・Trivy secret・禁止ファイル名） | **重大度にかかわらず 1 件でも** |
| 依存ライブラリの脆弱性（Trivy vuln） | HIGH 以上。例外は `.trivyignore.yaml` に理由（`statement`）と期限（`expired_at`、90 日以内）付きで記録し、PR で合意する。期限が切れると再び失敗する |
| 設定不備（Trivy misconfig） | HIGH 以上 |
| 検査ツールの自己テスト | ダミーの検出用データで各ツールが失敗しなかったら失敗（検査が働いていないため） |

## 3. 秘密情報の扱い

- API キーやトークンをソースコードに書かない。実行時に環境変数か `.env`（git 管理外）から読む。
- `.env` 系・秘密鍵・認証情報ファイルは `.gitignore` 済みで、追跡すると CI が失敗する。`.env.example` だけは追跡してよいが、**ダミー値のみ**（`<...>`、`changeme`、空）。
- CI で認証情報が必要になったら GitHub Actions Secrets に置き、`${{ secrets.NAME }}` で渡す。ログに出さない（`echo` しない、`set -x` しない）。クラウドへのデプロイなどでは、長期固定キーではなく OIDC（`permissions: id-token: write` と各クラウドのフェデレーション）を使う。現在の CI は秘密情報を使わず、`contents: read` の権限だけで動く。
- 検査結果はファイル・ルール・行・コミットだけを表示し、**値は表示しない**（`tools/security/report.py`）。PR コメントにも値を書かない。
- 独自形式のキーを追加するときは、同じ正規表現を 3 か所に足す: `.gitleaks.toml`、`tools/security/trivy-secret.yaml`、`.claude/hooks/guard_git.py`。`scan.sh selftest` が 3 か所の一致を確かめる。いまの例は `cxufo_live_` / `cxufo_test_` + 32 文字。

## 4. 秘密情報を検出したとき

1. 値をコードから取り除き、環境変数か `.env` に移す。
2. **一度でもコミットや push をした値は漏えいしたものとして扱い、発行元で無効化（ローテーション）する。** 履歴から消すだけでは不十分。
3. 履歴からの削除は force push を伴うので、必ず人が判断して行う（Claude は行わない）。
4. 誤検知なら、Gitleaks は `.gitleaksignore` に fingerprint と「理由・期限・担当」をコメントで書き、PR で合意する。本物の秘密情報を例外にしてはいけない。

## 5. ツールの版と更新

- Gitleaks 8.30.1、Trivy 0.75.0、pre-commit 4.7.0。`tools/security/install_tools.sh` が SHA-256 を照合してから入れる。
- 更新するときは公開から 2 週間以上たった版を選び、版とハッシュを同時に書き換えて PR にする。

## 6. ルールセットの適用（リポジトリ管理者）

```bash
tools/security/apply_ruleset.sh --check   # 適用状況の確認
tools/security/apply_ruleset.sh           # 作成または更新（管理者権限が必要）
```

Claude のフックはルールセットの変更を拒否するので、管理者が自分で実行する。必須チェックの名前を変えたら `.github/rulesets/main.json` も合わせる。
