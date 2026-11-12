class_name TitleScreen
extends CanvasLayer
## The first screen (#90): pick the study mode (UFOくん 勉強モード, #86) or the game mode
## (the crane game). Presentation only: it never writes RobotState and never sends a
## command. While it shows, main.gd holds the manual controls (jog keys, gestures, the
## auto catch); Space still stops. Esc in the game / the study mode comes back here.

signal chosen(mode: String)  # "study" or "game"

const CHOICES: Array[String] = ["study", "game"]
const UFO_SHEET := "res://assets/ufo/ufo_idle.png"
const UFO_FRAMES := 4
const UFO_FPS := 3.0
const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const INK := Color("1d2433")

var selected := 0
var root: Control
var _cards: Array[PanelContainer] = []
var _card_styles: Array[StyleBoxFlat] = []
var _ufo: TextureRect
var _ufo_atlas: AtlasTexture
var _status: Label
var _t := 0.0

func setup() -> void:
	layer = 20  # above the study HUD (5) and the debug panel
	root = Control.new()
	root.name = "TitleRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP  # clicks never reach the game behind
	add_child(root)
	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.06, 0.14, 0.9)  # the game shows faintly behind
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(box)

	var title := StudyHud.label("UFOくん", 96, YELLOW, 18)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := StudyHud.label("CoreXY UFO キャッチャー", 28, CYAN, 8)
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

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 36)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	_add_card(row, 0, "1", "勉強モード", "UFOくんと宿題をしよう\nわからない問題は Y で HELP")
	_add_card(row, 1, "2", "ゲームモード", "UFO キャッチャーで遊ぼう\n（いつものゲーム画面）")

	var keys := StudyHud.label("← → か 1 / 2 で選んで Enter（クリックでも選べる）    Esc: いつでもタイトルに戻る    Space: 止める",
		18, Color("c8d6f0"), 4)
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(keys)
	_status = StudyHud.label("", 16, Color("8fa3c4"), 3)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)
	visible = false
	_refresh()

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
	card.custom_minimum_size = Vector2(330, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.mouse_entered.connect(func(): select(index))
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			choose(CHOICES[index]))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var head := StudyHud.label("%s  %s" % [number, heading], 40, Color.WHITE, 8)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(head)
	var body := StudyHud.label(text, 20, Color("e8f0ff"), 4)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(body)
	parent.add_child(card)
	_cards.append(card)
	_card_styles.append(sb)

# ------------------------------------------------------------------ state
func active() -> bool:
	return visible

func open() -> void:
	visible = true
	_t = 0.0
	_refresh()

func close() -> void:
	visible = false

func select(index: int) -> void:
	selected = clampi(index, 0, CHOICES.size() - 1)
	_refresh()

func selected_mode() -> String:
	return CHOICES[selected]

func choose(mode: String) -> void:
	if not visible or not mode in CHOICES:
		return
	selected = CHOICES.find(mode)
	close()
	chosen.emit(mode)

func set_status(text: String) -> void:
	if _status != null and _status.text != text:
		_status.text = text

## Every key while the title shows ends here (main.gd keeps Space and F1 / Tab):
## true = used or swallowed, so nothing reaches the game behind.
func handle_key(keycode: int) -> bool:
	match keycode:
		KEY_LEFT, KEY_UP:
			select(0)
		KEY_RIGHT, KEY_DOWN:
			select(1)
		KEY_1, KEY_KP_1, KEY_F5:
			choose("study")
		KEY_2, KEY_KP_2:
			choose("game")
		KEY_ENTER, KEY_KP_ENTER:
			choose(selected_mode())
	return true

func _refresh() -> void:
	for i in range(_card_styles.size()):
		var on := i == selected
		var sb := _card_styles[i]
		sb.bg_color = (Color("e07a00") if i == 0 else Color("3b7dd8")) if on else Color("26324a")
		sb.border_color = YELLOW if on else Color("4a5a78")

func _process(dt: float) -> void:
	if not visible:
		return
	_t += dt
	if _ufo != null:
		_ufo_atlas.region = Rect2(64 * (int(_t * UFO_FPS) % UFO_FRAMES), 0, 64, 64)
		_ufo.position = Vector2(8.0, sin(_t * 2.2) * 6.0)  # a gentle bob inside its holder
	for i in range(_cards.size()):
		var s := 1.0 + (0.035 * (0.5 + 0.5 * sin(_t * 5.0)) if i == selected else 0.0)
		_cards[i].pivot_offset = _cards[i].size * 0.5
		_cards[i].scale = Vector2(s, s)
