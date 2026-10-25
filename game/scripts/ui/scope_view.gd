class_name ScopeView
extends Control
## The round "telescope" view on the right of the play area: the focus camera
## (arm tip) cropped to a disc, wrapped in a targeting HUD - rotating rings with
## ticks, a crosshair, lock-on brackets, a Z gauge, coordinates and a status
## line - plus a dotted beam from the UFO's spyglass. It irises open / closed.
##
## Presentation only. Drawn behind the UFO in the play field (it shakes along).
## Without a focus camera it falls back to the overview camera, then NO SIGNAL.

const CYAN := Color(0.35, 0.95, 1.0)
const PINK := Color(1.0, 0.35, 0.72)
const GOLD := Color(1.0, 0.8, 0.25)

var hub: CameraHub
## Seconds to open fully (closing is a bit faster).
var open_time_s := 0.35
var zoom := 1.0
var open_amount := 0.0
var wanted := false
var center := Vector2(900, 300)
var radius := 150.0
## Spyglass lens on screen (beam start); `show_beam` off hides the beam.
var beam_from := Vector2.ZERO
var show_beam := false
## Lines under the disc ("X 120.0  Y 80.0  Z 40.0") and the Z gauge level 0..1 (<0 = hidden).
var readout := ""
var z_level := -1.0
## Arm moving down / game lowering: the status line says LOCK instead of SCANNING.
var locking := false

var _cam: TextureRect
var _hud: Control
var _mat: ShaderMaterial
var _t := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_cam = TextureRect.new()
	_cam.name = "Camera"
	_cam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cam.stretch_mode = TextureRect.STRETCH_SCALE
	_cam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cam)
	_hud = Control.new()
	_hud.name = "Hud"
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_hud)
	_hud.draw.connect(_draw_hud)
	visible = false

func attach(h: CameraHub) -> void:
	hub = h
	_mat = h.view_material(true)
	_mat.set_shader_parameter("scanlines", 0.18)
	_cam.material = _mat

## Which camera the disc shows: "focus", "overview" (fallback) or "" (none).
func source_role() -> String:
	if hub == null:
		return ""
	if hub.has_feed("focus"):
		return "focus"
	if hub.has_feed("overview"):
		return "overview"
	return ""

func is_fully_open() -> bool:
	return open_amount >= 1.0

## Advance the iris and redraw. Called by the main scene every render frame.
func step(dt: float) -> void:
	_t += dt
	var rate := 1.0 / maxf(open_time_s, 0.01)
	open_amount = move_toward(open_amount, 1.0 if wanted else 0.0, dt * rate * (1.0 if wanted else 1.4))
	visible = open_amount > 0.0
	if not visible:
		return
	var e := _ease()
	_cam.position = center - Vector2(radius, radius)
	_cam.size = Vector2(radius, radius) * 2.0
	if hub != null:
		var role := source_role()
		if role == "":
			role = "focus"  # its static
		_cam.texture = hub.texture(role)
		_mat.set_shader_parameter("feed_aspect", hub.feed_aspect(role))
		_mat.set_shader_parameter("open", e)
		_mat.set_shader_parameter("zoom", zoom)
	_hud.queue_redraw()

func _ease() -> float:
	return 1.0 - pow(1.0 - open_amount, 3.0)

# ------------------------------------------------------------ HUD drawing
func _glow_arc(c: Vector2, r: float, a0: float, a1: float, col: Color, w: float) -> void:
	_hud.draw_arc(c, r, a0, a1, 64, Color(col, col.a * 0.25), w * 3.0, true)
	_hud.draw_arc(c, r, a0, a1, 64, col, w, true)

func _glow_line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
	_hud.draw_line(a, b, Color(col, col.a * 0.25), w * 3.0, true)
	_hud.draw_line(a, b, col, w, true)

func _text(pos: Vector2, s: String, size: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	var f := ThemeDB.fallback_font
	_hud.draw_string(f, pos + Vector2(1, 1), s, align, width, size, Color(0, 0, 0, col.a * 0.6))
	_hud.draw_string(f, pos, s, align, width, size, col)

func _draw_hud() -> void:
	var e := _ease()
	var a := clampf(open_amount * 1.6, 0.0, 1.0)
	var c := center
	var r := radius
	var cyan := Color(CYAN, a)
	var role := source_role()

	# beam from the spyglass to the disc
	if show_beam and a > 0.0:
		var to := c + (beam_from - c).normalized() * (r + 4.0) if beam_from.distance_to(c) > r else c
		var n := int(beam_from.distance_to(to) / 14.0)
		for i in range(n):
			var k := (float(i) + fmod(_t * 3.0, 1.0)) / maxf(n, 1)
			_hud.draw_circle(beam_from.lerp(to, k), 2.0, Color(GOLD, a * (0.35 + 0.65 * k)))

	# disc rim
	_glow_arc(c, r * e + 2.0, 0.0, TAU, cyan, 2.0)
	# ring 1: ticks, slowly turning
	var r1 := r * e + 10.0
	var spin := _t * 0.35
	for i in range(72):
		var ang := spin + TAU * i / 72.0
		var long := i % 6 == 0
		var d := Vector2(cos(ang), sin(ang))
		_hud.draw_line(c + d * r1, c + d * (r1 + (10.0 if long else 4.0)), Color(CYAN, a * (0.9 if long else 0.45)), 2.0 if long else 1.0)
	# ring 2: four arcs turning the other way
	var r2 := r * e + 30.0
	for i in range(4):
		var a0 := -_t * 0.8 + TAU * i / 4.0
		_glow_arc(c, r2, a0, a0 + deg_to_rad(52.0), cyan, 2.0)
	# crosshair (with range ticks on the horizontal)
	var g := r * 0.12
	var arm := r * 0.42 * e
	var ch := Color(CYAN, a * 0.85)
	for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		_glow_line(c + d * g, c + d * (g + arm), ch, 1.5)
	for k in range(1, 4):
		for sx: float in [-1.0, 1.0]:
			var x := c.x + sx * (g + arm * k / 4.0)
			_hud.draw_line(Vector2(x, c.y - 4.0), Vector2(x, c.y + 4.0), ch, 1.0)
	var dia := PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0), c + Vector2(0, -5)])
	_hud.draw_polyline(dia, Color(PINK, a), 2.0, true)

	# lock-on brackets: come in from wide while opening, pulse while locking
	var pulse := 1.0 + (0.04 * sin(_t * 10.0) if locking else 0.0)
	var h := (r + 46.0) * lerpf(1.6, 1.0, e) * pulse
	var bl := r * 0.35
	var bcol := Color(PINK if locking else CYAN, a)
	for s: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var p := c + s * h
		_glow_line(p, p - Vector2(s.x * bl, 0), bcol, 2.5)
		_glow_line(p, p - Vector2(0, s.y * bl), bcol, 2.5)

	# Z gauge on the right
	if z_level >= 0.0:
		var gx := c.x + h + 14.0
		var top := c.y - r * 0.9
		var bot := c.y + r * 0.9
		_hud.draw_line(Vector2(gx, top), Vector2(gx, bot), Color(CYAN, a * 0.6), 2.0)
		for k in range(11):
			var y := lerpf(top, bot, k / 10.0)
			_hud.draw_line(Vector2(gx, y), Vector2(gx + (8.0 if k % 5 == 0 else 4.0), y), Color(CYAN, a * 0.6), 1.0)
		var py := lerpf(bot, top, clampf(z_level, 0.0, 1.0))
		_hud.draw_colored_polygon(PackedVector2Array([Vector2(gx - 2, py), Vector2(gx - 12, py - 6), Vector2(gx - 12, py + 6)]), Color(GOLD, a))
		_text(Vector2(gx - 8, top - 8), "Z", 13, Color(CYAN, a))

	# labels
	var left := c.x - h
	var cam_name := "FOCUS CAM" if role == "focus" else ("OVERVIEW CAM" if role == "overview" else "FOCUS CAM")
	_text(Vector2(left, c.y - h - 10.0), "◢ " + cam_name, 15, Color(CYAN, a))
	if role == "":
		var blink := 0.55 + 0.45 * sin(_t * 6.0)
		_text(Vector2(c.x - r, c.y + 7.0), "NO SIGNAL", 22, Color(PINK, a * blink), HORIZONTAL_ALIGNMENT_CENTER, r * 2.0)
	var status := "TARGET LOCK" if locking else "SCANNING" + ".".repeat(int(_t * 3.0) % 4)
	var scol := Color(PINK, a * (0.55 + 0.45 * sin(_t * 9.0))) if locking else Color(CYAN, a)
	_text(Vector2(left, c.y + h + 22.0), status, 17, scol)
	if readout != "":
		_text(Vector2(left, c.y + h + 42.0), readout, 13, Color(CYAN, a * 0.85))
