class_name PinballField
extends Node2D
## The fixed field of the game mode (#138, docs/game_mode_spec.md §4): pins, three
## switches, bumpers, two turning spinners, a star, and three goals along the bottom. The
## capsules are Godot RigidBody2D (this is not the rope: the rope stays the project's own
## Verlet solver). Capsules never collide with each other (layer 2, mask 1).
##
## The field only reports: target_hit when a capsule touches something that scores and
## capsule_exited when it leaves (a goal, or "timeout" after max_stay_s). The score, the
## timing and the devices are the controller's. Coordinates are the 1280 x 720 design
## space (the window stretches as a whole).

signal target_hit(capsule_id: String, kind: String, target: String, pos: Vector2)
## goal: "left" / "center" / "right" / "timeout"
signal capsule_exited(capsule_id: String, goal: String, pos: Vector2)

const LEFT := 150.0
const RIGHT := 1130.0
const TOP := 140.0
const FLOOR_Y := 652.0
const SPAWN_Y := 150.0
const CAPSULE_R := 13.0
const PIN_R := 6.0
const BUMPER_R := 26.0
const STAR_R := 17.0
const SPINNER_ARM := 44.0
const PIN_ROWS := [[230.0, 199.0, 10], [285.0, 248.0, 9], [340.0, 199.0, 10]]  # y, first x, count
const PIN_STEP := 98.0
const SWITCH_Y := 185.0
const SWITCH_X := [444.0, 640.0, 836.0]
const BUMPERS := [Vector2(395, 430), Vector2(640, 415), Vector2(885, 430)]
const SPINNERS := [Vector2(500, 520), Vector2(780, 520)]
const STAR := Vector2(640, 505)
const POSTS_X := [570.0, 710.0]
const POST_TOP := 606.0
const LAYER_STATIC := 1
const LAYER_CAPSULE := 2
const COL_WALL := Color("2a3f7a")
const COL_EDGE := Color("7ae0ff")
const COL_PIN := Color("d8e6ff")
const COL_DARK := Color("0a1030")
const YELLOW := Color("ffe03c")

var max_stay_s := 15.0
## a capsule slower than this (px/s) for stall_s gets a nudge
var stall_speed := 14.0
var stall_s := 1.2
var gravity_scale := 0.7
var bounce := 0.45
var bumper_kick := 420.0
var spinner_speed := 2.6  # rad/s (the two turn opposite ways)
var star_respawn_s := 8.0
var frozen := false
## shown lit (the controller copies the score's state here)
var switch_lit: Array[bool] = [false, false, false]
var jackpot_on := false
var star_left := 0.0  # > 0: the star is away

var _capsules: Dictionary = {}  # id -> {body, color, age, slow, done}
var _spinners: Array[AnimatableBody2D] = []
var _bumper_flash: Array[float] = [0.0, 0.0, 0.0]
var _goal_flash: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _t := 0.0

func _ready() -> void:
	_rng.seed = 138
	_build()

func configure(cfg: Dictionary) -> void:
	max_stay_s = float(cfg.get("max_stay_s", max_stay_s))
	stall_s = float(cfg.get("stall_s", stall_s))
	gravity_scale = float(cfg.get("gravity_scale", gravity_scale))
	bounce = float(cfg.get("bounce", bounce))
	star_respawn_s = float(cfg.get("star_respawn_s", star_respawn_s))

# ------------------------------------------------------------------ building
func _material(b: float, friction := 0.2) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.bounce = b
	m.friction = friction
	return m

func _static(kind: String, target: String, b := 0.3) -> StaticBody2D:
	var s := StaticBody2D.new()
	s.collision_layer = LAYER_STATIC
	s.collision_mask = 0
	s.physics_material_override = _material(b)
	s.set_meta("kind", kind)
	s.set_meta("target", target)
	add_child(s)
	return s

func _circle(parent: Node, r: float, at := Vector2.ZERO) -> void:
	var c := CollisionShape2D.new()
	var sh := CircleShape2D.new()
	sh.radius = r
	c.shape = sh
	c.position = at
	parent.add_child(c)

func _rect(parent: Node, size: Vector2, at := Vector2.ZERO, rot := 0.0) -> void:
	var c := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = size
	c.shape = sh
	c.position = at
	c.rotation = rot
	parent.add_child(c)

func _area(kind: String, target: String, at: Vector2) -> Area2D:
	var a := Area2D.new()
	a.collision_layer = 0
	a.collision_mask = LAYER_CAPSULE
	a.monitorable = false
	a.position = at
	a.set_meta("kind", kind)
	a.set_meta("target", target)
	a.body_entered.connect(_on_area.bind(a))
	add_child(a)
	return a

func _build() -> void:
	# the walls (tall enough that nothing leaves over the top)
	var walls := _static("wall", "wall")
	_rect(walls, Vector2(24, 800), Vector2(LEFT - 12, 300))
	_rect(walls, Vector2(24, 800), Vector2(RIGHT + 12, 300))
	# the slopes that keep the corners moving
	for side in [-1, 1]:
		var wedge := CollisionPolygon2D.new()
		var x0 := LEFT if side < 0 else RIGHT
		wedge.polygon = PackedVector2Array([Vector2(x0, 530), Vector2(x0 - side * 110.0, 605), Vector2(x0, 605)])
		walls.add_child(wedge)
	var n := 0
	for row in PIN_ROWS:
		for i in int(row[2]):
			var pin := _static("pin", "pin_%d" % n, 0.55)
			pin.position = Vector2(float(row[1]) + PIN_STEP * i, float(row[0]))
			_circle(pin, PIN_R)
			n += 1
	for i in BUMPERS.size():
		var b := _static("bumper", "bumper_%d" % i, 0.9)
		b.position = BUMPERS[i]
		_circle(b, BUMPER_R)
	for i in SPINNERS.size():
		var sp := AnimatableBody2D.new()
		sp.collision_layer = LAYER_STATIC
		sp.collision_mask = 0
		sp.sync_to_physics = false
		sp.physics_material_override = _material(0.6)
		sp.position = SPINNERS[i]
		sp.set_meta("kind", "spinner")
		sp.set_meta("target", "spinner_%d" % i)
		_rect(sp, Vector2(SPINNER_ARM * 2.0, 10))
		_rect(sp, Vector2(10, SPINNER_ARM * 2.0))
		add_child(sp)
		_spinners.append(sp)
	for x in POSTS_X:
		var post := _static("post", "post", 0.4)
		post.position = Vector2(float(x), 0)
		_rect(post, Vector2(10, FLOOR_Y - POST_TOP), Vector2(0, (FLOOR_Y + POST_TOP) * 0.5))
		_circle(post, 7.0, Vector2(0, POST_TOP))
	for i in SWITCH_X.size():
		_rect(_area("switch", "switch_%d" % i, Vector2(SWITCH_X[i], SWITCH_Y)), Vector2(56, 14))
	_circle(_area("star", "star", STAR), STAR_R)
	# the goals: sensors under the floor line
	var edges := [LEFT, POSTS_X[0], POSTS_X[1], RIGHT]
	var names := ["left", "center", "right"]
	for i in 3:
		var w: float = edges[i + 1] - edges[i]
		_rect(_area("goal", names[i], Vector2((edges[i] + edges[i + 1]) * 0.5, FLOOR_Y + 30.0)), Vector2(w, 44))

# ------------------------------------------------------------------ capsules
func spawn_capsule(id: String, x: float, color: Color) -> void:
	if _capsules.has(id):
		return
	var b := RigidBody2D.new()
	b.name = "Capsule_" + id
	b.collision_layer = LAYER_CAPSULE
	b.collision_mask = LAYER_STATIC
	b.gravity_scale = gravity_scale
	b.physics_material_override = _material(bounce, 0.15)
	b.contact_monitor = true
	b.max_contacts_reported = 6
	b.continuous_cd = RigidBody2D.CCD_MODE_CAST_RAY
	b.linear_damp = 0.05
	b.angular_damp = 0.6
	b.freeze = frozen
	b.position = Vector2(clampf(x, LEFT + CAPSULE_R + 2.0, RIGHT - CAPSULE_R - 2.0), SPAWN_Y)
	b.linear_velocity = Vector2(_rng.randf_range(-18.0, 18.0), 40.0)
	b.angular_velocity = _rng.randf_range(-3.0, 3.0)
	b.set_meta("capsule", id)
	_circle(b, CAPSULE_R)
	b.body_entered.connect(_on_capsule_body.bind(id))
	add_child(b)
	_capsules[id] = {"body": b, "color": color, "age": 0.0, "slow": 0.0, "done": false}

func remove_capsule(id: String) -> void:
	if not _capsules.has(id):
		return
	var b: RigidBody2D = _capsules[id].body
	_capsules.erase(id)
	if is_instance_valid(b):
		b.queue_free()

func clear() -> void:
	for id in _capsules.keys():
		remove_capsule(id)
	switch_lit = [false, false, false]
	jackpot_on = false
	star_left = 0.0

func has_capsule(id: String) -> bool:
	return _capsules.has(id)

func capsule_count() -> int:
	return _capsules.size()

func capsule_position(id: String) -> Vector2:
	if not _capsules.has(id) or not is_instance_valid(_capsules[id].body):
		return Vector2.ZERO
	return (_capsules[id].body as RigidBody2D).position

func set_frozen(on: bool) -> void:
	frozen = on
	for c in _capsules.values():
		if is_instance_valid(c.body):
			(c.body as RigidBody2D).freeze = on

## Which goal a capsule at x falls into.
static func goal_at(x: float) -> String:
	return "left" if x < POSTS_X[0] else ("center" if x <= POSTS_X[1] else "right")

func _on_capsule_body(body: Node, id: String) -> void:
	if not _capsules.has(id) or _capsules[id].done or not body.has_meta("kind"):
		return
	var kind := str(body.get_meta("kind"))
	if not kind in ["pin", "bumper", "spinner"]:
		return
	var cap: RigidBody2D = _capsules[id].body
	if kind == "bumper":
		var away := (cap.position - (body as Node2D).position).normalized()
		cap.apply_central_impulse(away * bumper_kick * cap.mass)
		_bumper_flash[int(str(body.get_meta("target")).get_slice("_", 1))] = 0.25
	target_hit.emit(id, kind, str(body.get_meta("target")), cap.position)

func _on_area(body: Node, area: Area2D) -> void:
	if not body.has_meta("capsule"):
		return
	var id := str(body.get_meta("capsule"))
	if not _capsules.has(id) or _capsules[id].done:
		return
	var kind := str(area.get_meta("kind"))
	var pos := (body as Node2D).position
	match kind:
		"goal":
			_exit(id, str(area.get_meta("target")), pos)
		"star":
			if star_left <= 0.0:
				star_left = star_respawn_s
				target_hit.emit(id, "star", "star", pos)
		_:
			target_hit.emit(id, kind, str(area.get_meta("target")), pos)

func _exit(id: String, goal: String, pos: Vector2) -> void:
	_capsules[id].done = true
	if goal != "timeout":
		_goal_flash[goal] = 0.5
	capsule_exited.emit(id, goal, pos)

## One step of the field's own time (the physics tick; the tests call it directly): the
## spinners turn, the star comes back, a stuck capsule is nudged, an old one is taken out.
func advance(dt: float) -> void:
	_t += dt
	if frozen:
		return
	for i in _spinners.size():
		_spinners[i].rotation += spinner_speed * dt * (1.0 if i % 2 == 0 else -1.0)
	star_left = maxf(star_left - dt, 0.0)
	for i in _bumper_flash.size():
		_bumper_flash[i] = maxf(_bumper_flash[i] - dt, 0.0)
	for g in _goal_flash.keys():
		_goal_flash[g] = maxf(float(_goal_flash[g]) - dt, 0.0)
	for id in _capsules.keys():
		var c: Dictionary = _capsules[id]
		if c.done or not is_instance_valid(c.body):
			continue
		var b: RigidBody2D = c.body
		c.age += dt
		if b.position.y > FLOOR_Y + 90.0:  # past the sensors (it should never get here)
			_exit(id, goal_at(b.position.x), b.position)
			continue
		if c.age >= max_stay_s:
			_exit(id, "timeout", b.position)
			continue
		if b.linear_velocity.length() < stall_speed:
			c.slow += dt
			if c.slow >= stall_s:
				c.slow = 0.0
				b.apply_central_impulse(Vector2(_rng.randf_range(-1.0, 1.0) * 160.0, -120.0) * b.mass)
		else:
			c.slow = 0.0

func _physics_process(dt: float) -> void:
	advance(dt)

func _process(_dt: float) -> void:
	queue_redraw()

# ------------------------------------------------------------------ drawing
func _draw() -> void:
	# the board
	draw_rect(Rect2(LEFT, TOP, RIGHT - LEFT, FLOOR_Y - TOP + 68.0), Color(0.04, 0.07, 0.2, 0.92))
	for i in 12:  # faint scan bands, pixel-art style
		draw_rect(Rect2(LEFT, TOP + 46.0 * i, RIGHT - LEFT, 2), Color(0.3, 0.5, 1.0, 0.06))
	for x in [LEFT - 12.0, RIGHT]:
		draw_rect(Rect2(x, TOP - 30.0, 12, FLOOR_Y - TOP + 98.0), COL_WALL)
		draw_rect(Rect2(x + (8.0 if x < LEFT else 0.0), TOP - 30.0, 4, FLOOR_Y - TOP + 98.0), COL_EDGE)
	for side in [-1, 1]:
		var x0 := LEFT if side < 0 else RIGHT
		var tri := PackedVector2Array([Vector2(x0, 530), Vector2(x0 - side * 110.0, 605), Vector2(x0, 605)])
		draw_colored_polygon(tri, COL_WALL)
		draw_line(tri[0], tri[1], COL_EDGE, 3.0)
	# goals
	var edges := [LEFT, POSTS_X[0], POSTS_X[1], RIGHT]
	var names := ["left", "center", "right"]
	for i in 3:
		var f := float(_goal_flash.get(names[i], 0.0)) * 2.0
		var jack: bool = i == 1 and jackpot_on
		var col := Color("ffb000") if jack else (Color("3b7dd8") if i == 1 else Color("26407a"))
		if jack:
			col = col.lerp(Color.WHITE, 0.5 + 0.5 * sin(_t * 12.0))
		draw_rect(Rect2(edges[i], FLOOR_Y, edges[i + 1] - edges[i], 68), col.lerp(Color.WHITE, clampf(f, 0.0, 1.0)))
		var txt := "JACKPOT" if jack else ("1000" if i == 1 else "100")
		_text(txt, Vector2((edges[i] + edges[i + 1]) * 0.5, FLOOR_Y + 44.0), 26 if i == 1 else 22, YELLOW if i == 1 else Color("c8d6f0"))
	for x in POSTS_X:
		draw_rect(Rect2(float(x) - 5.0, POST_TOP, 10, FLOOR_Y - POST_TOP + 68.0), COL_EDGE)
		draw_circle(Vector2(float(x), POST_TOP), 7.0, Color.WHITE)
	# switches
	for i in SWITCH_X.size():
		var on: bool = switch_lit[i]
		var r := Rect2(SWITCH_X[i] - 28.0, SWITCH_Y - 7.0, 56, 14)
		draw_rect(r.grow(3.0), COL_DARK)
		draw_rect(r, YELLOW if on else Color("394a78"))
		draw_rect(Rect2(r.position + Vector2(4, 3), Vector2(48, 3)), Color(1, 1, 1, 0.8 if on else 0.15))
	# pins
	for row in PIN_ROWS:
		for i in int(row[2]):
			var p := Vector2(float(row[1]) + PIN_STEP * i, float(row[0]))
			draw_circle(p, PIN_R + 2.0, COL_DARK)
			draw_circle(p, PIN_R, COL_PIN)
			draw_rect(Rect2(p + Vector2(-3, -4), Vector2(3, 3)), Color.WHITE)
	# bumpers
	for i in BUMPERS.size():
		var k := _bumper_flash[i] * 4.0
		var p: Vector2 = BUMPERS[i]
		draw_circle(p, BUMPER_R + 4.0 + 6.0 * k, Color(1.0, 0.5, 0.9, 0.25 + 0.5 * k))
		draw_circle(p, BUMPER_R, Color("ff5fb4").lerp(Color.WHITE, clampf(k, 0.0, 1.0)))
		draw_circle(p, BUMPER_R - 8.0, Color("ffd0ea"))
		draw_circle(p, BUMPER_R - 15.0, Color("ff5fb4"))
		_text("100", p + Vector2(0, 6), 14, COL_DARK)
	# spinners
	for sp in _spinners:
		draw_set_transform(sp.position, sp.rotation)
		draw_rect(Rect2(-SPINNER_ARM, -5, SPINNER_ARM * 2.0, 10), Color("9ff0a8"))
		draw_rect(Rect2(-5, -SPINNER_ARM, 10, SPINNER_ARM * 2.0), Color("9ff0a8"))
		draw_rect(Rect2(-SPINNER_ARM, -5, 10, 10), Color.WHITE)
		draw_rect(Rect2(SPINNER_ARM - 10.0, -5, 10, 10), Color.WHITE)
		draw_set_transform(Vector2.ZERO)
		draw_circle(sp.position, 8.0, COL_DARK)
		draw_circle(sp.position, 5.0, Color("9ff0a8"))
	# the star
	if star_left <= 0.0:
		var pts := PackedVector2Array()
		for i in 10:
			var a := -PI * 0.5 + TAU * i / 10.0 + sin(_t * 2.0) * 0.15
			pts.append(STAR + Vector2(cos(a), sin(a)) * (STAR_R + 3.0 if i % 2 == 0 else STAR_R * 0.5))
		draw_colored_polygon(pts, YELLOW)
		draw_circle(STAR, 4.0, Color.WHITE)
	else:
		draw_arc(STAR, STAR_R * 0.6, 0, TAU, 16, Color(1, 0.9, 0.3, 0.25), 2.0)
	# capsules: two halves, the Dial's colour on top
	for c in _capsules.values():
		if not is_instance_valid(c.body):
			continue
		var b: RigidBody2D = c.body
		draw_capsule_at(self, b.position, b.rotation, c.color, 1.0)

## The capsule's picture (the transfer animations draw the same one).
static func draw_capsule_at(ci: CanvasItem, pos: Vector2, rot: float, color: Color, k: float) -> void:
	var r := CAPSULE_R * k
	ci.draw_set_transform(pos, rot)
	ci.draw_circle(Vector2.ZERO, r + 2.0, Color("0a1030"))
	ci.draw_circle(Vector2.ZERO, r, Color("f4f8ff"))
	var top := PackedVector2Array()
	for i in 13:
		var a := PI + PI * i / 12.0
		top.append(Vector2(cos(a), sin(a)) * r)
	ci.draw_colored_polygon(top, color)
	ci.draw_rect(Rect2(-r, -1.5 * k, 2.0 * r, 3.0 * k), Color("0a1030"))
	ci.draw_rect(Rect2(-r * 0.55, -r * 0.7, r * 0.35, r * 0.25), Color(1, 1, 1, 0.85))
	ci.draw_set_transform(Vector2.ZERO)

func _text(s: String, centre: Vector2, size: int, col: Color) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_CENTER, -1, size).x
	draw_string(font, centre - Vector2(w * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
