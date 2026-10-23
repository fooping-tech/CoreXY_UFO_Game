extends Node2D
## Tiny particle bursts from the effect sheets (sparkles / stars / motion lines).
var _parts: Array = []
var _tex: Dictionary = {}
var pixel_scale := 3.0

func _ready() -> void:
	for n in ["sparkles", "stars", "motion_lines"]:
		var p := "res://assets/effects/%s.png" % n
		if ResourceLoader.exists(p):
			_tex[n] = load(p)
	z_index = 5

func burst(kind: String, count: int = 14) -> void:
	for i in range(count):
		var ang := randf() * TAU
		var spd := randf_range(60.0, 220.0)
		_parts.append({"kind": kind, "p": Vector2.ZERO, "v": Vector2(cos(ang), sin(ang)) * spd, "life": randf_range(0.6, 1.2), "t": 0.0})

func _process(dt: float) -> void:
	for p in _parts:
		p.t += dt
		p.v.y += 160.0 * dt
		p.p += p.v * dt
	_parts = _parts.filter(func(p): return p.t < p.life)
	if not _parts.is_empty():
		queue_redraw()
	elif is_visible_in_tree():
		queue_redraw()

func _draw() -> void:
	for p in _parts:
		var frame := int(p.t * 10.0) % 4
		var size := Vector2(16, 16) * pixel_scale * 0.5
		if _tex.has(p.kind):
			draw_texture_rect_region(_tex[p.kind], Rect2(p.p - size * 0.5, size), Rect2(frame * 16, 0, 16, 16))
		else:
			draw_circle(p.p, 3.0, Color(1, 0.9, 0.3))
