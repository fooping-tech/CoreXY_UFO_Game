class_name StaffRecoveryPanel
extends CanvasLayer
## #292: the staff's screen after a fault of the crane stopped the score game.
##
## While the game is latched a banner stays on top of every screen: what stopped, call the
## staff, F9. F9 (StaffControl "recover", the staff remote's RECOVER) or a click on it opens
## the panel: the cause (category, code, the firmware's text, when, what the game was
## doing), the machine now (link, state, homing, motors, servos, the easy mode, the
## preparation), whether the stop was confirmed, what to do next, and the buttons of
## RobotFaultGuard (アラーム解除 = nothing moves; まとめて準備 = the arm moves, pressed twice;
## 状態を取り直す; 確認して新しいゲームへ; メニューへ; 閉じる). Space still stops.
## The screen only shows and calls the guard: it sends nothing itself.

const WIDTH := 660.0

var main: Node
var guard: RobotFaultGuard
var _banner: PanelContainer
var _banner_label: Label
var _panel: Control
var _cause: Label
var _machine: Label
var _todo: Label
var _note: Label
var _history: Label
var _prepare_b: Button
var _clear_b: Button
var _finish_b: Button
var _refresh_b: Button
var _shown := false

func setup(m: Node, g: RobotFaultGuard) -> void:
	main = m
	guard = g
	layer = 23  # over the title (20), the settings (21) and the debug panel (22)
	_build()
	refresh()

func open() -> void:
	_shown = true
	refresh()

func close() -> void:
	_shown = false
	refresh()

func is_open() -> bool:
	return _shown and _panel.visible

func _process(_dt: float) -> void:
	refresh()

func refresh() -> void:
	if guard == null:
		return
	var latched := guard.latched()
	if not latched and not guard.action_note.begins_with("ふっきした"):
		_shown = false
	_banner.visible = latched and not _shown
	_panel.visible = _shown
	if latched:
		_banner_label.text = "%s\nスタッフ: F9 で ふっきの画面" % banner_text(guard.fault())
	if not _shown:
		return
	_cause.text = cause_text(guard.fault(), guard.stop_state) if latched else "ゲームは止まっていない"
	_machine.text = machine_text(guard.state_now())
	var todo := guard.problems()
	var lines: Array[String] = []
	for p in todo:
		lines.append("・" + str(p.text))
	if latched and bool(guard.fault().get("capsule_risk", false)):
		lines.append("・カプセルが爪や Dial に残っていないか確かめて、手で取り除く（自動では出さない）")
	if lines.is_empty() and latched:
		lines.append("・機械とまわりを確かめてから［確認して新しいゲームへ］（中断したゲームは再開しない）")
	_todo.text = "次にすること:\n" + "\n".join(lines)
	_note.text = guard.action_note
	_note.add_theme_color_override("font_color", PanelKit.GOOD if guard.action_ok else PanelKit.BAD)
	_history.text = "\n".join(guard.history.slice(maxi(guard.history.size() - 8, 0)))
	var moving_why := guard.move_blocked()
	_prepare_b.disabled = moving_why != ""
	_prepare_b.text = ("もう一度押すと アームが動く（%d 秒）" % ceili(guard.confirm_left)) if guard.confirm_left > 0.0 \
		else "まとめて準備（原点復帰・アームが動く）"
	_prepare_b.tooltip_text = moving_why
	_clear_b.disabled = guard.pending() or not RobotState.machine_state in RobotFaultWatch.ALARMED
	_finish_b.disabled = not latched or guard.pending() or not guard.link_ok()
	_refresh_b.disabled = guard.pending() or not guard.link_ok()

static func banner_text(f: Dictionary) -> String:
	return "ゲーム停止：%s／スタッフを呼んでください" % RobotFaultWatch.CATEGORIES.get(str(f.get("category", "")), "不明")

static func cause_text(f: Dictionary, stop_state: String) -> String:
	var s := "原因: %s（%s）\n%s" % [RobotFaultWatch.CATEGORIES.get(str(f.get("category", "")), "不明"), str(f.get("code", "")),
		str(f.get("message", ""))]
	if str(f.get("error", "")) != "":
		s += "\nファームウェア／バックエンド: " + str(f.error)
	s += "\n発生: %s・ゲーム %s（セッション %s）" % [str(f.get("at", "")), str(f.get("phase", "")), str(f.get("session", ""))]
	if str(f.get("easy_state", "")) != "":
		s += "・かんたんモード %s %s" % [str(f.easy_state), str(f.get("easy_step", ""))]
	if int(f.get("count", 1)) > 1:
		s += "\n止まってからも異常が %d 回（最新を表示）" % (int(f.count) - 1)
	var also: Array = f.get("also", [])
	if not also.is_empty():
		s += "\n同時に: " + ", ".join(also)
	s += "\n停止: " + str(RobotFaultGuard.STOP_TEXT.get(stop_state, stop_state))
	return s

static func machine_text(s: Dictionary) -> String:
	var em: Dictionary = s.get("easy_mode", {}) if s.get("easy_mode") is Dictionary else {}
	var prep: Dictionary = s.get("calibration_prepare", {}) if s.get("calibration_prepare") is Dictionary else {}
	var yes := func(b) -> String: return "○" if bool(b) else "×"
	var t := "接続 %s・ロボット %s・状態 %s・原点 %s・モーター %s" % [yes.call(s.get("link", false)), yes.call(s.get("connected", false)),
		str(s.get("state", "?")), yes.call(s.get("homed", false)), yes.call(s.get("motors_enabled", false))]
	var servo := "サーボ: 巻き上げ %s・爪 %s" % [
		"電源の入れ直しが必要" if bool(s.get("z_servo_power_cycle", false)) else ("1 回転モード" if bool(s.get("z_servo_reset", false)) else "○"),
		"電源の入れ直しが必要" if bool(s.get("arm_servo_power_cycle", false)) else "○"]
	t += "\n" + servo
	t += "\nかんたんモード: %s %s%s" % [str(em.get("state", "-")), str(em.get("step", "")),
		("（" + str(em.error) + "）") if str(em.get("error", "")) != "" else ""]
	t += "・準備: " + (("実行中 " + str(prep.get("step", ""))) if bool(prep.get("active", false)) else str(prep.get("last_result", "-")))
	if str(s.get("error", "")) != "":
		t += "\nエラー: " + str(s.error)
	return t

func _build() -> void:
	_banner = PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.45, 0.02, 0.02, 0.95)
	bs.border_color = Color("ffcc33")
	bs.set_border_width_all(3)
	bs.set_content_margin_all(12)
	_banner.add_theme_stylebox_override("panel", bs)
	_banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_banner.offset_top = 8
	_banner.offset_left = 8
	_banner.offset_right = -8
	_banner.mouse_filter = Control.MOUSE_FILTER_STOP
	_banner.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			open())
	add_child(_banner)
	_banner_label = StudyHud.label("", 24, Color.WHITE, 4)
	_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_banner.add_child(_banner_label)

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.02, 0.03, 1.0)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(shade)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 20
	scroll.offset_right = -20
	scroll.offset_top = 16
	scroll.offset_bottom = -16
	_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	box.add_child(StudyHud.label("スタッフ用 ふっき", 32, PanelKit.YELLOW, 6))
	PanelKit.wrapped(box, "Space でいつでも止まる。アラーム解除ではアームは動かない。まとめて準備ではアームが動く（2 回押す）。"
		+ "ソフトの停止・解除は電源を切ることではない。機械を目で確かめてから操作する。", 15, PanelKit.MUTED, 2, WIDTH)
	_cause = PanelKit.wrapped(box, "", 19, Color("ff9a8a"), 3, WIDTH)
	_machine = PanelKit.wrapped(box, "", 16, Color.WHITE, 2, WIDTH)
	_todo = PanelKit.wrapped(box, "", 18, PanelKit.CYAN, 3, WIDTH)
	var row := PanelKit.row(box)
	_clear_b = PanelKit.button("アラーム解除（動かない）", 18, func(): guard.clear_alarm(); refresh())
	row.add_child(_clear_b)
	_prepare_b = PanelKit.button("", 18, func(): guard.prepare(); refresh())
	row.add_child(_prepare_b)
	row = PanelKit.row(box)
	_refresh_b = PanelKit.button("状態を取り直す", 16, func(): guard.refresh(); refresh())
	row.add_child(_refresh_b)
	_finish_b = PanelKit.button("確認して新しいゲームへ", 18, func(): guard.finish(); refresh())
	row.add_child(_finish_b)
	row.add_child(PanelKit.button("メニューへ", 16, func():
		close()
		main.show_title()))
	row.add_child(PanelKit.button("閉じる", 16, close))
	_note = PanelKit.wrapped(box, "", 17, PanelKit.GOOD, 2, WIDTH)
	box.add_child(StudyHud.label("記録", 15, PanelKit.MUTED, 2))
	_history = PanelKit.wrapped(box, "", 13, PanelKit.MUTED, 2, WIDTH)
