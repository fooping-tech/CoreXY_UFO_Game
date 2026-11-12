class_name StudyScopeView
extends Control
## The round close-up while the arm camera captures (#86). With a real focus camera
## the game's own scope view shows its frames; this one draws the mock demo's view:
## the HELP problem growing as the arm goes down (10 cm -> 5 cm -> landing), with a
## shutter flash and the stage's name.

var stage := "10cm"
var problem: Dictionary = {}
var _shutter := 0.0
var _t := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func shutter() -> void:
	_shutter = 1.0

func _process(dt: float) -> void:
	if visible:
		_t += dt
		_shutter = maxf(_shutter - dt * 3.0, 0.0)
		queue_redraw()

func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	var c := size * 0.5
	var zoom: float = {"10cm": 1.0, "5cm": 1.6, "landing": 2.4}.get(stage, 1.0)
	draw_circle(c, r + 8, Color("0b4a68"))
	draw_circle(c, r, Color("fffdf6"))
	var font := get_theme_default_font()
	var text := str(problem.get("prompt", ""))
	var fs := int(14 * zoom)
	var wobble := Vector2(sin(_t * 7.0), cos(_t * 5.0)) * (2.0 if _shutter <= 0.0 else 0.0) / zoom
	draw_string(font, c + Vector2(-r * 0.8, -r * 0.25) + wobble, text, HORIZONTAL_ALIGNMENT_LEFT, r * 1.6, fs, Color("1d2433"))
	var box := Rect2(c + Vector2(r * 0.05, r * 0.05) + wobble, Vector2(r * 0.6, r * 0.38) * minf(zoom, 1.4))
	draw_rect(box, Color("1d2433"), false, 2.0)
	# reticle
	draw_arc(c, r * 0.3, 0, TAU, 48, Color(0.1, 0.6, 0.9, 0.6), 2.0)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0.1, 0.6, 0.9, 0.35), 1.0)
	draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0.1, 0.6, 0.9, 0.35), 1.0)
	draw_arc(c, r, 0, TAU, 96, Color("4fd0ec"), 6.0)
	var names := {"10cm": "10cm 上", "5cm": "5cm 上", "landing": "いちばん近く"}
	draw_string(font, c + Vector2(-r, r + 34), str(names.get(stage, stage)), HORIZONTAL_ALIGNMENT_CENTER, r * 2, 22, Color("ffe03c"))
	if _shutter > 0.0:
		draw_circle(c, r, Color(1, 1, 1, _shutter))
