class_name RopeSimulator
extends RefCounted
## 3D Verlet / position-based rope with a fixed, movable top anchor and a heavy
## end mass (the UFO). Pure math: no Godot scene nodes, no rendering.
##
## World frame (right-handed, centimetres):
##   +X = right, +Y = up (gravity is -Y), +Z = towards the camera (front / 手前).
## The real crane's X maps to world X, its Y (front/back) to world Z, and its
## arm height to the rope length (see RobotState.rope_length_for_z()).
##
## Solver: each 60 Hz step is split into `substeps` small steps ("small steps"
## XPBD style). Every substep integrates once, projects all segment constraints
## with one direct tridiagonal solve (exact for any mass ratio) and then applies
## a long-range attachment so no point is ever further from the anchor than its
## arc length. There is no iterative Gauss-Seidel and no follow-the-leader pass,
## so the solver does not inject energy: the rope stays taut and smooth and the
## UFO swings like a real pendulum.

## Rope mass point as seen from outside (read it, do not write it). The solver
## works on packed arrays and mirrors them here once per step.
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
## Solver substeps per step. Each substep integrates and solves the whole chain
## once; more substeps = more accurate swing and less stretch under fast motion.
var substeps: int = 16
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
var anchor: Vector3 = Vector3.ZERO
var _prev_anchor: Vector3 = Vector3.ZERO
var _anchor_velocity: Vector3 = Vector3.ZERO
var _anchor_accel: Vector3 = Vector3.ZERO
var _ufo_velocity: Vector3 = Vector3.ZERO
var last_step_usec: int = 0
var step_count: int = 0
# solver working set (packed for speed; `points` mirrors it)
var _pos := PackedVector3Array()
var _prev := PackedVector3Array()
var _w := PackedFloat64Array()
# scratch buffers for the direct chain solve (sized in _rebuild)
var _dir := PackedVector3Array()
var _rhs := PackedFloat64Array()
var _cp := PackedFloat64Array()
var _lam := PackedFloat64Array()

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
	_pos.resize(points.size())
	_prev.resize(points.size())
	_w.resize(points.size())
	for i in range(points.size()):
		_pos[i] = points[i].position
		_prev[i] = points[i].previous
		_w[i] = points[i].inv_mass
	_dir.resize(segment_count)
	_rhs.resize(segment_count)
	_cp.resize(segment_count)
	_lam.resize(segment_count)
	_prev_anchor = anchor
	_anchor_velocity = Vector3.ZERO
	_anchor_accel = Vector3.ZERO
	_ufo_velocity = Vector3.ZERO

func set_ufo_mass(m: float) -> void:
	ufo_mass = maxf(m, 0.01)
	if points.size() > 0:
		points[points.size() - 1].inv_mass = 1.0 / ufo_mass
		_w[_w.size() - 1] = 1.0 / ufo_mass

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
		for i in range(1, _pos.size()):
			_pos[i] = anchor + (_pos[i] - anchor) * ratio
			_prev[i] = anchor + (_prev[i] - anchor) * ratio
	var seg := segment_length()

	# -- anchor kinematics (used for exaggeration and for character reactions)
	var from_anchor := _prev_anchor
	var new_anchor_vel := (anchor - _prev_anchor) / dt
	_anchor_accel = (new_anchor_vel - _anchor_velocity) / dt
	_anchor_velocity = new_anchor_vel
	_prev_anchor = anchor

	var n := points.size()
	var sub_count := maxi(substeps, 1)
	var h := dt / float(sub_count)
	var damp := exp(-damping * h)
	var ufo_damp := exp(-(damping + ufo_drag) * h)
	var acc := Vector3(0.0, -gravity, 0.0)
	if swing_gain != 1.0:
		# Pseudo-force in the anchor frame: exaggerate the inertial kick.
		acc -= _anchor_accel * (swing_gain - 1.0)
	var acc_h2 := acc * h * h
	var step_limit := max_step / float(sub_count)
	for sub in range(sub_count):
		# The anchor travels along its path inside the step instead of jumping
		# once per frame, so the rope sees a smooth drive.
		var a := from_anchor.lerp(anchor, float(sub + 1) / float(sub_count))
		# -- Verlet integration
		for i in range(1, n):
			var x := _pos[i]
			var vel := (x - _prev[i]) * (ufo_damp if i == n - 1 else damp)
			if vel.length_squared() > step_limit * step_limit:
				vel = vel.normalized() * step_limit
			_prev[i] = x
			_pos[i] = x + vel + acc_h2
		# -- kinematic anchor
		_prev[0] = _pos[0]
		_pos[0] = a
		# -- distance constraints (mass weighted, equality: the rope neither
		#    stretches nor piles up on itself), all segments in one direct solve
		_solve_chain(seg)
		# -- long-range attachment: no point may be further from the anchor than
		#    its arc length. Inequality only (a slack rope is allowed); the anchor
		#    is kinematic so only the point moves. This is the hard guarantee that
		#    the UFO never hangs below the rope length.
		for i in range(1, n):
			var d := _pos[i] - a
			var limit := seg * float(i)
			if d.length_squared() > limit * limit:
				_pos[i] = a + d * (limit / d.length())
	_ufo_velocity = (_pos[n - 1] - _prev[n - 1]) / h
	_sync_points()
	last_step_usec = Time.get_ticks_usec() - t0

## Project every segment back to `seg` in one linearised step. The segment
## constraints of a chain form a symmetric tridiagonal system
##   (J W J^T) lambda = -C,  diag_j = w_j + w_j+1,  off_j = -w_j+1 (n_j . n_j+1)
## which the Thomas algorithm solves exactly in O(n). Unlike Gauss-Seidel this
## converges in one pass for any mass ratio (heavy UFO on a light rope).
func _solve_chain(seg: float) -> void:
	var m := _pos.size() - 1 # number of segments
	for j in range(m):
		var d := _pos[j + 1] - _pos[j]
		var dist := d.length()
		_dir[j] = d / dist if dist > 1e-9 else Vector3.DOWN
		_rhs[j] = seg - dist
	# forward elimination
	var prev_c := 0.0
	var prev_d := 0.0
	for j in range(m):
		var wj := _w[j]
		var wk := _w[j + 1]
		var lower := -wj * _dir[j - 1].dot(_dir[j]) if j > 0 else 0.0
		var upper := -wk * _dir[j].dot(_dir[j + 1]) if j < m - 1 else 0.0
		var denom := wj + wk - lower * prev_c
		if absf(denom) < 1e-12:
			denom = 1e-12
		prev_c = upper / denom
		prev_d = (_rhs[j] - lower * prev_d) / denom
		_cp[j] = prev_c
		_lam[j] = prev_d
	# back substitution
	for j in range(m - 2, -1, -1):
		_lam[j] -= _cp[j] * _lam[j + 1]
	# dp_i = w_i (lambda_i-1 n_i-1 - lambda_i n_i)
	for i in range(1, m + 1):
		var corr := _lam[i - 1] * _dir[i - 1]
		if i < m:
			corr -= _lam[i] * _dir[i]
		_pos[i] += corr * _w[i]

func _sync_points() -> void:
	for i in range(points.size()):
		points[i].position = _pos[i]
		points[i].previous = _prev[i]

## Instantly move the whole rope with the anchor (no inertial kick). Used when
## the robot teleports (first state after connect) so the UFO does not whip.
func translate_all(offset: Vector3) -> void:
	for i in range(_pos.size()):
		_pos[i] += offset
		_prev[i] += offset
	_prev_anchor += offset
	_sync_points()
