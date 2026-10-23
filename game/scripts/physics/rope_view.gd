class_name RopeView
extends Node2D
## Draws the projected rope as a textured polyline. Reads the simulator and the
## projection; writes nothing back.

var rope_width_px: float = 6.0
var texture: Texture2D
var connector: Texture2D
var connector_anchor := Vector2(8, 13)
var pixel_scale: float = 3.0
var _points: PackedVector2Array = PackedVector2Array()
var _ufo_screen := Vector2.ZERO
var _ufo_scale := 1.0

func _ready() -> void:
	if ResourceLoader.exists("res://assets/rope/rope_texture.png"):
		texture = load("res://assets/rope/rope_texture.png")
	if ResourceLoader.exists("res://assets/rope/rope_connector.png"):
		connector = load("res://assets/rope/rope_connector.png")

func update_rope(sim: RopeSimulator, proj: Projection25D) -> void:
	_points.resize(sim.points.size())
	for i in range(sim.points.size()):
		_points[i] = proj.project(sim.points[i].position).screen
	var r := proj.project(sim.ufo_position())
	_ufo_screen = r.screen
	_ufo_scale = r.scale
	queue_redraw()

func _draw() -> void:
	if _points.size() < 2:
		return
	# Shadow / outline first for pixel-art readability.
	draw_polyline(_points, Color(0.03, 0.1, 0.3, 0.9), rope_width_px + 2.0, false)
	if texture != null:
		# Draw each segment as a textured quad to keep the striped look.
		for i in range(_points.size() - 1):
			var a := _points[i]
			var b := _points[i + 1]
			var d := b - a
			var len := d.length()
			if len < 0.5:
				continue
			var n := Vector2(-d.y, d.x).normalized() * rope_width_px * 0.5
			var quad := PackedVector2Array([a - n, b - n, b + n, a + n])
			var v := len / (16.0 * pixel_scale)
			var uvs := PackedVector2Array([Vector2(0, 0), Vector2(0, v), Vector2(1, v), Vector2(1, 0)])
			draw_polygon(quad, PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]), uvs, texture)
	else:
		draw_polyline(_points, Color(0.1, 0.55, 0.85), rope_width_px, false)
	# Anchor plate at the very top (the only "mechanical" thing we show: the
	# ceiling the rope comes out of, not the real crane).
	var top := _points[0]
	draw_rect(Rect2(top + Vector2(-14, -8), Vector2(28, 8)), Color(0.03, 0.1, 0.3))
	draw_rect(Rect2(top + Vector2(-10, -6), Vector2(20, 4)), Color(0.16, 0.5, 0.85))
	# Connector knot at the UFO end
	if connector != null:
		var s := pixel_scale * _ufo_scale
		draw_texture_rect(connector, Rect2(_ufo_screen - connector_anchor * s, Vector2(16, 16) * s), false)
