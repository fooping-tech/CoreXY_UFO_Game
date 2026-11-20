class_name OperatorHints
extends RefCounted
## What the operator is told about a refused jog and about the auto catch (the debug panel's
## lines): the backend's reasons said as the next step to take. Pure text, taken out of the
## main scene (#223); the main scene keeps jog_hint_for / auto_catch_hint_for /
## auto_catch_status_text as its callers know them.

## A refused jog, said as what to do next (the backend refuses before anything
## reaches the serial line, so otherwise the keys just seem dead).
static func jog_hint_for(reason: String) -> String:
	var r := reason.to_lower()
	if r.is_empty():
		return ""
	if r.contains("not connected"):
		return "実機に未接続（バックエンドとシリアルを確認）"
	if r.contains("motors not enabled"):
		return "モーターが無効:「実機」タブの「モーター有効」を押す"
	if r.contains("alarm"):
		return "アラーム中:「アラーム解除」→「原点復帰 (home)」を押す"
	if r.contains("not homed") or r.contains("not_homed"):
		return "原点復帰が必要:「原点復帰 (home)」を押す"
	if r.contains("busy"):
		return "ほかの移動を実行中: 終わるまで待つか Space で止める"
	return "JOG が拒否された: " + reason

## Phase names for the status line.
const AUTO_CATCH_PHASE_JA := {
	"IDLE": "待機", "OPEN_CLAW": "爪を開く", "LOWER_TO_CATCH": "キャッチ位置へ下降", "CLOSE_CLAW": "爪を閉じる",
	"RAISE_WITH_ITEM": "安全高さへ上昇", "MOVE_TO_BOX": "救出ボックスへ移動", "LOWER_TO_RELEASE": "リリース高さへ下降",
	"RELEASE": "爪を開いて落とす", "RAISE_EMPTY": "安全高さへ戻る", "CLAW_STANDBY": "爪を待機位置へ", "FAULT": "異常停止",
}

## One line (or two) about the auto catch for the debug panel: what it is doing, or why it stopped.
static func auto_catch_status_text(ac: Dictionary) -> String:
	if ac.is_empty():
		return "自動キャッチ: 状態なし（バックエンド未接続）"
	var phase := str(ac.get("phase", ""))
	var name := str(AUTO_CATCH_PHASE_JA.get(phase, phase))
	var prof := "ドライラン" if str(ac.get("profile", "")) == "dry_run" else "実機"
	if bool(ac.get("active", false)):
		return "自動キャッチ [%s] %d/%d %s（%s）  %.1f s" % [prof, int(ac.get("step", 0)), int(ac.get("steps", 0)), name, phase,
			float(ac.get("elapsed_s", 0.0))]
	match str(ac.get("last_result", "")):
		"done":
			return "自動キャッチ [%s]: 完了（手動操作に戻った）" % prof
		"fault":
			return "自動キャッチ [%s]: 異常停止 — %s\n→ ABORT 済み。原因を確かめてから「アラーム解除」→「原点復帰」" % [prof, str(ac.get("error", ""))]
	return "自動キャッチ [%s]: 待機（C で開始）" % prof

## A refused auto catch, said as what to do next.
static func auto_catch_hint_for(reason: String) -> String:
	var r := reason.to_lower()
	if r.is_empty() or r.contains("debounced"):
		return ""
	if r.contains("not confirmed") or r.contains("is not set"):
		return "自動キャッチ: 校正値が未設定・未確認（config/game_config.json の auto_catch.real）。実機では動かさない"
	if r.contains("alarm"):
		return "自動キャッチ: アラーム中 →「アラーム解除」→「原点復帰 (home)」"
	if r.contains("not homed"):
		return "自動キャッチ: 先に「原点復帰 (home)」"
	if r.contains("motors not enabled"):
		return "自動キャッチ: 先に「モーター有効」"
	if r.contains("z reference"):
		return "自動キャッチ: Z の基準が未設定（アームを一番上にして「巻き上げ点（上）に」）"
	if r.contains("claw open / closed"):
		return "自動キャッチ: 爪の開き / 閉じ位置を記録する（実機タブ 4）"
	if r.contains("below safe_z"):
		return "自動キャッチ: アームを安全高さまで上げてから（W）"
	if r.contains("busy") or r.contains("already running"):
		return "自動キャッチ: ほかの動作中"
	return "自動キャッチ拒否: " + reason
