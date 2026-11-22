class_name GameModeParticles
extends Node2D
## The score game's small effects (#144), in the pixel canvas (the UFO's dots): sparks that
## fly off a hit and rings that spread from it. Both are fixed pools: a burst takes free
## slots and, when there are none, the oldest; nothing is made or freed while it runs.
##
## Presentation only. `effects` false: nothing is started. `quality` "low": half the sparks.

const MAX_SPARKS := 192
const MAX_RINGS := 16
const GRAVITY := 520.0

var effects := true
var quality := "high"
# sparks, one slot each: position, velocity, seconds left, seconds given, colour, dot size
var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _left := PackedFloat32Array()
var _life := PackedFloat32Array()
var _col := PackedColorArray()
var _size := PackedFloat32Array()
var _grav := PackedFloat32Array()  # times GRAVITY, per spark (< 0 = it rises, like an ember)
var _next := 0
var _rings: Array[Dictionary] = []
var _ring_next := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	z_index = 5  # over the field's picture, under the UFO and the pop-ups
	_rng.seed = 144
	_pos.resize(MAX_SPARKS)
	_vel.resize(MAX_SPARKS)
	_left.resize(MAX_SPARKS)
	_life.resize(MAX_SPARKS)
	_col.resize(MAX_SPARKS)
	_size.resize(MAX_SPARKS)
	_grav.resize(MAX_SPARKS)
	for i in MAX_RINGS:
		_rings.append({"at": Vector2.ZERO, "left": 0.0, "dur": 1.0, "r0": 0.0, "r1": 0.0, "color": Color.WHITE})

## How many sparks a burst of `count` really starts (the quality setting, the pool's size).
func granted(count: int) -> int:
	if not effects:
		return 0
	return clampi(count / 2 if quality == "low" else count, 0, MAX_SPARKS)

## Sparks fly from `at`. `dir` / `spread` (radians): the middle of the fan and its width
## (TAU = all round). `white`: how many of them are white instead of `color` (0..1).
## `grav`: how much gravity pulls them (1 = falling sparks, < 0 = rising embers).
func burst(at: Vector2, color: Color, count: int, speed := 240.0, dir := -PI * 0.5, spread := TAU, white := 0.3, grav := 1.0) -> void:
	for i in granted(count):
		var s := _free_slot()
		var a := dir + (_rng.randf() - 0.5) * spread
		_pos[s] = at
		_vel[s] = Vector2(cos(a), sin(a)) * speed * _rng.randf_range(0.35, 1.0)
		_life[s] = _rng.randf_range(0.35, 0.75)
		_left[s] = _life[s]
		_col[s] = Color.WHITE if _rng.randf() < white else color
		_size[s] = 4.0 if _rng.randf() < 0.4 else 2.0
		_grav[s] = grav

## The capsule kinds' own particles (#266): what a capsule of `kind` leaves behind as it
## moves ("trail", a few a call) and what flies off when it hits something ("hit").
##   fire   embers rising, orange and yellow; a hit throws a ring of flame
##   water  drops falling off it, blue and white; a hit splashes up and spreads a ripple
##   green  leaves and sparkles drifting; a hit scatters green sparkles
const KIND_COLORS := {"fire": [Color("ff3b1f"), Color("ff8a1f"), Color("ffe03c")],
	"water": [Color("2f6cff"), Color("6fc8ff"), Color("e8f8ff")],
	"green": [Color("1fb84a"), Color("7dff6a"), Color("d8ff9a")]}

func kind_trail(kind: String, at: Vector2) -> void:
	if not KIND_COLORS.has(kind):
		return
	var cols: Array = KIND_COLORS[kind]
	var col: Color = cols[_rng.randi() % cols.size()]
	match kind:
		"fire":
			burst(at + Vector2(_rng.randf_range(-10, 10), -6), col, 2, 90.0, -PI * 0.5, 1.2, 0.05, -0.35)
		"water":
			burst(at + Vector2(_rng.randf_range(-12, 12), 6), col, 1, 50.0, PI * 0.5, 1.6, 0.2, 0.9)
		"green":
			burst(at + Vector2(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12)), col, 1, 60.0, -PI * 0.5, TAU, 0.25, 0.08)

func kind_hit(kind: String, at: Vector2) -> void:
	if not KIND_COLORS.has(kind):
		return
	var cols: Array = KIND_COLORS[kind]
	match kind:
		"fire":
			burst(at, cols[1], 12, 260.0, -PI * 0.5, TAU, 0.1, -0.3)
			burst(at, cols[2], 6, 160.0, -PI * 0.5, PI, 0.2, -0.5)
			ring(at, cols[0], 54.0, 0.3)
		"water":
			burst(at, cols[1], 12, 280.0, -PI * 0.5, PI * 0.8, 0.3, 1.4)
			ring(at, cols[2], 64.0, 0.45, 12.0)
		"green":
			burst(at, cols[1], 10, 200.0, -PI * 0.5, TAU, 0.4, 0.1)
			ring(at, cols[0], 48.0, 0.35)

## A ring spreads from `at` out to radius `r1`.
func ring(at: Vector2, color: Color, r1 := 60.0, secs := 0.35, r0 := 8.0) -> void:
	if not effects:
		return
	var r: Dictionary = _rings[_ring_next]
	_ring_next = (_ring_next + 1) % MAX_RINGS
	r.at = at
	r.left = secs
	r.dur = secs
	r.r0 = r0
	r.r1 = r1
	r.color = color

func _free_slot() -> int:
	for i in MAX_SPARKS:
		var s := (_next + i) % MAX_SPARKS
		if _left[s] <= 0.0:
			_next = (s + 1) % MAX_SPARKS
			return s
	var oldest := _next  # none free: the next in turn is replaced
	_next = (_next + 1) % MAX_SPARKS
	return oldest

func sparks() -> int:
	var n := 0
	for i in MAX_SPARKS:
		if _left[i] > 0.0:
			n += 1
	return n

func rings() -> int:
	var n := 0
	for r in _rings:
		if r.left > 0.0:
			n += 1
	return n

func clear() -> void:
	_left.fill(0.0)
	for r in _rings:
		r.left = 0.0

func advance(dt: float) -> void:
	for i in MAX_SPARKS:
		if _left[i] <= 0.0:
			continue
		_left[i] -= dt
		_vel[i] = _vel[i] * (1.0 - 1.8 * dt) + Vector2(0, GRAVITY * _grav[i] * dt)
		_pos[i] += _vel[i] * dt
	for r in _rings:
		if r.left > 0.0:
			r.left -= dt

func _process(_dt: float) -> void:
	queue_redraw()

func _draw() -> void:
	for r in _rings:
		if r.left <= 0.0:
			continue
		var k: float = 1.0 - r.left / r.dur
		var e := 1.0 - (1.0 - k) * (1.0 - k)
		var col: Color = r.color
		var rad := lerpf(r.r0, r.r1, e)
		draw_arc(r.at, rad, 0, TAU, 28, Color(col.r, col.g, col.b, 1.0 - k), 4.0 if k < 0.4 else 2.0)
		draw_arc(r.at, rad * 0.7, 0, TAU, 20, Color(1, 1, 1, 0.6 * (1.0 - k)), 2.0)
	for i in MAX_SPARKS:
		if _left[i] <= 0.0:
			continue
		var k := _left[i] / _life[i]
		if k < 0.3 and int(_left[i] * 40.0) % 2 == 0:
			continue  # it flickers out
		var sz := _size[i]
		draw_rect(Rect2((_pos[i] - Vector2(sz, sz) * 0.5).snapped(Vector2(2, 2)), Vector2(sz, sz)), _col[i])
