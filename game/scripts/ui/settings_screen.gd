class_name SettingsScreen
extends CanvasLayer
## The settings screen (#93), opened from the gear on the title screen. The items come from
## game_config.json's settings_screen section; 保存 writes the changed ones to config/local_settings.json
## (GameConfig.save_local: never game_config.json, never a key the schema does not list).
## The settings tab is presentation only: it never writes RobotState and never sends a
## command. It opens over the title, so main.gd keeps holding the manual controls; Space
## still stops. The 校正 tab (#98, CalibrationPanel) sends the calibration commands, and
## main.gd lets the keys move the arm only while that tab shows.

signal closed(saved: bool)

const YELLOW := PanelKit.YELLOW
const CYAN := PanelKit.CYAN
const MUTED := PanelKit.MUTED
const APPLY_LABELS := {"now": "今すぐ", "restart": "次の起動から", "backend": "バックエンド再起動"}

## Portrait (#157): the screen is 720 wide, so the panel is 690 and everything inside it
## is measured from that (the 校正 and テスト tabs use the same inner width).
const PANEL_W := 690.0
const INNER_W := 630.0
const CELL_W := 250.0

var root: Control
var _rows: Dictionary = {}  # key -> {"item", "control", "label"}
var _status: Label
var tabs: TabContainer
var calibration: CalibrationPanel
var tests: DeviceTestPanel
var sheet: SheetCheckPanel
var _reset_b: Button
var _cancel_b: Button
var _save_b: Button
const CALIBRATION_TAB := 1
const TEST_TAB := 2
const SHEET_TAB := 3
## #308: closing after the 校正 tab was shown asks first when the score game still lacks some of
## the crane's calibration: missing_check() -> the items missing ([] = nothing; set by main.gd)
var missing_check: Callable
var _calibration_seen := false
var _confirm: Control
var _confirm_text: Label
var _confirm_saved := false
## the question shown last (tests)
var confirm_message := ""
var _list: VBoxContainer
## #126: each schema section is a card (as on the 校正 tab); rows go in the current one
var _box: VBoxContainer
var cards: Array[PanelContainer] = []

func setup() -> void:
	layer = 21  # over the title (20); main.gd moves the debug panel above both
	root = Control.new()
	root.name = "SettingsRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.04, 0.1, 0.75)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("16203a")
	sb.border_color = Color("4a5a78")
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(PANEL_W, 1000)  # portrait (#157): as wide as the screen allows, tall
	centre.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	box.add_child(StudyHud.label("設定", 40, YELLOW, 10))
	# two tabs (#98): the settings, and the calibration of this machine
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 22)
	tabs.get_tab_bar().focus_mode = Control.FOCUS_NONE
	tabs.tab_changed.connect(_on_tab_changed)
	box.add_child(tabs)
	var page := VBoxContainer.new()
	page.name = "設定"
	page.add_theme_constant_override("separation", 8)
	tabs.add_child(page)
	var info := StudyHud.label("保存すると config/local_settings.json に書きます（Git には入らない）。"
		+ "［今すぐ］は保存で反映、［次の起動から］［バックエンド再起動］は ./start.sh で起動し直すと反映。"
		+ "実機で測る値は「校正」タブで。", 16, MUTED, 3)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(INNER_W, 0)
	page.add_child(info)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO  # a row wider than the portrait panel scrolls; it never widens the panel (#157)
	page.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)
	for sec in GameConfig.schema.get("sections", []):
		if not sec is Dictionary:
			continue
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", CalibrationPanel.card_style())
		_list.add_child(card)
		cards.append(card)
		_box = VBoxContainer.new()
		_box.add_theme_constant_override("separation", 8)
		card.add_child(_box)
		_box.add_child(StudyHud.label(str(sec.get("title", "")), 24, CYAN, 4))
		for it in sec.get("items", []):
			if it is Dictionary and it.has("key"):
				_add_row(it)
	if _rows.is_empty():
		_list.add_child(StudyHud.label("設定の一覧（config/game_config.json の settings_screen）が読めません", 20, Color("ff8a8a"), 4))

	_status = StudyHud.label("", 18, YELLOW, 4)
	# wraps: a long answer (the calibration's shifts, a path) never widens the panel off the screen (#242)
	_status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_status.custom_minimum_size = Vector2(1, 0)
	box.add_child(_status)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 14)
	box.add_child(buttons)
	_reset_b = _button("既定に戻す", reset_defaults)
	buttons.add_child(_reset_b)
	_cancel_b = _button("キャンセル（Esc）", cancel)
	buttons.add_child(_cancel_b)
	_save_b = _button("保存", func(): save())
	_save_b.custom_minimum_size = Vector2(160, 0)
	buttons.add_child(_save_b)
	_build_confirm()
	visible = false

## #308: "まだ … の設定ができていません。閉じてよいですか？" over the screen (hidden).
func _build_confirm() -> void:
	_confirm = Control.new()
	_confirm.name = "CloseConfirm"
	_confirm.set_anchors_preset(Control.PRESET_FULL_RECT)
	_confirm.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm.visible = false
	root.add_child(_confirm)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm.add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm.add_child(centre)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", CalibrationPanel.card_style())
	centre.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	card.add_child(box)
	box.add_child(StudyHud.label("校正がまだ終わっていません", 26, PanelKit.BAD, 4))
	_confirm_text = PanelKit.wrapped(box, "", 20, Color.WHITE, 3, INNER_W - 60.0)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	row.add_child(_button("校正をつづける（Esc）", keep_calibrating))
	var close_b := _button("閉じる（Enter）", confirm_close)
	close_b.custom_minimum_size = Vector2(180, 0)
	row.add_child(close_b)

func confirm_showing() -> bool:
	return _confirm != null and _confirm.visible

## The question, when closing now should be asked about (true = shown, the screen stays open).
func _ask_before_close(saved: bool) -> bool:
	if not _calibration_seen or not missing_check.is_valid():
		return false
	var missing: Array = missing_check.call()
	if missing.is_empty():
		return false
	var lines := ""
	for m in missing:
		lines += "\n・" + str(m)
	confirm_message = "まだ次の設定ができていません:%s\n\nこのままでは、スコアゲームを始められません。閉じてよいですか？" % lines
	_confirm_text.text = confirm_message
	_confirm_saved = saved
	_confirm.visible = true
	get_viewport().gui_release_focus()
	return true

## 閉じる on the question: closed as asked (saved: the settings were written already).
func confirm_close() -> void:
	if not confirm_showing():
		return
	_confirm.visible = false
	_close(_confirm_saved)

## 校正をつづける: back to the 校正 tab, the screen stays.
func keep_calibrating() -> void:
	if _confirm != null:
		_confirm.visible = false
	show_tab(CALIBRATION_TAB)

## The 校正 tab (#98): needs main (the robot link, the cameras, the arm's keys).
func setup_calibration(main: Node) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "校正"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO  # a row wider than the portrait panel scrolls; it never widens the panel (#157)
	tabs.add_child(scroll)
	calibration = CalibrationPanel.new()
	calibration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(calibration)
	calibration.setup(main)

## The テスト tab (#108): the peripherals (UFO-DeviceHub) through the backend.
func setup_tests(main: Node) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "テスト"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO  # a row wider than the portrait panel scrolls; it never widens the panel (#157)
	tabs.add_child(scroll)
	tests = DeviceTestPanel.new()
	tests.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(tests)
	tests.setup(main)

## The プリント tab (#230): the learning support AI's worksheet reader, tried with a camera.
func setup_sheet(main: Node) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "プリント"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	tabs.add_child(scroll)
	sheet = SheetCheckPanel.new()
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sheet)
	sheet.setup(main)

## The プリント tab shows.
func sheet_checking() -> bool:
	return visible and sheet != null and tabs.current_tab == SHEET_TAB

## The テスト tab shows: Space also stops the peripherals (STOP ALL).
func testing() -> bool:
	return visible and tests != null and tabs.current_tab == TEST_TAB

## The 校正 tab shows: main.gd lets the keys move the arm meanwhile.
func calibrating() -> bool:
	return visible and calibration != null and tabs.current_tab == CALIBRATION_TAB

func show_tab(i: int) -> void:
	if i >= 0 and i < tabs.get_tab_count():
		tabs.current_tab = i

func _on_tab_changed(i: int) -> void:
	if _save_b == null:
		return  # the first tab is added while the screen is built
	var cal := i == CALIBRATION_TAB
	var form := i == 0  # only the 設定 tab saves; 校正 and テスト act at once
	_reset_b.visible = form
	_save_b.visible = form
	_cancel_b.text = "キャンセル（Esc）" if form else "閉じる（Esc）"
	_status.text = ""
	_status.add_theme_color_override("font_color", YELLOW)
	if cal and calibration != null:
		_calibration_seen = true
		calibration.opened()
	if i == TEST_TAB and tests != null:
		tests.opened()
	if i == SHEET_TAB and sheet != null:
		sheet.opened()

func _process(dt: float) -> void:
	if testing():
		tests.tick(dt)
		if tests.result_text != "":
			_status.text = tests.result_text
			_status.add_theme_color_override("font_color", DeviceTestPanel.GOOD if tests.result_ok else DeviceTestPanel.BAD)
	if sheet != null:
		if sheet_checking():
			sheet.tick(dt)
		else:
			sheet.tick_hidden(dt)
		if sheet_checking() and sheet.result_text != "":
			_status.text = sheet.result_text
			_status.add_theme_color_override("font_color", SheetCheckPanel.GOOD if sheet.result_ok else SheetCheckPanel.BAD)
	if calibration != null:
		if calibrating():
			calibration.tick(dt)
		else:
			calibration.focus_cal.cancel("校正タブを閉じた")
	if calibrating():
		calibration.refresh()
		if calibration.result_text != "":  # the backend's answer, under the scrolled tab
			_status.text = calibration.result_text
			_status.add_theme_color_override("font_color", CalibrationPanel.GOOD if calibration.result_ok else CalibrationPanel.BAD)

func _button(text: String, cb: Callable) -> Button:
	return PanelKit.button(text, 22, cb)

func _add_row(it: Dictionary) -> void:
	var key := str(it["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := StudyHud.label(str(it.get("label", key)), 20, Color.WHITE, 3)
	label.custom_minimum_size = Vector2(210, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	var c: Control
	match str(it.get("type", "")):
		"bool":
			var cb := CheckButton.new()
			cb.focus_mode = Control.FOCUS_NONE
			cb.toggled.connect(func(_on): _mark(key))
			c = cb
		"enum":
			var ob := OptionButton.new()
			ob.focus_mode = Control.FOCUS_NONE
			ob.fit_to_longest_item = false
			ob.custom_minimum_size = Vector2(CELL_W, 0)
			ob.clip_text = true
			for o in it.get("options", []):
				if o is Array and o.size() > 0:
					ob.add_item(str(o[1]) if o.size() > 1 else str(o[0]))
					ob.set_item_metadata(ob.item_count - 1, str(o[0]))
			ob.item_selected.connect(func(_i): _mark(key))
			c = ob
		"number":
			var hb := HBoxContainer.new()
			var sl := HSlider.new()
			sl.focus_mode = Control.FOCUS_NONE
			sl.min_value = float(it.get("min", 0))
			sl.max_value = float(it.get("max", 100))
			sl.step = float(it.get("step", 1))
			sl.custom_minimum_size = Vector2(CELL_W - 70.0, 0)
			sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var val := StudyHud.label("", 18, Color.WHITE, 3)
			val.custom_minimum_size = Vector2(70, 0)
			sl.value_changed.connect(func(v): val.text = str(snappedf(v, sl.step)); _mark(key))
			hb.add_child(sl)
			hb.add_child(val)
			hb.set_meta("slider", sl)
			hb.set_meta("value_label", val)
			c = hb
		"text":
			var le := LineEdit.new()
			le.max_length = int(it.get("max_length", 200))
			le.custom_minimum_size = Vector2(CELL_W, 0)
			le.text_changed.connect(func(_t): _mark(key))
			c = le
		_:
			return
	var cell := HBoxContainer.new()  # one width for every control: the badges line up
	cell.custom_minimum_size = Vector2(CELL_W, 0)
	cell.add_child(c)
	row.add_child(cell)
	var badge := StudyHud.label(APPLY_LABELS.get(str(it.get("apply", "restart")), "次の起動から"), 14,
		Color("9ff0a8") if str(it.get("apply", "")) == "now" else MUTED, 2)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var parent: VBoxContainer = _box if _box != null else _list
	parent.add_child(row)
	if it.has("note"):
		var note := StudyHud.label("    " + str(it["note"]), 15, MUTED, 2)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(INNER_W - 20.0, 0)
		parent.add_child(note)
	_rows[key] = {"item": it, "control": c, "label": label}

# ------------------------------------------------------------------ state
func active() -> bool:
	return visible

## Shows the values in use (game_config.json + the saved local settings).
func open() -> void:
	for key in _rows.keys():
		set_form_value(key, GameConfig.value(key))
	_status.text = ""
	if not GameConfig.local_warnings.is_empty():
		_status.text = "使わなかった設定があります: " + GameConfig.local_warnings[0]
	if _confirm != null:
		_confirm.visible = false
	show_tab(0)  # the settings first; the arm moves only once 校正 is picked
	_on_tab_changed(0)
	_calibration_seen = tabs.current_tab == CALIBRATION_TAB
	visible = true

func cancel() -> void:
	if not visible or confirm_showing():
		return
	if _ask_before_close(false):
		return
	_close(false)

func _close(saved: bool) -> void:
	get_viewport().gui_release_focus()
	_calibration_seen = false
	visible = false
	closed.emit(saved)

## The form back to game_config.json's values (saved only with 保存).
func reset_defaults() -> void:
	for key in _rows.keys():
		set_form_value(key, GameConfig.base_value(key))
	_status.text = "既定の値に戻しました（保存で確定）"

## Writes the form; "" when saved (the screen closes), else the reason (it stays open).
func save() -> String:
	var err := GameConfig.save_local(form_values())
	if err != "":
		_status.text = "保存できません: " + err
		return err
	if not _ask_before_close(true):  # saved: the question only asks about closing
		_close(true)
	return ""

func form_values() -> Dictionary:
	var out := {}
	for key in _rows.keys():
		out[key] = form_value(key)
	return out

func form_value(key: String):
	var r: Dictionary = _rows[key]
	var c: Control = r.control
	match str(r.item.get("type", "")):
		"bool":
			return (c as CheckButton).button_pressed
		"enum":
			var ob := c as OptionButton
			return ob.get_item_metadata(ob.selected) if ob.selected >= 0 else null
		"number":
			return float((c.get_meta("slider") as HSlider).value)
		"text":
			return (c as LineEdit).text
	return null

func set_form_value(key: String, v) -> void:
	if not _rows.has(key):
		return
	var r: Dictionary = _rows[key]
	var c: Control = r.control
	match str(r.item.get("type", "")):
		"bool":
			(c as CheckButton).set_pressed_no_signal(bool(v))
		"enum":
			var ob := c as OptionButton
			for i in range(ob.item_count):
				if str(ob.get_item_metadata(i)) == str(v):
					ob.select(i)
		"number":
			var sl: HSlider = c.get_meta("slider")
			sl.set_value_no_signal(float(v) if v != null else sl.min_value)
			(c.get_meta("value_label") as Label).text = str(snappedf(sl.value, sl.step))
		"text":
			(c as LineEdit).text = str(v) if v != null else ""
	_mark(key)

## A * after the label: the form differs from game_config.json (saved or not).
func _mark(key: String) -> void:
	var r: Dictionary = _rows[key]
	var name := str(r.item.get("label", key))
	var differs := not GameConfig.same_value(form_value(key), GameConfig.base_value(key))
	(r.label as Label).text = name + ("  ＊" if differs else "")

## Keys while it shows (main.gd keeps Space and F1 / Tab): Esc closes without saving.
func handle_key(keycode: int) -> bool:
	if confirm_showing():  # #308: the question takes the keys while it shows
		if keycode == KEY_ESCAPE:
			keep_calibrating()
		elif keycode in [KEY_ENTER, KEY_KP_ENTER]:
			confirm_close()
		return true
	if keycode == KEY_ESCAPE:
		cancel()
	return true
