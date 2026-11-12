extends Node
## Headless physics / mapping tests. Run with:
##   godot --headless --path game res://tests/test_runner.tscn
## Exit code 0 when everything passes.

var _fails := 0
var _passes := 0
const StudyClientScript := preload("res://scripts/study/study_client.gd")

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_passes += 1
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", detail)

func _ready() -> void:
	var rs: Node = RobotState
	GameConfig.drop_local()  # this machine's config/local_settings.json (#93) must not change the tests
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
	_test_study_image_encoding()
	_test_hand_joystick()
	_test_gesture_states()
	_test_gesture_z_and_claw()
	_test_gesture_schemes()
	_test_pose_direction_scheme()
	_test_pose_finger_direction()
	_test_pose_thumb_and_claw()
	_test_gesture_z_has_its_own_sound(rs)
	_test_gesture_with_mock_robot(rs)
	_test_error_clears_when_the_machine_recovers(rs)
	_test_claw_steps_on_the_mock(rs)
	_test_vfx_manager()
	_test_vfx_follows_the_game(rs)
	_test_debug_panel_tabs_and_z_buttons(rs)
	_test_study_is_optional(rs)
	_test_homework_watch(rs)
	_test_auto_catch_controls(rs)
	_test_study_worksheets_and_tracker()
	_test_study_mode_mock_story(rs)
	_test_study_mode_failures(rs)
	_test_study_mode_backend_messages(rs)
	_test_title_screen(rs)
	_test_settings(rs)
	_test_calibration_tab(rs)
	print("\n%d passed, %d failed" % [_passes, _fails])
	get_tree().quit(0 if _fails == 0 else 1)

func _make() -> RopeSimulator:
	var s := RopeSimulator.new()
	s.rope_length = 40.0
	s.target_rope_length = 40.0
	s.reset()
	return s

func _test_study_image_encoding() -> void:
	var image := Image.create(2000, 1000, false, Image.FORMAT_RGB8)
	image.fill(Color(0.2, 0.4, 0.8))
	var jpeg: PackedByteArray = StudyClientScript.encode_jpeg(image, 1280, 700000)
	var decoded := Image.new()
	var err := decoded.load_jpg_from_buffer(jpeg)
	var too_small: PackedByteArray = StudyClientScript.encode_jpeg(image, 1280, 8)
	_ok(not jpeg.is_empty() and jpeg.size() <= 700000 and err == OK
		and maxi(decoded.get_width(), decoded.get_height()) <= 1280 and too_small.is_empty(),
		"study: the camera frame is resized and JPEG-capped", "%d %dx%d" % [jpeg.size(), decoded.get_width(), decoded.get_height()])

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
	# typing in a text field (the Study question) is not jogging (#68)
	var te := TextEdit.new()
	var le := LineEdit.new()
	var bt := Button.new()
	_ok(main_script.is_text_entry(te) and main_script.is_text_entry(le), "jog: text fields take the keys")
	_ok(not main_script.is_text_entry(bt) and not main_script.is_text_entry(null), "jog: buttons / no focus do not")
	_ok(main_script.sim_pose(true, false) == "open" and main_script.sim_pose(false, false) == "other",
		"jog: hand-shape keys ignored while typing")
	te.free()
	le.free()
	bt.free()
	# a refused jog is explained as the next thing to press
	var cases := {
		"motors not enabled (send enable_motors first)": "モーター有効",
		"not homed": "home",
		"not_homed": "home",
		"alarm active: abort requested": "アラーム解除",
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

## After an alarm the game leaves ERROR once the machine reports a normal state
## again (clear_alarm -> home), so the UFO's moods (and the telescope) come back.
func _test_error_clears_when_the_machine_recovers(rs: Node) -> void:
	var was_source: String = rs.source
	var was_connected: bool = rs.connected
	rs.source = "websocket"
	rs.connected = true
	GameState.set_state("READY")
	rs.machine_state = "ALARM"
	var in_error := GameState.state == "ERROR"
	rs.machine_state = "UNKNOWN"
	var still := GameState.state == "ERROR"
	rs.machine_state = "HOMING"
	var homing := GameState.state == "HOMING"
	rs.machine_state = "IDLE"
	var ready := GameState.state == "READY"
	_ok(in_error and still and homing and ready, "game state: ERROR after an alarm ends when the machine is back (HOMING -> READY)",
		"%s %s %s %s" % [in_error, still, homing, GameState.state])
	rs.machine_state = "UNKNOWN"
	rs.connected = was_connected
	rs.source = was_source

## Claw test controls: [ / ] and the debug buttons step the claw; arm_zero makes 0 degrees.
func _test_claw_steps_on_the_mock(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.arm_zero()
	game.arm_step(5.0)
	game.arm_step(5.0)
	game.arm_step(-1.0)
	var after_steps: float = rs.arm_deg
	game.arm_zero()
	var zeroed: float = rs.arm_deg
	var key := InputEventKey.new()
	key.keycode = KEY_BRACKETRIGHT
	key.pressed = true
	game._unhandled_input(key)
	var by_key: float = rs.arm_deg
	_ok(is_equal_approx(after_steps, 9.0) and zeroed == 0.0 and is_equal_approx(by_key, game.arm_step_deg) and rs.arm_reference_set,
		"claw: steps add up, arm_zero makes 0, ] steps by the set amount (mock)", "%.1f %.1f %.1f" % [after_steps, zeroed, by_key])
	# record closed / open, then go back and forth between them
	game.arm_goto("open")  # nothing recorded yet: stays
	var unmoved: float = rs.arm_deg
	game.arm_set("closed")
	game.arm_step(30.0)
	game.arm_set("open")
	game.arm_goto("closed")
	var closed_at: float = rs.arm_deg
	var qa := InputEventKey.new()
	qa.keycode = KEY_Q
	qa.pressed = true
	game._unhandled_input(qa)  # Q opens
	_ok(unmoved == by_key and closed_at == by_key and is_equal_approx(rs.arm_deg, by_key + 30.0) and is_equal_approx(rs.arm_span_deg, 30.0),
		"claw: arm_set records closed / open, arm_goto (and Q) turns there (mock)", "%.1f %.1f %.1f %.1f" % [unmoved, closed_at, rs.arm_deg, rs.arm_span_deg])
	qa.keycode = KEY_A
	game._unhandled_input(qa)  # A closes
	_ok(rs.arm_deg == by_key, "claw: Q opens and A closes to the recorded positions (mock)", "%.1f" % rs.arm_deg)
	remove_child(game)
	game.free()
	rs.clear_samples()

## Debug panel: hardware tests in the first tab; a held Z button never outlives the mouse press.
func _test_debug_panel_tabs_and_z_buttons(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var tabs: TabContainer = game.debug_ui._tabs
	var titles := []
	for i in tabs.get_tab_count():
		titles.append(tabs.get_tab_title(i))
	game.ui_jog_z = 1.0  # as if "▲" were held, but no mouse button is down
	var d: Vector3 = game._jog_input()
	var expected_tabs := 7 + (1 if bool(GameConfig.data.study.enabled) else 0) + (1 if bool(GameConfig.data.homework.enabled) else 0)
	var study_matches_config: bool = titles.has("Study") == bool(GameConfig.data.study.enabled)
	_ok(titles[0] == "実機" and titles.size() == expected_tabs and study_matches_config and game.ui_jog_z == 0.0 and d.z == 0.0,
		"debug panel: tabs (hardware first); on-screen Z jog stops once the mouse is up", "%s %.1f %.1f" % [titles, game.ui_jog_z, d.z])
	# backend / serial lines and game lines land in one log; the copy has the state on top
	game.ws._handle({"type": "log", "data": {"line": "[serial] RX JOG servo id=1 disabled test"}})
	game.debug_log.emit("keys: jog vx 0 vy 0 vz 15 -> mock")
	var report: String = game.debug_ui.log_report()
	_ok(report.begins_with("CoreXY UFO debug log") and report.contains("robot: source=") and report.contains("window_focus=")
		and report.contains("[serial] RX JOG servo id=1 disabled test") and report.contains("keys: jog vx 0 vy 0 vz 15"),
		"debug panel: the log collects backend, serial and key lines; the copy starts with the state", report.left(300))
	# a focused text field (the Study question) holds the keys; a click on the game releases it (#68)
	var field := TextEdit.new()
	game.debug_ui.add_child(field)
	field.grab_focus()
	var typing: bool = game.text_entry_focused()
	game._unhandled_input(_mouse_press())
	_ok(typing and not game.text_entry_focused(), "debug panel: typing holds the jog keys until the game is clicked")
	field.queue_free()
	remove_child(game)
	game.free()
	rs.clear_samples()

func _mouse_press() -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	return ev

func _test_study_is_optional(rs: Node) -> void:
	var previous: bool = bool(GameConfig.data.study.enabled)
	GameConfig.data.study.enabled = true
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var titles := []
	for i in game.debug_ui._tabs.get_tab_count():
		titles.append(game.debug_ui._tabs.get_tab_title(i))
	var study_tab: int = titles.find("Study")
	var buffer_ok: bool = game.study.link.outbound_buffer_size >= int(GameConfig.data.study.max_image_bytes) * 2
	RobotState.source = "websocket"
	RobotState.connected = true
	RobotState.machine_state = "READY"
	game.study.link._on_closed()
	var isolated: bool = RobotState.connected and RobotState.machine_state == "READY"
	game.debug_ui._tabs.current_tab = study_tab
	game.study.end_session()
	game.debug_ui.study_panel_visibility_changed(true)
	var reopened: bool = game.study.session_id != "" and game.study.state == "connecting"
	game.study.end_session()
	var labels_ok: bool = StudyClient.provider_label("claude") == "Claude Code" and StudyClient.provider_label("codex") == "Codex" \
		and StudyClient.provider_label("") == "アシスタント"
	_ok(labels_ok, "study: the provider from the backend's hello names who answers")
	var study_tabs := 8 + (1 if bool(GameConfig.data.homework.enabled) else 0)
	_ok(game.study != null and study_tab >= 0 and titles.size() == study_tabs and buffer_ok and isolated and reopened,
		"study: optional client is isolated, sized for images, and restarts on reopen", "%s buffer=%s isolated=%s reopened=%s" % [titles, buffer_ok, isolated, reopened])
	remove_child(game)
	game.free()
	GameConfig.data.study.enabled = previous
	RobotState.source = "mock"
	RobotState.connected = false
	rs.clear_samples()

## Homework watch: optional tab, aux link only, progress / held / errors from the backend's messages.
func _test_homework_watch(rs: Node) -> void:
	_ok(HomeworkClient.format_elapsed(0) == "00:00" and HomeworkClient.format_elapsed(754.9) == "12:34"
		and HomeworkClient.format_elapsed(3723) == "1:02:03", "homework: elapsed time as mm:ss / h:mm:ss")
	var previous: bool = bool(GameConfig.data.homework.enabled)
	GameConfig.data.homework.enabled = true
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var hw: HomeworkClient = game.homework
	var titles := []
	for i in game.debug_ui._tabs.get_tab_count():
		titles.append(game.debug_ui._tabs.get_tab_title(i))
	_ok(hw != null and titles.has("宿題") and hw.link.study_only and hw.interval_s == 10.0,
		"homework: optional tab and its own aux link", str(titles))
	hw.start()
	var started: bool = hw.state == "connecting" and hw.session_id != ""
	hw._on_message({"type": "hello", "data": {"homework": true}})
	hw._on_message({"type": "homework_status", "data": {"state": "running"}})
	var running: bool = hw.state == "running"
	hw._waiting = true
	hw._on_message({"type": "homework_progress", "data": {"progress_pct": 40.0, "smoothed_pct": 30.0, "held": false,
		"held_reason": "", "count": 2, "skipped": 1, "cost_usd": 0.0007}})
	var shown: bool = is_equal_approx(hw.progress_pct, 30.0) and is_equal_approx(hw.last_pct, 40.0) and hw.count == 2 \
		and not hw._waiting and hw.history.size() == 1
	hw._on_message({"type": "homework_progress", "data": {"progress_pct": 100.0, "smoothed_pct": null, "held": true,
		"held_reason": "occluded", "count": 3}})
	var held: bool = is_equal_approx(hw.progress_pct, 30.0) and hw.status_text.contains("隠れている")
	game.debug_ui._update_homework()
	var ui_ok: bool = game.debug_ui._hw_elapsed.text.contains("30%") and is_equal_approx(game.debug_ui._hw_bar.value, 30.0)
	hw._on_message({"type": "homework_error", "data": {"code": "auth", "message": "x", "stopped": true}})
	var stopped: bool = hw.state == "stopped" and hw.status_text.contains("止めました") and is_equal_approx(hw.progress_pct, 30.0)
	hw.start()
	hw._on_message({"type": "homework_error", "data": {"code": "config", "message": "Jev の鍵が未設定です"}})
	var no_key: bool = hw.state == "error" and hw.status_text.contains("未設定")
	_ok(started and running and shown and held and ui_ok and stopped and no_key,
		"homework: start, progress, held keeps the value, errors stop it", "%s %s %s %s %s %s %s" % [started, running, shown, held, ui_ok, stopped, no_key])
	RobotState.source = "websocket"
	RobotState.connected = true
	hw.link._on_closed()
	_ok(RobotState.connected, "homework: its link never touches RobotState")
	# advice (#76): side-by-side image, stall notice, streamed advice, HOLD -> capture + release, FAULT
	var a := Image.create(40, 30, false, Image.FORMAT_RGB8)
	a.fill(Color.RED)
	var b := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	b.fill(Color.BLUE)
	var both := HomeworkClient.compose_side_by_side([a, b] as Array[Image], 60)
	_ok(both.get_width() == 80 + 60 and both.get_height() == 60 and both.get_pixel(10, 10).r > 0.9
		and both.get_pixel(100, 10).b > 0.9, "homework: overview and close-up side by side at one height", "%dx%d" % [both.get_width(), both.get_height()])
	hw.start()
	hw._on_message({"type": "homework_status", "data": {"state": "running"}})
	hw._on_message({"type": "homework_progress", "data": {"progress_pct": 20.0, "smoothed_pct": 20.0, "held_reason": "",
		"count": 5, "stalled": true, "stalled_for_s": 200.0}})
	game.debug_ui._update_homework()
	var notice: bool = hw.stalled and game.debug_ui._hw_stall.text.contains("3 分ほど進んでいません")
	hw._on_message({"type": "homework_status", "data": {"state": "advising"}})
	hw._on_message({"type": "homework_advice_delta", "data": {"text": "3番の"}})
	hw._on_message({"type": "homework_advice_delta", "data": {"text": "問題で止まっています"}})
	hw._on_message({"type": "homework_advice_result", "data": {}})
	game.debug_ui._update_homework()
	var advice_ok: bool = hw.advice_state == "done" and game.debug_ui._hw_advice.text == "3番の問題で止まっています"
	hw.advice_state = "approaching"
	hw._captured = false
	hw._on_robot_message({"type": "homework_approach", "data": {"active": true, "phase": "HOLD", "spot": {"x": 1, "y": 2, "z": 3}}})
	var hold_ok: bool = hw._captured and hw.advice_state == "error" and hw.advice_status.contains("カメラの映像がない")  # headless: no camera
	game.debug_ui._update_homework()
	var spot_ok: bool = game.debug_ui._hw_spot.text.contains("X 1.0 / Y 2.0 / Z 3.0")
	hw.advice_state = "approaching"
	hw._on_robot_message({"type": "robot_state", "data": {"homework_approach": {"active": false, "phase": "FAULT", "error": "emergency stop (stop)"}}})
	var fault_ok: bool = hw.advice_state == "error" and hw.advice_status.contains("emergency stop")
	_ok(notice and advice_ok and hold_ok and spot_ok and fault_ok, "homework: stall notice, advice, capture at HOLD, fault",
		"%s %s %s %s %s" % [notice, advice_ok, hold_ok, spot_ok, fault_ok])
	hw.approach_and_advise()  # the game's own mock (no backend robot link): refused with a reason
	_ok(hw.advice_status.contains("バックエンド"), "homework: approaching needs the backend's robot link")
	_test_homework_camera_map(game, hw)
	_test_homework_helper(game, hw)
	hw.stop()
	remove_child(game)
	game.free()
	GameConfig.data.homework.enabled = previous
	RobotState.source = "mock"
	RobotState.connected = false
	rs.clear_samples()

## Stage 2 (#78): the backend's camera calibration in the panel, the clickable overview,
## the arm camera's aim marker from h_inv, and a look's states.
func _test_homework_camera_map(game: Node, hw: HomeworkClient) -> void:
	# homography rows: XY mm -> image (u, v); here u = x / 400, v = y / 300
	var h_inv := [[1.0 / 400.0, 0.0, 0.0], [0.0, 1.0 / 300.0, 0.0], [0.0, 0.0, 1.0]]
	var mapped = HomeworkClient.map_point(h_inv, 200.0, 75.0)
	var persp = HomeworkClient.map_point([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.5, 0.0, 1.0]], 2.0, 4.0)
	var map_ok: bool = mapped is Vector2 and mapped.is_equal_approx(Vector2(0.5, 0.25)) \
		and persp is Vector2 and persp.is_equal_approx(Vector2(1.0, 2.0))
	var r := OverviewPicker.fit_rect(Vector2(400, 400), Vector2(1280, 720))
	var fit_ok := r.position.is_equal_approx(Vector2(0, 87.5)) and r.size.is_equal_approx(Vector2(400, 225))
	_ok(map_ok and fit_ok, "camera map: homography point and the picker's drawn rect", "%s %s" % [mapped, r])
	# the marks are drawn on a child without the camera shader (it would recolour them)
	var picker: OverviewPicker = game.debug_ui._hw_preview
	_ok(picker.material != null and picker.overlay.get_parent() == picker and picker.overlay.material == null
		and not picker.overlay.use_parent_material, "camera map: marks drawn outside the camera shader")
	hw._on_robot_message({"type": "ack", "data": {"command": "camera_map_add", "usable": true, "problem": "",
		"points": [{"u": 0.1, "v": 0.2, "x": 40.0, "y": 60.0}], "rms_mm": 0.8, "max_mm": 1.4, "h_inv": h_inv}})
	RobotState.x_mm = 200.0
	RobotState.y_mm = 75.0
	var aim = hw.arm_view_uv()
	game.debug_ui._update_homework()
	var ui_ok: bool = game.debug_ui._hw_calib.text.contains("最大 1.4 mm") and game.debug_ui._hw_calib.text.contains("点を記録しました")
	hw._on_robot_message({"type": "nack", "data": {"command": "camera_map_add", "reason": "not homed"}})
	var nack_ok := hw.calib_status.contains("not homed") and hw.calibration_usable()
	_ok(aim is Vector2 and aim.is_equal_approx(Vector2(0.5, 0.25)) and ui_ok and nack_ok,
		"camera map: status from the backend, panel summary, aim marker, refusal shown", "%s %s %s" % [aim, ui_ok, nack_ok])
	# a look: stale IDLE / FAULT from robot_state must not end it before it moves
	hw.looking = true
	hw._look_moving = false
	hw._on_robot_message({"type": "robot_state", "data": {"homework_approach": {"active": false, "phase": "FAULT", "error": "old"}}})
	var stale_ok := hw.looking
	hw._on_robot_message({"type": "homework_approach", "data": {"active": true, "phase": "MOVE_XY"}})
	hw._on_robot_message({"type": "homework_approach", "data": {"active": true, "phase": "HOLD"}})
	var hold_ok := hw.looking and hw.calib_status.contains("見ています")
	hw._on_robot_message({"type": "homework_approach", "data": {"active": false, "phase": "IDLE"}})
	var back_ok := not hw.looking and hw.calib_status == "戻りました"
	hw.look_at(Vector2(0.5, 0.5))  # no backend robot link in the tests
	var refused_ok := not hw.looking and hw.calib_status.contains("バックエンド")
	_ok(stale_ok and hold_ok and back_ok and refused_ok, "camera map: look states (stale status ignored, hold, back, refused offline)",
		"%s %s %s %s" % [stale_ok, hold_ok, back_ok, refused_ok])

## Stage 3 (#79): the offer once per stall, the keys and the thumbs-up, the locate
## result (moves only when usable), the voice as a WAV and its credit.
func _test_homework_helper(game: Node, hw: HomeworkClient) -> void:
	# a 16-bit mono PCM WAV with 100 samples
	var wav := PackedByteArray()
	wav.append_array("RIFF".to_ascii_buffer())
	wav.resize(44)
	wav.encode_u32(4, 36 + 200)
	var fmt := "WAVEfmt ".to_ascii_buffer()
	for i in fmt.size():
		wav[8 + i] = fmt[i]
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, 1)
	wav.encode_u32(24, 24000)
	wav.encode_u32(28, 48000)
	wav.encode_u16(32, 2)
	wav.encode_u16(34, 16)
	var data := "data".to_ascii_buffer()
	for i in data.size():
		wav[36 + i] = data[i]
	wav.encode_u32(40, 200)
	wav.resize(44 + 200)
	var stream := HomeworkClient.wav_stream(wav)
	_ok(stream != null and stream.mix_rate == 24000 and HomeworkClient.wav_stream("not a wav at all, really not one".to_ascii_buffer()) == null,
		"helper: a WAV from the backend becomes a stream, anything else does not")
	hw._on_message({"type": "homework_speech", "data": {"text": "手伝おうか？", "engine": "voicevox",
		"credit": "VOICEVOX:ずんだもん", "wav_base64": Marshalls.raw_to_base64(wav)}})
	game.debug_ui._update_homework()
	_ok(hw.player.stream != null and hw.speech_credit == "VOICEVOX:ずんだもん"
		and game.debug_ui._hw_helper.text.contains("VOICEVOX:ずんだもん"), "helper: the voice plays and its credit is shown",
		game.debug_ui._hw_helper.text)
	# the offer: once per stall, again only after offer_repeat_s; spoken (here: no speech -> the reason)
	hw.state = "running"
	hw.stalled = false
	hw._offer_until_ms = 0  # the stage-1 test's stall already offered help
	hw._on_message({"type": "homework_progress", "data": {"smoothed_pct": 20.0, "held_reason": "", "stalled": false}})
	var calm := not hw.offer_pending(Time.get_ticks_msec())
	hw.speech_available = false
	hw._on_message({"type": "homework_progress", "data": {"smoothed_pct": 20.0, "held_reason": "", "stalled": true, "stalled_for_s": 200.0}})
	var offered := hw.offer_pending(Time.get_ticks_msec()) and hw.locate_status.begins_with(hw.offer_text) \
		and hw.speech_status.contains("声は使えない")
	var first := hw._last_offer_ms
	hw._on_message({"type": "homework_progress", "data": {"smoothed_pct": 20.0, "held_reason": "", "stalled": true, "stalled_for_s": 210.0}})
	var once := hw._last_offer_ms == first
	_ok(calm and offered and once, "helper: offers help once when the watch reports a stall", "%s %s %s" % [calm, offered, once])
	# the thumbs-up: held thumb_hold_ms while the offer is pending; refused here (no assistant), with the reason
	var t := float(Time.get_ticks_msec())
	hw.thumb_tick(true, t)
	hw.thumb_tick(true, t + hw.thumb_hold_ms * 0.5)
	var waiting := hw.offer_pending(t) and hw.locate_state != "error"
	hw.thumb_tick(true, t + hw.thumb_hold_ms + 1.0)
	var fired := not hw.offer_pending(t) and hw.locate_state == "error" and hw.locate_status.contains("アシスタント")
	hw.thumb_tick(false, t + 2000.0)
	hw.offer_help()
	hw.thumb_tick(false, t)
	hw.locate_state = ""
	var t2 := float(Time.get_ticks_msec())
	hw._offer_until_ms = 0
	hw.thumb_tick(true, t2)  # up before the offer: spent until put down
	hw._offer_until_ms = int(t2) + 60000
	hw.thumb_tick(true, t2 + hw.thumb_hold_ms * 3.0)
	var stale_thumb := hw.locate_state == ""
	_ok(waiting and fired and stale_thumb, "helper: a held thumbs-up answers the offer, an old one does not",
		"%s %s %s" % [waiting, fired, stale_thumb])
	# keys from config; the game's own keys win (only the default branch reaches the helper)
	var keys_before := hw.focus_keys.duplicate()
	hw.configure_helper({"keys": {"stuck": "J", "next": "bogus"}})
	var keys_ok: bool = hw.focus_keys.stuck == KEY_J and hw.focus_keys.next == KEY_N and hw.handle_key(KEY_J) \
		and not hw.handle_key(KEY_Z) and hw.locate_status.contains("見に行けません")
	hw.focus_keys = keys_before
	_ok(keys_ok and hw.key_name("stuck") == "Y" and hw.key_name("next") == "N", "helper: Y / N by default, keys from config")
	# results count only for the pending request; stop / disconnect cancel it (no motion afterwards)
	hw.locate_state = "locating"
	hw._locate_rid = "hwl-old"
	hw.cancel_locate("Space で止めた")
	hw.calib_status = ""
	hw._on_message({"type": "homework_locate_result", "request_id": "hwl-old", "data": {"usable": true, "u": 0.4, "v": 0.6}})
	var cancelled_ok := hw.locate_state == "error" and hw.calib_status == "" and hw.locate_status.contains("Space")
	hw._locate_rid = "hwl-2"
	hw.locate_state = "locating"
	hw._on_message({"type": "homework_locate_result", "request_id": "hwl-1", "data": {"usable": true, "u": 0.4, "v": 0.6}})
	var other_ok := hw.locate_state == "locating" and hw.calib_status == ""
	hw._on_disconnected()
	var dropped_ok := hw.locate_state == "error" and hw._locate_rid == "" and hw.locate_status.contains("接続が切れた")
	# a refusal of the locate itself (generic homework_error with its request_id) ends it, not the watch
	hw._locate_rid = "hwl-3"
	hw.locate_state = "locating"
	var errors_before := hw.errors
	hw._on_message({"type": "homework_error", "request_id": "hwl-3", "data": {"code": "invalid_request",
		"message": "a problem is already being located"}})
	dropped_ok = dropped_ok and hw.locate_state == "error" and hw._locate_rid == "" and hw.errors == errors_before \
		and hw.locate_status.contains("already")
	game.debug_ui._stop()
	dropped_ok = dropped_ok and hw.locate_status.contains("STOP") == false  # nothing pending: status kept
	hw.locate_state = "locating"
	hw._locate_rid = "hwl-4"
	game.debug_ui._stop()
	dropped_ok = dropped_ok and hw._locate_rid == "" and hw.locate_status.contains("STOP")
	_ok(cancelled_ok and other_ok and dropped_ok, "helper: a stop or a lost link cancels the locate; other results are ignored",
		"%s %s %s" % [cancelled_ok, other_ok, dropped_ok])
	# a locate result: not usable -> no motion, said; usable -> the look (refused here: no backend robot link)
	hw._locate_rid = "L1"
	hw._on_message({"type": "homework_locate_result", "request_id": "L1", "data": {"kind": "stuck", "problem": "(3) 4×12", "usable": false,
		"verified": false, "reason": "Claude と Jev の解答欄の位置が合いませんでした"}})
	var unsure_ok := hw.locate_state == "unsure" and hw.locate_status.contains("動かしません") and not hw.looking
	hw.calib_status = ""
	hw._locate_rid = "L2"
	hw._on_message({"type": "homework_locate_result", "request_id": "L2", "data": {"kind": "next", "problem": "(4)", "usable": true,
		"verified": true, "u": 0.4, "v": 0.6}})
	var go_ok := hw.locate_state == "done" and hw.locate_status.contains("(4)") and hw.calib_status.contains("バックエンド")
	hw._locate_rid = "L3"
	hw._on_message({"type": "homework_locate_error", "request_id": "L3", "data": {"code": "not_found", "message": "見えない"}})
	var err_ok := hw.locate_state == "error" and hw.locate_status.contains("見えない")
	_ok(unsure_ok and go_ok and err_ok, "helper: locate results (unsure stays put, usable looks, errors shown)",
		"%s %s %s" % [unsure_ok, go_ok, err_ok])

## pixelfx VFX: every catalog sheet loads with its frames, timing, loop and pivot;
## spawn_fx honours the options; one-shots free themselves; off = nothing spawns.
func _test_vfx_manager() -> void:
	var bad: Array[String] = []
	for id in VFXManager.ids():
		var m := VFXManager.meta(id)
		var sf := VFXManager._load(id, bool(m.get("loop", false)))
		if m.is_empty() or sf == null or sf.get_frame_count("default") != int(m.frames) \
				or not is_equal_approx(sf.get_animation_speed("default"), float(m.fps)) \
				or not is_equal_approx(sf.get_frame_duration("default", 0), 1.0):
			bad.append(id)
	_ok(VFXManager.ids().size() >= 9 and bad.is_empty(), "vfx: every catalog sheet loads (frames, fps, per-frame time)", str(bad))
	var holder := Node2D.new()
	add_child(holder)
	var was_layer = VFXManager.layer if is_instance_valid(VFXManager.layer) else null
	VFXManager.layer = holder
	var m := VFXManager.meta("grab_burst")
	var s := VFXManager.spawn_fx("grab_burst", Vector2(100, 200), {"scale": 3.0, "speed": 2.0, "alpha": 0.5, "layer": "back"})
	var pivot_ok := s != null and s.offset == Vector2(m.frameSize[0], m.frameSize[1]) * 0.5 - Vector2(m.pivot[0], m.pivot[1])
	var opts_ok := s != null and s.scale == Vector2(3, 3) and s.speed_scale == 2.0 and is_equal_approx(s.modulate.a, 0.5) \
		and s.z_index == VFXManager.Z_BACK and s.position == Vector2(100, 200) and s.get_parent() == holder
	var frees := s != null and s.animation_finished.is_connected(s.queue_free) and not s.sprite_frames.get_animation_loop("default")
	var loop := VFXManager.spawn_fx("grab_burst", Vector2.ZERO, {"loop": true})
	var loops := loop != null and loop.sprite_frames.get_animation_loop("default") and not loop.animation_finished.is_connected(loop.queue_free)
	var target := Node2D.new()
	holder.add_child(target)
	target.position = Vector2(300, 50)
	var f := VFXManager.spawn_fx("idle_glow", Vector2.ZERO, {"follow": target, "offset": Vector2(0, 10)})
	target.position = Vector2(320, 60)
	f._process(0.016)
	var follows := f != null and f.global_position == Vector2(320, 70)
	var count := VFXManager.active_count()
	VFXManager.stop_all()
	var stopped := VFXManager.active_count() == 0
	VFXManager.enabled = false
	var off := VFXManager.spawn_fx("grab_burst", Vector2.ZERO) == null
	VFXManager.enabled = true
	var unknown := VFXManager.spawn_fx("no_such_fx", Vector2.ZERO) == null
	_ok(pivot_ok and opts_ok and frees and loops and follows and count == 3 and stopped and off and unknown,
		"vfx: spawn_fx options (pivot, scale, speed, alpha, layer, loop, follow), auto free, stop_all, off",
		"%s %s %s %s %s %d %s %s %s" % [pivot_ok, opts_ok, frees, loops, follows, count, stopped, off, unknown])
	VFXManager.layer = was_layer
	remove_child(holder)
	holder.free()

## The director plays the moments from GameState, loops one at a time, one-shots
## not repeated by a duplicate event, success only from the result event.
func _test_vfx_follows_the_game(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var gs := GameState
	var was_follow := gs.follow_robot
	gs.follow_robot = false
	var log: Array[String] = VFXManager.spawned_log
	var since := func(n: int) -> Array: return log.slice(n)
	gs.set_state("DISCONNECTED")
	var n := log.size()
	gs.set_state("READY")
	var start: Array = since.call(n)
	n = log.size()
	gs.set_state("MOVING")
	gs.set_state("READY")
	gs.set_state("MOVING")
	var loops := VFXManager.active_count()
	var moving: Array = since.call(n)
	n = log.size()
	gs.post_event("claw_closed")
	gs.post_event("claw_closed")  # a duplicate (slow link): one burst
	var grabs: Array = since.call(n)
	n = log.size()
	gs.post_event("result_success")
	var win: Array = since.call(n)
	n = log.size()
	gs.set_state("READY")
	gs.post_event("result_failure")
	var lose: Array = since.call(n)
	_ok(start.has("start_countdown") and start.has("start_energy") and start.has("idle_glow")
		and moving.count("idle_glow") == 1 and not moving.has("move_sparkle") and grabs == ["grab_burst"]
		and win.has("success_confetti") and win.has("success_sparkle") and not win.has("fail_poof")
		and lose.has("fail_poof") and lose.has("end_fade") and not lose.has("success_confetti"),
		"vfx: game moments -> effects (start, loops, grab once, success / failure from the result only)",
		"%s | %s | %s | %s | %s" % [start, moving, grabs, win, lose])
	# loops are one slot: the moving state left the idle loop stopped
	_ok(loops <= 3, "vfx: state loops replace each other instead of stacking", "%d active" % loops)
	# "stop all" (debug tab) frees the running loop; the next state still gets its effects
	gs.set_state("READY")  # the idle loop runs
	var had_loop: bool = is_instance_valid(game.vfx._loop)
	VFXManager.stop_all()
	await_free_now(game)
	n = log.size()
	gs.set_state("LOWERING")
	_ok(had_loop and since.call(n).has("lower_charge"), "vfx: after stop all, the next state's loop still starts", "%s %s" % [had_loop, since.call(n)])
	VFXManager.enabled = false
	n = log.size()
	gs.post_event("result_success")
	_ok(log.size() == n, "vfx: off = no effects, the game goes on", str(since.call(n)))
	VFXManager.enabled = true
	gs.follow_robot = was_follow
	gs.set_state("DISCONNECTED")
	remove_child(game)
	game.free()
	VFXManager.stop_all()
	rs.clear_samples()

## Free what queue_free() queued under `n` now (tests run in one frame).
func await_free_now(n: Node) -> void:
	for c in n.get_children():
		if c.is_queued_for_deletion():
			c.free()

## A palm-down pinch steers Z (up on the shown view = arm up); a held fist /
## peace sign asks for the claw once per pose, never while the robot is gated.
func _test_gesture_z_and_claw() -> void:
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "joystick": {"smoothing_ms": 0.0, "max_speed_z": 15.0}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(ev: Dictionary, gate := "") -> void:
		t[0] += 1000.0 / 60.0
		seq[0] += 1
		ev["sequence"] = seq[0]
		g.on_event(ev, t[0])
		g.tick(t[0], 1.0 / 60.0, gate)
	var mid := func(y: float): return _hev(0, true, true, 0.5, y, {"pinch_finger": "middle", "pose": "open", "palm": "down"})
	var open_hand := func(pose: String): return _hev(0, true, false, 0.5, 0.5, {"pose": pose})
	for i in 6:
		step.call(open_hand.call("open"))
	for i in 6:
		step.call(mid.call(0.5))
	for i in 10:
		step.call(mid.call(0.3))  # hand up in the image
	var up := g.mode == "z" and g.velocity_z > 10.0 and g.velocity == Vector2.ZERO
	g.joystick.view_flip_v = true  # the view is shown upside down: same hand motion = down
	for i in 10:
		step.call(mid.call(0.3))
	var flipped := g.velocity_z < -10.0
	g.joystick.view_flip_v = false
	step.call(open_hand.call("open"))
	var stopped := g.velocity_z == 0.0 and g.state == GestureControl.State.HAND_DETECTED
	_ok(up and flipped and stopped, "gesture: a palm-down pinch steers Z only; follows the shown view; release stops",
		"%s %s %s %.1f %s" % [up, flipped, stopped, g.velocity_z, g.state_name()])

	for i in 20:  # 0.33 s of fist: not yet
		step.call(open_hand.call("fist"))
	var early := claws.is_empty()
	for i in 20:
		step.call(open_hand.call("fist"))
	var once := claws == ["closed"]
	for i in 60:
		step.call(open_hand.call("fist"))  # still the same fist: no repeat
	for i in 40:
		step.call(open_hand.call("peace"))
	var both := claws == ["closed", "open"]
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 40:
		step.call(open_hand.call("fist"), "モーターを有効にしてください")  # gated: nothing
	var gated := claws.size() == 2
	_ok(early and once and both and gated, "gesture: fist 0.5 s closes, peace opens, once per pose, not while gated",
		"%s %s %s %s %s" % [early, once, both, gated, claws])
	# Space while a fist builds up: no claw until the hand changes shape
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 10:
		step.call(open_hand.call("fist"))
	g.stop("stop_key")
	for i in 60:
		step.call(open_hand.call("fist"))
	var held_after_stop := claws.size() == 2
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 40:
		step.call(open_hand.call("fist"))
	_ok(held_after_stop and claws.size() == 3, "gesture: a stop latches a claw pose being held; a new fist works again", str(claws))

## The safety frame runs any GestureScheme: the scheme decides the sign, the
## velocity and the claw poses; the frame keeps the latch and the switch stop.
func _test_gesture_schemes() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pinch_joystick", "joystick": {"smoothing_ms": 0.0}})
	var default_ok := g.scheme.id() == PinchJoystickScheme.ID and GestureControl.SCHEME_IDS.has(PinchJoystickScheme.ID)
	var unknown_kept := not g.set_scheme("no_such_scheme") and g.scheme.id() == PinchJoystickScheme.ID
	_ok(default_ok and unknown_kept, "gesture scheme: the pinch joystick by default; an unknown name keeps the current one",
		"%s %s" % [default_ok, unknown_kept])

	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String) -> void:
		t[0] += 1000.0 / 60.0
		seq[0] += 1
		g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose}), t[0])
		g.tick(t[0], 1.0 / 60.0, "")
	# the pinch joystick steering, then switched to a scheme of the test's own
	for i in 3:
		step.call("open")
	for i in 3:
		g.on_event(_hev(seq[0] + 1, true, true, 0.5, 0.5, {"pose": "open"}), t[0])
		seq[0] += 1
		g.tick(t[0], 1.0 / 60.0, "")
	var was_active := g.is_active()
	var same := g.scheme
	g.configure({"scheme": "pinch_joystick"})  # the same scheme again: settings only
	var reselected := g.set_scheme(PinchJoystickScheme.ID) and g.scheme == same
	g.on_event(_hev(seq[0] + 1, true, true, 0.7, 0.5, {"pose": "open"}), t[0])
	seq[0] += 1
	g.tick(t[0], 1.0 / 60.0, "")
	_ok(reselected and g.is_active() and g.velocity.length() > 1.0,
		"gesture scheme: choosing the current scheme again keeps the steer going", "%s %s %s" % [reselected, g.state_name(), g.velocity])
	var fake := _PoseScheme.new()
	g.use_scheme(fake)
	var switched_stop := g.state == S.WAITING_RELEASE and g.reason == "scheme_changed" and g.velocity == Vector2.ZERO
	_ok(was_active and switched_stop, "gesture scheme: switching while steering is a forced stop", "%s %s %s" % [was_active, g.state_name(), g.reason])

	for i in 5:
		step.call("open")  # the new sign held across the switch: latched
	var latched := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other")
	for i in 3:
		step.call("open")
	var steers := g.is_active() and g.velocity == Vector2(12.0, 0.0) and g.velocity_z == 0.0
	step.call("peace")  # another sign: let go first, never straight into the reverse
	var let_go := g.state == S.HAND_DETECTED and g.velocity == Vector2.ZERO
	for i in 3:
		step.call("peace")  # ARMED, ACTIVE, then the velocity
	var reverse := g.is_active() and g.velocity == Vector2(-12.0, 0.0)
	_ok(latched and steers and let_go and reverse,
		"gesture scheme: a scheme's own sign arms the frame; latched after a stop; another sign lets go before reversing",
		"%s %s %s %s %s" % [latched, steers, let_go, reverse, g.velocity])

	for i in 3:
		step.call("other")
	for i in 60:
		step.call("fist")  # not a claw pose of this scheme
	_ok(claws.is_empty() and g.claw_pose == "", "gesture scheme: only the scheme's claw poses move the claw", str(claws))

## The hand-shape scheme: パー / チョキ move the crane a set way, through the safety frame.
func _test_pose_direction_scheme() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"schemes": {"pose_direction": {"directions": {"open": [1, 0, 0], "peace": [-1, 0, 0]}, "speed_mm_s": 20.0,
			"pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0, "claw": {"fist": "closed", "open": "open"}}}})
	var ps := g.scheme as PoseDirectionScheme
	_ok(ps != null and ps.speed_mm_s == 20.0 and ps.claw_poses() == {"fist": "closed"} and ps.mapping_text() == "パー=右 チョキ=左 グー=爪閉",
		"pose scheme: chosen by config with its settings; a shape used for a direction never moves the claw",
		"%s %s" % [ps.claw_poses() if ps else null, ps.mapping_text() if ps else ""])
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String, n := 1) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	step.call("other", 3)
	step.call("open", 3)  # 50 ms: passing through a shape moves nothing
	var passing := g.state == S.HAND_DETECTED and g.velocity == Vector2.ZERO
	step.call("other", 10)
	step.call("open", 10)  # held past pose_confirm_ms
	var right := g.is_active() and g.velocity == Vector2(20.0, 0.0) and g.velocity_z == 0.0
	_ok(passing and right, "pose scheme: パー held = +X at the set speed; a passing shape does nothing", "%s %s %s" % [passing, g.state_name(), g.velocity])

	step.call("other", 2)  # a flicker shorter than pose_release_ms
	var kept := g.is_active() and g.velocity == Vector2(20.0, 0.0)
	step.call("peace", 1)
	step.call("open", 1)
	kept = kept and g.is_active()
	_ok(kept, "pose scheme: a short flicker of the shape does not stop it", g.state_name())

	var states: Array[int] = []
	var rec := func(_f, to, _w): states.append(to)
	g.state_changed.connect(rec)
	step.call("peace", 20)
	g.state_changed.disconnect(rec)
	var left := g.is_active() and g.velocity == Vector2(-20.0, 0.0)
	_ok(left and states.has(S.HAND_DETECTED) and states.find(S.HAND_DETECTED) < states.find(S.ACTIVE),
		"pose scheme: チョキ = -X; changing shape stops first, then arms the new way", "%s %s" % [states, g.velocity])

	g.stop("stop_key")
	step.call("peace", 30)  # still チョキ: latched
	var latched := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other", 2)  # a flicker is not letting go
	step.call("peace", 30)
	latched = latched and g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other", 10)  # gone for longer than pose_release_ms
	var lifted := g.state == S.HAND_DETECTED
	step.call("peace", 12)
	_ok(latched and lifted and g.is_active(), "pose scheme: after a stop the same shape does not restart it; letting go does",
		"%s %s %s" % [latched, lifted, g.state_name()])

	# after a stop, going straight to another direction shape also lets go (held, not a misread)
	g.stop("stop_key")
	step.call("peace", 5)
	step.call("open", 1)  # a one-frame misread of another shape
	step.call("peace", 5)
	var misread_kept := g.state == S.WAITING_RELEASE
	step.call("open", 30)
	_ok(misread_kept and g.is_active() and g.velocity == Vector2(20.0, 0.0),
		"pose scheme: after a stop, holding another direction shape lets go and moves that way; a one-frame misread does not",
		"%s %s %s" % [misread_kept, g.state_name(), g.velocity])

	step.call("other", 10)
	step.call("fist", 40)
	_ok(claws == ["closed"], "pose scheme: the claw shape still works (fist = close)", str(claws))

	# switching the scheme while a shape is held: latched even though the new scheme has not confirmed it yet
	g.set_scheme(PinchJoystickScheme.ID)
	step.call("other", 3)
	g.set_scheme(PoseDirectionScheme.ID)
	step.call("open", 30)
	var switch_latched := g.state != S.ACTIVE and g.velocity == Vector2.ZERO
	g.use_scheme(PinchJoystickScheme.new())
	step.call("open", 3)
	var ps2 := PoseDirectionScheme.new()
	ps2.configure({"directions": {"open": [1, 0, 0]}, "pose_confirm_ms": 0.0, "smoothing_ms": 0.0})
	g.use_scheme(ps2)  # a stop while パー is in view
	step.call("open", 30)
	_ok(switch_latched and g.state == S.WAITING_RELEASE and g.reason == "scheme_changed",
		"pose scheme: a shape held across a scheme switch does not move", "%s %s %s" % [switch_latched, g.state_name(), g.reason])
	var main_script: GDScript = load("res://scripts/game/main.gd")
	_ok(main_script.sim_pose(true) == "open" and main_script.sim_pose(false) == "other",
		"pose scheme: the mouse simulation shows no shape unless a key says so (an open hand for the pinch stick)")

## Pointing: the crane goes where the index finger points (any angle), through
## the camera calibration of the stick.
func _test_pose_finger_direction() -> void:
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"joystick": {"invert_x": false, "invert_y": false, "swap_xy": false},
		"schemes": {"pose_direction": {"speed_mm_s": 20.0, "pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0}}})
	var ps := g.scheme as PoseDirectionScheme
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var step := func(pose: String, dir := Vector2.ZERO, n := 1, length := 1.0) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose, "point_dx": dir.x, "point_dy": dir.y, "point_len": length}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	var near := func(a: Vector2, b: Vector2) -> bool: return a.distance_to(b) < 0.05
	step.call("other", Vector2.ZERO, 3)
	step.call("point", Vector2(1, 0), 12)  # pointing right in the image
	var right: Vector2 = g.velocity
	step.call("point", Vector2(0, -1), 1)  # turned to point up in the image: away from the camera's bottom = +Y
	var away: Vector2 = g.velocity
	var d := Vector2(1, -1).normalized()
	step.call("point", d, 1)  # a diagonal
	var diag: Vector2 = g.velocity
	var still_active := g.is_active()
	_ok(near.call(right, Vector2(20, 0)) and near.call(away, Vector2(0, 20)) and near.call(diag, Vector2(14.142, 14.142)) and still_active,
		"pose scheme: pointing moves the crane where the finger points, diagonals too; turning the finger turns it",
		"%s %s %s %s" % [right, away, diag, still_active])
	step.call("point", Vector2(1, 0), 1, 0.2)  # the finger points at the camera: too short to tell
	var unsure: Vector2 = g.velocity
	g.joystick.invert_x = true  # the camera's calibration applies to the finger as to the stick
	step.call("point", Vector2(1, 0), 1)
	var inverted: Vector2 = g.velocity
	g.joystick.invert_x = false
	ps.point_snap_deg = 45.0
	step.call("point", Vector2.from_angle(deg_to_rad(-30.0)), 1)  # 30 deg up from right: snaps to 45
	var snapped: Vector2 = g.velocity
	_ok(unsure == Vector2.ZERO and g.is_active() and near.call(inverted, Vector2(-20, 0)) and near.call(snapped, Vector2(14.142, 14.142)),
		"pose scheme: no motion while the finger points at the camera; follows invert_x; can snap to 8 ways",
		"%s %s %s" % [unsure, inverted, snapped])
	_ok(ps.mapping_text() == "指差し=指の向き いいね↑=上げる いいね↓=下げる パー=爪開 チョキ=爪閉",
		"pose scheme: the default mapping (point, thumbs-up up / down, claw on パー / チョキ)", ps.mapping_text())

## The default hand-shape mapping: a thumbs-up raises / lowers the arm by where
## the thumb points in the shown view; パー opens the claw, チョキ closes it, グー rests.
func _test_pose_thumb_and_claw() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"joystick": {"invert_z": false},
		"schemes": {"pose_direction": {"speed_z": 10.0, "pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0}}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String, thumb := Vector2.ZERO, n := 1) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose, "thumb_dx": thumb.x, "thumb_dy": thumb.y}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	step.call("other", Vector2.ZERO, 3)
	step.call("thumb", Vector2(0, -1), 12)  # the thumb towards the top of the image
	var up := g.is_active() and g.mode == "z" and is_equal_approx(g.velocity_z, 10.0) and g.velocity == Vector2.ZERO
	var states: Array[int] = []
	var rec := func(_f, to, _w): states.append(to)
	g.state_changed.connect(rec)
	step.call("thumb", Vector2(0, 1), 20)  # turned over: towards the bottom
	g.state_changed.disconnect(rec)
	var down := g.is_active() and is_equal_approx(g.velocity_z, -10.0)
	_ok(up and down and states.has(S.HAND_DETECTED),
		"pose scheme: thumbs-up up = arm up, down = arm down; turning the thumb over stops first",
		"%s %s %s %.1f" % [up, down, states, g.velocity_z])

	step.call("thumb", Vector2(1, 0.2).normalized(), 20)  # sideways: no sign
	var sideways := not g.is_active() and g.velocity_z == 0.0
	g.joystick.view_flip_v = true  # the view is shown upside down: the top of the image is the bottom of the screen
	step.call("thumb", Vector2(0, -1), 20)
	var flipped := g.is_active() and is_equal_approx(g.velocity_z, -10.0)
	g.joystick.view_flip_v = false
	_ok(sideways and flipped, "pose scheme: a sideways thumb does nothing; up / down follow the shown view",
		"%s %s %.1f" % [sideways, flipped, g.velocity_z])

	step.call("other", Vector2.ZERO, 10)
	step.call("open", Vector2.ZERO, 40)  # 0.67 s of パー
	var opened := claws == ["open"] and g.velocity_z == 0.0 and not g.is_active()
	step.call("peace", Vector2.ZERO, 40)
	var closed := claws == ["open", "closed"]
	step.call("fist", Vector2.ZERO, 60)  # resting: nothing
	_ok(opened and closed and claws == ["open", "closed"] and not g.is_active() and g.velocity_z == 0.0,
		"pose scheme: パー opens the claw, チョキ closes it, グー does nothing (none moves the crane)", str(claws))

## A test scheme: "open" steers +X, "peace" -X, no claw.
class _PoseScheme extends GestureScheme:
	var armed_pose := ""
	func id() -> String:
		return "test_pose"
	func engaged(g, _now_ms: float) -> bool:
		return g.pose in ["open", "peace"]
	func same_engagement(g) -> bool:
		return g.pose == armed_pose
	func on_arm(g, _now_ms: float) -> void:
		armed_pose = g.pose
		g.mode = "xy"
	func velocity(_g, _dt: float) -> Vector3:
		return Vector3(12.0 if armed_pose == "open" else -12.0, 0.0, 0.0)
	func reset(_g) -> void:
		armed_pose = ""

## The Z pinch is told apart by ear: its own cue, different from the XY pinch.
func _test_gesture_z_has_its_own_sound(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var S := GestureControl.State
	game.gesture.mode = "xy"
	game._on_gesture_state(S.HAND_DETECTED, S.ARMED, "")
	var xy: String = game.sfx.cue_log[-1] if not game.sfx.cue_log.is_empty() else ""
	game.gesture.mode = "z"
	game._on_gesture_state(S.HAND_DETECTED, S.ARMED, "")
	var z: String = game.sfx.cue_log[-1] if not game.sfx.cue_log.is_empty() else ""
	var notes: Dictionary = game.sfx.CUE_NOTES
	_ok(xy == "pinch" and z == "pinch_z" and notes.pinch_z != notes.pinch, "gesture: the Z pinch plays its own cue", "%s %s" % [xy, z])
	remove_child(game)
	game.free()
	rs.clear_samples()


## Auto catch (runs in the backend): the catch button's debounce, the refusal hints,
## the status line, and the manual lock while the backend reports it active.
func _test_auto_catch_controls(rs: Node) -> void:
	var m: GDScript = load("res://scripts/game/main.gd")
	_ok(m.auto_catch_press_ok(1000.0, 0.0, 500.0, false, false) and not m.auto_catch_press_ok(1300.0, 1000.0, 500.0, false, false)
		and not m.auto_catch_press_ok(5000.0, 0.0, 500.0, true, false) and not m.auto_catch_press_ok(5000.0, 0.0, 500.0, false, true),
		"auto catch: a press within the debounce, while running, or while waiting for an answer is ignored")
	var cases := {"auto catch refused: catch_z is not set; not confirmed on the real machine: z_scale": "未設定",
		"auto catch refused: alarm active (abort requested): clear_alarm, then home": "アラーム解除",
		"auto catch refused: not homed": "原点復帰", "auto catch refused: Z 40.0 below safe_z 95: raise the claw first": "安全高さ",
		"busy: auto catch already running": "ほかの動作中"}
	var all_ok := true
	for reason in cases:
		if not str(m.auto_catch_hint_for(reason)).contains(cases[reason]):
			all_ok = false
			print("      hint for %s: %s" % [reason, m.auto_catch_hint_for(reason)])
	_ok(all_ok and m.auto_catch_hint_for("debounced: pressed again too soon") == "", "auto catch: refusals are shown as the next step")
	var running: String = m.auto_catch_status_text({"active": true, "phase": "MOVE_TO_BOX", "step": 5, "steps": 9, "profile": "dry_run", "elapsed_s": 3.2})
	var fault: String = m.auto_catch_status_text({"active": false, "phase": "FAULT", "last_result": "fault", "error": "LOWER_TO_CATCH timeout (8 s, Z -> 30)", "profile": "real"})
	_ok(running.contains("5/9") and running.contains("救出ボックス") and running.contains("ドライラン")
		and fault.contains("異常停止") and fault.contains("LOWER_TO_CATCH timeout") and fault.contains("ABORT"),
		"auto catch: the status line shows the state, or why it stopped", running + " | " + fault)

	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.ws._handle({"type": "robot_state", "timestamp": 0, "data": {"connected": true, "homed": true, "motors_enabled": true,
		"state": "Z_LOWERING", "x": 120.0, "y": 100.0, "z": 60.0, "auto_catch": {"active": true, "phase": "LOWER_TO_CATCH", "step": 2, "steps": 9, "profile": "dry_run"}}})
	var active: bool = rs.auto_catch_active()
	game._handle_input(1.0 / 60.0)
	var src: String = game.control_source
	var before: float = rs.arm_deg
	game.arm_goto("open")
	game.arm_step(10.0)
	_ok(active and src == "halt" and (is_nan(before) and is_nan(rs.arm_deg) or rs.arm_deg == before),
		"auto catch: while the backend runs it, no manual jog or claw command is made", "%s %s" % [active, src])
	game.ws._handle({"type": "auto_catch", "data": {"active": false, "phase": "FAULT", "last_result": "fault", "error": "emergency stop (stop)", "profile": "dry_run"}})
	game._handle_input(1.0 / 60.0)
	game.debug_ui._update_robot_test()
	_ok(not rs.auto_catch_active() and game.control_source != "halt" and str(game.debug_ui._auto_label.text).contains("emergency stop"),
		"auto catch: a FAULT message unlocks manual control and the panel shows the cause", str(game.debug_ui._auto_label.text))
	game._auto_catch_last_ms = -1.0e9
	game.request_auto_catch()  # no backend link in the test
	_ok(game._auto_catch_rid == "" and str(game.auto_catch_hint).contains("バックエンド"),
		"auto catch: without a backend the button explains instead of sending", game.auto_catch_hint)
	remove_child(game)
	game.free()
	rs.auto_catch = {}
	rs.source = "mock"
	rs.connected = false
	rs.clear_samples()

# ------------------------------------------------------------------ study mode (#86)
func _test_study_worksheets_and_tracker() -> void:
	var cat := WorksheetCatalog.load_default()
	var grades := cat.grades()
	var three := true
	for g in grades:
		var ws := cat.for_grade(str(g.id))
		var probs: Array = ws.get("problems", [])
		if probs.size() != 3 or int(ws.get("help_problem", 0)) != 3 or str(probs[2].difficulty) != "challenge" \
				or str(probs[0].difficulty) != "easy" or str(probs[1].difficulty) != "easy":
			three = false
	_ok(cat.ok() and grades.size() == 12 and three and str(grades[0].label) == "保育園 年少" and str(grades[11].label) == "中学3年",
		"study: 12 grades, each worksheet has 3 problems and problem 3 is the HELP challenge", str(grades.size()))
	var t := StudyQuestionTracker.new()
	t.configure({"filled_prob": 0.6, "writing_prob": 0.3, "confirm_readings": 2, "complete_readings": 2})
	t.reset(3)
	var first := t.add_reading([0.9, 0.4, 0.1])
	var want_states: Array[String] = ["writing", "writing", "empty"]
	var once_ok := first.is_empty() and t.states == want_states
	var second := t.add_reading([0.9, 0.4, 0.1])
	var want_one: Array[int] = [1]
	var filled_ok := second == want_one and t.filled_count() == 1
	t.add_reading([null, null, null], true, "occluded")
	var held_ok := t.filled_count() == 1 and t.shown_state(2) == "held" and t.shown_state(1) == "filled"
	t.add_reading([0.1, 0.9, 0.9])  # problem 1 erased
	var erased_ok := not t.is_filled(1)
	t.add_reading([0.9, 0.9, 0.9])
	t.add_reading([0.9, 0.9, 0.9])
	var not_yet := t.filled_count() == 3 and not t.complete  # all filled once: not stable yet
	t.add_reading([0.9, 0.9, 0.9])
	_ok(once_ok and filled_ok and held_ok and erased_ok and not_yet and t.complete and t.completed_by == "readings",
		"study: a problem counts after 2 readings, a hand holds the states, completion needs stable readings",
		"%s %s %s %s %s %s" % [once_ok, filled_ok, held_ok, erased_ok, not_yet, t.complete])
	var m := StudyQuestionTracker.new()
	m.reset(3)
	m.confirm_complete()
	_ok(m.complete and m.completed_by == "manual" and m.filled_count() == 3, "study: a grown-up can confirm the homework by hand")

## Advance the study mode's clocks (speech, services, controller timers); the game's
## mock jumps to its targets (it is the virtual crane: the walk only waits for it).
func _study_pump(game: Node, secs: float, until := Callable()) -> bool:
	var ctl: StudyModeController = game.study_mode
	var dt := 0.1
	var t := 0.0
	while t < secs:
		ctl.speech._process(dt)
		ctl.services._process(dt)
		ctl._process(dt)
		game.mock.pos = game.mock.target
		game.mock.vel = Vector3.ZERO
		t += dt
		if until.is_valid() and until.call():
			return true
	return not until.is_valid()

func _study_game(mode := "simulated") -> Node:
	GameConfig.data["study_mode"]["enabled"] = true
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	RobotState.source = "mock"
	game.mock.enabled = true
	game.study_mode.services.set_mode(mode)
	game.study_mode.speech.voice_on = false
	game.study_mode.sounds.enabled = false
	return game

func _test_study_mode_mock_story(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hud: StudyHud = game.study_hud
	var states: Array[String] = []
	ctl.state_changed.connect(func(_p, c): states.append(c))
	var events: Array[String] = []
	var on_event := func(n, _d): events.append(n)
	GameState.event.connect(on_event)
	ctl.start()
	var intro_ok := ctl.state == "INTRO" and hud.visible and ctl.speech.current == "そろそろ勉強の時間だよ！" \
		and str(hud._check_rows[0][1].text) == "さんすうプリント"
	_study_pump(game, 15.0, func(): return ctl.state == "WAITING_FOR_WORKSHEET")
	ctl.change_grade(-1)  # 小学2年
	var grade_ok := ctl.grade_label() == "小学2年"
	_study_pump(game, 8.0, func(): return ctl.state == "STUDYING")  # the mock sheet is seen after worksheet_wait_s
	var studying_ok := ctl.state == "STUDYING" and ctl.study_started_ms >= 0
	ctl.handle_key(KEY_1)
	_study_pump(game, 6.0, func(): return ctl.tracker.is_filled(1))
	hud.refresh()
	var one_ok := ctl.tracker.is_filled(1) and str(hud._count.text) == "宿題 1 / 3 問" and events.has("study_question_filled")
	# HELP: Y -> locate -> the 3 close-ups in order -> explanation -> back to the homework
	var target_before: Vector3 = game.mock.target
	ctl.handle_key(KEY_Y)
	var help_ok := ctl.state == "HELP_LOCATING"
	_study_pump(game, 5.0, func(): return ctl.state == "HELP_MOVING")
	var moving: bool = ctl.state == "HELP_MOVING" and ctl.blocks_manual_control()
	game._handle_input(1.0 / 60.0)
	var halted: bool = game.control_source == "halt"
	_study_pump(game, 30.0, func(): return ctl.state == "AI_EXPLAINING")
	var captures := states.filter(func(s): return s.begins_with("CAPTURE_"))
	var order_ok := captures == ["CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING"]
	var went_down: bool = game.mock.target != target_before
	_study_pump(game, 40.0, func(): return ctl.state == "STUDYING")
	var explained_ok := ctl.state == "STUDYING" and str(ctl.explanation.get("hint", "")) != "" \
		and str(ctl.explanation.get("source", "")) == "demo"
	_ok(intro_ok and grade_ok and studying_ok and one_ok, "study mock: intro, grade, the sheet is found, a problem filled",
		"%s %s %s %s" % [intro_ok, grade_ok, studying_ok, one_ok])
	_ok(help_ok and moving and halted and order_ok and went_down and explained_ok,
		"study mock: HELP looks at problem 3 with 10cm -> 5cm -> landing close-ups, explains, and the jog is held meanwhile",
		"%s %s %s %s %s %s %s" % [help_ok, moving, halted, captures, went_down, explained_ok, ctl.state])
	# complete: only after stable readings, celebrated once
	ctl.handle_key(KEY_2)
	ctl.handle_key(KEY_3)
	_study_pump(game, 2.0)
	var not_early := ctl.celebrate_count == 0
	var celebrations_before: int = game.vfx.celebrations
	_study_pump(game, 10.0, func(): return ctl.state == "CELEBRATION")
	var celebrate_ok: bool = ctl.state == "CELEBRATION" and ctl.celebrate_count == 1 and events.has("study_complete") \
		and game.vfx.celebrations == celebrations_before + 1 and game._mood() == "SUCCESS"
	ctl._on_reading([0.95, 0.95, 0.95], false, "")
	ctl._check_complete()
	ctl.advance()  # a stray Enter during the celebration
	var once_ok := ctl.celebrate_count == 1
	hud.refresh()
	var banner_ok := hud._banner.visible and str(hud._banner.text) == "宿題完了！！" and str(hud._check_rows[0][0].text) == "☑"
	_ok(not_early and celebrate_ok and once_ok and banner_ok, "study mock: the celebration fires once, after the 3 problems are stably filled",
		"%s %s %s %s" % [not_early, celebrate_ok, once_ok, banner_ok])
	# the tidy-up: waits for a grown-up to confirm the grip, then the game is unlocked
	_study_pump(game, 20.0, func(): return ctl.adult_prompt != "")
	var frozen := ctl.elapsed_s()
	var grip_wait := ctl.state == "CLEANUP" and ctl.adult_prompt.contains("つかめていたら") and hud._time_panel.visible
	_study_pump(game, 3.0)
	var still := ctl.state == "CLEANUP" and is_equal_approx(ctl.elapsed_s(), frozen)  # never by itself
	ctl.advance()
	_study_pump(game, 40.0, func(): return ctl.state == "GAME_UNLOCKED")
	hud.refresh()
	var unlocked := ctl.state == "GAME_UNLOCKED" and ctl.cleanup_ok and str(hud._check_rows[2][0].text) == "☑" \
		and hud._play.visible and str(hud._banner.text) == "MISSION COMPLETE!" and hud._sub_banner.text.begins_with("GAME MODE UNLOCKED!")
	_ok(grip_wait and still and unlocked, "study mock: the tidy-up waits for the grip confirmation, then MISSION COMPLETE",
		"%s %s %s %s" % [grip_wait, still, unlocked, ctl.state])
	ctl.play_game()
	_ok(ctl.state == "OFF" and not hud.visible and game._mood() != "SUCCESS" and not ctl.blocks_manual_control(),
		"study mock: 'ゲームで遊ぶ' returns to the claw game")
	GameState.event.disconnect(on_event)
	remove_child(game)
	game.free()
	RobotState.source = "mock"
	rs.clear_samples()

func _test_study_mode_failures(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	ctl.start()
	ctl.debug_skip()  # INTRO -> waiting
	ctl.debug_skip()  # the sheet is placed
	var to_study := ctl.state == "STUDYING"
	# the place cannot be told (calibration): no motion, the worksheet's hints instead
	ctl.services.inject_fail = "locate"
	var target_before: Vector3 = game.mock.target
	ctl.request_help()
	_study_pump(game, 4.0, func(): return ctl.state == "RESUME_STUDY")
	var no_move: bool = ctl.state == "RESUME_STUDY" and game.mock.target == target_before and ctl.notice.contains("校正")
	_study_pump(game, 30.0, func(): return ctl.state == "STUDYING")
	var hints_ok := str(ctl.explanation.get("source", "")) == "worksheet" and ctl.explain_note.contains("動かしていません")
	_ok(to_study and no_move and hints_ok, "study: an unusable calibration never moves the arm, the hints are still shown",
		"%s %s %s" % [to_study, no_move, hints_ok])
	# Space during a close-up: the arm stops, ERROR, Enter goes back to the homework
	ctl.request_help()
	_study_pump(game, 10.0, func(): return ctl.state == "CAPTURE_10CM")
	ctl.on_stop_key()
	var stopped := ctl.state == "ERROR" and not ctl.services.motion_active() and ctl.error_text.contains("Space")
	ctl.advance()
	_ok(stopped and ctl.state == "STUDYING", "study: Space during HELP stops the arm, then Enter resumes the homework",
		"%s %s" % [stopped, ctl.state])
	# the AI fails: the explanation still comes (the worksheet's hints) and the story goes on
	ctl.services.inject_fail = "ai"
	ctl.request_help()
	_study_pump(game, 40.0, func(): return ctl.state == "STUDYING")
	_ok(ctl.state == "STUDYING" and str(ctl.explanation.get("source", "")) == "worksheet" and ctl.explain_note.contains("AI"),
		"study: an AI failure is shown and the worksheet's hints explain instead", ctl.explain_note)
	# no voice engine: every line is still shown and the story moves on
	var spoke := ctl.services.voice_request("テスト")
	_ok(spoke == "" and ctl.speech.reading_time("あいうえお") >= ctl.speech.min_line_s,
		"study: without VOICEVOX the lines are only shown, for a reading time")
	# the tidy-up fails: told apart from the unlock, needs a grown-up, then unlocks without the check
	ctl.services.inject_fail = "cleanup"
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 30.0, func(): return ctl.state == "CLEANUP_FAILED")
	game.study_hud.refresh()
	var failed_ok: bool = ctl.state == "CLEANUP_FAILED" and not ctl.cleanup_ok and ctl.adult_prompt != "" \
		and str(game.study_hud._check_rows[2][0].text) == "☒"
	ctl.advance()
	_ok(failed_ok and ctl.state == "GAME_UNLOCKED" and not ctl.cleanup_ok and game.study_hud._sub_banner.text.contains("大人"),
		"study: a failed tidy-up is not the unlock (a grown-up confirms, the tidy-up stays unchecked)",
		"%s %s" % [failed_ok, ctl.state])
	# #92: the robot is the one start.sh connected; the config only says simulated / camera
	var sv := StudyServices
	_ok(sv.normalize_mode("mock") == "simulated" and sv.normalize_mode("real") == "camera"
		and sv.normalize_mode("camera") == "camera" and sv.normalize_mode("simulated") == "simulated"
		and sv.normalize_mode("bogus") == "simulated",
		"study: demo source names (earlier mock / real read; unknown = simulated, nothing sent)")
	var sim_real := sv.blocker_for("backend", true, "simulated")
	_ok(sim_real.contains("模擬デモでは実機を動かしません") and sv.blocker_for("backend", true, "camera") == ""
		and sv.blocker_for("backend", false, "simulated") == "" and sv.blocker_for("game_mock", false, "simulated") == ""
		and sv.blocker_for("", false, "camera") != "",
		"study: simulated never moves the real crane; camera follows the connected robot (backend gates stay)", sim_real)
	# camera mode without a backend: nothing to move, with the reason
	ctl.start()
	ctl.services.set_mode("camera")
	var why := ctl.services.motion_blocker()
	RobotState.source = "websocket"
	var why_ws := ctl.services.motion_blocker()
	RobotState.source = "mock"
	_ok(why != "" and why_ws.contains("つながっていません"), "study: the camera demo never moves the game's own mock, nor without a robot link", why + " | " + why_ws)
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

## The backend route: the sequences' status messages drive the story (holding at a
## stage -> that close-up; the previous run's IDLE / FAULT ignored; NACK and FAULT end it).
func _test_study_mode_backend_messages(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl._set_state("HELP_MOVING")
	sv._help_active = true
	sv._help_rid = "h1"
	var st := {"active": false, "phase": "FAULT", "last_result": "fault", "error": "old run"}
	sv._on_robot_message({"type": "robot_state", "data": {"homework_approach": st}})
	var stale_ok := ctl.state == "HELP_MOVING"  # the previous run's FAULT is not this one's
	var seen: Array[String] = []
	ctl.state_changed.connect(func(_p, c): seen.append(c))
	for stage in ["10cm", "5cm", "landing"]:
		sv._on_robot_message({"type": "homework_approach", "data": {"active": true, "phase": "LOWER", "stage": stage, "holding": false}})
		sv._on_robot_message({"type": "homework_approach", "data": {"active": true, "phase": "HOLD", "stage": stage, "holding": true}})
		sv._on_robot_message({"type": "robot_state", "data": {"homework_approach": {"active": true, "phase": "HOLD", "stage": stage, "holding": true}}})
		_study_pump(game, 1.5)
	var order: Array = seen.filter(func(x): return x.begins_with("CAPTURE_"))
	sv._on_robot_message({"type": "homework_approach", "data": {"active": false, "phase": "IDLE", "last_result": "done"}})
	var done_ok := ctl._help_arm_done and not sv.motion_active()
	_ok(stale_ok and order == ["CAPTURE_10CM", "CAPTURE_5CM", "CAPTURE_LANDING"] and done_ok,
		"study backend: the staged approach's messages give the 3 close-ups in order, then done", "%s %s %s" % [stale_ok, order, done_ok])
	# a refused approach (NACK) and a refused tidy-up are shown, never retried
	ctl._set_state("HELP_MOVING")
	sv._help_active = true
	sv._help_rid = "h2"
	sv._on_robot_ack("h2", false, {"reason": "staged capture refused: height calibration (study_mode.height.real) not measured"})
	var nack_ok := ctl.state == "ERROR" and ctl.error_text.contains("not measured") and not sv.motion_active()
	ctl.advance()
	ctl.completion_fired = true
	ctl._set_state("CLEANUP")
	sv._cleanup_active = true
	sv._cleanup_rid = "c1"
	sv._on_robot_ack("c1", false, {"reason": "tidy-up refused: the tidy-up is off on the real robot (study_mode.cleanup.enabled_real)"})
	_ok(nack_ok and ctl.state == "CLEANUP_FAILED" and ctl.error_text.contains("enabled_real"),
		"study backend: refusals (no height calibration, tidy-up off) stop the story with the reason", "%s %s" % [nack_ok, ctl.state])
	# F5 / F8 while the backend's run is going: the story forgets it, and its late FAULT changes nothing
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl._set_state("HELP_MOVING")
	sv._help_active = true
	sv._help_started = true
	ctl.start()  # F8
	var forgot := not sv._help_active and not sv.motion_active() and ctl.state == "INTRO"
	sv._on_robot_message({"type": "homework_approach", "data": {"active": false, "phase": "FAULT", "last_result": "fault", "error": "stopped"}})
	_ok(forgot and ctl.state == "INTRO", "study backend: a restart ends the run it started; its late FAULT is ignored", "%s %s" % [forgot, ctl.state])
	# HELP when problem 3 is already written: said so, the arm stays
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.states[2] = StudyQuestionTracker.FILLED
	ctl.request_help()
	_ok(ctl.state == "STUDYING" and not sv.motion_active() and ctl.notice.contains("動かしません"),
		"study: HELP on an already written problem 3 does not move the arm", ctl.state)
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev

## The title screen (#90): not shown headless; when shown it holds the arm (Space still
## stops), picks the study or the game mode by keys or a click, and Esc comes back.
func _test_settings(rs: Node) -> void:
	# the schema: what the screen may change, nothing about calibration or safety
	var items := GameConfig.schema_items(GameConfig.schema)
	var missing := []
	for k in items.keys():
		if GameConfig.base_value(k) == null:
			missing.append(k)
	var banned := []
	for k in items.keys():
		for b in ["robot.", "backend.z_", "backend.arm_open", "backend.home_", "auto_catch.", "study_mode.height.",
				"study_mode.cleanup.", "gesture.allow_real_robot", "network."]:
			if str(k).begins_with(b):
				banned.append(k)
	_ok(items.size() >= 15 and missing.is_empty() and banned.is_empty(),
		"settings: the schema lists the settings (all in game_config.json, no calibration / safety key)",
		"%d %s %s" % [items.size(), missing, banned])
	var warns: Array[String] = []
	var got := GameConfig.filter_overrides({"backend.z_sign": -1, "robot.x_max_mm": 999.0, "study.enabled": "yes",
		"audio.volume_db": 50.0, "backend.serial_port": "a\nb", "study.provider": "codex", "audio.volume_db_x": 1,
		"study_mode.demo.source": "camera"}, items, warns)
	_ok(got == {"study.provider": "codex", "study_mode.demo.source": "camera"} and warns.size() == 6,
		"settings: only allowed keys and values are used from local_settings.json", str(got))
	_ok(GameConfig.flatten({"a": {"b": {"c": 1}}, "d": 2}) == {"a.b.c": 1, "d": 2}
		and GameConfig.nest({"a.b.c": 1, "a.x": true}) == {"a": {"b": {"c": 1}, "x": true}},
		"settings: flatten / nest of the dotted keys")

	var game := _study_game()
	var t: TitleScreen = game.title
	var st: SettingsScreen = game.settings
	game._unhandled_input(_key(KEY_S))
	_ok(not game.settings_active(), "settings: only from the title")
	game.show_title()
	game._unhandled_input(_key(KEY_S))
	game._handle_input(0.1)
	var held: bool = game.settings_active() and game.title_active() and game.control_source == "halt"
	_ok(held and st.layer > t.layer and game.debug_ui.layer > st.layer,
		"settings: S opens it over the title; the arm stays held; the debug panel above it", game.control_source)
	game._unhandled_input(_key(KEY_2))
	_ok(game.settings_active() and game.title_active(), "settings: the title's keys do not reach through it")
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))
	game._unhandled_input(_key(KEY_SPACE))
	_ok(game.settings_active() and game.mock.target.is_equal_approx(game.mock.pos), "settings: Space still stops")
	# review on #95: Space stops even while a settings field has the keyboard
	var field: LineEdit = st._rows["backend.serial_port"].control
	field.grab_focus()
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))
	game._input(_key(KEY_SPACE))
	_ok(game.text_entry_focused() and game.mock.target.is_equal_approx(game.mock.pos),
		"settings: Space stops while typing in a settings field (the GUI would take it)")
	field.release_focus()
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(not game.settings_active() and game.title_active() and t.notice() == "", "settings: Esc closes it unsaved, back to the title")
	t.gear.pressed.emit()
	_ok(game.settings_active(), "settings: the gear opens it")

	# save to a test file (never the machine's own)
	var real_path := GameConfig.local_path
	var path := "user://test_local_settings.json"
	GameConfig.local_path = path
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var base_provider = GameConfig.base_value("study.provider")
	st.set_form_value("study.provider", "codex")
	st.set_form_value("study_mode.demo.source", "camera")
	st.set_form_value("audio.volume_db", -20.0)
	var marked: bool = (st._rows["study.provider"].label as Label).text.ends_with("＊")
	var err := st.save()
	var saved = GameConfig.read_json(path)
	_ok(game.study_mode.services.mode == "camera" and is_equal_approx(game.sfx.volume_db, -20.0),
		"settings: the 今すぐ items apply on 保存 (the study mode's source, the volume)")
	game.open_settings()
	st.set_form_value("render.screen_shake", false)
	st.set_form_value("study_mode.grade", "jhs_1")
	st.save()
	var live_ok: bool = not game.shake.enabled and game.study_mode.grade_index == game.study_mode.catalog.grade_index("jhs_1")
	game.open_settings()
	st.set_form_value("render.screen_shake", true)
	st.set_form_value("study_mode.grade", str(GameConfig.base_value("study_mode.grade")))
	st.save()
	_ok(live_ok and game.shake.enabled, "settings: the screen shake and the grade apply on 保存 too (and back)")
	_ok(err == "" and not game.settings_active() and t.notice().contains("保存") and marked
		and saved == {"audio": {"volume_db": -20.0}, "study": {"provider": "codex"}, "study_mode": {"demo": {"source": "camera"}}}
		and GameConfig.value("study.provider") == "codex" and GameConfig.base_value("study.provider") == base_provider,
		"settings: 保存 writes only the changed keys to local_settings.json and uses them", str(saved))
	game.open_settings()
	var shown: bool = st.form_value("study.provider") == "codex" and is_equal_approx(float(st.form_value("audio.volume_db")), -20.0)
	_ok(shown and GameConfig.save_local({"robot.x_max_mm": 1.0}) != "" and GameConfig.read_json(path) == saved,
		"settings: it reopens with the saved values; a key outside the schema is refused")
	GameConfig.load_local()
	_ok(GameConfig.local == {"study.provider": "codex", "study_mode.demo.source": "camera", "audio.volume_db": -20.0},
		"settings: the saved file reads back", str(GameConfig.local))
	st.reset_defaults()
	st.save()
	_ok(GameConfig.read_json(path) == {} and GameConfig.local.is_empty() and GameConfig.value("study.provider") == base_provider,
		"settings: 既定に戻す + 保存 empties the overrides")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameConfig.local_path = real_path
	remove_child(game)
	game.free()
	rs.clear_samples()

func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null

func _test_calibration_tab(rs: Node) -> void:
	var game := _study_game()
	var st: SettingsScreen = game.settings
	game.show_title()
	game.open_settings()
	game.ui_jog_z = 1.0  # as if W were held (the debug panel's hold button uses the same path)
	game._handle_input(0.1)
	var held_on_settings: bool = game.control_source == "halt" and not game.calibrating()
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	game._handle_input(0.1)
	var moves: bool = game.calibrating() and game.control_source != "halt"
	_ok(held_on_settings and moves and game.title_active(),
		"calibration: the keys move the arm only on the 校正 tab (the title stays up)", game.control_source)
	_ok(game.gesture_gate() != "", "calibration: the hand gestures stay off on the 校正 tab")
	var deg0: float = game.mock.arm_deg
	game._unhandled_input(_key(KEY_BRACKETRIGHT))
	var turned: bool = not is_equal_approx(game.mock.arm_deg, deg0)
	game._unhandled_input(_key(KEY_C))
	_ok(turned and not rs.auto_catch_active() and st.calibrating(),
		"calibration: [ ] turn the claw there; C (the auto catch) still goes nowhere")
	var open_b := _find_button(st.calibration, "ここを開きに記録")
	open_b.pressed.emit()
	_ok(is_equal_approx(float(game.mock.arm_marks.get("open", NAN)), game.mock.arm_deg),
		"calibration: 開きに記録 records the claw position (the game's mock here)")
	st.calibration.refresh()
	var z_b := _find_button(st.calibration, "ここを上に記録")
	_ok(z_b.disabled and st.calibration._link.text.contains("バックエンドなし"),
		"calibration: without a backend the Z / spot / camera buttons cannot be pressed, with the reason")
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))
	game._unhandled_input(_key(KEY_SPACE))
	_ok(game.mock.target.is_equal_approx(game.mock.pos) and st.calibrating(), "calibration: Space still stops")
	st.show_tab(0)
	game._handle_input(0.1)
	var held_again: bool = game.control_source == "halt"
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	game._unhandled_input(_key(KEY_ESCAPE))
	game._handle_input(0.1)
	_ok(held_again and not game.settings_active() and game.title_active() and game.control_source == "halt",
		"calibration: back on the settings tab or closed, the arm is held again")
	game.open_settings()
	_ok(not game.calibrating(), "calibration: the settings screen always opens on the settings tab")
	game.ui_jog_z = 0.0
	remove_child(game)
	game.free()
	rs.clear_samples()

func _test_title_screen(rs: Node) -> void:
	var game := _study_game()
	var t: TitleScreen = game.title
	var ctl: StudyModeController = game.study_mode
	_ok(t != null and not game.title_active(), "title: not shown at start when headless (tests, CI)")
	game.show_title()
	game._handle_input(0.1)
	var held: bool = game.title_active() and game.control_source == "halt"
	game._unhandled_input(_key(KEY_C))  # the auto catch key goes nowhere
	game._unhandled_input(_key(KEY_RIGHT))
	var moved_sel: bool = t.selected_mode() == "game" and game.title_active()
	game._unhandled_input(_key(KEY_LEFT))
	_ok(held and moved_sel and t.selected_mode() == "study" and not ctl.active(),
		"title: holds the manual controls; arrows choose, other keys are swallowed", game.control_source)
	game._unhandled_input(_key(KEY_ENTER))
	_ok(not game.title_active() and ctl.active() and ctl.state == "INTRO", "title: Enter on the study mode starts it", ctl.state)
	game._handle_input(0.1)
	var free_again: bool = game.control_source != "halt"
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(free_again and game.title_active() and not ctl.active(), "title: Esc stops the study mode and comes back", ctl.state)
	game._unhandled_input(_key(KEY_2))
	_ok(not game.title_active() and not ctl.active(), "title: 2 picks the game mode (the crane game, no study mode)")
	game.show_title()
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))  # as if the arm were on its way
	game._unhandled_input(_key(KEY_SPACE))
	var stopped: bool = game.mock.target.is_equal_approx(game.mock.pos)
	_ok(game.title_active() and stopped, "title: Space still reaches the game's stop (the mock halts) and leaves the title up")
	var card: PanelContainer = t._cards[1]
	card.gui_input.emit(_mouse_press())
	_ok(not game.title_active() and not ctl.active() and t.selected_mode() == "game", "title: a click on a card picks it")
	game.show_title()
	game._unhandled_input(_key(KEY_F5))
	_ok(not game.title_active() and ctl.active(), "title: F5 picks the study mode too")
	ctl.stop()
	# review on #91: the claw poses are gated too (the gate reaches GestureControl._claw_tick)
	game.gesture_require_focus = false
	var open_gate: String = game.gesture_gate()
	game.show_title()
	var title_gate: String = game.gesture_gate()
	_ok(open_gate == "" and title_gate != "", "title: the gesture gate (steering and claw poses) is shut while it shows",
		"%s / %s" % [open_gate, title_gate])
	# the debug panel goes above the title (hidden; F1 shows it there), and back after
	var dbg: CanvasLayer = game.debug_ui
	var above: bool = dbg.layer > t.layer and not dbg.visible
	game._unhandled_input(_key(KEY_F1))
	var shown: bool = dbg.visible and game.title_active()
	game._unhandled_input(_key(KEY_2))
	_ok(above and shown and dbg.layer < t.layer and dbg.visible, "title: the debug panel opens above it (F1) and goes back after",
		"layer %d" % dbg.layer)
	# when the title is shown at start
	var none := PackedStringArray()
	var GameMain: GDScript = load("res://scripts/game/main.gd")
	_ok(GameMain.title_on_start(none, true, false, false) and not GameMain.title_on_start(none, true, true, false)
		and not GameMain.title_on_start(none, false, false, false)
		and not GameMain.title_on_start(none, true, false, true)
		and not GameMain.title_on_start(PackedStringArray(["--study-mode"]), true, false, false)
		and not GameMain.title_on_start(PackedStringArray(["--scenario", "x_sweep"]), true, false, false)
		and not GameMain.title_on_start(PackedStringArray(["--no-title"]), true, false, false)
		and GameMain.title_on_start(PackedStringArray(["--capture", "d", "--title"]), true, true, true),
		"title: at start unless headless, disabled, autostarted or decided by arguments; --title forces it")
	remove_child(game)
	game.free()
	rs.clear_samples()
