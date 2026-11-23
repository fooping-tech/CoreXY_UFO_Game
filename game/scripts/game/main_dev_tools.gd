class_name MainDevTools
extends RefCounted
## The main scene's startup options and its two debugging aids, taken out of it (#223):
## what each `--option` after `--` does, the motion log (--log-motion) and the frame capture
## (--capture). Nothing here is part of the game: it only calls what the main scene already
## offers (use_source, set_gesture_enabled, the score game's own start ...), and sends
## nothing to the robot by itself.

var main: Node2D

func _init(m: Node2D) -> void:
	main = m

## `godot --path game -- --scenario x_sweep --source websocket --hide-debug`
func apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	# the configured window mode at start (review on #158: render.fullscreen saved in the
	# settings must hold after a restart with no argument); --fullscreen / --windowed below win
	main.apply_window_mode()
	if main.title_on_start(args, bool(GameConfig.get_value("title_screen", "enabled", true)),
			DisplayServer.get_name() == "headless",
			main.study_mode != null and bool(GameConfig.get_value("study_mode", "autostart", false))):
		main.show_title()
		main.open_startup_screen()
	for i in range(args.size()):
		match args[i]:
			"--scenario":
				if i + 1 < args.size():
					main.mock.run_scenario(args[i + 1])
			"--source":
				if i + 1 < args.size():
					main.use_source(args[i + 1])
			"--capture-frames":
				# how many frames --capture saves (2 per second; 16 = 8 s when left out). After --capture.
				if i + 1 < args.size():
					_capture_left = maxi(int(args[i + 1]), 1)
			"--hide-debug":
				main.debug_ui.visible = false
				main._layout()
			"--capture":
				# Save a viewport PNG every 0.5 s into <dir> for 8 s, print FPS, quit.
				if i + 1 < args.size():
					_capture_dir = args[i + 1]
					_capture_left = 16
			"--log-motion":
				# CSV of every physics tick (P) and render frame (R) for debugging
				# jitter: robot samples, playback pose, anchor, UFO, character cues.
				if i + 1 < args.size():
					open_motion_log(args[i + 1])
			"--gesture":
				main.set_gesture_enabled(true)
			"--no-gesture":
				# start.sh always says --gesture or --no-gesture; the config's gesture.enabled
				# is only the default of a game started without it
				main.set_gesture_enabled(false)
			"--gesture-scheme":
				# how the hand is read: pinch_joystick / pose_direction (config gesture.scheme)
				if i + 1 < args.size():
					main.gesture.set_scheme(args[i + 1])
			"--gesture-demo":
				# a scripted hand (pinch, steer, release, lose it) through the gesture path
				main._gesture_demo_t = 0.0
				main.set_gesture_enabled(true)
				main.gesture_require_focus = false
			"--study-mode", "--study-demo":
				# the study mode right away; --study-demo <simulated|camera> also picks what it
				# uses (mock / real still read: mock = simulated, real = camera)
				if main.study_mode == null:
					main._setup_study_mode()
				if args[i] == "--study-demo" and i + 1 < args.size():
					main.study_mode.services.set_mode(args[i + 1])
				main.study_mode.call_deferred("start")
			"--game-mode":
				# the 150 s score game right away (#138); --game-mode-devices mock / backend picks
				# the peripherals, --game-mode-seconds <n> a shorter round (demos, captures),
				# --game-mode-demo lets the mock Dials take capsules by themselves
				if main.game_mode != null:
					main._on_title_chosen("score")
					main.game_mode.call_deferred("start")
			"--game-mode-tutorial":
				# the score game from its practice (#149: the spell, the hand shapes, one capsule);
				# with --game-mode-demo a scripted hand and the mock Dial go through it by themselves
				if main.game_mode != null:
					main._on_title_chosen("score")
					main.game_mode.call_deferred("start_tutorial")
			"--game-mode-title":
				# the score game's own title screen (waiting for Enter): for captures
				if main.game_mode != null:
					main._on_title_chosen("score")
			"--game-mode-devices":
				if main.game_mode != null and i + 1 < args.size():
					main.game_mode.devices_wanted = args[i + 1]
					main.game_mode.use_devices(args[i + 1])
			"--game-mode-demo":
				if main.game_mode != null:
					main.game_mode.demo = true
			"--capsule-probe":
				# #291: the capsule colour probe (カプセル色判定テスト) open at start
				main.open_capsule_probe()
			"--capsule-probe-image":
				# #291: ... judging a saved picture (its 画像を保存 PNG), paused: compare values on it
				if i + 1 < args.size():
					main.open_capsule_probe()
					main.capsule_probe.load_image(args[i + 1])
			"--fullscreen":
				main.fullscreen_override = "on"
				main.apply_window_mode()
			"--windowed":
				main.fullscreen_override = "off"
				main.apply_window_mode()
			"--game-mode-ranking-file":
				# the high scores (#155) in a file of its own, and a rehearsal's rounds
				# (--game-mode-demo, --game-mode-seconds) are recorded in it: for captures and
				# checks, never the exhibit's ranking
				if main.game_mode != null and i + 1 < args.size():
					main.game_mode.ranking.path = args[i + 1]
					main.game_mode.ranking_force = true
					main.game_mode.ranking.load_file()
			"--game-mode-seconds":
				if main.game_mode != null and i + 1 < args.size():
					main.game_mode.duration_s = maxf(float(args[i + 1]), 1.0)
			"--quit-after":
				if i + 1 < args.size():
					main.get_tree().create_timer(float(args[i + 1])).timeout.connect(main.get_tree().quit)

var _motion_log: FileAccess

func open_motion_log(path: String) -> void:
	_motion_log = FileAccess.open(path, FileAccess.WRITE)
	if _motion_log == null:
		push_warning("cannot open motion log " + path)
		return
	_motion_log.store_line("kind,usec,dt,src,raw_x,raw_y,raw_z,pose_x,pose_y,pose_z,anchor_x,anchor_z,accel_x,accel_z,rope_target,rope_len,ufo_x,ufo_y,ufo_z,screen_x,screen_y,screen_vel_x,anchor_screen_accel,rotation_deg,face,game_state,play_ms,newest_ms,recv_ms,delay_ms")

func log_motion(kind: String, dt: float, pose: Vector3) -> void:
	if _motion_log == null:
		return
	var sim = main.sim
	var ufo = main.ufo
	var u = sim.ufo_position()
	var acc = sim.anchor_acceleration()
	_motion_log.store_line("%s,%d,%.5f,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.1f,%.1f,%.2f,%s,%s,%.1f,%.1f,%.1f,%.1f" % ([
		kind, Time.get_ticks_usec(), dt, RobotState.source,
		RobotState.x_mm, RobotState.y_mm, RobotState.z_mm, pose.x, pose.y, pose.z,
		sim.anchor.x, sim.anchor.z, acc.x, acc.z, sim.target_rope_length, sim.rope_length,
		u.x, u.y, u.z, ufo.position.x, ufo.position.y, main._ufo_screen_vel.x, main._anchor_screen_accel.length(),
		rad_to_deg(ufo.rotation), ufo.current_face(), GameState.state] + RobotState.playback_debug()))

## The main scene leaves the tree: the motion log is closed.
func close() -> void:
	if _motion_log != null:
		_motion_log.close()

var _capture_dir := ""
var _capture_left := 0
var _capture_timer := 0.0
var _capture_index := 0
var _fps_samples: Array[float] = []

func capture_tick(dt: float) -> void:
	if _capture_dir == "":
		return
	_capture_timer += dt
	if Engine.get_frames_per_second() > 0:
		_fps_samples.append(Engine.get_frames_per_second())
	if _capture_timer >= 0.5:
		_capture_timer = 0.0
		var img := main.get_viewport().get_texture().get_image()
		img.save_png(_capture_dir.path_join("frame_%02d.png" % _capture_index))
		_capture_index += 1
		_capture_left -= 1
		if _capture_left <= 0:
			var sum := 0.0
			var lo := 9999.0
			for f in _fps_samples:
				sum += f
				lo = minf(lo, f)
			print("[capture] frames saved to %s; avg FPS %.1f min FPS %.1f physics %d us" % [_capture_dir, sum / maxf(_fps_samples.size(), 1), lo, main.physics_usec])
			main.get_tree().quit()
