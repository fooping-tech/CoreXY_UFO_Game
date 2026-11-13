class_name StudyHud
extends CanvasLayer
## The study mode's screen (#86), drawn over the play area while it runs:
##   right   : 月曜日の宿題チェック表, "宿題 n / 3 問" with a chip per problem, the timer
##   bottom  : UFOくん's speech bubble (the same text the voice says)
##   left    : the worksheet on the desk (the mock demo's sheet / the known layout)
##   centre  : banners (宿題完了！！, MISSION COMPLETE!), the study time, the round
##             close-up view while capturing, grown-ups' prompts, errors
## Built in code (like the debug panel). Pure presentation: reads the controller only.

const RIGHT_W := 380.0
const BLUE := Color("3b7dd8")
const ORANGE := Color("e07a00")
const GREEN := Color("2fae5a")
const INK := Color("1d2433")
const PAPER := Color("fffdf6")

var ctl: StudyModeController
var root: Control
var _title: Label
var _mode: Label
var _grade: Label
var _grade_prev: Button
var _grade_next: Button
var _check_rows: Array = []  # [box Label, text Label]
var _count: Label
var _chips: Array = []  # [PanelContainer, Label]
var _bar: ProgressBar
var _timer: Label
var _notice: Label
var _bubble: PanelContainer
var _bubble_text: Label
var _credit: Label
var _explain: PanelContainer
var _explain_text: Label
var _banner: Label
var _sub_banner: Label
var _play: Button
var _time_panel: PanelContainer
var _time_label: Label
var _adult: PanelContainer
var _adult_text: Label
var _error: PanelContainer
var _error_text: Label
var _flash: ColorRect
var _keys: Label
var sheet: StudyWorksheetView
var scope: StudyScopeView
var crackers: StudyCrackers
var _typed := 0.0
var _last_line := ""

func setup(controller: StudyModeController) -> void:
	ctl = controller
	layer = 5
	root = Control.new()
	root.name = "StudyHudRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_header()
	_build_checklist()
	_build_bubble()
	_build_centre()
	ctl.changed.connect(refresh)
	ctl.state_changed.connect(_on_state)
	ctl.speech.line_started.connect(func(_t, _f): _typed = 0.0)
	visible = false

static func label(text: String, size: int, color := INK, outline := 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_constant_override("outline_size", outline)
		l.add_theme_color_override("font_outline_color", Color.WHITE if color.v < 0.5 else INK)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

static func panel(bg: Color, border: Color, radius := 18, border_w := 4) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 6
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

func _build_header() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(20, 14)
	root.add_child(box)
	_title = label("UFOくん 勉強モード", 30, Color("ffe03c"), 8)
	box.add_child(_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_mode = label("", 18, Color("a8f2ff"), 6)
	row.add_child(_mode)
	_grade_prev = Button.new()
	_grade_prev.text = "◀"
	_grade_prev.focus_mode = Control.FOCUS_NONE
	_grade_prev.pressed.connect(func(): ctl.change_grade(-1))
	row.add_child(_grade_prev)
	_grade = label("", 22, Color.WHITE, 6)
	row.add_child(_grade)
	_grade_next = Button.new()
	_grade_next.text = "▶"
	_grade_next.focus_mode = Control.FOCUS_NONE
	_grade_next.pressed.connect(func(): ctl.change_grade(1))
	row.add_child(_grade_next)
	sheet = StudyWorksheetView.new()
	sheet.position = Vector2(20, 112)
	sheet.size = Vector2(230, 325)
	root.add_child(sheet)

func _build_checklist() -> void:
	var p := panel(PAPER, BLUE)
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.offset_left = -RIGHT_W - 16
	p.offset_right = -16
	p.offset_top = 16
	root.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	v.add_child(label("%sの宿題チェック表" % ctl.weekday_label, 24, BLUE))
	for text in ["さんすうプリント", "むずかしい問題にチャレンジ", "おかたづけ"]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var box := label("☐", 30, INK)
		var t := label(text, 22, INK)
		h.add_child(box)
		h.add_child(t)
		v.add_child(h)
		_check_rows.append([box, t])
	v.add_child(HSeparator.new())
	_count = label("宿題 0 / 3 問", 30, INK)
	v.add_child(_count)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 10)
	v.add_child(chips)
	for i in 3:
		var c := panel(Color("e8ecf4"), Color("9aa6bb"), 12, 3)
		c.custom_minimum_size = Vector2(98, 0)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := label("", 19, INK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(l)
		chips.add_child(c)
		_chips.append([c, l])
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 22)
	_bar.max_value = 3
	_bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("d9dfeb")
	bg.set_corner_radius_all(10)
	var fill := StyleBoxFlat.new()
	fill.bg_color = GREEN
	fill.set_corner_radius_all(10)
	_bar.add_theme_stylebox_override("background", bg)
	_bar.add_theme_stylebox_override("fill", fill)
	v.add_child(_bar)
	_timer = label("べんきょう 00:00", 24, INK)
	v.add_child(_timer)
	_notice = label("", 17, Color("8a4b00"))
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size = Vector2(RIGHT_W - 40, 0)
	v.add_child(_notice)

func _build_bubble() -> void:
	_bubble = panel(Color.WHITE, BLUE, 26, 5)
	_bubble.anchor_top = 1.0
	_bubble.anchor_bottom = 1.0
	_bubble.anchor_right = 1.0
	_bubble.offset_left = 20
	_bubble.offset_right = -RIGHT_W - 36
	_bubble.offset_top = -190
	_bubble.offset_bottom = -34
	root.add_child(_bubble)
	var v := VBoxContainer.new()
	_bubble.add_child(v)
	var name_row := HBoxContainer.new()
	name_row.add_child(label("UFOくん", 20, BLUE))
	_credit = label("", 14, Color("8090a8"))
	_credit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_row.add_child(_credit)
	v.add_child(name_row)
	_bubble_text = label("", 32, INK)
	_bubble_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_bubble_text)
	_keys = label("", 14, Color("c8d6f0"), 4)
	_keys.anchor_top = 1.0
	_keys.anchor_bottom = 1.0
	_keys.offset_left = 24
	_keys.offset_top = -26
	_keys.offset_bottom = -4
	root.add_child(_keys)

func _build_centre() -> void:
	_explain = panel(Color("fff7d6"), ORANGE, 18, 4)
	_explain.position = Vector2(270, 112)
	_explain.custom_minimum_size = Vector2(430, 0)
	root.add_child(_explain)
	_explain_text = label("", 21, INK)
	_explain_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_explain_text.custom_minimum_size = Vector2(400, 0)
	_explain.add_child(_explain_text)
	scope = StudyScopeView.new()
	scope.size = Vector2(300, 300)
	root.add_child(scope)
	crackers = StudyCrackers.new()
	crackers.set_anchors_preset(Control.PRESET_FULL_RECT)
	crackers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crackers)
	_banner = label("", 84, Color("ffe03c"), 16)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_banner)
	_sub_banner = label("", 46, Color("7ae0ff"), 12)
	_sub_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_sub_banner)
	_play = Button.new()
	_play.text = "  ゲームで遊ぶ ▶  "
	_play.add_theme_font_size_override("font_size", 38)
	_play.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = {"normal": ORANGE, "hover": Color("ff9a1f"), "pressed": Color("b85f00")}[st]
		sb.border_color = Color("ffe03c")
		sb.set_border_width_all(5)
		sb.set_corner_radius_all(24)
		sb.content_margin_left = 24
		sb.content_margin_right = 24
		sb.content_margin_top = 10
		sb.content_margin_bottom = 10
		_play.add_theme_stylebox_override(st, sb)
	_play.add_theme_color_override("font_color", Color.WHITE)
	_play.add_theme_color_override("font_hover_color", Color.WHITE)
	_play.pressed.connect(func(): ctl.play_game())
	root.add_child(_play)
	_time_panel = panel(Color("10223a"), Color("4fd0ec"), 22, 5)
	var tv := VBoxContainer.new()
	_time_panel.add_child(tv)
	var head := label("今日のお勉強時間", 30, Color("a8f2ff"))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(head)
	_time_label = label("", 64, Color("ffe03c"), 10)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(_time_label)
	root.add_child(_time_panel)
	_adult = panel(Color("fff1dc"), ORANGE, 14, 5)
	_adult_text = label("", 22, Color("6b3a00"))
	_adult_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_adult_text.custom_minimum_size = Vector2(560, 0)
	_adult.add_child(_adult_text)
	root.add_child(_adult)
	_error = panel(Color("ffe3e3"), Color("d33a3a"), 14, 5)
	_error_text = label("", 22, Color("7a1010"))
	_error_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_text.custom_minimum_size = Vector2(560, 0)
	_error.add_child(_error_text)
	root.add_child(_error)
	_flash = ColorRect.new()
	_flash.color = Color(1, 1, 1, 0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flash)

func flash(strength := 0.8, secs := 0.5) -> void:
	_flash.color.a = strength
	var tw := create_tween()
	tw.tween_property(_flash, "color:a", 0.0, secs)

func _on_state(_prev: String, cur: String) -> void:
	visible = cur != "OFF"
	match cur:
		"CELEBRATION":
			flash(0.9, 0.8)
			crackers.burst()
			_pop_banner()
		"GAME_UNLOCKED":
			flash(0.6, 0.6)
			crackers.burst()
			_pop_banner()
		"CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING":
			flash(0.7, 0.25)
			scope.shutter()
	refresh()

func _pop_banner() -> void:
	_banner.scale = Vector2(0.2, 0.2)
	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_banner, "scale", Vector2.ONE, 0.5)

func refresh() -> void:
	if ctl == null:
		return
	var st := ctl.state
	visible = st != "OFF"
	if not visible:
		return
	var vs := root.get_viewport_rect().size
	_mode.text = "【%s】" % ctl.services.mode_label()
	_grade.text = ctl.grade_label()
	var choosing := st in ["INTRO", "WAITING_FOR_WORKSHEET"]
	_grade_prev.visible = choosing
	_grade_next.visible = choosing
	# the checklist
	var t := ctl.tracker
	var done := [t.complete or ctl.completion_fired, t.is_filled(ctl.help_problem), ctl.cleanup_ok]
	for i in 3:
		var row: Array = _check_rows[i]
		row[0].text = "☑" if done[i] else ("☒" if i == 2 and st in ["CLEANUP_FAILED"] else "☐")
		row[0].add_theme_color_override("font_color", GREEN if done[i] else INK)
		row[1].add_theme_color_override("font_color", GREEN if done[i] else INK)
	_count.text = "宿題 %d / %d 問" % [t.filled_count(), t.count]
	_bar.value = t.filled_count()
	for i in _chips.size():
		var s := t.shown_state(i + 1)
		var icon: String = {StudyQuestionTracker.EMPTY: "○", StudyQuestionTracker.WRITING: "✎",
			StudyQuestionTracker.FILLED: "✓", StudyQuestionTracker.HELD: "？"}.get(s, "○")
		var col: Color = {StudyQuestionTracker.EMPTY: Color("e8ecf4"), StudyQuestionTracker.WRITING: Color("ffe9a8"),
			StudyQuestionTracker.FILLED: Color("c9f2d4"), StudyQuestionTracker.HELD: Color("d6dcf0")}.get(s, Color.WHITE)
		var star := "★" if i + 1 == ctl.help_problem else ""
		_chips[i][1].text = "%s%d %s\n%s" % [star, i + 1, icon, StudyQuestionTracker.label(s)]
		(_chips[i][0].get_theme_stylebox("panel") as StyleBoxFlat).bg_color = col
	_timer.text = "べんきょう " + HomeworkClient.format_elapsed(ctl.elapsed_s())
	_notice.text = ctl.notice
	# the bubble
	var line := ctl.speech.current
	if line != "":
		_last_line = line
	_bubble_text.text = _last_line
	var credit := ctl.services.voice_credit
	_credit.text = credit if credit != "" else ("（声なし）" if not ctl.speech.voice_on else "")
	# the explanation card
	var ex := ctl.explanation
	_explain.visible = not ex.is_empty() and st in ["AI_EXPLAINING", "RESUME_STUDY", "STUDYING"] and not ctl.tracker.is_filled(ctl.help_problem)
	if _explain.visible:
		_explain_text.text = "ヒント: %s\n\n考え方:\n%s\n%s" % [ex.get("hint", ""), ex.get("explanation", ""), ctl.explain_note]
	# the worksheet
	sheet.worksheet = ctl.worksheet
	sheet.tracker = ctl.tracker
	sheet.highlight = ctl.help_problem if st in StudyModeController.HELP_STATES or st == "AI_EXPLAINING" else 0
	sheet.caption = "つくえの上（模擬）" if ctl.services.mode == "simulated" else "プリント（%s）" % ctl.worksheet.get("worksheet_id", "")
	sheet.visible = st not in ["CELEBRATION", "GAME_UNLOCKED", "HOMEWORK_COMPLETE"]
	sheet.queue_redraw()
	# the round close-up (the mock's drawing; a real focus camera shows in the game's scope)
	var stage := ctl.capture_stage()
	var has_focus: bool = ctl.main != null and ctl.main.cameras != null and ctl.main.cameras.has_feed("focus")
	scope.visible = ctl.wants_scope() and (not has_focus or ctl.services.mode == "simulated")
	scope.stage = stage if stage != "" else "10cm"
	scope.problem = WorksheetCatalog.problem(ctl.worksheet, ctl.help_problem)
	scope.position = Vector2(266.0, 128.0)  # beside the sheet, clear of the UFO (it rises as the arm goes down)
	scope.queue_redraw()
	# banners
	var celebrate := st in ["CELEBRATION", "HOMEWORK_COMPLETE"]
	var unlocked := st == "GAME_UNLOCKED"
	_banner.visible = celebrate or unlocked
	_banner.text = "宿題完了！！" if celebrate else "MISSION COMPLETE!"
	_banner.size = Vector2(vs.x - RIGHT_W, 110)
	_banner.position = Vector2(0, vs.y * 0.18)
	_banner.pivot_offset = _banner.size * 0.5
	_sub_banner.visible = unlocked
	_sub_banner.text = "GAME MODE UNLOCKED!" + ("" if ctl.cleanup_ok else "\n（お片付けは大人の人と確認してね）")
	_sub_banner.size = Vector2(vs.x - RIGHT_W, 120)
	_sub_banner.position = Vector2(0, vs.y * 0.18 + 110)
	_play.visible = unlocked
	_play.position = Vector2(48, vs.y * 0.18 + 230)
	_time_panel.visible = st in ["CLEANUP", "CLEANUP_FAILED"]
	_time_label.text = study_time_text(ctl.elapsed_s())
	_time_panel.position = Vector2((vs.x - RIGHT_W) * 0.5 - 200, vs.y * 0.12)
	_time_panel.custom_minimum_size = Vector2(400, 0)
	_adult.visible = ctl.adult_prompt != ""
	_adult_text.text = ctl.adult_prompt
	_adult.position = Vector2(270, vs.y - 190 - 150)
	_error.visible = st in ["ERROR"] and ctl.error_text != ""
	_error_text.text = ctl.error_text + "\n（Enter で続ける）"
	_error.position = Vector2(270, vs.y * 0.45)
	_keys.text = key_help(st, ctl.services.mode)

static func study_time_text(secs: float) -> String:
	var s := int(maxf(secs, 0.0))
	if s >= 3600:
		return "%d時間%d分%d秒" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d分%02d秒" % [s / 60, s % 60]

static func key_help(state: String, mode: String) -> String:
	var parts := ["Enter 次へ/確認", "Y HELP", "Space 止める"]
	if state in ["INTRO", "WAITING_FOR_WORKSHEET"]:
		parts.append(", . 学年")
	if mode == "simulated":
		parts.append("1/2/3 記入（模擬）")
	parts.append_array(["F6 スキップ", "F7 失敗注入", "F8 最初から", "F5 終了", "Esc タイトル"])
	return "  ".join(parts)

func _process(dt: float) -> void:
	if not visible or ctl == null:
		return
	_typed += dt * 28.0
	_bubble_text.visible_characters = -1 if _typed >= _bubble_text.text.length() else int(_typed)
	_timer.text = "べんきょう " + HomeworkClient.format_elapsed(ctl.elapsed_s())
