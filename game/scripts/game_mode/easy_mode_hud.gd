class_name EasyModeHud
extends Control
## The easy mode on the score game's screen (#169): what the hand can do now, and what the
## crane is doing by itself. It only reads (the main scene's EasyModeControl and the round's
## phase): it decides nothing and sends nothing.
##
##   playing by hand   a slim strip over the field: つまむ = うごかす, グー = キャッチ,
##                     ゆび 1 = ひだり, ゆび 2 = みぎ (the two numbers lit only while they count),
##                     the fist's hold as a bar, and why a sign was not taken
##   the crane moves   a big panel: じどうで キャッチちゅう… / どっちに いれる？ (the two hands,
##                     the time left) / ひだり・みぎ へ はこぶよ, "いまは そうさ できないよ" and
##                     "Space で とまる" all the time
##   stopped (FAULT)   かかりの ひとを よんでね, the reason, and the staff's key

const SCREEN := GameModeLayout.SCREEN
const STRIP := Rect2(40, GameModeLayout.FIELD_TOP + 4.0, 640, 48)
const STRIP_NOTE := Rect2(40, GameModeLayout.FIELD_TOP + 4.0, 640, 80)
const PANEL := Rect2(40, GameModeLayout.FIELD_TOP + 4.0, 640, 196)
const YELLOW := Color("ffe03c")
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")
const RED := Color("ff6b6b")
const DARK := Color("050818")
const GLASS := Color(0.02, 0.03, 0.13, 0.9)
const DIM := Color(0.55, 0.6, 0.75)
## the strip's four signs: [hand picture, words, the sign it is in EasyModeControl]
const LEGEND := [["pinch", "つまんで いどう", ""], ["fist", "グーで キャッチ", "grab"], ["point", "1ぽん ひだり", "1"], ["peace", "2ほん みぎ", "2"]]

var ctl: GameModeController
var _legend: Array[Label] = []
var _title: Label
var _sub: Label
var _note: Label
var _stop: Label
var _left: Label
var _right: Label
var _t := 0.0

func setup(c: GameModeController) -> void:
	ctl = c
	size = SCREEN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 21  # over the round's own HUD, under the result and the practice
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for i in LEGEND.size():
		var l := _label(15, Color.WHITE, Rect2(STRIP.position.x + 160.0 * i + 34.0, STRIP.position.y + 4.0, 124, 40), HORIZONTAL_ALIGNMENT_LEFT)
		l.text = str(LEGEND[i][1])
		_legend.append(l)
	_title = _label(34, YELLOW, Rect2(PANEL.position.x, PANEL.position.y + 10.0, PANEL.size.x, 44), HORIZONTAL_ALIGNMENT_CENTER)
	_sub = _label(20, Color("e8f0ff"), Rect2(PANEL.position.x + 110.0, PANEL.position.y + 60.0, PANEL.size.x - 220.0, 84), HORIZONTAL_ALIGNMENT_CENTER)
	_note = _label(16, Color("ffd24a"), Rect2(STRIP.position.x + 8.0, STRIP.end.y, STRIP.size.x - 16.0, 30), HORIZONTAL_ALIGNMENT_CENTER)
	_stop = _label(16, Color("b8c6ff"), Rect2(PANEL.position.x, PANEL.end.y - 30.0, PANEL.size.x, 24), HORIZONTAL_ALIGNMENT_CENTER)
	_left = _label(18, CYAN, Rect2(PANEL.position.x + 4.0, PANEL.position.y + 128.0, 110, 30), HORIZONTAL_ALIGNMENT_CENTER)
	_right = _label(18, MAGENTA, Rect2(PANEL.end.x - 114.0, PANEL.position.y + 128.0, 110, 30), HORIZONTAL_ALIGNMENT_CENTER)
	visible = false

func _label(font_size: int, color: Color, r: Rect2, align: int) -> Label:
	var l := StudyHud.label("", font_size, color, maxi(font_size / 6, 3))
	l.add_theme_color_override("font_outline_color", DARK)
	l.position = r.position
	l.size = r.size
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	add_child(l)
	return l

func easy() -> EasyModeControl:
	return ctl.main.easy if ctl != null and ctl.main != null and ctl.main.get("easy") != null else null

## The easy mode's part of the screen shows: it is what is played, and a round (or the
## practice capsule) is on.
func showing() -> bool:
	if ctl == null or not ctl.active() or not ctl.easy_on() or easy() == null or not easy().enabled():
		return false
	if ctl.ranking_view != "":
		return false
	return ctl.phase in ["COUNTDOWN", "PLAYING", "SETTLING"] or (ctl.phase == "TUTORIAL" and ctl.practice != "")

## "strip" (playing by hand) / "panel" (the crane moves by itself, or it stopped)
func view() -> String:
	var e := easy()
	return "panel" if e != null and (e.busy() or e.faulted()) else "strip"

## The panel's small line: what the crane does, what the hand should do, why it stopped.
func sub_text() -> String:
	var e := easy()
	match e.state:
		"AUTO_GRAB":
			return (e.step_text() + "\n" if e.step_text() != "" else "") + "いまは そうさ できないよ"
		"WAIT_DESTINATION":
			if e.note != "":
				return e.note
			if e.need_neutral:
				return "いちど パーに してね"
			return "ゆび 1ぽん＝ひだり　2ほん＝みぎ\nあと %d びょう" % int(ceil(e.wait_left_s))
		"DELIVER_DIAL_1", "DELIVER_DIAL_2":
			return (e.step_text() + "\n" if e.step_text() != "" else "") + "いまは そうさ できないよ"
		"FAULT":
			return e.note + "\nスタッフ: なおしてから F9（または つぎの ラウンド）"
	return ""

func _process(dt: float) -> void:
	var on := showing()
	visible = on
	if not on:
		return
	_t += dt
	var e := easy()
	var panel := view() == "panel"
	for i in _legend.size():
		_legend[i].visible = not panel
		# the numbers count only after a catch: dim while playing by hand
		var sgn := str(LEGEND[i][2])
		_legend[i].add_theme_color_override("font_color", DIM if sgn in ["1", "2"] else (YELLOW if e.holding == sgn and sgn != "" else Color.WHITE))
	_note.visible = not panel and e.note != ""
	_note.text = e.note
	_title.visible = panel
	_sub.visible = panel
	_stop.visible = panel
	_left.visible = panel and e.state == "WAIT_DESTINATION"
	_right.visible = _left.visible
	if panel:
		_title.text = e.title_text()
		_title.add_theme_color_override("font_color", RED if e.faulted() else YELLOW)
		_sub.text = sub_text()
		_stop.text = "Space で とまる" if not e.faulted() else "Space: 止める   Esc: タイトル"
		_left.text = "1 ひだり"
		_right.text = "2 みぎ"
		_left.add_theme_color_override("font_color", ctl.lanes["left"].color)
		_right.add_theme_color_override("font_color", ctl.lanes["right"].color)
	queue_redraw()

func _frame(r: Rect2, col: Color) -> void:
	draw_rect(r.grow(3.0), DARK)
	draw_rect(r, GLASS)
	draw_rect(r, col, false, 2.0)

func _bar(r: Rect2, k: float, col: Color) -> void:
	draw_rect(r.grow(2.0), DARK)
	draw_rect(r, Color(0.1, 0.12, 0.3))
	draw_rect(Rect2(r.position, Vector2(snappedf(r.size.x * clampf(k, 0.0, 1.0), 2.0), r.size.y)), col)

func _draw() -> void:
	if not showing():
		return
	var e := easy()
	if view() == "strip":
		_frame(STRIP_NOTE if e.note != "" else STRIP, CYAN)
		for i in LEGEND.size():
			var at := Vector2(STRIP.position.x + 160.0 * i + 8.0, STRIP.position.y + 6.0)
			GestureTutorialHud.paint_hand(self, at, 1.0, str(LEGEND[i][0]))
			if e.holding == str(LEGEND[i][2]) and e.holding != "":
				_bar(Rect2(at.x + 26.0, STRIP.end.y - 10.0, 120, 6), e.progress, YELLOW)
		return
	var col := RED if e.faulted() else (YELLOW if e.state == "WAIT_DESTINATION" else CYAN)
	PinballField.glow_rect(self, PANEL, col, 0.5 + 0.3 * sin(_t * 5.0))
	_frame(PANEL, col)
	if e.state == "WAIT_DESTINATION":
		# the two answers, each on its Dial's side, in its Dial's colour
		var lc: Color = ctl.lanes["left"].color
		var rc: Color = ctl.lanes["right"].color
		GestureTutorialHud.paint_hand(self, Vector2(PANEL.position.x + 30.0, PANEL.position.y + 28.0), 3.0, "point")
		GestureTutorialHud.paint_hand(self, Vector2(PANEL.end.x - 90.0, PANEL.position.y + 28.0), 3.0, "peace")
		if e.holding == "1":
			_bar(Rect2(PANEL.position.x + 10.0, PANEL.position.y + 160.0, 100, 8), e.progress, lc)
		elif e.holding == "2":
			_bar(Rect2(PANEL.end.x - 110.0, PANEL.position.y + 160.0, 100, 8), e.progress, rc)
		# the time left to choose
		_bar(Rect2(PANEL.position.x + 130.0, PANEL.position.y + 150.0, PANEL.size.x - 260.0, 8),
			e.wait_left_s / maxf(e.wait_s, 0.1), YELLOW if e.wait_left_s > 5.0 else RED)
	elif e.state.begins_with("DELIVER_DIAL_"):
		# an arrow to the side it goes to
		var side := -1.0 if e.destination == 1 else 1.0
		var c: Color = ctl.lanes["left" if e.destination == 1 else "right"].color
		var y := PANEL.position.y + 150.0
		for i in 8:
			var x := SCREEN.x * 0.5 + side * (40.0 + i * 22.0 + fmod(_t * 60.0, 22.0))
			draw_rect(Rect2(Vector2(x, y).snapped(Vector2(2, 2)), Vector2(10, 10)), Color(c.r, c.g, c.b, 1.0 - i * 0.1))
