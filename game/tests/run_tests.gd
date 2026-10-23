extends Node
## Headless physics / mapping tests. Run with:
##   godot --headless --path game res://tests/test_runner.tscn
## Exit code 0 when everything passes.

var _fails := 0
var _passes := 0

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_passes += 1
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", detail)

func _ready() -> void:
	var rs: Node = RobotState
	_test_rest_state()
	_test_inextensible_under_motion()
	_test_sudden_stop_swing_and_decay()
	_test_xy_diagonal_3d()
	_test_rope_length_change()
	_test_z_inverse_mapping(rs)
	_test_projection_consistency()
	_test_performance()
	print("\n%d passed, %d failed" % [_passes, _fails])
	get_tree().quit(0 if _fails == 0 else 1)

func _make() -> RopeSimulator:
	var s := RopeSimulator.new()
	s.rope_length = 40.0
	s.target_rope_length = 40.0
	s.reset()
	return s

func _max_stretch(s: RopeSimulator) -> float:
	var seg := s.segment_length()
	var worst := 0.0
	for i in range(1, s.points.size()):
		var d := (s.points[i].position - s.points[i - 1].position).length()
		worst = maxf(worst, d / seg)
	return worst

func _test_rest_state() -> void:
	var s := _make()
	for i in range(600):
		s.step(1.0 / 60.0)
	var u := s.ufo_position()
	_ok(absf(u.x) < 0.01 and absf(u.z) < 0.01, "rest: UFO hangs straight below anchor", str(u))
	_ok(absf(s.anchor_to_ufo_distance() - 40.0) < 0.05, "rest: anchor-UFO distance == rope length", str(s.anchor_to_ufo_distance()))
	_ok(s.ufo_velocity().length() < 0.01, "rest: no spontaneous vibration", str(s.ufo_velocity()))
	_ok(_max_stretch(s) < 1.01, "rest: no segment stretched >1%", str(_max_stretch(s)))

func _test_inextensible_under_motion() -> void:
	var s := _make()
	var worst := 0.0
	var worst_dist := 0.0
	var t := 0.0
	for i in range(900):
		t += 1.0 / 60.0
		# fast lateral anchor sweep 30 cm amplitude at 0.8 Hz, plus depth
		s.anchor = Vector3(30.0 * sin(t * TAU * 0.8), 0.0, 12.0 * sin(t * TAU * 0.5))
		s.step(1.0 / 60.0)
		worst = maxf(worst, _max_stretch(s))
		worst_dist = maxf(worst_dist, s.anchor_to_ufo_distance())
	_ok(worst < 1.05, "motion: segments never stretch >5%", "max stretch ratio %.3f" % worst)
	_ok(worst_dist <= 40.0 + 1e-3, "motion: UFO never further than rope length", "max %.3f" % worst_dist)
	_ok(is_finite(s.ufo_position().length()), "motion: no NaN", str(s.ufo_position()))

func _test_sudden_stop_swing_and_decay() -> void:
	var s := _make()
	# accelerate anchor to the right for 0.5 s at 60 cm/s, then stop dead
	for i in range(30):
		s.anchor += Vector3(1.0, 0.0, 0.0)
		s.step(1.0 / 60.0)
	var lag := s.anchor.x - s.ufo_position().x
	_ok(lag > 2.0, "accel: UFO lags behind the anchor (inertia)", "lag %.2f" % lag)
	var max_swing := 0.0
	var amp_early := 0.0
	var amp_late := 0.0
	for i in range(900):
		s.step(1.0 / 60.0)
		var dx := absf(s.ufo_position().x - s.anchor.x)
		max_swing = maxf(max_swing, dx)
		if i < 120:
			amp_early = maxf(amp_early, dx)
		if i >= 780:
			amp_late = maxf(amp_late, dx)
	_ok(max_swing > 3.0, "stop: pendulum swing after sudden stop", "max %.2f" % max_swing)
	_ok(amp_late < amp_early * 0.6, "stop: swing decays (damping)", "early %.2f late %.2f" % [amp_early, amp_late])
	_ok(max_swing < 40.0, "stop: swing does not exceed rope length", "max %.2f" % max_swing)

func _test_xy_diagonal_3d() -> void:
	var s := _make()
	for i in range(30):
		s.anchor += Vector3(0.8, 0.0, -0.8)
		s.step(1.0 / 60.0)
	var u := s.ufo_position() - s.anchor
	_ok(u.x < -1.0 and u.z > 1.0, "diagonal: UFO lags in both X and depth", str(u))
	var seen_z := 0.0
	for i in range(300):
		s.step(1.0 / 60.0)
		seen_z = maxf(seen_z, absf(s.ufo_position().z - s.anchor.z))
	_ok(seen_z > 1.0, "diagonal: depth (front/back) swing visible", "%.2f" % seen_z)

func _test_rope_length_change() -> void:
	var s := _make()
	s.rope_length_rate = 60.0
	s.target_rope_length = 15.0
	var worst := 0.0
	for i in range(240):
		s.step(1.0 / 60.0)
		worst = maxf(worst, _max_stretch(s))
	_ok(absf(s.rope_length - 15.0) < 1e-3, "reel in: rope reaches target length", "%.2f" % s.rope_length)
	_ok(absf(s.anchor_to_ufo_distance() - 15.0) < 0.1, "reel in: UFO rises with shorter rope", "%.2f" % s.anchor_to_ufo_distance())
	_ok(worst < 1.05, "reel in: no stretch while reeling", "%.3f" % worst)
	s.target_rope_length = 70.0
	s.rope_length_rate = 0.0 # snap
	for i in range(240):
		s.step(1.0 / 60.0)
	_ok(absf(s.anchor_to_ufo_distance() - 70.0) < 0.2, "snap out: UFO settles at new length without exceeding it", "%.2f" % s.anchor_to_ufo_distance())
	# clamp
	s.target_rope_length = 500.0
	s.step(1.0 / 60.0)
	_ok(s.rope_length <= s.max_rope_length, "rope length clamped to max", "%.1f" % s.rope_length)

func _test_z_inverse_mapping(rs: Node) -> void:
	var r: Dictionary = GameConfig.robot()
	var top_len: float = rs.rope_length_for_z(r.z_max_mm if r.z_up_is_positive else r.z_min_mm)
	var bot_len: float = rs.rope_length_for_z(r.z_min_mm if r.z_up_is_positive else r.z_max_mm)
	_ok(top_len > bot_len, "Z inverse: arm at TOP -> rope LONGEST (UFO lowest)", "top %.1f bottom %.1f" % [top_len, bot_len])
	var mid: float = rs.rope_length_for_z((r.z_min_mm + r.z_max_mm) * 0.5)
	_ok(mid > bot_len and mid < top_len, "Z inverse: monotonic", "%.1f" % mid)
	# anchor mapping sanity: robot X+ -> world +X, robot Y+ -> world -Z (away)
	var a0: Vector3 = rs.anchor_for_xy(r.x_min_mm, r.y_min_mm)
	var a1: Vector3 = rs.anchor_for_xy(r.x_max_mm, r.y_max_mm)
	_ok(a1.x > a0.x and a1.z < a0.z, "anchor: robot X+ -> right, Y+ -> away", str(a0) + " " + str(a1))

func _test_projection_consistency() -> void:
	var p := Projection25D.new()
	p.origin_px = Vector2(500, 30)
	var s := _make()
	s.anchor = Vector3(5, 0, -8)
	for i in range(120):
		s.step(1.0 / 60.0)
	# The UFO sprite is placed at project(ufo_position); the rope's last point
	# is project(points[n-1].position). They are the same world point, so the
	# screen points must coincide exactly.
	var a := p.project(s.ufo_position()).screen
	var b := p.project(s.points[s.points.size() - 1].position).screen
	_ok(a.is_equal_approx(b), "projection: rope end and UFO coincide", str(a) + " " + str(b))
	var far := p.project(Vector3(0, -20, -30))
	var near := p.project(Vector3(0, -20, 30))
	_ok(far.scale < near.scale, "projection: far objects smaller", "%.3f %.3f" % [far.scale, near.scale])
	_ok(far.screen.y < near.screen.y, "projection: far objects higher on screen", "%.1f %.1f" % [far.screen.y, near.screen.y])
	var anchor_px := p.project(Vector3.ZERO).screen
	_ok(anchor_px.is_equal_approx(p.origin_px), "projection: world origin maps to origin_px", str(anchor_px))

func _test_performance() -> void:
	var s := _make()
	s.segment_count = 16
	s.iterations = 8
	var t0 := Time.get_ticks_usec()
	for i in range(600):
		s.anchor = Vector3(10.0 * sin(i * 0.05), 0, 0)
		s.step(1.0 / 60.0)
	var per := (Time.get_ticks_usec() - t0) / 600.0
	_ok(per < 2000.0, "perf: one 60Hz step well under 2 ms", "%.0f us/step" % per)
	print("      (avg %.0f us per step, 16 segments x 8 iterations)" % per)
