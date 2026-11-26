class_name PracticeShow
extends Control
## The practice capsule's show (#314): instead of the round's pinball, the capsule the child put
## into the portal falls onto a plain practice board, and UFOくん explains on it, one scene at a
## time:
##
##   kind      the capsule that came in (its colour read by the arm camera), big, named
##   colours   the kinds by colour: red / blue / green / yellow / purple (#320), each a picture
##             and one line, and a "？"
##             card: there are more to come (お楽しみに). The one that came in is lit.
##   switches  a plain board: three switches and three goals. The capsule hops over the
##             switches and lights them one by one: JACKPOT チャンス
##   jackpot   in the chance it drops into the centre goal: JACKPOT +3000. Timing pays.
##
## A scene goes on when its lines are said (speech_busy() false) and it has shown min_s, or
## after max_s anyway. When the last one ends: finished(capsule_id). The controller then
## returns the capsule as after the pinball. Only a picture and words: it never sends anything
## to the Dials or the robot, never touches the round's score (the practice is reset before
## the round), and stop() drops it at once (Space, Esc, the practice left).

signal finished(capsule_id: String)
## the show's own sounds (GameModeSounds keys)
signal sound(key: String)

## the field and the row of its goals under the floor (their 100 / 1000 would read as this board's)
const RECT := Rect2(GameModeLayout.FIELD_LEFT, GameModeLayout.FIELD_TOP,
	GameModeLayout.FIELD_RIGHT - GameModeLayout.FIELD_LEFT, GameModeLayout.FIELD_FLOOR - GameModeLayout.FIELD_TOP + 64.0)
const BG := Color(0.03, 0.04, 0.13)
const INK := Color("e8f0ff")
const MUTED := Color("8fa3c4")
const YELLOW := Color("ffe03c")
const CYAN := Color("7ae0ff")
const MAGENTA := Color("ff4fd8")
const NORMAL_COLOR := Color("dfe6ff")
## the scenes in order: id, min_s, max_s
const SCENES := [["kind", 3.0, 12.0], ["colours", 5.0, 18.0], ["switches", 4.5, 16.0], ["jackpot", 4.0, 16.0]]
## the cards of the colours scene, top to bottom ("more": the "？" card)
const CARDS := ["fire", "water", "green", "thunder", "dark", "more"]
## where the cards stand (#320: six of them fit the board's 778 px)
const CARD_TOP := 160.0
const CARD_STEP := 100.0
const CARD_H := 90.0
const CARD_BALL := 56.0
## the plain board (design coordinates, inside RECT)
const SWITCH_Y := 640.0
const SWITCH_X := [200.0, 360.0, 520.0]
const GOAL_Y := 1010.0
const GOAL_X := [150.0, 360.0, 570.0]
const START := Vector2(360, 470)
const HOP_S := 0.7
const JACKPOT_POINTS := 3000
const CHANCE_S := 20  # what the round's chance lasts (ScoreManager.jackpot_s), as said on the board

var capsule_id := ""
var kind := "normal"
## the scene shown now ("" = not running) and how long it has been shown
var scene := ""
var scene_t := 0.0
## true while UFOくん speaks (the controller's speech): a scene waits for its lines
var speech_busy: Callable = func() -> bool: return false
## say(lines): the controller's voice (UFOくん)
var say: Callable = func(_lines: Array) -> void: pass
## seconds each scene may run, by id (config game_mode.tutorial.practice_show)
var min_s := {}
var max_s := {}
## the board: switches lit, the capsule's place, the jackpot shown
var lit: Array[bool] = [false, false, false]
var ball := START
var jackpot_shown := false
## scenes shown (tests)
var shown: Array[String] = []

var _title: Label
var _sub: Label
var _cards: Array[Control] = []
var _dots: Array[CapsuleDot] = []
var _index := -1
var _hop_t := 0.0

func _ready() -> void:
	position = RECT.position
	size = RECT.size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # the capsules' pixel art
	_title = StudyHud.label("", 40, YELLOW, 6)
	_sub = StudyHud.label("", 24, INK, 4)
	for l in [_title, _sub]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size = Vector2(RECT.size.x - 40.0, 0)
		l.position = Vector2(20, 0)
		add_child(l)
	_title.position.y = 24.0
	_sub.position.y = 86.0
	for k in CARDS:
		var card := _card(k)
		_cards.append(card)
		add_child(card)
	for s in SCENES:
		min_s[s[0]] = float(s[1])
		max_s[s[0]] = float(s[2])
	visible = false

func configure(cfg: Dictionary) -> void:
	for s in SCENES:
		var c = cfg.get(str(s[0]))
		if c is Dictionary:
			min_s[s[0]] = clampf(float(c.get("min_s", min_s[s[0]])), 0.0, 60.0)
			max_s[s[0]] = clampf(float(c.get("max_s", max_s[s[0]])), float(min_s[s[0]]), 120.0)

func active() -> bool:
	return scene != ""

## The practice capsule `id` of `k` (CapsuleKinds) came onto the screen: the show begins.
func begin(id: String, k: String) -> void:
	capsule_id = id
	kind = k if k in CapsuleKinds.KINDS else "normal"
	lit = [false, false, false]
	ball = START
	jackpot_shown = false
	shown.clear()
	_index = -1
	visible = true
	_next()

## Gone at once (Space, Esc, the practice left): nothing is finished.
func stop() -> void:
	scene = ""
	_index = -1
	visible = false

func tick(dt: float) -> void:
	if scene == "":
		return
	scene_t += dt
	_animate(dt)
	queue_redraw()
	if scene == "colours":
		for dot in _dots:
			dot.t = scene_t
			dot.queue_redraw()
	var done_min: bool = scene_t >= float(min_s.get(scene, 3.0)) and not bool(speech_busy.call())
	if (done_min and _scene_settled()) or scene_t >= float(max_s.get(scene, 15.0)):
		_next()

## The board's moves are over (a scene does not end with the capsule in the air).
func _scene_settled() -> bool:
	match scene:
		"switches":
			return lit.all(func(b): return b)
		"jackpot":
			return jackpot_shown
	return true

func _next() -> void:
	_index += 1
	if _index >= SCENES.size():
		var id := capsule_id
		stop()
		finished.emit(id)
		return
	scene = str(SCENES[_index][0])
	scene_t = 0.0
	_hop_t = 0.0
	shown.append(scene)
	var name := str(CapsuleKinds.NAMES.get(kind, "カプセル"))
	match scene:
		"kind":
			_title.text = ("%s！" % name) if kind != "normal" else "カプセル ゲット！"
			_sub.text = str(CapsuleKinds.TRAITS.get(kind, "ポータルから がめんに すいこまれたよ"))
			say.call([("%sを いれたね！" % name) if kind != "normal" else "カプセルが、がめんに はいったよ！"])
			sound.emit("reveal" if kind == "normal" else "reveal_" + kind)
		"colours":
			_title.text = "いろで こうかが かわる！"
			_sub.text = "カプセルの いろで うごきや とくてんが かわるよ"
			say.call(["カプセルの いろで、うごきや とくてんが かわるよ！", "ほかにも、いろんな カプセルが あるよ。おたのしみに！"])
		"switches":
			_title.text = "スイッチを 3つ つけると…"
			_sub.text = "JACKPOT チャンス！"
			say.call(["スイッチを みっつ つけると、ジャックポット チャンス！"])
		"jackpot":
			_title.text = "まんなかの ゴールへ！"
			_sub.text = "%d びょうの あいだ まんなかの ゴールが %d てん！ タイミングよく いれよう" % [CHANCE_S, JACKPOT_POINTS]
			say.call(["チャンスの あいだに、まんなかの ゴールに はいると、%dてん！" % JACKPOT_POINTS, "タイミングよく いれて、こうとくてんを ねらおう！"])
	_sub.position.y = _title.position.y + _title.get_combined_minimum_size().y + 4.0  # under the title, however it wraps
	for i in _cards.size():
		_cards[i].visible = scene == "colours"
		var k: String = CARDS[i]
		(_cards[i] as Control).modulate = Color(1, 1, 1, 1) if (k == kind or kind == "normal" or k == "more") else Color(1, 1, 1, 0.55)

## The capsule on the board: from the top over the three switches, then into the centre goal.
func _animate(dt: float) -> void:
	if scene == "switches":
		_hop_t += dt
		var path := [START] + SWITCH_X.map(func(x): return Vector2(x, SWITCH_Y - 26.0))
		var i := mini(int(_hop_t / HOP_S), path.size() - 1)
		for n in mini(i, 3):
			if not lit[n]:
				lit[n] = true
				sound.emit("switch" if n < 2 else "bonus")
		if i < path.size() - 1:
			ball = _arc(path[i], path[i + 1], fmod(_hop_t, HOP_S) / HOP_S)
		else:
			ball = path[-1]
	elif scene == "jackpot":
		_hop_t += dt
		var from := Vector2(SWITCH_X[2], SWITCH_Y - 26.0)
		var to := Vector2(GOAL_X[1], GOAL_Y - 10.0)
		var f := clampf((_hop_t - 0.6) / 1.2, 0.0, 1.0)  # a moment in the chance, then down
		ball = _arc(from, to, f) if f < 1.0 else to
		if f >= 1.0 and not jackpot_shown:
			jackpot_shown = true
			sound.emit("jackpot")

static func _arc(a: Vector2, b: Vector2, f: float) -> Vector2:
	var p := a.lerp(b, f)
	p.y -= sin(f * PI) * 70.0
	return p

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_rect(Rect2(Vector2.ZERO, size), Color(CYAN, 0.6), false, 3.0)
	var col := color_of(kind)
	var o := -position  # design coordinates -> this control's
	match scene:
		"kind":
			var c := Vector2(size.x * 0.5, 360.0)
			var pulse := 0.5 + 0.5 * sin(scene_t * 4.0)
			draw_circle(c, 120.0 + pulse * 10.0, Color(col, 0.18))
			_capsule(c, 70.0, kind, scene_t)
			for i in 8:  # sparkles round it
				var a := scene_t * 0.9 + TAU * i / 8.0
				var q := c + Vector2(cos(a), sin(a)) * 170.0
				draw_rect(Rect2(q - Vector2(4, 4), Vector2(8, 8)), Color(1, 1, 0.7, pulse))
		"switches", "jackpot":
			var chance := lit.all(func(b): return b)
			for i in 3:
				var p: Vector2 = Vector2(SWITCH_X[i], SWITCH_Y) + o
				draw_rect(Rect2(p - Vector2(30, 10), Vector2(60, 20)), YELLOW if lit[i] else Color(0.25, 0.28, 0.45))
				draw_rect(Rect2(p - Vector2(30, 10), Vector2(60, 20)), Color.WHITE, false, 2.0)
			var lamps := "LAMPS %d / 3" % lit.count(true)
			_text(lamps, Vector2(size.x * 0.5, SWITCH_Y + 60.0 + o.y), 28, YELLOW if chance else MUTED)
			if chance:
				var blink := 0.5 + 0.5 * sin(scene_t * 8.0)
				_text("JACKPOT チャンス！", Vector2(size.x * 0.5, SWITCH_Y + 130.0 + o.y), 40, YELLOW.lerp(Color.WHITE, blink))
			# the goals: the centre one pays the jackpot in the chance
			for i in 3:
				var g: Vector2 = Vector2(GOAL_X[i], GOAL_Y) + o
				var centre := i == 1
				var gc := (YELLOW if chance else CYAN) if centre else MUTED
				draw_rect(Rect2(g - Vector2(70, 0), Vector2(140, 40)), Color(gc, 0.25))
				draw_rect(Rect2(g - Vector2(70, 0), Vector2(140, 40)), gc, false, 3.0)
				var pts := (str(JACKPOT_POINTS) if chance else "1000") if centre else "100"
				_text(pts, g + Vector2(0, 58), 26, gc)
			_capsule(ball + o, 18.0, kind, scene_t)
			if jackpot_shown:
				var t := clampf(scene_t, 0.0, 3.0)
				_text("JACKPOT +%d" % JACKPOT_POINTS, Vector2(size.x * 0.5, GOAL_Y - 130.0 + o.y - t * 8.0), 54, YELLOW)

## A capsule of radius `r`: the kind's own animated sprite, the same one the field draws
## (CapsuleKinds.draw, #266), or a plain ball for normal / a missing sprite.
func _capsule(c: Vector2, r: float, k: String, t: float) -> void:
	draw_capsule(self, c, r, k, t)

static func draw_capsule(ci: CanvasItem, c: Vector2, r: float, k: String, t: float) -> void:
	if CapsuleKinds.draw(ci, k, c, r / (PinballField.CAPSULE_R + 1.0), t, 0.0, false):
		return
	ci.draw_circle(c, r + 3.0, Color(0.02, 0.02, 0.08))
	ci.draw_circle(c, r, color_of(k))
	ci.draw_circle(c + Vector2(-r * 0.35, -r * 0.35), r * 0.3, Color(1, 1, 1, 0.7))

func _text(t: String, centre: Vector2, fsize: int, col: Color) -> void:
	var font := get_theme_default_font()
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var pos := centre - Vector2(w * 0.5, -fsize * 0.35)
	draw_string_outline(font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, 6, Color(0.02, 0.02, 0.08))
	draw_string(font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, col)

static func color_of(k: String) -> Color:
	return CapsuleKinds.COLORS.get(k, NORMAL_COLOR)

## A card of the colours scene: the capsule, its name, its line ("more": a "？", お楽しみに).
func _card(k: String) -> Control:
	var more := k == "more"
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.25, 0.95)
	sb.border_color = MAGENTA if more else color_of(k)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	card.add_child(row)
	var ball: Control
	if more:
		var q := Label.new()
		q.text = "？"
		q.add_theme_font_size_override("font_size", 52)
		q.add_theme_color_override("font_color", MAGENTA)
		q.custom_minimum_size = Vector2(CARD_BALL, CARD_BALL)
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ball = q
	else:
		var dot := CapsuleDot.new()
		dot.kind = k
		_dots.append(dot)
		dot.custom_minimum_size = Vector2(CARD_BALL, CARD_BALL)
		ball = dot
	row.add_child(ball)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(words)
	var name := StudyHud.label("ほかにも いろんな カプセルが あるよ" if more else str(CapsuleKinds.NAMES.get(k, k)), 22, INK, 3)
	var line := StudyHud.label("おたのしみに！" if more else str(CapsuleKinds.TRAITS.get(k, "")), 18, YELLOW if more else color_of(k).lerp(Color.WHITE, 0.4), 3)
	for l in [name, line]:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(440, 0)
		words.add_child(l)
	card.position = Vector2(40, CARD_TOP + _cards.size() * CARD_STEP)
	card.size = Vector2(RECT.size.x - 80.0, CARD_H)
	card.visible = false
	return card

## The capsule drawn on a card: its kind's sprite, animated by `t`.
class CapsuleDot extends Control:
	var kind := "normal"
	var t := 0.0
	func _draw() -> void:
		PracticeShow.draw_capsule(self, size * 0.5, minf(size.x, size.y) * 0.38, kind, t)
