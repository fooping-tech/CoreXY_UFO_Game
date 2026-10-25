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
var ufo_fx: UfoFx
var sfx: Sfx
var shake: ScreenShake
var cameras: CameraHub
var scope: ScopeView
var scope_trigger := ScopeTrigger.new()
var scope_enabled := true
var debug_ui: CanvasLayer

var _initialised := false
var _last_anchor := Vector3.ZERO
var _last_pose := Vector3.ZERO
var _last_travel_x := 0.0
## Rope points of the previous and the latest physics tick. Rendering runs
## faster than 60 Hz, so frames draw a blend of the two instead of showing the
## same tick twice and then jumping.
var _prev_points := PackedVector3Array()
var _cur_points := PackedVector3Array()
var _render_points := PackedVector3Array()
## Character cues, measured once per physics tick with the fixed dt. Taking
## differences per render frame instead gives 0 on frames without a new tick
## and double on the next, which made the face and tilt chatter.
var _cue_prev_ufo := Vector3.ZERO
var _cue_prev_anchor := Vector3.ZERO
var _anchor_screen_vel := Vector2.ZERO
var _anchor_screen_accel := Vector2.ZERO
var _ufo_screen_vel := Vector2.ZERO
var _depth_vel := 0.0
## Motion intensities 0..1 for the sound / particle presentation (per physics tick).
var fx_move := 0.0
var fx_up := 0.0
var fx_down := 0.0
var _fx_prev_rope := -1.0
## Speeds that count as "full" for the presentation: anchor travel (cm/s) and
## rope length change (cm/s). The real W/S jog (15 Z units/s) changes the rope by
## ~8 cm/s.
const FX_MOVE_FULL_CM_S := 15.0
const FX_ROPE_FULL_CM_S := 8.0
var physics_usec: int = 0
## Keyboard jog speed for the mock robot (mm/s)
var jog_speed_mm := 180.0
## Keyboard jog speed for the real robot over WebSocket (mm/s; the backend caps it
## at backend.jog_max_mm_s, the firmware recommends <= 50)
var jog_speed_real_mm := 40.0
## W/S speed for the real arm (z units/s: 0..100 is the whole range). 15 -> ~1840
## servo counts/s with the default z_counts_per_unit; the backend caps it at 2400.
var jog_speed_real_z := 15.0
## The real robot stops by itself ~250 ms after the last jog, so refresh at 20 Hz.
const JOG_REFRESH_S := 0.05
var _jog_refresh_left := 0.0
var _jog_active := false
## Set by Space (stop): arrow keys are ignored until all of them are released,
## so a key still held after Space cannot restart the robot.
var _jog_latched := false
## Why the last arrow-key jog was refused, as the next thing to do ("" = accepted).
var jog_hint := ""
## request ids of moving (non-zero) jogs: only their acceptance clears jog_hint;
## the {0,0} sent on key release is always accepted and says nothing about it.
var _moving_jog_rids := {}
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
	# drawn before (behind) the UFO so the trail never covers its face
	ufo_fx = UfoFx.new()
	ufo_fx.name = "UfoFx"
	ufo_fx.pixel_scale = float(GameConfig.get_value("render", "pixel_scale", 3.0))
	ufo_fx.enabled = bool(GameConfig.get_value("render", "particles", true))
	add_child(ufo_fx)
	cameras = CameraHub.new()
	cameras.name = "Cameras"
	add_child(cameras)
	# the scope view: behind the UFO, so a UFO still swinging passes in front of it
	scope = ScopeView.new()
	scope.name = "Scope"
	add_child(scope)
	scope.attach(cameras)
	var sc = GameConfig.get_value("camera", "scope", {})
	if sc is Dictionary:
		scope_enabled = bool(sc.get("enabled", true))
		scope_trigger.settle_s = float(sc.get("settle_s", 0.7))
		scope_trigger.hold_s = float(sc.get("hold_s", 10.0))
		scope.zoom = float(sc.get("zoom", 1.0))
	ufo = UfoScene.instantiate()
	ufo.name = "UFO"
	ufo.pixel_scale = float(GameConfig.get_value("render", "pixel_scale", 3.0))
	add_child(ufo)
	effects = Node2D.new()
	effects.name = "Effects"
	effects.set_script(load("res://scripts/ui/effects.gd"))
	add_child(effects)
	sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	shake = ScreenShake.new()
	shake.name = "ScreenShake"
	shake.enabled = bool(GameConfig.get_value("render", "screen_shake", true))
	shake.max_offset_px = float(GameConfig.get_value("render", "shake_max_px", 14.0))
	add_child(shake)
	ufo_fx.kicked.connect(shake.add_trauma)
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
	ws.ack.connect(_on_ws_ack)
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
			"--log-motion":
				# CSV of every physics tick (P) and render frame (R) for debugging
				# jitter: robot samples, playback pose, anchor, UFO, character cues.
				if i + 1 < args.size():
					_open_motion_log(args[i + 1])
			"--quit-after":
				if i + 1 < args.size():
					get_tree().create_timer(float(args[i + 1])).timeout.connect(get_tree().quit)

var _motion_log: FileAccess

func _open_motion_log(path: String) -> void:
	_motion_log = FileAccess.open(path, FileAccess.WRITE)
	if _motion_log == null:
		push_warning("cannot open motion log " + path)
		return
	_motion_log.store_line("kind,usec,dt,src,raw_x,raw_y,raw_z,pose_x,pose_y,pose_z,anchor_x,anchor_z,accel_x,accel_z,rope_target,rope_len,ufo_x,ufo_y,ufo_z,screen_x,screen_y,screen_vel_x,anchor_screen_accel,rotation_deg,face,game_state,play_ms,newest_ms,recv_ms,delay_ms")

func _log_motion(kind: String, dt: float, pose: Vector3) -> void:
	if _motion_log == null:
		return
	var u := sim.ufo_position()
	var acc := sim.anchor_acceleration()
	_motion_log.store_line("%s,%d,%.5f,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.1f,%.1f,%.2f,%s,%s,%.1f,%.1f,%.1f,%.1f" % ([
		kind, Time.get_ticks_usec(), dt, RobotState.source,
		RobotState.x_mm, RobotState.y_mm, RobotState.z_mm, pose.x, pose.y, pose.z,
		sim.anchor.x, sim.anchor.z, acc.x, acc.z, sim.target_rope_length, sim.rope_length,
		u.x, u.y, u.z, ufo.position.x, ufo.position.y, _ufo_screen_vel.x, _anchor_screen_accel.length(),
		rad_to_deg(ufo.rotation), ufo.current_face(), GameState.state] + RobotState.playback_debug()))

func _exit_tree() -> void:
	if _motion_log != null:
		_motion_log.close()

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
	sim.substeps = int(p.substeps)
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
	var w: Dictionary = GameConfig.data.world
	var travel_z: float = w.travel_z_cm
	var lift := 0.5 * travel_z * proj.xy_display_scale * proj.depth_scale * sin(deg_to_rad(proj.pitch_deg)) * proj.pixels_per_unit
	proj.origin_px = Vector2(_play_w * 0.5, 20.0 + lift)
	# The robot's X range spans the play area (RobotState.anchor_for_xy reads it).
	# Done in world units, not by stretching the projection, so the rope and the
	# swing keep their shape. Recomputed every frame: cheap, and it follows window
	# resizes, the debug panel and the projection sliders.
	var ufo_half_px := 32.0 * float(GameConfig.get_value("render", "pixel_scale", 3.0))
	var margin := float(GameConfig.get_value("projection", "edge_margin_px", 24.0))
	w["travel_x_fit_cm"] = fit_travel_x_cm(proj, _play_w, travel_z, float(w.rope_min_cm), float(w.rope_max_cm), ufo_half_px, margin,
		swing_per_travel(float(w.rope_max_cm), proj_swing_speed_mm_s()))

## Fastest the real robot moves in X (mm/s): serial jog cap or the XY feed.
func proj_swing_speed_mm_s() -> float:
	var b: Dictionary = GameConfig.data.get("backend", {})
	return maxf(float(b.get("jog_max_mm_s", 50.0)), float(b.get("xy_feed_mm_min", 900.0)) / 60.0)

## How far the UFO swings past its anchor when the robot stops from `speed_mm_s`,
## per cm of world travel: a pendulum hit by a velocity step dv swings about
## dv * sqrt(L / g), and dv in world units grows with the travel.
static func swing_per_travel(rope_cm: float, speed_mm_s: float) -> float:
	var r := GameConfig.robot()
	var range_mm := maxf(float(r.x_max_mm) - float(r.x_min_mm), 1.0)
	return speed_mm_s / range_mm * sqrt(maxf(rope_cm, 0.0) / 980.0)

## World X travel (cm) that brings the UFO to `margin_px` from both edges of a
## play area `play_w` wide, wherever it is in depth and rope length (rope_min..max), leaving room
## for the swing past the end (`swing_per_cm` of the travel): x projects linearly
## for a given (y, z), so the tightest corner sets the travel.
static func fit_travel_x_cm(p: Projection25D, play_w: float, travel_z: float, rope_min: float, rope_max: float,
		ufo_half_px: float, margin_px: float, swing_per_cm: float = 0.0) -> float:
	var px_per_cm := 0.0
	var max_scale := 0.0
	for z in [-0.5 * travel_z, 0.5 * travel_z]:
		for y in [-rope_min, -rope_max]:  # where the UFO hangs (not the anchor plate)
			var a := p.project(Vector3(0.0, y, z))
			var b := p.project(Vector3(1.0, y, z))
			px_per_cm = maxf(px_per_cm, absf(b.screen.x - a.screen.x))
			max_scale = maxf(max_scale, a.scale)
	var half_px := play_w * 0.5 - ufo_half_px * max_scale - margin_px
	if px_per_cm <= 0.0 or half_px <= 0.0:
		return 1.0
	# anchor at travel/2 plus the swing past it (swing_per_cm * travel) fits half_px
	return half_px / (px_per_cm * (0.5 + swing_per_cm))

## Select which robot source drives the rope.
func use_source(src: String) -> void:
	RobotState.clear_samples()
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
	var pose := RobotState.playback_pose(dt)
	var anchor := RobotState.anchor_for_xy(pose.x, pose.y)
	sim.target_rope_length = RobotState.rope_length_for_z(pose.z)
	var travel_x := RobotState.travel_x_cm()
	if _initialised and not is_equal_approx(travel_x, _last_travel_x):
		# The mm -> world mapping changed (window resize, debug panel, projection
		# sliders), not the robot: move the rope with the anchor's new place for the
		# last pose, without velocity, so a layout change does not kick it.
		var shift := RobotState.anchor_for_xy(_last_pose.x, _last_pose.y) - _last_anchor
		sim.translate_all(shift)
		sim.anchor = _last_anchor + shift
		_last_anchor += shift
		_reset_render_history()
	_last_travel_x = travel_x
	_last_pose = pose
	if not _initialised:
		sim.anchor = anchor
		sim.rope_length = sim.target_rope_length
		sim.reset()
		_initialised = true
		_reset_render_history()
	elif (anchor - _last_anchor).length() > 25.0:
		# Teleport (first sample after reconnect etc): carry the rope along so it
		# does not whip across the screen.
		sim.translate_all(anchor - _last_anchor)
		sim.anchor = anchor
		_reset_render_history()
	else:
		sim.anchor = anchor
	_last_anchor = anchor
	sim.step(dt)
	physics_usec = sim.last_step_usec
	_store_tick(dt)
	_log_motion("P", dt, pose)

## Start the render/cue history from the current rope (no blend, no velocity).
func _reset_render_history() -> void:
	_cur_points.resize(sim.points.size())
	for i in range(sim.points.size()):
		_cur_points[i] = sim.points[i].position
	_prev_points = _cur_points.duplicate()
	_cue_prev_ufo = sim.ufo_position()
	_cue_prev_anchor = sim.anchor
	_anchor_screen_vel = Vector2.ZERO
	_fx_prev_rope = sim.rope_length

func _store_tick(dt: float) -> void:
	_prev_points = _cur_points.duplicate()
	if _cur_points.size() != sim.points.size():
		_reset_render_history()
	for i in range(sim.points.size()):
		_cur_points[i] = sim.points[i].position
	# Both ends of each difference go through the current projection, so a
	# layout change (origin_px) does not read as motion.
	var u := sim.ufo_position()
	_ufo_screen_vel = (proj.project(u).screen - proj.project(_cue_prev_ufo).screen) / dt
	var av := (proj.project(sim.anchor).screen - proj.project(_cue_prev_anchor).screen) / dt
	_anchor_screen_accel = (av - _anchor_screen_vel) / dt
	_anchor_screen_vel = av
	_depth_vel = sim.anchor_velocity().z
	_cue_prev_ufo = u
	_cue_prev_anchor = sim.anchor
	var rope_rate := 0.0 if _fx_prev_rope < 0.0 else (sim.rope_length - _fx_prev_rope) / dt
	_fx_prev_rope = sim.rope_length
	var fx := motion_intensities(sim.anchor_velocity(), rope_rate)
	fx_move = fx.x
	fx_up = fx.y
	fx_down = fx.z

## Presentation intensities 0..1 from the physics: (sideways move, UFO rising,
## UFO sinking). A longer rope means the UFO sinks (arm up), a shorter one that it
## rises (arm down).
static func motion_intensities(anchor_vel: Vector3, rope_rate_cm_s: float) -> Vector3:
	var move := clampf(Vector2(anchor_vel.x, anchor_vel.z).length() / FX_MOVE_FULL_CM_S, 0.0, 1.0)
	var rise := clampf(-rope_rate_cm_s / FX_ROPE_FULL_CM_S, 0.0, 1.0)
	var sink := clampf(rope_rate_cm_s / FX_ROPE_FULL_CM_S, 0.0, 1.0)
	return Vector3(move, rise, sink)

func _process(dt: float) -> void:
	_capture_tick(dt)
	_update_origin()
	if _cur_points.is_empty():
		return
	# Blend the last two physics ticks; rope and UFO use the same points.
	var alpha := Engine.get_physics_interpolation_fraction()
	var n := _cur_points.size()
	_render_points.resize(n)
	for i in range(n):
		_render_points[i] = _prev_points[i].lerp(_cur_points[i], alpha)
	rope_view.update_rope(_render_points, proj)
	var ufo_world := _render_points[n - 1]
	var r := proj.project(ufo_world)
	ufo.position = r.screen
	# screen-space rope angle at the UFO for the character's tilt
	var tangent := (ufo_world - _render_points[n - 2]).normalized()
	var tip := proj.project(ufo_world - tangent * 3.0).screen
	var dir := (r.screen - tip)
	var tangent_angle := 0.0
	if dir.length_squared() > 1e-6:
		tangent_angle = atan2(dir.x, dir.y) * -1.0 # 0 = straight down, + when leaning right
	ufo.mood = _mood()
	ufo.update_motion(tangent_angle, _ufo_screen_vel.x, _depth_vel, _anchor_screen_accel, r.scale, dt)
	effects.position = r.screen
	effects.scale = Vector2.ONE * r.scale
	# the saucer's body hangs below the rope end (attachment near the sprite top)
	var body_px := r.screen + Vector2(0.0, 27.0 * ufo.pixel_scale * r.scale)
	ufo_fx.update_fx(body_px, r.scale, _ufo_screen_vel, fx_move, fx_up, fx_down, dt)
	sfx.update_sfx(fx_move, fx_up, fx_down, dt)
	_update_scope(dt)
	_log_motion("R", dt, Vector3.ZERO)

## The telescope moment: the trigger decides, the UFO peers through its
## spyglass and the round focus-camera view opens on the right.
func _update_scope(dt: float) -> void:
	var lowering := GameState.state in ["LOWERING", "GRABBING"]
	var want := scope_trigger.step(fx_move, maxf(fx_up, fx_down), lowering, dt) and scope_enabled
	scope.wanted = want
	ufo.peering = want
	if want and scope.open_amount == 0.0:
		_place_scope()
	scope.beam_from = ufo.global_transform * ufo.lens_offset()
	scope.show_beam = ufo.current_face() == "telescope"
	scope.locking = fx_up > 0.05 or GameState.state in ["LOWERING", "GRABBING"]
	var r := GameConfig.robot()
	var z_span := float(r.z_max_mm) - float(r.z_min_mm)
	scope.z_level = (RobotState.z_mm - float(r.z_min_mm)) / z_span if z_span > 0.0 else -1.0
	if z_span > 0.0 and not r.z_up_is_positive:
		scope.z_level = 1.0 - scope.z_level  # the gauge shows the arm height
	scope.readout = "X %6.1f  Y %6.1f  Z %5.1f" % [RobotState.x_mm, RobotState.y_mm, RobotState.z_mm]
	scope.step(dt)

## Where the scope opens: next to the UFO on its right, or on its left when the
## UFO is too far right (it then looks left). Fixed while open.
func _place_scope() -> void:
	var vs := get_viewport_rect().size
	var r := clampf(minf(_play_w * 0.15, vs.y * 0.24), 80.0, 200.0)
	# x where the UFO comes to rest (under the anchor; it may still be swinging), y of its body
	var body := ufo.global_position + Vector2(0.0, 27.0 * ufo.pixel_scale)
	var rest_x := proj.project(Vector3(sim.anchor.x, sim.ufo_position().y, sim.anchor.z)).screen.x
	var placed := scope_placement(_play_w, vs.y, r, Vector2(rest_x, body.y))
	scope.radius = r
	scope.center = Vector2(placed.x, placed.y)
	ufo.peer_left = placed.z < 0.0

## Scope centre (x, y) and side (z: +1 right of the UFO, -1 left) for a disc of
## radius `r` next to a UFO resting at `ufo_px` in a play area `play_w` x `h`.
## Leaves room for the brackets (r + 46) and the Z gauge on the right.
static func scope_placement(play_w: float, h: float, r: float, ufo_px: Vector2) -> Vector3:
	var gap := 90.0  # UFO body half-width, the spyglass and some leftover swing
	var right_min := ufo_px.x + gap + r + 46.0
	var right_max := play_w - r - 46.0 - 40.0
	var side := 1.0 if right_min <= right_max else -1.0
	var x := right_min if side > 0.0 else ufo_px.x - gap - r - 46.0
	x = clampf(x, r + 50.0, maxf(right_max, r + 50.0))
	var y := clampf(ufo_px.y - r * 0.3, r + 60.0, maxf(h - r - 80.0, r + 60.0))
	return Vector3(x, y, side)

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
		shake.add_trauma(0.6)

func _on_ws_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if str(data.get("command", "")) != "jog":
		return
	var moving := _moving_jog_rids.has(rid)
	_moving_jog_rids.erase(rid)
	if not ok:
		jog_hint = jog_hint_for(str(data.get("reason", "")))
	elif moving:
		jog_hint = ""

## A refused jog, said as what to do next (the backend refuses before anything
## reaches the serial line, so otherwise the keys just seem dead).
static func jog_hint_for(reason: String) -> String:
	var r := reason.to_lower()
	if r.is_empty():
		return ""
	if r.contains("not connected"):
		return "実機に未接続（バックエンドとシリアルを確認）"
	if r.contains("motors not enabled"):
		return "モーターが無効:「Backend: enable motors」を押す"
	if r.contains("alarm"):
		return "アラーム中:「clear_alarm」→「home」を押す"
	if r.contains("not homed") or r.contains("not_homed"):
		return "原点復帰が必要:「home」を押す"
	if r.contains("busy"):
		return "ほかの移動を実行中: 終わるまで待つか Space で止める"
	return "JOG が拒否された: " + reason

## Velocity (mm/s, robot X/Y) for the arrow keys: diagonals keep the same speed.
static func jog_velocity(dir: Vector2, speed: float) -> Vector2:
	return Vector2.ZERO if dir == Vector2.ZERO else dir.normalized() * speed

## Held jog keys as robot axes: x/y from the arrows, z from W/S (+1 = larger z,
## i.e. W raises the arm whatever z_up_is_positive says).
func _jog_input() -> Vector3:
	var d := Vector3.ZERO
	if not get_window().has_focus():
		return d  # keys of an unfocused window must not keep the robot moving
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
	return d

## Jog keys, or zero while stopped by Space and a key is still held.
func _latched_jog_input() -> Vector3:
	var d := _jog_input()
	_jog_latched = jog_latch(_jog_latched, d != Vector3.ZERO)
	return Vector3.ZERO if _jog_latched else d

## Latch after a stop: stays set while any jog key is held, clears once all are released.
static func jog_latch(latched: bool, any_held: bool) -> bool:
	return latched and any_held

## Real robot: dead-man jog. While an arrow key or W/S is held send `jog` every
## 50 ms (XY in mm/s, Z in z-units/s); on release send one zero `jog` (stops at
## once). Never retried: if messages stop, the firmware stops by itself.
func _handle_real_jog(dt: float) -> void:
	var d := _latched_jog_input()
	var v := jog_velocity(Vector2(d.x, d.y), jog_speed_real_mm)
	var vz := d.z * jog_speed_real_z
	if not ws.enabled or not ws.is_open():
		_jog_active = false
		return
	if v == Vector2.ZERO and vz == 0.0:
		if _jog_active:
			ws.send_command("jog", {"vx": 0.0, "vy": 0.0, "vz": 0.0})
			_jog_active = false
		_jog_refresh_left = 0.0
		return
	_jog_refresh_left -= dt
	if _jog_refresh_left <= 0.0:
		_jog_refresh_left = JOG_REFRESH_S
		var rid: String = ws.send_command("jog", {"vx": v.x, "vy": v.y, "vz": vz})
		_moving_jog_rids[rid] = true
		if _moving_jog_rids.size() > 64:  # acks lost on a disconnect must not pile up
			_moving_jog_rids.erase(_moving_jog_rids.keys()[0])
		_jog_active = true

func _handle_keys(dt: float) -> void:
	if RobotState.source == "websocket":
		_handle_real_jog(dt)
		return
	if not mock.enabled:
		return
	var d := _latched_jog_input()
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
				_jog_latched = _jog_input() != Vector3.ZERO
				if mock.enabled:
					mock.emergency_stop()
				if ws.enabled and ws.is_open():
					# decelerating stop, no alarm (the debug panel's E-STOP sends ABORT)
					_jog_active = false
					ws.send_command("soft_stop")
			KEY_F1, KEY_TAB:
				debug_ui.visible = not debug_ui.visible
				_layout()
			KEY_V:
				scope_trigger.toggle()
			KEY_G:
				GameState.post_event("result_success")
			KEY_F:
				GameState.post_event("result_failure")
