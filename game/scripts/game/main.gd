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
## UFOくん 学習モード (#86): the experience (F5 / --study-mode) and its screen
var study_mode: StudyModeController
var study_hud: StudyHud
## SUMMON THE UFO, the 150 s score game (#138): its own screen over the crane's, its own state
var game_mode: GameModeController
## The title screen (#90): study mode or game mode at start; Esc comes back to it
var title: TitleScreen
var settings: SettingsScreen
## #292: the score game stops by itself on a fault of the crane; the staff's recovery screen
var robot_guard: RobotFaultGuard
var recovery_panel: StaffRecoveryPanel
## #291: the capsule colour probe (カプセル色判定テスト); hidden and idle until opened
var capsule_probe: CapsuleColourProbe
## the keys besides the polled jog (arrows, W / S) that work on the 校正 tab (#98)
const CALIBRATION_KEYS := [KEY_BRACKETLEFT, KEY_BRACKETRIGHT, KEY_Q, KEY_A]
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
## The score game's easy mode (#169): what the hand's shapes mean there (a fist = catch by
## itself, one / two fingers = carry to Dial 1 / 2). Its own state; it only asks the backend
## for the sequence (`_easy_send`) and follows the backend's report.
var easy := EasyModeControl.new()
## #260: the staff's operations (F6..F10 now; an outside device later): StaffControl.run()
var staff := StaffControl.new(self)
## The staff remote (M5StopWatch through the device hub): its staff operations go to `staff`,
## its hand-like input to `gesture` in place of the camera's hand while it is used.
var remote := StaffRemote.new()
## whose hand events GestureControl is reading: "camera" (the backend's vision) or "remote"
var hand_source := "camera"
var _remote_scheme_logged := false
## The backend's link is open, as the hand control's gate and the easy mode see it (the
## tests put a stand-in here; commands still go out through `ws` only).
var backend_link: Callable = func() -> bool: return RobotState.source == "websocket" and ws.enabled and ws.is_open()
const GATE_GESTURE_OFF := "ハンドジェスチャーが オフ（H で オン）"
const GATE_EASY_BUSY := "かんたんモード: じどうで うごいているよ"
const GATE_EASY_FAULT := "かんたんモード: とまっているよ（かかりの ひとを よんでね）"
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
## Z held against the end of its measured range (#102): how to go past it (校正 tab).
var z_end_hint := ""
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
	ws.outbound_buffer_size = StudyServices.SHEET_SEND_BUFFER  # the study sheet's camera frame
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
	ws.message_received.connect(_on_remote_message.bind(ws))
	vision_ws.message_received.connect(_on_remote_message.bind(vision_ws))
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
	var easy_cfg = GameConfig.value("game_mode.easy", {})
	easy.configure(easy_cfg if easy_cfg is Dictionary else {})
	easy.send = _easy_send
	ws.ack.connect(easy.on_ack)
	ws.ack.connect(_on_park_ack)
	easy.delivered.connect(_on_easy_delivered)
	easy.cue.connect(_on_easy_cue)
	easy.state_changed.connect(func(from: String, to: String): debug_log.emit("easy mode: %s -> %s%s" % [from, to,
		(" (%s)" % easy.note) if easy.note != "" else ""]))
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
	if bool(GameConfig.value("game_mode.enabled", true)):
		game_mode = GameModeController.new()
		game_mode.name = "GameMode"
		add_child(game_mode)
		game_mode.setup(self)
		game_mode.phase_changed.connect(_on_game_mode_phase)
		game_mode.tutorial_claw.connect(_on_tutorial_claw)
		game_mode.tutorial_goto.connect(_on_tutorial_goto)
		var hand_cam = GameConfig.get_value("camera", "overview", {})  # #183: the practice shows the hand camera
		game_mode.tutorial_hud.attach(cameras, gesture, hand_cam is Dictionary and bool(hand_cam.get("flip_h", false)), hand_cam is Dictionary and bool(hand_cam.get("flip_v", false)))
	title = TitleScreen.new()
	title.name = "TitleScreen"
	add_child(title)
	title.setup(game_mode != null)
	title.chosen.connect(_on_title_chosen)
	title.settings_requested.connect(open_settings)
	settings = SettingsScreen.new()
	settings.name = "SettingsScreen"
	add_child(settings)
	settings.setup()
	settings.setup_calibration(self)
	settings.setup_tests(self)
	settings.setup_sheet(self)  # #230: the プリント tab
	settings.missing_check = crane_missing  # #308: asked about when the screen closes after 校正
	settings.closed.connect(_on_settings_closed)
	robot_guard = RobotFaultGuard.new()
	robot_guard.name = "RobotFaultGuard"
	add_child(robot_guard)
	robot_guard.setup(self)
	recovery_panel = StaffRecoveryPanel.new()
	recovery_panel.name = "StaffRecoveryPanel"
	add_child(recovery_panel)
	recovery_panel.setup(self, robot_guard)
	capsule_probe = CapsuleColourProbe.new()  # #291: opened from the debug panel's カメラ tab
	capsule_probe.name = "CapsuleColourProbe"
	add_child(capsule_probe)
	capsule_probe.setup(self)
	GameState.state_changed.connect(_on_game_state_changed)
	ws.ack.connect(_on_ws_ack)
	get_viewport().size_changed.connect(_layout)
	_layout()
	set_gesture_enabled(bool(GameConfig.get_value("gesture", "enabled", false)))
	dev.apply_cmdline()

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
	# #237: the study mode's warm pixel-art room behind the UFO (over the stars), and no gesture
	# mini camera meanwhile (the study mode shows its own camera picture)
	var backdrop := StudyBackdrop.new()
	backdrop.name = "StudyBackdrop"
	add_child(backdrop)
	backdrop.visible = false
	study_mode.state_changed.connect(func(_p, c):
		backdrop.visible = c != "OFF"
		if c == "REWARD_REVEAL" and game_mode != null:  # the reward's show opens in the mist
			game_mode.mist_burst(game_mode.mist_study_s)
		if gesture_hud != null:
			gesture_hud.hidden_by_study = c != "OFF")
	if bool(GameConfig.get_value("study_mode", "autostart", false)):
		study_mode.call_deferred("start")

## Full screen or a window (#157: the exhibit's monitor stands on end; the OS turns the
## picture, the game only fills it). config render.fullscreen, --fullscreen / --windowed on
## the command line (these win), F11 while it runs. Nothing to do with no window (headless).
var fullscreen_override := ""  # "" (the config decides) / "on" / "off"

func fullscreen_wanted() -> bool:
	if fullscreen_override != "":
		return fullscreen_override == "on"
	return bool(GameConfig.value("render.fullscreen", false))

## how many times the window mode was decided (at start, on a saved setting, on F11): tests
var window_mode_applied := 0

func apply_window_mode() -> void:
	window_mode_applied += 1
	if DisplayServer.get_name() == "headless" or not is_inside_tree():
		return
	var want := Window.MODE_FULLSCREEN if fullscreen_wanted() else Window.MODE_WINDOWED
	if get_window().mode != want:
		get_window().mode = want

## The title at start unless the start is already decided (a scenario, a capture, the study
## mode by argument or by study_mode.autostart) or nobody looks (headless: the tests and CI).
## --title shows it anyway, --no-title never.
static func title_on_start(args: PackedStringArray, enabled: bool, headless: bool, study_autostart: bool) -> bool:
	if args.has("--title"):
		return true
	if not enabled or headless or study_autostart:
		return false
	for a in ["--no-title", "--scenario", "--capture", "--log-motion", "--gesture-demo", "--study-mode", "--study-demo", "--game-mode", "--game-mode-title", "--game-mode-tutorial"]:
		if args.has(a):
			return false
	return true

var _debug_layer := 1
var _debug_before_title := false
## the score game closed the debug panel when it opened (#171: nobody wants it beside the game)
var _score_hid_debug := false

## Back to the title (Esc, and at start): the study mode stops (its backend sequence too),
## the hand stick lets go, and main holds the manual controls while it shows. The debug
## panel goes above the title (hidden; F1 / Tab shows it there, STOP / E-STOP clickable).
## #114: at start the settings screen's 校正 tab comes first (the Z top, the heights, the AI's
## reachability); closing it shows the title. title_screen.calibration_first false = the title.
func open_startup_screen() -> void:
	if settings == null or not bool(GameConfig.get_value("title_screen", "calibration_first", true)) \
			or OS.get_cmdline_user_args().has("--title-only"):  # (a capture of the title itself)
		return
	open_settings()
	settings.show_tab(SettingsScreen.CALIBRATION_TAB)

func show_title() -> void:
	if study_mode != null and study_mode.active():
		study_mode.stop()
	if game_mode != null and game_mode.active():
		game_mode.close()  # a running round is stopped (STOP_ALL to the peripherals)
	if gesture.is_active():
		gesture.stop("title")
	if not title.active():
		_debug_layer = debug_ui.layer
		# (the score game closed it for itself: it was open before, and is again afterwards)
		_debug_before_title = debug_ui.visible or _score_hid_debug
		_score_hid_debug = false
	debug_ui.layer = title.layer + 2  # above the title and the settings screen
	_set_debug_visible(false)
	title.open()

## The gear on the title (#93). Only over the title: the arm is held meanwhile.
## #291: the capsule colour probe. It never sends anything; the round (if any) goes on.
func open_capsule_probe() -> void:
	if capsule_probe != null:
		capsule_probe.open()

func capsule_probe_active() -> bool:
	return capsule_probe != null and capsule_probe.active()

func open_settings() -> void:
	if not title_active() or settings.active():
		return
	settings.layer = title.layer + 1
	settings.open()

func settings_active() -> bool:
	return settings != null and settings.active()

## The settings screen's 校正 tab shows (#98): the keys may move the arm (arrows, W / S,
## [ ], Q / A) though the title is up; gestures and the auto catch stay off, Space stops.
func calibrating() -> bool:
	return settings != null and settings.calibrating()

## The calibration needs the homework link (the spot, the camera map) even when the
## homework watch and the study mode are off: theirs, or one of its own.
var _calib_hw: HomeworkClient
func homework_for_calibration() -> HomeworkClient:
	if homework != null:
		return homework
	if study_mode != null and study_mode.services.homework != null:
		return study_mode.services.homework
	if _calib_hw == null:
		_calib_hw = HomeworkClientScript.new()
		_calib_hw.name = "CalibrationHomeworkClient"
		add_child(_calib_hw)
		_calib_hw.setup(cameras, ws)
		_calib_hw.helper_offer = false
	return _calib_hw

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
	AudioBuses.apply(GameConfig.data.get("audio", {}) if GameConfig.data.get("audio") is Dictionary else {})
	if game_mode != null:
		game_mode.sounds.enabled = sfx.enabled
		game_mode.sounds.volume_db = sfx.volume_db
		game_mode.tutorial_auto = bool(GameConfig.value("game_mode.tutorial.enabled", game_mode.tutorial_auto))
		game_mode.set_mist_enabled(bool(GameConfig.value("game_mode.mist.enabled", game_mode.mist_enabled)))  # #318
	shake.enabled = bool(GameConfig.value("render.screen_shake", true))
	apply_window_mode()
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

## #183: what the menus read of the hand (the title's choice, the game mode's start and
## difficulty): only whether a fresh hand is seen, and its shape. No steering here.
func hand_for_menus() -> Dictionary:
	if gesture == null or not gesture.enabled:
		return {}
	var age := gesture.age_ms(float(Time.get_ticks_msec()))
	return {"fresh": age >= 0.0 and age <= gesture.stale_ms and gesture.camera_ok, "detected": gesture.detected, "pose": gesture.pose}

func title_active() -> bool:
	return title != null and title.active()

## #237: the study mode is done: on to the score game's own title (as if chosen at the start), or
## back to the claw game when there is no score game.
func open_score_game() -> void:
	if game_mode != null:
		_on_title_chosen("score")

func _on_title_chosen(mode: String) -> void:
	debug_log.emit("title: " + mode)
	if game_mode != null:
		game_mode.sounds.play_jingle()  # #181
	debug_ui.layer = _debug_layer
	_set_debug_visible(_debug_before_title or debug_ui.visible)
	if mode == "study":
		if study_mode == null:
			_setup_study_mode()
		if not study_mode.active():
			study_mode.start()
	elif study_mode != null and study_mode.active():
		study_mode.stop()
	if game_mode != null:
		if mode == "score":
			debug_ui.layer = maxi(debug_ui.layer, GameModeController.LAYER + 1)  # F1 opens it above the field
			if not game_mode.debug_panel and debug_ui.visible:
				_score_hid_debug = true
				_set_debug_visible(false)  # the score game has the whole screen; F1 / Tab opens the panel
			game_mode.open()
		elif game_mode.active():
			game_mode.close()

func _title_status() -> String:
	if RobotState.source != "websocket":
		return "アーム: ゲーム内の仮想クレーン"
	if not ws.is_open():
		return "アーム: バックエンドにつながっていない"
	return "アーム: バックエンド（%s）  モーターは「実機」タブで有効にするまで動かない" % RobotState.machine_state

## The startup options, the motion log and the frame capture (MainDevTools, #223).
var dev := MainDevTools.new(self)

func _exit_tree() -> void:
	dev.close()

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
	dev.log_motion("P", dt, pose)

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
	# #327: the motion sounds are timed here, on the physics tick (not per render frame):
	# the arm going up or down is one sound (Z), the travel another (XY)
	sfx.tick_motion(maxf(fx_up, fx_down), fx_move, dt)

## Presentation intensities 0..1 from the physics: (sideways move, UFO rising,
## UFO sinking). A longer rope means the UFO sinks (arm up), a shorter one that it
## rises (arm down).
static func motion_intensities(anchor_vel: Vector3, rope_rate_cm_s: float) -> Vector3:
	var move := clampf(Vector2(anchor_vel.x, anchor_vel.z).length() / FX_MOVE_FULL_CM_S, 0.0, 1.0)
	var rise := clampf(-rope_rate_cm_s / FX_ROPE_FULL_CM_S, 0.0, 1.0)
	var sink := clampf(rope_rate_cm_s / FX_ROPE_FULL_CM_S, 0.0, 1.0)
	return Vector3(move, rise, sink)

func _process(dt: float) -> void:
	dev.capture_tick(dt)
	_tick_tutorial_goto(dt)
	_tick_park(dt)
	if game_mode != null:
		# the menu's music (#173): the title screen, and the score game's own title
		# #181: the title screen at start has its own (top), the practice too; none in the 校正 tab
		game_mode.sounds.top_on = title_active()
		game_mode.sounds.menu_on = game_mode.active() and game_mode.phase == "IDLE"
		game_mode.sounds.tutorial_on = game_mode.active() and game_mode.phase == "TUTORIAL"
		game_mode.sounds.silent = calibrating()
		# the shelf's light outside the score game: the title's show, the study mode's desk light
		var studying: bool = study_mode != null and study_mode.active()
		game_mode.scene_outside = "study" if studying else ("title" if title_active() else "")
		game_mode.lights_tick(dt)
	if title_active():
		title.set_status(_title_status())
		if not settings_active():  # #183: one finger / two fingers pick a mode
			title.hand_tick(dt, hand_for_menus())
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
	_update_scope(dt)
	_update_gesture_presentation(dt)
	dev.log_motion("R", dt, Vector3.ZERO)

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
	scope.still = study_mode.explain_photo() if study_mode != null and study_mode.active() else null
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
	if robot_guard != null and robot_guard.on_ack(rid, ok, data):
		return
	if _on_recover_ack(rid, ok):
		return
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

## The operator's lines (OperatorHints, #223), under the names their callers know.
static func jog_hint_for(reason: String) -> String:
	return OperatorHints.jog_hint_for(reason)

static func auto_catch_status_text(ac: Dictionary) -> String:
	return OperatorHints.auto_catch_status_text(ac)

static func auto_catch_hint_for(reason: String) -> String:
	return OperatorHints.auto_catch_hint_for(reason)

## A moving jog's parameters. On the settings screen's 校正 tab, z_free: Z goes past the
## measured top / bottom, to measure them again (#102; still hold-to-move, Space stops).
func jog_params(v: Vector3) -> Dictionary:
	var params := {"vx": v.x, "vy": v.y, "vz": v.z}
	if calibrating():
		params["z_free"] = true
	return params

## The backend stops a Z jog at the measured range's ends (0..z_max, once the top is
## recorded): said when one is held there, as the way past it (#102).
func z_end_hint_for(vz: float, z: float) -> String:
	if vz == 0.0 or not RobotState.z_calibrated or not RobotState.z_reference_set:
		return ""
	var r := GameConfig.robot()
	if (vz < 0.0 and z <= float(r.z_min_mm) + 0.5) or (vz > 0.0 and z >= float(r.z_max_mm) - 0.5):
		return "Z: 前に測った範囲の端で止まっている。下ろす量を変えたら 設定（歯車）→ 校正 で Z を測り直す（校正タブでは範囲で止まらない）"
	return ""

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
	if settings != null and settings.confirm_showing():
		return Vector3.ZERO  # #308: the close question shows: no key moves the arm (Space still stops)
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
		var rid: String = ws.send_command("jog", jog_params(v))
		_moving_jog_rids[rid] = true
		if _moving_jog_rids.size() > 64:  # acks lost on a disconnect must not pile up
			_moving_jog_rids.erase(_moving_jog_rids.keys()[0])
		_jog_active = true

## Every physics tick: keyboard and hand joystick -> ControlArbiter -> the one
## jog path (real robot) or the MockRobot target.
## SPEED UP (#188). Without it everything is as outside the game: the hand's stick at its
## own top speed (gesture.joystick.max_speed_mm_s, 60), the keys at theirs. While it lasts
## both go up to game_mode.powerups.speed.boost_mm_s (100) in XY; Z never changes. It is
## read from the game's phase and the power's timer every tick, so a stop, the round's end
## or the title cannot leave it on. On the real crane the speed is the backend's to allow:
## its jog cap is raised only by jog_boost, for the seconds asked, and falls back by itself.
func speed_boost_on() -> bool:
	return game_mode != null and game_mode.active() and game_mode.phase == "PLAYING" \
		and game_mode.powerups.active("speed")

func speed_boost_mm_s() -> float:
	return clampf(float(GameConfig.value("game_mode.powerups.speed.boost_mm_s", 100.0)), 1.0, 300.0)

## how many times the hand's top speed the boost is (1 = no boost, never below 1)
func hand_boost_scale() -> float:
	if not speed_boost_on():
		return 1.0
	return maxf(speed_boost_mm_s() / maxf(gesture.joystick.max_speed, 1.0), 1.0)

## the keys' XY speed now
func powerup_xy_speed(real: bool) -> float:
	var usual := jog_speed_real_mm if real else jog_speed_mm
	if not speed_boost_on():
		return usual
	return maxf(speed_boost_mm_s(), usual) if real else usual * hand_boost_scale()

## The backend is told how long its jog cap may be the boost's: when the power starts, when
## it was taken again (more seconds than it knows of), and 0 when it ended early.
var _boost_told_s := 0.0
## how jog_boost {seconds} reaches the backend (the tests put their own here)
var jog_boost_sender: Callable = func(seconds: float) -> void: _easy_send("jog_boost", {"seconds": seconds})
func _sync_jog_boost(real: bool) -> void:
	var left := float(game_mode.powerups.left.get("speed", 0.0)) if speed_boost_on() else 0.0
	if not real:
		_boost_told_s = 0.0
		return
	if left > 0.0 and left > _boost_told_s + 0.25:
		jog_boost_sender.call(snappedf(left, 0.01))
	elif left <= 0.0 and _boost_told_s > 0.05:
		jog_boost_sender.call(0.0)
	_boost_told_s = left

func _handle_input(dt: float) -> void:
	var real := RobotState.source == "websocket"
	var xy_speed := powerup_xy_speed(real)
	_sync_jog_boost(real)
	var keys := _latched_jog_input()
	if capsule_probe_active():
		keys = Vector3.ZERO  # #291: the probe covers the screen; the keys never move the arm behind it
	var kb := Vector3.ZERO
	if keys != Vector3.ZERO:
		var xy := jog_velocity(Vector2(keys.x, keys.y), xy_speed)
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
	# the easy mode (#169): the hand steers XY only and its shapes are not the claw's
	var easy_on := easy_wanted()
	gesture.xy_only = easy_on
	gesture.claw_enabled = not easy_on
	var base_gate := gesture_gate()
	gesture_gate_reason = base_gate
	if base_gate == "" and easy_on:
		if easy.busy() or RobotState.easy_mode_active():
			gesture_gate_reason = GATE_EASY_BUSY
		elif easy.faulted():
			gesture_gate_reason = GATE_EASY_FAULT  # the keys stay, for the staff
	var gv := gesture.tick(Time.get_ticks_msec(), dt, gesture_gate_reason)
	gv *= hand_boost_scale()  # SPEED UP: the same stick, faster in XY (never Z)
	_tick_easy(dt, easy_on, base_gate, kb != Vector3.ZERO)
	if study_mode != null and study_mode.active():
		# #136: 1 / 2 / 3 fingers offer help with that problem, a thumbs-up starts it
		var hand_age := gesture.age_ms(Time.get_ticks_msec())
		var fresh := gesture.detected and hand_age >= 0.0 and hand_age <= gesture.stale_ms
		study_mode.hand_tick(gesture.pose if fresh else "", Time.get_ticks_msec())
		# #334: after the answer check, the problem's number shown with the fingers
		study_mode.finger_tick(gesture.fingers if fresh else -1, gesture.pose if fresh else "", Time.get_ticks_msec())
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
	if title_active() and not calibrating():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "タイトル画面ではアームを動かせない（モードを選んでから）"
		if gesture.is_active():
			gesture.stop("title")
	# #292: the score game stopped on a fault of the crane: nothing moves it by hand until the
	# staff recovered it (the recovery screen's buttons, the backend's gates)
	# (the 校正 tab keeps its keys, as on the title; outside the score game the backend's
	# own gates are left: the latch is the score game's)
	if game_mode != null and game_mode.active() and game_mode.robot_fault_latched() and not calibrating():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "ロボットの異常で止まっています（スタッフ: F9 で ふっき）"
		if gesture.is_active():
			gesture.stop("robot_fault")
	# the study mode's HELP / tidy-up owns the arm: no manual jog meanwhile (Space still stops it)
	if study_mode != null and study_mode.blocks_manual_control():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "学習モードでアームを使っている間は手動操作できない（Space で止める）"
		if gesture.is_active():
			gesture.stop("study_mode")
	# #242 review: the arm-tip camera's calibration owns the arm (a jog would change what it measures)
	if settings != null and settings.calibration != null and settings.calibration.focus_cal.active():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "先端カメラの校正中は手動操作できない（Space で止める）"
		if gesture.is_active():
			gesture.stop("focus_calibration")
	# the auto catch owns the crane: no manual jog until it ends (Space / E-STOP still stop it)
	if RobotState.auto_catch_active():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "自動キャッチ中は手動操作できない（Space で中断）"
		if gesture.is_active():
			gesture.stop("auto_catch")
	# the easy mode's catch / wait / carry owns the crane (the backend holds the motion lock)
	if easy.busy() or RobotState.easy_mode_active():
		halt = true
		if kb != Vector3.ZERO:
			jog_hint = "かんたんモードの自動の動きの間は手動操作できない（Space で中断）"
		if gesture.is_active():
			gesture.stop("easy_mode")
	# gesture Z is "+ = arm up", like W: the same z_up_is_positive sign as the keys
	var gz := gesture.velocity_z * (1.0 if GameConfig.robot().z_up_is_positive else -1.0)
	# #185: the practice's "touch the fingers" steps only look at the pinch: the stick stays
	# as it is (the next step moves with the same pinch) but moves nothing yet
	if game_mode != null and game_mode.hand_holds_still():
		gv = Vector2.ZERO
		gz = 0.0
	var d := ControlArbiter.decide(halt, _jog_latched, kb, Vector3(gv.x, gv.y, gz), gesture.is_active())
	control_source = d.source
	var v: Vector3 = d.v
	z_end_hint = z_end_hint_for(v.z, RobotState.z_mm) if real and not calibrating() else ""
	if real:
		_send_jog(v, dt)
	elif mock.enabled and v != Vector3.ZERO:
		mock.set_target(mock.target + v * dt)
		if debug_ui != null:
			debug_ui.sync_targets_from_mock()

# ------------------------------------------------------------ easy mode (#169)
## Why the easy mode cannot be used at all here ("" = it can): then the score game stays
## in its manual controls and says so. Not the link's state (that only holds a catch back).
func easy_problem() -> String:
	if gesture.scheme.id() != PinchJoystickScheme.ID:
		return "かんたんモードは「つまんで動かす」だけ（手の形で方向を決める方式は未対応）"
	if RobotState.source != "websocket":
		return "かんたんモードはバックエンド接続時だけ（実機なしなら ./start.sh --mock）"
	return ""

## #275: why the backend would refuse the easy mode's catch now, in plain words ("" = it would
## not): not homed, an alarm, the motors off, the values not recorded, ... (what passes by
## itself, a jog or another motion, is not reported). The score game starts nothing meanwhile.
func easy_blocker() -> String:
	if RobotState.source != "websocket" or not RobotState.connected:
		return ""
	var bl = RobotState.easy_mode.get("blockers", [])
	if not (bl is Array) or (bl as Array).is_empty():
		return ""
	return EasyModeControl.refusal_text(str(bl[0]))

## #299: what the real crane needs before any score game (easy or not): the Z top and bottom
## (the Z reference this power-on and the measured scale), the portal's XY and the release height
## (the catch height is the bottom). "" = it has them (or this is not the real crane). While the
## backend's easy status has not come yet, nothing starts either (never "" by default).
func crane_blocker() -> String:
	if RobotState.source != "websocket":
		return ""
	# review on #301: which crane the backend runs is told by its hello (and forgotten on a
	# disconnect): until then nothing starts; only a backend that said it is not the real one is free
	var robot := str(ws.server_robot)
	if robot == "":
		return "ロボットの じょうたいを かくにんちゅう…（バックエンドに つながるのを まっています）"
	if robot != "real":
		return ""
	return crane_blocker_for(RobotState.connected, RobotState.z_reference_set, RobotState.z_calibrated,
		RobotState.easy_mode)

static func crane_blocker_for(connected: bool, z_reference: bool, z_calibrated: bool, easy_status: Dictionary) -> String:
	if not connected:
		return "ロボットに つながっていない（かかりの ひとへ）"
	if not z_reference:
		return "アームの たかさが まだ きまっていない（校正タブ 2: 前回の上下を呼び出す か うえを きろく）"
	if not z_calibrated:
		return "Z の うえと したが まだ（校正タブ 2: うえと したを きろく）"
	var bl = easy_status.get("blockers")
	if not bl is Array:
		return "ロボットの じょうたいを かくにんちゅう…"
	var missing: Array[String] = []
	for b in bl:
		var r := str(b).to_lower()
		if r.contains("dial 1 drop point is not recorded"):
			missing.append("ポータルの XY")
		elif r.contains("release height is not recorded") or r.contains("measured again"):
			missing.append("とうにゅうの たかさ")
		elif r.contains("z bottom"):
			missing.append("Z の した")
	if not missing.is_empty():
		return "%sが まだ（校正タブ 2 で きろく: かかりの ひとへ）" % "・".join(missing)
	return ""

## #308: what the score game still needs of the real crane, item by item (crane_blocker's
## conditions, all of them at once): [] = nothing, not the real crane, or not known yet.
func crane_missing() -> Array[String]:
	if RobotState.source != "websocket" or str(ws.server_robot) != "real":
		return []
	return crane_missing_for(RobotState.connected, RobotState.z_reference_set, RobotState.z_calibrated,
		RobotState.easy_mode)

static func crane_missing_for(connected: bool, z_reference: bool, z_calibrated: bool, easy_status: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if not connected:
		out.append("ロボットとの接続")
		return out
	if not z_reference:
		out.append("Z の基準（前回の上下を呼び出す か 上を記録）")
	if not z_calibrated:
		out.append("Z の上と下")
	var bl = easy_status.get("blockers")
	for b in bl if bl is Array else []:
		var r := str(b).to_lower()
		var item := ""
		if r.contains("dial 1 drop point is not recorded"):
			item = "ポータルの XY"
		elif r.contains("release height is not recorded") or r.contains("measured again"):
			item = "投入の高さ"
		elif r.contains("z bottom") and z_calibrated:
			item = "Z の下"
		if item != "" and not out.has(item):
			out.append(item)
	return out

## The easy mode is on: the score game is open with difficulty easy and it is usable.
func easy_wanted() -> bool:
	if game_mode == null:
		return false
	game_mode.easy_block = easy_problem()
	return game_mode.active() and game_mode.easy_on()

## a game just started: the easy mode asks the backend for the arm's start position (once)
var _easy_start_reset := false

func _tick_easy(dt: float, on: bool, gate: String, keys_held: bool) -> void:
	var now := float(Time.get_ticks_msec())
	var age := gesture.age_ms(now)
	# the hand control switched off (H, --no-gesture): the camera's events still come in, but
	# no shape of the hand asks for anything (review on #170)
	if not gesture.enabled and gate == "":
		gate = GATE_GESTURE_OFF
	var hand := {"fresh": age >= 0.0 and age <= gesture.stale_ms, "camera_ok": gesture.camera_ok, "detected": gesture.detected,
		"pose": gesture.pose, "pinch": gesture.pinch or gesture.sign_seen,
		# a catch never starts on top of a steer: the pinch let go, the stick at rest, the zero jog out
		"steering": gesture.state in [GestureControl.State.ARMED, GestureControl.State.ACTIVE] or _jog_active or keys_held}
	easy.tick(dt, hand, {"enabled": on, "taking": game_mode != null and game_mode.taking(),
		"link": bool(backend_link.call()), "gate": gate,
		"status": RobotState.easy_mode})
	if _easy_start_reset:
		# only at the start itself: not later in the round (a run in the way, no link: not asked)
		_easy_start_reset = false
		if on and easy.state == "MANUAL_XY" and bool(backend_link.call()) and not keys_held:
			easy.request_reset()

## The easy mode's one way to the backend. "" = not sent. Never repeated by itself.
func _easy_send(name: String, params: Dictionary) -> String:
	if not bool(backend_link.call()):
		return ""
	if name == "soft_stop":
		_jog_active = false
	return ws.send_command(name, params)

## The backend's carry ended over a Dial. The Dial's own BALL_RECEIVED is what counts; with
## a simulated crane and simulated Dials the score game gives the mock Dial its capsule.
func _on_easy_delivered(destination: int) -> void:
	if game_mode != null and destination == 1:
		game_mode.easy_delivered("left", ws.server_robot != "real")  # Dial 1 is the only one (#200)

func _on_easy_cue(name: String) -> void:
	match name:
		"grab":
			sfx.play_cue("catch")  # #332: the fist's own sound (決定ボタンを押す23), not the pinch's
			gesture_hud.flash("じどうキャッチ！", 0.9)
		"lower":
			if game_mode != null:
				game_mode.cheer_descent()  # #332: UFOくん's cheer as the arm goes down to catch
		"caught":
			sfx.play_cue("hand")
		"deliver":
			sfx.play_cue("pinch")
			gesture_hud.flash("はこぶよ！", 0.9)
		"done", "cancelled":
			sfx.play_cue("release")
		"refused", "fault":
			sfx.play_cue("lost")

# ------------------------------------------------------------ recovery from the game's screen (#179)
## Shift + F6..F8: what those keys did before #260, for the developers: the practice's step
## again (score game), the next failure injected / the study mode from the start (study mode).
func _developer_key(keycode: int) -> bool:
	if keycode == KEY_F6 and game_mode != null and game_mode.active():
		return game_mode.staff_step("retry")
	if study_mode != null and study_mode.active():
		if keycode == KEY_F7:
			study_mode.debug_next_failure()
			return true
		if keycode == KEY_F8:
			study_mode.start()
			return true
	return false

## The arm cannot be used as it is (the backend's robot): an alarm (a stop that had to cut a
## moving servo with ABORT, an emergency stop), or homing lost. "" = it can.
func arm_recovery_reason() -> String:
	if RobotState.source != "websocket" or not bool(backend_link.call()) or not RobotState.connected:
		return ""
	if RobotState.machine_state in ["ALARM", "ESTOP"]:
		return "アラームちゅう"
	if not RobotState.homed and RobotState.machine_state != "HOMING":
		return "げんてんふっきが いる"
	if not RobotState.motors_enabled:
		return "モーターが オフ"
	return ""

## The recovery is running (the 校正 tab's preparation, started from here or there).
func arm_recovering() -> bool:
	return RobotState.source == "websocket" and bool(RobotState.calibration_prepare.get("active", false))

## (The motors off count too: homed and without an alarm, the arm still cannot move until the
## preparation switches them on. Seen with the staff remote: its ふっき did nothing then.)
##
## Staff, from any screen (F9 = StaffControl's "recover", #260; or the button on the score game's
## screen): the alarm
## cleared, then the preparation (#167: motors, Z, the arm to the top, homing, the middle, the
## claw open). The same two commands as the debug panel's 「アラーム解除」 and the 校正 tab's
## 「準備をまとめて実行」, in that order; the backend refuses whatever is not in order. The
## arm moves: a person decided it. Returns false when there is nothing to recover or no link.
func recover_arm() -> bool:
	if arm_recovery_reason() == "" or arm_recovering():
		return false
	if _recover_clear_rid != "" or _recover_prepare_rid != "":
		return false  # already on its way
	debug_log.emit("recover: clear_alarm, then calibration_prepare")
	# one after the other, not queued together: the preparation (which moves the arm) is only
	# asked for when the alarm's clearing was answered, and not at all when the stop key came
	# in between (review on #180)
	_recover_clear_rid = ws.send_command("clear_alarm")
	if easy.faulted():
		easy.reset()
	return true

## A recovery command still without its answer (#292: the recovery screen waits for it).
func recover_pending() -> bool:
	return _recover_clear_rid != "" or _recover_prepare_rid != ""

## #292: the preparation alone (calibration_prepare: the arm moves), when there is no alarm
## to clear first. Same tracking as recover_arm (Space holds back a late start).
func prepare_arm() -> bool:
	if not bool(backend_link.call()) or arm_recovering() or recover_pending():
		return false
	debug_log.emit("recover: calibration_prepare")
	_recover_prepare_rid = ws.send_command("calibration_prepare")
	if easy.faulted():
		easy.reset()
	return true

## the recovery's two requests still without an answer ("" = none), and the preparation's
## request the stop key overtook (if it starts after all, it is stopped again)
var _recover_clear_rid := ""
var _recover_prepare_rid := ""
var _recover_stopped_rid := ""

func _on_recover_ack(rid: String, ok: bool) -> bool:
	if rid == "":
		return false
	if rid == _recover_clear_rid:
		_recover_clear_rid = ""
		if ok and bool(backend_link.call()):
			_recover_prepare_rid = ws.send_command("calibration_prepare")
		return true
	if rid == _recover_prepare_rid:
		_recover_prepare_rid = ""
		return true
	if rid == _recover_stopped_rid:
		_recover_stopped_rid = ""
		if ok and bool(backend_link.call()):
			ws.send_command("soft_stop")  # it started behind the stop: stopped again
		return true
	return false

## The stop key: a recovery on its way goes no further.
func _stop_recovery() -> void:
	_recover_clear_rid = ""  # its answer no longer starts the preparation
	if _recover_prepare_rid != "":
		_recover_stopped_rid = _recover_prepare_rid
		_recover_prepare_rid = ""

## A new round or practice: the easy mode leaves its FAULT (a person started it). The
## backend still refuses whatever is not in order.
func _on_game_mode_phase(p: String) -> void:
	if p in ["COUNTDOWN", "TUTORIAL"]:
		easy.new_round()  # #302: every round has its servo recoveries
		if easy.faulted():
			easy.reset()
		# #177: a game starts with the arm at its start (the claw open, the arm at the top):
		# the easy mode has no way to raise it by hand. Asked on the next tick, when it is on.
		_easy_start_reset = true

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
	if remote.present(recv_ms):
		return  # the staff remote is the hand now
	if hand_source != "camera":
		hand_source = "camera"
		gesture.reset_stream("camera")  # a new stream: its numbers start over, a held sign is let go first
	gesture.on_event(data, recv_ms)

## The staff remote (M5StopWatch, through the backend's device hub): a staff operation goes
## to StaffControl like F6..F10 / Space; its input is a hand for GestureControl (the camera's
## events wait meanwhile). The gesture control is switched on by the remote's first input:
## a person picked it up to steer.
##
## The backend link in use carries them: `ws` with the backend's robot, the listen-only
## `vision_ws` while the game drives its own MockRobot (review on #263; never both, so an
## event is handled once).
func _on_remote_message(msg: Dictionary, link: UfoWebSocketClient = null) -> void:
	if link != null and (link == ws) != (RobotState.source == "websocket"):
		return
	var now := float(Time.get_ticks_msec())
	var r := remote.on_message(msg, now)
	if r.has("staff"):
		staff.run(str(r["staff"]), StaffRemote.SOURCE)
	elif r.has("hand"):
		feed_remote_hand(r["hand"], now)

## One REMOTE_INPUT frame (in order) as the hand, received at `now_ms`.
func feed_remote_hand(d: Dictionary, now_ms: float) -> void:
	if gesture_sim or _gesture_demo_t >= 0.0:
		return  # the developer's simulated hand owns it
	# the remote is a pinch joystick: under another scheme its shapes would mean other things
	# (pose_direction: peace closes the claw, a finger steers). Not used then (review on #263).
	if gesture.scheme.id() != PinchJoystickScheme.ID:
		if not _remote_scheme_logged:
			_remote_scheme_logged = true
			debug_log.emit("remote: input not used (gesture.scheme is %s; the remote needs %s)"
				% [gesture.scheme.id(), PinchJoystickScheme.ID])
			if gesture_hud != null:
				gesture_hud.flash("リモコンは「つまんで動かす」方式のときだけ", 2.0)
		return
	_remote_scheme_logged = false
	if not gesture.enabled:
		debug_log.emit("remote: hand control on (the staff remote steers)")
		set_gesture_enabled(true)
	if hand_source != StaffRemote.SOURCE:
		hand_source = StaffRemote.SOURCE
		debug_log.emit("remote: the remote is the hand (the camera's hand waits)")
	gesture.on_event(StaffRemote.hand_event(d, gesture.joystick, gesture.last_sequence() + 1), now_ms)

## #183: the practice's carry (easy mode; #266: shown after the fist): the arm really goes over that Dial, at the
## carry's speed. Asked of the backend (easy_goto: XY only, refused unless the easy mode's
## values are usable and the arm is up); the virtual crane of --game-only does not move.
## #276: the arm out of the way of the screen (the backend's `park`: the left back corner,
## slowly) when the study mode or the score game opens and when a round has ended (its
## result). Only with the backend; the backend refuses it while anything else moves, a jog is
## on or the arm is not wound up. A "busy" refusal is asked again PARK_RETRY_S later, for
## PARK_WINDOW_S at most; nothing while a round is being played.
const PARK_RETRY_S := 0.8
const PARK_WINDOW_S := 15.0
var park_want := ""  # why the arm is to be parked ("" = not)
var parks_sent := 0
var _park_left := 0.0
var _park_try := 0.0
var _park_rid := ""
var _park_screen := ""
var _park_phase := ""

func request_park(why: String) -> void:
	if RobotState.source != "websocket":
		return
	park_want = why
	_park_left = PARK_WINDOW_S
	_park_try = 0.0

func _park_now_ok() -> bool:
	if not RobotState.connected or not RobotState.homed or not RobotState.motors_enabled \
			or RobotState.machine_state in ["ALARM", "ESTOP"]:
		return false
	if RobotState.auto_catch_active() or RobotState.easy_mode_active() or ws.has_pending_motion():
		return false
	# never while a round is played (the start's own move, the hand's moves)
	return game_mode == null or not game_mode.active() or game_mode.phase in ["IDLE", "RESULT"]

func _tick_park(dt: float) -> void:
	var s := staff.screen()
	if s != _park_screen:
		if s in ["study", "score"]:
			request_park("mode " + s)
		_park_screen = s
	var ph: String = game_mode.phase if game_mode != null and game_mode.active() else ""
	if ph != _park_phase:
		if ph == "RESULT":
			request_park("round over")
		_park_phase = ph
	if park_want == "":
		return
	_park_left -= dt
	if _park_left <= 0.0:
		debug_log.emit("park: not done in time (%s)" % park_want)
		park_want = ""
		return
	_park_try -= dt
	if _park_try > 0.0 or not _park_now_ok():
		return
	_park_try = PARK_RETRY_S
	var rid := ws.send_command("park", {})
	if rid == "":
		return
	parks_sent += 1
	debug_log.emit("park: to the waiting point (%s)" % park_want)
	_park_rid = rid
	park_want = ""

func _on_park_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if rid == "" or rid != _park_rid:
		return
	_park_rid = ""
	if ok:
		return
	var reason := str(data.get("reason", ""))
	debug_log.emit("park refused: %s" % reason)
	if reason.contains("busy") and _park_left > 0.0:
		park_want = "again"  # another motion was just ending: once more, inside the same window

## #266: the same step closes the claw first: while that request is still out, the carry
## waits for its answer (TUTORIAL_GOTO_WAIT_S at most, then it is left out), so the arm
## never sets off with the claw open.
const TUTORIAL_GOTO_WAIT_S := 5.0
var _tutorial_goto := {}  # {"destination", "left"} waiting for the claw's answer

func _on_tutorial_goto(destination: int) -> void:
	debug_log.emit("tutorial: to Dial %d" % destination)
	_tutorial_goto = {}
	if RobotState.auto_catch_active() or RobotState.easy_mode_active():
		return
	if RobotState.source != "websocket":
		return
	if ws.has_pending_motion():
		_tutorial_goto = {"destination": destination, "left": TUTORIAL_GOTO_WAIT_S}
		return
	_easy_send("easy_goto", {"destination": destination})

## The carry of the practice waiting for the claw's answer (every frame).
func _tick_tutorial_goto(dt: float) -> void:
	if _tutorial_goto.is_empty():
		return
	var in_practice: bool = game_mode != null and game_mode.active() and game_mode.phase == "TUTORIAL"
	if not in_practice or RobotState.source != "websocket" or RobotState.auto_catch_active() or RobotState.easy_mode_active():
		_tutorial_goto = {}
		return
	_tutorial_goto.left = float(_tutorial_goto.left) - dt
	if not ws.has_pending_motion():
		var dest := int(_tutorial_goto.destination)
		_tutorial_goto = {}
		_easy_send("easy_goto", {"destination": dest})
	elif float(_tutorial_goto.left) <= 0.0:
		debug_log.emit("tutorial: the claw did not answer in time: no carry")
		_tutorial_goto = {}

## #183: the practice's fist step (easy mode): the claw closes as a show of what the fist
## does, and opens again with the next step. The same request as the hand's own (arm_goto:
## nothing while a sequence drives the claw, nothing while another motion is pending).
func _on_tutorial_claw(which: String) -> void:
	debug_log.emit("tutorial: claw %s" % which)
	if which == "closed":
		sfx.play_cue("catch")  # #332: the practice's fist sounds like the round's fist
	arm_goto(which)

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
	if RobotState.auto_catch_active() or RobotState.easy_mode_active():
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
	if RobotState.auto_catch_active() or RobotState.easy_mode_active():
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
	if study_mode != null and study_mode.active():
		return "学習モード（手は 1・2・3 本の指といいねで使う）"
	if RobotState.auto_catch_active():
		return "自動キャッチ中"
	if RobotState.machine_state in ["ALARM", "ESTOP"]:
		return "アラーム中:「clear_alarm」→「home」"
	if RobotState.source == "mock":
		return "" if mock.enabled and RobotState.connected else "ロボットに未接続"
	return real_gesture_gate(bool(backend_link.call()), RobotState.connected, ws.server_robot, gesture_allow_real,
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
	if was_live and to == GestureControl.State.WAITING_RELEASE and why not in ["stop_key", "manual", "disabled", "auto_catch", "easy_mode"]:
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
	# #258: in the score game the hand window bottom right, the easy mode's guide under it;
	# faint while a capsule comes in and plays
	gesture_hud.column = game_mode != null and game_mode.active()
	gesture_hud.guide_lower = gesture_hud.column and game_mode.easy_hud != null and game_mode.easy_hud.showing()
	gesture_hud.modulate.a = game_mode.guide_alpha() if gesture_hud.column else 1.0
	gesture_hud.hidden_by_tutorial = gesture_hud.column and game_mode.guide_hidden()
	gesture_hud.place(_play_w, get_viewport_rect().size.y)
	# into the window's bottom right corner while a capsule plays (the easy guide does the same)
	gesture_hud.pivot_offset = GameModeLayout.GUIDE_RECT.end - gesture_hud.position if gesture_hud.column else Vector2.ZERO
	gesture_hud.scale = Vector2.ONE * (game_mode.guide_scale() if gesture_hud.column else 1.0)
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
	# #276 (review on #279): a stop ends any parking still to come; a late answer re-arms nothing
	park_want = ""
	_park_rid = ""
	_tutorial_goto = {}  # nothing of the practice's carry is sent after a stop
	if robot_guard != null:
		robot_guard.on_stop_key()  # #292: a confirmation armed on the recovery screen is gone
	if study_mode != null:
		study_mode.on_stop_key()
	if game_mode != null:
		game_mode.on_stop_key()  # the score game stops and STOP_ALL goes to the peripherals (#138)
	if settings != null and settings.calibration != null:
		settings.calibration.on_stop_key()  # #242: the arm-tip camera's calibration run ends
	easy.on_stop()  # the easy mode's run is over (the soft_stop below ends the backend's sequence)
	_stop_recovery()  # a recovery asked for from the game's screen goes no further
	_jog_latched = _jog_input() != Vector3.ZERO
	gesture.stop("stop_key")
	if homework != null:
		homework.cancel_locate("Space で止めたので、問題を見に行くのをやめました")
	if mock.enabled:
		mock.emergency_stop()
	if ws.enabled and ws.is_open():
		_jog_active = false
		ws.send_command("soft_stop")
		if settings != null and settings.testing():
			ws.send_command("devicehub_stop_all")  # the テスト tab: the peripherals too (#108)

## #292: a fault of the crane stopped the score game: nothing more is asked of the crane by
## this side (what Space ends too, without its soft_stop: RobotFaultGuard sends that itself,
## once, and never on top of an alarm).
func halt_motion_requests(why: String) -> void:
	park_want = ""
	_park_rid = ""
	_tutorial_goto = {}
	easy.on_stop()
	_stop_recovery()
	_jog_latched = _jog_input() != Vector3.ZERO  # keys held now must be let go first
	gesture.stop(why)

## Review on #95: a settings field (camera name, serial port) would take Space as text, and
## the title does not end a running sequence (the auto catch), so Space must still stop.
## _input runs before the GUI; the space is typed too (stopping again is harmless).
func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_SPACE \
			and (settings_active() or capsule_probe_active()) and text_entry_focused():
		stop_key()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and text_entry_focused():
		# a click on the game area ends typing, so the jog keys work again
		get_viewport().gui_release_focus()
	# #233: the study mode's talk key is held while the child speaks: its release ends the listening
	if ev is InputEventKey and not ev.pressed and study_mode != null and not settings_active() \
			and not title_active() and not text_entry_focused() and study_mode.handle_key_release(ev.keycode):
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		# the settings and the title screens take every key but the stop (Space) and the
		# debug panel (F1 / Tab); typing in a settings field never gets here
		# the 校正 tab lets the claw keys through to the match below (#98)
		var claw_key: bool = calibrating() and not settings.confirm_showing() and ev.keycode in CALIBRATION_KEYS
		if ev.keycode == KEY_F11:  # full screen / a window, in any screen
			fullscreen_override = "off" if fullscreen_wanted() else "on"
			apply_window_mode()
			return
		# #260: the staff's operations, the same on every screen (before the screens' own keys)
		var staff_action := StaffControl.action_for_key(ev.keycode, ev.shift_pressed)
		if staff_action != "" and not text_entry_focused():
			staff.run(staff_action, "key")
			return
		if ev.shift_pressed and _developer_key(ev.keycode):
			return
		# #291: the capsule probe takes every key but the stop and the debug panel; Esc closes it
		if capsule_probe_active() and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB]:
			if ev.keycode == KEY_ESCAPE and not text_entry_focused():
				capsule_probe.close()
			return
		if settings_active() and not claw_key and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB]:
			settings.handle_key(ev.keycode)
			return
		if title_active() and not claw_key and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB]:
			title.handle_key(ev.keycode)
			return
		if ev.keycode == KEY_ESCAPE and title != null and not text_entry_focused():
			show_title()
			return
		# the study mode's keys first (Enter, its HELP key, F5..F8, ...); Space stays the game's stop
		if study_mode != null and ev.keycode != KEY_SPACE and not text_entry_focused() \
				and study_mode.handle_key(ev.keycode):
			return
		# the score game's keys (Enter, the mock's Z / M); Space stays the stop
		if game_mode != null and ev.keycode != KEY_SPACE and not text_entry_focused() \
				and game_mode.handle_key(ev.keycode):
			return
		# #292 (review on #294): the score game stopped on a fault of the crane: no key of the
		# crane either (the claw, the auto catch, the homework's keys): Space, the debug panel,
		# the scope and the hand switch only. The staff's recovery screen is the way back.
		if game_mode != null and game_mode.active() and game_mode.robot_fault_latched() and not calibrating() \
				and not ev.keycode in [KEY_SPACE, KEY_F1, KEY_TAB, KEY_V, KEY_H]:
			jog_hint = "ロボットの異常で止まっています（スタッフ: F9 で ふっき）"
			debug_log.emit("key refused (robot fault latched): " + OS.get_keycode_string(ev.keycode))
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
