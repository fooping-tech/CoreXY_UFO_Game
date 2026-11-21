class_name ArmScope
extends Control
## The arm camera on the score game's screen (#141): a round aiming scope in the right
## column, the mirror of the hand panel on the left. The camera at the end of the arm,
## cropped to a disc, under a targeting reticle: crosshair, tick ring, a turning dashed
## ring, a sweep, and corner brackets.
##
## The picture is the camera hub's focus role, so it is the **stabilized** one whenever the
## backend streams it (#118: the arm hangs on chains and swings; the backend measures each
## frame's motion with optical flow and cancels the shake). The scope only says which it
## is showing: STAB ON (the brackets close in, yellow), STAB WAIT (stabilizing, but nothing
## to hold on to in the picture right now), STAB OFF (the camera as it is: no backend, or
## the stabilization switched off), with a small meter of how much shake is being
## cancelled. Nothing is measured here.
##
## Presentation only: it shows the camera and decides nothing. Without the arm's camera it
## shows the overview camera; with no camera at all it stays hidden (the planet is there
## instead).

const RECT := GameModeLayout.SCOPE_RECT
const RADIUS := 44.0
## a correction this large (fraction of the frame's width) fills the shake meter
const SHAKE_FULL := 0.04
const DEMO_SIZE := 160
## the demo's camera path: it goes to each point in turn and rests there
const DEMO_STOPS := [Vector2(0, 0), Vector2(90, 30), Vector2(40, 110), Vector2(-60, 60), Vector2(-30, -50)]
const DEMO_MOVE_S := 1.6
const DEMO_REST_S := 1.6
const CYAN := Color("3ff0ff")
const YELLOW := Color("ffe03c")
const MAGENTA := Color("ff4fd8")
const DARK := Color("050818")

var hub: CameraHub
var zoom := 1.0
## true: a made-up desk that pans and stops stands in for the camera (the score game's
## --game-mode-demo: the scope's look can be checked with no camera)
var demo := false
var _demo_view: SubViewport
var _demo_scene: Node2D
var _cam: TextureRect
var _mat: ShaderMaterial
var _art: Control
var _shake := 0.0
var _t := 0.0

func setup(h: CameraHub) -> void:
	hub = h
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = RECT.position
	size = RECT.size
	z_index = 20
	_cam = TextureRect.new()
	_cam.name = "Camera"
	_cam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cam.stretch_mode = TextureRect.STRETCH_SCALE
	_cam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cam.position = centre() - Vector2(RADIUS, RADIUS)
	_cam.size = Vector2(RADIUS, RADIUS) * 2.0
	add_child(_cam)
	if hub != null:
		_mat = hub.view_material(true)
		_mat.set_shader_parameter("scanlines", 0.22)
		_cam.material = _mat
	# the stand-in picture for the demo: drawn only while it is used
	_demo_view = SubViewport.new()
	_demo_view.name = "DemoDesk"
	_demo_view.size = Vector2i(DEMO_SIZE, DEMO_SIZE)
	_demo_view.disable_3d = true
	_demo_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_demo_view)
	_demo_scene = Node2D.new()
	_demo_scene.draw.connect(_draw_demo)
	_demo_view.add_child(_demo_scene)
	_art = Control.new()
	_art.name = "Reticle"
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.size = RECT.size
	_art.draw.connect(_draw_art)
	add_child(_art)
	visible = false

## The disc's centre in this panel.
func centre() -> Vector2:
	return Vector2(RADIUS + 12.0, RECT.size.y * 0.5)  # on the left of its panel; the words beside it

## Which camera the disc shows: "focus" (the arm), "overview" (when the arm has none),
## "demo" or "".
func source_role() -> String:
	if demo:
		return "demo"
	if hub == null:
		return ""
	if hub.has_feed("focus"):
		return "focus"
	if hub.has_feed("overview"):
		return "overview"
	return ""

## The last stabilized frame's header ({} when the picture is not the backend's stream).
func stream_header() -> Dictionary:
	if source_role() == "focus" and hub.external_live("focus"):
		return hub.stream.header
	return {}

## What the scope shows: "STAB ON" (the backend's stabilized picture, tracking), "STAB WAIT"
## (stabilizing, nothing to track just now), "STAB OFF" (the camera as it is), "DEMO",
## "NO SIGNAL".
func state() -> String:
	return state_of(source_role(), stream_header())

static func state_of(role: String, header: Dictionary) -> String:
	if role == "":
		return "NO SIGNAL"
	if role == "demo":
		return "DEMO"
	if header.is_empty() or not bool(header.get("stabilized", false)):
		return "STAB OFF"
	return "STAB ON" if bool(header.get("tracking", false)) else "STAB WAIT"

## 0..1: how much shake the backend is cancelling in this frame (its correction against
## the frame's width).
static func shake_of(header: Dictionary) -> float:
	var w := float(header.get("w", 0))
	if w <= 0.0:
		return 0.0
	return clampf(Vector2(float(header.get("dx", 0.0)), float(header.get("dy", 0.0))).length() / (w * SHAKE_FULL), 0.0, 1.0)

## Once a render frame while the score game is up. `show`: the game wants it on screen.
func step(dt: float, show: bool) -> void:
	_t += dt
	var role := source_role()
	visible = show and role != ""
	_demo_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible and role == "demo" else SubViewport.UPDATE_DISABLED
	if not visible:
		return
	_cam.texture = _demo_view.get_texture() if role == "demo" else hub.texture(role)
	if role == "demo":
		_demo_scene.queue_redraw()
	if _mat != null:
		_mat.set_shader_parameter("feed_aspect", 1.0 if role == "demo" else hub.feed_aspect(role))
		_mat.set_shader_parameter("zoom", zoom)
	_shake = lerpf(_shake, shake_of(stream_header()), clampf(dt * 8.0, 0.0, 1.0))
	queue_redraw()
	_art.queue_redraw()

# ------------------------------------------------------------------ drawing
func _px(p: Vector2) -> Vector2:
	return p.snapped(Vector2(2, 2))

## A line in 2 px steps (pixel-art look, like the rest of the score game's HUD).
func _line(a: Vector2, b: Vector2, col: Color, w := 2.0) -> void:
	_art.draw_line(_px(a), _px(b), col, w)

func _color(st: String) -> Color:
	return YELLOW if st == "STAB ON" else (MAGENTA if st == "STAB WAIT" else CYAN)

## The panel behind the disc: the same dark glass as the hand panel on the left.
func _draw() -> void:
	var col := _color(state())
	draw_rect(Rect2(Vector2.ZERO, RECT.size), Color(0.02, 0.05, 0.16, 0.92))
	draw_rect(Rect2(Vector2.ONE, RECT.size - Vector2(2, 2)), Color(col, 0.6), false, 2.0)
	for corner in [Vector2.ZERO, Vector2(RECT.size.x - 4.0, 0), Vector2(0, RECT.size.y - 4.0), RECT.size - Vector2(4, 4)]:
		draw_rect(Rect2(corner, Vector2(4, 4)), DARK)
	draw_circle(centre(), RADIUS + 2.0, DARK)

func _draw_art() -> void:
	var c := centre()
	var st := state()
	var col := _color(st)
	var steady := st == "STAB ON"
	# the bezel: a dark ring, the neon ring, ticks every 30 degrees, a turning dashed ring
	_art.draw_arc(c, RADIUS + 5.0, 0, TAU, 48, DARK, 8.0)
	_art.draw_arc(c, RADIUS + 3.0, 0, TAU, 48, col, 2.0)
	for i in 12:
		var a := TAU * i / 12.0
		var d := Vector2(cos(a), sin(a))
		_line(c + d * (RADIUS - (10.0 if i % 3 == 0 else 5.0)), c + d * RADIUS, Color(col, 0.9))
	for i in 16:
		var a := TAU * i / 16.0 + _t * 0.5
		_art.draw_arc(c, RADIUS + 7.0, a, a + TAU / 40.0, 3, Color(col, 0.8), 2.0)
	# a range ring and the crosshair (a gap in the middle so the target stays visible)
	_art.draw_arc(c, RADIUS * 0.5, 0, TAU, 32, Color(CYAN, 0.35), 1.0)
	for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		_line(c + d * 10.0, c + d * (RADIUS - 12.0), Color(CYAN, 0.7))
		_line(c + d * RADIUS * 0.5 - d.orthogonal() * 4.0, c + d * RADIUS * 0.5 + d.orthogonal() * 4.0, Color(CYAN, 0.7))
	_art.draw_rect(Rect2(c - Vector2(2, 2), Vector2(4, 4)), col)
	# a sweep going round
	var sa := _t * 1.8
	for i in 6:
		var a := sa - i * 0.07
		_line(c, c + Vector2(cos(a), sin(a)) * (RADIUS - 2.0), Color(CYAN, 0.22 - 0.035 * i))
	# the brackets: closed in and yellow on the stabilized picture, wide and breathing otherwise
	var gap := 20.0 if steady else 30.0 + 3.0 * sin(_t * 6.0)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var p := c + Vector2(sx, sy) * gap
			_line(p, p - Vector2(sx * 10.0, 0), col, 2.0)
			_line(p, p - Vector2(0, sy * 10.0), col, 2.0)
	# beside the disc: what it is, which picture, and how much shake is being cancelled
	var tx := (c.x + RADIUS + 8.0 + RECT.size.x) * 0.5
	PixelText.draw_centered(_art, "ARM CAM", Vector2(tx, 22.0), 2.0, CYAN, DARK)
	PixelText.draw_centered(_art, st, Vector2(tx, 46.0), 2.0, col, DARK)
	if st.begins_with("STAB O"):
		PixelText.draw_centered(_art, "SHAKE", Vector2(tx, 72.0), 2.0, Color(CYAN, 0.8 if steady else 0.35), DARK)
		for i in 5:
			var on := steady and i < int(ceil(_shake * 5.0))
			_art.draw_rect(Rect2(tx - 28.0 + i * 12.0, 86.0, 8, 10), (YELLOW if i >= 3 else CYAN) if on else Color(CYAN, 0.18))

## Where the demo's camera looks now (px of its desk).
func demo_pan() -> Vector2:
	var leg := DEMO_MOVE_S + DEMO_REST_S
	var i := int(_t / leg) % DEMO_STOPS.size()
	var k := clampf(fmod(_t, leg) / DEMO_MOVE_S, 0.0, 1.0)
	var a: Vector2 = DEMO_STOPS[i]
	var b: Vector2 = DEMO_STOPS[(i + 1) % DEMO_STOPS.size()]
	return a.lerp(b, k * k * (3.0 - 2.0 * k))

## The demo's picture: a desk with a mat, lines and a few capsules, seen from above.
func _draw_demo() -> void:
	var d := _demo_scene
	var pan := demo_pan()
	d.draw_rect(Rect2(0, 0, DEMO_SIZE, DEMO_SIZE), Color("6b4a2e"))
	for i in range(-6, 12):  # the desk's boards
		var x := i * 40.0 - fposmod(pan.x, 40.0)
		d.draw_rect(Rect2(x, 0, 3, DEMO_SIZE), Color("4a321e"))
		d.draw_rect(Rect2(x + 14.0, fposmod(i * 53.0 - pan.y, 200.0) - 20.0, 12, 5), Color("8a6240"))
	for gy in range(-1, 10):  # the wood's knots and specks
		for gx in range(-1, 10):
			var cell := Vector2i(gx + int(floor(pan.x / 22.0)), gy + int(floor(pan.y / 22.0)))
			var hsh := absi(cell.x * 73856093 ^ cell.y * 19349663)
			var q := Vector2(cell) * 22.0 + Vector2(hsh % 17, (hsh / 17) % 17) - pan
			d.draw_rect(Rect2(q, Vector2(4 + hsh % 3, 3)), Color("3a2614") if hsh % 2 == 0 else Color("9a7450"))
	var mat := Rect2(Vector2(30, 40) - pan, Vector2(150, 110))
	d.draw_rect(mat, Color("2d6a5a"))
	d.draw_rect(mat, Color("9fe0c8"), false, 3.0)
	var caps := [[Vector2(70, 80), CYAN], [Vector2(130, 110), MAGENTA], [Vector2(20, 150), YELLOW], [Vector2(170, 40), CYAN], [Vector2(-30, 30), MAGENTA]]
	for cap in caps:
		var p: Vector2 = (cap[0] as Vector2) - pan
		d.draw_circle(p + Vector2(3, 4), 15.0, Color(0, 0, 0, 0.35))
		d.draw_circle(p, 15.0, DARK)
		d.draw_circle(p, 13.0, Color("f4f8ff"))
		d.draw_arc(p, 7.0, PI, TAU, 10, cap[1], 13.0)
		d.draw_rect(Rect2(p + Vector2(-8, -9), Vector2(5, 3)), Color.WHITE)
