extends CanvasLayer
## Debug / tuning overlay. State and the stops stay on top; the rest is in tabs:
## hardware tests (Z drum, claw, moves), hand gesture, cameras, look (rope,
## projection, effects, character), the MockRobot and its scenarios, the log.
## Built in code (no .tscn editing needed). Toggle with F1 / Tab. Its controls
## never take keyboard focus, so Space and the arrows always reach the game.

const PANEL_W := 360.0
const LOG_MAX := 500
const MINI_LOG_LINES := 6

var main: Node2D
var _panel: PanelContainer
var _vbox: VBoxContainer
var _sliders: Dictionary = {}
var _status: Label
var _log: RichTextLabel
var _mini_log: Label
var _log_dirty := false
var _expr_option: OptionButton
var _source_option: OptionButton
var _state_chip: Label
var _log_lines: PackedStringArray = PackedStringArray()
## role -> {"option": OptionButton, "view": TextureRect, "info": Label}
var _cam_ui: Dictionary = {}
var _gesture_status: Label
var _claw_label: Label
var _z_label: Label
var _claw_marks_label: Label
var _tabs: TabContainer
var _gesture_overlay: GestureCameraOverlay

func panel_width() -> float:
	return PANEL_W if visible else 0.0

func setup(m: Node2D) -> void:
	main = m
	_build()
	main.ws.log_line.connect(_append_log)
	main.debug_log.connect(_append_log)
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
	style.content_margin_left = 6
	style.content_margin_right = 4
	style.content_margin_top = 4
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var root := VBoxContainer.new()
	_panel.add_child(root)

	# always on top: state, the stops, which robot
	_vbox = root
	_state_chip = Label.new()
	_state_chip.add_theme_font_size_override("font_size", 12)
	_state_chip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_state_chip)
	var stops := HBoxContainer.new()
	root.add_child(stops)
	_button(stops, "STOP (space)", func(): main.mock.emergency_stop(); if main.ws.enabled: main.ws.send_command("soft_stop")).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var estop := _button(stops, "E-STOP (ABORT)", func(): main.mock.emergency_stop(); if main.ws.enabled: main.ws.send_command("stop"))
	estop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	estop.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	_source_option = OptionButton.new()
	_source_option.add_theme_font_size_override("font_size", 11)
	_source_option.focus_mode = Control.FOCUS_NONE
	_source_option.add_item("MockRobot (no hardware)")
	_source_option.add_item("WebSocket backend (real robot)")
	_source_option.item_selected.connect(func(i): main.use_source("websocket" if i == 1 else "mock"); _append_log("source: " + RobotState.source))
	root.add_child(_source_option)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", 11)
	_tabs.get_tab_bar().focus_mode = Control.FOCUS_NONE
	root.add_child(_tabs)

	_tab("実機")
	_build_robot_test()
	_tab("ジェスチャー")
	_build_gesture()
	_tab("カメラ")
	_build_cameras()
	_tab("見た目")
	_build_look()
	_tab("モック")
	_build_mock()
	_tab("ログ")
	_note("ゲーム・バックエンド・シリアル（TX = 送信、RX = ファームウェアから）の行。POS / JOG_POS の定期報告は省く。")
	_log_buttons(_vbox)
	_log = RichTextLabel.new()
	_log.custom_minimum_size = Vector2(0, 460)
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.focus_mode = Control.FOCUS_NONE
	_log.add_theme_font_size_override("normal_font_size", 10)
	_vbox.add_child(_log)

	# the last few lines stay in view whatever the tab, with the copy button
	var mini_head := HBoxContainer.new()
	root.add_child(mini_head)
	var mini_title := Label.new()
	mini_title.text = "Log"
	mini_title.add_theme_font_size_override("font_size", 11)
	mini_title.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	mini_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mini_head.add_child(mini_title)
	_log_buttons(mini_head)
	_mini_log = Label.new()
	_mini_log.add_theme_font_size_override("font_size", 10)
	_mini_log.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_mini_log.clip_text = true
	_mini_log.custom_minimum_size.y = MINI_LOG_LINES * 13
	root.add_child(_mini_log)

	var help := Label.new()
	help.text = "Keys: arrows=XY  W/S=Z  [ ]=claw  Q/A=open/close  space=stop  V=scope  H=gesture  G/F=result  F1=hide"
	help.add_theme_font_size_override("font_size", 10)
	help.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(help)

## Hardware tests: get ready, the Z drum (servo 1), the claw (servo 2), and
## moving to a position.
func _build_robot_test() -> void:
	_header("1. 準備")
	var hb := HBoxContainer.new()
	_vbox.add_child(hb)
	_button(hb, "モーター有効", func(): main.ws.send_command("enable_motors", {"enable": true}))
	_button(hb, "原点復帰 (home)", func(): main.ws.send_command("home"))
	_button(hb, "アラーム解除", func(): main.ws.send_command("clear_alarm"))
	_note("巻き上げと爪は「モーター有効」だけで動く。XY の移動には原点復帰が要る。")

	_header("2. 巻き上げ（Z・サーボ 1）")
	_z_label = Label.new()
	_z_label.add_theme_font_size_override("font_size", 12)
	_z_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_z_label)
	var hz := HBoxContainer.new()
	_vbox.add_child(hz)
	_hold_button(hz, "▲ 上げる (W)", 1.0)
	_hold_button(hz, "▼ 下げる (S)", -1.0)
	_button(hz, "z_zero", func(): main.ws.send_command("z_zero"))
	_note("ボタンは押している間だけ動く。アームを一番上まで上げて z_zero を押すと高さが画面に出る。")
	_slider("z_speed", "上げ下げの速さ (z/s, 実機)", 3.0, 40.0, main.jog_speed_real_z, 1.0, func(v): main.jog_speed_real_z = v)

	_header("3. 爪（サーボ 2）")
	_claw_label = Label.new()
	_claw_label.add_theme_font_size_override("font_size", 12)
	_claw_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_claw_label)
	var hc := HBoxContainer.new()
	_vbox.add_child(hc)
	for d in [-10.0, -1.0, 1.0, 10.0]:
		_button(hc, "%+d°" % int(d), func(): main.arm_step(d)).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(_vbox, "arm_zero（いまの角度を 0° にする）", func(): main.arm_zero())
	var hs := HBoxContainer.new()
	_vbox.add_child(hs)
	_button(hs, "ここを閉じ位置に", func(): main.arm_set("closed")).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(hs, "ここを開き位置に", func(): main.arm_set("open")).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hg := HBoxContainer.new()
	_vbox.add_child(hg)
	_button(hg, "閉じる (A)", func(): main.arm_goto("closed")).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(hg, "開く (Q)", func(): main.arm_goto("open")).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_claw_marks_label = Label.new()
	_claw_marks_label.add_theme_font_size_override("font_size", 11)
	_claw_marks_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_claw_marks_label)
	_note("少しずつ回して閉じた所で「ここを閉じ位置に」、開いた所で「ここを開き位置に」。記録は保存され、掴む / 離す（grab）もこの角度を使う。")
	_slider("arm_step", "[ / ] キー 1 回の角度 (°)", 0.5, 30.0, main.arm_step_deg, 0.5, func(v): main.arm_step_deg = v)

	var box := _fold("位置を指定して移動 (move_xy / move_z)")
	var r := GameConfig.robot()
	_slider("target_x", "X", r.x_min_mm, r.x_max_mm, main.mock.target.x, 1.0, func(v): main.mock.set_target_axis(0, v); _ws_move())
	_slider("target_y", "Y (front/back)", r.y_min_mm, r.y_max_mm, main.mock.target.y, 1.0, func(v): main.mock.set_target_axis(1, v); _ws_move())
	_slider("target_z", "Z (arm height)", r.z_min_mm, r.z_max_mm, main.mock.target.z, 0.5, func(v): main.mock.set_target_axis(2, v); _ws_z())
	var hb3 := HBoxContainer.new()
	_vbox.add_child(hb3)
	_button(hb3, "XYZ random", func():
		main.mock.set_target(Vector3(randf_range(r.x_min_mm, r.x_max_mm), randf_range(r.y_min_mm, r.y_max_mm), randf_range(r.z_min_mm, r.z_max_mm))); sync_targets_from_mock())
	_button(hb3, "center", func(): main.mock.set_target(Vector3((r.x_min_mm + r.x_max_mm) / 2, (r.y_min_mm + r.y_max_mm) / 2, r.z_max_mm if r.z_up_is_positive else r.z_min_mm)); sync_targets_from_mock())
	_end_fold(box)

## Rope, projection, effects and the character: how the game looks.
func _build_look() -> void:
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_vbox.add_child(_status)
	var box := _fold("Rope physics")
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
	_end_fold(box)

	box = _fold("Projection (2.5D)")
	_slider("pitch", "Camera pitch °", 0.0, 70.0, main.proj.pitch_deg, 1.0, func(v): main.proj.pitch_deg = v)
	_slider("ppu", "Pixels per cm", 2.0, 14.0, main.proj.pixels_per_unit, 0.1, func(v): main.proj.pixels_per_unit = v)
	_slider("persp", "Perspective (scale change)", 0.0, 0.02, main.proj.perspective, 0.0005, func(v): main.proj.perspective = v)
	_slider("depth_scale", "Depth display gain", 0.0, 3.0, main.proj.depth_scale, 0.05, func(v): main.proj.depth_scale = v)
	_slider("xy_scale", "XY display gain", 0.2, 3.0, main.proj.xy_display_scale, 0.05, func(v): main.proj.xy_display_scale = v)
	_slider("rope_w", "Rope width px", 1.0, 16.0, main.rope_view.rope_width_px, 1.0, func(v): main.rope_view.rope_width_px = v)
	_slider("pixel_scale", "Sprite pixel scale", 1.0, 6.0, main.ufo.pixel_scale, 1.0, func(v): main.ufo.pixel_scale = v; main.rope_view.pixel_scale = v)
	_slider("tilt_follow", "UFO tilt follow", 0.0, 1.5, main.ufo.tilt_follow, 0.05, func(v): main.ufo.tilt_follow = v)
	_end_fold(box)

	box = _fold("Effects / sound")
	var hf := HBoxContainer.new()
	_vbox.add_child(hf)
	_button(hf, "Particles", func(): main.ufo_fx.enabled = not main.ufo_fx.enabled)
	_button(hf, "Sound", func(): main.sfx.enabled = not main.sfx.enabled)
	_button(hf, "Shake", func(): main.shake.enabled = not main.shake.enabled)
	_note("ボタンで ON/OFF を切り替え")
	_slider("shake_px", "Shake max px", 0.0, 40.0, main.shake.max_offset_px, 1.0, func(v): main.shake.max_offset_px = v)
	_slider("fx_amount", "Particle amount", 0.0, 2.0, main.ufo_fx.amount, 0.05, func(v): main.ufo_fx.amount = v)
	_slider("sfx_db", "Sound volume dB", -40.0, 6.0, main.sfx.volume_db, 1.0, func(v): main.sfx.volume_db = v)
	_end_fold(box)

	_header("Character")
	_expr_option = OptionButton.new()
	_expr_option.add_theme_font_size_override("font_size", 11)
	_expr_option.focus_mode = Control.FOCUS_NONE
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

## The GDScript MockRobot: link faults, dynamics and the scripted scenarios.
func _build_mock() -> void:
	_header("Link")
	var hb := HBoxContainer.new()
	_vbox.add_child(hb)
	_button(hb, "Mock disconnect", func(): main.mock.set_connected(false))
	_button(hb, "Mock reconnect", func(): main.mock.set_connected(true))
	_header("Dynamics")
	_slider("mock_speed", "Mock XY speed mm/s", 20.0, 800.0, main.mock.max_speed_xy, 5.0, func(v): main.mock.max_speed_xy = v)
	_slider("mock_accel", "Mock XY accel mm/s²", 100.0, 6000.0, main.mock.accel_xy, 50.0, func(v): main.mock.accel_xy = v)
	_slider("mock_zspeed", "Mock Z speed", 5.0, 300.0, main.mock.max_speed_z, 1.0, func(v): main.mock.max_speed_z = v)
	_slider("mock_hz", "Mock report rate Hz", 2.0, 60.0, main.mock.report_hz, 1.0, func(v): main.mock.report_hz = v)
	_header("Test scenarios")
	var grid := GridContainer.new()
	grid.columns = 2
	_vbox.add_child(grid)
	var scen := [["1 X sweep", "x_sweep"], ["2 Y sweep", "y_sweep"], ["3 XY diagonal", "xy_diagonal"], ["4 Sudden stop", "sudden_stop"],
		["5 Z down/up", "z_down_up"], ["6 XYZ together", "xyz_together"], ["7 Disconnect", "disconnect"], ["8 Reconnect", "reconnect"],
		["9 Limits", "limits"], ["10 Rope snap", "rope_snap"], ["Grab cycle", "grab_cycle"]]
	for sc in scen:
		_button(grid, sc[0], func(): main.mock.run_scenario(sc[1])).size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _update_robot_test() -> void:
	if _z_label != null:
		var zref := "基準: モック" if RobotState.source != "websocket" else ("基準: 設定済み" if RobotState.z_reference_set else "基準: 未設定（一番上で z_zero）")
		_z_label.text = "Z = %.1f  (%s)  %s" % [RobotState.z_mm, "測定" if RobotState.position_is_measured else "推定", zref]
	if _claw_marks_label != null:
		var c: float = RobotState.arm_closed_deg
		var o: float = RobotState.arm_open_deg
		var sp: float = RobotState.arm_span_deg
		_claw_marks_label.text = "記録（サーボの 1 回転内の角度）: 閉じ %s / 開き %s%s" % [
			"未設定" if is_nan(c) else "%.1f°" % c, "未設定" if is_nan(o) else "%.1f°" % o,
			"" if is_nan(sp) else "（閉じ→開き %+.1f°）" % sp]
	if _claw_label == null:
		return
	var a: float = RobotState.arm_deg
	if is_nan(a):
		_claw_label.text = "爪: 角度はまだ読んでいない（1 回回すか arm_zero を押す）"
	elif RobotState.arm_reference_set:
		_claw_label.text = "爪: arm_zero から %+.1f°" % a
	else:
		_claw_label.text = "爪: %.1f°（1 回転の中の角度。arm_zero で 0° にできる）" % a

## Hand joystick: mode, simulation, live values and tuning.
func _build_gesture() -> void:
	var g: GestureControl = main.gesture
	var j: HandJoystick = g.joystick
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
	_note("検出の様子はカメラタブの Overview に重ねて出る")
	var box := _fold("感度・速度・ROI")
	var gc: Dictionary = GameConfig.data.get("gesture", {})
	_slider("g_pinch_on", "Pinch start (ratio <=)", 0.1, 1.0, float(gc.get("pinch_start", 1.0)), 0.01, func(v): main.send_gesture_config({"pinch_start": v}))
	_slider("g_pinch_off", "Pinch release (ratio >=)", 0.15, 1.5, float(gc.get("pinch_release", 1.5)), 0.01, func(v): main.send_gesture_config({"pinch_release": v}))
	_slider("g_pinch_ms", "Pinch confirm ms", 0.0, 300.0, float(gc.get("pinch_confirm_ms", 0.0)), 5.0, func(v): main.send_gesture_config({"pinch_confirm_ms": v}))
	_slider("g_lost_ms", "Lost-hand grace ms", 0.0, 600.0, float(gc.get("lost_grace_ms", 300.0)), 10.0, func(v): main.send_gesture_config({"lost_grace_ms": v}))
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
	_end_fold(box)

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
		opt.focus_mode = Control.FOCUS_NONE
		opt.item_selected.connect(func(i): hub.assign(role, opt.get_item_id(i)))
		row.add_child(opt)
		var view := TextureRect.new()
		view.texture = hub.texture(role)
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		view.custom_minimum_size = Vector2(_inner_w(), _inner_w() * 0.75)
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
		var w := _inner_w()
		ui.view.custom_minimum_size = Vector2(w, w / hub.feed_aspect(role))
		var s := hub.feed_size(role)
		ui.info.text = ("%s  %dx%d" % [hub.feed_name(role), s.x, s.y]) if hub.has_feed(role) else "NO SIGNAL (pick a camera above, or set camera.%s.match)" % role

## A new tab, scrolling; the helpers below add to it.
func _tab(title: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, title)
	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.custom_minimum_size.x = _inner_w()
	scroll.add_child(_vbox)

func _inner_w() -> float:
	return PANEL_W - 34

## A closed-by-default section: the helpers add to it until _end_fold(the
## returned outer box).
func _fold(title: String) -> VBoxContainer:
	var outer := _vbox
	var head := Button.new()
	head.flat = true
	head.focus_mode = Control.FOCUS_NONE
	head.toggle_mode = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	outer.add_child(head)
	var body := VBoxContainer.new()
	body.visible = false
	outer.add_child(body)
	head.text = "▸ " + title
	head.toggled.connect(func(on): body.visible = on; head.text = ("▾ " if on else "▸ ") + title)
	_vbox = body
	return outer

func _end_fold(outer: VBoxContainer) -> void:
	_vbox = outer

func _note(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(l)

## Moves Z while held (like W / S); main clears it once the mouse button is up.
func _hold_button(parent: Node, text: String, dir: float) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 12)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.button_down.connect(func(): main.ui_jog_z = dir)
	b.button_up.connect(func(): main.ui_jog_z = 0.0)
	parent.add_child(b)
	return b

func _header(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	l.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(l)

func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 11)
	b.focus_mode = Control.FOCUS_NONE  # Space (stop) and the arrows stay with the game
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
	s.focus_mode = Control.FOCUS_NONE  # a focused slider would also eat the arrow keys
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

func _log_buttons(parent: Node) -> void:
	_button(parent, "ログをコピー", copy_log)
	_button(parent, "クリア", func(): _log_lines.clear(); _log_dirty = true)

func _append_log(t: String) -> void:
	var now := Time.get_time_dict_from_system()
	_log_lines.append("%02d:%02d:%02d.%03d %s" % [now.hour, now.minute, now.second, Time.get_ticks_msec() % 1000, t])
	if _log_lines.size() > LOG_MAX:
		_log_lines.remove_at(0)
	_log_dirty = true  # redrawn once per frame: serial lines can come in bursts

func _refresh_log() -> void:
	if not _log_dirty:
		return
	_log_dirty = false
	if _log != null:
		_log.text = "\n".join(_log_lines)
	if _mini_log != null:
		_mini_log.text = "\n".join(_log_lines.slice(maxi(_log_lines.size() - MINI_LOG_LINES, 0)))

## The state at this moment and the whole log, for pasting into a bug report.
func log_report() -> String:
	var lines := PackedStringArray()
	lines.append("CoreXY UFO debug log  %s" % Time.get_datetime_string_from_system(false, true))
	lines.append(_state_chip.text if _state_chip != null else "")
	lines.append("robot: source=%s connected=%s machine=%s motors=%s homed=%s z=%.1f z_ref=%s arm_deg=%s backend=%s" % [
		RobotState.source, RobotState.connected, RobotState.machine_state, RobotState.motors_enabled, RobotState.homed,
		RobotState.z_mm, RobotState.z_reference_set, "-" if is_nan(RobotState.arm_deg) else "%.1f" % RobotState.arm_deg,
		main.ws.server_robot if main.ws.enabled else "off"])
	lines.append("game=%s control=%s window_focus=%s gesture=%s" % [GameState.state, main.control_source,
		main.get_window().has_focus(), main.gesture.state_name() if main.gesture.enabled else "off"])
	lines.append("---")
	lines.append_array(_log_lines)
	return "\n".join(lines)

func copy_log() -> void:
	DisplayServer.clipboard_set(log_report())
	_append_log("(log copied to the clipboard: %d lines)" % _log_lines.size())

func _process(_dt: float) -> void:
	if main == null:
		return
	_update_cameras()
	_update_gesture_status()
	_update_robot_test()
	_refresh_log()
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
		hint += ("\n" if hint != "" else "") + "Z: 基準が未設定（アームが動いても画面に出ない）。W か「実機」タブの ▲ でアームを一番上まで上げて「z_zero」を押す"
	if hint != "":
		_state_chip.text += "\nJOG: " + hint
	var ok_color := Color(0.4, 1.0, 0.5) if RobotState.connected else Color(1.0, 0.5, 0.4)
	_state_chip.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3) if hint != "" else ok_color)
