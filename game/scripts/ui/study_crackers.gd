class_name StudyCrackers
extends Control
## Party crackers from the bottom left and right corners: streamers and paper bits
## flying up and falling (the homework-complete moment). Drawn over the HUD; the
## pixelfx confetti and sparkles play in the world (vfx_director.gd).

const COLORS := [Color("3cc8ff"), Color("ffe03c"), Color("5ad84a"), Color("f53cd1"), Color("7a6cff"), Color("ff8a3c")]
var parts: Array = []  # [pos, vel, color, spin, life, w, h]
var bursts := 0

func burst(count := 90) -> void:
	bursts += 1
	var vs := get_viewport_rect().size
	for side in [-1.0, 1.0]:
		var origin := Vector2(0.0 if side < 0.0 else vs.x, vs.y)
		for i in count:
			var ang := deg_to_rad(randf_range(50.0, 80.0))
			var speed := randf_range(700.0, 1250.0)
			var v := Vector2(cos(ang) * speed * -side, -sin(ang) * speed)
			parts.append([origin, v, COLORS[randi() % COLORS.size()], randf_range(-8.0, 8.0), randf_range(2.2, 3.6),
				randf_range(6.0, 12.0), randf_range(10.0, 26.0)])

func _process(dt: float) -> void:
	if parts.is_empty():
		return
	for p in parts:
		p[1] = p[1] * (1.0 - 1.2 * dt) + Vector2(0, 700.0) * dt
		p[0] += p[1] * dt
		p[3] += dt * 6.0
		p[4] -= dt
	parts = parts.filter(func(p): return p[4] > 0.0)
	queue_redraw()

func _draw() -> void:
	for p in parts:
		var w: float = p[5] * absf(cos(p[3]))
		draw_set_transform(p[0], p[3] * 0.3, Vector2.ONE)
		draw_rect(Rect2(-w * 0.5, -p[6] * 0.5, maxf(w, 2.0), p[6]), p[2])
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
