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

const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const MUTED := Color("8fa3c4")
const APPLY_LABELS := {"now": "今すぐ", "restart": "次の起動から", "backend": "バックエンド再起動"}

var root: Control
var _rows: Dictionary = {}  # key -> {"item", "control", "label"}
var _status: Label
var tabs: TabContainer
var calibration: CalibrationPanel
var _reset_b: Button
var _cancel_b: Button
var _save_b: Button
const CALIBRATION_TAB := 1
var _list: VBoxContainer

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
	panel.custom_minimum_size = Vector2(940, 640)
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
	info.custom_minimum_size = Vector2(880, 0)
	page.add_child(info)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	for sec in GameConfig.schema.get("sections", []):
		if not sec is Dictionary:
			continue
		var head := StudyHud.label(str(sec.get("title", "")), 24, CYAN, 6)
		_list.add_child(head)
		for it in sec.get("items", []):
			if it is Dictionary and it.has("key"):
				_add_row(it)
	if _rows.is_empty():
		_list.add_child(StudyHud.label("設定の一覧（config/game_config.json の settings_screen）が読めません", 20, Color("ff8a8a"), 4))

	_status = StudyHud.label("", 18, YELLOW, 4)
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
	visible = false

## The 校正 tab (#98): needs main (the robot link, the cameras, the arm's keys).
func setup_calibration(main: Node) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "校正"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	calibration = CalibrationPanel.new()
	calibration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(calibration)
	calibration.setup(main)

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
	_reset_b.visible = not cal
	_save_b.visible = not cal
	_cancel_b.text = "閉じる（Esc）" if cal else "キャンセル（Esc）"
	_status.text = ""
	if cal and calibration != null:
		calibration.opened()

func _process(_dt: float) -> void:
	if calibrating():
		calibration.refresh()

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 22)
	b.focus_mode = Control.FOCUS_NONE  # Space stays the stop key, never "press the button"
	b.pressed.connect(cb)
	return b

func _add_row(it: Dictionary) -> void:
	var key := str(it["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := StudyHud.label(str(it.get("label", key)), 20, Color.WHITE, 3)
	label.custom_minimum_size = Vector2(340, 0)
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
			ob.custom_minimum_size = Vector2(380, 0)
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
			sl.custom_minimum_size = Vector2(300, 0)
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
			le.custom_minimum_size = Vector2(380, 0)
			le.text_changed.connect(func(_t): _mark(key))
			c = le
		_:
			return
	var cell := HBoxContainer.new()  # one width for every control: the badges line up
	cell.custom_minimum_size = Vector2(380, 0)
	cell.add_child(c)
	row.add_child(cell)
	var badge := StudyHud.label(APPLY_LABELS.get(str(it.get("apply", "restart")), "次の起動から"), 14,
		Color("9ff0a8") if str(it.get("apply", "")) == "now" else MUTED, 2)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	_list.add_child(row)
	if it.has("note"):
		var note := StudyHud.label("    " + str(it["note"]), 15, MUTED, 2)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(860, 0)
		_list.add_child(note)
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
	show_tab(0)  # the settings first; the arm moves only once 校正 is picked
	_on_tab_changed(0)
	visible = true

func cancel() -> void:
	if not visible:
		return
	get_viewport().gui_release_focus()
	visible = false
	closed.emit(false)

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
	get_viewport().gui_release_focus()
	visible = false
	closed.emit(true)
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
	if keycode == KEY_ESCAPE:
		cancel()
	return true
