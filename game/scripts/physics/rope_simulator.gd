class_name RopeSimulator
extends RefCounted
## 3D Verlet / position-based rope with a fixed, movable top anchor and a heavy
## end mass (the UFO). Pure math: no Godot scene nodes, no rendering.
##
## World frame (right-handed, centimetres):
##   +X = right, +Y = up (gravity is -Y), +Z = towards the camera (front / 手前).
## The real crane's X maps to world X, its Y (front/back) to world Z, and its
## arm height to the rope length (see RobotState.rope_length_for_z()).

## Rope mass point. Kept as a light inner class so arrays stay cache friendly.
class Point:
	var position: Vector3
	var previous: Vector3
	var inv_mass: float = 1.0

	func _init(p: Vector3, w: float = 1.0) -> void:
		position = p
		previous = p
		inv_mass = w

# ------------------------------------------------------------------ tunables
## Number of rope segments (points = segments + 1). Changing it rebuilds the rope.
var segment_count: int = 16:
	set(v):
		v = clampi(v, 2, 64)
		if v != segment_count:
			segment_count = v
			_rebuild()
## Distance-constraint solver iterations per step.
var iterations: int = 8
## Gravity magnitude in world units / s^2 (cm). Real gravity ~ 980.
var gravity: float = 980.0
## Velocity damping per second (0 = no damping). ~0.4 looks like a real string.
var damping: float = 0.45
## Air drag that only affects the UFO point (extra damping, per second).
var ufo_drag: float = 0.25
## Mass of the UFO relative to one rope point (rope point mass = 1).
var ufo_mass: float = 25.0
## Current rope length (cm). Target is reached at rope_length_rate.
var rope_length: float = 40.0
## Desired rope length (cm), e.g. from the real Z axis.
var target_rope_length: float = 40.0
## Max rope length change speed (cm/s). 0 = snap instantly.
var rope_length_rate: float = 60.0
var min_rope_length: float = 8.0
var max_rope_length: float = 90.0
## Artistic exaggeration of anchor acceleration transmitted into the rope.
## 1.0 = physically faithful. >1 makes the UFO swing more on start/stop.
var swing_gain: float = 1.0
## Maximum per-step point displacement (cm) to keep the solver stable when the
## anchor teleports (e.g. first robot state after reconnect).
var max_step: float = 40.0

# ------------------------------------------------------------------ state
var points: Array[Point] = []
var anchor: Vector3 = Vector3.ZERO:
	set(v):
		anchor = v
var _prev_anchor: Vector3 = Vector3.ZERO
var _anchor_velocity: Vector3 = Vector3.ZERO
var _anchor_accel: Vector3 = Vector3.ZERO
var _ufo_velocity: Vector3 = Vector3.ZERO
var last_step_usec: int = 0
var step_count: int = 0

func _init() -> void:
	_rebuild()

## Rebuild all points hanging straight down from the anchor (rest state).
func reset(hang_down: bool = true) -> void:
	_rebuild(hang_down)

func _rebuild(hang_down: bool = true) -> void:
	points.clear()
	var seg: float = rope_length / float(segment_count)
	for i in range(segment_count + 1):
		var p := anchor + Vector3(0.0, -seg * float(i) if hang_down else 0.0, 0.0)
		var w: float = 1.0
		if i == 0:
			w = 0.0 # anchor is kinematic
		elif i == segment_count:
			w = 1.0 / maxf(ufo_mass, 0.01)
		points.append(Point.new(p, w))
	_prev_anchor = anchor
	_anchor_velocity = Vector3.ZERO
	_anchor_accel = Vector3.ZERO
	_ufo_velocity = Vector3.ZERO

func set_ufo_mass(m: float) -> void:
	ufo_mass = maxf(m, 0.01)
	if points.size() > 0:
		points[points.size() - 1].inv_mass = 1.0 / ufo_mass

func segment_length() -> float:
	return rope_length / float(segment_count)

func ufo_point() -> Point:
	return points[points.size() - 1]

func ufo_position() -> Vector3:
	return points[points.size() - 1].position

func ufo_velocity() -> Vector3:
	return _ufo_velocity

func anchor_velocity() -> Vector3:
	return _anchor_velocity

func anchor_acceleration() -> Vector3:
	return _anchor_accel

## Direction of the last rope segment (from the second-last point to the UFO).
func end_tangent() -> Vector3:
	var n := points.size()
	var d := points[n - 1].position - points[n - 2].position
	return d.normalized() if d.length_squared() > 1e-9 else Vector3.DOWN

## Actual straight-line length from anchor to UFO (<= rope_length when slack).
func anchor_to_ufo_distance() -> float:
	return (ufo_position() - anchor).length()

## Sum of segment lengths currently realised by the solver.
func realised_length() -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += (points[i].position - points[i - 1].position).length()
	return total

## Advance the simulation by dt seconds. Call at a fixed rate (60 Hz).
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	var t0 := Time.get_ticks_usec()
	step_count += 1

	# -- rope length follows its target at a bounded rate (natural reel in/out)
	target_rope_length = clampf(target_rope_length, min_rope_length, max_rope_length)
	var old_length := rope_length
	if rope_length_rate <= 0.0:
		rope_length = target_rope_length
	else:
		rope_length = move_toward(rope_length, target_rope_length, rope_length_rate * dt)
	if absf(rope_length - old_length) > 1e-6 and old_length > 1e-6:
		# Reeling in/out: scale the hanging shape about the anchor so the rope
		# keeps its curve instead of compressing/folding onto itself.
		var ratio := rope_length / old_length
		for i in range(1, points.size()):
			var p := points[i]
			p.position = anchor + (p.position - anchor) * ratio
			p.previous = anchor + (p.previous - anchor) * ratio
	var seg := segment_length()

	# -- anchor kinematics (used for exaggeration and for character reactions)
	var new_anchor_vel := (anchor - _prev_anchor) / dt
	_anchor_accel = (new_anchor_vel - _anchor_velocity) / dt
	_anchor_velocity = new_anchor_vel
	_prev_anchor = anchor

	# -- Verlet integration
	var n := points.size()
	var damp := exp(-damping * dt)
	var ufo_damp := exp(-(damping + ufo_drag) * dt)
	var g := Vector3(0.0, -gravity, 0.0)
	var extra := Vector3.ZERO
	if swing_gain != 1.0:
		# Pseudo-force in the anchor frame: exaggerate the inertial kick.
		extra = -_anchor_accel * (swing_gain - 1.0)
	for i in range(1, n):
		var p := points[i]
		var vel := (p.position - p.previous)
		vel *= ufo_damp if i == n - 1 else damp
		if vel.length() > max_step:
			vel = vel.normalized() * max_step
		var acc := g + extra
		p.previous = p.position
		p.position += vel + acc * dt * dt

	# -- kinematic anchor
	points[0].previous = points[0].position
	points[0].position = anchor

	# -- distance constraints (PBD, mass weighted). Rope is inextensible: each
	#    segment is pulled back to exactly `seg`. Compression is also removed so
	#    the chain does not pile up when the UFO is thrown upward (this keeps it
	#    behaving like a stiff rope rather than a loose chain).
	#    Gauss-Seidel converges slowly across a 25:1 mass ratio, so each
	#    iteration sweeps down the rope and then back up, and a final exact
	#    pass from the anchor removes any residual stretch.
	for _it in range(iterations):
		for i in range(n - 1):
			_solve_segment(i, seg)
		for i in range(n - 2, -1, -1):
			_solve_segment(i, seg)
		# Re-pin the anchor after every pass so the rope never drifts.
		points[0].position = anchor
	# Exact pass: walk from the fixed anchor and place each point at exactly
	# one segment length from its parent, preserving direction. This is what
	# makes the rope inextensible regardless of mass ratio or iteration count.
	for i in range(n - 1):
		var a := points[i]
		var b := points[i + 1]
		var delta := b.position - a.position
		var dist := delta.length()
		if dist < 1e-6:
			delta = Vector3.DOWN
			dist = 1.0
		b.position = a.position + delta * (seg / dist)
	var u := points[n - 1]

	_ufo_velocity = (u.position - u.previous) / dt
	last_step_usec = Time.get_ticks_usec() - t0

func _solve_segment(i: int, seg: float) -> void:
	var a := points[i]
	var b := points[i + 1]
	var delta := b.position - a.position
	var dist := delta.length()
	if dist < 1e-6:
		return
	var wsum := a.inv_mass + b.inv_mass
	if wsum <= 0.0:
		return
	var corr := delta * ((dist - seg) / dist)
	a.position += corr * (a.inv_mass / wsum)
	b.position -= corr * (b.inv_mass / wsum)

## Instantly move the whole rope with the anchor (no inertial kick). Used when
## the robot teleports (first state after connect) so the UFO does not whip.
func translate_all(offset: Vector3) -> void:
	for p in points:
		p.position += offset
		p.previous += offset
	_prev_anchor += offset
