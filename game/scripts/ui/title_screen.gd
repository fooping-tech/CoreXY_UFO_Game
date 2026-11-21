class_name TitleScreen
extends CanvasLayer
## The first screen (#90): pick the study mode (UFOくん 勉強モード, #86) or the game mode
## (the crane game). Presentation only: it never writes RobotState and never sends a
## command. While it shows, main.gd holds the manual controls (jog keys, gestures, the
## auto catch); Space still stops. Esc in the game / the study mode comes back here.

signal chosen(mode: String)  # "study" or "score" (the game mode = the 150 s score game, #138, #183); "game" for staff
signal settings_requested  # the gear (#93) or S

## what this title offers (#183): the study mode and the game mode. The game mode is the
## score game ("score"); without it (game_mode.enabled false) the plain crane screen ("game").
var choices: Array[String] = ["study", "game"]
## not offered, still accepted: the plain crane screen for staff (G), and the score game by
## its old key (3)
const HIDDEN: Array[String] = ["game", "score"]
const CARD_COLORS := [Color("e07a00"), Color("b0379c"), Color("3b7dd8")]
const UFO_SHEET := "res://assets/ufo/ufo_idle.png"
const UFO_FRAMES := 4
const UFO_FPS := 3.0
const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const INK := Color("1d2433")
const LOGO_FONT := "res://assets/fonts/Orbitron-Variable.ttf"
const LOGO_LINES := ["SUMMON", "THE UFO"]
## a hand picks a mode (#183): one finger = the first, two fingers = the second, held this long
const HAND_HOLD_S := 1.5
const HAND_POSES := {"point": 0, "peace": 1}

var selected := 0
var root: Control
var _cards: Array[PanelContainer] = []
var _card_styles: Array[StyleBoxFlat] = []
var _bars: Array[ProgressBar] = []
var _ufo: TextureRect
var _ufo_atlas: AtlasTexture
var _status: Label
var gear: GearButton
var _notice: Label
var _t := 0.0
var sky: NightSky
## the hand's choice: which card it holds (-1 none), how far (0..1), and whether a hand may
## choose yet (only after it was seen without a choosing shape: the shape that brought the
## player here does not choose again)
var hand_index := -1
var hand_progress := 0.0
var _hand_armed := false

func setup(score_game := false) -> void:
	choices.assign(["study", "score"] if score_game else ["study", "game"])
	layer = 20  # above the study HUD (5) and the debug panel
	root = Control.new()
	root.name = "TitleRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP  # clicks never reach the game behind
	add_child(root)
	# the night: mountains under the stars (drawn; the game behind is not seen)
	sky = NightSky.new()
	sky.name = "NightSky"
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(sky)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(box)

	for line in LOGO_LINES:
		box.add_child(logo_label(line, 104))
	var sub := StudyHud.label("CoreXY UFO キャッチャー", 24, CYAN, 8)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	_ufo_atlas = AtlasTexture.new()
	if ResourceLoader.exists(UFO_SHEET):
		_ufo_atlas.atlas = load(UFO_SHEET)
	_ufo_atlas.region = Rect2(0, 0, 64, 64)
	# the container places the holder; the UFO bobs inside it
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(192, 176)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(holder)
	_ufo = TextureRect.new()
	_ufo.texture = _ufo_atlas
	_ufo.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ufo.size = Vector2(176, 176)
	_ufo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_ufo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ufo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(_ufo)

	# portrait (#157): the modes are cards one under another (↑ ↓ as well as ← → pick one)
	var row := VBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	_add_card(row, 0, "1", "勉強モード", "UFOくんと宿題をしよう\nゆびを 1ぽん みせて えらぶ")
	if score_game:
		_add_card(row, 1, "2", "ゲームモード", "150 秒！ カプセルを Dial に入れて 高得点をねらおう\nゆびを 2ほん みせて えらぶ")
	else:
		_add_card(row, 1, "2", "ゲームモード", "UFO キャッチャーで遊ぼう\nゆびを 2ほん みせて えらぶ")

	var keys := StudyHud.label("ゆび 1ぽん / 2ほん、1 / 2 キー、クリックで えらぶ\nS / 右上の歯車: 設定　Esc: タイトルに戻る　Space: 止める", 18, Color("c8d6f0"), 4)
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	keys.custom_minimum_size = Vector2(640, 0)
	box.add_child(keys)
	_status = StudyHud.label("", 16, Color("8fa3c4"), 3)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY  # a long line wraps inside the screen
	_status.custom_minimum_size = Vector2(640, 0)
	box.add_child(_status)
	_notice = StudyHud.label("", 18, YELLOW, 4)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_notice.custom_minimum_size = Vector2(640, 0)
	box.add_child(_notice)

	# the settings (#93): a gear in the top-right corner
	gear = GearButton.new()
	gear.name = "Gear"
	gear.tooltip_text = "設定（S）"
	gear.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	gear.offset_left = -96
	gear.offset_top = 20
	gear.offset_right = -24
	gear.offset_bottom = 92
	gear.pressed.connect(func(): if visible: settings_requested.emit())
	root.add_child(gear)
	visible = false
	_refresh()

## A line of the logo: the display font (Orbitron Black, OFL), yellow with a dark rim and a
## cyan glow behind. Without the font file: the game's title font.
static func logo_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(LOGO_FONT):
		var f := FontVariation.new()
		f.base_font = load(LOGO_FONT)
		f.variation_opentype = {"wght": 900}
		f.spacing_glyph = 2
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", YELLOW)
	l.add_theme_color_override("font_outline_color", Color("120a3a"))
	l.add_theme_constant_override("outline_size", 14)
	l.add_theme_color_override("font_shadow_color", Color(0.25, 0.9, 1.0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 6)
	l.add_theme_constant_override("shadow_outline_size", 22)
	l.add_theme_constant_override("line_spacing", -10)
	return l

func _add_card(parent: Control, index: int, number: String, heading: String, text: String) -> void:
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(22)
	sb.set_border_width_all(5)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	sb.shadow_color = Color(0, 0, 0, 0.4)
	sb.shadow_size = 8
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(600, 0)
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.mouse_entered.connect(func(): select(index))
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			choose(choices[index]))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var head := StudyHud.label("%s  %s" % [number, heading], 40, Color.WHITE, 8)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(head)
	var body := StudyHud.label(text, 20, Color("e8f0ff"), 4)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	body.custom_minimum_size = Vector2(540, 0)
	v.add_child(body)
	# the hand's hold on this card (#183)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.modulate.a = 0.0
	v.add_child(bar)
	_bars.append(bar)
	parent.add_child(card)
	_cards.append(card)
	_card_styles.append(sb)

# ------------------------------------------------------------------ state
func active() -> bool:
	return visible

func open() -> void:
	visible = true
	_t = 0.0
	hand_index = -1
	hand_progress = 0.0
	_hand_armed = false
	_refresh()

## #183: the hand picks a mode: one finger = the first card, two fingers = the second, held
## HAND_HOLD_S. `hand`: {fresh, detected, pose}. A choosing shape counts only after the hand
## was seen without one (or not seen) since the title opened. Returns the mode chosen ("" none).
func hand_tick(dt: float, hand: Dictionary) -> String:
	if not visible:
		return ""
	var pose := str(hand.get("pose", "")) if bool(hand.get("fresh", false)) and bool(hand.get("detected", false)) else ""
	var index := int(HAND_POSES.get(pose, -1))
	if index >= choices.size():
		index = -1
	if index < 0:
		_hand_armed = true
	if not _hand_armed or index < 0:
		hand_index = -1
		hand_progress = 0.0
		return ""
	if index != hand_index:
		hand_index = index
		hand_progress = 0.0
		select(index)
	hand_progress = minf(hand_progress + dt / HAND_HOLD_S, 1.0)
	if hand_progress >= 1.0:
		var mode := choices[index]
		choose(mode)
		return mode
	return ""

func close() -> void:
	visible = false

func select(index: int) -> void:
	selected = clampi(index, 0, choices.size() - 1)
	_refresh()

func selected_mode() -> String:
	return choices[selected]

func choose(mode: String) -> void:
	if not visible or not (mode in choices or mode in HIDDEN):
		return
	selected = maxi(choices.find(mode), 0)
	close()
	chosen.emit(mode)

## A line under the status (the settings screen's "saved").
func set_notice(text: String) -> void:
	if _notice != null:
		_notice.text = text

func notice() -> String:
	return _notice.text if _notice != null else ""

func set_status(text: String) -> void:
	if _status != null and _status.text != text:
		_status.text = text

## Every key while the title shows ends here (main.gd keeps Space and F1 / Tab):
## true = used or swallowed, so nothing reaches the game behind.
func handle_key(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_UP:
			select(selected - 1)
		KEY_RIGHT, KEY_DOWN:
			select(selected + 1)
		KEY_1, KEY_KP_1, KEY_F5:
			choose("study")
		KEY_2, KEY_KP_2:
			choose(choices[1])
		KEY_3, KEY_KP_3:
			if "score" in choices:
				choose("score")  # the score game's old key
		KEY_G:
			choose("game")  # staff: the plain crane screen (not offered on the cards)
		KEY_ENTER, KEY_KP_ENTER:
			choose(selected_mode())
		KEY_S:
			settings_requested.emit()
	return true

func _refresh() -> void:
	for i in range(_card_styles.size()):
		var on := i == selected
		var sb := _card_styles[i]
		sb.bg_color = CARD_COLORS[i] if on else Color(0.1, 0.13, 0.24, 0.92)
		sb.border_color = YELLOW if on else Color("4a5a78")

func _process(dt: float) -> void:
	if not visible:
		return
	_t += dt
	if _ufo != null:
		_ufo_atlas.region = Rect2(64 * (int(_t * UFO_FPS) % UFO_FRAMES), 0, 64, 64)
		_ufo.position = Vector2(8.0, sin(_t * 2.2) * 6.0)  # a gentle bob inside its holder
	for i in range(_bars.size()):
		_bars[i].value = hand_progress if i == hand_index else 0.0
		_bars[i].modulate.a = 1.0 if i == hand_index else 0.0
	for i in range(_cards.size()):
		var s := 1.0 + (0.035 * (0.5 + 0.5 * sin(_t * 5.0)) if i == selected else 0.0)
		_cards[i].pivot_offset = _cards[i].size * 0.5
		_cards[i].scale = Vector2(s, s)


## The gear icon, drawn (no icon font needed): 8 teeth around a ring.
class GearButton extends Button:
	var _hover := false

	func _init() -> void:
		flat = true
		focus_mode = Control.FOCUS_NONE  # Space stays the stop key
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		custom_minimum_size = Vector2(72, 72)
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		var col := Color("ffe03c") if _hover else Color("c8d6f0")
		draw_circle(c, r * 0.95, Color(0.1, 0.14, 0.25, 0.85))
		for i in range(8):
			var a := TAU * i / 8.0
			var d := Vector2(cos(a), sin(a))
			var n := Vector2(-d.y, d.x)
			var pts := PackedVector2Array([c + d * r * 0.42 + n * r * 0.13, c + d * r * 0.78 + n * r * 0.1,
				c + d * r * 0.78 - n * r * 0.1, c + d * r * 0.42 - n * r * 0.13])
			draw_colored_polygon(pts, col)
		draw_circle(c, r * 0.55, col)
		draw_circle(c, r * 0.24, Color(0.1, 0.14, 0.25, 1.0))


## The title's background (#183): a night sky with stars and a moon over three ranges of
## mountains, drawn (no picture file). The stars twinkle; nothing else moves.
class NightSky extends Control:
	var _t := 0.0
	var _stars: Array = []  # [x 0..1, y 0..1, size, phase]

	func _init() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = 183
		for i in 110:
			_stars.append([rng.randf(), rng.randf() * 0.62, 1.0 + float(rng.randi() % 3), rng.randf() * TAU])

	func _process(dt: float) -> void:
		if is_visible_in_tree():
			_t += dt
			queue_redraw()

	## The ridge of range `layer` (0 far .. 2 near) at x (0..1): its height as a part of the screen.
	static func ridge(layer: int, x: float) -> float:
		var base: float = [0.36, 0.27, 0.17][layer]
		var amp: float = [0.11, 0.09, 0.07][layer]
		var f: float = [2.3, 3.7, 5.1][layer]
		var h := sin(x * f * TAU * 0.5 + layer * 1.7) * 0.5 + sin(x * f * TAU * 1.3 + layer * 4.1) * 0.3 + sin(x * f * TAU * 2.9 + layer) * 0.2
		return base + amp * (0.5 + 0.5 * h) + amp * 0.6 * absf(sin(x * f * PI + layer * 2.3))

	func _draw() -> void:
		var w := size.x
		var h := size.y
		# the sky: deep blue at the top to a glow over the ridges
		var top := Color("03061a")
		var low := Color("2a2f6e")
		var bands := 48
		for i in bands:
			var k := float(i) / (bands - 1)
			draw_rect(Rect2(0, h * 0.8 * i / bands, w, h * 0.8 / bands + 1.0), top.lerp(low, pow(k, 1.6)))
		draw_rect(Rect2(0, h * 0.8, w, h * 0.2), Color("05060f"))
		for s in _stars:
			var tw := 0.55 + 0.45 * sin(_t * 1.7 + float(s[3]))
			var at := Vector2(float(s[0]) * w, float(s[1]) * h).snapped(Vector2(2, 2))
			draw_rect(Rect2(at, Vector2(float(s[2]), float(s[2]))), Color(1, 1, 0.92, tw))
		# the moon, with a soft ring
		var moon := Vector2(w * 0.8, h * 0.13)
		for r in [70.0, 54.0, 44.0]:
			draw_circle(moon, r, Color(1.0, 0.96, 0.75, 0.05))
		draw_circle(moon, 36.0, Color("fff3c4"))
		draw_circle(moon + Vector2(-15, -9), 30.0, Color("0b1036"))  # a crescent
		# three ranges, far (lighter, bluer) to near (almost black)
		var cols := [Color("27306b"), Color("171c47"), Color("090b1f")]
		for layer in 3:
			var pts := PackedVector2Array([Vector2(0, h)])
			var steps := 72
			for i in steps + 1:
				var x := float(i) / steps
				pts.append(Vector2(x * w, h * (1.0 - ridge(layer, x))))
			pts.append(Vector2(w, h))
			draw_colored_polygon(pts, cols[layer])
			if layer == 0:  # the moon's light along the far ridge
				for i in steps:
					draw_line(pts[i + 1], pts[i + 2], Color(0.6, 0.7, 1.0, 0.35), 2.0)
