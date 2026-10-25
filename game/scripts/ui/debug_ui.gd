extends CanvasLayer
## Debug / tuning overlay. Everything in the spec's section 10 lives here:
## virtual XYZ, mock robot dynamics, rope physics, projection, expression
## override, connection state, FPS and physics cost, and the test scenarios.
## Built in code (no .tscn editing needed). Toggle with F1 / Tab.

const PANEL_W := 360.0

var main: Node2D
var _panel: PanelContainer
var _vbox: VBoxContainer
var _sliders: Dictionary = {}
var _status: Label
var _log: RichTextLabel
var _expr_option: OptionButton
var _source_option: OptionButton
var _state_chip: Label
var _log_lines: PackedStringArray = PackedStringArray()
## role -> {"option": OptionButton, "view": TextureRect, "info": Label}
var _cam_ui: Dictionary = {}
var _gesture_status: Label
var _gesture_overlay: GestureCameraOverlay

func panel_width() -> float:
	return PANEL_W if visible else 0.0

func setup(m: Node2D) -> void:
	main = m
	_build()
	main.ws.log_line.connect(_append_log)
	GameState.state_changed.connect(func(p, c): _append_log("game: %s -> %s" % [p, c]))
	RobotState.error_reported.connect(func(e): _append_log("robot error: " + e))
	main.mock.scenario_started.connect(func(n): _append_log("scenario start: " + n))
	main.mock.scenario_finished.connect(func(n): _append_log("scenario done: " + n))

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_W
	_panel.offset_right = 0
	_panel.offset_top = 0
	_panel.offset_bottom = 0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.04, 0.12, 0.88)
	style.border_color = Color(0.2, 0.5, 0.9)
	style.border_width_left = 2
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.custom_minimum_size.x = PANEL_W - 24
	scroll.add_child(_vbox)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_vbox.add_child(_status)
	_state_chip = Label.new()
	_state_chip.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(_state_chip)

	_header("Robot source / connection")
	_source_option = OptionButton.new()
	_source_option.add_item("MockRobot (no hardware)")
	_source_option.add_item("WebSocket backend (real robot)")
	_source_option.item_selected.connect(func(i): main.use_source("websocket" if i == 1 else "mock"); _append_log("source: " + RobotState.source))
	_vbox.add_child(_source_option)
	var hb := HBoxContainer.new()
	_vbox.add_child(hb)
	_button(hb, "Mock disconnect", func(): main.mock.set_connected(false))
	_button(hb, "Mock reconnect", func(): main.mock.set_connected(true))
	_button(hb, "STOP (space)", func(): main.mock.emergency_stop(); if main.ws.enabled: main.ws.send_command("soft_stop"))
	_button(hb, "E-STOP (ABORT)", func(): main.mock.emergency_stop(); if main.ws.enabled: main.ws.send_command("stop"))
	var hb2 := HBoxContainer.new()
	_vbox.add_child(hb2)
	_button(hb2, "Backend: enable motors", func(): main.ws.send_command("enable_motors", {"enable": true}))
	_button(hb2, "home", func(): main.ws.send_command("home"))
	_button(hb2, "z_zero", func(): main.ws.send_command("z_zero"))
	_button(hb2, "clear_alarm", func(): main.ws.send_command("clear_alarm"))

	_build_gesture()
	_build_cameras()

	_header("Virtual robot target (mm / z units)")
	var r := GameConfig.robot()
	_slider("target_x", "X", r.x_min_mm, r.x_max_mm, main.mock.target.x, 1.0, func(v): main.mock.set_target_axis(0, v); _ws_move())
	_slider("target_y", "Y (front/back)", r.y_min_mm, r.y_max_mm, main.mock.target.y, 1.0, func(v): main.mock.set_target_axis(1, v); _ws_move())
	_slider("target_z", "Z (arm height)", r.z_min_mm, r.z_max_mm, main.mock.target.z, 0.5, func(v): main.mock.set_target_axis(2, v); _ws_z())
	var hb3 := HBoxContainer.new()
	_vbox.add_child(hb3)
	_button(hb3, "XYZ random", func():
		main.mock.set_target(Vector3(randf_range(r.x_min_mm, r.x_max_mm), randf_range(r.y_min_mm, r.y_max_mm), randf_range(r.z_min_mm, r.z_max_mm))); sync_targets_from_mock())
	_button(hb3, "center", func(): main.mock.set_target(Vector3((r.x_min_mm + r.x_max_mm) / 2, (r.y_min_mm + r.y_max_mm) / 2, r.z_max_mm if r.z_up_is_positive else r.z_min_mm)); sync_targets_from_mock())
	_slider("mock_speed", "Mock XY speed mm/s", 20.0, 800.0, main.mock.max_speed_xy, 5.0, func(v): main.mock.max_speed_xy = v)
	_slider("mock_accel", "Mock XY accel mm/s²", 100.0, 6000.0, main.mock.accel_xy, 50.0, func(v): main.mock.accel_xy = v)
	_slider("mock_zspeed", "Mock Z speed", 5.0, 300.0, main.mock.max_speed_z, 1.0, func(v): main.mock.max_speed_z = v)
	_slider("mock_hz", "Mock report rate Hz", 2.0, 60.0, main.mock.report_hz, 1.0, func(v): main.mock.report_hz = v)

	_header("Rope physics")
	_slider("gravity", "Gravity cm/s²", 100.0, 3000.0, main.sim.gravity, 10.0, func(v): main.sim.gravity = v)
	_slider("damping", "Damping /s", 0.0, 4.0, main.sim.damping, 0.01, func(v): main.sim.damping = v)
	_slider("ufo_drag", "UFO drag /s", 0.0, 3.0, main.sim.ufo_drag, 0.01, func(v): main.sim.ufo_drag = v)
	_slider("ufo_mass", "UFO mass", 1.0, 200.0, main.sim.ufo_mass, 1.0, func(v): main.sim.set_ufo_mass(v))
	_slider("segments", "Segments", 2.0, 48.0, main.sim.segment_count, 1.0, func(v): main.sim.segment_count = int(v))
	_slider("substeps", "Solver substeps", 1.0, 32.0, main.sim.substeps, 1.0, func(v): main.sim.substeps = int(v))
	_slider("rope_rate", "Rope reel speed cm/s (0=snap)", 0.0, 400.0, main.sim.rope_length_rate, 5.0, func(v): main.sim.rope_length_rate = v)
	_slider("rope_min", "Rope min cm", 2.0, 60.0, main.sim.min_rope_length, 1.0, func(v): main.sim.min_rope_length = v; GameConfig.data.world.rope_min_cm = v)
	_slider("rope_max", "Rope max cm", 10.0, 120.0, main.sim.max_rope_length, 1.0, func(v): main.sim.max_rope_length = v; GameConfig.data.world.rope_max_cm = v)
	_slider("swing_gain", "Swing exaggeration", 0.5, 3.0, main.sim.swing_gain, 0.05, func(v): main.sim.swing_gain = v)
	_button(_vbox, "Fit X to screen: ON/OFF", func(): GameConfig.data.world.fit_travel_x_to_screen = not bool(GameConfig.data.world.get("fit_travel_x_to_screen", false)))
	_slider("travel_x", "World travel X cm (fit OFF)", 10.0, 150.0, GameConfig.data.world.travel_x_cm, 1.0, func(v): GameConfig.data.world.travel_x_cm = v)
	_slider("travel_z", "World travel depth cm", 5.0, 120.0, GameConfig.data.world.travel_z_cm, 1.0, func(v): GameConfig.data.world.travel_z_cm = v)
	_button(_vbox, "Reset rope (hang straight)", func(): main.sim.reset())

	_header("Projection (2.5D)")
	_slider("pitch", "Camera pitch °", 0.0, 70.0, main.proj.pitch_deg, 1.0, func(v): main.proj.pitch_deg = v)
	_slider("ppu", "Pixels per cm", 2.0, 14.0, main.proj.pixels_per_unit, 0.1, func(v): main.proj.pixels_per_unit = v)
	_slider("persp", "Perspective (scale change)", 0.0, 0.02, main.proj.perspective, 0.0005, func(v): main.proj.perspective = v)
	_slider("depth_scale", "Depth display gain", 0.0, 3.0, main.proj.depth_scale, 0.05, func(v): main.proj.depth_scale = v)
	_slider("xy_scale", "XY display gain", 0.2, 3.0, main.proj.xy_display_scale, 0.05, func(v): main.proj.xy_display_scale = v)
	_slider("rope_w", "Rope width px", 1.0, 16.0, main.rope_view.rope_width_px, 1.0, func(v): main.rope_view.rope_width_px = v)
	_slider("pixel_scale", "Sprite pixel scale", 1.0, 6.0, main.ufo.pixel_scale, 1.0, func(v): main.ufo.pixel_scale = v; main.rope_view.pixel_scale = v)
	_slider("tilt_follow", "UFO tilt follow", 0.0, 1.5, main.ufo.tilt_follow, 0.05, func(v): main.ufo.tilt_follow = v)

	_header("Effects / sound")
	_button(_vbox, "Particles: ON/OFF", func(): main.ufo_fx.enabled = not main.ufo_fx.enabled)
	_button(_vbox, "Sound: ON/OFF", func(): main.sfx.enabled = not main.sfx.enabled)
	_button(_vbox, "Screen shake: ON/OFF", func(): main.shake.enabled = not main.shake.enabled)
	_slider("shake_px", "Shake max px", 0.0, 40.0, main.shake.max_offset_px, 1.0, func(v): main.shake.max_offset_px = v)
	_slider("fx_amount", "Particle amount", 0.0, 2.0, main.ufo_fx.amount, 0.05, func(v): main.ufo_fx.amount = v)
	_slider("sfx_db", "Sound volume dB", -40.0, 6.0, main.sfx.volume_db, 1.0, func(v): main.sfx.volume_db = v)
	_header("Character")
	_expr_option = OptionButton.new()
	_expr_option.add_item("(auto)")
	for e in main.ufo.available_expressions():
		_expr_option.add_item(e)
	_expr_option.item_selected.connect(func(i): main.ufo.manual_expression = "" if i == 0 else _expr_option.get_item_text(i))
	_vbox.add_child(_expr_option)
	var hb4 := HBoxContainer.new()
	_vbox.add_child(hb4)
	_button(hb4, "Success (G)", func(): GameState.post_event("result_success"))
	_button(hb4, "Failure (F)", func(): GameState.post_event("result_failure"))
	_button(hb4, "Error", func(): GameState.post_event("error"))
	_button(hb4, "Clear", func(): GameState.post_event("error_cleared"))

	_header("Test scenarios (mock)")
	var grid := GridContainer.new()
	grid.columns = 2
	_vbox.add_child(grid)
	var scen := [["1 X sweep", "x_sweep"], ["2 Y sweep", "y_sweep"], ["3 XY diagonal", "xy_diagonal"], ["4 Sudden stop", "sudden_stop"],
		["5 Z down/up", "z_down_up"], ["6 XYZ together", "xyz_together"], ["7 Disconnect", "disconnect"], ["8 Reconnect", "reconnect"],
		["9 Limits", "limits"], ["10 Rope snap", "rope_snap"], ["Grab cycle", "grab_cycle"]]
	for s in scen:
		_button(grid, s[0], func(): main.mock.run_scenario(s[1]))

	_header("Log")
	_log = RichTextLabel.new()
	_log.custom_minimum_size = Vector2(0, 160)
	_log.scroll_following = true
	_log.add_theme_font_size_override("normal_font_size", 11)
	_vbox.add_child(_log)
	var help := Label.new()
	help.text = "Keys: arrows=XY  W/S=Z  space=E-stop  V=scope  H=hand gesture  G/F=result  F1=hide panel"
	help.add_theme_font_size_override("font_size", 11)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	_vbox.add_child(help)

## Hand joystick: mode, simulation, live values and tuning.
func _build_gesture() -> void:
	var g: GestureControl = main.gesture
	var j: HandJoystick = g.joystick
	_header("Hand gesture joystick (H)")
	var hb := HBoxContainer.new()
	_vbox.add_child(hb)
	_button(hb, "Gesture: ON/OFF", func(): main.set_gesture_enabled(not g.enabled))
	_button(hb, "Sim hand (mouse): ON/OFF", func(): main.set_gesture_sim(not main.gesture_sim))
	var hb2 := HBoxContainer.new()
	_vbox.add_child(hb2)
	_button(hb2, "Invert X", func(): j.invert_x = not j.invert_x)
	_button(hb2, "Invert Y", func(): j.invert_y = not j.invert_y)
	_button(hb2, "Swap XY", func(): j.swap_xy = not j.swap_xy)
	_button(hb2, "ROI: ON/OFF", func(): g.roi_enabled = not g.roi_enabled)
	_gesture_status = Label.new()
	_gesture_status.add_theme_font_size_override("font_size", 11)
	_vbox.add_child(_gesture_status)
	var gc: Dictionary = GameConfig.data.get("gesture", {})
	_slider("g_pinch_on", "Pinch start (ratio <=)", 0.1, 1.0, float(gc.get("pinch_start", 0.45)), 0.01, func(v): main.send_gesture_config({"pinch_start": v}))
	_slider("g_pinch_off", "Pinch release (ratio >=)", 0.15, 1.5, float(gc.get("pinch_release", 0.65)), 0.01, func(v): main.send_gesture_config({"pinch_release": v}))
	_slider("g_pinch_ms", "Pinch confirm ms", 0.0, 300.0, float(gc.get("pinch_confirm_ms", 80.0)), 5.0, func(v): main.send_gesture_config({"pinch_confirm_ms": v}))
	_slider("g_speed", "Max speed mm/s", 5.0, 50.0, j.max_speed, 1.0, func(v): j.max_speed = v)
	_slider("g_radius", "Stick radius (short side)", 0.05, 0.4, j.radius, 0.01, func(v): j.radius = v)
	_slider("g_dead", "Dead zone (of radius)", 0.0, 0.5, j.deadzone, 0.01, func(v): j.deadzone = v)
	_slider("g_full", "Full speed at (of radius)", 0.3, 1.0, j.full, 0.01, func(v): j.full = v)
	_slider("g_smooth", "Smoothing ms", 0.0, 300.0, j.smoothing_ms, 5.0, func(v): j.smoothing_ms = v)
	_slider("g_stale", "Event expiry ms", 50.0, 500.0, g.stale_ms, 10.0, func(v): g.stale_ms = v)
	_slider("g_roi_x0", "ROI x0", 0.0, 1.0, g.roi.position.x, 0.01, func(v): g.roi = Rect2(Vector2(v, g.roi.position.y), Vector2(g.roi.end.x - v, g.roi.size.y)))
	_slider("g_roi_y0", "ROI y0", 0.0, 1.0, g.roi.position.y, 0.01, func(v): g.roi = Rect2(Vector2(g.roi.position.x, v), Vector2(g.roi.size.x, g.roi.end.y - v)))
	_slider("g_roi_x1", "ROI x1", 0.0, 1.0, g.roi.end.x, 0.01, func(v): g.roi = Rect2(g.roi.position, Vector2(v - g.roi.position.x, g.roi.size.y)))
	_slider("g_roi_y1", "ROI y1", 0.0, 1.0, g.roi.end.y, 0.01, func(v): g.roi = Rect2(g.roi.position, Vector2(g.roi.size.x, v - g.roi.position.y)))

func _update_gesture_status() -> void:
	if _gesture_overlay != null:
		_gesture_overlay.simulated = main.gesture_sim or main._gesture_demo_t >= 0.0
	if _gesture_status == null:
		return
	var g: GestureControl = main.gesture
	var j: HandJoystick = g.joystick
	var now := float(Time.get_ticks_msec())
	var ev: Dictionary = g.last_event
	var src := "mouse (sim)" if main.gesture_sim else ("backend camera %s %dx%d" % [GameConfig.get_value("gesture", "camera", "?"), int(ev.get("frame_w", 0)), int(ev.get("frame_h", 0))])
	_gesture_status.text = "mode %s  state %s%s\nsource: %s  control: %s\nhand %s pinch %s ratio %.2f (on <=%.2f off >=%.2f) conf %.2f hands %d\nstick %+.2f %+.2f  v %+.1f %+.1f mm/s\nlatency %.0f ms  age %s  events %d dropped %d\ninvert X %s Y %s swap %s  ROI %s %s\ngate: %s" % [
		"ON" if g.enabled else "off", g.state_name(), (" (%s)" % g.reason) if g.reason != "" else "",
		src, main.control_source,
		"yes" if g.detected else "no", "YES" if g.pinch else "no", g.pinch_ratio, float(GameConfig.get_value("gesture", "pinch_start", 0.45)), float(GameConfig.get_value("gesture", "pinch_release", 0.65)), float(ev.get("confidence", 0.0)), int(ev.get("hand_count", 0)),
		j.stick.x, j.stick.y, g.velocity.x, g.velocity.y,
		g.latency_ms, ("%.0f ms" % g.age_ms(now)) if g.age_ms(now) >= 0.0 else "-", g.events, g.dropped,
		j.invert_x, j.invert_y, j.swap_xy, "ON" if g.roi_enabled else "off",
		"[%.2f %.2f %.2f %.2f]" % [g.roi.position.x, g.roi.position.y, g.roi.end.x, g.roi.end.y],
		main.gesture_gate_reason if main.gesture_gate_reason != "" else "ok"]

## Both USB cameras at their full field of view (no crop, real aspect), each
## with a picker for which camera plays that role.
func _build_cameras() -> void:
	var hub: CameraHub = main.cameras
	_header("Cameras (full frame)")
	for role in CameraHub.ROLES:
		var row := HBoxContainer.new()
		_vbox.add_child(row)
		var l := Label.new()
		l.text = "Overview (desk / gesture)" if role == "overview" else "Focus (arm tip)"
		l.custom_minimum_size.x = 150
		l.add_theme_font_size_override("font_size", 11)
		row.add_child(l)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.add_theme_font_size_override("font_size", 11)
		opt.item_selected.connect(func(i): hub.assign(role, opt.get_item_id(i)))
		row.add_child(opt)
		var view := TextureRect.new()
		view.texture = hub.texture(role)
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		view.custom_minimum_size = Vector2(PANEL_W - 24, (PANEL_W - 24) * 0.75)
		_vbox.add_child(view)
		if role == "overview":
			# the gesture camera: what the hand joystick detects, drawn over the frame
			var overlay := GestureCameraOverlay.new()
			overlay.gesture = main.gesture
			var c = GameConfig.get_value("camera", role, {})
			if c is Dictionary:
				overlay.flip_h = bool(c.get("flip_h", false))
				overlay.flip_v = bool(c.get("flip_v", false))
			view.add_child(overlay)
			_gesture_overlay = overlay
		var info := Label.new()
		info.add_theme_font_size_override("font_size", 10)
		_vbox.add_child(info)
		_cam_ui[role] = {"option": opt, "view": view, "info": info}
	var hb := HBoxContainer.new()
	_vbox.add_child(hb)
	_button(hb, "Scope open/close (V)", func(): main.scope_trigger.toggle())
	_button(hb, "Scope: ON/OFF", func(): main.scope_enabled = not main.scope_enabled)
	_slider("scope_zoom", "Scope zoom", 1.0, 4.0, main.scope.zoom, 0.1, func(v): main.scope.zoom = v)
	hub.feeds_changed.connect(_refresh_camera_options)
	_refresh_camera_options()

func _refresh_camera_options() -> void:
	var hub: CameraHub = main.cameras
	var feeds := hub.feed_list()
	for role in _cam_ui.keys():
		var opt: OptionButton = _cam_ui[role].option
		opt.clear()
		opt.add_item("(none)", -1)
		for f in feeds:
			opt.add_item(str(f.name), int(f.id))
		opt.select(maxi(opt.get_item_index(hub.feed_id(role)), 0))

func _update_cameras() -> void:
	var hub: CameraHub = main.cameras
	for role in _cam_ui.keys():
		var ui: Dictionary = _cam_ui[role]
		var w := PANEL_W - 24
		ui.view.custom_minimum_size = Vector2(w, w / hub.feed_aspect(role))
		var s := hub.feed_size(role)
		ui.info.text = ("%s  %dx%d" % [hub.feed_name(role), s.x, s.y]) if hub.has_feed(role) else "NO SIGNAL (pick a camera above, or set camera.%s.match)" % role

func _header(t: String) -> void:
	var l := Label.new()
	l.text = "▸ " + t
	l.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	l.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(l)

func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _slider(key: String, label: String, lo: float, hi: float, val: float, step: float, cb: Callable) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 150
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 48
	v.add_theme_font_size_override("font_size", 11)
	v.text = _fmt(val)
	row.add_child(v)
	s.value_changed.connect(func(x): v.text = _fmt(x); cb.call(x))
	_vbox.add_child(row)
	_sliders[key] = s

func _fmt(x: float) -> String:
	if absf(x - roundf(x)) < 1e-6:
		return "%d" % int(roundf(x))
	if absf(x) >= 10.0:
		return "%.1f" % x
	if absf(x) >= 0.1:
		return "%.2f" % x
	return "%.4f" % x

func sync_targets_from_mock() -> void:
	for k in ["target_x", "target_y", "target_z"]:
		if _sliders.has(k):
			var s: HSlider = _sliders[k]
			var axis := ["target_x", "target_y", "target_z"].find(k)
			s.set_value_no_signal(main.mock.target[axis])

func _ws_move() -> void:
	if main.ws.enabled:
		main.ws.send_command("move_xy", {"x": _sliders.target_x.value, "y": _sliders.target_y.value})

func _ws_z() -> void:
	if main.ws.enabled:
		main.ws.send_command("move_z", {"z": _sliders.target_z.value})

func _append_log(t: String) -> void:
	_log_lines.append(t)
	if _log_lines.size() > 60:
		_log_lines.remove_at(0)
	if _log != null:
		_log.text = "\n".join(_log_lines)

func _process(_dt: float) -> void:
	if main == null:
		return
	_update_cameras()
	_update_gesture_status()
	var fps := Engine.get_frames_per_second()
	var sim: RopeSimulator = main.sim
	var pose := Vector3(RobotState.x_mm, RobotState.y_mm, RobotState.z_mm)
	_status.text = "FPS %d | physics %d µs | pts %d substeps %d\nrobot x=%.1f y=%.1f z=%.1f (%s)  travelX %.0f cm %s\nrope %.1f→%.1f cm  realised %.1f  anchor→ufo %.1f\nufo v=%.0f cm/s  face=%s" % [
		fps, main.physics_usec, sim.points.size(), sim.substeps,
		pose.x, pose.y, pose.z, "measured" if RobotState.position_is_measured else "estimated",
		RobotState.travel_x_cm(), "(fit)" if GameConfig.data.world.get("fit_travel_x_to_screen", false) else "(fixed)",
		sim.rope_length, sim.target_rope_length, sim.realised_length(), sim.anchor_to_ufo_distance(),
		sim.ufo_velocity().length(), main.ufo.current_face()]
	var conn := "CONNECTED" if RobotState.connected else "DISCONNECTED"
	_state_chip.text = "[%s] %s  machine=%s  game=%s  motors=%s  homed=%s" % [RobotState.source, conn, RobotState.machine_state, GameState.state, "ON" if RobotState.motors_enabled else "off", "YES" if RobotState.homed else "no"]
	# a refused arrow-key jog (or a firmware-side refusal) shows what to do next
	var hint: String = main.jog_hint
	if hint == "" and RobotState.source == "websocket" and RobotState.robot_error.begins_with("jog rejected"):
		hint = main.jog_hint_for(RobotState.robot_error.trim_prefix("jog rejected: "))
	if RobotState.source == "websocket" and RobotState.connected and not RobotState.z_reference_set:
		hint += ("\n" if hint != "" else "") + "Z: 基準が未設定（アームが動いても画面に出ない）。W でアームを一番上まで上げて「z_zero」を押す"
	if hint != "":
		_state_chip.text += "\nJOG: " + hint
	var ok_color := Color(0.4, 1.0, 0.5) if RobotState.connected else Color(1.0, 0.5, 0.4)
	_state_chip.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3) if hint != "" else ok_color)
