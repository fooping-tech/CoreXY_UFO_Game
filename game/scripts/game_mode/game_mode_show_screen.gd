class_name GameModeShowScreen
extends Control
## What the result's show (GameModeResultScreen) and the high scores (GameModeRankingHud)
## share: the picture's root in the game mode's pixel canvas (a back layer, a particle pool,
## a front layer), the centred labels on top, the pixelfx sheets over the picture and the
## turning rays. It decides nothing; each screen says what is on and draws its own picture
## in _draw_back / _draw_front.

const SCREEN := GameModeLayout.SCREEN
const RAYS := 14
const DARK := Color("050818")

var ctl: GameModeController
## the picture's root, in the pixel canvas (over the field, the effects and the UFO)
var art: Node2D
## the screen's own sparks, rings and confetti (the same pool class as the field's)
var particles: GameModeParticles
var _back: Node2D
var _front: Node2D
var _t := 0.0

## The Control over the HUD (z) and the picture's root in the canvas (art_z).
func _build_art(c: GameModeController, z: int, art_name: String, art_z: int, particles_name: String) -> void:
	ctl = c
	size = SCREEN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = z
	art = Node2D.new()
	art.name = art_name
	art.z_index = art_z
	art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	art.visible = false
	c.pixel_view.add_child(art)
	_back = Node2D.new()
	_back.name = "Back"
	_back.draw.connect(_draw_back)
	art.add_child(_back)
	particles = GameModeParticles.new()
	particles.name = particles_name
	art.add_child(particles)
	_front = Node2D.new()
	_front.name = "Front"
	_front.z_index = 2
	_front.draw.connect(_draw_front)
	art.add_child(_front)

## A centred line across the screen, at y.
func _label(font_size: int, color: Color, y: float, h: float) -> Label:
	var l := StudyHud.label("", font_size, color, maxi(font_size / 6, 3))
	l.add_theme_color_override("font_outline_color", DARK)
	l.position = Vector2(20, y)
	l.size = Vector2(SCREEN.x - 40.0, h)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(l)
	return l

## A pixelfx sheet over the picture (confetti, sparkles...), in the canvas.
func sheet(id: String, at: Vector2, sheet_scale := 2.0, color := Color.WHITE) -> void:
	if ctl.effects and art.visible:
		VFXManager.spawn_fx(id, at, {"parent": art, "scale": sheet_scale, "color": color, "layer": "front"})

## Everything of the show that is still on the screen goes (a new round, the title).
func clear() -> void:
	particles.clear()
	for c in art.get_children():
		if c.is_in_group("vfx"):
			VFXManager.stop_fx(c)

func sheets() -> int:
	var n := 0
	for c in art.get_children():
		if c.is_in_group("vfx") and not c.is_queued_for_deletion():
			n += 1
	return n

## The particles' time (the controller's tick: the same clock as the cues).
func advance(dt: float) -> void:
	particles.z_index = 1  # (the pool's own _ready puts it at the field's height)
	particles.effects = ctl.effects
	particles.quality = ctl.visual_quality
	particles.advance(dt)

func _draw_back() -> void:
	pass

func _draw_front() -> void:
	pass

## The rays that turn behind the middle of the picture, one colour after another.
func _draw_rays(centre: Vector2, turn: float, cols: Array, alpha: float) -> void:
	for i in RAYS:
		var a := turn + TAU * i / RAYS
		var w := TAU / RAYS * 0.5
		var col: Color = cols[i % cols.size()]
		_back.draw_colored_polygon(PackedVector2Array([centre, centre + Vector2(cos(a), sin(a)) * 900.0,
			centre + Vector2(cos(a + w), sin(a + w)) * 900.0]), Color(col.r, col.g, col.b, alpha))
