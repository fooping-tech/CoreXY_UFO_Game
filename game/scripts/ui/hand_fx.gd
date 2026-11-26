class_name HandFx
extends Control
## Pixel particles on the hand window (#321): square dots, snapped to whole pixels, no
## smoothing (the game's pixel look).
##
## - `orbit` (the camera picture): a ring of dots circles the detected hand; it fades in
##   when the hand is seen and out when it is lost.
## - a pinch (its first frame): the ring's dots and a few more fly outwards, and the
##   pixelfx sheet `grab_burst` plays on the hand (as a child, so the window clips it).
##   At most one burst per BURST_COOLDOWN_S (a flickering pinch does not pile them up).
## - steering (`move` > 0): sparks stream out behind the hand, against `dir` (the way the
##   crane goes, in this picture's axes), more the faster it goes.
##
## Presentation only: the GestureHud feeds it what the GestureControl already decided
## (detected, pinch, speed); it sends nothing and decides nothing.

const CYAN := Color(0.35, 0.95, 1.0)
const GOLD := Color(1.0, 0.8, 0.25)
const PINK := Color(1.0, 0.35, 0.72)
const ORBIT_N := 10
## Dots added to the ring's own when it bursts.
const BURST_EXTRA := 14
const BURST_COOLDOWN_S := 0.45
## Speed of the burst's dots, in ring radii per second.
const BURST_SPEED := Vector2(6.0, 11.0)
## Steering sparks per second at full speed.
const TRAIL_RATE := 45.0
const MAX_PARTICLES := 160
const FADE_IN_S := 0.25
const FADE_OUT_S := 0.35
## After a burst the ring forms again from nothing (it flew away).
const REFORM_S := 0.5
const BURST_SHEET := "grab_burst"
## grab_burst's picture sits this many sheet pixels above its pivot (the pivot is at the
## bottom of the frame): the sheet goes this much lower so the ring lands on the hand.
const BURST_SHEET_LIFT := 32.0

## true: the ring around the hand (the camera picture); false: only the steering sparks (the stick).
var orbit := true
## The ring's radius in this control's pixels.
var radius := 14.0
## One dot's side in pixels.
var dot := 2.0
## The burst sheet's scale (screen px per sheet px).
var sheet_scale := 0.5
## Off: no dots, no sheet (render.vfx / VFXManager.enabled).
var enabled := true
## Free dots: {p: Vector2, v: Vector2, life: float, max: float, col: Color, size: float}.
var particles: Array[Dictionary] = []
## How many bursts so far (tests / debug).
var bursts := 0
## The burst sheet playing now (null when none).
var sheet: AnimatedSprite2D
var hand := Vector2.ZERO
var seen := false
var pinching := false
## The ring's visibility, 0..1.
var presence := 0.0
var _spin := 0.0
var _t := 0.0
var _cool := 0.0
var _was_pinch := false
var _trail_acc := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## One frame. `at_hand`: the hand in this control's pixels; `is_seen`: the hand is detected;
## `pinch`: it pinches; `move`: how fast it steers (0..1); `dir`: the way the crane goes in
## this picture (the sparks go the other way); `gold`: the stick is held (the ring goes gold).
func step(dt: float, is_seen: bool, at_hand: Vector2, pinch := false, move := 0.0, dir := Vector2.ZERO, gold := false) -> void:
	if not enabled:
		clear()
		return
	_t += dt
	_cool = maxf(_cool - dt, 0.0)
	seen = is_seen
	if seen:
		hand = at_hand
	pinching = seen and (pinch or gold)
	var target := 1.0 if (seen and orbit) else 0.0
	presence = move_toward(presence, target, dt / (FADE_IN_S if target > presence else FADE_OUT_S))
	_spin += dt * (5.0 if pinching else 2.2)
	var p_now := seen and pinch
	if p_now and not _was_pinch and _cool <= 0.0:
		burst()
	_was_pinch = p_now
	if seen and move > 0.02:
		_trail_acc += TRAIL_RATE * clampf(move, 0.0, 1.0) * dt
		while _trail_acc >= 1.0:
			_trail_acc -= 1.0
			_spark(dir, move)
	else:
		_trail_acc = 0.0
	_age(dt)
	queue_redraw()

## The ring's dots now (whole pixels), [] when it is not shown.
func orbit_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if not orbit or presence <= 0.01:
		return out
	var r := radius * (0.85 if pinching else 1.0)
	for i in ORBIT_N:
		var a := TAU * i / ORBIT_N + _spin
		var wob := 1.0 + 0.12 * sin(_t * 6.0 + i * 1.7)
		out.append((hand + Vector2(cos(a), sin(a)) * r * wob).floor())
	return out

## The ring flies apart: its dots and BURST_EXTRA more go outwards, the sheet plays on the
## hand, and the ring forms again from nothing.
func burst() -> void:
	bursts += 1
	_cool = BURST_COOLDOWN_S
	var n := ORBIT_N + BURST_EXTRA
	for i in n:
		var a := TAU * i / n + _spin + _rng.randf_range(-0.15, 0.15)
		var d := Vector2(cos(a), sin(a))
		var from := hand + d * radius * (1.0 if i < ORBIT_N else 0.4)
		var speed := radius * _rng.randf_range(BURST_SPEED.x, BURST_SPEED.y)
		var col := GOLD if i % 3 == 0 else (Color.WHITE if i % 3 == 1 else CYAN)
		_add({"p": from, "v": d * speed, "life": 0.0, "max": _rng.randf_range(0.35, 0.6), "col": col,
			"size": dot * (2.0 if i % 4 == 0 else 1.0)})
	presence = -REFORM_S / FADE_IN_S  # below zero: a moment before the ring shows again
	if is_instance_valid(sheet):
		VFXManager.stop_fx(sheet)
	sheet = VFXManager.spawn_fx(BURST_SHEET, hand + Vector2(0.0, BURST_SHEET_LIFT * sheet_scale),
		{"parent": self, "scale": sheet_scale, "layer": "front"})

func clear() -> void:
	particles.clear()
	presence = 0.0
	_was_pinch = false
	_trail_acc = 0.0
	if is_instance_valid(sheet):
		VFXManager.stop_fx(sheet)
	sheet = null
	queue_redraw()

func _spark(dir: Vector2, move: float) -> void:
	var back := -dir.normalized() if dir.length() > 1e-4 else Vector2.ZERO
	var side := back.orthogonal()
	var jitter := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * radius * 0.25
	var speed := radius * _rng.randf_range(2.5, 5.0) * (0.6 + 0.6 * clampf(move, 0.0, 1.0))
	var v := back * speed + side * _rng.randf_range(-1.2, 1.2) * radius
	if back == Vector2.ZERO:  # no direction: a little puff all around
		v = Vector2.from_angle(_rng.randf() * TAU) * radius * 2.0
	var pick := _rng.randi() % 3
	var col := GOLD if pick == 0 else (PINK if pick == 1 else CYAN)
	_add({"p": hand + jitter + back * radius * 0.3, "v": v, "life": 0.0, "max": _rng.randf_range(0.25, 0.45),
		"col": col, "size": dot * (1.5 if pick == 0 else 1.0)})

func _add(p: Dictionary) -> void:
	particles.append(p)
	if particles.size() > MAX_PARTICLES:
		particles.remove_at(0)

func _age(dt: float) -> void:
	var drag := pow(0.08, dt)  # they slow down as they go
	var keep: Array[Dictionary] = []
	for p in particles:
		p.life += dt
		if p.life >= p.max:
			continue
		p.p += p.v * dt
		p.v *= drag
		keep.append(p)
	particles = keep

func _draw() -> void:
	for p in particles:
		var k := 1.0 - float(p.life) / float(p.max)
		var s := float(p.size)
		var c: Color = p.col
		draw_rect(Rect2((Vector2(p.p) - Vector2(s, s) * 0.5).floor(), Vector2(s, s)), Color(c, k))
	var pts := orbit_points()
	if pts.is_empty():
		return
	var a := clampf(presence, 0.0, 1.0)
	var base := GOLD if pinching else CYAN
	for i in pts.size():
		var tw := 0.55 + 0.45 * sin(_t * 9.0 + i * 2.3)  # twinkle
		var c := Color.WHITE if i % 4 == 0 else base
		var s := dot * (1.5 if i % 2 == 0 else 1.0)
		draw_rect(Rect2(pts[i] - Vector2(s, s) * 0.5, Vector2(s, s)).abs(), Color(c, a * tw))
	# a few slower dots on an inner ring, the other way round: depth
	for i in 4:
		var ang := -_spin * 0.6 + TAU * i / 4.0
		var q := (hand + Vector2(cos(ang), sin(ang)) * radius * 0.55).floor()
		draw_rect(Rect2(q - Vector2(dot, dot) * 0.5, Vector2(dot, dot)), Color(base, a * 0.6))
