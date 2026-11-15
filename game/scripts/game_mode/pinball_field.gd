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
##
## The picture is PinballFieldArt's (#141): this node is the physics and the state the
## picture reads (what is lit, what was just hit, where each capsule has been). More kinds
## of things to hit came with it: two small pop bumpers by the walls, four standup targets
## on the walls, and the two bottom slopes are slingshots that kick.

signal target_hit(capsule_id: String, kind: String, target: String, pos: Vector2)
## goal: "left" / "center" / "right" / "timeout"
signal capsule_exited(capsule_id: String, goal: String, pos: Vector2)

const LEFT := 150.0
const RIGHT := 1130.0
const TOP := 140.0
const FLOOR_Y := 652.0
const SPAWN_Y := 150.0
const CAPSULE_R := 18.0
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
const POPS := [Vector2(262, 440), Vector2(1018, 440)]
const POP_R := 16.0
## standup targets on the walls: [centre, side (-1 left wall, 1 right wall)]
const TARGETS := [[Vector2(156, 400), -1], [Vector2(156, 480), -1], [Vector2(1124, 400), 1], [Vector2(1124, 480), 1]]
const TARGET_SIZE := Vector2(12, 44)
const TARGET_LIT_S := 6.0
## the bottom slopes (slingshots): from the wall at SLOPE_TOP_Y down to SLOPE_END
const SLOPE_TOP_Y := 530.0
const SLOPE_W := 110.0
const SLOPE_BOTTOM_Y := 605.0
const TRAIL_POINTS := 12
const POSTS_X := [570.0, 710.0]
const POST_TOP := 606.0
const LAYER_STATIC := 1
const LAYER_CAPSULE := 2
# the palette (#141): deep navy with cyan, magenta, yellow and purple accents
const COL_PANEL := Color("0a1036")
const COL_PANEL_LINE := Color("1b2a6b")
const COL_WALL := Color("1a2460")
const COL_EDGE := Color("3ff0ff")
const COL_PIN := Color("b9c8ff")
const COL_DARK := Color("050818")
const YELLOW := Color("ffe03c")
const MAGENTA := Color("ff4fd8")
const PURPLE := Color("8a5cff")
const GREEN := Color("7dffa8")

var max_stay_s := 15.0
## a capsule slower than this (px/s) for stall_s gets a nudge
var stall_speed := 14.0
var stall_s := 1.2
var gravity_scale := 0.7
var bounce := 0.45
var bumper_kick := 420.0
var pop_kick := 300.0
var sling_kick := 230.0
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
var _pin_flash: Dictionary = {}  # pin target -> seconds of glow left
var _switch_flash: Array[float] = [0.0, 0.0, 0.0]
var _spinner_flash: Array[float] = [0.0, 0.0]
var _pop_flash: Array[float] = [0.0, 0.0]
var _sling_flash: Array[float] = [0.0, 0.0]
## seconds each standup target stays lit after a hit (the picture only)
var _target_lit: Array[float] = [0.0, 0.0, 0.0, 0.0]
## the neon of the left / right wall (the Dials' colours; the controller sets them)
var wall_colors: Array[Color] = [Color("00ffff"), Color("ff00ff")]
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
		wedge.polygon = PackedVector2Array([Vector2(x0, SLOPE_TOP_Y), Vector2(x0 - side * SLOPE_W, SLOPE_BOTTOM_Y), Vector2(x0, SLOPE_BOTTOM_Y)])
		walls.add_child(wedge)
		# the slope's face is a slingshot: a thin strip over the wedge that kicks along its normal
		var i := 0 if side < 0 else 1
		var normal := slope_normal(i)
		var sling := _static("sling", "sling_%d" % i, 0.5)
		sling.set_meta("normal", normal)
		var strip := CollisionPolygon2D.new()
		var a := Vector2(x0, SLOPE_TOP_Y)
		var b := Vector2(x0 - side * SLOPE_W, SLOPE_BOTTOM_Y)
		strip.polygon = PackedVector2Array([a + normal * 3.0, b + normal * 3.0, b, a])
		sling.add_child(strip)
	for i in POPS.size():
		var pop := _static("pop", "pop_%d" % i, 0.8)
		pop.position = POPS[i]
		_circle(pop, POP_R)
	for i in TARGETS.size():
		var t := _static("target", "target_%d" % i, 0.7)
		t.position = TARGETS[i][0]
		_rect(t, TARGET_SIZE)
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
	_capsules[id] = {"body": b, "color": color, "age": 0.0, "slow": 0.0, "done": false, "trail": PackedVector2Array(), "trail_t": 0.0}

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

## Where a capsule has just been, oldest first (the picture's light trail).
func capsule_trail(id: String) -> PackedVector2Array:
	return _capsules[id].trail if _capsules.has(id) else PackedVector2Array()

func capsule_ids() -> Array:
	return _capsules.keys()

func capsule_color(id: String) -> Color:
	return _capsules[id].color if _capsules.has(id) else Color.WHITE

func capsule_rotation(id: String) -> float:
	return (_capsules[id].body as RigidBody2D).rotation if _capsules.has(id) and is_instance_valid(_capsules[id].body) else 0.0

## The way slope i (0 left, 1 right) kicks: away from its face, up and towards the middle.
static func slope_normal(i: int) -> Vector2:
	return Vector2(SLOPE_BOTTOM_Y - SLOPE_TOP_Y, -SLOPE_W).normalized() * Vector2(1.0 if i == 0 else -1.0, 1.0)

## Which goal a capsule at x falls into.
static func goal_at(x: float) -> String:
	return "left" if x < POSTS_X[0] else ("center" if x <= POSTS_X[1] else "right")

func _on_capsule_body(body: Node, id: String) -> void:
	if not _capsules.has(id) or _capsules[id].done or not body.has_meta("kind"):
		return
	var kind := str(body.get_meta("kind"))
	if not kind in ["pin", "bumper", "spinner", "pop", "target", "sling"]:
		return
	var cap: RigidBody2D = _capsules[id].body
	var n := int(str(body.get_meta("target")).get_slice("_", 1))
	match kind:
		"pop":
			cap.apply_central_impulse((cap.position - (body as Node2D).position).normalized() * pop_kick * cap.mass)
			_pop_flash[n] = 0.25
		"target":
			_target_lit[n] = TARGET_LIT_S
		"sling":
			cap.apply_central_impulse((body.get_meta("normal") as Vector2) * sling_kick * cap.mass)
			_sling_flash[n] = 0.25
	if kind == "bumper":
		var away := (cap.position - (body as Node2D).position).normalized()
		cap.apply_central_impulse(away * bumper_kick * cap.mass)
		_bumper_flash[int(str(body.get_meta("target")).get_slice("_", 1))] = 0.25
	elif kind == "pin":
		_pin_flash[str(body.get_meta("target"))] = 0.3
	elif kind == "spinner":
		_spinner_flash[int(str(body.get_meta("target")).get_slice("_", 1))] = 0.3
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
			if kind == "switch":
				_switch_flash[int(str(area.get_meta("target")).get_slice("_", 1))] = 0.4
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
	for i in _switch_flash.size():
		_switch_flash[i] = maxf(_switch_flash[i] - dt, 0.0)
	for i in _spinner_flash.size():
		_spinner_flash[i] = maxf(_spinner_flash[i] - dt, 0.0)
	for list in [_pop_flash, _sling_flash, _target_lit]:
		for i in list.size():
			list[i] = maxf(list[i] - dt, 0.0)
	for k in _pin_flash.keys():
		_pin_flash[k] = float(_pin_flash[k]) - dt
		if _pin_flash[k] <= 0.0:
			_pin_flash.erase(k)
	for g in _goal_flash.keys():
		_goal_flash[g] = maxf(float(_goal_flash[g]) - dt, 0.0)
	for id in _capsules.keys():
		var c: Dictionary = _capsules[id]
		if c.done or not is_instance_valid(c.body):
			continue
		var b: RigidBody2D = c.body
		c.age += dt
		c.trail_t += dt
		if c.trail_t >= 0.03:  # a fixed-size history: nothing is made or freed for the trail
			c.trail_t = 0.0
			var tr: PackedVector2Array = c.trail
			if tr.size() >= TRAIL_POINTS:
				tr.remove_at(0)
			tr.append(b.position)
			c.trail = tr
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

# ------------------------------------------------------------------ shared pictures
## A neon glow in pixel steps: the same shape twice, larger and fainter.
static func glow_rect(ci: CanvasItem, r: Rect2, col: Color, strength := 1.0) -> void:
	for i in 2:
		ci.draw_rect(r.grow(4.0 + 4.0 * i), Color(col.r, col.g, col.b, clampf(0.16 * strength / (i + 1), 0.0, 1.0)))

static func glow_circle(ci: CanvasItem, p: Vector2, r: float, col: Color, strength := 1.0) -> void:
	for i in 2:
		ci.draw_circle(p, r + 4.0 + 6.0 * i, Color(col.r, col.g, col.b, clampf(0.16 * strength / (i + 1), 0.0, 1.0)))

## The capsule's picture (the transfer animations and the title draw the same one): a dark
## rim, the Dial's colour on the top half with a lighter band, a white bottom half with a
## shadow, a shine, and a halo of its colour.
static func draw_capsule_at(ci: CanvasItem, pos: Vector2, rot: float, color: Color, k: float) -> void:
	var r := CAPSULE_R * k
	ci.draw_circle(pos, r + 8.0 * k, Color(color.r, color.g, color.b, 0.18))
	ci.draw_set_transform(pos, rot)
	ci.draw_circle(Vector2.ZERO, r + 2.0, Color("050818"))
	ci.draw_circle(Vector2.ZERO, r, Color("f4f8ff"))
	var low := PackedVector2Array()
	var top := PackedVector2Array()
	var band := PackedVector2Array()
	for i in 13:
		var a := PI * i / 12.0
		low.append(Vector2(cos(a), sin(a)) * r)
		top.append(Vector2(cos(a + PI), sin(a + PI)) * r)
		band.append(Vector2(cos(a + PI), sin(a + PI)) * r * 0.62)
	ci.draw_colored_polygon(low, Color("c9d2ee"))
	ci.draw_circle(Vector2(0, r * 0.18), r * 0.72, Color("f4f8ff"))
	ci.draw_colored_polygon(top, color)
	ci.draw_colored_polygon(band, color.lerp(Color.WHITE, 0.35))
	ci.draw_rect(Rect2(-r, -2.0 * k, 2.0 * r, 4.0 * k), Color("050818"))
	ci.draw_rect(Rect2(-r * 0.6, -r * 0.72, r * 0.42, r * 0.26), Color(1, 1, 1, 0.95))
	ci.draw_rect(Rect2(-r * 0.12, -r * 0.72, r * 0.14, r * 0.14), Color(1, 1, 1, 0.7))
	ci.draw_set_transform(Vector2.ZERO)
