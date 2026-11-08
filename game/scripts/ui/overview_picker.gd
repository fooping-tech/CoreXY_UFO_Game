class_name OverviewPicker
extends TextureRect
## A camera view you can click (homework stage 2, #78): the whole frame (no crop) at its
## own aspect, so a click maps to (u, v) = 0..1 of the image exactly as it is sent to
## Jev / Claude and as the calibration uses it.
## Draws the calibration points and, when calibrated, where the arm's camera looks.
## `center_cross` draws a crosshair in the middle instead (the arm camera's aim).
## The marks are drawn on a child without the camera shader: the shader on this node
## would replace their colours with the camera's.

signal picked(uv: Vector2)

var hw: HomeworkClient
var clickable := false
var center_cross := false
## The marks' layer (no material, so the drawing keeps its own colours).
var overlay := Control.new()

func _init() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.name = "Marks"
	overlay.use_parent_material = false
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_marks)
	add_child(overlay)

## The material shows the whole frame stretched over the drawn rect (fit 0, no disc).
func use_material(m: ShaderMaterial) -> void:
	m.set_shader_parameter("fit", 0)
	m.set_shader_parameter("circle", false)
	material = m

## Where the texture is drawn inside this control (keep aspect, centered).
func image_rect() -> Rect2:
	var tex_size := texture.get_size() if texture != null else Vector2.ZERO
	return fit_rect(size, tex_size)

static func fit_rect(area: Vector2, tex_size: Vector2) -> Rect2:
	if tex_size.x <= 0 or tex_size.y <= 0 or area.x <= 0 or area.y <= 0:
		return Rect2(Vector2.ZERO, area)
	var s := minf(area.x / tex_size.x, area.y / tex_size.y)
	var drawn := tex_size * s
	return Rect2((area - drawn) * 0.5, drawn)

## Control position -> (u, v) in 0..1, or null outside the image.
func uv_at(pos: Vector2):
	var r := image_rect()
	if not r.has_point(pos):
		return null
	return (pos - r.position) / r.size

func _gui_input(event: InputEvent) -> void:
	if not clickable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var uv = uv_at(event.position)
		if uv != null:
			picked.emit(uv)
			accept_event()

func _process(_dt: float) -> void:
	if is_visible_in_tree():
		overlay.queue_redraw()

func _draw_marks() -> void:
	var o := overlay
	var r := image_rect()
	if center_cross:
		var c := r.get_center()
		var col := Color(1.0, 0.25, 0.25, 0.9)
		o.draw_line(c - Vector2(14, 0), c + Vector2(14, 0), col, 2.0)
		o.draw_line(c - Vector2(0, 14), c + Vector2(0, 14), col, 2.0)
		o.draw_arc(c, 6.0, 0, TAU, 20, col, 1.0)
		return
	if hw == null:
		return
	var pts = hw.camera_map.get("points", [])
	if pts is Array:
		var i := 0
		for p in pts:
			i += 1
			var at := r.position + Vector2(float(p.u), float(p.v)) * r.size
			o.draw_circle(at, 4.0, Color(0.2, 1.0, 1.0, 0.9))
			o.draw_string(ThemeDB.fallback_font, at + Vector2(5, -5), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.2, 1.0, 1.0))
	var aim = hw.arm_view_uv()
	if aim is Vector2 and Rect2(Vector2.ZERO, Vector2.ONE).grow(0.05).has_point(aim):
		var c2: Vector2 = r.position + aim * r.size
		var col2 := Color(1.0, 0.3, 0.3, 0.95)
		o.draw_arc(c2, 9.0, 0, TAU, 24, col2, 2.0)
		o.draw_line(c2 - Vector2(14, 0), c2 + Vector2(14, 0), col2, 1.5)
		o.draw_line(c2 - Vector2(0, 14), c2 + Vector2(0, 14), col2, 1.5)
