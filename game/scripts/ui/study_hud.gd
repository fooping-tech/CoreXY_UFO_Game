class_name StudyHud
extends CanvasLayer
## The study mode's screen (#86), drawn over the play area while it runs:
##   top     : the title, the mode and grade; at the right "宿題 n / m 問", the study time, the energy ⚡
##   bottom  : UFOくん's speech bubble (the same text the voice says), the voice bar over it
##   middle  : the worksheet, big (the camera's cut-out picture / the mock demo's sheet); in the
##             answer check (#237) its ○ / ？ are drawn on it, with a giant "せいかい！", COMBO,
##             shakes, flashes and sparkles (no list at the right any more)
##   centre  : banners (宿題完了！！, MISSION COMPLETE!), the study time, the round
##             close-up view while capturing, grown-ups' prompts, errors
## Built in code (like the debug panel). Pure presentation: reads the controller only.

const RIGHT_W := 380.0
## Portrait (#157), top to bottom: the title; UFOくん's sky (the explanation, the scope and
## the banners come up there); the worksheet (left) beside the checklist (right); UFOくん's words.
## the worksheet and the checklist stand in the middle of the screen: UFOくん hangs above
## them from the top (the crane's rope), its words are under them
const HEADER_H := 560.0
const EXPLAIN_Y := 112.0
const BLUE := Color("3b7dd8")
const ORANGE := Color("e07a00")
const GREEN := Color("2fae5a")
const INK := Color("1d2433")
const PAPER := Color("fffdf6")

var ctl: StudyModeController
var root: Control
var _title: Label
var _mode: Label
var _energy: Label
var _powers: PanelContainer
var _power_buttons: Array[Control] = []  # the roulette's cards (a pixel-art item and its name)
## #237: "GET!!": the item the roulette stopped on, big, with turning rays (time since it began)
var _get_fx: Control
var _get_kind := ""
var _get_text := ""
var _get_t := -1.0
var _get_queue: Array = []  # [kind, words] still to show, one after another
var _reward_gets_in := -1.0  # seconds until the reward's items are got (-1 = none to come)
const GET_S := 2.6
const GET_DELAY_S := 1.0  # the reward's banner first, then its items
## the play button's top: below where UFOくん can hang (the crane lowers it), above the bubble
const PLAY_Y := HEADER_H + 250.0
var _count: Label
var _timer: Label
## #237: the big moments: a giant word ("せいかい！"), COMBO, the effects' layer over the sheet
var _pop: Label
var _combo: Label
var fx_layer: Node2D
var _mark_t := {}  # number -> msec its mark was shown
var _crop_frozen: ImageTexture
var _frozen_src: Image
var _time_shown := 0.0  # the TIME count-up
var _last_tick := -1
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
## #233: the voice dialogue: the microphone button (held) and what the child said / is happening
var _voice_bar: PanelContainer
var _mic: Button
var _voice_text: Label
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
	_build_status()
	_build_bubble()
	_build_voice()
	_build_centre()
	_build_pops()
	GameState.event.connect(_on_event)
	ctl.changed.connect(refresh)
	if ctl.voice != null:
		ctl.voice.changed.connect(refresh)
	ctl.state_changed.connect(_on_state)
	ctl.speech.line_started.connect(func(_t, _f): _typed = 0.0)
	visible = false

## Big symbols that stay in the body font (the dot font draws them small or not at all).
const SYMBOLS := ["☐", "☑", "✓", "✔"]

static func label(text: String, size: int, color := INK, outline := 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	if size >= UiFonts.TITLE_MIN_SIZE and not text in SYMBOLS:
		UiFonts.use_title(l)  # titles, banners and the big lines in the dot font (#134)
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
	_title = label("UFOくん 学習モード", 30, Color("ffe03c"), 8)
	box.add_child(_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	_mode = label("", 18, Color("a8f2ff"), 6)
	row.add_child(_mode)
	# #283: no grade picker here any more (the grade comes from the settings screen)
	sheet = StudyWorksheetView.new()
	sheet.position = Vector2(60, HEADER_H + 2.0)  # #237: big in the middle (no list at the right)
	sheet.size = Vector2(600, 386)
	root.add_child(sheet)

## The top right: the homework's count, the study time, the game energy (no list: #237).
func _build_status() -> void:
	var v := VBoxContainer.new()
	v.anchor_left = 1.0
	v.anchor_right = 1.0
	v.offset_left = -300
	v.offset_right = -16
	v.offset_top = 14
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(v)
	_count = label("", 24, Color.WHITE, 6)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_count)
	_timer = label("べんきょう 00:00", 20, Color("a8f2ff"), 6)
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_timer)
	_energy = label("", 34, Color("ffd21f"), 8)
	_energy.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_energy)
	_notice = label("", 17, Color("ffcf8a"), 5)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size = Vector2(680, 0)
	_notice.position = Vector2(20, HEADER_H - 40.0)
	root.add_child(_notice)

## The giant words and the effects' layer, over everything but the flash.
func _build_pops() -> void:
	fx_layer = Node2D.new()
	fx_layer.name = "StudyFx"
	root.add_child(fx_layer)
	_pop = label("", 120, Color("ff3b5c"), 22)
	_pop.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pop.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pop.modulate.a = 0.0
	root.add_child(_pop)
	_combo = label("", 64, Color("ffd21f"), 14)
	_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo.modulate.a = 0.0
	root.add_child(_combo)
	_get_fx = Control.new()
	_get_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	_get_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_get_fx.draw.connect(_draw_get)
	root.add_child(_get_fx)
	root.move_child(_flash, root.get_child_count() - 1)

func _build_bubble() -> void:
	_bubble = panel(Color.WHITE, BLUE, 26, 5)
	_bubble.anchor_top = 1.0
	_bubble.anchor_bottom = 1.0
	_bubble.anchor_right = 1.0
	# portrait (#157): UFOくん's words across the whole foot of the screen
	_bubble.offset_left = 20
	_bubble.offset_right = -20
	_bubble.offset_top = -250
	_bubble.offset_bottom = -64
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
	_keys.anchor_right = 1.0
	_keys.offset_left = 20
	_keys.offset_right = -20
	_keys.offset_top = -58
	_keys.offset_bottom = -4
	_keys.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_keys.clip_text = true
	root.add_child(_keys)

## #233: over UFOくん's bubble: hold the microphone (or the talk key) and speak.
func _build_voice() -> void:
	_voice_bar = panel(Color("eaf6ff"), Color("5cb8ff"), 20, 3)
	# portrait (#157): the left column, under the worksheet and over the bubble (the checklist is
	# on the right down to about there)
	_voice_bar.anchor_top = 1.0
	_voice_bar.anchor_bottom = 1.0
	_voice_bar.anchor_right = 1.0
	_voice_bar.offset_left = 20
	_voice_bar.offset_right = -20
	_voice_bar.offset_top = -326
	_voice_bar.offset_bottom = -258
	root.add_child(_voice_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_voice_bar.add_child(row)
	_mic = Button.new()
	_mic.text = "🎤"
	_mic.custom_minimum_size = Vector2(52, 52)
	_mic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mic.add_theme_font_size_override("font_size", 24)
	_mic.focus_mode = Control.FOCUS_NONE  # Space stays the stop key
	_mic.mouse_filter = Control.MOUSE_FILTER_STOP
	_mic.button_down.connect(func(): if ctl.voice != null: ctl.voice.press())
	_mic.button_up.connect(func(): if ctl.voice != null: ctl.voice.release())
	row.add_child(_mic)
	_voice_text = label("", 18, INK)
	_voice_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_voice_text)
	_voice_bar.visible = false

## What the voice bar says: the child's words, then how it goes.
static func voice_line(heard: String, status: String) -> String:
	if heard != "" and status != "":
		return "きみ:「%s」\n%s" % [heard, status]
	if heard != "":
		return "きみ:「%s」" % heard
	return status

func _build_centre() -> void:
	_explain = panel(Color("fff7d6"), ORANGE, 18, 4)
	_explain.position = Vector2(20, EXPLAIN_Y)
	_explain.custom_minimum_size = Vector2(680, 0)
	root.add_child(_explain)
	_explain_text = label("", 21, INK)
	_explain_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_explain_text.custom_minimum_size = Vector2(640, 0)
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
	UiFonts.use_title(_play)
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
	# #237: the power ticket's roulette over the game's power-ups (the light goes round and stops)
	_powers = panel(Color("10223a"), Color("ffe03c"), 22, 5)
	_powers.mouse_filter = Control.MOUSE_FILTER_STOP
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 14)
	_powers.add_child(pr)
	for i in StudyModeController.POWERUPS.size():
		var kind: String = StudyModeController.POWERUPS[i][0]
		var b := panel(Color("1c2a4a"), Color("4a5a78"), 16, 3)
		b.custom_minimum_size = Vector2(196, 170)
		var cv := VBoxContainer.new()
		cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(cv)
		var art := Control.new()  # the item, drawn in dots
		art.custom_minimum_size = Vector2(0, 104)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.draw.connect(func(): PowerItemArt.draw(art, kind, art.size * 0.5, 6.0))
		cv.add_child(art)
		var name_l := label(StudyModeController.POWERUPS[i][1], 22, Color.WHITE, 4)
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(name_l)
		pr.add_child(b)
		_power_buttons.append(b)
	root.add_child(_powers)
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

func _on_state(prev: String, cur: String) -> void:
	visible = cur != "OFF"
	if prev == "WAITING_FOR_WORKSHEET" and cur == "STUDYING":
		found()
	match cur:
		"REWARD_REVEAL":
			flash(1.0, 0.9)
			crackers.burst()
			_pop_banner()
			shake(1.0)
			_time_shown = 0.0
			_last_tick = -1
			_burst_at(Vector2(360, HEADER_H + 60.0), 4.0)
			_reward_gets_in = GET_DELAY_S
			get_tree().create_timer(0.45).timeout.connect(func(): if visible: crackers.burst())
		"POWERUP_SELECT":
			shake(0.35)
		"ANSWER_CHECK_READY":
			_mark_t.clear()
			pop("こたえあわせ！", Color("5cd6ff"), 92)
			shake(0.4)
		"GAME_READY_WITH_REWARD":
			flash(0.8, 0.6)
			crackers.burst()
			_pop_banner()
			shake(0.7)
		"CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING":
			flash(0.7, 0.25)
			scope.shutter()
	refresh()

## #237: the sheet found: a giant word, a shake, a flash, crackers and bursts round the sheet.
func found() -> void:
	pop("みつけた！", Color("ff7a2f"), 110)
	flash(0.8, 0.5)
	shake(0.8)
	crackers.burst()
	var c := sheet.global_position + sheet.size * 0.5
	_burst_at(c, 4.0)
	for i in 6:
		var a := TAU * i / 6.0
		var p := c + Vector2(cos(a) * 250.0, sin(a) * 160.0)
		get_tree().create_timer(0.08 * i).timeout.connect(func(): if visible: _burst_at(p, 2.2))

## #237: the big moments.
func shake(amount: float) -> void:
	if ctl.main != null and ctl.main.get("shake") != null:
		ctl.main.shake.add_trauma(amount)

## A giant word in the middle, bouncing in and fading out.
func pop(text: String, color: Color, size := 120) -> void:
	_pop.text = text
	_pop.add_theme_font_size_override("font_size", size)
	_pop.add_theme_color_override("font_color", color)
	var vs := root.get_viewport_rect().size
	_pop.size = Vector2(vs.x, size * 1.6)
	_pop.position = Vector2(0, HEADER_H - 40.0 - size * 0.8)  # over the sheet's top: the ○ being drawn stays in sight
	_pop.pivot_offset = _pop.size * 0.5
	_pop.scale = Vector2(0.2, 0.2)
	_pop.rotation = randf_range(-0.12, 0.12)
	_pop.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(_pop, "scale", Vector2(1.25, 1.25), 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_pop, "scale", Vector2.ONE, 0.12)
	tw.tween_interval(0.55)
	tw.parallel().tween_property(_pop, "rotation", 0.0, 0.3)
	tw.tween_property(_pop, "modulate:a", 0.0, 0.35)

func _pop_combo(n: int) -> void:
	_combo.text = "COMBO × %d!!" % n
	var vs := root.get_viewport_rect().size
	_combo.size = Vector2(vs.x, 90)
	_combo.position = Vector2(0, HEADER_H + 40.0)
	_combo.pivot_offset = _combo.size * 0.5
	_combo.scale = Vector2(1.6, 1.6)
	_combo.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_property(_combo, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.7)
	tw.tween_property(_combo, "modulate:a", 0.0, 0.3)

## Sparkles and a burst on the HUD (over the sheet).
func _burst_at(p: Vector2, scale_k := 2.5) -> void:
	if not VFXManager.enabled:
		return
	VFXManager.spawn_fx("success_sparkle", p, {"scale": scale_k, "parent": fx_layer})
	VFXManager.spawn_fx("grab_burst", p, {"scale": scale_k * 0.8, "parent": fx_layer})

func _on_event(name: String, data: Dictionary) -> void:
	if ctl == null or not ctl.active():
		return
	match name:
		"study_answer_correct":
			var n := int(data.get("number", 0))
			_mark_t[n] = Time.get_ticks_msec()
			refresh()
			flash(0.55, 0.3)
			shake(0.55 + 0.1 * minf(float(data.get("combo", 1)), 4.0))
			pop("せいかい！", Color("ff3b5c"))
			get_tree().create_timer(0.25).timeout.connect(func(): if visible: _burst_at(sheet.mark_point(n)))
			if int(data.get("combo", 0)) >= 2:
				_pop_combo(int(data.combo))
			_bump(_energy)
		"study_answer_review":
			_mark_t[int(data.get("number", 0))] = Time.get_ticks_msec()
			refresh()
			pop("みてみよう？", Color("ffd21f"), 84)
			shake(0.15)
		"study_answer_unclear":
			_mark_t[int(data.get("number", 0))] = Time.get_ticks_msec()
			refresh()
		"study_powerup_selected":
			flash(0.8, 0.45)
			shake(0.9)
			var kind := str(data.get("kind", ""))
			item_get(kind, "%s GET!!" % power_name(kind))
			var vs := root.get_viewport_rect().size
			_burst_at(get_centre(vs), 4.0)
			get_tree().create_timer(0.5).timeout.connect(func(): if visible: _burst_at(get_centre(vs) + Vector2(-140, 40), 2.5))
			get_tree().create_timer(0.8).timeout.connect(func(): if visible: _burst_at(get_centre(vs) + Vector2(150, -30), 2.5))

## An item got (a pixel-art item, big, with turning rays); one after another when several.
func item_get(kind: String, words: String) -> void:
	if _get_t >= 0.0:
		_get_queue.append([kind, words])
	else:
		_start_get(kind, words)

func _start_get(kind: String, words: String) -> void:
	_get_kind = kind
	_get_text = words
	_get_t = 0.0
	flash(0.6, 0.35)
	shake(0.6)
	if ctl != null:
		ctl.sounds.cue("power_pick")
	var vs := root.get_viewport_rect().size
	_burst_at(get_centre(vs), 3.5)

## The reward's items: the clock for the TIME, then the ticket (the reveal waits for them).
func reward_gets(r: Dictionary) -> void:
	_get_queue.clear()
	if int(r.get("time_bonus_s", 0)) > 0:
		item_get("clock", "TIME +%d GET!!" % int(r.time_bonus_s))
	if int(r.get("power_tickets", 0)) > 0:
		item_get("ticket", "POWER TICKET GET!!")

static func get_centre(vs: Vector2) -> Vector2:
	return Vector2(vs.x * 0.5, HEADER_H + 150.0)  # over the roulette (under UFOくん)

## The item get: the screen dims, rays turn behind the item, it bounces in big, "GET!!" under it;
## then, on the game's ready screen, the items got float by the play button.
func _draw_get() -> void:
	var vs := root.get_viewport_rect().size
	if _get_t >= 0.0 and _get_kind != "":
		var t := _get_t
		var fade := clampf(minf(t / 0.15, (GET_S - t) / 0.4), 0.0, 1.0)
		_get_fx.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.02, 0.03, 0.08, 0.55 * fade))
		var c := get_centre(vs)
		var rays := 14
		for i in rays:  # turning rays
			var a0 := t * 0.9 + TAU * i / rays
			var a1 := a0 + TAU / rays * 0.5
			var far := 520.0
			var col := Color(1.0, 0.85, 0.2, 0.32 * fade) if i % 2 == 0 else Color(1.0, 1.0, 1.0, 0.18 * fade)
			_get_fx.draw_colored_polygon(PackedVector2Array([c, c + Vector2(cos(a0), sin(a0)) * far,
				c + Vector2(cos(a1), sin(a1)) * far]), col)
		var k := clampf(t / 0.35, 0.0, 1.0)
		var bounce := 1.0 + 0.25 * sin(k * PI) if k < 1.0 else 1.0 + 0.04 * sin(t * 6.0)
		var px := 13.0 * ease(k, 0.3) * bounce
		var bob := Vector2(0, 6.0 * sin(t * 4.0))
		_get_fx.draw_circle(c + bob, 120.0 * ease(k, 0.3), Color(1.0, 0.95, 0.6, 0.25 * fade))
		PowerItemArt.draw(_get_fx, _get_kind, c + bob, px, fade)
		for i in 6:  # twinkles round it
			var a := t * 2.2 + TAU * i / 6.0
			var sp := c + Vector2(cos(a), sin(a)) * (150.0 + 20.0 * sin(t * 5.0 + i))
			var sz := 10.0 + 6.0 * sin(t * 9.0 + i)
			var sc := Color(1, 1, 1, fade)
			_get_fx.draw_line(sp - Vector2(sz, 0), sp + Vector2(sz, 0), sc, 3.0)
			_get_fx.draw_line(sp - Vector2(0, sz), sp + Vector2(0, sz), sc, 3.0)
		var font: Font = UiFonts.title()
		var text := _get_text
		var fs := int(58 * clampf((t - 0.25) / 0.2, 0.0, 1.0) * (1.0 + 0.15 * sin(clampf((t - 0.25) / 0.25, 0.0, 1.0) * PI)))
		if fs > 4:
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var at := Vector2(c.x - w * 0.5, c.y + 150.0)
			_get_fx.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 14, Color("1a1030", fade))
			_get_fx.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.85, 0.15, fade))
		return
	if ctl != null and ctl.state == "GAME_READY_WITH_REWARD":
		var tt := Time.get_ticks_msec() / 1000.0
		var i := 0
		for kind in ctl.selected_powerups:
			var at := Vector2(vs.x * 0.5 + 90.0 * (i - (ctl.selected_powerups.size() - 1) * 0.5), PLAY_Y + 150.0)
			PowerItemArt.draw(_get_fx, str(kind), at + Vector2(0, 6.0 * sin(tt * 3.0 + i)), 6.0)
			i += 1

## A little bounce on a label (the energy when it grows).
func _bump(l: Label) -> void:
	l.pivot_offset = l.size * 0.5
	l.scale = Vector2(1.6, 1.6)
	create_tween().tween_property(l, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

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
	var t := ctl.tracker
	# the top right: how far the homework is, then the answer check's right ones
	var checking := ctl.completion_fired
	if checking:
		_count.text = "せいかい %d / %d" % [ctl.grading.count(StudyGrading.CORRECT), ctl.grading.numbers.size()]
	elif t.count == 0:
		_count.text = "問題を さがしています"
	else:
		_count.text = "宿題 %d / %d 問" % [t.filled_count(), t.count]
	var e := ctl.energy()
	_energy.text = ("⚡ × %d" % e) if checking and e > 0 else ""
	_timer.text = "べんきょう " + HomeworkClient.format_elapsed(ctl.elapsed_s())
	_notice.text = ctl.notice
	# the bubble
	var line := ctl.speech.current
	if line != "":
		_last_line = line
	_bubble_text.text = _last_line
	# #233: the voice dialogue
	var vo := ctl.voice
	if vo != null:
		var status := vo.status_text()
		var talking := vo.state != StudyVoice.IDLE
		_voice_bar.visible = vo.enabled and ctl.services.mode != "simulated" and vo.in_talk_state() \
			and (status != "" or vo.heard != "" or talking)
		_voice_text.text = voice_line(vo.heard, status)
		_mic.disabled = not (talking or vo.can_talk())
		_mic.modulate = Color("ff8a8a") if vo.state == StudyVoice.LISTENING else Color.WHITE
	var credit := ctl.services.voice_credit
	_credit.text = credit if credit != "" else ("（声なし）" if not ctl.speech.voice_on else "")
	# the explanation card
	var ex := ctl.explanation
	# #136: asked by hand, a filled problem is explained too: shown while it is explained
	_explain.visible = not ex.is_empty() and (st == "AI_EXPLAINING"
		or (st in ["RESUME_STUDY", "STUDYING"] and not ctl.tracker.is_filled(ctl.help_problem)))
	if _explain.visible:
		_explain_text.text = "ヒント: %s\n\n考え方:\n%s\n%s" % [ex.get("hint", ""), ex.get("explanation", ""), ctl.explain_note]
	# the worksheet
	sheet.worksheet = ctl.worksheet
	sheet.tracker = ctl.tracker
	sheet.highlight = ctl.help_problem if st in StudyModeController.HELP_STATES or st == "AI_EXPLAINING" else \
		(ctl.reveal_current if st == "GRADING_QUESTION" else 0)
	sheet.marks = ctl.services.sheet_marks() if ctl.services.mode == "camera" else {}
	var cams: CameraHub = ctl.main.cameras if ctl.main != null else null
	sheet.photo_texture = cams.texture("overview") if cams != null and cams.has_feed("overview") else null
	sheet.crop_texture = _crop if _crop_wanted() else null
	# the camera mode never shows the sample sheet's drawing (it is not the child's print): the
	# camera's picture instead, in its frame
	if sheet.crop_texture == null and ctl.services.mode == "camera" and cams != null and cams.has_feed("overview") \
			and not sheet.showing_photo():
		sheet.crop_texture = cams.texture("overview")
	# #237: the answer check: the very picture read, frozen, with its ○ / ？
	var in_check := ctl.completion_fired and st in StudyModeController.CHECK_STATES
	var img: Image = ctl.services.graded_image
	if in_check and img != null and not img.is_empty():
		if _frozen_src != img:
			_frozen_src = img
			_crop_frozen = ImageTexture.create_from_image(img)
		sheet.crop_texture = _crop_frozen
	# #237: until the sheet is found: where to put it, over the camera's whole picture
	sheet.guide = st == "WAITING_FOR_WORKSHEET"
	sheet.guide_error = ctl.services.watch_problem() if sheet.guide else ""
	if sheet.guide:
		var cam_ok := ctl.services.mode == "camera" and cams != null and cams.has_feed("overview")
		sheet.guide_texture = cams.texture("overview") if cam_ok else null
		var hw := ctl.services.homework
		# #298: the プリント tab's おく場所 (else its 読む範囲, as before)
		sheet.guide_region = SheetFrame.guide_rect(SheetFrame.for_role("overview", hw.sheet_settings_path)) if hw != null else Rect2()
	sheet.scanning = st in ["ANSWER_CHECK_READY", "SHEET_SCANNING", "RESCAN"]
	var looking: bool = st in StudyModeController.HELP_STATES or st == "AI_EXPLAINING"
	sheet.focus_box = ctl.services.located_box if looking else []
	sheet.focus_number = ctl.help_problem
	sheet.mark_boxes = ctl.grading.boxes
	var am := {}
	for n in ctl.shown:
		am[n] = {"verdict": ctl.grading.verdicts.get(n, ""), "t": _mark_t.get(n, 0)}
	sheet.answer_marks = am if ctl.completion_fired else {}
	if in_check:
		sheet.caption = "答え合わせ（AI が 読んだ 画像）" if sheet.crop_texture != null else "答え合わせ"
	elif sheet.crop_texture != null:
		sheet.caption = "カメラ（AI に送る画像）"
	else:
		sheet.caption = "つくえの上（模擬）" if ctl.services.mode == "simulated" else \
			("プリント（カメラ）" if sheet.showing_photo() else "プリント（%s・カメラで探し中）" % ctl.worksheet.get("worksheet_id", ""))
	sheet.visible = st not in ["INTRO", "REWARD_REVEAL", "POWERUP_SELECT", "GAME_READY_WITH_REWARD"] \
		and not (ctl.services.mode == "camera" and sheet.crop_texture == null and not sheet.guide and not sheet.showing_photo())
	sheet.queue_redraw()
	# the round close-up (the mock's drawing; a real focus camera shows in the game's scope)
	var stage := ctl.capture_stage()
	var has_focus: bool = ctl.main != null and ctl.main.cameras != null and ctl.main.cameras.has_feed("focus")
	scope.visible = ctl.wants_scope() and (not has_focus or ctl.services.mode == "simulated")
	scope.stage = stage if stage != "" else "10cm"
	scope.problem = ctl.services.sheet_problem(ctl.help_problem)  # #287: never the sample's text on a real print
	scope.position = Vector2(210.0, EXPLAIN_Y + 10.0)  # under the sheet and the checklist, in the middle
	scope.queue_redraw()
	# banners
	var revealing := st in ["REWARD_REVEAL", "POWERUP_SELECT"]
	var unlocked := st == "GAME_READY_WITH_REWARD"
	_banner.visible = revealing or unlocked
	if unlocked:  # #237: then the score game by itself, a count-down on the button
		_play.text = "  ゲームで遊ぶ ▶ %d  " % ctl.ready_left()
	_banner.text = banner_text(st, ctl.reward)
	# a wide (Japanese) or long banner gets a smaller size: it must fit the narrow screen
	var ascii := _banner.text.to_ascii_buffer().size() == _banner.text.to_utf8_buffer().size()
	_banner.add_theme_font_size_override("font_size", 84 if ascii and _banner.text.length() <= 14 else (60 if ascii else 64))
	_banner.size = Vector2(vs.x, 110)
	_banner.position = Vector2(0, HEADER_H - 10.0)  # under UFOくん
	_banner.pivot_offset = _banner.size * 0.5
	_sub_banner.visible = revealing or unlocked
	_sub_banner.text = reward_text(st, ctl.reward) + ("" if not unlocked or ctl.cleanup_ok or not StudyModeController.cleanup_enabled()
		else "\n（お片付けは大人の人と確認してね）")
	_sub_banner.visible = _sub_banner.visible and st != "POWERUP_SELECT"
	_sub_banner.size = Vector2(vs.x - 40, 220)
	_sub_banner.position = Vector2(20, HEADER_H + 90.0)
	_sub_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_banner.add_theme_font_size_override("font_size", 34)
	_powers.visible = st == "POWERUP_SELECT"
	_powers.position = Vector2(vs.x * 0.5 - 330, HEADER_H + 110.0)  # under the banner, under UFOくん
	for i in _power_buttons.size():
		var chosen: bool = StudyModeController.POWERUPS[i][0] in ctl.selected_powerups
		var lit: bool = chosen or (ctl.roulette_spinning and i == ctl.roulette_index)
		var b: Control = _power_buttons[i]
		(b.get_theme_stylebox("panel") as StyleBoxFlat).border_color = Color("ffe03c") if lit else Color("4a5a78")
		b.modulate = Color("ffe03c") if lit else (Color(0.55, 0.55, 0.65) if not ctl.selected_powerups.is_empty() else Color(0.8, 0.8, 0.9))
		b.scale = Vector2(1.12, 1.12) if lit else Vector2.ONE
		b.pivot_offset = b.size * 0.5
	_play.visible = unlocked
	# under UFOくん wherever the arm holds it (it hangs lower with the real crane): the middle of
	# the screen, where the sheet is when shown (hidden now)
	_play.position = Vector2((vs.x - _play.size.x) * 0.5, PLAY_Y)
	_time_panel.visible = st in ["CLEANUP", "CLEANUP_FAILED"]
	_time_label.text = study_time_text(ctl.elapsed_s())
	_time_panel.position = Vector2(vs.x * 0.5 - 200, EXPLAIN_Y)
	_time_panel.custom_minimum_size = Vector2(400, 0)
	_adult.visible = ctl.adult_prompt != ""
	_adult_text.text = ctl.adult_prompt
	_adult.position = Vector2(40, vs.y - 250 - 190)
	_error.visible = st in ["ERROR"] and ctl.error_text != ""
	_error_text.text = ctl.error_text + "\n（Enter で続ける）"
	_error.position = Vector2(40, vs.y * 0.5)
	_keys.text = key_help(st, ctl.services.mode, "off" if ctl.dialog_needs_thumb and not ctl.dialog_mode else "on")

static func banner_text(st: String, r: Dictionary) -> String:
	if st == "GAME_READY_WITH_REWARD":
		return "STUDY POWER LOADED!"
	if st == "POWERUP_SELECT":
		return "パワールーレット！"
	return "PERFECT!" if bool(r.get("perfect", false)) else "MISSION COMPLETE!"

static func power_name(kind: String) -> String:
	for pw in StudyModeController.POWERUPS:
		if pw[0] == kind:
			return pw[1]
	return kind.to_upper()

## The reward in words: the counts, then what the game gets.
static func reward_text(st: String, r: Dictionary, time_now := -1) -> String:
	if r.is_empty():
		return ""
	# one thing a line (the screen is narrow): the counts, then what the game gets
	var lines: Array[String] = []
	if st != "GAME_READY_WITH_REWARD":
		lines.append("%dもん かくにん" % int(r.get("question_count", 0)))
		var right := "%dもん せいかい" % int(r.get("confirmed_correct", 0))
		var review := (r.get("needs_review", []) as Array).size() + (r.get("unclear", []) as Array).size()
		lines.append(right + ("　%dもん みなおし" % review if review > 0 else ""))
	if int(r.get("time_bonus_s", 0)) > 0:
		lines.append("TIME +%d" % (int(r.time_bonus_s) if time_now < 0 else time_now))
	var chosen: Array = r.get("selected_powerups", [])
	if not chosen.is_empty():
		for k in chosen:
			lines.append("%s READY" % power_name(str(k)))
	elif int(r.get("power_tickets", 0)) > 0:
		lines.append("POWER TICKET ×%d" % int(r.power_tickets))
	return "\n".join(lines)

static func study_time_text(secs: float) -> String:
	var s := int(maxf(secs, 0.0))
	if s >= 3600:
		return "%d時間%d分%d秒" % [s / 3600, (s / 60) % 60, s % 60]
	return "%d分%02d秒" % [s / 60, s % 60]

## `dialog` (#281): "on" (the dialogue mode is on, or not needed), "off" (a thumbs-up enters it)
static func key_help(state: String, mode: String, dialog := "on") -> String:
	var parts := ["Enter 次へ/確認", "指 1・2・3 → いいね 解説（Y も）", "Space 止める"]
	if state == "POWERUP_SELECT":
		parts.append("パワールーレット！")  # #237
	elif state == "REVIEW_SUMMARY":
		parts.append("R もう一度読む")
	elif mode == "simulated":
		parts.append("1/2/3 記入（模擬）")
	elif state in StudyVoice.TALK_STATES and dialog == "on":
		parts.append("V 押して話す")  # #233
	if dialog == "off" and state in StudyModeController.DIALOG_ENTRY_STATES:
		parts.append("👍 3びょう おはなし")  # #281
	# #260: the staff's keys (StaffControl), then the developers' (Shift)
	parts.append_array(["F6 とばす", "F7 ゲームへ", "F8 メニュー", "F9 ふっき", "Shift+F7 失敗注入", "Shift+F8 最初から", "F5 終了"])
	return "  ".join(parts)

## #232: the sheet as it goes to the local LLM server, from the overview camera now and then.
const CROP_EVERY_S := 0.5
const CROP_EDGE := 480
var _crop: ImageTexture
var _crop_left := 0.0

func _crop_wanted() -> bool:
	var hw := ctl.services.homework if ctl.services != null else null
	return ctl.services.mode == "camera" and hw != null and hw.reads_locally()

func _update_crop(dt: float) -> void:
	_crop_left -= dt
	if _crop_left > 0.0 or not _crop_wanted():
		return
	_crop_left = CROP_EVERY_S
	var cams: CameraHub = ctl.main.cameras if ctl.main != null else null
	if cams == null or not cams.has_feed("overview"):
		return
	var img := cams.texture("overview").get_image()
	if img == null or img.is_empty():
		return
	var out := ctl.services.homework.watch_image(img)
	var big := maxi(out.get_width(), out.get_height())
	if big > CROP_EDGE:
		out.resize(maxi(1, out.get_width() * CROP_EDGE / big), maxi(1, out.get_height() * CROP_EDGE / big), Image.INTERPOLATE_BILINEAR)
	if _crop == null or Vector2i(_crop.get_size()) != out.get_size():
		_crop = ImageTexture.create_from_image(out)
	else:
		_crop.update(out)
	sheet.crop_texture = _crop
	sheet.queue_redraw()

func _process(dt: float) -> void:
	if not visible or ctl == null:
		return
	_update_crop(dt)
	if sheet.visible:  # the frame's bulbs, the magnifying glass, the ○ being drawn
		sheet.queue_redraw()
	if _reward_gets_in >= 0.0:
		_reward_gets_in -= dt
		if _reward_gets_in < 0.0 and ctl.state == "REWARD_REVEAL":
			reward_gets(ctl.reward)
	if _get_t >= 0.0:
		_get_t += dt
		if _get_t > GET_S:
			_get_t = -1.0
			if not _get_queue.is_empty():
				var nx: Array = _get_queue.pop_front()
				_start_get(str(nx[0]), str(nx[1]))
	if _get_t >= 0.0 or ctl.state == "GAME_READY_WITH_REWARD":
		_get_fx.queue_redraw()
	# the reward: TIME counts up, a tick a second
	if ctl.state == "REWARD_REVEAL" and _sub_banner.visible:
		var goal := float(ctl.reward.get("time_bonus_s", 0))
		if _time_shown < goal:
			_time_shown = minf(_time_shown + dt * 30.0, goal)
			if int(_time_shown) != _last_tick:
				_last_tick = int(_time_shown)
				ctl.sounds.cue("count")
			_sub_banner.text = reward_text(ctl.state, ctl.reward, int(_time_shown))
	_typed += dt * 28.0
	_bubble_text.visible_characters = -1 if _typed >= _bubble_text.text.length() else int(_typed)
	_timer.text = "べんきょう " + HomeworkClient.format_elapsed(ctl.elapsed_s())
