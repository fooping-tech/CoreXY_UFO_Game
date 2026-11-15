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
## The picture (#141) is drawn here in code, pixel-art style: thick dark outlines, a
## highlight on everything round, soft neon made of a few translucent layers. It only
## shows the state (lit switches, the jackpot, what was just hit); it decides nothing.

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
## A soft glow: the same shape a few times, larger and fainter.
static func glow_rect(ci: CanvasItem, r: Rect2, col: Color, strength := 1.0) -> void:
	for i in 3:
		ci.draw_rect(r.grow(3.0 + 4.0 * i), Color(col.r, col.g, col.b, 0.14 * strength / (i + 1)))

static func glow_circle(ci: CanvasItem, p: Vector2, r: float, col: Color, strength := 1.0) -> void:
	for i in 3:
		ci.draw_circle(p, r + 4.0 + 5.0 * i, Color(col.r, col.g, col.b, 0.13 * strength / (i + 1)))

func _draw() -> void:
	_draw_board()
	_draw_goals()
	_draw_switches()
	_draw_pins()
	_draw_bumpers()
	_draw_spinners()
	_draw_star()
	_draw_frame()
	for c in _capsules.values():
		if is_instance_valid(c.body):
			var b: RigidBody2D = c.body
			draw_capsule_at(self, b.position, b.rotation, c.color, 1.0)

## The dark panel with a faint grid, and the slopes at the bottom corners.
func _draw_board() -> void:
	draw_rect(Rect2(LEFT, TOP - 12.0, RIGHT - LEFT, FLOOR_Y - TOP + 12.0), Color(COL_PANEL.r, COL_PANEL.g, COL_PANEL.b, 0.9))
	for i in 17:
		draw_rect(Rect2(LEFT, TOP + 32.0 * i, RIGHT - LEFT, 2), Color(COL_PANEL_LINE.r, COL_PANEL_LINE.g, COL_PANEL_LINE.b, 0.35))
	for i in 21:
		draw_rect(Rect2(LEFT + 49.0 * i, TOP - 12.0, 2, FLOOR_Y - TOP + 12.0), Color(COL_PANEL_LINE.r, COL_PANEL_LINE.g, COL_PANEL_LINE.b, 0.22))
	for side in [-1, 1]:
		var x0 := LEFT if side < 0 else RIGHT
		var col: Color = wall_colors[0 if side < 0 else 1]
		var tri := PackedVector2Array([Vector2(x0, 530), Vector2(x0 - side * 110.0, 605), Vector2(x0, 605)])
		draw_colored_polygon(tri, COL_WALL)
		draw_line(tri[0], tri[1], Color(col.r, col.g, col.b, 0.25), 9.0)
		draw_line(tri[0], tri[1], col, 3.0)
		draw_line(tri[0] + Vector2(0, 2), tri[1] + Vector2(0, 2), Color(1, 1, 1, 0.5), 1.0)
		for j in 3:
			var q := tri[0].lerp(tri[1], 0.25 + 0.25 * j) + Vector2(side * 10.0, 22.0)
			draw_rect(Rect2(q.snapped(Vector2(2, 2)), Vector2(6, 6)), Color(col.r, col.g, col.b, 0.25))

## The walls as neon tubes in each Dial's colour, and the rail the UFO hovers over.
func _draw_frame() -> void:
	var top := TOP - 30.0
	var h := FLOOR_Y - top + 68.0
	for i in 2:
		var x := LEFT - 12.0 if i == 0 else RIGHT
		var col: Color = wall_colors[i]
		draw_rect(Rect2(x - 4.0, top, 20.0, h), Color(col.r, col.g, col.b, 0.1))
		draw_rect(Rect2(x, top, 12, h), COL_DARK)
		draw_rect(Rect2(x + 1.0, top, 10, h), COL_WALL)
		draw_rect(Rect2(x + 4.0, top, 4, h), col)
		draw_rect(Rect2(x + 5.0, top, 1, h), Color(1, 1, 1, 0.75))
		for j in 9:  # bolts
			draw_rect(Rect2(x + 3.0, top + 20.0 + 70.0 * j, 6, 6), COL_DARK)
			draw_rect(Rect2(x + 4.0, top + 21.0 + 70.0 * j, 2, 2), Color(1, 1, 1, 0.6))
	# the rail along the top: purple, with small lights running
	draw_rect(Rect2(LEFT - 12.0, top - 6.0, RIGHT - LEFT + 24.0, 10), COL_DARK)
	draw_rect(Rect2(LEFT - 10.0, top - 4.0, RIGHT - LEFT + 20.0, 6), COL_WALL)
	draw_rect(Rect2(LEFT - 10.0, top - 2.0, RIGHT - LEFT + 20.0, 2), PURPLE)
	for i in 25:
		var on := int(_t * 6.0 + i) % 5 == 0
		draw_rect(Rect2(LEFT + 40.0 * i + 6.0, top - 3.0, 4, 4), YELLOW if on else Color(0.3, 0.3, 0.6))

func _draw_goals() -> void:
	var edges := [LEFT, POSTS_X[0], POSTS_X[1], RIGHT]
	var names := ["left", "center", "right"]
	for i in 3:
		var x0: float = edges[i]
		var w: float = edges[i + 1] - edges[i]
		var f := clampf(float(_goal_flash.get(names[i], 0.0)) * 2.0, 0.0, 1.0)
		var jack: bool = i == 1 and jackpot_on
		var col := (YELLOW if jack else PURPLE) if i == 1 else Color("2b3fa8")
		draw_rect(Rect2(x0, FLOOR_Y, w, 68), Color("070a26"))
		draw_rect(Rect2(x0, FLOOR_Y, w, 68), Color(col.r, col.g, col.b, (0.35 if i == 1 else 0.22) + 0.6 * f))
		if jack:
			glow_rect(self, Rect2(x0, FLOOR_Y, w, 68), YELLOW, 0.6 + 0.4 * sin(_t * 12.0))
		draw_rect(Rect2(x0, FLOOR_Y, w, 3), Color(col.r, col.g, col.b, 0.95))
		draw_rect(Rect2(x0, FLOOR_Y + 3.0, w, 1), Color(1, 1, 1, 0.5))
		# chevrons falling into the slot: this is where things go in
		var step := 70.0 if i != 1 else 46.0
		var count := int(w / step)
		for c in count:
			var cx := x0 + (w - (count - 1) * step) * 0.5 + c * step
			for row in 3:
				var k := fmod(_t * 1.4 + row / 3.0, 1.0)
				var y := FLOOR_Y + 8.0 + 46.0 * k
				var a := sin(PI * k) * (0.55 if i == 1 else 0.35)
				for d in 3:  # a "v" of three steps
					draw_rect(Rect2(cx - 8.0 + d * 2.0, y + d * 2.0, 2, 2), Color(1, 1, 1, a))
					draw_rect(Rect2(cx + 6.0 - d * 2.0, y + d * 2.0, 2, 2), Color(1, 1, 1, a))
		var label := "JACKPOT" if jack else ("1000" if i == 1 else "100")
		var lc := (Color.WHITE if int(_t * 8.0) % 2 == 0 else YELLOW) if jack else (YELLOW if i == 1 else Color("c8d6ff"))
		PixelText.draw_centered(self, label, Vector2(x0 + w * 0.5, FLOOR_Y + 40.0), 2.0 if jack else 3.0, lc, COL_DARK)
	for x in POSTS_X:  # the posts between the goals
		var px := float(x)
		draw_rect(Rect2(px - 7.0, POST_TOP, 14, FLOOR_Y - POST_TOP + 68.0), COL_DARK)
		draw_rect(Rect2(px - 5.0, POST_TOP, 10, FLOOR_Y - POST_TOP + 68.0), COL_WALL)
		draw_rect(Rect2(px - 2.0, POST_TOP, 4, FLOOR_Y - POST_TOP + 68.0), COL_EDGE)
		glow_circle(self, Vector2(px, POST_TOP), 7.0, COL_EDGE, 0.8)
		draw_circle(Vector2(px, POST_TOP), 9.0, COL_DARK)
		draw_circle(Vector2(px, POST_TOP), 7.0, COL_EDGE)
		draw_rect(Rect2(px - 4.0, POST_TOP - 5.0, 3, 3), Color.WHITE)

func _draw_switches() -> void:
	for i in SWITCH_X.size():
		var on: bool = switch_lit[i]
		var f := clampf(_switch_flash[i] * 2.5, 0.0, 1.0)
		var x: float = SWITCH_X[i]
		var r := Rect2(x - 28.0, SWITCH_Y - 7.0, 56, 14)
		# the lane it sits in
		draw_rect(Rect2(x - 30.0, TOP - 12.0, 60, SWITCH_Y - TOP + 12.0), Color(YELLOW.r, YELLOW.g, YELLOW.b, 0.05 + (0.1 if on else 0.0)))
		for d in 2:  # an arrow above: aim here
			var bob := fmod(_t * 1.2 + d * 0.5, 1.0) * 8.0
			var a := 0.5 if not on else 0.2
			for sx in 4:
				draw_rect(Rect2(x - 8.0 + sx * 2.0, SWITCH_Y - 34.0 + bob + sx * 2.0 + d * 8.0, 2, 2), Color(1, 1, 1, a))
				draw_rect(Rect2(x + 6.0 - sx * 2.0, SWITCH_Y - 34.0 + bob + sx * 2.0 + d * 8.0, 2, 2), Color(1, 1, 1, a))
		if on or f > 0.0:
			glow_rect(self, r, YELLOW, 0.8 + f)
		draw_rect(r.grow(3.0), COL_DARK)
		draw_rect(r, (YELLOW if on else Color("3a3470")).lerp(Color.WHITE, f))
		draw_rect(Rect2(r.position + Vector2(3, 2), Vector2(50, 3)), Color(1, 1, 1, 0.85 if on else 0.2))
		draw_rect(Rect2(r.position + Vector2(0, 10), Vector2(56, 4)), Color(0, 0, 0, 0.25))

func _draw_pins() -> void:
	var n := 0
	for row in PIN_ROWS:
		for i in int(row[2]):
			var p := Vector2(float(row[1]) + PIN_STEP * i, float(row[0]))
			var f := clampf(float(_pin_flash.get("pin_%d" % n, 0.0)) / 0.3, 0.0, 1.0)
			n += 1
			if f > 0.0:
				glow_circle(self, p, PIN_R + 2.0, COL_EDGE, 2.0 * f)
			draw_circle(p + Vector2(2, 3), PIN_R + 2.0, Color(0, 0, 0, 0.35))
			draw_circle(p, PIN_R + 2.5, COL_DARK)
			draw_circle(p, PIN_R, COL_PIN.lerp(Color.WHITE, f))
			draw_circle(p + Vector2(1, 1.5), PIN_R - 2.5, Color("8496e0").lerp(Color.WHITE, f))
			draw_rect(Rect2(p + Vector2(-4, -4), Vector2(3, 3)), Color.WHITE)

## Pop bumpers: a ring of small lamps that chase round, a domed cap with a star.
func _draw_bumpers() -> void:
	for i in BUMPERS.size():
		var k := clampf(_bumper_flash[i] * 4.0, 0.0, 1.0)
		var p: Vector2 = BUMPERS[i]
		var r := BUMPER_R * (1.0 + 0.14 * k)
		glow_circle(self, p, r + 2.0, MAGENTA, 1.0 + 2.5 * k)
		draw_circle(p + Vector2(3, 4), r + 3.0, Color(0, 0, 0, 0.35))
		draw_circle(p, r + 5.0, COL_DARK)
		draw_circle(p, r + 3.0, Color("3a1a66"))
		for j in 12:  # the lamps
			var a := TAU * j / 12.0
			var on := k > 0.0 or (j + int(_t * 6.0)) % 4 == 0
			draw_rect(Rect2((p + Vector2(cos(a), sin(a)) * (r + 1.0) - Vector2(2, 2)).snapped(Vector2(1, 1)), Vector2(4, 4)),
				YELLOW if on else Color("6a4a9a"))
		draw_circle(p, r - 3.0, MAGENTA.lerp(Color.WHITE, k))
		draw_circle(p + Vector2(0, 2), r - 6.0, Color("c8309e").lerp(Color.WHITE, k))
		draw_circle(p, r - 9.0, Color("ffc4ee"))
		draw_circle(p, r - 12.0, MAGENTA.lerp(Color.WHITE, k * 0.6))
		draw_arc(p, r - 5.0, PI * 1.1, PI * 1.6, 8, Color(1, 1, 1, 0.9), 3.0)  # the shine on the dome
		var star := PackedVector2Array()
		for j in 10:
			var a := -PI * 0.5 + TAU * j / 10.0
			star.append(p + Vector2(cos(a), sin(a)) * ((r - 14.0) if j % 2 == 0 else (r - 14.0) * 0.45))
		draw_colored_polygon(star, YELLOW.lerp(Color.WHITE, k))

## Spinners: lit edges, and faint copies behind the arms as they turn.
func _draw_spinners() -> void:
	for i in _spinners.size():
		var sp := _spinners[i]
		var dir := 1.0 if i % 2 == 0 else -1.0
		var f := clampf(_spinner_flash[i] / 0.3, 0.0, 1.0)
		glow_circle(self, sp.position, 12.0, GREEN, 0.8 + 2.0 * f)
		for ghost in [3, 2, 1, 0]:
			draw_set_transform(sp.position, sp.rotation - dir * 0.16 * ghost)
			if ghost > 0:
				var a: float = 0.16 / float(ghost)
				draw_rect(Rect2(-SPINNER_ARM, -5, SPINNER_ARM * 2.0, 10), Color(GREEN.r, GREEN.g, GREEN.b, a))
				draw_rect(Rect2(-5, -SPINNER_ARM, 10, SPINNER_ARM * 2.0), Color(GREEN.r, GREEN.g, GREEN.b, a))
				continue
			var body := Color("2fbf73").lerp(Color.WHITE, f)
			for arm in 2:
				var r := Rect2(-SPINNER_ARM, -5, SPINNER_ARM * 2.0, 10) if arm == 0 else Rect2(-5, -SPINNER_ARM, 10, SPINNER_ARM * 2.0)
				draw_rect(r.grow(2.0), COL_DARK)
			for arm in 2:
				var r := Rect2(-SPINNER_ARM, -5, SPINNER_ARM * 2.0, 10) if arm == 0 else Rect2(-5, -SPINNER_ARM, 10, SPINNER_ARM * 2.0)
				draw_rect(r, body)
			draw_rect(Rect2(-SPINNER_ARM, -5, SPINNER_ARM * 2.0, 3), GREEN.lerp(Color.WHITE, 0.4))
			draw_rect(Rect2(-5, -SPINNER_ARM, 3, SPINNER_ARM * 2.0), GREEN.lerp(Color.WHITE, 0.4))
			for e in [Vector2(-SPINNER_ARM, -5), Vector2(SPINNER_ARM - 10.0, -5), Vector2(-5, -SPINNER_ARM), Vector2(-5, SPINNER_ARM - 10.0)]:
				draw_rect(Rect2(e, Vector2(10, 10)), YELLOW)
				draw_rect(Rect2(e + Vector2(2, 2), Vector2(3, 3)), Color.WHITE)
		draw_set_transform(Vector2.ZERO)
		draw_circle(sp.position, 10.0, COL_DARK)
		draw_circle(sp.position, 7.0, COL_EDGE)
		draw_circle(sp.position, 3.0, Color.WHITE)

func _draw_star() -> void:
	if star_left > 0.0:  # away: a faint ring fills as it comes back
		draw_arc(STAR, STAR_R * 0.7, 0, TAU, 20, Color(1, 0.9, 0.3, 0.18), 2.0)
		draw_arc(STAR, STAR_R * 0.7, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - star_left / maxf(star_respawn_s, 0.01)), 20,
			Color(1, 0.9, 0.3, 0.6), 3.0)
		return
	var c := STAR + Vector2(0, sin(_t * 3.0) * 2.0)
	glow_circle(self, c, STAR_R, YELLOW, 1.2 + 0.5 * sin(_t * 4.0))
	for layer in 3:
		var scale_k: float = [1.3, 1.0, 0.55][layer]
		var col: Color = [COL_DARK, YELLOW, Color("fff6b0")][layer]
		var pts := PackedVector2Array()
		for i in 10:
			var a := -PI * 0.5 + TAU * i / 10.0 + sin(_t * 2.0) * 0.12
			pts.append(c + Vector2(cos(a), sin(a)) * ((STAR_R + 3.0) if i % 2 == 0 else (STAR_R + 3.0) * 0.48) * scale_k)
		draw_colored_polygon(pts, col)
	for i in 4:  # a turning glint
		var a := _t * 1.5 + TAU * i / 4.0
		draw_rect(Rect2((c + Vector2(cos(a), sin(a)) * (STAR_R + 12.0) - Vector2(2, 2)).snapped(Vector2(2, 2)), Vector2(4, 4)), Color(1, 1, 1, 0.8))

## The capsule's picture (the transfer animations draw the same one): a dark rim, the
## Dial's colour on the top half with a lighter band, a white bottom half with a shadow,
## a shine, and a soft halo of its colour.
static func draw_capsule_at(ci: CanvasItem, pos: Vector2, rot: float, color: Color, k: float) -> void:
	var r := CAPSULE_R * k
	ci.draw_circle(pos, r + 6.0 * k, Color(color.r, color.g, color.b, 0.16))
	ci.draw_circle(pos, r + 3.5 * k, Color(color.r, color.g, color.b, 0.2))
	ci.draw_set_transform(pos, rot)
	ci.draw_circle(Vector2.ZERO, r + 2.5 * k, Color("050818"))
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
	ci.draw_rect(Rect2(-r, -1.5 * k, 2.0 * r, 3.0 * k), Color("050818"))
	ci.draw_rect(Rect2(-r * 0.6, -r * 0.72, r * 0.42, r * 0.26), Color(1, 1, 1, 0.95))
	ci.draw_rect(Rect2(-r * 0.12, -r * 0.72, r * 0.14, r * 0.14), Color(1, 1, 1, 0.7))
	ci.draw_set_transform(Vector2.ZERO)
