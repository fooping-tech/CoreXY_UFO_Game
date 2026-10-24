# CLAUDE.md — CoreXY UFO Game

このリポジトリで作業するときは、最初にプロジェクト専用スキル **`corexy-ufo-game`**（`.claude/skills/corexy-ufo-game/SKILL.md`）を読むこと。設計制約、改修パターン、テスト手順がまとまっている。

常に守ること（詳細はスキル）:

- `RobotState`（実機の状態）と `GameState`（演出の状態）を混ぜない。物理演算の結果を実機へのコマンドにしない。
- Z は逆マッピング: アームが上がる → ロープが長くなる → UFO が下がる。
- ロープは自前の 3D Verlet/PBD（60 Hz）。エンジンの RigidBody/Joint に置き換えない。
- 安全機構（起動時モーター無効、アーミング、ホーミング、ソフトリミット、`request_id`、常に受け付ける `stop`）を弱めない。通信切断の検知は実機の停止を保証しない。
- `z_sign` / `z_counts_per_unit` / `arm_open_turns` は実機で未確認。実機がつながっていなければ「実機未検証」と報告する。
- 変更後のテスト: `godot --headless --path game res://tests/test_runner.tscn`（基準 46 件）と `cd backend && uv run pytest`（基準 32 件）。

人向けの文書: `README.md`、`docs/HANDOFF.md`、`docs/firmware_protocol.md`、`docs/test_report.md`。
