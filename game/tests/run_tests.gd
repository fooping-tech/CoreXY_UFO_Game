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
	_test_pendulum_and_taut_rope()
	_test_playback_smoothing(rs)
	_test_playback_30hz_acceleration(rs)
	_test_mock_robot_settles(rs)
	_test_real_jog_velocity()
	_test_z_inverse_mapping(rs)
	_test_projection_consistency()
	_test_performance()
	_test_game_assets_in_sync()
	_test_ufo_metadata()
	_test_ufo_faces_and_pose_effects()
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

## A heavy UFO on a light, taut rope must swing like a simple pendulum: right
## period, rope straight (no snaking), no vertical bouncing.
func _test_pendulum_and_taut_rope() -> void:
	var s := _make()
	var dt := 1.0 / 60.0
	var v := 0.0
	var worst_kink := 0.0
	var worst_vy := 0.0
	for i in range(90):
		v = move_toward(v, 33.0, 133.0 * dt)
		s.anchor += Vector3(v * dt, 0.0, 0.0)
		s.step(dt)
		if i >= 30:
			worst_vy = maxf(worst_vy, absf(s.ufo_velocity().y))
			for k in range(1, s.points.size() - 1):
				var a := s.points[k].position - s.points[k - 1].position
				var b := s.points[k + 1].position - s.points[k].position
				worst_kink = maxf(worst_kink, rad_to_deg(a.angle_to(b)))
	_ok(worst_kink < 2.0, "pendulum: taut rope stays straight while cruising", "max bend %.2f deg" % worst_kink)
	_ok(worst_vy < 10.0, "pendulum: UFO does not bounce vertically", "max |vy| %.1f cm/s" % worst_vy)
	# hard stop, then time the zero crossings of the swing
	var crossings: Array[float] = []
	var prev := s.ufo_position().x - s.anchor.x
	for i in range(360):
		s.step(dt)
		var off := s.ufo_position().x - s.anchor.x
		if off * prev < 0.0:
			crossings.append(i * dt)
		prev = off
	var expected := TAU * sqrt(40.0 / s.gravity)
	var period := 2.0 * (crossings[-1] - crossings[0]) / float(crossings.size() - 1) if crossings.size() >= 3 else 0.0
	_ok(absf(period - expected) < expected * 0.1, "pendulum: swing period ~ 2*pi*sqrt(L/g)", "period %.2f s, expected %.2f s" % [period, expected])

## Status samples arrive at irregular wall-clock times (batched physics ticks,
## network jitter). Playback must still move the anchor in even steps and must
## not overshoot when the robot stops.
func _test_playback_smoothing(rs: Node) -> void:
	rs.clear_samples()
	var dt := 1.0 / 60.0
	var t_ms := 1000.0
	var x := 100.0
	var deltas: Array[float] = []
	var last := -1.0
	var overshoot := 0.0
	for i in range(120):
		# all of these run inside one real frame: the wall clock barely moves,
		# exactly like ticks that Godot batches after a slow frame
		if i < 80:
			x += 2.0
		t_ms += dt * 1000.0
		rs.push_pose(x, 100.0, 50.0, "", t_ms)
		var p: Vector3 = rs.playback_pose(dt)
		if last >= 0.0 and i > 10 and i < 75:
			deltas.append(p.x - last)
		overshoot = maxf(overshoot, p.x - x)
		last = p.x
	var lo: float = deltas.min()
	var hi: float = deltas.max()
	_ok(lo > 1.8 and hi < 2.2, "playback: even anchor steps despite batched ticks", "step min %.3f max %.3f mm" % [lo, hi])
	_ok(overshoot <= 1e-4, "playback: never overshoots the newest sample", "%.3f mm" % overshoot)
	_ok(absf(rs.sample_at(t_ms + 500.0).x - x) < 1e-4, "playback: holds the last sample (no extrapolation)")
	rs.clear_samples()

## A 30 Hz stream of an accelerating move: with linear interpolation the
## velocity is a staircase (constant for two ticks, then a jump), so the rope
## gets acceleration in 0 / 2x pulses. The cubic must keep it even.
func _test_playback_30hz_acceleration(rs: Node) -> void:
	rs.clear_samples()
	var dt := 1.0 / 60.0
	var accel := 0.0004 # mm/ms^2 (400 mm/s^2)
	var xs: Array[float] = []
	for i in range(90):
		if i % 2 == 0:
			var t := 1000.0 + i * dt * 1000.0
			var dt_ms := t - 1000.0
			rs.push_pose(100.0 + 0.5 * accel * dt_ms * dt_ms, 100.0, 50.0, "", t)
		xs.append(rs.playback_pose(dt).x)
	var worst := 0.0
	var mean := 0.0
	var count := 0
	for i in range(30, 80):
		var dd: float = (xs[i] - xs[i - 1]) - (xs[i - 1] - xs[i - 2])
		mean += dd
		count += 1
	mean /= float(count)
	for i in range(30, 80):
		var dd: float = (xs[i] - xs[i - 1]) - (xs[i - 1] - xs[i - 2])
		worst = maxf(worst, absf(dd - mean))
	_ok(mean > 0.0 and worst < mean * 0.3, "playback: 30 Hz samples give even acceleration (no 0/2x pulses)", "mean %.4f worst dev %.4f mm/tick^2" % [mean, worst])
	rs.clear_samples()

## The mock's discrete axis controller used to overshoot and hunt around the
## target (+-0.1 mm) forever: values chattered and the state stayed MOVING_XY.
func _test_mock_robot_settles(rs: Node) -> void:
	var m := MockRobot.new()
	add_child(m)
	m.set_target(Vector3(40.0, 20.0, m.pos.z))
	var overshoot := false
	for i in range(600):
		m._physics_process(1.0 / 60.0)
		overshoot = overshoot or m.pos.x < 40.0 - 1e-6
	_ok(m.pos.x == 40.0 and m.pos.y == 20.0 and m.vel == Vector3.ZERO, "mock: settles exactly on the target", "pos %s vel %s" % [m.pos, m.vel])
	_ok(not overshoot, "mock: no overshoot past the target")
	_ok(m._state_string() == "IDLE", "mock: IDLE after arriving", m._state_string())
	remove_child(m)
	m.free()
	rs.clear_samples()

## Arrow keys -> jog velocity for the real robot: same speed on diagonals, zero when released.
func _test_real_jog_velocity() -> void:
	var main_script: GDScript = load("res://scripts/game/main.gd")
	var right: Vector2 = main_script.jog_velocity(Vector2(1, 0), 40.0)
	var diag: Vector2 = main_script.jog_velocity(Vector2(1, 1), 40.0)
	var none: Vector2 = main_script.jog_velocity(Vector2.ZERO, 40.0)
	_ok(right.is_equal_approx(Vector2(40, 0)), "jog: arrow key -> 40 mm/s along the axis", str(right))
	_ok(absf(diag.length() - 40.0) < 1e-4 and diag.x > 0 and diag.y > 0, "jog: diagonal keeps the speed", str(diag))
	_ok(none == Vector2.ZERO, "jog: released -> zero", str(none))

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
	s.substeps = 16
	var t0 := Time.get_ticks_usec()
	for i in range(600):
		s.anchor = Vector3(10.0 * sin(i * 0.05), 0, 0)
		s.step(1.0 / 60.0)
	var per := (Time.get_ticks_usec() - t0) / 600.0
	_ok(per < 2000.0, "perf: one 60Hz step well under 2 ms", "%.0f us/step" % per)
	print("      (avg %.0f us per step, 16 segments x 16 substeps)" % per)

## tools/build_ufo_assets.py writes to <repo>/assets; the game only reads
## res://assets. Catch a forgotten sync.
func _test_game_assets_in_sync() -> void:
	var src_root := ProjectSettings.globalize_path("res://").path_join("../assets").simplify_path()
	var stale: Array[String] = []
	var checked := 0
	for sub in ["ufo", "rope", "effects"]:
		var dir := src_root.path_join(sub)
		for f in DirAccess.get_files_at(dir):
			if not (f.ends_with(".png") or f.ends_with(".json")):
				continue
			checked += 1
			var game_path := "res://assets/%s/%s" % [sub, f]
			if not FileAccess.file_exists(game_path) or FileAccess.get_file_as_bytes(game_path) != FileAccess.get_file_as_bytes(dir.path_join(f)):
				stale.append(sub + "/" + f)
	_ok(checked > 0 and stale.is_empty(), "assets: game/assets matches assets/ (run tools/build_ufo_assets.py)", "checked %d, stale %s" % [checked, str(stale)])

func _test_ufo_metadata() -> void:
	var meta = JSON.parse_string(FileAccess.get_file_as_string("res://assets/ufo/ufo_metadata.json"))
	_ok(meta is Dictionary and meta.has("sheets"), "metadata: parses with sheets")
	if not (meta is Dictionary):
		return
	var missing: Array[String] = []
	for name in meta.sheets.keys():
		if not ResourceLoader.exists(meta.sheets[name].file):
			missing.append(name)
	_ok(missing.is_empty(), "metadata: every sheet texture exists", str(missing))
	var poses: Array = meta.sheets.get("action_poses", {}).get("frames", [])
	var fx: Array = meta.sheets.get("action_effects", {}).get("frames", [])
	_ok(poses.size() > 0 and poses.size() == fx.size(), "metadata: action_effects aligned 1:1 with action_poses", "%d poses, %d fx" % [poses.size(), fx.size()])

func _test_ufo_faces_and_pose_effects() -> void:
	var ufo: UfoCharacter = load("res://scenes/ufo.tscn").instantiate()
	add_child(ufo)
	var tick := func(): ufo.update_motion(0.0, 0.0, 0.0, Vector2.ZERO, 1.0, 1.0 / 60.0)
	ufo.mood = "ERROR"
	tick.call()
	_ok(ufo.current_face() == "surprised", "face: ERROR -> surprised", ufo.current_face())
	ufo.mood = "DISCONNECTED"
	tick.call()
	_ok(ufo.current_face() == "worried", "face: DISCONNECTED -> worried", ufo.current_face())
	ufo.mood = "Z_LOWERING"
	tick.call()
	_ok(ufo.current_face() == "strain_up" and ufo.pose_effects_visible(), "face: Z_LOWERING -> strain_up pose with effect overlay", "%s fx=%s" % [ufo.current_face(), ufo.pose_effects_visible()])
	var body: Sprite2D = ufo.get_node("Body")
	var fx: Sprite2D = ufo.get_node("PoseEffects")
	_ok(fx.position == body.position and fx.scale == body.scale and fx.region_rect.size == body.region_rect.size, "pose fx: overlay registered on the pose cell", "%s vs %s" % [fx.position, body.position])
	ufo.mood = "ERROR"
	tick.call()
	_ok(not ufo.pose_effects_visible(), "pose fx: hidden for plain expressions")
	ufo.show_pose_effects = false
	ufo.mood = "Z_LOWERING"
	tick.call()
	_ok(not ufo.pose_effects_visible(), "pose fx: can be switched off")
	remove_child(ufo)
	ufo.free()
