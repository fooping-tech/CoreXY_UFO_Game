class_name ArmScope
extends Control
## The arm camera on the score game's screen (#141): a round aiming scope in the right
## column, the mirror of the hand panel on the left. The camera at the end of the arm,
## cropped to a disc, under a targeting reticle (crosshair, turning tick ring, corner
## brackets that close in when the picture holds still, a sweep), with the picture's
## optical flow drawn over it: an arrow per cell of a grid showing where the picture is
## moving, and one arrow from the middle for the whole view. Under the disc: the state
## (LOCK when the view is still, MOVE while it moves, NO SIGNAL) and how fast it moves.
##
## The flow is measured here (OpticalFlow, block matching on a 48 x 48 grey copy of the
## view taken about ten times a second), so it also works without the backend.
##
## Presentation only: it shows the camera and decides nothing. The frames and the flow are
## never saved, sent, or used to move the robot. Without the arm's camera it shows the
## overview camera; with no camera at all it stays hidden (the planet is there instead).

const RECT := Rect2(1145, 124, 133, 236)
const RADIUS := 58.0
const SAMPLE := 48
const SAMPLE_EVERY_S := 0.1
## mean flow under this (px of the 48 px copy per sample) counts as still
const STILL_PX := 0.25
const LOCK_AFTER_S := 0.6
## how long a drawn arrow is per px of flow, and its limit
const ARROW_GAIN := 7.0
const ARROW_MAX := 22.0
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
var flow := OpticalFlow.new()
## the cells as drawn: {at, v (smoothed), ok}
var cells: Array = []
var mean_flow := Vector2.ZERO
var locked := false
## false: no arrows and no sampling (config game_mode.scope.optical_flow)
var flow_enabled := true
var zoom := 1.0
## true: a made-up desk that pans and stops stands in for the camera (the score game's
## --game-mode-demo: the scope and its flow can be checked with no camera)
var demo := false
var _demo_view: SubViewport
var _demo_scene: Node2D
var _still_s := 0.0
var _prev := PackedByteArray()
var _cam: TextureRect
var _mat: ShaderMaterial
var _sampler: SubViewport
var _sample_rect: TextureRect
var _sample_mat: ShaderMaterial
var _sample_left := 0.0
var _art: Control
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
	# the same view, small and square, to measure the flow on
	_sampler = SubViewport.new()
	_sampler.name = "FlowSample"
	_sampler.size = Vector2i(SAMPLE, SAMPLE)
	_sampler.disable_3d = true
	_sampler.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sampler)
	_sample_rect = TextureRect.new()
	_sample_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sample_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_sample_rect.size = Vector2(SAMPLE, SAMPLE)
	_sampler.add_child(_sample_rect)
	if hub != null:
		_mat = hub.view_material(true)
		_mat.set_shader_parameter("scanlines", 0.22)
		_cam.material = _mat
		_sample_mat = hub.view_material(false)
		_sample_rect.material = _sample_mat
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
	return Vector2(RECT.size.x * 0.5, 8.0 + RADIUS + 6.0)

## Which camera the disc shows: "focus" (the arm), "overview" (when the arm has none) or "".
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

## "LOCK" (the view holds still), "MOVE", "SCAN" (nothing to track yet) or "NO SIGNAL".
func state() -> String:
	if source_role() == "" and _prev.is_empty():
		return "NO SIGNAL"
	if not flow_enabled or cells.is_empty() or OpticalFlow.tracked(cells) == 0:
		return "SCAN"
	return "LOCK" if locked else "MOVE"

## Once a render frame while the score game is up. `show`: the game wants it on screen.
func step(dt: float, show: bool) -> void:
	_t += dt
	var role := source_role()
	visible = show and role != ""
	var sampling := visible and flow_enabled and DisplayServer.get_name() != "headless"
	_sampler.render_target_update_mode = SubViewport.UPDATE_ALWAYS if sampling else SubViewport.UPDATE_DISABLED
	_demo_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible and role == "demo" else SubViewport.UPDATE_DISABLED
	if not visible:
		return
	var tex: Texture2D = _demo_view.get_texture() if role == "demo" else hub.texture(role)
	_cam.texture = tex
	_sample_rect.texture = tex
	if role == "demo":
		_demo_scene.queue_redraw()
	for m in [_mat, _sample_mat]:
		if m != null:
			m.set_shader_parameter("feed_aspect", 1.0 if role == "demo" else hub.feed_aspect(role))
			m.set_shader_parameter("zoom", zoom)
	if sampling:
		_sample_left -= dt
		if _sample_left <= 0.0:
			_sample_left = SAMPLE_EVERY_S
			var img := _sampler.get_texture().get_image()
			if img != null and not img.is_empty():
				img.convert(Image.FORMAT_L8)
				feed_frame(img.get_data(), img.get_width(), img.get_height(), SAMPLE_EVERY_S)
	queue_redraw()
	_art.queue_redraw()

## One grey frame of the view (w x h bytes): the flow from the frame before it is measured
## and the drawn arrows ease towards it. The tests call this with made-up frames.
func feed_frame(grey: PackedByteArray, w: int, h: int, dt := SAMPLE_EVERY_S) -> void:
	if not flow_enabled:
		return
	if _prev.size() == grey.size() and w * h == grey.size():
		var now := flow.estimate(_prev, grey, w, h)
		if cells.size() != now.size():
			cells = now
		else:
			for i in now.size():
				cells[i].ok = now[i].ok
				cells[i].v = (cells[i].v as Vector2).lerp(now[i].v, 0.6) if now[i].ok else Vector2.ZERO
		mean_flow = mean_flow.lerp(OpticalFlow.mean(now), 0.6)
		if OpticalFlow.tracked(now) > 0 and OpticalFlow.mean(now).length() < STILL_PX:
			_still_s += dt
		else:
			_still_s = 0.0
		locked = _still_s >= LOCK_AFTER_S
	_prev = grey

func reset() -> void:
	_prev = PackedByteArray()
	cells = []
	mean_flow = Vector2.ZERO
	locked = false
	_still_s = 0.0

# ------------------------------------------------------------------ drawing
func _px(p: Vector2) -> Vector2:
	return p.snapped(Vector2(2, 2))

## A line in 2 px steps (pixel-art look, like the rest of the score game's HUD).
func _line(a: Vector2, b: Vector2, col: Color, w := 2.0) -> void:
	_art.draw_line(_px(a), _px(b), col, w)

## The panel behind the disc: the same dark glass as the hand panel on the left.
func _draw() -> void:
	var st := state()
	var col := YELLOW if st == "LOCK" else (MAGENTA if st == "MOVE" else CYAN)
	draw_rect(Rect2(Vector2.ZERO, RECT.size), Color(0.02, 0.05, 0.16, 0.92))
	draw_rect(Rect2(Vector2.ONE, RECT.size - Vector2(2, 2)), Color(col, 0.6), false, 2.0)
	for corner in [Vector2.ZERO, Vector2(RECT.size.x - 4.0, 0), Vector2(0, RECT.size.y - 4.0), RECT.size - Vector2(4, 4)]:
		draw_rect(Rect2(corner, Vector2(4, 4)), DARK)
	draw_circle(centre(), RADIUS + 2.0, DARK)

func _draw_art() -> void:
	var c := centre()
	var st := state()
	var col := YELLOW if st == "LOCK" else (MAGENTA if st == "MOVE" else CYAN)
	# the bezel: a dark ring, the neon ring, ticks every 30 degrees, a turning dashed ring
	_art.draw_arc(c, RADIUS + 5.0, 0, TAU, 48, DARK, 8.0)
	_art.draw_arc(c, RADIUS + 3.0, 0, TAU, 48, col, 2.0)
	for i in 12:
		var a := TAU * i / 12.0
		var d := Vector2(cos(a), sin(a))
		_line(c + d * (RADIUS - (10.0 if i % 3 == 0 else 5.0)), c + d * RADIUS, Color(col, 0.9))
	for i in 16:
		var a := TAU * i / 16.0 + _t * (1.6 if st == "MOVE" else 0.5)
		_art.draw_arc(c, RADIUS + 7.0, a, a + TAU / 40.0, 3, Color(col, 0.8), 2.0)
	# range rings and the crosshair (a gap in the middle so the target stays visible)
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
	# the brackets: wide while it moves, closing in and yellow when it holds still
	var gap := 20.0 if st == "LOCK" else 30.0 + 3.0 * sin(_t * 6.0)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var p := c + Vector2(sx, sy) * gap
			_line(p, p - Vector2(sx * 10.0, 0), col, 2.0)
			_line(p, p - Vector2(0, sy * 10.0), col, 2.0)
	_draw_flow(c)
	# under the disc: what it is, the state, how fast the view moves
	var y := c.y + RADIUS + 20.0
	PixelText.draw_centered(_art, "ARM CAM", Vector2(c.x, y), 2.0, CYAN, DARK)
	if st != "LOCK" or int(_t * 4.0) % 2 == 0:
		PixelText.draw_centered(_art, st, Vector2(c.x, y + 22.0), 2.0, col, DARK)
	var speed := clampf(mean_flow.length() / flow.search, 0.0, 1.0)
	for i in 10:
		var on := i < int(round(speed * 10.0))
		_art.draw_rect(Rect2(8.0 + i * 12.0, y + 38.0, 9, 6), (YELLOW if i >= 7 else CYAN) if on else Color(CYAN, 0.18))
	PixelText.draw_centered(_art, "FLOW %+d %+d" % [int(round(mean_flow.x * 10.0)), int(round(mean_flow.y * 10.0))], Vector2(c.x, y + 58.0), 2.0,
		Color(CYAN, 0.9), DARK)

## The optical flow: an arrow per cell (a dot where it is still), and the whole view's from the middle.
func _draw_flow(c: Vector2) -> void:
	if not flow_enabled:
		return
	for cell in cells:
		var p := c + ((cell.at as Vector2) - Vector2(0.5, 0.5)) * 2.0 * RADIUS
		if (p - c).length() > RADIUS - 8.0:
			continue
		if not cell.ok:
			continue
		var v: Vector2 = cell.v
		if v.length() < 0.3:
			_art.draw_rect(Rect2(_px(p) - Vector2(1, 1), Vector2(2, 2)), Color(CYAN, 0.6))
			continue
		var k := clampf(v.length() / flow.search, 0.0, 1.0)
		var acol := CYAN.lerp(YELLOW, clampf(k * 2.0, 0.0, 1.0)).lerp(MAGENTA, clampf(k * 2.0 - 1.0, 0.0, 1.0))
		var tip := p + (v * ARROW_GAIN).limit_length(ARROW_MAX)
		_line(p, tip, DARK, 4.0)
		_line(p, tip, acol, 2.0)
		_art.draw_rect(Rect2(_px(tip) - Vector2(3, 3), Vector2(6, 6)), DARK)
		_art.draw_rect(Rect2(_px(tip) - Vector2(2, 2), Vector2(4, 4)), acol.lerp(Color.WHITE, 0.4))
	if mean_flow.length() >= STILL_PX:
		var tip := c + (mean_flow * ARROW_GAIN * 2.0).limit_length(RADIUS - 10.0)
		var d := (tip - c).normalized()
		_line(c, tip, DARK, 6.0)
		_line(c, tip, Color.WHITE, 2.0)
		_art.draw_colored_polygon(PackedVector2Array([tip + d * 8.0, tip + d.orthogonal() * 6.0, tip - d.orthogonal() * 6.0]), Color.WHITE)

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
	for gy in range(-1, 10):  # the wood's knots and specks (something for the flow to hold on to everywhere)
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
