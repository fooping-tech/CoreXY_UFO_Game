extends Node2D
## Subtle starry night-blue background with a gentle twinkle.
var _stars: Array = []
var _t := 0.0

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in range(140):
		_stars.append({"p": Vector2(rng.randf() * 1920.0, rng.randf() * 1080.0), "s": rng.randf_range(1.0, 3.0), "ph": rng.randf() * TAU, "sp": rng.randf_range(0.5, 2.0)})
	z_index = -10

func _process(dt: float) -> void:
	_t += dt
	queue_redraw()

func _draw() -> void:
	var vs := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0.05, 0.08, 0.24))
	# soft glow band near the floor
	draw_rect(Rect2(Vector2(0, vs.y * 0.82), Vector2(vs.x, vs.y * 0.18)), Color(0.09, 0.14, 0.34))
	for s in _stars:
		var a: float = 0.45 + 0.45 * sin(_t * s.sp + s.ph)
		var sz: float = s.s
		draw_rect(Rect2(s.p - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), Color(0.85, 0.92, 1.0, a))
