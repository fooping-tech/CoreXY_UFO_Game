class_name PinballFieldArt
extends Node2D
## The picture of the pinball field (#141), drawn in code as pixel art. It lives in the
## score game's low-resolution canvas (640 x 360, shown at 2x: one dot is two screen
## pixels, the same as UFOくん's 64 x 64 sprite at 2x), so every line, circle and turning
## arm here comes out in the same dots as the UFO. Coordinates are still the 1280 x 720
## design space; a width of 2 is one dot.
##
## The style: a dark one-dot outline round everything, a highlight and a shadow, a few
## flat colours. The table's floor carries inlays (orbit rings, lane lines, arrow lamps),
## the walls are neon tubes in each Dial's colour, and the things that score breathe so
## the eye finds them; their points are written beside them.
##
## Presentation only: it reads the field (what is lit, what was just hit, where the
## capsules are) and decides nothing.

const DARK := Color("050818")
const PANEL := Color("0a1036")
const INLAY := Color("26358a")
const WALL := Color("1a2460")
const EDGE := Color("3ff0ff")
const PIN := Color("b9c8ff")
const YELLOW := Color("ffe03c")
const MAGENTA := Color("ff4fd8")
const PURPLE := Color("8a5cff")
const GREEN := Color("7dffa8")
const ORANGE := Color("ff9a3c")
const WHITE := Color("f4f8ff")

var field: PinballField
## kind -> points, written beside the targets (the controller copies the score table)
var points: Dictionary = {}
## 0..3: how far the combo has climbed (the lamps run faster, the glow is stronger)
var combo_level := 0
## false: no breathing, no trails, no running lamps (a debug switch; the game is the same)
var effects := true
var _t := 0.0

func _process(dt: float) -> void:
	_t += dt
	queue_redraw()

func _pts(kind: String) -> String:
	return str(int(points.get(kind, ScoreManager.DEFAULT_TABLE.get(kind, 0))))

## 0..1, slow: the "aim here" breathing of a target (phase shifts them apart).
func breath(phase := 0.0) -> float:
	return 0.5 + 0.5 * sin(_t * 2.6 + phase) if effects else 0.5

func _chase(i: int, n: int) -> bool:
	return effects and (i + int(_t * (5.0 + 3.0 * combo_level))) % n == 0

func _draw() -> void:
	if field == null:
		return
	_draw_board()
	_draw_goals()
	_draw_switches()
	_draw_targets()
	_draw_pins()
	_draw_pops()
	_draw_bumpers()
	_draw_spinners()
	_draw_star()
	_draw_slopes()
	_draw_frame()
	_draw_capsules()

func _a(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)

## A shape with its dark one-dot outline.
func _disc(p: Vector2, r: float, col: Color) -> void:
	draw_circle(p, r + 2.0, DARK)
	draw_circle(p, r, col)

func _box(r: Rect2, col: Color) -> void:
	draw_rect(r.grow(2.0), DARK)
	draw_rect(r, col)

## A dashed circle (an inlay on the floor).
func _dashes(p: Vector2, r: float, col: Color, n: int, spin := 0.0) -> void:
	for i in n:
		var a := TAU * i / n + spin
		draw_arc(p, r, a, a + TAU / n * 0.55, 4, col, 2.0)

# ------------------------------------------------------------------ the table
## The floor: a dark panel the stars show through a little, with the inlays of a pinball
## table (orbit rings, lane lines, a big faint UFO, arrow lamps towards what scores).
func _draw_board() -> void:
	var l := PinballField.LEFT
	var r := PinballField.RIGHT
	var top := PinballField.TOP - 12.0
	var floor_y := PinballField.FLOOR_Y
	draw_rect(Rect2(l, top, r - l, floor_y - top), _a(PANEL, 0.78))
	# a darker band down each side and a lighter lane down the middle: the table has depth
	draw_rect(Rect2(l, top, 60, floor_y - top), _a(DARK, 0.35))
	draw_rect(Rect2(r - 60.0, top, 60, floor_y - top), _a(DARK, 0.35))
	draw_rect(Rect2(570, top, 140, floor_y - top), _a(INLAY, 0.12))
	# orbit rings round the centre
	var c := Vector2(640, 420)
	_dashes(c, 300.0, _a(PURPLE, 0.35), 36, _t * 0.05 if effects else 0.0)
	_dashes(c, 210.0, _a(EDGE, 0.22), 24, -_t * 0.08 if effects else 0.0)
	draw_arc(c, 130.0, 0, TAU, 40, _a(INLAY, 0.7), 2.0)
	PixelText.draw_centered(self, "UFO", Vector2(640, 372), 18.0, _a(INLAY, 0.26))
	# lane lines from the switches down through the pins
	for x in PinballField.SWITCH_X:
		for j in 9:
			draw_rect(Rect2(float(x) - 1.0, 204.0 + 16.0 * j, 2, 8), _a(YELLOW, 0.22))
	# arrow lamps: a row pointing down at each bumper, and towards the centre goal
	for i in PinballField.BUMPERS.size():
		var b: Vector2 = PinballField.BUMPERS[i]
		for j in 2:
			_arrow(Vector2(b.x, b.y - 62.0 + 14.0 * j), Vector2.DOWN, MAGENTA if _chase(j + i, 3) else _a(MAGENTA, 0.3))
	for j in 3:
		var on := _chase(2 - j, 3) if not field.jackpot_on else int(_t * 8.0) % 2 == 0
		_arrow(Vector2(640, 556.0 + 16.0 * j), Vector2.DOWN, YELLOW if on else _a(YELLOW, 0.3))
	# starburst behind the star
	for i in 8:
		var a := TAU * i / 8.0 + PI / 8.0
		var d := Vector2(cos(a), sin(a))
		draw_line(PinballField.STAR + d * 30.0, PinballField.STAR + d * 44.0, _a(YELLOW, 0.3), 2.0)
	# small round inserts along the sides (they run like a marquee)
	for i in 8:
		for side in 2:
			var p := Vector2(l + 30.0 if side == 0 else r - 30.0, 190.0 + 26.0 * i)
			var col: Color = field.wall_colors[side]
			draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), DARK)
			draw_rect(Rect2(p - Vector2(2, 2), Vector2(4, 4)), col if _chase(i, 4) else _a(col, 0.25))

## A small pixel arrow head (three steps) pointing along dir.
func _arrow(p: Vector2, dir: Vector2, col: Color) -> void:
	var side := dir.orthogonal()
	for s in 4:
		var w := 6.0 - 2.0 * s
		draw_rect(Rect2((p + dir * 2.0 * s - side * w - Vector2(1, 1)).snapped(Vector2(2, 2)), Vector2(2, 2) + (side * w * 2.0).abs()), col)

## The walls: neon tubes in each Dial's colour with a dark outline, bevelled top corners,
## bolts, and the rail the UFO hovers over with its running lamps.
func _draw_frame() -> void:
	var top := PinballField.TOP - 30.0
	var h := PinballField.FLOOR_Y - top + 68.0
	for i in 2:
		var x := PinballField.LEFT - 12.0 if i == 0 else PinballField.RIGHT
		var col: Color = field.wall_colors[i]
		draw_rect(Rect2(x - 6.0, top, 24.0, h), _a(col, 0.12))
		draw_rect(Rect2(x - 2.0, top, 16, h), DARK)
		draw_rect(Rect2(x, top, 12, h), WALL)
		draw_rect(Rect2(x + 4.0, top, 4, h), col)
		draw_rect(Rect2(x + 4.0, top, 2, h), col.lerp(Color.WHITE, 0.7))
		for j in 9:  # bolts
			draw_rect(Rect2(x + 2.0, top + 20.0 + 70.0 * j, 8, 8), DARK)
			draw_rect(Rect2(x + 4.0, top + 22.0 + 70.0 * j, 2, 2), Color(1, 1, 1, 0.7))
	var l := PinballField.LEFT - 14.0
	var w := PinballField.RIGHT - PinballField.LEFT + 28.0
	draw_rect(Rect2(l, top - 8.0, w, 14), DARK)
	draw_rect(Rect2(l + 2.0, top - 6.0, w - 4.0, 10), WALL)
	draw_rect(Rect2(l + 2.0, top - 6.0, w - 4.0, 2), PURPLE.lerp(Color.WHITE, 0.4))
	draw_rect(Rect2(l + 2.0, top - 4.0, w - 4.0, 2), PURPLE)
	for i in 25:
		draw_rect(Rect2(PinballField.LEFT + 40.0 * i + 6.0, top - 2.0, 4, 4), YELLOW if _chase(i, 5) else Color(0.3, 0.3, 0.6))
	for i in 2:  # the bevelled caps at the top corners
		var x := l if i == 0 else l + w - 20.0
		_box(Rect2(x, top - 12.0, 20, 22), WALL)
		draw_rect(Rect2(x + 4.0, top - 8.0, 12, 4), field.wall_colors[i])
		draw_rect(Rect2(x + 4.0, top - 8.0, 4, 2), Color.WHITE)

## The bottom slopes are slingshots: a striped wedge with a rubber band along its face
## that jumps out and turns white when it kicks.
func _draw_slopes() -> void:
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var x0 := PinballField.LEFT if i == 0 else PinballField.RIGHT
		var col: Color = field.wall_colors[i]
		var a := Vector2(x0, PinballField.SLOPE_TOP_Y)
		var b := Vector2(x0 - side * PinballField.SLOPE_W, PinballField.SLOPE_BOTTOM_Y)
		var corner := Vector2(x0, PinballField.SLOPE_BOTTOM_Y)
		var k := clampf(field._sling_flash[i] * 4.0, 0.0, 1.0)
		draw_colored_polygon(PackedVector2Array([a, b, corner]), WALL)
		for j in 4:  # hazard stripes
			var q := a.lerp(corner, 0.25 + 0.2 * j)
			var q2 := Vector2(x0 - side * PinballField.SLOPE_W * (0.25 + 0.2 * j) * 0.6, PinballField.SLOPE_BOTTOM_Y)
			draw_line(q, q2, _a(col, 0.3), 4.0)
		draw_polyline(PackedVector2Array([a, b, corner]), DARK, 2.0)
		var n := PinballField.slope_normal(i)
		var mid := a.lerp(b, 0.5) + n * (4.0 + 8.0 * k)
		var band := PackedVector2Array([a + n * 2.0, mid, b + n * 2.0])
		draw_polyline(band, DARK, 8.0)
		draw_polyline(band, col.lerp(Color.WHITE, k), 4.0)
		for e in [a + n * 2.0, b + n * 2.0]:  # the band's two posts
			_disc(e, 5.0, WHITE)
			draw_rect(Rect2(e - Vector2(2, 2), Vector2(2, 2)), col)
		if k > 0.0:
			PinballField.glow_circle(self, mid, 10.0, col, 3.0 * k)

func _draw_goals() -> void:
	var floor_y := PinballField.FLOOR_Y
	var edges := [PinballField.LEFT, PinballField.POSTS_X[0], PinballField.POSTS_X[1], PinballField.RIGHT]
	var names := ["left", "center", "right"]
	for i in 3:
		var x0: float = edges[i]
		var w: float = edges[i + 1] - edges[i]
		var f := clampf(float(field._goal_flash.get(names[i], 0.0)) * 2.0, 0.0, 1.0)
		var jack: bool = i == 1 and field.jackpot_on
		var col := (YELLOW if jack else PURPLE) if i == 1 else Color("2b3fa8")
		var glow := (0.5 + 0.5 * breath()) if i == 1 else 0.0
		draw_rect(Rect2(x0, floor_y, w, 68), Color("070a26"))
		draw_rect(Rect2(x0, floor_y, w, 68), _a(col, (0.3 + 0.2 * glow if i == 1 else 0.22) + 0.6 * f))
		if jack:
			PinballField.glow_rect(self, Rect2(x0, floor_y, w, 68), YELLOW, 1.2 + 0.8 * sin(_t * 12.0))
		draw_rect(Rect2(x0, floor_y, w, 4), col.lerp(Color.WHITE, 0.3 + 0.7 * f))
		draw_rect(Rect2(x0, floor_y + 4.0, w, 2), DARK)
		# chevrons falling into the slot: this is where things go in
		var step := 70.0 if i != 1 else 46.0
		var count := int(w / step)
		for c in count:
			var cx := x0 + (w - (count - 1) * step) * 0.5 + c * step
			for row in 3:
				var k := fmod(_t * 1.4 + row / 3.0, 1.0) if effects else row / 3.0
				_arrow(Vector2(cx, floor_y + 12.0 + 44.0 * k), Vector2.DOWN, Color(1, 1, 1, sin(PI * k) * (0.5 if i == 1 else 0.3)))
		var label := "JACKPOT" if jack else _pts("goal_center" if i == 1 else "goal_" + names[i])
		var lc := (Color.WHITE if int(_t * 8.0) % 2 == 0 else YELLOW) if jack else (YELLOW if i == 1 else Color("c8d6ff"))
		PixelText.draw_centered(self, label, Vector2(x0 + w * 0.5, floor_y + 40.0), 2.0 if jack else 4.0, lc, DARK)
	for x in PinballField.POSTS_X:  # the posts between the goals
		var px := float(x)
		var pt := PinballField.POST_TOP
		_box(Rect2(px - 5.0, pt, 10, floor_y - pt + 68.0), WALL)
		draw_rect(Rect2(px - 1.0, pt, 2, floor_y - pt + 68.0), EDGE)
		PinballField.glow_circle(self, Vector2(px, pt), 7.0, EDGE, 0.6 + 0.6 * breath())
		_disc(Vector2(px, pt), 7.0, EDGE)
		draw_rect(Rect2(px - 4.0, pt - 4.0, 4, 4), Color.WHITE)

## The three switches: a lane each, an arrow dropping into it while it is still dark, and
## above them what they are for (light all three, the centre goal becomes the jackpot).
func _draw_switches() -> void:
	var sy := PinballField.SWITCH_Y
	var lit := 0
	for i in PinballField.SWITCH_X.size():
		var on: bool = field.switch_lit[i]
		lit += 1 if on else 0
		var f := clampf(field._switch_flash[i] * 2.5, 0.0, 1.0)
		var x: float = PinballField.SWITCH_X[i]
		var r := Rect2(x - 28.0, sy - 8.0, 56, 14)
		var b := breath(i * 1.3)
		draw_rect(Rect2(x - 30.0, PinballField.TOP - 12.0, 60, sy - PinballField.TOP + 12.0), _a(YELLOW, 0.06 + (0.12 if on else 0.06 * b)))
		for side in [-1.0, 1.0]:  # the lane's rails
			draw_rect(Rect2(x + side * 32.0 - 2.0, PinballField.TOP - 12.0, 4, sy - PinballField.TOP + 20.0), DARK)
			draw_rect(Rect2(x + side * 32.0 - 1.0, PinballField.TOP - 12.0, 2, sy - PinballField.TOP + 18.0), _a(YELLOW, 0.7))
		if not on:  # aim here
			var bob := fmod(_t * 1.2, 1.0) * 10.0 if effects else 0.0
			_arrow(Vector2(x, sy - 36.0 + bob), Vector2.DOWN, Color(1, 1, 1, 0.5 + 0.4 * b))
			PinballField.glow_rect(self, r, YELLOW, 0.5 * b)
		if on or f > 0.0:
			PinballField.glow_rect(self, r, YELLOW, 1.2 + 2.0 * f)
		_box(r, (YELLOW if on else Color("4a4290").lerp(Color("6a60c0"), b)).lerp(Color.WHITE, f))
		draw_rect(Rect2(r.position + Vector2(4, 2), Vector2(48, 2)), Color(1, 1, 1, 0.9 if on else 0.3))
		draw_rect(Rect2(r.position + Vector2(0, 10), Vector2(56, 4)), Color(0, 0, 0, 0.25))
	# the mission, between the lanes: three lamps and where they lead
	for g in 2:
		var cx := (float(PinballField.SWITCH_X[g]) + float(PinballField.SWITCH_X[g + 1])) * 0.5
		if g == 0:
			for i in 3:
				var p := Vector2(cx - 24.0 + 24.0 * i, 150.0)
				_box(Rect2(p - Vector2(6, 6), Vector2(12, 12)), YELLOW if i < lit else Color("2a2658"))
			PixelText.draw_centered(self, "LAMPS", Vector2(cx, 174), 2.0, _a(YELLOW, 0.9), DARK)
		else:
			var jack := field.jackpot_on
			var col := (Color.WHITE if int(_t * 8.0) % 2 == 0 else YELLOW) if jack else _a(YELLOW, 0.9)
			PixelText.draw_centered(self, "> JACKPOT", Vector2(cx, 150), 2.0, col, DARK)
			PixelText.draw_centered(self, _pts("jackpot"), Vector2(cx, 174), 2.0, col, DARK)

## Standup targets on the walls: a plate that lights for a while when it is hit.
func _draw_targets() -> void:
	for i in PinballField.TARGETS.size():
		var p: Vector2 = PinballField.TARGETS[i][0]
		var side: float = PinballField.TARGETS[i][1]
		var lit: float = field._target_lit[i]
		var f := clampf((lit - (PinballField.TARGET_LIT_S - 0.3)) / 0.3, 0.0, 1.0)
		var b := breath(i * 0.9)
		var r := Rect2(p - PinballField.TARGET_SIZE * 0.5, PinballField.TARGET_SIZE)
		var col := ORANGE if lit > 0.0 else ORANGE.darkened(0.55).lerp(ORANGE.darkened(0.3), b)
		if lit > 0.0 or f > 0.0:
			PinballField.glow_rect(self, r, ORANGE, 1.0 + 2.0 * f)
		else:
			PinballField.glow_rect(self, r, ORANGE, 0.5 * b)
		_box(r, col.lerp(Color.WHITE, f))
		draw_rect(Rect2(r.position + Vector2(2, 2), Vector2(2, r.size.y - 4.0)), Color(1, 1, 1, 0.7 if lit > 0.0 else 0.25))
		for j in 3:  # the plate's rivets
			draw_rect(Rect2(p.x - 2.0, p.y - 14.0 + 12.0 * j, 4, 4), DARK)
		_arrow(Vector2(p.x - side * 26.0, p.y), Vector2(side, 0), _a(ORANGE, 0.35 + 0.5 * b) if lit <= 0.0 else _a(ORANGE, 0.2))
		if i % 2 == 0:
			PixelText.draw_centered(self, _pts("target"), Vector2(p.x - side * 36.0, p.y + 40.0), 2.0, _a(ORANGE, 0.9), DARK)

func _draw_pins() -> void:
	var n := 0
	for row in PinballField.PIN_ROWS:
		for i in int(row[2]):
			var p := Vector2(float(row[1]) + PinballField.PIN_STEP * i, float(row[0]))
			var f := clampf(float(field._pin_flash.get("pin_%d" % n, 0.0)) / 0.3, 0.0, 1.0)
			n += 1
			if f > 0.0:
				PinballField.glow_circle(self, p, PinballField.PIN_R + 2.0, EDGE, 3.0 * f)
			draw_circle(p + Vector2(2, 4), PinballField.PIN_R + 2.0, Color(0, 0, 0, 0.35))
			_disc(p, PinballField.PIN_R, PIN.lerp(Color.WHITE, f))
			draw_rect(Rect2(p + Vector2(0, 0), Vector2(4, 4)), Color("8496e0").lerp(Color.WHITE, f))
			draw_rect(Rect2(p + Vector2(-4, -4), Vector2(2, 2)), Color.WHITE)

## Small pop bumpers by the walls: a green dome with a ring that breathes.
func _draw_pops() -> void:
	for i in PinballField.POPS.size():
		var p: Vector2 = PinballField.POPS[i]
		var k := clampf(field._pop_flash[i] * 4.0, 0.0, 1.0)
		var b := breath(2.0 + i)
		var r := PinballField.POP_R + 2.0 * k
		draw_arc(p, r + 8.0 + 4.0 * b, 0, TAU, 20, _a(GREEN, 0.5 - 0.35 * b), 2.0)
		PinballField.glow_circle(self, p, r, GREEN, 0.6 + 3.0 * k)
		draw_circle(p + Vector2(2, 4), r + 2.0, Color(0, 0, 0, 0.35))
		_disc(p, r, Color("1f8f58").lerp(Color.WHITE, k))
		draw_circle(p + Vector2(0, -2), r - 4.0, GREEN.lerp(Color.WHITE, k))
		draw_circle(p, r - 10.0, WHITE)
		draw_rect(Rect2(p + Vector2(-8, -10), Vector2(4, 4)), Color.WHITE)
		PixelText.draw_centered(self, _pts("pop"), p + Vector2(0, 34), 2.0, _a(GREEN, 0.9), DARK)

## Pop bumpers: a ring of small lamps that chase round, a domed cap with a star, and a
## ring that breathes out from each ("aim here").
func _draw_bumpers() -> void:
	for i in PinballField.BUMPERS.size():
		var k := clampf(field._bumper_flash[i] * 4.0, 0.0, 1.0)
		var p: Vector2 = PinballField.BUMPERS[i]
		var r := PinballField.BUMPER_R + 4.0 * k
		var b := breath(i * 2.1)
		draw_arc(p, r + 10.0 + 8.0 * b, 0, TAU, 28, _a(MAGENTA, 0.6 - 0.45 * b), 2.0)
		PinballField.glow_circle(self, p, r + 2.0, MAGENTA, 0.8 + 0.6 * b + 3.0 * k)
		draw_circle(p + Vector2(4, 6), r + 4.0, Color(0, 0, 0, 0.35))
		_disc(p, r + 4.0, Color("3a1a66"))
		for j in 12:  # the lamps
			var a := TAU * j / 12.0
			draw_rect(Rect2((p + Vector2(cos(a), sin(a)) * (r + 1.0) - Vector2(2, 2)).snapped(Vector2(2, 2)), Vector2(4, 4)),
				YELLOW if k > 0.0 or _chase(j, 4) else Color("6a4a9a"))
		_disc(p, r - 4.0, MAGENTA.lerp(Color.WHITE, k))
		draw_circle(p + Vector2(0, 2), r - 6.0, Color("c8309e").lerp(Color.WHITE, k))
		draw_circle(p, r - 10.0, Color("ffc4ee"))
		draw_circle(p, r - 12.0, MAGENTA.lerp(Color.WHITE, k * 0.6))
		draw_rect(Rect2(p + Vector2(-14, -16), Vector2(6, 4)), Color.WHITE)  # the shine on the dome
		draw_rect(Rect2(p + Vector2(-18, -12), Vector2(4, 4)), Color.WHITE)
		var star := PackedVector2Array()
		for j in 10:
			var a := -PI * 0.5 + TAU * j / 10.0
			star.append(p + Vector2(cos(a), sin(a)) * ((r - 14.0) if j % 2 == 0 else (r - 14.0) * 0.45))
		draw_colored_polygon(star, YELLOW.lerp(Color.WHITE, k))
		PixelText.draw_centered(self, _pts("bumper"), p + Vector2(0, r + 22.0), 2.0, _a(MAGENTA.lerp(Color.WHITE, 0.4), 0.95), DARK)

## Spinners: outlined arms with yellow tips, and faint copies behind them as they turn.
func _draw_spinners() -> void:
	var arm := PinballField.SPINNER_ARM
	for i in field._spinners.size():
		var sp := field._spinners[i]
		var dir := 1.0 if i % 2 == 0 else -1.0
		var f := clampf(field._spinner_flash[i] / 0.3, 0.0, 1.0)
		PinballField.glow_circle(self, sp.position, 12.0, GREEN, 0.8 + 0.5 * breath(4.0 + i) + 2.0 * f)
		var bars := [Rect2(-arm, -5, arm * 2.0, 10), Rect2(-5, -arm, 10, arm * 2.0)]
		if effects:
			for ghost in [2, 1]:
				draw_set_transform(sp.position, sp.rotation - dir * 0.2 * ghost)
				for bar in bars:
					draw_rect(bar, _a(GREEN, 0.16 / ghost))
		draw_set_transform(sp.position, sp.rotation)
		for bar in bars:
			draw_rect((bar as Rect2).grow(2.0), DARK)
		for bar in bars:
			draw_rect(bar, Color("2fbf73").lerp(Color.WHITE, f))
		draw_rect(Rect2(-arm, -5, arm * 2.0, 2), GREEN.lerp(Color.WHITE, 0.5))
		draw_rect(Rect2(-5, -arm, 2, arm * 2.0), GREEN.lerp(Color.WHITE, 0.5))
		for e in [Vector2(-arm, -5), Vector2(arm - 10.0, -5), Vector2(-5, -arm), Vector2(-5, arm - 10.0)]:
			draw_rect(Rect2(e, Vector2(10, 10)), YELLOW)
			draw_rect(Rect2(e + Vector2(2, 2), Vector2(2, 2)), Color.WHITE)
		draw_set_transform(Vector2.ZERO)
		_disc(sp.position, 8.0, EDGE)
		draw_rect(Rect2(sp.position - Vector2(2, 2), Vector2(4, 4)), Color.WHITE)
		PixelText.draw_centered(self, _pts("spinner"), sp.position + Vector2(0, arm + 16.0), 2.0, _a(GREEN, 0.9), DARK)

func _draw_star() -> void:
	var star_r := PinballField.STAR_R
	var at := PinballField.STAR
	if field.star_left > 0.0:  # away: a ring fills as it comes back
		draw_arc(at, star_r * 0.8, 0, TAU, 20, _a(YELLOW, 0.2), 2.0)
		draw_arc(at, star_r * 0.8, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - field.star_left / maxf(field.star_respawn_s, 0.01)), 20,
			_a(YELLOW, 0.7), 4.0)
		return
	var b := breath(1.0)
	var c := (at + Vector2(0, sin(_t * 3.0) * 2.0 if effects else 0.0)).snapped(Vector2(2, 2))
	draw_arc(c, star_r + 10.0 + 8.0 * b, 0, TAU, 24, _a(YELLOW, 0.6 - 0.45 * b), 2.0)
	PinballField.glow_circle(self, c, star_r, YELLOW, 1.0 + b)
	for layer in 3:
		var scale_k: float = [1.3, 1.0, 0.55][layer]
		var col: Color = [DARK, YELLOW, Color("fff6b0")][layer]
		var pts := PackedVector2Array()
		for i in 10:
			var a := -PI * 0.5 + TAU * i / 10.0
			pts.append(c + Vector2(cos(a), sin(a)) * ((star_r + 4.0) if i % 2 == 0 else (star_r + 4.0) * 0.48) * scale_k)
		draw_colored_polygon(pts, col)
	if effects:
		for i in 4:  # a turning glint
			var a := _t * 1.5 + TAU * i / 4.0
			draw_rect(Rect2((c + Vector2(cos(a), sin(a)) * (star_r + 14.0) - Vector2(2, 2)).snapped(Vector2(2, 2)), Vector2(4, 4)), Color(1, 1, 1, 0.8))
	PixelText.draw_centered(self, _pts("star"), at + Vector2(0, star_r + 26.0), 2.0, YELLOW, DARK)

## The capsules, each with a trail of light where it has just been.
func _draw_capsules() -> void:
	for id in field.capsule_ids():
		var col := field.capsule_color(id)
		var pos := field.capsule_position(id)
		if effects:
			var tr := field.capsule_trail(id)
			for j in tr.size():
				var k := float(j + 1) / (tr.size() + 1)
				var sz := (4.0 + 12.0 * k) + 4.0 * combo_level * k
				draw_rect(Rect2((tr[j] - Vector2(sz, sz) * 0.5).snapped(Vector2(2, 2)), Vector2(sz, sz).snapped(Vector2(2, 2))),
					_a(col.lerp(Color.WHITE, 0.6 * k * k), 0.1 + 0.5 * k))
		PinballField.draw_capsule_at(self, pos, field.capsule_rotation(id), col, 1.0)
