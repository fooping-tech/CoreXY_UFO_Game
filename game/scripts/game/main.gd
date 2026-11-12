extends Node2D
## Main scene: wires RobotState -> rope anchor/length -> RopeSimulator ->
## Projection25D -> RopeView + UfoCharacter. Also hosts MockRobot, the
## WebSocket client and the debug overlay.

const UfoScene := preload("res://scenes/ufo.tscn")
const DebugScene := preload("res://scenes/debug.tscn")
const StudyClientScript := preload("res://scripts/study/study_client.gd")
const HomeworkClientScript := preload("res://scripts/study/homework_client.gd")

## A line for the debug panel's log (keyboard jog start/stop, ignored keys...).
signal debug_log(text: String)

var sim := RopeSimulator.new()
var proj := Projection25D.new()
var rope_view: RopeView
var ufo: UfoCharacter
var mock: MockRobot
var ws: UfoWebSocketClient
var background: Node2D
var effects: Node2D
var vfx: VfxDirector
## request id of a claw close sent to the backend: its ACK is the "claw_closed" moment
var _claw_close_rid := ""
var ufo_fx: UfoFx
var sfx: Sfx
var shake: ScreenShake
var cameras: CameraHub
var study: Node
var homework: Node
## UFOくん 勉強モード (#86): the experience (F5 / --study-mode) and its screen
var study_mode: StudyModeController
var study_hud: StudyHud
## The title screen (#90): study mode or game mode at start; Esc comes back to it
var title: TitleScreen
var settings: SettingsScreen
var scope: ScopeView
var scope_trigger := ScopeTrigger.new()
var scope_enabled := true
var debug_ui: CanvasLayer
## Hand joystick (pinch). Its events come from the backend (`--gesture`): over
## `ws` when the backend drives the robot, over the listen-only `vision_ws`
## while the game drives its own MockRobot, or from the mouse (`gesture_sim`).
var gesture := GestureControl.new()
var vision_ws: UfoWebSocketClient
var gesture_hud: GestureHud
## The mouse stands in for the hand: left button = pinch (no camera needed).
var gesture_sim := false
var _sim_seq := 0
## The real robot may be driven by the gesture (config gesture.allow_real_robot).
var gesture_allow_real := false
## Why the gesture may not move the robot now ("" = it may).
var gesture_gate_reason := ""
## Who drove the crane on the last tick (ControlArbiter source).
var control_source := "none"
var _lost_since_ms := -1.0
## --gesture-demo clock (s; < 0 = off).
var _gesture_demo_t := -1.0
## The gesture stops when the game window loses focus (off for the scripted
## demo and the headless tests, which have no focused window).
var gesture_require_focus := true
## The "hand seen" cue at most this often (a hand at the edge of the view flickers).
const HAND_CUE_GAP_MS := 600
var _hand_cue_ms := -100000
const GATE_FOCUS := "ゲームのウィンドウを選んでね"

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
## Last keyboard jog sent to the arbiter, and whether "no focus" was logged, so the
## debug log gets one line per change instead of one per tick.
var _kb_logged := Vector3.ZERO
var _unfocused_logged := false
var _typing_logged := false
## Why the last arrow-key jog was refused, as the next thing to do ("" = accepted).
var jog_hint := ""
## request ids of moving (non-zero) jogs: only their acceptance clears jog_hint;
## the {0,0} sent on key release is always accepted and says nothing about it.
var _moving_jog_rids := {}
var jog_speed_z := 50.0
## Claw step for the [ / ] keys (degrees).
var arm_step_deg := 5.0
## Held on-screen Z buttons in the debug panel: +1 = like W (arm up), -1 = like S.
## Dead-man: cleared as soon as the left mouse button is up.
var ui_jog_z := 0.0
## Catch button (C / the hardware tab): one press = one `auto_catch` request. The
## backend runs the sequence and guards it (preconditions, its own debounce); here
## a press is also ignored within the debounce time, while one is running, or
## while the last request has no answer yet.
var _auto_catch_last_ms := -1.0e9
var _auto_catch_rid := ""
var auto_catch_hint := ""
var _overview_flip_v := false

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
	ufo_fx.amount = float(GameConfig.get_value("render", "particle_amount", 1.0))
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
	# pixelfx VFX on this scene (so they shake with it), driven by GameState
	VFXManager.layer = self
	VFXManager.enabled = bool(GameConfig.get_value("render", "vfx", true))
	vfx = VfxDirector.new()
	vfx.name = "VfxDirector"
	add_child(vfx)
	vfx.setup(self)
	sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	shake = ScreenShake.new()
	shake.name = "ScreenShake"
	shake.enabled = bool(GameConfig.get_value("render", "screen_shake", true))
	shake.max_offset_px = float(GameConfig.get_value("render", "shake_max_px", 12.0))
	add_child(shake)
	ufo_fx.kicked.connect(shake.add_trauma)
	mock = MockRobot.new()
	mock.name = "MockRobot"
	add_child(mock)
	ws = UfoWebSocketClient.new()
	ws.name = "WebSocket"
	add_child(ws)
	vision_ws = UfoWebSocketClient.new()
	vision_ws.name = "VisionLink"
	vision_ws.listen_only = true
	add_child(vision_ws)
	gesture.configure(GameConfig.data.get("gesture", {}))
	var ovc = GameConfig.get_value("camera", "overview", {})
	_overview_flip_v = ovc is Dictionary and bool(ovc.get("flip_v", false))
	gesture_allow_real = bool(GameConfig.get_value("gesture", "allow_real_robot", false))
	ws.hand_control.connect(_on_hand_control.bind(ws))
	vision_ws.hand_control.connect(_on_hand_control.bind(vision_ws))
	ws.disconnected.connect(func(): gesture.reset_stream("ws_disconnect"))
	ws.ack.connect(_on_claw_ack)
	vision_ws.disconnected.connect(func(): gesture.reset_stream("ws_disconnect"))
	if bool(GameConfig.get_value("study", "enabled", false)):
		study = StudyClientScript.new()
		study.name = "StudyClient"
		add_child(study)
		study.setup(cameras)
	if bool(GameConfig.get_value("homework", "enabled", false)):
		homework = HomeworkClientScript.new()
		homework.name = "HomeworkClient"
		add_child(homework)
		homework.setup(cameras, ws)
	gesture.state_changed.connect(_on_gesture_state)
	gesture.claw_requested.connect(_on_gesture_claw)
	var hud_layer := CanvasLayer.new()
	hud_layer.name = "GestureHudLayer"
	hud_layer.layer = 4
	add_child(hud_layer)
	gesture_hud = GestureHud.new()
	gesture_hud.name = "GestureHud"
	gesture_hud.gesture = gesture
	hud_layer.add_child(gesture_hud)
	var ov = GameConfig.get_value("camera", "overview", {})
	if ov is Dictionary:
		gesture_hud.attach(cameras, bool(ov.get("flip_h", false)), bool(ov.get("flip_v", false)))
	else:
		gesture_hud.attach(cameras)
	debug_ui = DebugScene.instantiate()
	debug_ui.name = "DebugUI"
	add_child(debug_ui)
	debug_ui.setup(self)
	if bool(GameConfig.get_value("study_mode", "enabled", false)):
		_setup_study_mode()
	title = TitleScreen.new()
	title.name = "TitleScreen"
	add_child(title)
	title.setup()
	title.chosen.connect(_on_title_chosen)
	title.settings_requested.connect(open_settings)
	settings = SettingsScreen.new()
	settings.name = "SettingsScreen"
	add_child(settings)
	settings.setup()
	settings.closed.connect(_on_settings_closed)
	GameState.state_changed.connect(_on_game_state_changed)
	ws.ack.connect(_on_ws_ack)
	get_viewport().size_changed.connect(_layout)
	_layout()
	set_gesture_enabled(bool(GameConfig.get_value("gesture", "enabled", false)))
	_apply_cmdline()

## The study mode reuses the homework watch (HomeworkClient); without the F1 panel's
## one (homework.enabled false) it gets its own, kept out of the game's helper keys.
func _setup_study_mode() -> void:
	var hw: HomeworkClient = homework
	if hw == null:
		hw = HomeworkClientScript.new()
		hw.name = "StudyHomeworkClient"
		add_child(hw)
		hw.setup(cameras, ws)
		hw.helper_offer = false  # the study mode has its own HELP
	study_mode = StudyModeController.new()
	study_mode.name = "StudyMode"
	add_child(study_mode)
	study_mode.setup(self, hw)
	study_hud = StudyHud.new()
	study_hud.name = "StudyHud"
	add_child(study_hud)
	study_hud.setup(study_mode)
	if bool(GameConfig.get_value("study_mode", "autostart", false)):
		study_mode.call_deferred("start")

## The title at start unless the start is already decided (a scenario, a capture, the study
## mode by argument or by study_mode.autostart) or nobody looks (headless: the tests and CI).
## --title shows it anyway, --no-title never.
static func title_on_start(args: PackedStringArray, enabled: bool, headless: bool, study_autostart: bool) -> bool:
	if args.has("--title"):
		return true
	if not enabled or headless or study_autostart:
		return false
	for a in ["--no-title", "--scenario", "--capture", "--log-motion", "--gesture-demo", "--study-mode", "--study-demo"]:
		if args.has(a):
			return false
	return true

var _debug_layer := 1
var _debug_before_title := false

## Back to the title (Esc, and at start): the study mode stops (its backend sequence too),
## the hand stick lets go, and main holds the manual controls while it shows. The debug
## panel goes above the title (hidden; F1 / Tab shows it there, STOP / E-STOP clickable).
func show_title() -> void:
	if study_mode != null and study_mode.active():
		study_mode.stop()
	if gesture.is_active():
		gesture.stop("title")
	if not title.active():
		_debug_layer = debug_ui.layer
		_debug_before_title = debug_ui.visible
	debug_ui.layer = title.layer + 2  # above the title and the settings screen
	_set_debug_visible(false)
	title.open()

## The gear on the title (#93). Only over the title: the arm is held meanwhile.
func open_settings() -> void:
	if not title_active() or settings.active():
		return
	settings.layer = title.layer + 1
	settings.open()

func settings_active() -> bool:
	return settings != null and settings.active()

func _on_settings_closed(saved: bool) -> void:
	debug_log.emit("settings: " + ("saved" if saved else "cancelled"))
	if saved:
		apply_live_settings()
		title.set_notice("設定を保存しました（「今すぐ」の項目は反映済み。ほかは次の起動から）")

## The settings marked "now" in game_config.json's settings_screen section (#93).
## Presentation only: sounds, effects, the hand-reading scheme, the study mode's choices.
func apply_live_settings() -> void:
	sfx.enabled = bool(GameConfig.value("audio.enabled", true))
	sfx.volume_db = float(GameConfig.value("audio.volume_db", -8.0))
	shake.enabled = bool(GameConfig.value("render.screen_shake", true))
	ufo_fx.enabled = bool(GameConfig.value("render.particles", true))
	var sch := str(GameConfig.value("gesture.scheme", gesture.scheme.id()))
	if sch != gesture.scheme.id():
		gesture.set_scheme(sch)  # a forced stop of the hand stick (it is held on the title anyway)
	if study_mode != null:
		study_mode.reload_settings()

func _set_debug_visible(on: bool) -> void:
	if debug_ui.visible != on:
		debug_ui.visible = on
		debug_ui.study_panel_visibility_changed(on)
		_layout()

func title_active() -> bool:
	return title != null and title.active()

func _on_title_chosen(mode: String) -> void:
	debug_log.emit("title: " + mode)
	debug_ui.layer = _debug_layer
	_set_debug_visible(_debug_before_title or debug_ui.visible)
	if mode == "study":
		if study_mode == null:
			_setup_study_mode()
		if not study_mode.active():
			study_mode.start()
	elif study_mode != null and study_mode.active():
		study_mode.stop()

func _title_status() -> String:
	if RobotState.source != "websocket":
		return "アーム: ゲーム内の仮想クレーン"
	if not ws.is_open():
		return "アーム: バックエンドにつながっていない"
	return "アーム: バックエンド（%s）  モーターは「実機」タブで有効にするまで動かない" % RobotState.machine_state

## `godot --path game -- --scenario x_sweep --source websocket --hide-debug`
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	if title_on_start(args, bool(GameConfig.get_value("title_screen", "enabled", true)),
			DisplayServer.get_name() == "headless",
			study_mode != null and bool(GameConfig.get_value("study_mode", "autostart", false))):
		show_title()
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
			"--gesture":
				set_gesture_enabled(true)
			"--no-gesture":
				# start.sh always says --gesture or --no-gesture; the config's gesture.enabled
				# is only the default of a game started without it
				set_gesture_enabled(false)
			"--gesture-scheme":
				# how the hand is read: pinch_joystick / pose_direction (config gesture.scheme)
				if i + 1 < args.size():
					gesture.set_scheme(args[i + 1])
			"--gesture-demo":
				# a scripted hand (pinch, steer, release, lose it) through the gesture path
				_gesture_demo_t = 0.0
				set_gesture_enabled(true)
				gesture_require_focus = false
			"--study-mode", "--study-demo":
				# the study mode right away; --study-demo <simulated|camera> also picks what it
				# uses (mock / real still read: mock = simulated, real = camera)
				if study_mode == null:
					_setup_study_mode()
				if args[i] == "--study-demo" and i + 1 < args.size():
					study_mode.services.set_mode(args[i + 1])
				study_mode.call_deferred("start")
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
	gesture.reset_stream("source_changed")
	_update_vision_link()

func _physics_process(dt: float) -> void:
	_handle_input(dt)
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
	if title_active():
		title.set_status(_title_status())
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
	_update_gesture_presentation(dt)
	_log_motion("R", dt, Vector3.ZERO)

## The telescope moment: the trigger decides, the UFO peers through its
## spyglass and the round focus-camera view opens on the right.
func _update_scope(dt: float) -> void:
	var lowering := GameState.state in ["LOWERING", "GRABBING"]
	var want := scope_trigger.step(fx_move, maxf(fx_up, fx_down), lowering, dt) and scope_enabled
	# not while the hand joystick has the crane (the UFO shows the steering then)
	want = want and not gesture.state in [GestureControl.State.ARMED, GestureControl.State.ACTIVE]
	# the study mode's close-ups: the arm camera's real frames in the round view (the mock
	# demo draws its own close-up, and the game's telescope moment waits meanwhile)
	if study_mode != null and study_mode.active():
		want = study_mode.wants_scope() and cameras.has_feed("focus") and study_mode.services.mode != "simulated"
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
	# keep clear of the gesture HUD at the bottom
	var h := vs.y - (GestureHud.SIZE.y + 44.0 if gesture.enabled else 0.0)
	var placed := scope_placement(_play_w, h, r, Vector2(rest_x, body.y))
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
	if study_mode != null:
		var o := study_mode.mood_override()
		if o != "":
			return o
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
	if rid != "" and rid == _auto_catch_rid:
		_auto_catch_rid = ""
		auto_catch_hint = "" if ok else auto_catch_hint_for(str(data.get("reason", "")))
		return
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
		return "モーターが無効:「実機」タブの「モーター有効」を押す"
	if r.contains("alarm"):
		return "アラーム中:「アラーム解除」→「原点復帰 (home)」を押す"
	if r.contains("not homed") or r.contains("not_homed"):
		return "原点復帰が必要:「原点復帰 (home)」を押す"
	if r.contains("busy"):
		return "ほかの移動を実行中: 終わるまで待つか Space で止める"
	return "JOG が拒否された: " + reason

## Catch button debounce (ms) from config/game_config.json auto_catch.<profile>.button_debounce_ms.
func auto_catch_debounce_ms() -> float:
	var ac = GameConfig.data.get("auto_catch", {})
	var prof = ac.get("real" if ws.server_robot == "real" else "dry_run", {}) if ac is Dictionary else {}
	var v = prof.get("button_debounce_ms") if prof is Dictionary else null
	return float(v) if v != null else 500.0

## A press counts only when nothing is running or waiting and the debounce time has passed.
static func auto_catch_press_ok(now_ms: float, last_ms: float, debounce_ms: float, active: bool, pending: bool) -> bool:
	return not active and not pending and now_ms - last_ms >= debounce_ms

## The catch button. Every press (accepted or not) restarts the debounce window,
## so a chattering button gives one request.
func request_auto_catch() -> void:
	var now := float(Time.get_ticks_msec())
	var ok := auto_catch_press_ok(now, _auto_catch_last_ms, auto_catch_debounce_ms(), RobotState.auto_catch_active(),
		_auto_catch_rid != "")
	_auto_catch_last_ms = now
	if not ok:
		return
	if RobotState.source != "websocket" or not ws.enabled or not ws.is_open():
		auto_catch_hint = "自動キャッチはバックエンド接続時だけ（実機なしなら ./start.sh mock でドライラン）"
		return
	if _jog_input() != Vector3.ZERO or gesture.is_active():
		auto_catch_hint = "手動操作を止めてから（キーを離す / 指を開く）"
		return
	auto_catch_hint = ""
	_auto_catch_rid = ws.send_command("auto_catch")

## Phase names for the status line.
const AUTO_CATCH_PHASE_JA := {
	"IDLE": "待機", "OPEN_CLAW": "爪を開く", "LOWER_TO_CATCH": "キャッチ位置へ下降", "CLOSE_CLAW": "爪を閉じる",
	"RAISE_WITH_ITEM": "安全高さへ上昇", "MOVE_TO_BOX": "救出ボックスへ移動", "LOWER_TO_RELEASE": "リリース高さへ下降",
	"RELEASE": "爪を開いて落とす", "RAISE_EMPTY": "安全高さへ戻る", "CLAW_STANDBY": "爪を待機位置へ", "FAULT": "異常停止",
}

## One line (or two) about the auto catch for the debug panel: what it is doing, or why it stopped.
static func auto_catch_status_text(ac: Dictionary) -> String:
	if ac.is_empty():
		return "自動キャッチ: 状態なし（バックエンド未接続）"
	var phase := str(ac.get("phase", ""))
	var name := str(AUTO_CATCH_PHASE_JA.get(phase, phase))
	var prof := "ドライラン" if str(ac.get("profile", "")) == "dry_run" else "実機"
	if bool(ac.get("active", false)):
		return "自動キャッチ [%s] %d/%d %s（%s）  %.1f s" % [prof, int(ac.get("step", 0)), int(ac.get("steps", 0)), name, phase,
			float(ac.get("elapsed_s", 0.0))]
	match str(ac.get("last_result", "")):
		"done":
			return "自動キャッチ [%s]: 完了（手動操作に戻った）" % prof
		"fault":
			return "自動キャッチ [%s]: 異常停止 — %s\n→ ABORT 済み。原因を確かめてから「アラーム解除」→「原点復帰」" % [prof, str(ac.get("error", ""))]
	return "自動キャッチ [%s]: 待機（C で開始）" % prof

## A refused auto catch, said as what to do next.
static func auto_catch_hint_for(reason: String) -> String:
	var r := reason.to_lower()
	if r.is_empty() or r.contains("debounced"):
		return ""
	if r.contains("not confirmed") or r.contains("is not set"):
		return "自動キャッチ: 校正値が未設定・未確認（config/game_config.json の auto_catch.real）。実機では動かさない"
	if r.contains("alarm"):
		return "自動キャッチ: アラーム中 →「アラーム解除」→「原点復帰 (home)」"
	if r.contains("not homed"):
		return "自動キャッチ: 先に「原点復帰 (home)」"
	if r.contains("motors not enabled"):
		return "自動キャッチ: 先に「モーター有効」"
	if r.contains("z reference"):
		return "自動キャッチ: Z の基準が未設定（アームを一番上にして「巻き上げ点（上）に」）"
	if r.contains("claw open / closed"):
		return "自動キャッチ: 爪の開き / 閉じ位置を記録する（実機タブ 4）"
	if r.contains("below safe_z"):
		return "自動キャッチ: アームを安全高さまで上げてから（W）"
	if r.contains("busy") or r.contains("already running"):
		return "自動キャッチ: ほかの動作中"
	return "自動キャッチ拒否: " + reason

## Velocity (mm/s, robot X/Y) for the arrow keys: diagonals keep the same speed.
static func jog_velocity(dir: Vector2, speed: float) -> Vector2:
	return Vector2.ZERO if dir == Vector2.ZERO else dir.normalized() * speed

## Held jog keys as robot axes: x/y from the arrows, z from W/S (+1 = larger z,
## i.e. W raises the arm whatever z_up_is_positive says).
func _jog_input() -> Vector3:
	var d := Vector3.ZERO
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		ui_jog_z = 0.0  # a missed button_up (panel hidden mid-press) must not keep it moving
	if not get_window().has_focus():
		if not _unfocused_logged and _any_jog_key():
			debug_log.emit("keys: ignored, the game window has no keyboard focus (click the game)")
			_unfocused_logged = true
		return d  # keys of an unfocused window must not keep the robot moving
	_unfocused_logged = false
	var zsign := 1.0 if GameConfig.robot().z_up_is_positive else -1.0
	if text_entry_focused():
		# typing (the Study question): arrows move the caret, W / S are letters
		if not _typing_logged and _any_jog_key():
			debug_log.emit("keys: ignored while typing in a text field (click the game area to jog)")
			_typing_logged = true
	else:
		_typing_logged = false
		if Input.is_key_pressed(KEY_RIGHT):
			d.x += 1
		if Input.is_key_pressed(KEY_LEFT):
			d.x -= 1
		if Input.is_key_pressed(KEY_UP):
			d.y += 1
		if Input.is_key_pressed(KEY_DOWN):
			d.y -= 1
		if Input.is_key_pressed(KEY_W):
			d.z += zsign
		if Input.is_key_pressed(KEY_S):
			d.z -= zsign
	d.z = clampf(d.z + ui_jog_z * zsign, -1.0, 1.0)
	return d

## A text field has the keyboard: its keys are typing, never jog or hand-shape keys.
func text_entry_focused() -> bool:
	return is_text_entry(get_viewport().gui_get_focus_owner())

static func is_text_entry(c: Control) -> bool:
	return c is TextEdit or c is LineEdit

func _any_jog_key() -> bool:
	for k in [KEY_RIGHT, KEY_LEFT, KEY_UP, KEY_DOWN, KEY_W, KEY_S]:
		if Input.is_key_pressed(k):
			return true
	return false

## Jog keys, or zero while stopped by Space and a key is still held.
func _latched_jog_input() -> Vector3:
	var d := _jog_input()
	_jog_latched = jog_latch(_jog_latched, d != Vector3.ZERO)
	return Vector3.ZERO if _jog_latched else d

## Latch after a stop: stays set while any jog key is held, clears once all are released.
static func jog_latch(latched: bool, any_held: bool) -> bool:
	return latched and any_held

## Real robot: dead-man jog. While a velocity is asked for, send `jog` every
## 50 ms (XY in mm/s, Z in z-units/s); when it drops to zero send one zero `jog`
## (stops at once). Never retried: if messages stop, the firmware stops by itself.
func _send_jog(v: Vector3, dt: float) -> void:
	if not ws.enabled or not ws.is_open():
		_jog_active = false
		return
	if v == Vector3.ZERO:
		if _jog_active:
			ws.send_command("jog", {"vx": 0.0, "vy": 0.0, "vz": 0.0})
			_jog_active = false
		_jog_refresh_left = 0.0
		return
	_jog_refresh_left -= dt
	if _jog_refresh_left <= 0.0:
		_jog_refresh_left = JOG_REFRESH_S
		var rid: String = ws.send_command("jog", {"vx": v.x, "vy": v.y, "vz": v.z})
		_moving_jog_rids[rid] = true
		if _moving_jog_rids.size() > 64:  # acks lost on a disconnect must not pile up
			_moving_jog_rids.erase(_moving_jog_rids.keys()[0])
		_jog_active = true

## Every physics tick: keyboard and hand joystick -> ControlArbiter -> the one
## jog path (real robot) or the MockRobot target.
func _handle_input(dt: float) -> void:
	var real := RobotState.source == "websocket"
	var keys := _latched_jog_input()
	var kb := Vector3.ZERO
	if keys != Vector3.ZERO:
		var xy := jog_velocity(Vector2(keys.x, keys.y), jog_speed_real_mm if real else jog_speed_mm)
		kb = Vector3(xy.x, xy.y, keys.z * (jog_speed_real_z if real else jog_speed_z))
	if kb != _kb_logged:
		if kb == Vector3.ZERO:
			debug_log.emit("keys: jog stop" + (" (latched by Space)" if _jog_latched else ""))
		else:
			debug_log.emit("keys: jog vx %.0f vy %.0f vz %.0f -> %s" % [kb.x, kb.y, kb.z,
				("backend (open)" if ws.is_open() else "backend NOT CONNECTED") if real else "mock"])
		_kb_logged = kb
	# Z: up on the screen raises the arm; the camera view may be shown flipped, the mouse never is
	gesture.joystick.view_flip_v = _overview_flip_v and not gesture_sim
	if gesture_sim:
		_feed_sim_hand()
	elif _gesture_demo_t >= 0.0:
		_gesture_demo_t += dt
		var ev := gesture_demo_event(_gesture_demo_t) if gesture.scheme.uses_stick() else gesture_pose_demo_event(_gesture_demo_t)
		_sim_seq += 1
		ev["sequence"] = _sim_seq
		gesture.on_event(ev, float(Time.get_ticks_msec()))
	gesture_gate_reason = gesture_gate()
	var gv := gesture.tick(Time.get_ticks_msec(), dt, gesture_gate_reason)
	if homework != null and (study_mode == null or not study_mode.active()) and not title_active():
		# a thumbs-up answers the helper's offer (#79) only while the gesture control is off:
		# with it on, the thumb steers (pose_direction) or closes the claw (pinch joystick)
		var age := gesture.age_ms(Time.get_ticks_msec())
		homework.thumb_tick(not gesture.enabled and gesture.detected and gesture.pose == "thumb"
			and age >= 0.0 and age <= gesture.stale_ms, Time.get_ticks_msec())
	if kb != Vector3.ZERO and gesture.state in [GestureControl.State.ARMED, GestureControl.State.ACTIVE]:
		gesture.stop("manual")  # the keyboard takes over; the gesture needs a new pinch
		gv = Vector2.ZERO
	var halt := RobotState.machine_state in ["ALARM", "ESTOP"]
	if halt and kb != Vector3.ZERO:
		jog_hint = jog_hint_for("alarm")
	# the title screen: nothing moves the arm until a mode is picked (Space still stops)
	if title_active():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "タイトル画面ではアームを動かせない（モードを選んでから）"
		if gesture.is_active():
			gesture.stop("title")
	# the study mode's HELP / tidy-up owns the arm: no manual jog meanwhile (Space still stops it)
	if study_mode != null and study_mode.blocks_manual_control():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "勉強モードでアームを使っている間は手動操作できない（Space で止める）"
		if gesture.is_active():
			gesture.stop("study_mode")
	# the auto catch owns the crane: no manual jog until it ends (Space / E-STOP still stop it)
	if RobotState.auto_catch_active():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "自動キャッチ中は手動操作できない（Space で中断）"
		if gesture.is_active():
			gesture.stop("auto_catch")
	# gesture Z is "+ = arm up", like W: the same z_up_is_positive sign as the keys
	var gz := gesture.velocity_z * (1.0 if GameConfig.robot().z_up_is_positive else -1.0)
	var d := ControlArbiter.decide(halt, _jog_latched, kb, Vector3(gv.x, gv.y, gz), gesture.is_active())
	control_source = d.source
	var v: Vector3 = d.v
	if real:
		_send_jog(v, dt)
	elif mock.enabled and v != Vector3.ZERO:
		mock.set_target(mock.target + v * dt)
		if debug_ui != null:
			debug_ui.sync_targets_from_mock()

# ------------------------------------------------------------ hand joystick
func set_gesture_enabled(on: bool) -> void:
	gesture.enabled = on
	_update_vision_link()

## The listen-only link to the backend is up only while the gesture needs it:
## gesture on, the game driving its own MockRobot, no mouse simulation.
func _update_vision_link() -> void:
	if vision_ws == null:
		return
	var want := gesture.enabled and RobotState.source == "mock" and not gesture_sim and _gesture_demo_t < 0.0
	if vision_ws.enabled != want:
		vision_ws.enabled = want

func _on_hand_control(data: Dictionary, recv_ms: float, link: UfoWebSocketClient) -> void:
	# only the link that matches the current source counts (and not while simulating)
	if gesture_sim or _gesture_demo_t >= 0.0 or (link == ws) != (RobotState.source == "websocket"):
		return
	gesture.on_event(data, recv_ms)

## A held fist / peace sign: the claw to its recorded position (like A / Q).
func _on_gesture_claw(which: String) -> void:
	var line := "gesture: claw %s" % which
	if is_nan(RobotState.arm_span_deg):
		line += " (positions not recorded: set them in the hardware tab)"
	debug_log.emit(line)
	gesture_hud.flash("爪を閉じる！" if which == "closed" else "爪を開く！", 0.8)
	sfx.play_cue("pinch" if which == "closed" else "release")
	arm_goto(which)

## Debug: a `hand_control` event from the mouse over the play area (left button
## = pinch, right button = a pinch with the palm down (Z); keys 1 / 2 / 3 / 4 / 5
## held = パー / チョキ / グー / 指差し / いいね, the finger or the thumb pointing
## from the play area's centre to the mouse), through the same path as the camera's.
func _feed_sim_hand() -> void:
	var vs := get_viewport_rect().size
	var m := get_viewport().get_mouse_position()
	var inside := m.x >= 0.0 and m.x < _play_w and m.y >= 0.0 and m.y < vs.y and get_window().has_focus()
	var down := inside and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var pinch := inside and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or down)
	var sim_point := (m - Vector2(_play_w, vs.y) * 0.5).normalized()  # image axes: x right, y down
	_sim_seq += 1
	gesture.on_event({"event": "hand_control", "camera_ok": true, "detected": inside, "hand_count": 1 if inside else 0,
		"pinch": pinch, "pinch_finger": "index" if pinch else "", "pose": sim_pose(gesture.scheme.uses_stick(), not text_entry_focused()),
		"point_dx": sim_point.x, "point_dy": sim_point.y, "point_len": 1.0 if sim_point != Vector2.ZERO else 0.0,
		"thumb_dx": sim_point.x, "thumb_dy": sim_point.y, "palm": "down" if down else "up", "hand_x": m.x / _play_w, "hand_y": m.y / vs.y, "pinch_ratio": 0.2 if pinch else 0.8,
		"confidence": 1.0, "in_roi": inside, "reason": "" if inside else "no_hand", "frame_w": _play_w, "frame_h": vs.y,
		"timestamp": int(Time.get_unix_time_from_system() * 1000.0), "sequence": _sim_seq, "latency_ms": 0.0},
		float(Time.get_ticks_msec()))

## The mouse simulation's hand shape: keys 1 / 2 / 3 / 4 / 5 held = open / peace / fist / point / thumb.
## Without a key: an open hand for the pinch stick (its resting hand), "other"
## for a shape scheme (so the crane does not move just because the mouse is there).
static func sim_pose(stick: bool, keys := true) -> String:
	if not keys:
		return "open" if stick else "other"
	if Input.is_physical_key_pressed(KEY_1):
		return "open"
	if Input.is_physical_key_pressed(KEY_2):
		return "peace"
	if Input.is_physical_key_pressed(KEY_3):
		return "fist"
	if Input.is_physical_key_pressed(KEY_4):
		return "point"
	if Input.is_physical_key_pressed(KEY_5):
		return "thumb"
	return "open" if stick else "other"

## The scripted hand of --gesture-demo at `t` seconds (a 7 s loop): open hand,
## pinch, steer to the right and away, back to the centre, release, then pinch
## again and slide out of the view at the right edge (the stop that needs a new pinch).
static func gesture_demo_event(t: float) -> Dictionary:
	var k := fmod(t, 7.0)
	var c := Vector2(0.45, 0.55)
	var p := c
	var pinch := false
	var seen := true
	if k >= 0.6 and k < 4.2:
		pinch = true
		var s := clampf((k - 0.9) / 0.8, 0.0, 1.0) - clampf((k - 3.0) / 0.6, 0.0, 1.0)
		p = c + Vector2(0.12, -0.07) * s
	elif k >= 5.0 and k < 5.8:
		pinch = true
		p = c.lerp(Vector2(0.97, 0.5), clampf((k - 5.0) / 0.6, 0.0, 1.0))  # off the right edge
	elif k >= 5.8:
		seen = false
	return {"event": "hand_control", "camera_ok": true, "detected": seen, "hand_count": 1 if seen else 0,
		"pinch": pinch and seen, "hand_x": p.x, "hand_y": p.y, "pinch_ratio": 0.2 if pinch else 0.8, "confidence": 0.95,
		"in_roi": seen, "reason": "" if seen else "no_hand", "frame_w": 640, "frame_h": 480, "timestamp": 0, "latency_ms": 30.0}

## --gesture-demo for a hand-shape scheme (a 12 s loop, the hand at rest in the
## middle; another shape in between): pointing with the finger turning a full
## circle, a thumbs-up towards the top of the image then the bottom, パー (claw
## open), チョキ (claw closed), グー (rest), then out of the view.
static func gesture_pose_demo_event(t: float) -> Dictionary:
	var k := fmod(t, 12.0)
	var pose := "other"
	var dir := Vector2.ZERO
	var thumb := Vector2.ZERO
	if k >= 0.8 and k < 3.8:
		pose = "point"
		dir = Vector2.from_angle(-PI / 2.0 + TAU * (k - 0.8) / 3.0)  # up in the image, then clockwise
	elif k >= 4.4 and k < 5.6:
		pose = "thumb"
		thumb = Vector2(0.0, -1.0)  # towards the top of the image
	elif k >= 6.2 and k < 7.4:
		pose = "thumb"
		thumb = Vector2(0.0, 1.0)
	elif k >= 8.0 and k < 8.8:
		pose = "open"
	elif k >= 9.4 and k < 10.2:
		pose = "peace"
	elif k >= 10.2 and k < 10.8:
		pose = "fist"
	var seen := k < 10.8
	return {"event": "hand_control", "camera_ok": true, "detected": seen, "hand_count": 1 if seen else 0,
		"pinch": false, "pose": pose if seen else "", "hand_x": 0.45, "hand_y": 0.55, "pinch_ratio": 0.8, "confidence": 0.95,
		"point_dx": dir.x, "point_dy": dir.y, "point_len": 1.0 if dir != Vector2.ZERO else 0.0, "thumb_dx": thumb.x, "thumb_dy": thumb.y,
		"in_roi": seen, "reason": "" if seen else "no_hand", "frame_w": 640, "frame_h": 480, "timestamp": 0, "latency_ms": 30.0}

## Claw test: turn the claw servo by `deg` degrees (relative). The real robot
## gets `arm_step` (SERVO_TURN 2; one step at a time, refused while another
## move runs); the game's own MockRobot just changes its angle.
func arm_step(deg: float) -> void:
	if RobotState.auto_catch_active():
		return  # the sequence drives the claw
	if RobotState.source == "websocket":
		if ws.is_open() and not ws.has_pending_motion():
			ws.send_command("arm_step", {"deg": deg})
	elif mock.enabled:
		mock.arm_deg += deg
		mock._report(true)

## Make the claw's current angle 0 degrees.
func arm_zero() -> void:
	if RobotState.source == "websocket":
		if ws.is_open():
			ws.send_command("arm_zero")
	elif mock.enabled:
		mock.arm_deg = 0.0
		mock._report(true)

## Record the claw's current angle as its "closed" or "open" position (saved by the backend).
func arm_set(which: String) -> void:
	if RobotState.source == "websocket":
		if ws.is_open():
			ws.send_command("arm_set", {"which": which})
	elif mock.enabled:
		mock.arm_marks[which] = mock.arm_deg
		mock._report(true)

## Turn the claw to its recorded "closed" or "open" position.
func arm_goto(which: String) -> void:
	if RobotState.auto_catch_active():
		return  # the sequence drives the claw
	if RobotState.source == "websocket":
		if ws.is_open() and not ws.has_pending_motion():
			var rid := ws.send_command("arm_goto", {"which": which})
			_claw_close_rid = rid if which == "closed" else ""
	elif mock.enabled and mock.arm_marks.size() == 2:
		mock.arm_deg = mock.arm_marks[which]
		mock._report(true)
		if which == "closed":
			GameState.post_event("claw_closed")

## The backend confirmed the claw closed (not just that we asked): the grab moment.
func _on_claw_ack(rid: String, ok: bool, _payload: Dictionary) -> void:
	if rid != "" and rid == _claw_close_rid:
		_claw_close_rid = ""
		if ok:
			GameState.post_event("claw_closed")

## Pinch thresholds to the backend at run time (they are applied where the
## landmarks are, in the backend). Returns false when no link is open.
func send_gesture_config(params: Dictionary) -> bool:
	var link := ws if RobotState.source == "websocket" else vision_ws
	if not link.is_open():
		return false
	link.send_command("gesture_config", params)
	var g: Dictionary = GameConfig.data.get("gesture", {})
	for k in params.keys():
		g[k] = params[k]
	return true

func set_gesture_sim(on: bool) -> void:
	gesture_sim = on
	gesture.reset_stream("source_changed")
	_sim_seq = 0
	_update_vision_link()

## "" when the hand joystick may move the robot now, else why not (shown in the
## HUD). It never starts anything itself: no homing, no motor enabling.
func gesture_gate() -> String:
	if gesture_require_focus and not get_window().has_focus():
		return GATE_FOCUS
	# the steering and the claw poses: nothing while the title shows or something else owns
	# the arm (a claw pose would otherwise still reach arm_goto)
	if title_active():
		return "タイトル画面（モードを選んでから）"
	if study_mode != null and study_mode.blocks_manual_control():
		return "勉強モードがアームを使用中"
	if RobotState.auto_catch_active():
		return "自動キャッチ中"
	if RobotState.machine_state in ["ALARM", "ESTOP"]:
		return "アラーム中:「clear_alarm」→「home」"
	if RobotState.source == "mock":
		return "" if mock.enabled and RobotState.connected else "ロボットに未接続"
	return real_gesture_gate(ws.is_open(), RobotState.connected, ws.server_robot, gesture_allow_real,
		RobotState.motors_enabled, RobotState.homed, RobotState.machine_state == "HOMING" or ws.has_pending_motion())

## The real (backend) robot checks, in the order they must be fixed.
static func real_gesture_gate(ws_open: bool, connected: bool, server_robot: String, allow_real: bool,
		motors: bool, homed: bool, busy: bool) -> String:
	if not ws_open:
		return "バックエンドに未接続"
	if not connected:
		return "実機に未接続"
	if server_robot != "mock" and not allow_real:
		return "実機のジェスチャー操作は無効（gesture.allow_real_robot）"
	if not motors:
		return "モーターを有効にしてください"
	if not homed:
		return "原点復帰（home）してください"
	if busy:
		return "ほかの移動を実行中"
	return ""

func _on_gesture_state(from: int, to: int, why: String) -> void:
	var S := GestureControl.STATE_NAMES
	var line := "gesture: %s -> %s%s" % [S[from], S[to], (" (%s)" % why) if why != "" else ""]
	if debug_ui != null:
		debug_ui._append_log(line)
	var was_live := from in [GestureControl.State.ARMED, GestureControl.State.ACTIVE]
	if was_live:
		# also in the terminal: why a steer ended, with the hand's last numbers
		var ev := gesture.last_event
		print("[%d ms] %s  hands %d pinch_ratio %.2f reason %s latency %.0f ms" % [Time.get_ticks_msec(), line,
			int(ev.get("hand_count", 0)), float(ev.get("pinch_ratio", 0.0)), str(ev.get("reason", "")), float(ev.get("latency_ms", 0.0))])
	match to:
		GestureControl.State.ARMED:
			ufo.flash("excited", 0.7)  # eyes light up on the pinch
			var z_mode := gesture.mode == "z"
			sfx.play_cue("pinch_z" if z_mode else "pinch")  # Z sounds different: no mixing the two up
			gesture_hud.flash("上下モード！" if z_mode else "操縦開始！", 0.6)
		GestureControl.State.ACTIVE:
			ufo.flash("straining", 0.35)  # psyched up
		GestureControl.State.HAND_DETECTED:
			if was_live and why == "released":
				gesture_hud.flash("停止", 0.8)
				sfx.play_cue("release")  # fingers opened: a normal end of steering
			elif from in [GestureControl.State.WAITING_HAND, GestureControl.State.WAITING_RELEASE]:
				# an open hand came into view: a quiet "pon", at most every HAND_CUE_GAP_MS
				var now := Time.get_ticks_msec()
				if now - _hand_cue_ms >= HAND_CUE_GAP_MS:
					_hand_cue_ms = now
					sfx.play_cue("hand")
	# control was cut (not a plain release, not a stop asked for by hand)
	if was_live and to == GestureControl.State.WAITING_RELEASE and why not in ["stop_key", "manual", "disabled", "auto_catch"]:
		sfx.play_cue("lost")
	# lost track / stale / camera gone while driving the real robot: besides the
	# zero jog, a decelerating STOP (no alarm)
	if was_live and to == GestureControl.State.WAITING_RELEASE and why in ["stale", "camera_lost", "no_events", GATE_FOCUS] \
			and RobotState.source == "websocket" and ws.is_open():
		_jog_active = false
		ws.send_command("soft_stop")

## UFO cues and the HUD (render frame).
func _update_gesture_presentation(dt: float) -> void:
	gesture_hud.gate = gesture_gate_reason
	gesture_hud.place(_play_w, get_viewport_rect().size.y)
	gesture_hud.step(dt)
	var face := ""
	var steer := Vector2.ZERO
	if gesture.enabled:
		var now := float(Time.get_ticks_msec())
		var lost := gesture.state == GestureControl.State.WAITING_RELEASE and gesture.reason in ["no_hand", "stale", "camera_lost"] and not gesture.detected
		if lost and _lost_since_ms < 0.0:
			_lost_since_ms = now
		elif not lost:
			_lost_since_ms = -1.0
		if lost and now - _lost_since_ms < 4000.0:
			face = "lost"  # looks around for a few seconds
		elif gesture_gate_reason != "" and gesture_gate_reason != GATE_FOCUS and gesture.detected:
			face = "blocked"
		elif gesture.is_active():
			steer = gesture.velocity / maxf(gesture.scheme.max_speed(gesture), 1e-6)
	ufo.gesture_face = face
	ufo.steer = steer

## Space: the game's stop (the mock halts, the backend gets soft_stop: a decelerating stop,
## no alarm; the debug panel's E-STOP sends ABORT).
func stop_key() -> void:
	if study_mode != null:
		study_mode.on_stop_key()
	_jog_latched = _jog_input() != Vector3.ZERO
	gesture.stop("stop_key")
	if homework != null:
		homework.cancel_locate("Space で止めたので、問題を見に行くのをやめました")
	if mock.enabled:
		mock.emergency_stop()
	if ws.enabled and ws.is_open():
		_jog_active = false
		ws.send_command("soft_stop")

## Review on #95: a settings field (camera name, serial port) would take Space as text, and
## the title does not end a running sequence (the auto catch), so Space must still stop.
## _input runs before the GUI; the space is typed too (stopping again is harmless).
func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_SPACE \
			and settings_active() and text_entry_focused():
		stop_key()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and text_entry_focused():
		# a click on the game area ends typing, so the jog keys work again
		get_viewport().gui_release_focus()
	if ev is InputEventKey and ev.pressed and not ev.echo:
		# the settings and the title screens take every key but the stop (Space) and the
		# debug panel (F1 / Tab); typing in a settings field never gets here
		if settings_active() and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB]:
			settings.handle_key(ev.keycode)
			return
		if title_active() and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB]:
			title.handle_key(ev.keycode)
			return
		if ev.keycode == KEY_ESCAPE and title != null and not text_entry_focused():
			show_title()
			return
		# the study mode's keys first (Enter, its HELP key, F5..F8, ...); Space stays the game's stop
		if study_mode != null and ev.keycode != KEY_SPACE and not text_entry_focused() \
				and study_mode.handle_key(ev.keycode):
			return
		match ev.keycode:
			KEY_SPACE:
				stop_key()
			KEY_F1, KEY_TAB:
				debug_ui.visible = not debug_ui.visible
				debug_ui.study_panel_visibility_changed(debug_ui.visible)
				_layout()
			KEY_V:
				scope_trigger.toggle()
			KEY_H:
				set_gesture_enabled(not gesture.enabled)
			KEY_BRACKETLEFT:
				arm_step(-arm_step_deg)
			KEY_BRACKETRIGHT:
				arm_step(arm_step_deg)
			KEY_Q:
				arm_goto("open")
			KEY_A:
				arm_goto("closed")
			KEY_C:
				request_auto_catch()
			KEY_G:
				GameState.post_event("result_success")
			KEY_F:
				GameState.post_event("result_failure")
			_:
				# the homework helper's keys (#79, homework.helper.keys; the keys above win).
				# Not during the study mode: its HELP is the only way the arm goes to the sheet then.
				if homework != null and (study_mode == null or not study_mode.active()):
					homework.handle_key(ev.keycode)
