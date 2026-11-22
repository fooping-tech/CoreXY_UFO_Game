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
## the portrait layout (#157): every position of the HUD comes from GameModeLayout
const SCREEN := GameModeLayout.SCREEN
const SCORE_RECT := GameModeLayout.SCORE_RECT
const TIME_RECT := GameModeLayout.TIME_RECT
const HOW_TO := ["クレーンで カプセルをつかむ", "左の ポータル（Dial）に 入れる", "ピンボールで 高得点をねらおう！"]
## the easy mode's three cards (#169): what the hand does there, each with its hand
const HOW_TO_EASY := ["つまんで うごかす → グーで じどうキャッチ", "つかんだら じどうで ひだりの ポータルへ はこぶ", "ピンボールで 高得点をねらおう！"]
## the difficulty's line on the title, over START
const MODE_RECT := Rect2(40, 712, 640, 82)
## the title screen, down the screen: the logo on two lines, UFOくん, START, three cards
const LOGO_LINES := ["SUMMON", "THE UFO"]
const LOGO_Y := 158.0
const TITLE_UFO_Y := 560.0
const START_RECT := Rect2(120, 800, 480, 68)
const CARDS_Y := 920.0
const CARD_SIZE := Vector2(620, 104)
const CARD_STEP := 116.0

var ctl: GameModeController
var art: Control
var _combo: Label
var _centre: Label
var _message: Label
var _lane: Dictionary = {}  # side -> Label
var _hint: Label
var _problem: Label
var _start: Label
var _rank_hint: Label
var _mode: Label
## the arm needs a person (an alarm, no homing): what it is, and the button that recovers it (#179)
var _recover: Label
var _recover_button: Button
const RECOVER_RECT := Rect2(60, 600, 600, 150)
var _how: Array[Label] = []
var _shown_score := 0.0
var _ufo_tex: Texture2D
var _t := 0.0

func setup(c: GameModeController) -> void:
	ctl = c
	# a fixed size (the design space): under a CanvasLayer the full-rect anchors left it at
	# 0 x 0, and a drawing with no area drops out of the picture for a frame when the layer shakes
	size = SCREEN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 20  # over the effect sheets and the UFO of the field (z 6 / 7)
	if ResourceLoader.exists(UFO_SHEET):
		_ufo_tex = load(UFO_SHEET)
	# the drawn parts (panels, pixel numbers, the title screen) under the labels
	art = Control.new()
	art.name = "Art"
	art.size = SCREEN
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	art.draw.connect(_draw_art)
	add_child(art)
	_combo = _label("", 16, YELLOW, Vector2(GameModeLayout.COMBO_RECT.position.x, GameModeLayout.COMBO_RECT.end.y - 24.0), Vector2(GameModeLayout.COMBO_RECT.size.x, 24))
	_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# the countdown, GO!, STOP: over the middle of the field
	_centre = _label("", 160, YELLOW, Vector2(0, GameModeLayout.CENTRE.y - 120.0), Vector2(GameModeLayout.SCREEN.x, 240))
	_centre.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_centre.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message = _label("", 24, Color("e8f0ff"), Vector2(40, GameModeLayout.CENTRE.y + 130.0), Vector2(GameModeLayout.SCREEN.x - 80.0, 170))
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	for side in GameModeController.SIDES:
		# what the Dial is doing: over its port (bottom left)
		var left: bool = side == "left"
		var l := _label("", 20, Color.WHITE, Vector2(8.0 if left else GameModeLayout.SCREEN.x - 8.0 - 344.0, GameModeLayout.LANE_LABEL_Y - 56.0), Vector2(344, 100))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if left else HORIZONTAL_ALIGNMENT_RIGHT
		l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		_lane[side] = l
	_hint = _label("", 12, Color("8fa3c4"), Vector2(0, GameModeLayout.HINT_Y - 2.0), Vector2(GameModeLayout.SCREEN.x, 16))  # under the score and the clock
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# why the hub does not answer (another system's hub, no port...): over the top of the field
	_problem = _label("", 20, Color("ffd24a"), Vector2(40, GameModeLayout.FIELD_TOP + 70.0), Vector2(GameModeLayout.SCREEN.x - 80.0, 90))
	_problem.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_problem.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	# the title screen's words (Japanese: the game's normal font)
	_rank_hint = _label("R：ランキング", 20, Color("b8f4ff"), Vector2(60, START_RECT.end.y + 12.0), Vector2(GameModeLayout.SCREEN.x - 120.0, 28))
	_rank_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recover = _label("", 20, Color("ffd24a"), RECOVER_RECT.position + Vector2(10, 8), Vector2(RECOVER_RECT.size.x - 20.0, 84))
	_recover.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recover.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_recover.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_recover_button = Button.new()
	_recover_button.name = "RecoverButton"
	_recover_button.text = "ふっきする（F9）"
	_recover_button.focus_mode = Control.FOCUS_NONE  # Space / Enter never press it: the stop key stays the stop key
	_recover_button.add_theme_font_size_override("font_size", 22)
	_recover_button.position = Vector2(RECOVER_RECT.position.x + 170.0, RECOVER_RECT.end.y - 52.0)
	_recover_button.size = Vector2(RECOVER_RECT.size.x - 340.0, 44)
	_recover_button.pressed.connect(func(): if ctl.main != null and ctl.main.has_method("recover_arm"): ctl.main.recover_arm())
	add_child(_recover_button)
	_mode = _label("", 18, CYAN, MODE_RECT.position, MODE_RECT.size)
	_mode.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mode.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_start = _label("パーを 3びょう（Enter でも）で スタート", 26, Color.WHITE, Vector2(60, START_RECT.position.y + 8.0), Vector2(GameModeLayout.SCREEN.x - 120.0, START_RECT.size.y - 16.0))
	_start.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for i in HOW_TO.size():
		var h := _label(HOW_TO[i], 26, Color("e8f0ff"), title_card(i).position + Vector2(112, 10), Vector2(title_card(i).size.x - 124.0, title_card(i).size.y - 20.0))
		h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY  # a long line wraps inside its card (#183)
		_how.append(h)

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

## The number in the score panel now (it eases after the score while playing).
func shown_score() -> float:
	return _shown_score

## The title screen shows: the round has not started (and is not a result or a stop).
func title_showing() -> bool:
	return ctl != null and ctl.active() and ctl.phase == "IDLE" and ctl.ranking_view == ""  # (R: the high scores instead)

## Where the three "how to play" cards sit on the title screen.
static func title_card(i: int) -> Rect2:
	return Rect2(Vector2((GameModeLayout.SCREEN.x - CARD_SIZE.x) * 0.5, CARDS_Y + CARD_STEP * i), CARD_SIZE)

## The arm's trouble and what recovers it, for the screen ("" = nothing to say). While the
## recovery runs: its steps; when it stopped: why.
func recover_text() -> String:
	var m: Node = ctl.main
	if m == null or not m.has_method("arm_recovery_reason"):
		return ""
	var prep: Dictionary = RobotState.calibration_prepare if RobotState.source == "websocket" else {}
	if m.arm_recovering():
		return "ふっきちゅう…（アームが うごきます）\n" + CalibrationPanel.prepare_text(prep)
	var why: String = m.arm_recovery_reason()
	if why == "":
		return ""
	var out := "アームが とまっています（%s）\nスタッフ: まわりを たしかめてから「ふっきする」（アラーム解除 → 準備をまとめて実行。アームが うごきます）" % why
	if str(prep.get("last_result", "")) == "fault":
		out += "\nまえの ふっきは とまった: " + CalibrationPanel.reason_text(str(prep.get("error", "")))
	return out

## What keeps the Dials away, said on the screen ("" when the hub answers).
func problem_text() -> String:
	if ctl.devices == null or ctl.devices.available():
		return ""
	var why := ctl.devices.problem()
	return "周辺機器のハブにつながっていない\n" + (why if why != "" else "（理由を問い合わせ中）")

## The result as plain lines (the tests and a log read it; the screen is GameModeResultScreen):
## the score while playing, each end bonus, the final score, the Dials that failed.
func result_lines() -> String:
	var s := ctl.score
	var r := ctl.result
	var lines := ["RESULT", "", "スコア  %d" % s.score]
	for it in r.get("items", []):
		lines.append("%s  +%d" % [it.label, int(it.points)])
	lines.append("FINAL SCORE  %d" % ctl.final_score())
	lines.append("カプセル  %d こ    最大コンボ  %d    ジャックポット  %d" % [
		int(r.get("capsules", ResultBonus.valid_capsules(ctl.capsules.finished))), s.best_chain, s.jackpots])
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		if l.state == "FAULT":
			lines.append("Dial: %s" % l.fault)
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
	var target := ctl.display_score()
	if ctl.phase == "RESULT" and ctl.result_show.active():
		# the result's show does its own counting: the panel shows that very number (no
		# easing of its own, or it would run backwards to 0 and then lag behind the big one)
		_shown_score = target
	else:
		_shown_score = move_toward(_shown_score, target, maxf(absf(target - _shown_score) * 8.0, 200.0) * dt)
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
		"STOPPED":
			centre = "STOP"
	_centre.text = centre
	_centre.add_theme_font_size_override("font_size", 76 if centre.length() > 4 else 200)
	_message.text = ctl.message if ctl.phase == "STOPPED" else ""
	if ctl.phase == "COUNTDOWN" and ctl.tutorial_speech.current != "":
		_message.text = "UFOくん「%s」" % ctl.tutorial_speech.current  # "よし！ はじめよう！" after the practice
	_start.visible = title
	_rank_hint.visible = title and ctl.ranking_enabled
	_start.modulate.a = 0.8 + 0.2 * sin(_t * 5.0)  # START breathes
	_start.scale = Vector2.ONE * (1.0 + 0.04 * sin(_t * 5.0))
	_start.pivot_offset = _start.size * 0.5
	var rec := recover_text()
	_recover.visible = rec != ""
	_recover.text = rec
	_recover_button.visible = rec != "" and ctl.main != null and ctl.main.has_method("arm_recovering") and not ctl.main.arm_recovering()
	_mode.text = ctl.difficulty_text()
	_mode.visible = title and _mode.text != ""  # #198: nothing to say while the easy mode is played
	_mode.add_theme_color_override("font_color", Color("ff6b6b") if ctl.start_blocked() != "" else CYAN if ctl.easy_on() else (Color("ffd24a") if ctl.difficulty == "easy" else MAGENTA))
	for i in _how.size():
		_how[i].visible = title
		_how[i].text = HOW_TO_EASY[i] if ctl.easy_on() else HOW_TO[i]
		_how[i].add_theme_font_size_override("font_size", 20 if ctl.easy_on() else 24)
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		# (the result and the ranking have the screen: only a Dial a person must look at keeps its line)
		_lane[side].visible = not title and (ctl.phase != "TUTORIAL" or ctl.practice != "") and ctl.ranking_view == "" \
			and (ctl.phase != "RESULT" or l.state == "FAULT")
		_lane[side].text = ctl.lane_text(side)
		_lane[side].add_theme_color_override("font_color", RED if l.state == "FAULT" else l.color)
	var hint := "Space: 止める   Esc: タイトル"
	if ctl.devices != null and ctl.devices.can_mock_ball():
		hint += "   Mock: Z = Dial に入れる"
	if ctl.phase == "TUTORIAL":
		hint = "Space: 止める　F6 つぎへ / F7 ぜんぶ とばす / Shift+F6 やりなおし　F8 メニュー"
		if ctl.practice != "" and ctl.devices != null and ctl.devices.can_mock_ball():
			hint += "   Mock: Z"
	_hint.text = hint
	_problem.text = problem_text() if ctl.phase != "TUTORIAL" or ctl.practice != "" else ""
	_problem.position.y = (MODE_RECT.position.y - 96.0) if title else (GameModeLayout.FIELD_TOP + 70.0)
	if ctl.easy_on() and not title:
		_problem.position.y += 140.0  # under the easy mode's strip / panel

# ------------------------------------------------------------------ drawing
func _draw_art() -> void:
	if ctl == null or not ctl.active():
		return
	if title_showing():
		_draw_title()
	if _recover != null and _recover.visible:
		_panel(RECOVER_RECT, RED)
	# the score (top left) and the clock (top right): half the screen each, big enough to read
	# from a few steps back
	var rising := ctl.display_score() - _shown_score > 0.5
	_panel(SCORE_RECT, YELLOW.lerp(Color.WHITE, 0.6) if rising else YELLOW)
	# in the practice the numbers are not the round's: the panel says so
	# on the title: today's best score (#183)
	var today := title_showing()
	PixelText.draw(art, "PRACTICE" if ctl.phase == "TUTORIAL" else ("TODAY BEST" if today else "SCORE"), SCORE_RECT.position + Vector2(14, 10), 4.0, YELLOW)
	var st := "%d" % (ctl.today_best() if today else int(round(_shown_score)))
	PixelText.draw_right(art, st, Vector2(SCORE_RECT.end.x - 14.0, SCORE_RECT.position.y + 42.0 - (2.0 if rising else 0.0)),
		GameModeLayout.fit_scale(st, SCORE_RECT.size.x - 28.0, 8.0), YELLOW if rising else Color.WHITE, DARK)
	var cc := clock_color()
	_panel(TIME_RECT, cc if cc != Color.WHITE else CYAN)
	PixelText.draw(art, "TIME", TIME_RECT.position + Vector2(14, 10), 4.0, CYAN)
	PixelText.draw_right(art, clock_text(ctl.time_left), Vector2(TIME_RECT.end.x - 14.0, TIME_RECT.position.y + 42.0), 8.0, cc, DARK)
	# the combo, between the hand and the arm camera: the chain, the multiplier and how long it still holds
	var chain := ctl.score.chain_now(ctl.clock)
	if chain >= 2 and ctl.phase == "PLAYING":
		var col: Color = GameModeVFX.BANNER_COLORS[ctl.combo_level()]
		var c := GameModeLayout.COMBO_RECT
		PixelText.draw_centered(art, "COMBO %d" % chain, Vector2(c.get_center().x, c.position.y + 18.0), 4.0, col, DARK)
		PixelText.draw_centered(art, "x%s" % str(ctl.score.multiplier(ctl.clock)), Vector2(c.get_center().x, c.position.y + 56.0), 4.0, Color.WHITE, DARK)
		art.draw_rect(Rect2(c.position.x + 8.0, c.position.y + 76.0, c.size.x - 16.0, 8), DARK)
		art.draw_rect(Rect2(c.position.x + 10.0, c.position.y + 78.0, snappedf((c.size.x - 20.0) * ctl.score.chain_left_k(ctl.clock), 2.0), 4), col)

## An arcade panel: dark glass, a neon rim, a shine along the top.
func _panel(r: Rect2, col: Color) -> void:
	PinballField.glow_rect(art, r, col, 0.5)
	art.draw_rect(r.grow(3.0), DARK)
	art.draw_rect(r, PANEL)
	art.draw_rect(r, col, false, 2.0)
	art.draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8.0, 2)), Color(1, 1, 1, 0.18))
	for c in [r.position, r.position + Vector2(r.size.x - 6.0, 0), r.position + Vector2(0, r.size.y - 6.0), r.end - Vector2(6, 6)]:
		art.draw_rect(Rect2(c, Vector2(6, 6)), col)

## The score game's title screen, top to bottom: the logo on two lines, UFOくん big in its
## beam, START, then how to play as three cards one under another.
func _draw_title() -> void:
	art.draw_rect(Rect2(0, GameModeLayout.HINT_Y + 14.0, GameModeLayout.SCREEN.x, GameModeLayout.SCREEN.y - GameModeLayout.HINT_Y - 14.0), Color(0.01, 0.02, 0.1, 0.84))
	# the logo: a magenta shadow, a cyan rim, yellow letters with a shine passing over
	var bob := sin(_t * 1.6) * 3.0
	var y := LOGO_Y
	var widest := 0.0
	for li in LOGO_LINES.size():
		var line: String = LOGO_LINES[li]
		var scale := GameModeLayout.fit_scale(line, GameModeLayout.SAFE_W - 60.0, 16.0)
		var w := PixelText.width(line, scale)
		widest = maxf(widest, w)
		var pos := Vector2((GameModeLayout.SCREEN.x - w) * 0.5, y + bob).snapped(Vector2(2, 2))
		PinballField.glow_rect(art, Rect2(pos - Vector2(20, 12), Vector2(w + 40.0, PixelText.height(scale) + 24.0)), PURPLE, 0.7)
		PixelText.draw(art, line, pos + Vector2(6, 6), scale, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
		PixelText.draw(art, line, pos, scale, YELLOW, DARK)
		var shine := fposmod(_t * 420.0 - li * 260.0, w + 500.0) - 120.0
		for i in line.length():  # the letters under the passing shine turn white
			var lx := i * (PixelText.W + PixelText.GAP) * scale
			if absf(lx - shine) < 70.0 and line[i] != " ":
				PixelText.draw(art, line[i], pos + Vector2(lx, 0), scale, Color(1, 1, 1, 0.85 - absf(lx - shine) / 90.0))
		y += PixelText.height(scale) + 22.0
	art.draw_rect(Rect2((GameModeLayout.SCREEN.x - widest) * 0.5, y - 6.0 + bob, widest, 4), CYAN)
	art.draw_rect(Rect2((GameModeLayout.SCREEN.x - widest) * 0.5 + 40.0, y + 2.0 + bob, widest - 80.0, 2), MAGENTA)
	# UFOくん, big, bobbing, with a beam under it
	var c := Vector2(GameModeLayout.CX, TITLE_UFO_Y + sin(_t * 2.2) * 8.0)
	var beam := PackedVector2Array([c + Vector2(-50, 90), c + Vector2(50, 90), Vector2(GameModeLayout.CX + 190.0, START_RECT.position.y - 14.0),
		Vector2(GameModeLayout.CX - 190.0, START_RECT.position.y - 14.0)])
	art.draw_colored_polygon(beam, Color(CYAN.r, CYAN.g, CYAN.b, 0.1 + 0.05 * sin(_t * 4.0)))
	if _ufo_tex != null:
		var size := Vector2(64, 64) * 6.0
		art.draw_texture_rect_region(_ufo_tex, Rect2((c - size * 0.5).snapped(Vector2(2, 2)), size), Rect2(64 * (int(_t * 3.0) % 4), 0, 64, 64))
	for i in 6:  # sparkles round it
		var a := _t * 0.8 + TAU * i / 6.0
		var q := c + Vector2(cos(a) * 270.0, sin(a) * 110.0)
		var tw := 0.5 + 0.5 * sin(_t * 5.0 + i)
		art.draw_rect(Rect2((q - Vector2(3, 3)).snapped(Vector2(2, 2)), Vector2(6, 6)), Color(1, 1, 0.7, tw))
		art.draw_rect(Rect2((q - Vector2(9, 1)).snapped(Vector2(2, 2)), Vector2(18, 2)), Color(1, 1, 0.7, tw * 0.5))
		art.draw_rect(Rect2((q - Vector2(1, 9)).snapped(Vector2(2, 2)), Vector2(2, 18)), Color(1, 1, 0.7, tw * 0.5))
	# START
	var sr := START_RECT
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	PinballField.glow_rect(art, sr, YELLOW, 0.4 + 0.6 * pulse)
	art.draw_rect(sr.grow(3.0), DARK)
	art.draw_rect(sr, Color(0.12, 0.1, 0.32, 0.95))
	art.draw_rect(sr, YELLOW.lerp(Color.WHITE, pulse * 0.5), false, 3.0)
	if ctl.title_hand == "start":  # the open hand's hold fills START (#183)
		art.draw_rect(Rect2(sr.position, Vector2(snappedf(sr.size.x * ctl.title_hand_progress, 2.0), sr.size.y)), Color(YELLOW.r, YELLOW.g, YELLOW.b, 0.45))
	var sy := sr.get_center().y
	for side in [-1, 1]:  # arrows pointing at it
		for d in 3:
			var ax: float = GameModeLayout.CX + side * (sr.size.x * 0.5 + 12.0 + d * 14.0 + pulse * 6.0)
			for stp in 5:
				art.draw_rect(Rect2(ax - side * stp * 2.0, sy - 8.0 + stp * 2.0, 2, 2), Color(1, 1, 1, 0.9 - 0.25 * d))
				art.draw_rect(Rect2(ax - side * stp * 2.0, sy + 8.0 - stp * 2.0, 2, 2), Color(1, 1, 1, 0.9 - 0.25 * d))
	# how to play: three cards, 1 -> 2 -> 3, down the screen
	var cols := [CYAN, MAGENTA, YELLOW]
	for i in 3:
		var r := title_card(i)
		art.draw_rect(r.grow(3.0), DARK)
		art.draw_rect(r, PANEL)
		art.draw_rect(r, cols[i], false, 2.0)
		var badge := Rect2(r.position + Vector2(10, 10), Vector2(30, 30))
		art.draw_rect(badge, cols[i])
		PixelText.draw_centered(art, str(i + 1), badge.get_center(), 2.0, DARK)
		var ic := r.position + Vector2(70, r.size.y * 0.5 + 6.0)
		if ctl.easy_on() and i < 2:
			# the easy mode: the hands that do it (pinch + fist; one finger)
			var hands: Array = [["pinch", "fist"], ["point"]][i]
			for j in hands.size():
				GestureTutorialHud.paint_hand(art, ic + Vector2(-34.0 + 34.0 * j, -30.0), 1.5, str(hands[j]))
		match (-1 if ctl.easy_on() and i < 2 else i):
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
		if i < 2:  # the arrow down to the next card
			var ay := r.end.y + 3.0
			for stp in 4:
				art.draw_rect(Rect2(GameModeLayout.CX - 8.0 + stp * 2.0, ay + stp * 2.0, 2, 2), Color.WHITE)
				art.draw_rect(Rect2(GameModeLayout.CX + 8.0 - stp * 2.0, ay + stp * 2.0, 2, 2), Color.WHITE)
