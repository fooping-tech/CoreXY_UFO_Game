# CLAUDE.md — CoreXY UFO Game

このリポジトリで作業するときは、最初にプロジェクト専用スキル **`corexy-ufo-game`**（`.claude/skills/corexy-ufo-game/SKILL.md`）を読むこと。設計制約、改修パターン、テスト手順がまとまっている。

常に守ること（詳細はスキル）:

- `RobotState`（実機の状態）と `GameState`（演出の状態）を混ぜない。物理演算の結果を実機へのコマンドにしない。
- Z は逆マッピング: アームが上がる → ロープが長くなる → UFO が下がる。
- ロープは自前の 3D Verlet/PBD（60 Hz）。エンジンの RigidBody/Joint に置き換えない。
- 安全機構（起動時モーター無効、アーミング、ホーミング、ソフトリミット、`request_id`、常に受け付ける `stop`）を弱めない。通信切断の検知は実機の停止を保証しない。
- `z_sign` / `z_counts_per_unit` / `arm_open_turns` は実機で未確認。実機がつながっていなければ「実機未検証」と報告する。
- 変更後のテスト: `godot --headless --path game res://tests/test_runner.tscn`（基準 56 件）と `cd backend && uv run pytest`（基準 48 件）。

人向けの文書: `README.md`、`docs/HANDOFF.md`、`docs/firmware_protocol.md`、`docs/test_report.md`。

## GitHub での開発（Issue・PR・マージ）

Issue・ブランチ・PR・CI・レビュー・マージに関わる作業は、統合スキル **`dev`**（`.claude/skills/dev/SKILL.md`）の手順で行う。

- 作業前に `python3 .claude/skills/dev/scripts/dev_state.py` で GitHub から状態を復元し、済んでいるフェーズを繰り返さない。
- main に直接 push しない（1 Issue = 1 ブランチ `種類/<番号>-<内容>` = 1 PR、本文に `Closes #N`）。フック `.claude/hooks/guard_git.py` が main への push・force push・破壊的な git 操作・秘密情報のコミットを止める。
- PR の前に `tools/verify.sh` を通す（CI・Security と同じ内容）。秘密情報の検査（pre-commit / pre-push / CI）は回避しない。初回は `tools/security/setup.sh`。方針は `docs/SECURITY.md`。
- マージはユーザーがその PR について明示的に承認したときだけ。
