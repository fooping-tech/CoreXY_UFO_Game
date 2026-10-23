extends Node2D
## Main scene: wires RobotState -> rope anchor/length -> RopeSimulator ->
## Projection25D -> RopeView + UfoCharacter. Also hosts MockRobot, the
## WebSocket client and the debug overlay.

const UfoScene := preload("res://scenes/ufo.tscn")
const DebugScene := preload("res://scenes/debug.tscn")

var sim := RopeSimulator.new()
var proj := Projection25D.new()
var rope_view: RopeView
var ufo: UfoCharacter
var mock: MockRobot
var ws: UfoWebSocketClient
var background: Node2D
var effects: Node2D
var debug_ui: CanvasLayer

var _initialised := false
var _last_anchor := Vector3.ZERO
var _prev_ufo_screen := Vector2.ZERO
var _prev_anchor_screen_vel := Vector2.ZERO
var _prev_anchor_screen := Vector2.ZERO
var _anchor_screen_accel := Vector2.ZERO
var _ufo_screen_vel := Vector2.ZERO
var _prev_depth := 0.0
var _depth_vel := 0.0
var physics_usec: int = 0
## Keyboard jog speed for the mock robot (mm/s)
var jog_speed_mm := 180.0
var jog_speed_z := 50.0

func _ready() -> void:
	_apply_config()
	background = Node2D.new()
	background.name = "Background"
	background.set_script(load("res://scripts/ui/starfield.gd"))
	add_child(background)
	rope_view = RopeView.new()
	rope_view.name = "RopeView"
	rope_view.pixel_scale = float(GameConfig.get_value("render", "pixel_scale", 3.0))
	rope_view.rope_width_px = float(GameConfig.get_value("render", "rope_width_px", 6.0))
	add_child(rope_view)
	ufo = UfoScene.instantiate()
	ufo.name = "UFO"
	ufo.pixel_scale = float(GameConfig.get_value("render", "pixel_scale", 3.0))
	add_child(ufo)
	effects = Node2D.new()
	effects.name = "Effects"
	effects.set_script(load("res://scripts/ui/effects.gd"))
	add_child(effects)
	mock = MockRobot.new()
	mock.name = "MockRobot"
	add_child(mock)
	ws = UfoWebSocketClient.new()
	ws.name = "WebSocket"
	add_child(ws)
	debug_ui = DebugScene.instantiate()
	debug_ui.name = "DebugUI"
	add_child(debug_ui)
	debug_ui.setup(self)
	GameState.state_changed.connect(_on_game_state_changed)
	get_viewport().size_changed.connect(_layout)
	_layout()
	_apply_cmdline()

## `godot --path game -- --scenario x_sweep --source websocket --hide-debug`
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--scenario":
				if i + 1 < args.size():
					mock.run_scenario(args[i + 1])
			"--source":
				if i + 1 < args.size():
					use_source(args[i + 1])
			"--hide-debug":
				debug_ui.visible = false
				_layout()
			"--capture":
				# Save a viewport PNG every 0.5 s into <dir> for 8 s, print FPS, quit.
				if i + 1 < args.size():
					_capture_dir = args[i + 1]
					_capture_left = 16

var _capture_dir := ""
var _capture_left := 0
var _capture_timer := 0.0
var _capture_index := 0
var _fps_samples: Array[float] = []

func _capture_tick(dt: float) -> void:
	if _capture_dir == "":
		return
	_capture_timer += dt
	if Engine.get_frames_per_second() > 0:
		_fps_samples.append(Engine.get_frames_per_second())
	if _capture_timer >= 0.5:
		_capture_timer = 0.0
		var img := get_viewport().get_texture().get_image()
		img.save_png(_capture_dir.path_join("frame_%02d.png" % _capture_index))
		_capture_index += 1
		_capture_left -= 1
		if _capture_left <= 0:
			var sum := 0.0
			var lo := 9999.0
			for f in _fps_samples:
				sum += f
				lo = minf(lo, f)
			print("[capture] frames saved to %s; avg FPS %.1f min FPS %.1f physics %d us" % [_capture_dir, sum / maxf(_fps_samples.size(), 1), lo, physics_usec])
			get_tree().quit()

func _apply_config() -> void:
	var p: Dictionary = GameConfig.data["physics"]
	sim.segment_count = int(p.segment_count)
	sim.iterations = int(p.iterations)
	sim.gravity = float(p.gravity)
	sim.damping = float(p.damping)
	sim.ufo_drag = float(p.ufo_drag)
	sim.set_ufo_mass(float(p.ufo_mass))
	sim.rope_length_rate = float(p.rope_length_rate)
	sim.swing_gain = float(p.swing_gain)
	var w: Dictionary = GameConfig.data["world"]
	sim.min_rope_length = float(w.rope_min_cm)
	sim.max_rope_length = float(w.rope_max_cm)
	var pr: Dictionary = GameConfig.data["projection"]
	proj.pitch_deg = float(pr.pitch_deg)
	proj.pixels_per_unit = float(pr.pixels_per_unit)
	proj.xy_display_scale = float(pr.xy_display_scale)
	proj.perspective = float(pr.perspective)
	proj.depth_scale = float(pr.depth_scale)

func _layout() -> void:
	var vs := get_viewport_rect().size
	# Anchor origin: horizontally centred in the play area (left of the debug
	# panel when it is visible), near the top.
	var play_w := vs.x
	if debug_ui != null and debug_ui.visible:
		play_w = vs.x - debug_ui.panel_width()
	_play_w = play_w
	_update_origin()

var _play_w := 1280.0

## The anchor's screen origin: horizontally centred in the play area and far
## enough below the top edge that the rearmost crane position (world -Z,
## which projects upward) is still on screen.
func _update_origin() -> void:
	var travel_z: float = GameConfig.data.world.travel_z_cm
	var lift := 0.5 * travel_z * proj.xy_display_scale * proj.depth_scale * sin(deg_to_rad(proj.pitch_deg)) * proj.pixels_per_unit
	proj.origin_px = Vector2(_play_w * 0.5, 20.0 + lift)

## Select which robot source drives the rope.
func use_source(src: String) -> void:
	if src == "websocket":
		mock.enabled = false
		ws.enabled = true
		RobotState.source = "websocket"
		RobotState.connected = false
	else:
		ws.enabled = false
		mock.enabled = true
		mock.set_connected(true)
		RobotState.source = "mock"

func _physics_process(dt: float) -> void:
	_handle_keys(dt)
	var now := Time.get_ticks_msec()
	var pose := RobotState.interpolated_pose(now)
	var anchor := RobotState.anchor_for_xy(pose.x, pose.y)
	sim.target_rope_length = RobotState.rope_length_for_z(pose.z)
	if not _initialised:
		sim.anchor = anchor
		sim.rope_length = sim.target_rope_length
		sim.reset()
		_initialised = true
	elif (anchor - _last_anchor).length() > 25.0:
		# Teleport (first sample after reconnect etc): carry the rope along so it
		# does not whip across the screen.
		sim.translate_all(anchor - _last_anchor)
		sim.anchor = anchor
	else:
		sim.anchor = anchor
	_last_anchor = anchor
	sim.step(dt)
	physics_usec = sim.last_step_usec

func _process(dt: float) -> void:
	_capture_tick(dt)
	_update_origin()
	rope_view.update_rope(sim, proj)
	var r := proj.project(sim.ufo_position())
	ufo.position = r.screen
	# screen-space cues for the character
	var tangent := sim.end_tangent()
	var tip := proj.project(sim.ufo_position() - tangent * 3.0).screen
	var dir := (r.screen - tip)
	var tangent_angle := 0.0
	if dir.length_squared() > 1e-6:
		tangent_angle = atan2(dir.x, dir.y) * -1.0 # 0 = straight down, + when leaning right
	if dt > 0.0:
		_ufo_screen_vel = (r.screen - _prev_ufo_screen) / dt
		var anchor_screen := proj.project(sim.anchor).screen
		var av := (anchor_screen - _prev_anchor_screen) / dt
		_anchor_screen_accel = (av - _prev_anchor_screen_vel) / dt
		_prev_anchor_screen_vel = av
		_prev_anchor_screen = anchor_screen
		_depth_vel = (sim.anchor.z - _prev_depth) / dt
		_prev_depth = sim.anchor.z
	_prev_ufo_screen = r.screen
	ufo.mood = _mood()
	ufo.update_motion(tangent_angle, _ufo_screen_vel.x, _depth_vel, _anchor_screen_accel, r.scale, dt)
	effects.position = r.screen
	effects.scale = Vector2.ONE * r.scale

func _mood() -> String:
	match GameState.state:
		"DISCONNECTED", "BOOT":
			return "DISCONNECTED"
		"ERROR":
			return "ERROR"
		"RESULT":
			return "SUCCESS" if GameState.result_success else "FAILURE"
		"GRABBING":
			return "GRABBING"
		"LOWERING":
			return "Z_LOWERING"
		"RAISING":
			return "Z_RAISING"
		"MOVING", "HOMING":
			var av := sim.anchor_velocity()
			if absf(av.z) > absf(av.x) * 1.2 and absf(av.z) > 2.0:
				return "MOVING_BACKWARD" if av.z < 0.0 else "MOVING_FORWARD"
			return "MOVING_XY"
		_:
			return "IDLE"

func _on_game_state_changed(_prev: String, cur: String) -> void:
	if cur == "RESULT":
		effects.burst("sparkles" if GameState.result_success else "motion_lines")

func _handle_keys(dt: float) -> void:
	if RobotState.source != "mock" or not mock.enabled:
		return
	var d := Vector3.ZERO
	if Input.is_key_pressed(KEY_RIGHT):
		d.x += 1
	if Input.is_key_pressed(KEY_LEFT):
		d.x -= 1
	if Input.is_key_pressed(KEY_UP):
		d.y += 1
	if Input.is_key_pressed(KEY_DOWN):
		d.y -= 1
	var zsign := 1.0 if GameConfig.robot().z_up_is_positive else -1.0
	if Input.is_key_pressed(KEY_W):
		d.z += zsign
	if Input.is_key_pressed(KEY_S):
		d.z -= zsign
	if d != Vector3.ZERO:
		var t := mock.target
		t.x += d.x * jog_speed_mm * dt
		t.y += d.y * jog_speed_mm * dt
		t.z += d.z * jog_speed_z * dt
		mock.set_target(t)
		if debug_ui != null:
			debug_ui.sync_targets_from_mock()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_SPACE:
				if mock.enabled:
					mock.emergency_stop()
			KEY_F1, KEY_TAB:
				debug_ui.visible = not debug_ui.visible
				_layout()
			KEY_G:
				GameState.post_event("result_success")
			KEY_F:
				GameState.post_event("result_failure")
