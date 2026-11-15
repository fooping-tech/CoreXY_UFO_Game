class_name GameModeHud
extends Control
## The game mode's HUD (#138, restyled in #141): the score panel (top left), the clock
## panel (top right), what each Dial's port is doing (bottom corners), the countdown, the
## result, and the score game's own title screen while it waits for Enter (the logo, UFOくん,
## START, how to play). During play there is no big title: the field is the picture.
## It only reads the controller.

const YELLOW := Color("ffe03c")
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")
const PURPLE := Color("8a5cff")
const RED := Color("ff6b6b")
const DARK := Color("050818")
const PANEL := Color(0.03, 0.05, 0.16, 0.92)
const UFO_SHEET := "res://assets/ufo/ufo_idle.png"
const LOGO := "SUMMON THE UFO"
const SCORE_RECT := Rect2(8, 6, 164, 62)
const TIME_RECT := Rect2(1108, 6, 164, 62)
const HOW_TO := ["クレーンで\nカプセルをつかむ", "左か右の Dial に\n入れる", "ピンボールで\n高得点をねらおう！"]

var ctl: GameModeController
var art: Control
var _combo: Label
var _centre: Label
var _message: Label
var _lane: Dictionary = {}  # side -> Label
var _result: PanelContainer
var _result_text: Label
var _hint: Label
var _problem: Label
var _start: Label
var _how: Array[Label] = []
var _shown_score := 0.0
var _ufo_tex: Texture2D
var _t := 0.0

func setup(c: GameModeController) -> void:
	ctl = c
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 20  # over the effect sheets and the UFO of the field (z 6 / 7)
	if ResourceLoader.exists(UFO_SHEET):
		_ufo_tex = load(UFO_SHEET)
	# the drawn parts (panels, pixel numbers, the title screen) under the labels
	art = Control.new()
	art.name = "Art"
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	art.draw.connect(_draw_art)
	add_child(art)
	_combo = _label("", 14, YELLOW, Vector2(1100, 70), Vector2(172, 24))  # under the clock
	_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_centre = _label("", 120, YELLOW, Vector2(240, 230), Vector2(800, 150))
	_centre.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message = _label("", 22, Color("e8f0ff"), Vector2(140, 386), Vector2(1000, 70))
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for side in GameModeController.SIDES:
		var l := _label("", 15, Color.WHITE, Vector2(4 if side == "left" else 1138, 520), Vector2(138, 86))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		_lane[side] = l
	_hint = _label("", 13, Color("8fa3c4"), Vector2(390, 2), Vector2(500, 20))  # above the UFO's rail
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# why the hub does not answer (another system's hub, no port...): over the top of the field
	_problem = _label("", 18, Color("ffd24a"), Vector2(170, 150), Vector2(940, 60))
	_problem.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_problem.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	# the title screen's words (Japanese: the game's normal font)
	_start = _label("Enter でスタート", 30, Color.WHITE, Vector2(340, 474), Vector2(600, 44))
	_start.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for i in HOW_TO.size():
		var h := _label(HOW_TO[i], 18, Color("e8f0ff"), Vector2(title_card(i).position.x + 76.0, title_card(i).position.y + 12.0), Vector2(170, 60))
		h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_how.append(h)
	_result = StudyHud.panel(Color(0.04, 0.06, 0.2, 0.95), YELLOW, 14, 4)
	_result.position = Vector2(340, 150)
	_result.custom_minimum_size = Vector2(600, 330)
	_result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_text = StudyHud.label("", 26, Color.WHITE, 4)
	_result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result.add_child(_result_text)
	add_child(_result)
	_result.visible = false

func _label(text: String, size: int, color: Color, pos: Vector2, box: Vector2) -> Label:
	var l := StudyHud.label(text, size, color, maxi(size / 6, 3))
	l.add_theme_color_override("font_outline_color", DARK)
	l.position = pos
	l.size = box
	add_child(l)
	return l

static func clock_text(seconds: float) -> String:
	var s := int(ceil(maxf(seconds, 0.0)))
	return "%d:%02d" % [s / 60, s % 60]

## The title screen shows: the round has not started (and is not a result or a stop).
func title_showing() -> bool:
	return ctl != null and ctl.active() and ctl.phase == "IDLE"

## Where the three "how to play" cards sit on the title screen.
static func title_card(i: int) -> Rect2:
	return Rect2(160.0 + 330.0 * i, 560.0, 300.0, 84.0)

## What keeps the Dials away, said on the screen ("" when the hub answers).
func problem_text() -> String:
	if ctl.devices == null or ctl.devices.available():
		return ""
	var why := ctl.devices.problem()
	return "周辺機器のハブにつながっていない\n" + (why if why != "" else "（理由を問い合わせ中）")

## The result screen's lines (also read by the tests).
func result_lines() -> String:
	var s := ctl.score
	var lines := ["RESULT", "", "スコア  %d" % s.score, "カプセル  %d こ    最大コンボ  %d    ジャックポット  %d" % [
		ctl.capsules.finished.size(), s.best_chain, s.jackpots]]
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		if l.state == "FAULT":
			lines.append("%s の Dial: %s" % ["左" if side == "left" else "右", l.fault])
	return "\n".join(lines)

## The colour of the clock: white, yellow for the last stretch, blinking red at the end.
func clock_color() -> Color:
	if ctl.phase == "PLAYING" and ctl.time_left <= ctl.warning_s:
		return RED if int(ctl.time_left * 4.0) % 2 == 0 else Color.WHITE
	if ctl.phase == "PLAYING" and ctl.time_left <= ctl.hurry_s:
		return YELLOW
	return Color.WHITE

func _process(dt: float) -> void:
	if ctl == null or not ctl.active():
		return
	_t += dt
	art.queue_redraw()
	_shown_score = move_toward(_shown_score, float(ctl.score.score), maxf(absf(ctl.score.score - _shown_score) * 8.0, 200.0) * dt)
	_combo.text = "JACKPOT チャンス！" if ctl.score.jackpot_armed(ctl.clock) else ""
	_combo.modulate.a = 0.6 + 0.4 * sin(_t * 8.0)
	var title := title_showing()
	var centre := ""
	match ctl.phase:
		"COUNTDOWN":
			centre = str(int(ceil(ctl.countdown_left)))
		"PLAYING":
			if ctl.duration_s - ctl.time_left < 0.8:
				centre = "GO!"
			elif ctl.time_left <= ctl.hurry_s and ctl.time_left > ctl.hurry_s - 1.5:
				centre = "あと %d 秒！" % int(ctl.hurry_s)
		"SETTLING":
			centre = "TIME UP"
		"STOPPED":
			centre = "STOP"
	_centre.text = centre
	_centre.add_theme_font_size_override("font_size", 72 if centre.length() > 4 else 120)
	_message.text = ctl.message if ctl.phase == "STOPPED" else ""
	_start.visible = title
	_start.modulate.a = 0.8 + 0.2 * sin(_t * 5.0)  # START breathes
	_start.scale = Vector2.ONE * (1.0 + 0.04 * sin(_t * 5.0))
	_start.pivot_offset = _start.size * 0.5
	for h in _how:
		h.visible = title
	_result.visible = ctl.phase == "RESULT"
	if _result.visible:
		_result_text.text = result_lines() + "\n\n" + ctl.message
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		_lane[side].visible = not title
		_lane[side].text = ctl.lane_text(side)
		_lane[side].add_theme_color_override("font_color", RED if l.state == "FAULT" else l.color)
	var hint := "Space: 止める   Esc: タイトル"
	if ctl.devices != null and ctl.devices.can_mock_ball():
		hint += "   Mock: Z = 左 / M = 右に入れる"
	_hint.text = hint
	_problem.text = problem_text()
	_problem.position.y = 420.0 if title else 150.0

# ------------------------------------------------------------------ drawing
func _draw_art() -> void:
	if ctl == null or not ctl.active():
		return
	if title_showing():
		_draw_title()
	# the score (top left) and the clock (top right): narrow, so the UFO's rail between them is clear
	var rising := float(ctl.score.score) - _shown_score > 0.5
	_panel(SCORE_RECT, YELLOW.lerp(Color.WHITE, 0.6) if rising else YELLOW)
	PixelText.draw(art, "SCORE", SCORE_RECT.position + Vector2(10, 8), 2.0, YELLOW)
	var st := "%d" % int(round(_shown_score))
	PixelText.draw_right(art, st, Vector2(SCORE_RECT.end.x - 10.0, 32.0 - (2.0 if rising else 0.0)), 4.0 if st.length() <= 6 else 2.0,
		YELLOW if rising else Color.WHITE, DARK)
	var cc := clock_color()
	_panel(TIME_RECT, cc if cc != Color.WHITE else CYAN)
	PixelText.draw(art, "TIME", TIME_RECT.position + Vector2(10, 8), 2.0, CYAN)
	PixelText.draw_right(art, clock_text(ctl.time_left), Vector2(TIME_RECT.end.x - 10.0, 32), 4.0, cc, DARK)
	# the combo, under the score: the chain, the multiplier and how long it still holds
	var chain := ctl.score.chain_now(ctl.clock)
	if chain >= 2 and ctl.phase == "PLAYING":
		var col: Color = GameModeVFX.BANNER_COLORS[ctl.combo_level()]
		PixelText.draw(art, "COMBO %d" % chain, Vector2(12, 74), 2.0, col, DARK)
		PixelText.draw_right(art, "x%s" % str(ctl.score.multiplier(ctl.clock)), Vector2(168, 74), 2.0, Color.WHITE, DARK)
		art.draw_rect(Rect2(10, 90, 160, 6), DARK)
		art.draw_rect(Rect2(12, 92, snappedf(156.0 * ctl.score.chain_left_k(ctl.clock), 2.0), 2), col)

## An arcade panel: dark glass, a neon rim, a shine along the top.
func _panel(r: Rect2, col: Color) -> void:
	PinballField.glow_rect(art, r, col, 0.5)
	art.draw_rect(r.grow(3.0), DARK)
	art.draw_rect(r, PANEL)
	art.draw_rect(r, col, false, 2.0)
	art.draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8.0, 2)), Color(1, 1, 1, 0.18))
	for c in [r.position, r.position + Vector2(r.size.x - 6.0, 0), r.position + Vector2(0, r.size.y - 6.0), r.end - Vector2(6, 6)]:
		art.draw_rect(Rect2(c, Vector2(6, 6)), col)

## The score game's title screen: the field dimmed, the logo, UFOくん, how to play.
func _draw_title() -> void:
	art.draw_rect(Rect2(0, 96, 1280, 624), Color(0.01, 0.02, 0.1, 0.8))
	# the logo: a magenta shadow, a cyan rim, yellow letters with a shine passing over
	var scale := 8.0
	var w := PixelText.width(LOGO, scale)
	var pos := Vector2((1280.0 - w) * 0.5, 126.0 + sin(_t * 1.6) * 3.0).snapped(Vector2(1, 1))
	PinballField.glow_rect(art, Rect2(pos - Vector2(20, 14), Vector2(w + 40.0, PixelText.height(scale) + 28.0)), PURPLE, 0.7)
	PixelText.draw(art, LOGO, pos + Vector2(6, 6), scale, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
	PixelText.draw(art, LOGO, pos, scale, YELLOW, DARK)
	var shine := fposmod(_t * 420.0, w + 500.0) - 120.0
	for i in LOGO.length():  # the letters under the passing shine turn white
		var lx := i * (PixelText.W + PixelText.GAP) * scale
		if absf(lx - shine) < 70.0 and LOGO[i] != " ":
			PixelText.draw(art, LOGO[i], pos + Vector2(lx, 0), scale, Color(1, 1, 1, 0.85 - absf(lx - shine) / 90.0))
	art.draw_rect(Rect2(pos.x, pos.y + PixelText.height(scale) + 12.0, w, 4), CYAN)
	art.draw_rect(Rect2(pos.x + 40.0, pos.y + PixelText.height(scale) + 20.0, w - 80.0, 2), MAGENTA)
	# UFOくん, big, bobbing, with a beam under it
	var c := Vector2(640, 330 + sin(_t * 2.2) * 8.0)
	var beam := PackedVector2Array([c + Vector2(-34, 60), c + Vector2(34, 60), Vector2(760, 470), Vector2(520, 470)])
	art.draw_colored_polygon(beam, Color(CYAN.r, CYAN.g, CYAN.b, 0.1 + 0.05 * sin(_t * 4.0)))
	if _ufo_tex != null:
		var size := Vector2(64, 64) * 4.0
		art.draw_texture_rect_region(_ufo_tex, Rect2((c - size * 0.5).snapped(Vector2(1, 1)), size), Rect2(64 * (int(_t * 3.0) % 4), 0, 64, 64))
	for i in 6:  # sparkles round it
		var a := _t * 0.8 + TAU * i / 6.0
		var q := c + Vector2(cos(a) * 190.0, sin(a) * 70.0)
		var tw := 0.5 + 0.5 * sin(_t * 5.0 + i)
		art.draw_rect(Rect2((q - Vector2(3, 3)).snapped(Vector2(2, 2)), Vector2(6, 6)), Color(1, 1, 0.7, tw))
		art.draw_rect(Rect2((q - Vector2(9, 1)).snapped(Vector2(2, 2)), Vector2(18, 2)), Color(1, 1, 0.7, tw * 0.5))
		art.draw_rect(Rect2((q - Vector2(1, 9)).snapped(Vector2(2, 2)), Vector2(2, 18)), Color(1, 1, 0.7, tw * 0.5))
	# START
	var sr := Rect2(440, 468, 400, 54)
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	PinballField.glow_rect(art, sr, YELLOW, 0.4 + 0.6 * pulse)
	art.draw_rect(sr.grow(3.0), DARK)
	art.draw_rect(sr, Color(0.12, 0.1, 0.32, 0.95))
	art.draw_rect(sr, YELLOW.lerp(Color.WHITE, pulse * 0.5), false, 3.0)
	for side in [-1, 1]:  # arrows pointing at it
		for d in 3:
			var ax: float = 640.0 + side * (232.0 + d * 14.0 + pulse * 6.0)
			for st in 5:
				art.draw_rect(Rect2(ax - side * st * 2.0, 495.0 - 8.0 + st * 2.0, 2, 2), Color(1, 1, 1, 0.9 - 0.25 * d))
				art.draw_rect(Rect2(ax - side * st * 2.0, 495.0 + 8.0 - st * 2.0, 2, 2), Color(1, 1, 1, 0.9 - 0.25 * d))
	# how to play: three cards, 1 -> 2 -> 3
	var cols := [CYAN, MAGENTA, YELLOW]
	for i in 3:
		var r := title_card(i)
		art.draw_rect(r.grow(3.0), DARK)
		art.draw_rect(r, PANEL)
		art.draw_rect(r, cols[i], false, 2.0)
		var badge := Rect2(r.position + Vector2(10, 10), Vector2(26, 26))
		art.draw_rect(badge, cols[i])
		PixelText.draw_centered(art, str(i + 1), badge.get_center(), 2.0, DARK)
		var ic := r.position + Vector2(52, 52)
		match i:
			0:  # a claw over a capsule
				art.draw_rect(Rect2(ic.x - 2.0, ic.y - 30.0, 4, 14), Color("c8d6ff"))
				art.draw_line(ic + Vector2(0, -16), ic + Vector2(-12, -2), Color("c8d6ff"), 3.0)
				art.draw_line(ic + Vector2(0, -16), ic + Vector2(12, -2), Color("c8d6ff"), 3.0)
				PinballField.draw_capsule_at(art, ic + Vector2(0, 8), 0.3, CYAN, 0.8)
			1:  # a capsule going into a Dial
				art.draw_circle(ic + Vector2(8, 8), 15.0, DARK)
				art.draw_arc(ic + Vector2(8, 8), 13.0, 0, TAU, 20, MAGENTA, 3.0)
				PinballField.draw_capsule_at(art, ic + Vector2(-10.0 + fmod(_t * 14.0, 14.0), -12.0 + fmod(_t * 14.0, 14.0)), _t * 3.0, MAGENTA, 0.6)
			2:  # a star and points
				var pts := PackedVector2Array()
				for j in 10:
					var a := -PI * 0.5 + TAU * j / 10.0 + _t
					pts.append(ic + Vector2(0, 4) + Vector2(cos(a), sin(a)) * (16.0 if j % 2 == 0 else 7.0))
				art.draw_colored_polygon(pts, YELLOW)
		if i < 2:  # the arrow to the next card
			var ax := r.end.x + 8.0
			for st in 5:
				art.draw_rect(Rect2(ax + st * 2.0, r.get_center().y - 8.0 + st * 2.0, 2, 2), Color.WHITE)
				art.draw_rect(Rect2(ax + st * 2.0, r.get_center().y + 8.0 - st * 2.0, 2, 2), Color.WHITE)
