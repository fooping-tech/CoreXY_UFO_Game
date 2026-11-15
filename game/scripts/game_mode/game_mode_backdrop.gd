class_name GameModeBackdrop
extends Node2D
## The score game's background (#141): a space arcade behind the field. Deep navy bands,
## faint nebulae, three layers of stars that drift at different speeds (a quiet parallax),
## slow motes of light, now and then a shooting star, and beside the field a conduit from
## each Dial's port with small panel lights. It stays in the back: low contrast, slow.
##
## Presentation only. Everything is laid out once (a fixed seed) and only moved in
## advance(dt): no nodes are made or freed while it runs. `quality` "low" keeps the bands
## and one layer of still stars.

const SIZE := Vector2(1280, 720)
const BANDS := 12
const TOP_COLOR := Color("02041a")
const BOTTOM_COLOR := Color("0d0a33")
## [count, pixel size, speed px/s, alpha]
const STAR_LAYERS := [[70, 2.0, 3.0, 0.35], [40, 2.0, 7.0, 0.6], [16, 4.0, 14.0, 0.9]]
const MOTES := 14
const NEBULAE := 5
const SHOOT_EVERY_S := 7.0
const CYAN := Color("3ff0ff")
const MAGENTA := Color("ff4fd8")
const PURPLE := Color("8a5cff")

var quality := "high"
## the colour of each side's conduit (the Dial's colour)
var side_colors := {"left": Color("00ffff"), "right": Color("ff00ff")}
## where each conduit starts (the port) and the field's edges
var ports := {"left": Vector2(75, 640), "right": Vector2(1205, 640)}
var _stars: Array = []  # per layer: Array of [x, y, phase]
var _motes: Array = []  # [x, y, phase, colour]
var _nebulae: Array = []  # [centre, colour, Array of [offset, size]]
var _shoot := {"t": -1.0, "from": Vector2.ZERO, "dir": Vector2.ZERO}
var _shoot_left := 3.0
var _flash := 0.0
var _flash_color := Color.WHITE
var _side_glow := {"left": 0.0, "right": 0.0}
var _t := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	z_index = -5  # over the plain colour, under everything else of the game mode
	_rng.seed = 141
	_layout()

func _layout() -> void:
	_stars.clear()
	for l in STAR_LAYERS:
		var layer: Array = []
		for i in int(l[0]):
			layer.append([_rng.randf() * SIZE.x, _rng.randf() * SIZE.y, _rng.randf() * TAU])
		_stars.append(layer)
	_motes.clear()
	for i in MOTES:
		_motes.append([_rng.randf() * SIZE.x, _rng.randf() * SIZE.y, _rng.randf() * TAU, CYAN if i % 2 == 0 else MAGENTA])
	_nebulae.clear()
	for i in NEBULAE:
		var blobs: Array = []
		for j in 14:
			blobs.append([Vector2(_rng.randf_range(-150, 150), _rng.randf_range(-90, 90)), _rng.randf_range(28, 64)])
		_nebulae.append([Vector2(_rng.randf() * SIZE.x, _rng.randf_range(60, 640)), [PURPLE, CYAN, MAGENTA][i % 3], blobs])

func star_count() -> int:
	var n := 0
	for i in _stars.size():
		if quality != "low" or i == 1:
			n += (_stars[i] as Array).size()
	return n

## The whole background glows for a moment (a bonus, the last 30 seconds).
func pulse(color: Color, strength := 0.5) -> void:
	_flash = clampf(maxf(_flash, strength), 0.0, 1.0)
	_flash_color = color

## One side's conduit lights up (a capsule passes that Dial's port).
func side_pulse(side: String, strength := 1.0) -> void:
	if _side_glow.has(side):
		_side_glow[side] = clampf(maxf(_side_glow[side], strength), 0.0, 1.0)

func flash_level() -> float:
	return _flash

func side_level(side: String) -> float:
	return _side_glow.get(side, 0.0)

func advance(dt: float) -> void:
	_t += dt
	_flash = maxf(_flash - dt * 1.6, 0.0)
	for s in _side_glow.keys():
		_side_glow[s] = maxf(_side_glow[s] - dt * 1.2, 0.0)
	if quality == "low":
		return
	for i in _stars.size():
		var speed: float = STAR_LAYERS[i][2]
		for s in _stars[i]:
			s[0] = fposmod(s[0] - speed * dt * 0.6, SIZE.x)
			s[1] = fposmod(s[1] + speed * dt * 0.25, SIZE.y)
	for m in _motes:
		m[1] = fposmod(m[1] - 9.0 * dt, SIZE.y)
		m[0] = fposmod(m[0] + sin(_t * 0.6 + m[2]) * 6.0 * dt, SIZE.x)
	for n in _nebulae:
		n[0].x = fposmod(n[0].x - 2.0 * dt + 200.0, SIZE.x + 400.0) - 200.0
	_shoot_left -= dt
	if _shoot.t >= 0.0:
		_shoot.t += dt
		if _shoot.t > 0.9:
			_shoot.t = -1.0
	elif _shoot_left <= 0.0:
		_shoot_left = SHOOT_EVERY_S + _rng.randf() * 5.0
		_shoot = {"t": 0.0, "from": Vector2(_rng.randf_range(200, 1200), _rng.randf_range(10, 120)),
			"dir": Vector2(-1.0, 0.45).normalized()}

func _process(_dt: float) -> void:
	queue_redraw()

func _draw() -> void:
	var band_h := SIZE.y / BANDS
	for i in BANDS:
		draw_rect(Rect2(0, i * band_h, SIZE.x, band_h + 1.0), TOP_COLOR.lerp(BOTTOM_COLOR, float(i) / (BANDS - 1)))
	if quality != "low":
		for n in _nebulae:
			var col: Color = n[1]
			for b in n[2]:
				var p: Vector2 = (n[0] + b[0]).snapped(Vector2(4, 4))
				draw_rect(Rect2(p - Vector2(b[1], b[1]) * 0.5, Vector2(b[1], b[1])), Color(col.r, col.g, col.b, 0.022))
	for i in _stars.size():
		if quality == "low" and i != 1:
			continue
		var size: float = STAR_LAYERS[i][1]
		var alpha: float = STAR_LAYERS[i][3]
		for s in _stars[i]:
			var tw := 0.65 + 0.35 * sin(_t * (1.0 + i) + s[2])
			var p := Vector2(s[0], s[1]).snapped(Vector2(2, 2))
			var c := Color(0.85, 0.92, 1.0, alpha * tw)
			draw_rect(Rect2(p, Vector2(size, size)), c)
			if i == 2:  # the near stars are little crosses
				draw_rect(Rect2(p + Vector2(-size, 0), Vector2(size * 3.0, size)), Color(c.r, c.g, c.b, c.a * 0.45))
				draw_rect(Rect2(p + Vector2(0, -size), Vector2(size, size * 3.0)), Color(c.r, c.g, c.b, c.a * 0.45))
	if quality != "low":
		for m in _motes:
			var col: Color = m[3]
			var a := 0.12 + 0.1 * sin(_t * 1.3 + m[2])
			var p := Vector2(m[0], m[1]).snapped(Vector2(2, 2))
			draw_rect(Rect2(p - Vector2(4, 4), Vector2(12, 12)), Color(col.r, col.g, col.b, a * 0.4))
			draw_rect(Rect2(p, Vector2(4, 4)), Color(col.r, col.g, col.b, a * 2.0))
		if _shoot.t >= 0.0:
			var sdir: Vector2 = _shoot.dir
			var st: float = _shoot.t
			var head: Vector2 = _shoot.from + sdir * 520.0 * st
			for j in 10:
				var q: Vector2 = (head - sdir * 9.0 * j).snapped(Vector2(2, 2))
				draw_rect(Rect2(q, Vector2(4, 4) if j < 3 else Vector2(2, 2)), Color(1, 1, 1, (1.0 - j / 10.0) * (1.0 - st)))
	_draw_sides()
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, SIZE), Color(_flash_color.r, _flash_color.g, _flash_color.b, 0.16 * _flash))

## Beside the field: a conduit up from each port, with a light running along it and a few
## panel lamps (the machine the capsule travels through).
func _draw_sides() -> void:
	for side in ports.keys():
		var p: Vector2 = ports[side]
		var col: Color = side_colors[side]
		var glow: float = _side_glow[side]
		var x := p.x
		# the conduit
		draw_rect(Rect2(x - 7.0, 170.0, 14.0, p.y - 262.0), Color(0.05, 0.07, 0.2, 0.9))
		draw_rect(Rect2(x - 7.0, 170.0, 2.0, p.y - 262.0), Color(col.r, col.g, col.b, 0.35 + 0.5 * glow))
		draw_rect(Rect2(x + 5.0, 170.0, 2.0, p.y - 262.0), Color(col.r, col.g, col.b, 0.35 + 0.5 * glow))
		if glow > 0.0:
			draw_rect(Rect2(x - 13.0, 170.0, 26.0, p.y - 262.0), Color(col.r, col.g, col.b, 0.14 * glow))
		for i in 4:  # joints
			var y := 190.0 + 78.0 * i
			draw_rect(Rect2(x - 11.0, y, 22.0, 8.0), Color(0.12, 0.16, 0.36))
			draw_rect(Rect2(x - 11.0, y, 22.0, 2.0), Color(col.r, col.g, col.b, 0.5))
		if quality != "low":  # a light going along it
			for i in 3:
				var k := fmod(_t * 0.25 + i / 3.0, 1.0)
				var y := lerpf(180.0, p.y - 100.0, k)
				draw_rect(Rect2(x - 2.0, y, 4.0, 10.0), Color(col.r, col.g, col.b, 0.5 + 0.5 * glow))
		# a small panel of lamps above
		var px := x - 30.0
		draw_rect(Rect2(px, 124.0, 60.0, 34.0), Color(0.06, 0.08, 0.24, 0.95))
		draw_rect(Rect2(px, 124.0, 60.0, 2.0), Color(col.r, col.g, col.b, 0.7))
		draw_rect(Rect2(px, 156.0, 60.0, 2.0), Color(col.r, col.g, col.b, 0.3))
		for i in 4:
			var on := quality != "low" and int(_t * 2.0 + i * 1.7 + (0.0 if side == "left" else 0.9)) % 4 == 0
			var lamp := col if on or glow > 0.3 else Color(0.2, 0.26, 0.5)
			draw_rect(Rect2(px + 8.0 + 12.0 * i, 136.0, 8.0, 8.0), lamp)
			draw_rect(Rect2(px + 8.0 + 12.0 * i, 136.0, 3.0, 3.0), Color(1, 1, 1, 0.6 if on else 0.15))
