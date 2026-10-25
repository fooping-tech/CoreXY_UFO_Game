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
	_test_fit_travel_to_screen(rs)
	_test_motion_fx()
	_test_z_inverse_mapping(rs)
	_test_projection_consistency()
	_test_performance()
	_test_game_assets_in_sync()
	_test_ufo_metadata()
	_test_ufo_faces_and_pose_effects()
	_test_camera_scope()
	_test_hand_joystick()
	_test_gesture_states()
	_test_gesture_with_mock_robot(rs)
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
	# Space with an arrow held latches; the arrow must be released before jogging again
	var latched: bool = main_script.jog_latch(true, true)
	_ok(latched, "jog: after Space a still-held arrow does not restart the robot")
	latched = main_script.jog_latch(latched, false)
	_ok(not latched, "jog: releasing the arrows clears the stop latch")
	_ok(not main_script.jog_latch(false, true), "jog: no latch without Space")
	# a refused jog is explained as the next thing to press
	var cases := {
		"motors not enabled (send enable_motors first)": "enable motors",
		"not homed": "home",
		"not_homed": "home",
		"alarm active: abort requested": "clear_alarm",
		"busy: another motion command is running": "Space",
		"not connected": "未接続",
	}
	var all_ok := true
	for reason in cases:
		if not str(main_script.jog_hint_for(reason)).contains(cases[reason]):
			all_ok = false
			print("      hint for %s: %s" % [reason, main_script.jog_hint_for(reason)])
	_ok(all_ok and main_script.jog_hint_for("") == "", "jog: refusals are shown as the next step to take")

## The robot's X range spans the play area: the UFO sprite reaches the margin at
## the tightest corner and never leaves the play area at any depth / rope length.
func _test_fit_travel_to_screen(rs: Node) -> void:
	var main_script: GDScript = load("res://scripts/game/main.gd")
	var p := Projection25D.new()
	var w: Dictionary = GameConfig.data.world
	var tz: float = w.travel_z_cm
	var rope_max: float = w.rope_max_cm
	var half_sprite := 96.0
	var margin := 24.0
	var all_inside := true
	var closest := INF
	for play_w in [1280.0, 900.0]:
		p.origin_px = Vector2(play_w * 0.5, 172.0)
		var swing_k: float = main_script.swing_per_travel(rope_max, 50.0)
		var travel: float = main_script.fit_travel_x_cm(p, play_w, tz, float(w.rope_min_cm), rope_max, half_sprite, margin, swing_k)
		var reach := 0.5 * travel + swing_k * travel  # anchor end + swing past it
		for z in [-0.5 * tz, 0.0, 0.5 * tz]:
			for y in [-float(w.rope_min_cm), -0.5 * (float(w.rope_min_cm) + rope_max), -rope_max]:
				for sx in [-1.0, 1.0]:
					var r := p.project(Vector3(sx * reach, y, z))
					var left := r.screen.x - half_sprite * r.scale
					var right := r.screen.x + half_sprite * r.scale
					all_inside = all_inside and left >= margin - 0.01 and right <= play_w - margin + 0.01
					closest = minf(closest, minf(left - margin, play_w - margin - right))
	_ok(all_inside, "fit X: UFO (incl. the swing at a stop) stays inside the play area at every depth and rope length")
	_ok(closest < 1.0, "fit X: the tightest corner reaches the edge margin", "gap %.2f px" % closest)
	var keep_fit = w.get("fit_travel_x_to_screen", false)
	var keep_val = w.get("travel_x_fit_cm", 0.0)
	var r: Dictionary = GameConfig.robot()
	w["travel_x_fit_cm"] = 150.0
	w["fit_travel_x_to_screen"] = true
	var fitted: Vector3 = rs.anchor_for_xy(r.x_max_mm, r.y_min_mm)
	w["fit_travel_x_to_screen"] = false
	var fixed: Vector3 = rs.anchor_for_xy(r.x_max_mm, r.y_min_mm)
	w["fit_travel_x_to_screen"] = keep_fit
	w["travel_x_fit_cm"] = keep_val
	_ok(is_equal_approx(fitted.x, 75.0) and is_equal_approx(fixed.x, 0.5 * float(w.travel_x_cm)), "fit X: anchor uses the fitted travel, or the fixed one when off", "%s %s" % [fitted, fixed])
	# A layout change (new fitted travel) must not kick the rope: the robot did not move.
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.mock.enabled = false
	rs.clear_samples()
	rs.push_pose(292.5, 100.0, float(r.z_max_mm), "", 1000.0)  # stationary, right of centre
	w["fit_travel_x_to_screen"] = true
	w["travel_x_fit_cm"] = 150.0
	for i in range(240):
		game._physics_process(1.0 / 60.0)
	var before: Vector3 = game.sim.anchor
	w["travel_x_fit_cm"] = 123.0  # e.g. the debug panel was shown
	var worst_v := 0.0
	for i in range(30):
		game._physics_process(1.0 / 60.0)
		worst_v = maxf(worst_v, game.sim.ufo_velocity().length())
	_ok(not is_equal_approx(game.sim.anchor.x, before.x) and game.sim.anchor_velocity().length() < 1e-3 and worst_v < 1.0,
		"fit X: a layout change moves the rope without kicking it", "anchor %.1f -> %.1f, max ufo v %.2f cm/s" % [before.x, game.sim.anchor.x, worst_v])
	w["fit_travel_x_to_screen"] = keep_fit
	w["travel_x_fit_cm"] = keep_val
	remove_child(game)
	game.free()
	rs.clear_samples()

## Sound / particle presentation follows the motion and stays out of the physics.
func _test_motion_fx() -> void:
	var main_script: GDScript = load("res://scripts/game/main.gd")
	var i: Vector3 = main_script.motion_intensities(Vector3(15, 0, 0), 0.0)
	var rise: Vector3 = main_script.motion_intensities(Vector3.ZERO, -8.0)  # rope shortening
	var sink: Vector3 = main_script.motion_intensities(Vector3.ZERO, 4.0)
	_ok(is_equal_approx(i.x, 1.0) and i.y == 0.0 and is_equal_approx(rise.y, 1.0) and rise.z == 0.0
		and is_equal_approx(sink.z, 0.5) and sink.y == 0.0, "fx: move / rise / sink intensities", "%s %s %s" % [i, rise, sink])

	var fx := UfoFx.new()
	add_child(fx)
	fx.update_fx(Vector2(400, 300), 1.0, Vector2(300, 0), 1.0, 0.0, 0.0, 1.0 / 60.0)
	var after_start := fx.particle_count()
	for k in range(30):
		fx.update_fx(Vector2(400 + k * 5, 300), 1.0, Vector2(300, 0), 1.0, 0.0, 0.0, 1.0 / 60.0)
	var moving := fx.particle_count()
	for k in range(int(UfoFx.STOP_HOLD_S * 60.0) + 1):
		fx.update_fx(Vector2(550, 300), 1.0, Vector2.ZERO, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var ring := fx.ring_count()
	for k in range(150):
		fx.update_fx(Vector2(550, 300), 1.0, Vector2.ZERO, 0.0, 0.0, 0.0, 1.0 / 60.0)
	_ok(after_start >= 10 and moving > after_start and ring >= 1 and fx.particle_count() == 0 and fx.ring_count() == 0,
		"fx: start burst, trail while moving, stop burst + ring, then clears",
		"start %d moving %d ring %d left %d" % [after_start, moving, ring, fx.particle_count()])
	for k in range(20):
		fx.update_fx(Vector2(400, 300), 1.0, Vector2.ZERO, 0.0, 1.0, 0.0, 1.0 / 60.0)
	var jets := fx.particle_count()
	fx.enabled = false
	for k in range(150):
		fx.update_fx(Vector2(400, 300), 1.0, Vector2(300, 0), 1.0, 1.0, 0.0, 1.0 / 60.0)
	_ok(jets > 18 and fx.particle_count() == 0, "fx: thrust while rising; nothing when switched off", "jets %d off %d" % [jets, fx.particle_count()])
	remove_child(fx)
	fx.free()

	# start / stop bursts kick the screen shake; the shake decays and never moves the physics
	var kicks: Array[float] = []
	var fx2 := UfoFx.new()
	add_child(fx2)
	fx2.kicked.connect(func(s): kicks.append(s))
	var move_stop := func(f: UfoFx, secs: float, peak: float) -> void:
		for k in range(int(secs * 60.0)):
			f.update_fx(Vector2(400, 300), 1.0, Vector2(300, 0), peak, 0.0, 0.0, 1.0 / 60.0)
		for k in range(20):
			f.update_fx(Vector2(400, 300), 1.0, Vector2.ZERO, 0.0, 0.0, 0.0, 1.0 / 60.0)
	move_stop.call(fx2, 0.3, 1.0)  # a tap: no shake (the 0.2 s stop wait does not count as motion)
	move_stop.call(fx2, 1.0, 0.5)
	move_stop.call(fx2, 1.0, 1.0)
	remove_child(fx2)
	fx2.free()
	# a held key with the speed dropping out for a few frames now and then: one
	# start and one stop, not a burst and a shake per dropout
	var held_kicks: Array[float] = []
	var fx4 := UfoFx.new()
	add_child(fx4)
	fx4.kicked.connect(func(s): held_kicks.append(s))
	for k in range(180):
		var dropout := k % 12 >= 9  # 3 frames of zero speed every 12
		fx4.update_fx(Vector2(400, 300), 1.0, Vector2(300, 0), 0.0 if dropout else 1.0, 0.0, 0.0, 1.0 / 60.0)
	var during := Vector2i(fx4.start_count, fx4.stop_count)
	for k in range(20):
		fx4.update_fx(Vector2(400, 300), 1.0, Vector2.ZERO, 0.0, 0.0, 0.0, 1.0 / 60.0)
	_ok(during == Vector2i(1, 0) and fx4.start_count == 1 and fx4.stop_count == 1 and held_kicks.size() == 1,
		"fx: a held key with speed dropouts gives one start, one stop and one shake",
		"during %s starts %d stops %d kicks %s" % [during, fx4.start_count, fx4.stop_count, held_kicks])
	remove_child(fx4)
	fx4.free()
	# particles off: still kicks the shake, but spawns nothing
	var off_kicks: Array[float] = []
	var fx3 := UfoFx.new()
	add_child(fx3)
	fx3.enabled = false
	fx3.kicked.connect(func(s): off_kicks.append(s))
	move_stop.call(fx3, 1.0, 1.0)
	_ok(off_kicks.size() == 1 and fx3.particle_count() == 0 and fx3.ring_count() == 0,
		"fx: particles off still kicks the shake on a stop", "kicks %s parts %d rings %d" % [off_kicks, fx3.particle_count(), fx3.ring_count()])
	remove_child(fx3)
	fx3.free()
	var sh := ScreenShake.new()
	sh.max_offset_px = 14.0
	sh.add_trauma(0.8)
	sh.step(1.0 / 60.0)
	var shaking := sh.offset.length()
	var bounded := true
	for k in range(120):
		sh.step(1.0 / 60.0)
		bounded = bounded and sh.offset.length() <= 14.0 * 1.5
	var settled := sh.offset.length()
	sh.enabled = false
	sh.add_trauma(1.0)
	sh.step(1.0 / 60.0)
	_ok(kicks.size() == 2 and kicks[1] > kicks[0] and shaking > 0.0 and bounded and settled == 0.0 and sh.offset == Vector2.ZERO,
		"shake: a stop after a real move kicks it (harder after a faster one, none after a tap), it decays to rest, off = still",
		"kicks %s shaking %.2f settled %.2f" % [kicks, shaking, settled])
	sh.free()

	var sfx := Sfx.new()
	add_child(sfx)  # files may be absent (not in the repo): must still work, silently
	_ok(Sfx.load_mp3("res://assets/audio/does-not-exist.mp3") == null, "sfx: a missing file loads as null (silence)")
	sfx.update_sfx(1.0, 0.0, 0.0, 0.1)
	var on := sfx.level("move")
	sfx.update_sfx(0.0, 0.0, 0.0, 0.1)
	var fading := sfx.level("move")
	sfx.enabled = false
	sfx.update_sfx(1.0, 1.0, 1.0, 1.0)
	_ok(is_equal_approx(on, 1.0) and fading > 0.5 and fading < 1.0 and sfx.level("up") == 0.0,
		"sfx: fades in fast, out slowly; silent when off", "on %.2f fading %.2f" % [on, fading])
	remove_child(sfx)
	sfx.free()

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
	var tele: Dictionary = meta.sheets.get("telescope", {})
	var tele_ok := int(tele.get("frame_count", 0)) == 2 and bool(tele.get("loop", false))
	for f in tele.get("frames", []):
		tele_ok = tele_ok and int(f.rope_attachment_local.x) == 32 and int(f.rope_attachment_local.y) == 5
	_ok(tele_ok, "metadata: telescope sheet, 2 looping frames on the usual knot", str(tele))

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
	# the telescope moment: peering while idle or moving the arm, mirrored to look left
	ufo.mood = "IDLE"
	ufo.peering = true
	tick.call()
	var looks_right := ufo.current_face() == "telescope" and not body.flip_h and ufo.lens_offset().x > 0.0
	ufo.peer_left = true
	tick.call()
	var looks_left := body.flip_h and ufo.lens_offset().x < 0.0 and body.position.x == -32.0 * ufo.pixel_scale
	ufo.mood = "Z_LOWERING"
	tick.call()
	var while_lowering := ufo.current_face() == "telescope"
	ufo.peering = false
	tick.call()
	_ok(looks_right and looks_left and while_lowering and ufo.current_face() == "strain_up" and not body.flip_h,
		"face: peers through the spyglass (right or mirrored left), then back", "%s %s %s %s" % [looks_right, looks_left, while_lowering, ufo.current_face()])
	remove_child(ufo)
	ufo.free()

func _test_camera_scope() -> void:
	var feeds := [{"id": 1, "name": "MacBook Airカメラ"}, {"id": 2, "name": "C270 HD WEBCAM"}, {"id": 3, "name": "USB Camera"}]
	_ok(CameraHub.pick_feed(feeds, "c270") == 2 and CameraHub.pick_feed(feeds, "") == -1 and CameraHub.pick_feed(feeds, "C270", [2]) == -1
		and CameraHub.pick_feed(feeds, " usb ") == 3 and CameraHub.pick_feed(feeds, "none") == -1,
		"camera: a role picks its camera by a name substring, never one already taken")
	# two identical webcams both match the overview pattern: unplugging the overview
	# one must not hand it the focus camera, and plugging it back restores it
	var two := [{"id": 5, "name": "C270 HD WEBCAM"}, {"id": 6, "name": "C270 HD WEBCAM"}]
	var pats := {"overview": "C270", "focus": "C270"}
	var none := {"overview": false, "focus": false}
	var first: Dictionary = CameraHub.fill_roles(two, {"overview": -1, "focus": -1}, pats, none)
	var unplugged: Dictionary = CameraHub.fill_roles([two[1]], first, pats, none)
	var back: Dictionary = CameraHub.fill_roles(two, unplugged, pats, none)
	var by_hand: Dictionary = CameraHub.fill_roles(two, {"overview": -1, "focus": 6}, pats, {"overview": true, "focus": true})
	_ok(first.overview == 5 and first.focus == 6 and unplugged.overview == -1 and unplugged.focus == 6
		and back.overview == 5 and back.focus == 6 and by_hand.overview == -1 and by_hand.focus == 6,
		"camera: unplugging one camera never moves another role's camera onto it", "%s %s %s %s" % [first, unplugged, back, by_hand])
	# headless: no cameras, but every view still gets a texture (static)
	var hub := CameraHub.new()
	add_child(hub)
	_ok(not hub.has_feed("focus") and hub.texture("focus") != null and hub.texture("overview") != null and is_equal_approx(hub.feed_aspect("focus"), 4.0 / 3.0),
		"camera: without cameras the roles show static at 4:3")

	var t := ScopeTrigger.new()
	var dt := 1.0 / 60.0
	var run := func(move: float, z: float, secs: float, lowering := false) -> bool:
		var o := false
		for i in range(int(secs * 60.0)):
			o = t.step(move, z, lowering, dt)
		return o
	var start_closed: bool = not run.call(0.0, 0.0, 2.0)
	var while_moving: bool = run.call(1.0, 0.0, 1.0)
	var just_stopped: bool = run.call(0.0, 0.0, 0.5)
	var settled: bool = run.call(0.0, 0.0, 0.3)
	var arm_moving: bool = run.call(0.0, 0.8, 12.0)
	var held: bool = run.call(0.0, 0.0, 9.5)
	var timed_out: bool = run.call(0.0, 0.0, 0.6)
	_ok(start_closed and not while_moving and not just_stopped and settled and arm_moving and held and not timed_out,
		"scope: opens once at rest after a move, stays while the arm moves, closes after hold_s",
		"%s %s %s %s %s %s %s" % [start_closed, while_moving, just_stopped, settled, arm_moving, held, timed_out])
	var z_opens: bool = run.call(0.0, 0.6, 0.1)
	var move_closes: bool = not run.call(0.6, 0.6, 0.1)
	t.toggle()
	var hand_open: bool = t.is_open and run.call(0.0, 0.0, 1.0)
	var hand_move_closes: bool = not run.call(1.0, 0.0, 0.1)
	run.call(0.0, 0.8, 0.1)  # arm moving: opens
	t.toggle()  # closed by hand while the arm still moves
	var stays_shut: bool = not run.call(0.0, 0.8, 1.0)
	run.call(0.0, 0.0, 0.1)
	var lowering_opens: bool = run.call(0.0, 0.0, 0.1, true)
	_ok(z_opens and move_closes and hand_open and hand_move_closes and stays_shut and lowering_opens,
		"scope: arm motion and lowering open it, a sideways move closes it, V toggles and a hand close sticks",
		"%s %s %s %s %s %s" % [z_opens, move_closes, hand_open, hand_move_closes, stays_shut, lowering_opens])

	var main_script: GDScript = load("res://scripts/game/main.gd")
	var mid: Vector3 = main_script.scope_placement(920.0, 720.0, 130.0, Vector2(400.0, 300.0))
	var edge: Vector3 = main_script.scope_placement(920.0, 720.0, 130.0, Vector2(860.0, 300.0))
	var inside := func(p: Vector3) -> bool: return p.x - 130.0 - 46.0 >= 0.0 and p.x + 130.0 + 46.0 <= 920.0 and p.y - 130.0 >= 0.0 and p.y + 130.0 <= 720.0
	_ok(mid.z > 0.0 and mid.x - 130.0 - 46.0 > 400.0 and edge.z < 0.0 and edge.x + 130.0 + 46.0 < 860.0 and inside.call(mid) and inside.call(edge),
		"scope: opens beside the UFO, on its right unless there is no room", "%s %s" % [mid, edge])

	var view := ScopeView.new()
	add_child(view)
	view.attach(hub)
	view.wanted = true
	for i in range(30):
		view.step(dt)
	var opened := view.is_fully_open() and view.visible and view.source_role() == ""
	view.wanted = false
	for i in range(30):
		view.step(dt)
	_ok(opened and not view.visible and view.open_amount == 0.0, "scope view: irises open, shows static without a camera, closes",
		"%s %s %.2f" % [opened, view.visible, view.open_amount])
	remove_child(view)
	view.free()
	remove_child(hub)
	hub.free()

# ------------------------------------------------------------ hand gesture joystick
## A hand_control event (640x480 frame), like the backend sends.
func _hev(seq: int, detected: bool, pinch: bool, x := 0.5, y := 0.5, extra := {}) -> Dictionary:
	var ev := {"event": "hand_control", "camera_ok": true, "detected": detected, "hand_count": 1 if detected else 0,
		"pinch": pinch, "hand_x": x, "hand_y": y, "pinch_ratio": 0.2 if pinch else 0.8, "confidence": 0.95,
		"reason": "" if detected else "no_hand", "frame_w": 640, "frame_h": 480, "sequence": seq, "timestamp": 0, "latency_ms": 30.0}
	ev.merge(extra, true)
	return ev

func _test_hand_joystick() -> void:
	var j := HandJoystick.new()
	j.smoothing_ms = 0.0
	j.set_anchor(Vector2(0.6, 0.5))
	var r := j.radius
	var dead := j.update(Vector2(0.6 + r * 0.1, 0.5), 0.05)
	var right := j.update(Vector2(0.6 + r * 0.5, 0.5), 0.05)
	var away := j.update(Vector2(0.6, 0.5 - r * 0.5), 0.05)  # hand moved up in the image
	var far := j.update(Vector2(0.6 + r * 3.0, 0.5), 0.05)
	var diag := j.update(Vector2(0.6 + r * 2.0, 0.5 - r * 2.0), 0.05)
	var back := j.update(Vector2(0.6, 0.5), 0.05)
	var mid := HandJoystick.shape(Vector2(r * 0.46, 0.0), r, 0.12, 0.8, 1.5).x  # half way between dead and full
	_ok(dead == Vector2.ZERO and right.x > 0.0 and is_zero_approx(right.y) and away.y > 0.0 and is_zero_approx(away.x)
		and is_equal_approx(far.x, j.max_speed) and diag.length() <= j.max_speed + 1e-3 and diag.x > 0.0 and diag.y > 0.0
		and back == Vector2.ZERO and is_equal_approx(mid, pow(0.5, 1.5)),
		"stick: dead zone, +X right, +Y away, curve, max speed, diagonal capped, centre stops",
		"%s %s %s %s %s %s mid %.3f" % [dead, right, away, far, diag, back, mid])
	j.invert_x = true
	j.swap_xy = true
	var swapped := j.update(Vector2(0.6 + r * 3.0, 0.5), 0.05)
	j.smoothing_ms = 80.0
	j.invert_x = false
	j.swap_xy = false
	j.set_anchor(Vector2(0.6, 0.5))
	var first := j.update(Vector2(0.6 + r * 3.0, 0.5), 1.0 / 60.0)
	_ok(is_equal_approx(swapped.y, j.max_speed) and is_zero_approx(swapped.x) and first.x > 0.0 and first.x < j.max_speed * 0.4,
		"stick: axes can be swapped / inverted; the output is smoothed", "%s %s" % [swapped, first])

func _test_gesture_states() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 100.0, "joystick": {"smoothing_ms": 0.0}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var dt := 1.0 / 60.0
	# one tick: the event (if any) arrives now, then the physics tick
	var step := func(ev: Dictionary, gate := "") -> Vector2:
		t[0] += dt * 1000.0
		if not ev.is_empty():
			seq[0] += 1
			ev["sequence"] = seq[0]
			g.on_event(ev, t[0])
		return g.tick(t[0], dt, gate)
	var hold := func(make: Callable, secs: float, gate := "") -> Vector2:
		var v := Vector2.ZERO
		for i in range(int(secs * 60.0)):
			v = step.call(make.call(), gate)
		return v
	var open_hand := func(): return _hev(0, true, false, 0.5, 0.5)
	var pinch_at := func(x: float, y: float): return func(): return _hev(0, true, true, x, y)

	step.call({})
	var waits := g.state == S.WAITING_HAND
	hold.call(open_hand, 0.1)
	var seen := g.state == S.HAND_DETECTED
	step.call(pinch_at.call(0.5, 0.5).call())
	var armed := g.state == S.ARMED and g.joystick.has_anchor
	hold.call(pinch_at.call(0.5, 0.5), 0.15)
	var active := g.state == S.ACTIVE and g.velocity == Vector2.ZERO  # anchor = where it pinched
	var v: Vector2 = hold.call(pinch_at.call(0.62, 0.5), 0.2)
	var moved := v.x > 0.0
	var released: Vector2 = step.call(open_hand.call())
	_ok(waits and seen and armed and active and moved and released == Vector2.ZERO and g.state == S.HAND_DETECTED and g.reason == "released",
		"gesture: hand -> pinch (anchor) -> ARMED -> ACTIVE moves; release = zero velocity",
		"%s %s %s %s %s %s %s" % [waits, seen, armed, active, moved, released, g.state_name()])

	# lost while steering: stops and stays stopped when the hand comes back still pinching
	hold.call(pinch_at.call(0.5, 0.5), 0.3)
	hold.call(pinch_at.call(0.62, 0.5), 0.1)
	var lost_v: Vector2 = step.call(_hev(0, false, false))
	var latched := g.state == S.WAITING_RELEASE and g.reason == "no_hand"
	var back_v: Vector2 = hold.call(pinch_at.call(0.62, 0.5), 0.5)
	var still_latched := g.state == S.WAITING_RELEASE and back_v == Vector2.ZERO
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	var new_anchor := g.state == S.ACTIVE and g.joystick.anchor.is_equal_approx(Vector2(0.3 * 640.0 / 480.0, 0.3)) and g.velocity == Vector2.ZERO
	_ok(lost_v == Vector2.ZERO and latched and still_latched and new_anchor,
		"gesture: losing the hand stops; it does not restart until released, a new pinch sets a new centre",
		"%s %s %s %s %s" % [lost_v, latched, still_latched, new_anchor, g.state_name()])

	# two hands
	hold.call(pinch_at.call(0.42, 0.3), 0.1)
	var two: Vector2 = step.call(_hev(0, false, true, 0.5, 0.5, {"hand_count": 2, "reason": "multiple_hands"}))
	_ok(two == Vector2.ZERO and g.state == S.WAITING_RELEASE and g.reason == "multiple_hands", "gesture: two hands stop it", g.state_name())

	# stale events: nothing for longer than stale_ms
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	hold.call(pinch_at.call(0.42, 0.3), 0.05)
	var moving_before := g.velocity.length() > 0.0
	for i in range(12):  # 200 ms without an event
		step.call({})
	var stale_stop := g.state == S.WAITING_RELEASE and g.reason == "stale" and g.velocity == Vector2.ZERO
	_ok(moving_before and stale_stop, "gesture: events older than stale_ms stop it", "%s %s %s" % [moving_before, g.state_name(), g.reason])

	# old / reordered events are dropped and cannot lift a stop
	var dropped0 := g.dropped
	t[0] += 16.0
	var accepted_old := g.on_event(_hev(1, true, false), t[0])  # sequence 1: long gone
	var dup := g.on_event(_hev(seq[0], true, false), t[0])
	g.tick(t[0], dt, "")
	_ok(not accepted_old and not dup and g.dropped == dropped0 + 2 and g.state == S.WAITING_RELEASE,
		"gesture: old and duplicate events are ignored (a stop stays latched)", "%s %s" % [g.dropped, g.state_name()])

	# camera lost
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	step.call(_hev(0, false, false, 0.5, 0.5, {"camera_ok": false, "reason": "camera_lost"}))
	_ok(g.state == S.WAITING_RELEASE and g.reason == "camera_lost", "gesture: a lost camera stops it", g.reason)

	# WebSocket gone and back: a new stream starting at 1 while still pinching does not restart it
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.reset_stream("ws_disconnect")
	var after_drop := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	seq[0] = 0
	var reconnect_v: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.5)
	_ok(after_drop and reconnect_v == Vector2.ZERO and g.state == S.WAITING_RELEASE,
		"gesture: a disconnect stops it; after reconnecting a held pinch does not restart it", "%s %s" % [reconnect_v, g.state_name()])

	# STOP (Space) and the keyboard: latched until a new pinch
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.stop("stop_key")
	var stop_v: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.3)
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	var again: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.2)
	_ok(stop_v == Vector2.ZERO and again.x > 0.0, "gesture: after STOP it needs a release and a new pinch", "%s %s" % [stop_v, again])
	var kb := ControlArbiter.decide(false, false, Vector3(40, 0, 0), Vector3(-20, 0, 0), true)
	var gs := ControlArbiter.decide(false, false, Vector3.ZERO, Vector3(-20, 5, 0), true)
	var halted := ControlArbiter.decide(true, false, Vector3(40, 0, 0), Vector3(-20, 0, 0), true)
	var latched_stop := ControlArbiter.decide(false, true, Vector3.ZERO, Vector3(-20, 0, 0), true)
	var idle := ControlArbiter.decide(false, false, Vector3.ZERO, Vector3(-20, 0, 0), false)
	_ok(kb.source == "keyboard" and kb.v == Vector3(40, 0, 0) and gs.source == "gesture" and halted.v == Vector3.ZERO
		and halted.source == "halt" and latched_stop.v == Vector3.ZERO and idle.v == Vector3.ZERO,
		"arbiter: alarm > STOP > keyboard > gesture, never both", "%s %s %s" % [kb, gs, halted])

	# not ready (e.g. not homed): a pinch does nothing, and it does not start once ready while held
	hold.call(open_hand, 0.05)
	var blocked: Vector2 = hold.call(pinch_at.call(0.3, 0.3), 0.3, "原点復帰（home）してください")
	var blocked_state := g.state == S.WAITING_RELEASE and g.reason == "原点復帰（home）してください"
	var ready_held: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.3)
	var main_script: GDScript = load("res://scripts/game/main.gd")
	var not_homed: String = main_script.real_gesture_gate(true, true, "mock", false, true, false, false)
	var real_off: String = main_script.real_gesture_gate(true, true, "real", false, true, true, false)
	var real_on: String = main_script.real_gesture_gate(true, true, "real", true, true, true, false)
	var no_motors: String = main_script.real_gesture_gate(true, true, "mock", false, false, true, false)
	_ok(blocked == Vector2.ZERO and blocked_state and ready_held == Vector2.ZERO and not_homed.contains("原点復帰")
		and real_off.contains("allow_real_robot") and real_on == "" and no_motors.contains("モーター"),
		"gesture: refused before homing / motors / on the real robot unless allowed; no start while held",
		"%s %s %s | %s | %s | %s" % [blocked, g.state_name(), ready_held, not_homed, real_off, no_motors])

	# gesture mode off
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.enabled = false
	var off_v: Vector2 = hold.call(pinch_at.call(0.5, 0.3), 0.2)
	_ok(off_v == Vector2.ZERO and g.state == S.DISABLED, "gesture: switching the mode off stops it", g.state_name())

	# operating region (ROI) on the game side
	g.enabled = true
	g.roi_enabled = true
	g.roi = Rect2(0.0, 0.0, 0.5, 1.0)
	hold.call(func(): return _hev(0, true, false, 0.8, 0.5), 0.1)
	_ok(not g.detected and g.state == S.WAITING_HAND and g.reason == "outside_roi", "gesture: a hand outside the ROI is ignored", g.reason)
	# where in the view: near an edge while seen, "left the view" when it vanishes from there
	var e1 := GestureControl.edge_of(Vector2(0.95, 0.5), 0.1)
	var e2 := GestureControl.edge_of(Vector2(0.05, 0.02), 0.1)
	var e3 := GestureControl.edge_of(Vector2(0.5, 0.5), 0.1)
	g.roi_enabled = false
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	var mid_ok := g.edge == Vector2.ZERO and not g.left_view
	hold.call(func(): return _hev(0, true, false, 0.95, 0.5), 0.05)
	var near_ok := g.edge == Vector2(1, 0)
	step.call(_hev(0, false, false))
	var out_ok := g.left_view and g.last_seen.is_equal_approx(Vector2(0.95, 0.5))
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	var back_ok := not g.left_view and g.edge == Vector2.ZERO
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	step.call(_hev(0, false, false))
	var middle_loss := not g.left_view  # vanished in the middle: not "out of the view"
	_ok(e1 == Vector2(1, 0) and e2 == Vector2(-1, -1) and e3 == Vector2.ZERO and mid_ok and near_ok and out_ok and back_ok and middle_loss,
		"gesture: knows when the hand is near the frame edge and when it left the view there",
		"%s %s %s | %s %s %s %s %s" % [e1, e2, e3, mid_ok, near_ok, out_ok, back_ok, middle_loss])
	# the HUD ring shows the hand like the (flipped) camera view does
	var gv := GestureControl.new()
	gv.joystick.set_anchor(Vector2(0.5, 0.5))
	gv.detected = true
	gv.hand = Vector2(0.5 + gv.joystick.radius * 0.5, 0.5 - gv.joystick.radius * 0.5)  # right and up in the image
	var plain := GestureHud.view_offset(gv, false, false)
	var turned := GestureHud.view_offset(gv, true, true)
	_ok(plain.is_equal_approx(Vector2(0.5, -0.5)) and turned.is_equal_approx(Vector2(-0.5, 0.5)),
		"gesture HUD: the ring follows the camera view's flips", "%s %s" % [plain, turned])
	_ok(GestureHud.direction_text(Vector2(20, 15)) == "右奥へ移動" and GestureHud.direction_text(Vector2(-20, 0)) == "左へ移動"
		and GestureHud.direction_text(Vector2(0, -20)) == "手前へ移動" and GestureHud.direction_text(Vector2.ZERO) == "",
		"gesture HUD: direction words")

func _test_gesture_with_mock_robot(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.gesture_require_focus = false
	game.set_gesture_enabled(true)
	game.gesture.joystick.smoothing_ms = 0.0
	game.gesture.arm_delay_ms = 0.0  # real-time delays: this loop runs in a few ms
	game.gesture.joystick.invert_x = false  # the config holds the real camera's calibration
	game.gesture.joystick.invert_y = false
	game.gesture.joystick.swap_xy = false
	var start: Vector3 = game.mock.target
	var dt := 1.0 / 60.0
	var seq := [0]  # lambdas capture ints by value
	var feed := func(ev: Dictionary) -> void:
		seq[0] += 1
		ev["sequence"] = seq[0]
		game.gesture.on_event(ev, float(Time.get_ticks_msec()))
		game._handle_input(dt)
	for i in range(6):
		feed.call(_hev(0, true, false, 0.5, 0.5))
	for i in range(15):
		feed.call(_hev(0, true, true, 0.5, 0.5))
	for i in range(30):
		feed.call(_hev(0, true, true, 0.65, 0.5))
	var moved: Vector3 = game.mock.target - start
	var src: String = game.control_source
	var pinch_cue: String = game.sfx.last_cue
	feed.call(_hev(0, true, false, 0.65, 0.5))
	var after_release: Vector3 = game.mock.target
	var release_cue: String = game.sfx.last_cue
	for i in range(10):
		feed.call(_hev(0, true, false, 0.65, 0.5))
	_ok(moved.x > 5.0 and absf(moved.y) < 1e-3 and src == "gesture" and game.mock.target == after_release,
		"gesture + MockRobot: steering right moves the mock target +X; releasing stops it", "%s %s" % [moved, src])
	for i in range(15):
		feed.call(_hev(0, true, true, 0.5, 0.5))
	feed.call(_hev(0, false, false))  # the hand vanishes while steering
	var lost_cue: String = game.sfx.last_cue
	var blips: AudioStreamWAV = game.sfx.cue_stream("pinch")
	var log_: Array[String] = game.sfx.cue_log
	var first_hand := log_.find("hand")
	_ok(first_hand >= 0 and log_.find("pinch") > first_hand and pinch_cue == "pinch" and release_cue == "release" and lost_cue == "lost"
		and blips != null and blips.data.size() > 4000 and game.sfx.cue_stream("hand") != null and game.sfx.cue_stream("release") != null,
		"gesture sound: hand seen, pinch caught, fingers opened, control cut - each its own blip",
		"%s | %s %s %s" % [log_, pinch_cue, release_cue, lost_cue])
	var ov := GestureCameraOverlay.new()
	ov.size = Vector2(320, 240)
	var straight := ov.to_px(Vector2(0.25, 0.5))
	ov.flip_h = true
	var mirrored := ov.to_px(Vector2(0.25, 0.5))
	ov.free()
	_ok(straight == Vector2(80, 120) and mirrored == Vector2(240, 120), "gesture overlay: image coords map onto the camera view (mirrored with it)")
	remove_child(game)
	game.free()
	rs.clear_samples()
