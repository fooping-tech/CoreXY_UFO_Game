class_name GameModeResultScreen
extends Control
## The end of a round on the screen (#153, docs/game_mode_spec.md §3.2): "TIME UP!" while
## the round settles, then the result's show: the huge score in the middle, the bonuses
## flying into it one by one, "FINAL SCORE!".
##
## It only draws what ResultShow says is on now (the number shown, the title, the bonus, the
## punch, the flash); it decides nothing and keeps no clock of the seq. The picture (the
## dimmed field, the rays, the pixel letters, the sparks) is in the game mode's pixel canvas
## like the field, so its dots are the field's dots and the hit-stop holds it too; the
## Japanese lines are the game's normal labels on top, as on the HUD.
##
## No new effect system: the sparks, rings and confetti are a GameModeParticles pool of its
## own (over the dimmed field), the sheets are pixelfx ones through VFXManager.spawn_fx.

const SCREEN := Vector2(1280, 720)
## the middle of the number
const CENTRE := Vector2(640, 350)
const TITLE_Y := 164.0
const UFO_AT := Vector2(640, 78)
## where a bonus's points are shown before they fly into the number
const BONUS_AT := Vector2(640, 570)
## the number's digits are never wider than this, however many (its neon rim needs the rest)
const NUMBER_MAX_W := 1100.0
## where the lines under the number sit (the bonus being announced; the round's numbers)
const SUB_Y := 494.0
## the dot size of the number at rest, when the digits allow it
const NUMBER_SCALE := 26.0
const NUMBER_SCALE_MAX := 40.0
## how far the number's dark body reaches round its strokes, in dots
const BODY_DOTS := 1.5
## the ground line of the confetti sheets: just under the number
const CONFETTI_Y := 566.0
const TIME_UP := "TIME UP!"
const RAYS := 14
const YELLOW := Color("ffe03c")
const GOLD := Color("ffb020")
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")
const DARK := Color("050818")
const UFO_FACES_SHEET := "res://assets/ufo/ufo_expressions.png"
const TITLE_SCALES := {"YOUR SCORE": 6.0, "BONUS!": 10.0, "FINAL SCORE!": 8.0}

var ctl: GameModeController
var seq: ResultShow
## the picture's root, in the pixel canvas (over the field, the effects and the UFO)
var art: Node2D
## the result's own sparks, rings and confetti (the same pool class as the field's)
var particles: GameModeParticles
var _back: Node2D
var _front: Node2D
var _sub: Label
var _stats: Label
var _faults: Label
var _keys: Label
var _faces: Texture2D
var _t := 0.0

func setup(c: GameModeController) -> void:
	ctl = c
	seq = c.result_show
	size = SCREEN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 30  # over the HUD's panels
	if ResourceLoader.exists(UFO_FACES_SHEET):
		_faces = load(UFO_FACES_SHEET)
	art = Node2D.new()
	art.name = "ResultArt"
	art.z_index = 40
	art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	art.visible = false
	c.pixel_view.add_child(art)
	_back = Node2D.new()
	_back.name = "Back"
	_back.draw.connect(_draw_back)
	art.add_child(_back)
	particles = GameModeParticles.new()
	particles.name = "ResultParticles"
	art.add_child(particles)
	particles.z_index = 1  # over the dimmed field and the rays, under the letters
	_front = Node2D.new()
	_front.name = "Front"
	_front.z_index = 2
	_front.draw.connect(_draw_front)
	art.add_child(_front)
	_sub = _label(30, Color.WHITE, SUB_Y, 44.0)
	_stats = _label(20, Color("c8d6ff"), 596.0, 30.0)
	_keys = _label(22, Color.WHITE, 640.0, 34.0)
	_faults = _label(18, Color("ff6b6b"), 682.0, 30.0)

func _label(font_size: int, color: Color, y: float, h: float) -> Label:
	var l := StudyHud.label("", font_size, color, maxi(font_size / 6, 3))
	l.add_theme_color_override("font_outline_color", DARK)
	l.position = Vector2(40, y)
	l.size = Vector2(1200, h)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(l)
	return l

# ------------------------------------------------------------------ what is on
## "" (nothing) / "time_up" (the round settles) / "result" (the show, or its last picture).
func mode() -> String:
	if ctl == null or not ctl.active():
		return ""
	if ctl.phase == "SETTLING":
		return "time_up"
	return "result" if ctl.phase == "RESULT" and seq.active() else ""

## The number in the middle, as text.
func number_text() -> String:
	return str(int(round(seq.shown)))

## The dot size of a number of `digits` digits at the factor `k` (ResultShow.number_k, plus
## the punch): the size at rest shrinks with the digits so it always fits the screen, and
## however hard it is punched it never leaves it. Even, so the dots stay the canvas's dots.
static func number_scale(digits: int, k := 1.0) -> float:
	var cols := float(maxi(digits, 1) * (PixelText.W + PixelText.GAP) - PixelText.GAP)
	var rest := minf(NUMBER_SCALE, floorf(NUMBER_MAX_W * 0.86 / cols / 2.0) * 2.0)
	var fit := minf(NUMBER_SCALE_MAX, floorf(NUMBER_MAX_W / cols / 2.0) * 2.0)
	return clampf(snappedf(rest * k, 2.0), 2.0, maxf(fit, 2.0))

## How far the cyan (up-left) and magenta (down-right) rims are set off from the number.
static func number_rim(dot: float) -> float:
	return maxf(snappedf(dot * 0.25, 2.0), 4.0)

## The whole width of the number on the screen: its digits, their dark body and the rims.
static func number_width(digits: int, k := 1.0) -> float:
	var sc := number_scale(digits, k)
	return PixelText.width("0".repeat(maxi(digits, 1)), sc) + 2.0 * (sc * BODY_DOTS + number_rim(sc))

## The line under the title while a bonus is announced.
func item_text() -> String:
	var it := seq.item()
	if it.is_empty():
		return ""
	return "%s    %d %s × %d" % [it.label, int(it.count), it.unit, int(it.each)]

func stats_text() -> String:
	var d := seq.data
	return "カプセル  %d こ        最大コンボ  %d        ジャックポット  %d" % [int(d.get("capsules", 0)), int(d.get("best_chain", 0)),
		int(d.get("jackpots", 0))]

## The Dials a person has to look at (a fault is never hidden by the show).
func faults_text() -> String:
	var lines: Array[String] = []
	for side in GameModeController.SIDES:
		var l: GameModeController.Lane = ctl.lanes[side]
		if l.state == "FAULT":
			lines.append("%s の Dial: %s" % ["左" if side == "left" else "右", l.fault])
	return "    ".join(lines)

func keys_text() -> String:
	if mode() != "result":
		return ""
	return "Enter：もう一回        T：練習から        Esc：タイトル" if seq.settled() else "Enter：スキップ"

## A pixelfx sheet over the result (success_confetti, success_sparkle...), in the canvas.
func sheet(id: String, at: Vector2, sheet_scale := 2.0, color := Color.WHITE) -> void:
	if ctl.effects and art.visible:
		VFXManager.spawn_fx(id, at, {"parent": art, "scale": sheet_scale, "color": color, "layer": "front"})

## Everything of the show that is still on the screen goes (a new round, the title).
func clear() -> void:
	particles.clear()
	for c in art.get_children():
		if c.is_in_group("vfx"):
			VFXManager.stop_fx(c)

func sheets() -> int:
	var n := 0
	for c in art.get_children():
		if c.is_in_group("vfx") and not c.is_queued_for_deletion():
			n += 1
	return n

## The particles' time (the controller's tick: the same clock as the cues).
func advance(dt: float) -> void:
	particles.z_index = 1  # (the pool's own _ready puts it at the field's height)
	particles.effects = ctl.effects
	particles.quality = ctl.visual_quality
	particles.advance(dt)

func _process(dt: float) -> void:
	if ctl == null:
		return
	_t += dt
	var m := mode()
	art.visible = m != ""
	visible = m != ""
	if m == "":
		return
	_back.queue_redraw()
	_front.queue_redraw()
	queue_redraw()
	_sub.text = ""
	_sub.position.y = SUB_Y
	if m == "time_up":
		_sub.text = "スコア集計中…"
		_sub.position.y = 410.0
		_sub.modulate.a = 0.7 + 0.3 * sin(_t * 6.0)
	elif seq.item_showing():
		_sub.text = item_text()
		_sub.modulate.a = 1.0 - seq.fly_k()
	_faults.text = faults_text() if m == "result" else ""
	_stats.text = stats_text() if m == "result" and seq.finale() else ""
	_keys.text = keys_text()
	_keys.modulate.a = (0.75 + 0.25 * sin(_t * 5.0)) if seq.settled() else 0.6

# ------------------------------------------------------------------ drawing
## The white flash, over everything of the game mode (the labels and the panels too).
func _draw() -> void:
	if ctl != null and ctl.effects and seq.flash > 0.01:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 1, 1, clampf(seq.flash, 0.0, 1.0) * 0.85))

func _draw_back() -> void:
	var m := mode()
	if m == "":
		return
	_back.draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0.01, 0.02, 0.08, 0.62 if m == "time_up" else 0.84))
	if m == "time_up":
		# a band of light behind the words
		for i in 4:
			_back.draw_rect(Rect2(0, 300.0 - 70.0 - 18.0 * i, 1280, 140.0 + 36.0 * i), Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.05))
		return
	if not ctl.effects:
		return
	# the rays turn behind the number: slow while it counts, fast and full for the final score
	var fin := seq.finale()
	var turn := _t * (0.9 if fin else 0.35)
	var cols := [CYAN, MAGENTA, GOLD] if fin else [CYAN, MAGENTA]
	var alpha := (0.2 if fin else 0.1) + 0.12 * seq.punch
	for i in RAYS:
		var a := turn + TAU * i / RAYS
		var w := TAU / RAYS * 0.5
		var col: Color = cols[i % cols.size()]
		_back.draw_colored_polygon(PackedVector2Array([CENTRE, CENTRE + Vector2(cos(a), sin(a)) * 900.0,
			CENTRE + Vector2(cos(a + w), sin(a + w)) * 900.0]), Color(col.r, col.g, col.b, alpha))
	# the spotlight on the number
	for i in 3:
		_back.draw_circle(CENTRE, 330.0 - 80.0 * i, Color(1.0, 0.95, 0.6, 0.05 + 0.03 * seq.punch))

func _draw_front() -> void:
	var m := mode()
	if m == "time_up":
		_draw_time_up()
	elif m == "result":
		_draw_ufo()
		_draw_title()
		_draw_number()
		_draw_bonus()

## "TIME UP!" slams in: big, then its size, white for the first moment.
func _draw_time_up() -> void:
	var tt := seq.title_t
	var sc := 16.0 + (snappedf(8.0 * exp(-tt * 12.0), 2.0) if ctl.effects else 0.0)
	var c := Vector2(640, 300)
	PixelText.draw_centered(_front, TIME_UP, c + Vector2(8, 8), sc, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
	PixelText.draw_centered(_front, TIME_UP, c, sc, Color.WHITE if ctl.effects and tt < 0.12 else YELLOW, DARK)

## UFOくん over the title: it watches the count, jumps for a bonus and for the final score.
func _draw_ufo() -> void:
	if _faces == null:
		return
	var face := "happy"
	var off := Vector2(0, sin(_t * 2.4) * 4.0)
	if seq.final_score() <= 0 and seq.finale():
		face = "sad"
	elif seq.stage in ["count", "bonus_count"]:
		face = "surprised"
	elif seq.stage in ["announce", "absorb", "final"]:
		face = "excited"
		if ctl.effects:
			off = Vector2(0, -18.0 * absf(sin(_t * 9.0)))
	elif seq.stage == "settled":
		face = "wink" if int(_t * 0.8) % 3 == 0 else "happy"
	var fi := GameModeVFX.UFO_FACES.find(face)
	var size := Vector2(64, 64) * 2.0
	_front.draw_texture_rect_region(_faces, Rect2((UFO_AT - size * 0.5 + off).snapped(Vector2(2, 2)), size),
		Rect2(64 * (fi % 5), 64 * (fi / 5), 64, 64))

## The title over the number: its letters arrive one after another, each dropping in with
## a bounce; "FINAL SCORE!" keeps waving in the three neon colours.
func _draw_title() -> void:
	var text := seq.title()
	if text == "":
		return
	var sc: float = TITLE_SCALES.get(text, 6.0)
	var step := (PixelText.W + PixelText.GAP) * sc
	var x0 := 640.0 - PixelText.width(text, sc) * 0.5
	var y0 := TITLE_Y - PixelText.height(sc) * 0.5
	for i in text.length():
		if text[i] == " ":
			continue
		var lt := seq.title_t - 0.035 * i  # this letter's own time
		if ctl.effects and lt < 0.0:
			continue
		var dy := 0.0
		var col := CYAN
		if ctl.effects:
			dy = -44.0 * exp(-9.0 * lt) * cos(lt * 16.0)
		match text:
			"BONUS!":
				col = YELLOW if int(_t * 8.0 + i) % 2 == 0 else MAGENTA
			"FINAL SCORE!":
				col = [CYAN, MAGENTA, YELLOW][(i + int(_t * 6.0)) % 3]
				if ctl.effects:
					dy += sin(_t * 6.0 + i * 0.7) * 4.0
		var p := Vector2(x0 + step * i, y0 + dy).snapped(Vector2(2, 2))
		PixelText.draw(_front, text[i], p + Vector2(sc, sc), sc, Color(0.02, 0.03, 0.1, 0.85))
		PixelText.draw(_front, text[i], p, sc, Color.WHITE if ctl.effects and lt < 0.08 else col, DARK)

## The number: yellow, a white shine along its top, a gold shade along its foot, a cyan
## rim up-left and a magenta one down-right. A hit punches it bigger for a moment.
func _draw_number() -> void:
	var text := number_text()
	var k := seq.number_k() if ctl.effects else (1.15 if seq.finale() else 1.0)
	var sc := number_scale(text.length(), k + (0.22 * seq.punch if ctl.effects else 0.0))
	var jolt := Vector2(0, -10.0 * seq.punch) if ctl.effects else Vector2.ZERO
	var pos := (CENTRE + jolt - Vector2(PixelText.width(text, sc), PixelText.height(sc)) * 0.5).snapped(Vector2(2, 2))
	# the dark body reaches a dot and a half round every stroke (the holes of the digits are
	# dark all through). The same shape, set off down-right in magenta and up-left in cyan,
	# is the neon rim: one even line round the outside.
	var rim := number_rim(sc)
	PixelText.draw_grown(_front, text, pos + Vector2(rim, rim), sc, MAGENTA, sc * BODY_DOTS)
	PixelText.draw_grown(_front, text, pos - Vector2(rim, rim), sc, CYAN, sc * BODY_DOTS)
	PixelText.draw_grown(_front, text, pos, sc, DARK, sc * BODY_DOTS)
	var hot := ctl.effects and seq.punch > 0.7
	PixelText.draw(_front, text, pos, sc, Color.WHITE if hot else YELLOW)
	if not hot:
		PixelText.draw_rows(_front, text, pos, sc, Color(1, 1, 0.86), 0, 2)
		PixelText.draw_rows(_front, text, pos, sc, GOLD, 6, 7)

## A bonus's points: they jump out under the number, then fly into it, shrinking.
func _draw_bonus() -> void:
	if not seq.item_showing():
		return
	var text := "+%d" % int(seq.item().get("points", 0))
	var fk := seq.fly_k()
	var e := fk * fk
	var sc := 10.0
	if ctl.effects and seq.stage == "announce":
		sc += snappedf(8.0 * exp(-seq.t * 12.0), 2.0)
	sc = maxf(snappedf(lerpf(sc, 4.0, e), 2.0), 2.0)
	while sc > 2.0 and PixelText.width(text, sc) > NUMBER_MAX_W:
		sc -= 2.0
	var c := BONUS_AT.lerp(CENTRE, e).snapped(Vector2(2, 2))
	var col := YELLOW if int(_t * 10.0) % 2 == 0 else Color.WHITE
	PixelText.draw_centered(_front, text, c + Vector2(sc, sc), sc, Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.9))
	PixelText.draw_centered(_front, text, c, sc, col, DARK)
