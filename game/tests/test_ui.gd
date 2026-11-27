extends "res://tests/test_base.gd"
## The screens: title, settings, calibration, device test, debug panel, VFX, fonts.

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
	# #167: the preparation's status reaches RobotState (message and robot_state)
	game.ws._handle({"type": "calibration_prepare", "data": {"active": true, "step": "home", "steps": []}})
	var prep_seen: bool = rs.calibration_prepare.get("step", "") == "home"
	game.ws._handle({"type": "robot_state", "timestamp": 0, "data": {"connected": true, "state": "IDLE",
		"x": 0.0, "y": 0.0, "z": 100.0, "calibration_prepare": {"active": false, "last_result": "done", "steps": []}}})
	_ok(prep_seen and rs.calibration_prepare.get("last_result", "") == "done",
		"calibration prepare: its progress messages and robot_state reach RobotState", str(rs.calibration_prepare))
	rs.calibration_prepare = {}
	# #163: a servo the firmware refuses until its power is cut and restored: said in the panel
	game.ws._handle({"type": "robot_state", "timestamp": 0, "data": {"connected": true, "homed": false, "motors_enabled": true,
		"state": "IDLE", "x": 0.0, "y": 0.0, "z": 100.0, "z_servo_power_cycle": true}})
	game.debug_ui._process(0.0)
	var refused_chip := str(game.debug_ui._state_chip.text)
	var refused_ok: bool = rs.z_servo_power_cycle and not rs.arm_servo_power_cycle and refused_chip.contains("電源")
	game.ws._handle({"type": "robot_state", "timestamp": 0, "data": {"connected": true, "homed": false, "motors_enabled": true,
		"state": "IDLE", "x": 0.0, "y": 0.0, "z": 100.0}})
	game.debug_ui._process(0.0)
	_ok(refused_ok and not rs.z_servo_power_cycle and not str(game.debug_ui._state_chip.text).contains("サーボの電源"),
		"servo power cycle: robot_state's flag reaches RobotState and the panel's hint, and goes with it", refused_chip)
	remove_child(game)
	game.free()
	rs.auto_catch = {}
	rs.source = "mock"
	rs.connected = false
	rs.clear_samples()

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
	game._unhandled_input(_key(KEY_G))
	_ok(game.settings_active() and game.title_active(), "settings: the title's keys do not reach through it")
	# #126: each section of the schema is a card holding its own rows
	var in_card := true
	for key in st._rows.keys():
		var n: Node = st._rows[key].control
		while n != null and not (n is PanelContainer and st.cards.has(n)):
			n = n.get_parent()
		in_card = in_card and n != null
	_ok(st.cards.size() == (GameConfig.schema.get("sections", []) as Array).size() and in_card and not st._rows.is_empty(),
		"settings: one card per section, every setting inside its card (#126)", str(st.cards.size()))
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
	st.set_form_value("study_mode.demo.source", "simulated")  # the default is camera since #110
	st.set_form_value("audio.volume_db", -20.0)
	var marked: bool = (st._rows["study.provider"].label as Label).text.ends_with("＊")
	var err := st.save()
	var saved = GameConfig.read_json(path)
	_ok(game.study_mode.services.mode == "simulated" and is_equal_approx(game.sfx.volume_db, -20.0),
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
		and saved == {"audio": {"volume_db": -20.0}, "study": {"provider": "codex"}, "study_mode": {"demo": {"source": "simulated"}}}
		and GameConfig.value("study.provider") == "codex" and GameConfig.base_value("study.provider") == base_provider,
		"settings: 保存 writes only the changed keys to local_settings.json and uses them", str(saved))
	game.open_settings()
	var shown: bool = st.form_value("study.provider") == "codex" and is_equal_approx(float(st.form_value("audio.volume_db")), -20.0)
	_ok(shown and GameConfig.save_local({"robot.x_max_mm": 1.0}) != "" and GameConfig.read_json(path) == saved,
		"settings: it reopens with the saved values; a key outside the schema is refused")
	GameConfig.load_local()
	_ok(GameConfig.local == {"study.provider": "codex", "study_mode.demo.source": "simulated", "audio.volume_db": -20.0},
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

## #108: the テスト tab drives the peripherals' hub like UFO-DeviceHub's console.
func _test_device_test_tab(rs: Node) -> void:
	var game := _study_game()
	var st: SettingsScreen = game.settings
	game.show_title()
	game.open_settings()
	st.show_tab(SettingsScreen.TEST_TAB)
	var p: DeviceTestPanel = st.tests
	st._process(0.0)
	var no_backend: bool = st.testing() and not game.calibrating() and p._hub.text.contains("つながっていない") \
		and _find_button(p, "適用").disabled and not st._save_b.visible and st._cancel_b.text.begins_with("閉じる")
	_ok(no_backend, "device test: the テスト tab shows, without a backend its buttons cannot be pressed (and say why)")
	p._lm_mode.select(DeviceTestPanel.LIGHT_MODES.find("GAME_PLAY"))
	p._lm_color.color = Color8(255, 136, 0)
	var lp := p.light_params()
	_ok(lp.mode == "GAME_PLAY" and lp.brightness == 160 and lp.speed == 128 and lp.transition_ms == 500
		and lp.color == [255, 136, 0], "device test: SET_LIGHT_MODE as the console sends it", JSON.stringify(lp))
	# the backend's answers and the hub's events
	game.ws.ack.emit("m", true, {"command": "devicehub_meta", "connected": true, "system_id": 1,
		"port": "/dev/cu.usbmodem1", "session_id": 7})
	game.ws.ack.emit("d", true, {"command": "devicehub_devices", "devices": [
		{"id": 16.0, "name": "Ill", "online": true, "state": "NORMAL", "session_ok": true},
		{"id": 32.0, "name": "Dial", "online": false}]})
	game.ws.ack.emit("s", true, {"command": "devicehub_status", "device": 16.0, "status": {"state": "NORMAL",
		"op_mode": "GAME", "mist_pattern": "PUFF", "mist_on": true, "mist_remaining_s": 30, "light_mode": "AURORA",
		"brightness": 160, "fw": "0.1"}})
	game.ws.ack.emit("c", true, {"command": "devicehub_command", "result": {"destination": 32.0,
		"name": "ARM_RECEIVER", "result": "REJECTED_STATE", "ok": false}})
	game.ws.message_received.emit({"type": "devicehub_event", "data": {"time": "12:00:00.000", "source": 32,
		"name": "BALL_RECEIVED", "data": {"cycle": 1}}})
	game.ws.message_received.emit({"type": "devicehub_event", "data": {"time": "12:00:01.000", "source": null,
		"name": "HUB_CONNECTED", "data": {}}})
	p.refresh()
	st._process(0.0)
	_ok(p._hub.text.contains("接続") and p._hub.text.contains("usbmodem1") and p._dev.text.contains("● Illumination")
		and p._dev.text.contains("○ M5Dial 1") and p._ill_kv.text.contains("PUFF") and p._ill_kv.text.contains("AURORA")
		and p._log.text.contains("M5Dial 1  BALL_RECEIVED {\"cycle\":1}") and p._log.text.contains("hub  HUB_CONNECTED")
		and p._log.text.contains("✗ M5Dial 1 → ARM_RECEIVER: REJECTED_STATE")
		and st._status.text.contains("REJECTED_STATE"),
		"device test: the hub, the devices, the status, a refused command and an event are shown", p._log.text)
	game.ws.ack.emit("sa", true, {"command": "devicehub_stop_all", "results": {"16": {"ok": true, "result": "ACCEPTED"},
		"32": {"ok": false, "result": "OFFLINE"}}})
	var partial: String = p.result_text
	var partial_bad: bool = not p.result_ok
	game.ws.ack.emit("sb", true, {"command": "devicehub_stop_all", "results": {"16": {"ok": true, "result": "ACCEPTED"}}})
	_ok(partial_bad and partial.contains("M5Dial 1") and p.result_ok and p.result_text.contains("すべて止めた"),
		"device test: STOP ALL is a success only when every device accepted it (review on #109)", partial)
	game.ws.ack.emit("w", true, {"command": "devicehub_meta", "connected": false, "system_id": 1, "port": "/dev/cu.usbmodem101",
		"session_id": 0, "problem": "ポート /dev/cu.usbmodem101 のハブは別のシステムのもの（this hub is system 2）。設定のシステム番号は 1"})
	p.refresh()
	_ok(p._hub.text.contains("接続待ち") and p._hub.text.contains("別のシステム") and p._hub.text.contains("システム番号は 1"),
		"device test: a hub that does not connect says why (another UFO system's hub)", p._hub.text)
	game.ws.ack.emit("x", false, {"command": "devicehub_meta", "reason": "周辺機器のハブを使っていない"})
	p.refresh()
	_ok(p._hub.text.contains("使っていない"), "device test: no hub in the backend says how to turn it on", p._hub.text)
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(not game.settings_active() and not st.testing(), "device test: Esc closes the screen")
	remove_child(game)
	game.free()
	rs.clear_samples()

## #230: the プリント tab tries the worksheet reader (POST /v1/sheet) with a connected camera: the
## frame is cut out and turned upright before it is sent; what was sent and the answer are shown.
func _test_sheet_check_tab(rs: Node) -> void:
	var game := _study_game()
	var st: SettingsScreen = game.settings
	var p: SheetCheckPanel = st.sheet
	p.settings_path = ""  # never the player's own user://sheet_check.cfg
	p.rotations = {}
	p.regions = {}
	game.show_title()
	game.open_settings()
	st.show_tab(SettingsScreen.SHEET_TAB)
	st._process(0.0)
	_ok(st.sheet_checking() and not st.testing() and not game.calibrating() and p._read_b.disabled and p._look_b.disabled
		and not st._save_b.visible and st._cancel_b.text.begins_with("閉じる"),
		"sheet check: the プリント tab shows; without a backend or a camera nothing can be taken", p._camera_state.text)
	p.read_now()
	_ok(not p.waiting() and not p.result_ok and p.result_text.contains("つながっていない"),
		"sheet check: pressed anyway, it says why and sends nothing", p.result_text)
	p.pick_camera("focus")
	_ok(p.role == "focus" and p._camera_buttons["focus"].button_pressed and not p._camera_buttons["overview"].button_pressed,
		"sheet check: the arm camera can be picked")
	p.pick_camera("overview")
	# the part sent, turned upright: a 400x300 frame, its right half, upside down
	var img := Image.create(400, 300, false, Image.FORMAT_RGB8)
	img.fill_rect(Rect2i(200, 0, 200, 300), Color.WHITE)
	img.set_pixel(390, 290, Color.RED)  # the bottom right of the frame
	var out := SheetCheckPanel.prepare(img, 180, Rect2(0.5, 0, 0.5, 1))
	var turned := SheetCheckPanel.prepare(img, 90, Rect2())
	var tiny := SheetCheckPanel.prepare(img, 0, Rect2(0, 0, 0.01, 0.01))
	_ok(out.get_size() == Vector2i(200, 300) and out.get_pixel(9, 9).is_equal_approx(Color.RED)
		and turned.get_size() == Vector2i(300, 400) and tiny.get_size() == Vector2i(400, 300) and img.get_pixel(390, 290) == Color.RED,
		"sheet check: the region is cut out, then turned (180° / 90°); a region too small sends the whole frame", str(out.get_size()))
	p.set_rotation_deg(180)
	p.set_region(Rect2(Vector2(0.9, 0.8), Vector2(-0.5, -0.8)))  # dragged from bottom right to top left
	_ok(p.rotation_deg() == 180 and p.region().is_equal_approx(Rect2(0.4, 0, 0.5, 0.8)) and p.rotation_deg("focus") == 0
		and p._region_label.text.contains("左 40%") and not p._clear_b.disabled
		and p._rotation.get_selected_id() == 180,
		"sheet check: the turn and the region are kept per camera", p._region_label.text)
	p.take_frame(img, false)  # 送る画像を見る: shown, not sent
	_ok(not p.waiting() and p.view_mode == "sent" and p.sent.get_size() == Vector2i(200, 240)
		and p._view_label.text.contains("まだ送っていない") and p._view_label.text.contains("上下反転"),
		"sheet check: what would be sent is shown before sending", p._view_label.text)
	var want_roi := [100, 200, 600, 1000]  # the region turned 180° (a pixel's rounding either way)
	var roi_ok: bool = p.sent_roi.size() == 4 and p.sent_size == Vector2i(400, 300) and p._view_label.text.contains("roi [")
	for i in 4:
		roi_ok = roi_ok and absi(int(p.sent_roi[i]) - want_roi[i]) <= 3
	# #298: the おく場所 ("ここへおいてね！" in the study mode) and the 読む範囲 around it
	p.places = {}
	var no_place: bool = p._place_clear_b.disabled and p._around_b.disabled and p._region_label.text.contains("おく場所: 未設定")
	p.start_pick("place")
	var picking: bool = p._place_b.text.contains("ドラッグ…") and not p._pick_b.text.contains("ドラッグ…")
	p.set_place(Rect2(0.3, 0.2, 0.4, 0.5))
	var outside: bool = p._region_label.text.contains("はみ出している")
	p.region_around_place()
	_ok(roi_ok and no_place and picking and outside and p.place().is_equal_approx(Rect2(0.3, 0.2, 0.4, 0.5))
		and p.region().is_equal_approx(Rect2(0.28, 0.175, 0.44, 0.55)) and not p._region_label.text.contains("はみ出している")
		and p._region_label.text.contains("おく場所: 左 30%") and p.place("focus") == Rect2() and p._picking == "",
		"sheet check: the 読む範囲 goes as the server's roi; the おく場所 is dragged, and the 読む範囲 can be set 5% around it",
		str([roi_ok, p.sent_roi, no_place, picking, outside, p.place(), p.region(), p._picking, p._view_label.text]))
	p.set_place(Rect2())
	p.set_region(Rect2(Vector2(0.9, 0.8), Vector2(-0.5, -0.8)))
	p.take_frame(img, false)
	p.show_view("frame")
	_ok(p.view_mode == "frame" and p._view_label.text.contains("400×300"), "sheet check: the whole frame can be shown again",
		p._view_label.text)
	# an answer over the image sent
	p.sending = true
	p.show_view("sent")
	p._rid = "sr1"
	game.ws.ack.emit("sr1", false, {"reason": "timeout"})  # the link's own few seconds: keep waiting
	var still := p.waiting()
	game.ws.ack.emit("other", true, {"command": "sheet_read", "problems": []})  # not ours
	game.ws.ack.emit("sr1", true, {"command": "sheet_read", "read_anything": true, "summary": "2 問（正解 1・まちがい 1）",
		"seconds": 9.5, "paper": [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]], "notes": ["形の正しくない枠を除外"],
		"response": {"id": "sheet-1", "model": "tutor-ufo-v6-sheet", "image": {"width": 200, "height": 240}},
		"problems": [
			{"number": 1, "answer_status": "correct", "student_answer": "12", "correct_answer": "12", "visible": "full",
				"notes": [], "box": [100, 100, 900, 300], "answer_box": [600, 150, 880, 280]},
			{"number": 2, "answer_status": "incorrect", "student_answer": "42", "correct_answer": "45", "visible": "partial",
				"notes": ["計算し直した"], "box": [100, 400, 900, 600], "answer_box": null}]})
	st._process(0.0)
	_ok(still and not p.waiting() and p.result_ok and p._summary.text.contains("2 問") and p._summary.text.contains("9.5 秒")
		and p._list.text.contains("○ 1. 正解　答え「12」")
		and p._list.text.contains("× 2. まちがい　答え「42」　正答 45（見切れ）　※計算し直した")
		and p._list.text.contains("※ 形の正しくない枠を除外") and st._status.text.contains("プリント読み取り: 2 問")
		and p._json.text.contains("\"model\": \"tutor-ufo-v6-sheet\"") and p._view_label.text.begins_with("送った画像")
		and p._view_label.text.contains("サーバが受け取ったのは 200×240"),
		"sheet check: the answer is listed over the image sent, with the server's JSON (the link's early timeout does not end the wait)",
		p._view_label.text)
	# the boxes land on the shown image (kept aspect, centred)
	var shown := SheetCheckPanel.frame_rect(Vector2(640, 480), Vector2(630, 470))
	var r := SheetCheckPanel.box_rect([100, 100, 900, 300], shown)
	_ok(shown.size.is_equal_approx(Vector2(626.6667, 470)) and is_equal_approx(shown.position.x, 1.6666667)
		and r.position.is_equal_approx(shown.position + Vector2(62.66667, 47)) and r.size.is_equal_approx(Vector2(501.3333, 94))
		and SheetCheckPanel.box_rect(null, shown) == Rect2(),
		"sheet check: a 0..1000 box is drawn on the image as shown", str(r))
	# a refusal, and a sheet it could not read
	p._rid = "sr2"
	game.ws.ack.emit("sr2", false, {"command": "sheet_read", "reason": "学習支援 AI のトークンが違う"})
	_ok(not p.waiting() and not p.result_ok and p.result_text.contains("トークンが違う") and p._json.text.contains("トークンが違う"),
		"sheet check: a refusal says why", p.result_text)
	p.show_result({"read_anything": false, "summary": "問題を読めなかった", "problems": []})
	_ok(not p.result_ok and p._summary.text.begins_with("読めなかった"), "sheet check: nothing read is not \"no problems\"",
		p._summary.text)
	# no answer at all
	p._rid = "sr3"
	p.tick_hidden(SheetCheckPanel.WAIT_S + 1.0)
	_ok(not p.waiting() and p.result_text.contains("返事がない"), "sheet check: no answer in time ends the wait", p.result_text)
	p.set_region(Rect2())
	p.show_live()
	_ok(p.view_mode == "live" and not p.region().has_area() and p._clear_b.disabled, "sheet check: ライブ, and the region cleared")
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(not game.settings_active() and not st.sheet_checking(), "sheet check: Esc closes the screen")
	remove_child(game)
	game.free()
	rs.clear_samples()

func _test_calibration_summary() -> void:
	# #120: the summary on top (one row per section, the next thing to do) and each card's badge
	var game := _study_game()
	var st: SettingsScreen = game.settings
	game.open_settings()
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	var cp: CalibrationPanel = st.calibration
	cp.refresh()
	# #242: a long answer (the shifts of a failed calibration) wraps, the panel stays on the screen
	cp.result_text = "先端カメラの校正をやめました: 画像のずれがアームの動きと合いません（誤差 19.2 px。" + "(+10,+0)mm→(+5,+0)px".repeat(12) + "）"
	st._status.text = cp.result_text
	_ok(st._status.get_combined_minimum_size().x < 400.0,
		"settings: a long calibration answer wraps (the panel is not pushed off the screen)", str(st._status.get_combined_minimum_size()))
	cp.result_text = ""
	var states := cp.section_states()
	var by := {}
	for x in states:
		by[x.key] = x
	_ok(states.size() == CalibrationPanel.SECTIONS.size() and by.link.state == "todo" and by.z.state == "na"
		and by.claw.state == "todo" and cp._next.text.contains("1. つながりとモーター")
		and (cp._summary["z"] as Button).text.begins_with("－ 2.") and (cp._cards["z"].badge as Label).text == "使えない",
		"calibration summary: without a backend, connect first; the backend's sections say they need it", cp._next.text)
	# #124: a real robot that is not connected is a problem of the link, with its reason
	var missing := {"kind": "real", "connected": false, "problem": "port_missing", "registered": ["/dev/cu.usbserial-AAAA"],
		"port": "/dev/cu.usbserial-AAAA", "others": ["/dev/cu.usbserial-CCCC"], "error": "could not open port"}
	var down: Dictionary = CalibrationPanel.link_state("websocket", true, false, false, "real", missing)
	var long_text := CalibrationPanel.link_problem_text(missing)
	_ok(down.state == "todo" and str(down.text).contains("登録したポートが見つからない")
		and long_text.contains("usbserial-AAAA") and long_text.contains("usbserial-CCCC")
		and long_text.contains("シリアルポート 2 台目") and long_text.contains("起動し直す"),
		"calibration link: a registered port that is missing is shown with the port seen instead and what to do", long_text)
	var unplugged := CalibrationPanel.link_problem_text({"problem": "port_missing", "registered": ["A"], "others": []})
	var none := CalibrationPanel.link_problem_text({"problem": "no_port"})
	var busy := CalibrationPanel.link_problem_text({"problem": "open_failed", "port": "/dev/cu.usbserial-AAAA", "error": "Resource busy"})
	_ok(unplugged.contains("USB ケーブル") and not unplugged.contains("2 台目") and none.contains("1 つも見つからない")
		and busy.contains("usbserial-AAAA") and busy.contains("Resource busy") and busy.contains("ほかのプログラム")
		and CalibrationPanel.link_problem_text({}).contains("確かめています"),
		"calibration link: unplugged, no port at all, a port that does not open and no answer yet have their own words", busy)
	# #161: the link went silent while running (a USB hub's error): said so, with the reopen and the hub
	var silent_info := {"kind": "real", "connected": false, "problem": "silent", "port": "/dev/cu.usbserial-AAAA",
		"error": "no reply from the robot (serial link silent: USB cable / hub?) (5 s without a reply)"}
	var silent := CalibrationPanel.link_problem_text(silent_info)
	var z_refused := CalibrationPanel.reason_text("internal error: timeout after 3.0s")
	_ok(str(CalibrationPanel.link_state("websocket", true, false, false, "real", silent_info).text).contains("返事が来ない")
		and silent.contains("usbserial-AAAA") and silent.contains("つなぎ直") and silent.contains("ハブ")
		and z_refused.contains("実機から返事がない") and z_refused.contains("timeout after 3.0s")
		and CalibrationPanel.reason_text("no reply from the robot (serial link silent)").contains("USB")
		and CalibrationPanel.reason_text("timeout") == "バックエンドから返事がない",
		"calibration link: a silent link and a refusal for a firmware timeout point at the USB hub / cable", z_refused)
	# #348: the servo bus failing for a while is said as such (not as a power cut, not as the USB link)
	var bus_lines := ["SERVO_STATUS 2 failed: SERVO_STATUS id=2 result=NO_REPLY tracking=YES",
		"SERVO_TURN id=1 value=-0.65 result=REJECTED reason=no_reply",
		"OPEN_CLAW failed: SERVO_TURN id=2 result=FAILED reason=feedback_lost (servo bus error for 20.1 s)",
		"the drum servo's count of turns is being taken back after a servo bus error"]
	var bus_ok := true
	for line in bus_lines:
		bus_ok = bus_ok and CalibrationPanel.reason_text(line).contains("サーボの通信が不安定") \
			and EasyModeControl.fault_text(line).contains("つうしん")
	_ok(bus_ok and not CalibrationPanel.reason_text("no reply from the robot (serial link silent)").contains("サーボ")
		and not CalibrationPanel.servo_bus_trouble("z servo reset (its power was cut)"),
		"servo bus trouble: no answer / feedback lost / count taken back are said as a flaky servo line", str(bus_lines))
	# #167: the one-button preparation's progress, its end and why it stopped
	var prep_steps := [{"key": "motors", "label": "モーター有効", "state": "done", "note": ""},
		{"key": "z_restore", "label": "前回の Z の上下を呼び出す", "state": "fail", "note": ""},
		{"key": "claw_open", "label": "爪を開く", "state": "todo", "note": ""}]
	var prep_fault := CalibrationPanel.prepare_text({"active": false, "last_result": "fault", "steps": prep_steps,
		"error": "前回から +25 単位ずれている（電源を切っている間に回った）: W で一番上まで巻き上げて「ここを上に記録」"})
	var prep_skip := [{"key": "claw_open", "label": "爪を開く", "state": "skip", "note": "爪の開き・閉じが未記録"}]
	_ok(CalibrationPanel.prepare_text({}) == "" and prep_fault.begins_with("止まった") and prep_fault.contains("✓ モーター有効")
		and prep_fault.contains("✗ 前回の Z") and prep_fault.contains("ここを上に記録")
		and CalibrationPanel.prepare_text({"active": true, "steps": prep_steps}).begins_with("実行中")
		and CalibrationPanel.prepare_text({"last_result": "done", "steps": prep_skip}).contains("－ 爪を開く（爪の開き・閉じが未記録）"),
		"calibration prepare: the steps, the end and the reason it stopped are shown", prep_fault)
	# #163: a servo refused until its power is cut and restored: which one, not the USB, and what after
	var pc_z := CalibrationPanel.servo_power_cycle_text(true, false)
	var pc_arm := CalibrationPanel.servo_power_cycle_text(false, true)
	_ok(CalibrationPanel.servo_power_cycle_text(false, false) == "" and pc_z.contains("巻き上げサーボ")
		and pc_z.contains("USB ではない") and pc_z.contains("記録し直す") and pc_z.contains("下がる")
		and pc_arm.contains("爪のサーボ") and not pc_arm.contains("巻き上げ")
		and CalibrationPanel.servo_power_cycle_text(true, true).contains("巻き上げサーボと爪のサーボ"),
		"calibration: a servo refused until a power cycle says which one and what to do", pc_z)
	var up: Dictionary = CalibrationPanel.link_state("websocket", true, true, true, "real", {})
	var motors_off: Dictionary = CalibrationPanel.link_state("websocket", true, true, false, "mock", {})
	_ok(up.state == "ok" and up.text == "実機" and motors_off.state == "todo" and str(motors_off.text).contains("モーターが無効")
		and CalibrationPanel.link_state("mock", false, true, true, "", {}).state == "todo",
		"calibration link: connected is as before (done with the motors on, the motors' hint, no backend)", str(up))
	# #249: the alarm is cleared from the top card too (the debug panel's command, nothing moves)
	game.ws._pending.clear()
	cp._alarm_clear.pressed.emit()
	var sent: Array = game.ws._pending.values().map(func(p): return str(p.type))
	var was_shown := st.visible
	st.visible = true  # the panel's answers are shown only while the tab is on the screen
	var shown := cp.is_visible_in_tree()
	cp._on_ack("r", true, {"command": "clear_alarm"})
	st.visible = was_shown
	_ok(cp._alarm_clear.get_parent() == cp._prepare.get_parent() and sent == ["clear_alarm"]
		and shown and cp.result_text.contains("原点復帰"),
		"calibration: アラーム解除 beside the preparation sends clear_alarm and says homing is next", "%s %s" % [sent, cp.result_text])
	game.ws._pending.clear()
	cp.result_text = ""
	cp.link_info = {}
	cp._on_ack("r", true, {"command": "list_ports", "ports": [], "robot": missing})
	_ok(cp.link_info.get("problem") == "port_missing" and cp.result_text == "",
		"calibration link: the backend's list_ports answer is kept, without a result message", str(cp.link_info))
	cp.link_info = {}
	var open0 := RobotState.arm_open_deg
	var closed0 := RobotState.arm_closed_deg
	RobotState.arm_open_deg = 40.0
	RobotState.arm_closed_deg = 5.0
	cp.refresh()
	var claw_done: bool = (cp._summary["claw"] as Button).text.begins_with("✓ 3.") and (cp._cards["claw"].badge as Label).text == "済"
	RobotState.arm_open_deg = open0
	RobotState.arm_closed_deg = closed0
	_ok(claw_done, "calibration summary: a recorded claw turns its row and badge to done")
	var all_ok := []
	for x in CalibrationPanel.SECTIONS:
		all_ok.append({"key": x[0], "title": x[1], "state": "ok", "text": ""})
	var waiting := all_ok.duplicate(true)
	waiting[5].state = "wait"
	waiting[5].text = "2 の Z の上と下を記録すると使える"
	_ok(CalibrationPanel.next_text(all_ok).begins_with("すべて済み")
		and CalibrationPanel.next_text(waiting).contains("6. 学習モードの撮影の高さ: 2 の Z の上と下を記録すると使える"),
		"calibration summary: the next thing to do is the first section not done")
	_ok(CalibrationPanel.short_detail("2.1.325 (Claude Code)（/Users/x/.vscode/claude）") == "2.1.325 (Claude Code)"
		and CalibrationPanel.short_detail("VOICEVOX 0.26.0（http://127.0.0.1:50021）") == "VOICEVOX 0.26.0"
		and CalibrationPanel.short_detail("つながらない") == "つながらない",
		"calibration summary: the service lines leave out file paths")
	remove_child(game)
	game.free()

## #308: closing the settings screen after the 校正 tab asks first when the score game still lacks
## some of the real crane's calibration (crane_blocker's conditions, all listed).
func _test_calibration_close_confirm() -> void:
	var items: Array = load("res://scripts/game/main.gd").crane_missing_for(true, false, false, {"blockers": ["dial 1 drop point is not recorded", "release height is not recorded", "z bottom"]})
	var all_listed: bool = items == ["Z の基準（前回の上下を呼び出す か 上を記録）", "Z の上と下", "ポータルの XY", "投入の高さ"]
	var none: bool = load("res://scripts/game/main.gd").crane_missing_for(true, true, true, {"blockers": []}).is_empty() \
		and load("res://scripts/game/main.gd").crane_missing_for(false, true, true, {}) == ["ロボットとの接続"]
	var game := _study_game()
	var st: SettingsScreen = game.settings
	RobotState.source = "websocket"
	game.ws.server_robot = "real"
	RobotState.connected = true
	RobotState.z_reference_set = true
	RobotState.z_calibrated = true
	RobotState.easy_mode = {"blockers": ["dial 1 drop point is not recorded"]}
	var closes := [0]
	st.closed.connect(func(_saved): closes[0] += 1)
	# the 校正 tab not shown: closes as before
	st.open()
	st.show_tab(0)
	st.cancel()
	var plain: bool = not st.visible and closes[0] == 1 and not st.confirm_showing()
	# after the 校正 tab: asked, the screen stays; Esc goes back to 校正
	st.open()
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	st.cancel()
	var asked: bool = st.visible and st.confirm_showing() and closes[0] == 1 and st.confirm_message.contains("ポータルの XY") \
		and st.confirm_message.contains("閉じてよいですか")
	var no_arm_keys: bool = game._jog_input() == Vector3.ZERO
	st.handle_key(KEY_ESCAPE)
	var back: bool = st.visible and not st.confirm_showing() and st.tabs.current_tab == SettingsScreen.CALIBRATION_TAB and closes[0] == 1
	# asked again, Enter closes
	st.cancel()
	st.handle_key(KEY_ENTER)
	var closed_on_enter: bool = not st.visible and closes[0] == 2
	# all done: no question
	RobotState.easy_mode = {"blockers": []}
	st.open()
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	st.cancel()
	var done_free: bool = not st.visible and closes[0] == 3
	# the simulated crane: no question either
	game.ws.server_robot = "mock"
	RobotState.easy_mode = {"blockers": ["dial 1 drop point is not recorded"]}
	st.open()
	st.show_tab(SettingsScreen.CALIBRATION_TAB)
	st.cancel()
	var mock_free: bool = not st.visible and closes[0] == 4
	game.ws.server_robot = ""
	RobotState.source = "mock"
	RobotState.connected = false
	RobotState.z_reference_set = false
	RobotState.z_calibrated = false
	RobotState.easy_mode = {}
	_ok(all_listed and none and plain and asked and no_arm_keys and back and closed_on_enter and done_free and mock_free,
		"settings #308: closing after the 校正 tab asks when the score game lacks calibration (the items listed; Esc back to 校正, Enter closes); never without the tab, when all is done or on the simulated crane",
		str([items, none, plain, asked, no_arm_keys, back, closed_on_enter, done_free, mock_free, st.confirm_message]))
	remove_child(game)
	game.free()

func _test_calibration_tab(rs: Node) -> void:
	# #114: at start the 校正 tab opens over the title (the backend's checks come when it connects)
	var g0 := _study_game()
	g0.show_title()
	g0.open_startup_screen()
	var first: bool = g0.settings_active() and g0.settings.calibrating() and g0.title_active()
	g0._unhandled_input(_key(KEY_ESCAPE))
	_ok(first and not g0.settings_active() and g0.title_active(),
		"startup: the 校正 tab opens first, Esc shows the title (#114)")
	GameConfig.data["title_screen"]["calibration_first"] = false
	g0.open_startup_screen()
	_ok(not g0.settings_active(), "startup: calibration_first false keeps the title")
	GameConfig.data["title_screen"]["calibration_first"] = true
	remove_child(g0)
	g0.free()
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
	# #126: 上げる / 下げる beside the record buttons go to the recorded top / bottom (move_z)
	var up_b := _find_button(st.calibration, "上げる（上の記録へ）")
	var down_b := _find_button(st.calibration, "下げる（下の記録へ）")
	var bottom_b := _find_button(st.calibration, "ここを下に記録")
	var sent: Array[String] = []
	var cap := func(l: String): if l.contains(" move_z "): sent.append(l)
	game.ws.log_line.connect(cap)
	rs.z_top_set = true
	rs.z_bottom_set = false
	st.calibration.refresh()
	var one_point_off: bool = up_b.disabled and down_b.disabled
	st.calibration.move_z_to("bottom")
	var refused_one: bool = sent.is_empty() and st.calibration.result_text.contains("両方")
	rs.z_bottom_set = true
	st.calibration.move_z_to("bottom")
	st.calibration.move_z_to("top")
	game.ws.log_line.disconnect(cap)
	rs.z_top_set = false
	rs.z_bottom_set = false
	var zb := JSON.stringify({"z": CalibrationPanel.z_end("bottom")})
	var zt := JSON.stringify({"z": CalibrationPanel.z_end("top")})
	_ok(up_b != null and down_b != null and up_b.get_parent() == bottom_b.get_parent() and one_point_off and refused_one
		and sent.size() == 2 and sent[0].contains(zb) and sent[1].contains(zt)
		and CalibrationPanel.z_end("top") != CalibrationPanel.z_end("bottom"),
		"calibration: 上げる / 下げる beside the record buttons move Z to the recorded top / bottom, only with both (#126)", str(sent))
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))
	game._unhandled_input(_key(KEY_SPACE))
	_ok(game.mock.target.is_equal_approx(game.mock.pos) and st.calibrating(), "calibration: Space still stops")
	game.ws.ack.emit("r1", false, {"command": "home",
		"reason": "the arm is not wound up (Z 3.0, top 100): raise it to the top before homing"})
	st._process(0.0)
	var refused: String = st._status.text
	game.ws.ack.emit("r2", false, {"command": "jog", "reason": "busy"})
	st._process(0.0)
	_ok(refused.contains("原点復帰 は断られました") and refused.contains("巻き上げ")
		and st._status.text == refused,
		"calibration: a refused command shows why under the tab (a jog's refusal does not replace it)", refused)
	game.ws.ack.emit("r3", true, {"command": "z_set"})
	st._process(0.0)
	_ok(st._status.text.contains("Z の記録: できました"), "calibration: an accepted command says so", st._status.text)
	# #114: the AI / outside services, as the backend checked them
	var cpp: CalibrationPanel = st.calibration
	game.ws.ack.emit("sv1", true, {"command": "services_check", "results": [
		{"name": "jev", "label": "Jev（Cloudflare）", "status": "ok", "detail": "トークン有効"},
		{"name": "voicevox", "label": "VOICEVOX", "status": "ng", "detail": "つながらない"},
		{"name": "tutor", "label": "学習支援 AI（ローカル LLM）", "status": "skip", "detail": "使っていない"}]})
	game.ws.ack.emit("sv2", true, {"command": "services_check", "results": [
		{"name": "jev", "label": "Jev（Cloudflare）", "status": "ok", "detail": "トークン有効"},
		{"name": "ask", "label": "AI に試しに質問", "status": "ok", "detail": "claude が答えた: OK"},
		{"name": "sheet", "label": "プリント読み取り（/v1/sheet）", "status": "ok", "detail": "見本のプリントを読んだ: 6 問"}]})
	cpp.refresh()
	var svt: String = cpp._services.text
	_ok(svt.contains("✓ Jev（Cloudflare）") and svt.contains("✗ VOICEVOX: つながらない") and svt.contains("－ 学習支援 AI")
		and svt.contains("✓ AI に試しに質問: claude が答えた: OK") and svt.contains("✓ プリント読み取り（/v1/sheet）: 見本のプリントを読んだ")
		and svt.contains("✗ VOICEVOX"),
		"calibration: the AI / outside services are listed, an ask adds its lines (#114, the worksheet reader #230)", svt)
	# #110 / #165: the capture heights: the saved values fill the inputs, the stages and the state are shown
	var cp: CalibrationPanel = st.calibration
	game.ws.ack.emit("h1", true, {"command": "study_height_status", "usable": false, "stages": [],
		"problem": "the 10 cm stage leaves no clearance", "z_calibrated": true, "default_drum_radius_mm": 15.0,
		"saved": {"drum_radius_mm": 15.0, "camera_offset_cm": 3.0, "landing_tip_cm": 1.0, "allow_landing_contact": false,
			"desk": "bottom", "confirmed": false},
		"values": {"z_per_cm": 5.404, "z_desk_tip": 0.0, "confirmed": false},
		"trial_stages": [{"name": "10cm", "z": 37.83, "tip_cm": 7.0}, {"name": "5cm", "z": 10.81, "tip_cm": 2.0},
			{"name": "landing", "z": 5.4, "tip_cm": 1.0}]})
	cp.refresh()
	var hp := cp.height_params("bottom")
	var unconfirmed_text: String = cp._height.text
	game.ws.ack.emit("h2", true, {"command": "study_height_status", "usable": true, "z_calibrated": true,
		"saved": null, "values": {"z_per_cm": 5.404, "z_desk_tip": 0.0, "confirmed": true},
		"stages": [{"name": "10cm", "z": 37.83, "tip_cm": 7.0}, {"name": "5cm", "z": 10.81, "tip_cm": 2.0},
			{"name": "landing", "z": 5.4, "tip_cm": 1.0}]})
	cp.refresh()
	_ok(not hp.has("camera_offset_cm") and is_equal_approx(float(hp.drum_radius_mm), 15.0)
		and hp.desk == "bottom" and unconfirmed_text.contains("1cm = Z 5.40") and unconfirmed_text.contains("10cm: Z 37.8")
		and unconfirmed_text.contains("このままでは使えない") and cp._height.text.contains("学習モードで使う")
		and not cp._height.text.contains("確かめた")
		and is_equal_approx(cp.stage_z("5cm"), 10.81) and is_nan(cp.stage_z("bogus")),
		"calibration: the study heights are shown and used from the Z bottom with no check (#110, #165)",
		cp._height.text)
	# #106: the call-back's estimate is shown, then used only with the same turn shift
	game.ws.ack.emit("r4", true, {"command": "z_restore", "restore": {"turns": -1, "drift_counts": 150,
		"drift_units": 1.9, "z": 42.5, "too_far": false, "applied": false}})
	var est_text: String = st.calibration._z_restore.text
	var est_kept: bool = int(st.calibration.restore_estimate.get("turns", 0)) == -1
	game.ws.ack.emit("r5", true, {"command": "z_restore", "restore": {"turns": 4, "drift_units": 22.0, "z": 10.0,
		"too_far": true, "applied": false}})
	var far_dropped: bool = st.calibration.restore_estimate.is_empty() and st.calibration._z_restore.text.contains("上を記録")
	game.ws.ack.emit("r6", true, {"command": "z_restore", "restore": {"turns": -1, "z": 42.5, "applied": true}})
	st._process(0.0)
	_ok(est_text.contains("42.5") and est_text.contains("これを使う") and est_kept and far_dropped
		and st.calibration.restore_estimate.is_empty() and st._status.text.contains("呼び出しました"),
		"calibration: the last Z points are called back after a look at the estimate (#106)", est_text)
	var free_here: bool = game.jog_params(Vector3(0, 0, -5)).get("z_free", false) == true
	RobotState.z_calibrated = true
	RobotState.z_reference_set = true
	var hint_here: String = game.z_end_hint_for(-5.0, 0.0)
	st.show_tab(0)
	var usual: Dictionary = game.jog_params(Vector3(0, 0, -5))
	_ok(free_here and not usual.has("z_free"),
		"calibration: only the 校正 tab's jog goes past the measured Z range (z_free, #102)", str(usual))
	_ok(game.z_end_hint_for(-5.0, 0.0).contains("校正") and game.z_end_hint_for(-5.0, 50.0) == ""
		and game.z_end_hint_for(5.0, 0.0) == "" and hint_here.contains("校正"),
		"calibration: S held at the measured bottom says how to measure it again")
	RobotState.z_calibrated = false
	RobotState.z_reference_set = false
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
	var moved_sel: bool = t.selected_mode() == t.choices[1] and t.choices.size() == 2 and game.title_active()
	game._unhandled_input(_key(KEY_LEFT))
	_ok(held and moved_sel and t.selected_mode() == "study" and not ctl.active(),
		"title: holds the manual controls; arrows choose, other keys are swallowed", game.control_source)
	game._unhandled_input(_key(KEY_ENTER))
	_ok(not game.title_active() and ctl.active() and ctl.state == "INTRO", "title: Enter on the study mode starts it", ctl.state)
	game._handle_input(0.1)
	var free_again: bool = game.control_source != "halt"
	game._unhandled_input(_key(KEY_ESCAPE))
	_ok(free_again and game.title_active() and not ctl.active(), "title: Esc stops the study mode and comes back", ctl.state)
	game._unhandled_input(_key(KEY_G))
	_ok(not game.title_active() and not ctl.active(), "title: G (staff) picks the plain crane screen, no study mode")
	game.show_title()
	game.mock.set_target(game.mock.pos + Vector3(50, 0, 0))  # as if the arm were on its way
	game._unhandled_input(_key(KEY_SPACE))
	var stopped: bool = game.mock.target.is_equal_approx(game.mock.pos)
	_ok(game.title_active() and stopped, "title: Space still reaches the game's stop (the mock halts) and leaves the title up")
	var card: PanelContainer = t._cards[1]
	card.gui_input.emit(_mouse_press())
	_ok(not game.title_active() and not ctl.active() and t.selected_mode() == t.choices[1], "title: a click on a card picks it")
	# #183: the hand picks: one finger = the first card, two fingers = the second, held; a
	# shape that was already up when the title opened does not choose
	game.show_title()
	var two = {"fresh": true, "detected": true, "pose": "peace"}
	var one = {"fresh": true, "detected": true, "pose": "point"}
	for i in 200:
		t.hand_tick(1.0 / 60.0, two)
	var not_yet: bool = game.title_active() and t.hand_index == -1
	t.hand_tick(1.0 / 60.0, {"fresh": true, "detected": true, "pose": "open"})
	for i in 30:
		t.hand_tick(1.0 / 60.0, one)
	var holding: bool = game.title_active() and t.hand_index == 0 and t.hand_progress > 0.2 and t.hand_progress < 0.5 and t.selected == 0
	for i in 30:
		t.hand_tick(1.0 / 60.0, two)  # another shape: the hold starts again
	var restarted: bool = game.title_active() and t.hand_index == 1 and t.hand_progress < 0.5
	t.hand_tick(1.0 / 60.0, {"fresh": false, "detected": true, "pose": "peace"})  # a stale hand is no hand
	var stale_none: bool = t.hand_index == -1
	var picked := ""
	for i in 100:
		var got: String = t.hand_tick(1.0 / 60.0, two)
		if got != "":
			picked = got
	_ok(not_yet and holding and restarted and stale_none and picked == t.choices[1] and not game.title_active() and t.choices == ["study", "score"],
		"title (#183): two modes (study, the game mode = the score game); one finger / two fingers held pick a card; the shape already up when the title opened does not",
		"%s %s %s %s %s" % [not_yet, holding, restarted, stale_none, picked])
	var logo := TitleScreen.logo_label("SUMMON", 104)
	_ok(logo.get_theme_font("font") is FontVariation and TitleScreen.NightSky.ridge(0, 0.3) > TitleScreen.NightSky.ridge(2, 0.3) - 0.2,
		"title (#183): the drawn logo (without the picture) is in its display font; the night sky's ridges")
	logo.free()
	# #283: the pixel-art title: the logo picture over the meadow; animals stroll by and leave
	var m: TitleScreen.Meadow = t.meadow
	var art_ok: bool = m != null and t.sky == null and t.logo_rect != null and t.logo_rect.texture != null \
		and m.bg != null and m.sheets.size() == TitleScreen.Meadow.KINDS.size() and m.front != null
	m.walkers.clear()
	var cow_in: bool = m.spawn("cow", 1) and m.walkers.size() == 1 and float(m.walkers[0]["x"]) < 0.0
	var bird_in: bool = m.spawn("bird", -1) and float(m.walkers[1]["y"]) < m.bg.get_height() * 0.3
	var full: bool = not m.spawn("pig", 1) and not m.spawn("nothing", 1)  # two at once at most
	var x0: float = m.walkers[0]["x"]
	m._next = 999.0  # no new one while this test walks them
	m.tick(1.0)
	var moved: bool = float(m.walkers[0]["x"]) > x0 and float(m.walkers[1]["x"]) < float(m.bg.get_width()) + 20.0
	for i in 200:
		m.tick(0.5)
	_ok(art_ok and cow_in and bird_in and full and moved and m.walkers.is_empty(),
		"title (#283): the logo picture over the pixel-art meadow; a cow walks in from the left, a bird flies high, two at most, they cross and leave",
		"%s %s %s %s %s %d" % [art_ok, cow_in, bird_in, full, moved, m.walkers.size()])
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
	game._unhandled_input(_key(KEY_G))
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

## #179: the arm in an alarm (or without homing) can be recovered from the score game's screen.
## #260: the staff's operations: F6..F10 mean one thing on every screen, all through
## StaffControl.run() (an outside device later); the exhibit's day can be run with them alone.
func _test_staff_control(rs: Node) -> void:
	_ok(StaffControl.action_for_key(KEY_F6) == "next" and StaffControl.action_for_key(KEY_F7) == "skip"
		and StaffControl.action_for_key(KEY_F8) == "menu" and StaffControl.action_for_key(KEY_F9) == "recover"
		and StaffControl.action_for_key(KEY_F10) == "switch" and StaffControl.action_for_key(KEY_F6, true) == ""
		and StaffControl.action_for_key(KEY_ENTER) == "",
		"staff #260: F6 next, F7 skip, F8 menu, F9 recover, F10 study <-> game (Shift: the developers' own)")
	var game := _study_game()
	var st: StaffControl = game.staff
	var gm: GameModeController = game.game_mode
	gm.devices_wanted = "mock"
	gm.sounds.enabled = false
	gm.trace_to_file = false
	gm.ranking.path = ""
	gm.ranking_enabled = false
	# the day starts on 校正 (over the menu): next = on to the menu
	game.show_title()
	game.open_settings()
	game.settings.show_tab(SettingsScreen.CALIBRATION_TAB)
	var on_cal: bool = st.screen() == "settings" and st.describe("next") == "メニューへ" and st.describe("recover") == ""
	game._unhandled_input(_key(KEY_F6))
	var to_menu: bool = st.screen() == "title" and not game.settings_active() and st.describe("menu") == ""
	# the menu: F10 = the study mode
	game._unhandled_input(_key(KEY_F10))
	var in_study: bool = st.screen() == "study" and game.study_mode.state == "INTRO"
	# the study mode: next skips the wait on (the intro, the sheet), skip = on to the score game
	game._unhandled_input(_key(KEY_F6))
	var skipped: bool = game.study_mode.state == "WAITING_FOR_WORKSHEET"
	_ok(on_cal and to_menu and in_study and skipped and st.describe("next") == "とばして つづける",
		"staff #260: 校正 -> (F6) the menu -> (F10) the study mode -> (F6) its waits skipped",
		"%s %s %s %s %s" % [on_cal, to_menu, in_study, game.study_mode.state, st.last])
	game._unhandled_input(_key(KEY_F7))
	var to_game: bool = st.screen() == "score" and not game.study_mode.active() and gm.phase == "IDLE"
	# the score game: next = its start, the practice first; skip there = the practice left out
	gm.tutorial_auto = true
	gm.tutorial_seen = false
	game._unhandled_input(_key(KEY_F6))
	var practice: bool = gm.phase == "TUTORIAL" and st.describe("skip") == "れんしゅうを ぜんぶ とばす"
	game._unhandled_input(_key(KEY_F7))
	for i in 60 * 3:
		gm.tick(1.0 / 60.0)
	var played: bool = gm.phase in ["COUNTDOWN", "PLAYING"]
	_ok(to_game and practice and played,
		"staff #260: (F7) the study mode over, the score game's title -> (F6) the practice -> (F7) the practice left out, the round starts",
		"%s %s %s %s" % [to_game, practice, gm.phase, st.last])
	# Space-equal stop, then the menu
	st.run("stop", "remote")
	var stopped: bool = gm.phase == "STOPPED" and st.last[0] == "stop"
	var again: bool = st.describe("skip") == "れんしゅう なしで はじめる"
	game._unhandled_input(_key(KEY_F8))
	_ok(stopped and again and st.screen() == "title" and not gm.active(),
		"staff #260: stop from outside (as Space), then (F8) back to the menu; the score game is closed", "%s %s" % [gm.phase, st.screen()])
	# nothing to recover on the mock: the key does nothing and says so
	_ok(st.run("recover") == "" and st.last == ["recover", "title", ""] and st.run("dance") == "",
		"staff #260: recover with nothing to recover (and an unknown action) does nothing")
	remove_child(game)
	game.free()

func _test_arm_recovery(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	ctl.hud._process(0.016)
	# the game's own mock crane: nothing to recover, nothing shown
	var mock_nothing = game.arm_recovery_reason() == "" and not ctl.hud._recover.visible and not ctl.hud._recover_button.visible \
		and not game.recover_arm()
	game.mock.enabled = false
	RobotState.source = "websocket"
	RobotState.connected = true
	RobotState.motors_enabled = true
	RobotState.homed = true
	RobotState.machine_state = "IDLE"
	RobotState.calibration_prepare = {}
	game.backend_link = func() -> bool: return true
	ctl.hud._process(0.016)
	var fine = game.arm_recovery_reason() == "" and not ctl.hud._recover.visible
	# the motors off (homed, no alarm: as after a start-up): the arm cannot move, so ふっき /
	# F9 / the staff remote's RECOVER prepares it (the preparation switches the motors on)
	RobotState.motors_enabled = false
	ctl.hud._process(0.016)
	var motors_off = game.arm_recovery_reason().contains("モーター") and ctl.hud._recover.visible \
		and game.staff.describe("recover").contains("まとめて準備")
	_ok(fine and motors_off, "recovery: the motors off need it too (homed, no alarm), so F9 / the remote's ふっき prepares the arm",
		"%s %s %s" % [fine, game.arm_recovery_reason(), game.staff.describe("recover")])
	RobotState.motors_enabled = true
	RobotState.machine_state = "ALARM"
	RobotState.homed = false
	ctl.hud._process(0.016)
	var shown = game.arm_recovery_reason().contains("アラーム") and ctl.hud._recover.visible and ctl.hud._recover_button.visible \
		and ctl.hud.recover_text().contains("ふっきする") and ctl.hud._recover_button.focus_mode == Control.FOCUS_NONE
	game.ws._pending.clear()
	var types := func() -> Array: return game.ws._pending.values().map(func(p): return str(p.type))
	# the backend's answer to the request of that kind still open (taken off the open ones, as the link does)
	var answer := func(type: String, ok: bool) -> String:
		for r in game.ws._pending.keys():
			if str(game.ws._pending[r].type) == type:
				game.ws._pending.erase(r)
				game.ws.ack.emit(str(r), ok, {"command": type})
				return str(r)
		return ""
	# the stop key between the two steps: the preparation is never asked for
	game._unhandled_input(_key(KEY_F9))
	var first_only = types.call() == ["clear_alarm"]
	game.stop_key()
	answer.call("clear_alarm", true)
	var stop_between = first_only and types.call().is_empty()
	# the stop key right after the preparation was asked for: if it starts after all, it is stopped again
	game._unhandled_input(_key(KEY_F9))
	answer.call("clear_alarm", true)
	var asked_prepare = types.call() == ["calibration_prepare"]
	game.stop_key()
	answer.call("calibration_prepare", true)
	var stopped_again = asked_prepare and types.call() == ["soft_stop"]
	# a refused clearing: no preparation either
	game.ws._pending.clear()
	game._unhandled_input(_key(KEY_F9))
	answer.call("clear_alarm", false)
	var refused_stops = types.call().is_empty()
	# the normal way: the alarm cleared, then the preparation; pressed twice = once
	game._unhandled_input(_key(KEY_F9))
	game._unhandled_input(_key(KEY_F9))
	var once = types.call() == ["clear_alarm"]
	answer.call("clear_alarm", true)
	var sent: Array = types.call()
	var by_key = once and sent == ["calibration_prepare"] and stop_between and stopped_again and refused_stops
	answer.call("calibration_prepare", true)
	# while the recovery runs: its steps are shown, the button is away, a second press sends nothing
	RobotState.calibration_prepare = {"active": true, "steps": [{"key": "home", "label": "原点復帰", "state": "run", "note": ""}]}
	ctl.hud._process(0.016)
	game._unhandled_input(_key(KEY_F9))
	ctl.hud._recover_button.pressed.emit()
	var running = types.call().is_empty() and ctl.hud._recover.visible and not ctl.hud._recover_button.visible \
		and ctl.hud.recover_text().contains("原点復帰")
	# it stopped: why is said, and the button is back; the button does the same as the key
	RobotState.calibration_prepare = {"active": false, "last_result": "fault", "error": "robot not connected", "steps": []}
	RobotState.machine_state = "IDLE"  # (the alarm is cleared, homing is still missing)
	ctl.hud._process(0.016)
	var stopped = game.arm_recovery_reason().contains("げんてんふっき") and ctl.hud.recover_text().contains("とまった") and ctl.hud._recover_button.visible
	ctl.hud._recover_button.pressed.emit()
	answer.call("clear_alarm", true)
	var by_button = types.call() == ["calibration_prepare"]
	answer.call("calibration_prepare", true)
	RobotState.homed = true
	RobotState.calibration_prepare = {"active": false, "last_result": "done", "steps": []}
	ctl.hud._process(0.016)
	var recovered = game.arm_recovery_reason() == "" and not ctl.hud._recover.visible and not ctl.hud._recover_button.visible
	_ok(mock_nothing and fine and shown and by_key and running and stopped and by_button and recovered,
		"arm recovery: an alarm (or lost homing) is said on the score game's screen with a button; F9 (#260: the staff's recover) or the button sends clear_alarm and, when that is answered, the preparation, once (never after the stop key; a preparation that started behind the stop is stopped again); its steps and a stop's reason are shown; gone when the arm is ready",
		"%s %s %s %s %s %s %s %s %s | %s %s %s %s %s %s" % [mock_nothing, fine, shown, by_key, running, stopped, by_button, recovered, sent,
			first_only, stop_between, asked_prepare, stopped_again, refused_stops, once])
	game.ws._pending.clear()
	RobotState.calibration_prepare = {}
	RobotState.source = "mock"
	RobotState.connected = false
	RobotState.motors_enabled = false
	RobotState.homed = false
	_gm_free(game, rs)

## #134: the body font is the project's default, titles and big lines are in the dot font.
func _test_fonts() -> void:
	var body := UiFonts.body()
	var title := UiFonts.title()
	var files_ok := body is FontFile and title is FontFile and body != title \
		and str(ProjectSettings.get_setting("gui/theme/custom_font", "")) == UiFonts.BODY_PATH
	var big := StudyHud.label("UFOくん", 96)
	var small := StudyHud.label("説明", 16)
	var box := StudyHud.label("☐", 30)
	var labels_ok := big.get_theme_font("font") == title and not small.has_theme_font_override("font") \
		and not box.has_theme_font_override("font")
	var glyphs_ok := true
	for f in [body, title]:
		for ch in "UFOくん勉強校正上げる下げる宿題スコア0123456789":
			glyphs_ok = glyphs_ok and (f as Font).has_char(ch.unicode_at(0))
	_ok(files_ok and labels_ok and glyphs_ok,
		"fonts: M PLUS Rounded 1c for the body, DotGothic16 for titles and big lines, both with the game's kana and kanji",
		str([files_ok, labels_ok, glyphs_ok]))
	for l in [big, small, box]:
		l.free()

## #242: the arm-tip camera's calibration from the 校正 tab: base picture, +X / +Y / -X / -Y
## by move_xy, back to where it started, then focus_calibrate with the 4 pictures; Space, a
## refusal or an arm that did not get there end it; it never starts without homing / a frame.
func _test_focus_calibrator() -> void:
	var keep := [RobotState.x_mm, RobotState.y_mm, RobotState.homed, RobotState.motors_enabled, RobotState.machine_state]
	var sent: Array = []
	var frame := Image.create(64, 48, false, Image.FORMAT_RGB8)
	frame.fill(Color(0.8, 0.8, 0.8))
	var fc := FocusCalibrator.new()
	fc.capture = func() -> Image: return frame
	fc.send = func(name: String, params: Dictionary) -> String:
		sent.append([name, params])
		return "r%d" % sent.size()
	RobotState.motors_enabled = true
	RobotState.homed = false
	RobotState.machine_state = "IDLE"
	RobotState.x_mm = 150.0
	RobotState.y_mm = 100.0
	var not_homed := fc.start("10cm")
	RobotState.homed = true
	RobotState.x_mm = 5.0
	var at_edge := fc.start("10cm")
	# #339: X = 20 is 10 mm off the edge, but its -X sample (X = 10) is inside the home switches'
	# 15 mm margin (the backend would move it to 15): not enough room
	RobotState.x_mm = 20.0
	var at_home_edge := fc.start("10cm")
	RobotState.x_mm = 150.0
	RobotState.y_mm = 24.0
	var at_front := fc.start("10cm")
	RobotState.y_mm = 100.0
	var room: bool = FocusCalibrator.blocker({}, Vector2(25.0, 25.0), true, true, "IDLE", true, 15.0) == ""
	_ok(not_homed.contains("原点復帰") and at_edge.contains("端") and at_home_edge.contains("端") and at_front.contains("端")
		and room and sent.is_empty() and not fc.active(),
		"focus calibration: needs homing and room to move (25 mm from the home switches' side); nothing is sent then",
		"%s / %s / %s / %s" % [not_homed, at_edge, at_home_edge, at_front])
	var started := fc.start("10cm")
	var before_still := sent.size()
	for k in 30:
		fc.tick(0.1)
	var targets: Array = []
	for i in 6:
		if sent.is_empty() or str(sent[-1][0]) != "move_xy":
			break
		var p: Dictionary = sent[-1][1]
		targets.append(Vector2(p.x, p.y))
		fc.on_ack("r%d" % sent.size(), true, {"command": "move_xy"})
		RobotState.x_mm = p.x
		RobotState.y_mm = p.y
		for k in 20:
			fc.tick(0.1)
	var last: Array = sent[-1]
	var params: Dictionary = last[1]
	var moves: Array = params.get("moves", [])
	_ok(started == "" and targets == [Vector2(160, 100), Vector2(150, 110), Vector2(140, 100), Vector2(150, 90), Vector2(150, 100)]
		and str(last[0]) == "focus_calibrate" and params.height == "10cm" and (params.base_images_jpeg_base64 as Array).size() == 1
		and str(params.base_images_jpeg_base64[0]).length() > 100 and (moves[0].images_jpeg_base64 as Array).size() == 1
		and moves.size() == 4 and moves[0].dx == 10.0 and moves[1].dy == 10.0 and moves[3].dy == -10.0
		and fc.state == FocusCalibrator.COMPUTING and before_still == 0,
		"focus calibration: the base picture once still, 4 moves of 10 mm and back, then the pictures go to the backend", str(targets))
	fc.on_ack("r%d" % sent.size(), true, {"command": "focus_calibrate", "px_per_mm": 6.0, "residual_px": [0.2]})
	_ok(fc.state == FocusCalibrator.DONE and fc.progress_text().contains("6.0"), "focus calibration: the answer is shown", fc.progress_text())
	# Space in the middle, a refused move, an arm that stopped short
	sent.clear()
	fc.start("10cm")
	fc.cancel("Space で止めました")
	var after_space := fc.state
	fc.start("10cm")
	for k in 30:
		fc.tick(0.1)
	fc.on_ack("r%d" % sent.size(), false, {"command": "move_xy", "reason": "busy"})
	var refused := fc.error
	fc.start("10cm")
	for k in 30:
		fc.tick(0.1)
	fc.on_ack("r%d" % sent.size(), true, {"command": "move_xy"})
	for k in 30:
		fc.tick(0.1)
	_ok(after_space == FocusCalibrator.FAILED and refused == "busy" and fc.state == FocusCalibrator.FAILED
		and fc.error.contains("目的の位置"), "focus calibration: Space, a refusal or an arm that stayed end it", fc.error)
	# #242 review: closing the tab mid-move stops the arm; a jog of the height / place ends it
	sent.clear()
	fc.start("10cm")
	for k in 30:
		fc.tick(0.1)
	fc.cancel("校正タブを閉じた")
	var stopped: bool = sent.size() == 2 and str(sent[0][0]) == "move_xy" and str(sent[1][0]) == "soft_stop"
	fc.start("10cm")
	RobotState.z_mm += 5.0
	fc.tick(0.1)
	var z_moved := fc.error
	RobotState.z_mm -= 5.0
	fc.start("10cm")
	RobotState.x_mm += 3.0
	fc.tick(0.1)
	var xy_moved := fc.error
	RobotState.x_mm -= 3.0
	_ok(stopped and z_moved.contains("高さが変わった") and xy_moved.contains("位置が変わった"),
		"focus calibration: closing the tab stops the move; a changed height or place ends it", "%s %s %s" % [sent, z_moved, xy_moved])
	# the camera swings on the rope: no picture while it moves, a failure when it never stops
	var dark := Image.create(64, 48, false, Image.FORMAT_RGB8)
	dark.fill(Color(0.2, 0.2, 0.2))
	var flip := [false]
	fc.capture = func() -> Image:
		flip[0] = not flip[0]
		return dark if flip[0] else frame
	sent.clear()
	fc.start("10cm")
	for k in 30:
		fc.tick(0.1)
	var waiting := fc.state == FocusCalibrator.SETTLING and sent.is_empty() and fc.progress_text().contains("揺れが止まる")
	for k in 40:
		fc.tick(0.1)
	var burst_sent := sent.size() == 1 and str(sent[0][0]) == "move_xy"
	for i in 6:
		if sent.is_empty() or str(sent[-1][0]) != "move_xy":
			break
		var p2: Dictionary = sent[-1][1]
		fc.on_ack("r%d" % sent.size(), true, {"command": "move_xy"})
		RobotState.x_mm = p2.x
		RobotState.y_mm = p2.y
		for k in 80:
			fc.tick(0.1)
	var swung: Dictionary = sent[-1][1]
	_ok(waiting and burst_sent and str(sent[-1][0]) == "focus_calibrate"
		and (swung.base_images_jpeg_base64 as Array).size() == FocusCalibrator.BURST_N
		and (swung.moves[2].images_jpeg_base64 as Array).size() == FocusCalibrator.BURST_N and fc.bursts == 5
		and is_equal_approx(FocusCalibrator.motion(FocusCalibrator.thumb(frame), FocusCalibrator.thumb(frame)), 0.0),
		"focus calibration: while the camera keeps swinging, pictures in a row (the backend takes the middle)", str(fc.bursts))
	fc.capture = func() -> Image: return frame
	fc.cancel("テスト")
	# the card says why it failed (it said "まだ" before); only at the capture height
	var shown := CalibrationPanel.focus_state({"heights": {}}, fc)
	var cp := CalibrationPanel
	_ok(shown.state == "todo" and shown.text.contains("できなかった") and shown.text.contains("テスト")
		and cp.focus_height_blocker(100.0, 40.0, "10cm").contains("撮影の高さへ")
		and cp.focus_height_blocker(41.0, 40.0, "10cm") == "" and cp.focus_height_blocker(41.0, NAN, "10cm").contains("6 の"),
		"focus calibration: a failure shows on the card; it starts only at the capture height", shown.text)
	RobotState.x_mm = keep[0]
	RobotState.y_mm = keep[1]
	RobotState.homed = keep[2]
	RobotState.motors_enabled = keep[3]
	RobotState.machine_state = keep[4]

## #292: a backend state in robot_state's shape, all well
static func _fine_state() -> Dictionary:
	return {"link": true, "connected": true, "state": "IDLE", "homed": true, "motors_enabled": true, "error": "",
		"z_servo_reset": false, "z_servo_power_cycle": false, "arm_servo_power_cycle": false, "easy_mode": {"state": "MANUAL_XY"},
		"calibration_prepare": {}, "auto_catch": {}}

## #339: a jog (or an XY move) stopped by a home limit switch at the stage's edge, as the
## backend reports it with the firmware of CoreXY_UFO #33: the arm moved and stopped, still
## homed, no alarm, no error (POS LIMIT_Y=ON is not in robot_state's judged keys). Not a fault,
## and nothing keeps a new game. The older firmware's alarm for the same switch stays one.
func _test_robot_fault_watch_limit_edge() -> void:
	var w := RobotFaultWatch.new()
	var s := _fine_state()
	s.state = "MOVING_XY"
	w.arm(s)
	s.state = "IDLE"
	s["limit_y"] = true
	var quiet: bool = w.update(s).is_empty()
	var free: bool = RobotFaultWatch.problems(s, true).is_empty() and RobotFaultWatch.still(s)
	var old := RobotFaultWatch.new()
	var o := _fine_state()
	old.arm(o)
	o.state = "ALARM"
	o.error = "hard limit active away from home x=OFF y=ON x_raw=OFF y_raw=ON"
	var alarm: Array = old.update(o).map(func(f): return "%s/%s" % [f.category, f.code])
	_ok(quiet and free and alarm == ["corexy/alarm"],
		"robot fault #339: a stop at a home limit switch without an alarm is not a fault (nor a blocker); the older firmware's hard-limit alarm still is",
		"%s %s %s" % [quiet, free, alarm])

## #292: what is a new fault of the crane (only changes), and what keeps it from a new game.
func _test_robot_fault_watch() -> void:
	var w := RobotFaultWatch.new()
	var codes := func(found: Array) -> Array: return found.map(func(f): return "%s/%s" % [f.category, f.code])
	var s := _fine_state()
	var idle: bool = w.update(s).is_empty()  # not armed: nothing
	w.arm(s)
	var quiet: bool = w.update(s).is_empty()
	s.state = "ALARM"
	s.homed = false
	s.error = "position lost"
	var alarm: Array = codes.call(w.update(s))
	var again: bool = w.update(s).is_empty()  # the same alarm reported again: not new
	# a fault already there when armed is not new (the start's blockers keep that game from starting)
	var w2 := RobotFaultWatch.new()
	w2.arm(s)
	var old_one: bool = w2.update(s).is_empty()
	# servos: the firmware names the servo
	var w3 := RobotFaultWatch.new()
	var t := _fine_state()
	w3.arm(t)
	t.state = "ALARM"
	t.error = "SERVO id=2 move timeout"
	var claw: Array = codes.call(w3.update(t))
	var w4 := RobotFaultWatch.new()
	var u := _fine_state()
	w4.arm(u)
	u.z_servo_power_cycle = true
	var zpc: Array = codes.call(w4.update(u))
	# the easy mode's sequence fails without any alarm of the firmware (#269); a stop is not a fault
	var w5 := RobotFaultWatch.new()
	var e := _fine_state()
	w5.arm(e)
	e.easy_mode = {"state": "FAULT", "error": "servo id=1 no reply", "last_result": "fault"}
	var easy_fault: Array = codes.call(w5.update(e))
	var w6 := RobotFaultWatch.new()
	var e2 := _fine_state()
	w6.arm(e2)
	e2.easy_mode = {"state": "FAULT", "error": "stopped", "last_result": "stopped"}
	var stopped_quiet: bool = w6.update(e2).is_empty()
	# #302: a servo command that only failed (stopped with STOP, no alarm) is not the crane's fault
	var w6b := RobotFaultWatch.new()
	var e3 := _fine_state()
	w6b.arm(e3)
	e3.easy_mode = {"state": "FAULT", "error": "RELEASE failed: SERVO_TURN id=2 result=FAILED reason=feedback_lost", "last_result": "fault",
		"servo_fault": true}
	stopped_quiet = stopped_quiet and w6b.update(e3).is_empty()
	# homing and the motors lost, without an alarm
	var w7 := RobotFaultWatch.new()
	var h := _fine_state()
	w7.arm(h)
	h.homed = false
	h.motors_enabled = false
	var lost: Array = codes.call(w7.update(h))
	# the link gone: only that (the rest of the state is old), once
	var w8 := RobotFaultWatch.new()
	var l := _fine_state()
	w8.arm(l)
	l.link = false
	l.state = "ALARM"
	var link: Array = codes.call(w8.update(l))
	var link_once: bool = w8.update(l).is_empty()
	var robot_gone := RobotFaultWatch.new()
	var r := _fine_state()
	robot_gone.arm(r)
	r.connected = false
	r.homed = false  # (what the backend resets with it is not another fault)
	r.motors_enabled = false
	var core2: Array = codes.call(robot_gone.update(r))
	_ok(idle and quiet and alarm == ["corexy/alarm"] and again and old_one and claw == ["claw/alarm"] and zpc == ["z/z_servo_power_cycle"]
		and easy_fault == ["z/easy_fault"] and stopped_quiet and lost == ["corexy/homing_lost", "corexy/motors_off"]
		and link == ["link/link_lost"] and link_once and core2 == ["link/robot_disconnected"],
		"robot fault #292: only new faults count (an alarm, a servo by its id, the easy sequence failing without an alarm, homing / motors lost, the link or the robot gone); the same one again, one there before, a stop or a busy are not",
		"%s %s %s %s %s %s %s %s %s %s %s %s" % [idle, quiet, alarm, again, old_one, claw, zpc, easy_fault, stopped_quiet, lost, link, core2])
	# what still keeps the crane from a new game, in order
	var fine: bool = RobotFaultWatch.problems(_fine_state()).is_empty() and RobotFaultWatch.still(_fine_state())
	var p := _fine_state()
	p.state = "ALARM"
	p.homed = false
	p.motors_enabled = false
	var al: Array = RobotFaultWatch.problems(p).map(func(x): return x.code)
	p.state = "ESTOP"
	var es: Array = RobotFaultWatch.problems(p).map(func(x): return x.code)
	p.state = "IDLE"
	p.arm_servo_power_cycle = true
	var after_clear: Array = RobotFaultWatch.problems(p).map(func(x): return x.code)
	var q := _fine_state()
	q.easy_mode = {"state": "MANUAL_XY", "blockers": ["not homed"]}
	var easy_bl: Array = RobotFaultWatch.problems(q, true).map(func(x): return x.code)
	var easy_ignored: bool = RobotFaultWatch.problems(q, false).is_empty()
	q.state = "MOVING_XY"
	var moving: bool = not RobotFaultWatch.still(q) and RobotFaultWatch.problems(q)[0].code == "moving"
	var gone := _fine_state()
	gone.link = false
	var no_link: bool = RobotFaultWatch.problems(gone).map(func(x): return x.code) == ["link"] and not RobotFaultWatch.still(gone)
	_ok(fine and al == ["alarm"] and es == ["estop"] and after_clear == ["arm_power", "home", "motors"] and easy_bl == ["easy_blocker"]
		and easy_ignored and moving and no_link,
		"robot fault #292: what is left before a new game: the alarm / emergency stop first (homing waits for it), a servo's power, homing, the motors, a moving arm, the easy mode's blockers, the link",
		"%s %s %s %s %s %s %s %s" % [fine, al, es, after_clear, easy_bl, easy_ignored, moving, no_link])

## #292: a fault of the crane in the round: the game stops once and stays stopped; the staff's
## screen; clearing, preparing (asked twice), Space between; a new game only after the
## backend's state is checked; the mock is never stopped.
func _test_robot_fault_stop(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	var guard: RobotFaultGuard = game.robot_guard
	var panel: StaffRecoveryPanel = game.recovery_panel
	var tick := func(n := 2) -> void:
		for i in n:
			guard.tick(1.0 / 60.0)
			ctl.tick(1.0 / 60.0)
	var types := func() -> Array: return game.ws._pending.values().map(func(x): return str(x.type))
	var answer := func(type: String, ok: bool, data := {}) -> String:
		for rid in game.ws._pending.keys():
			if str(game.ws._pending[rid].type) == type:
				game.ws._pending.erase(rid)
				var d: Dictionary = data.duplicate()
				d.command = type
				game.ws.ack.emit(str(rid), ok, d)
				return str(rid)
		return ""
	# the mock: a round goes on whatever (the watch is not for the game's own crane)
	_gm_playing(game)
	RobotState.machine_state = "ALARM"
	tick.call(5)
	var mock_untouched: bool = ctl.phase == "PLAYING" and not ctl.robot_fault_latched() and not panel._banner.visible
	RobotState.machine_state = "IDLE"
	game.stop_key()
	# the backend's robot (a stand-in link)
	game.mock.enabled = false
	RobotState.source = "websocket"
	game.ws.server_robot = "mock"  # #299: a backend that said which crane it runs (the real one has its own start check)
	RobotState.connected = true
	RobotState.motors_enabled = true
	RobotState.homed = true
	RobotState.machine_state = "IDLE"
	RobotState.robot_error = ""
	RobotState.easy_mode = {}
	RobotState.calibration_prepare = {}
	game.backend_link = func() -> bool: return true
	game.ws._pending.clear()
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	tick.call(5)
	game.ws.ack.emit("unknown-rid", false, {"command": "jog", "reason": "busy: another motion command is running"})
	tick.call(5)
	var normal: bool = ctl.phase == "PLAYING" and not ctl.robot_fault_latched() and types.call().is_empty()
	# 1. an alarm in the round: stopped once, latched, nothing sent on top of the alarm
	ctl.score.score = 1234
	RobotState.machine_state = "ALARM"
	RobotState.homed = false
	RobotState.robot_error = "position lost"
	tick.call(2)
	var f: Dictionary = ctl.robot_fault
	var halted: bool = ctl.phase == "STOPPED" and str(f.get("code")) == "alarm" and str(f.get("category")) == "corexy" \
		and int(f.count) == 1 and str(f.phase) == "PLAYING" and guard.stop_state == "alarm" and not types.call().has("soft_stop") \
		and ctl.message.contains("ゲーム停止") and ctl.message.contains("CoreXY")
	panel.refresh()
	var banner: bool = panel._banner.visible and panel._banner_label.text.contains("スタッフを呼んでください") and not panel.is_open()
	tick.call(5)  # the same alarm again: nothing more
	var once: bool = int(ctl.robot_fault.count) == 1
	# 5. nothing starts it again: Enter, T, F6 / F7, the start itself, the practice
	game._unhandled_input(_key(KEY_ENTER))
	game._unhandled_input(_key(KEY_T))
	game._unhandled_input(_key(KEY_F6))
	game._unhandled_input(_key(KEY_F7))
	ctl.start()
	ctl.start_tutorial()
	var held: bool = ctl.phase == "STOPPED" and ctl.robot_fault_latched() and ctl.start_blocked().contains("スタッフ")
	# no key of the crane either (review on #294): the claw (Q / A / [ ]) and the auto catch (C)
	game.ws._pending.clear()
	for k in [KEY_Q, KEY_A, KEY_BRACKETLEFT, KEY_BRACKETRIGHT, KEY_C]:
		game._unhandled_input(_key(k))
	held = held and types.call().is_empty() and game.jog_hint.contains("異常")
	# the staff: F9 opens the screen (nothing sent); #291's capsule probe, if open, gives way to it
	game.ws._pending.clear()
	game.open_capsule_probe()
	game._unhandled_input(_key(KEY_F9))
	panel.refresh()
	var opened: bool = panel.is_open() and types.call().is_empty() and panel._cause.text.contains("position lost") \
		and panel._todo.text.contains("アラーム") and not game.capsule_probe_active() and panel.layer > game.capsule_probe.layer
	# まとめて準備 asks twice; Space in between takes the first press back
	var first := guard.prepare()
	var armed: bool = first and guard.confirm_left > 0.0 and types.call().is_empty()
	game.stop_key()
	game.ws._pending.clear()
	var space_off: bool = guard.confirm_left == 0.0
	game._unhandled_input(_key(KEY_F9))  # F9 on the open screen = まとめて準備: armed again
	var still_none: bool = types.call().is_empty() and guard.confirm_left > 0.0
	game._unhandled_input(_key(KEY_F9))  # the second: clear_alarm, then (when answered) the preparation
	var cleared_first: bool = types.call() == ["clear_alarm"]
	var dup := guard.prepare()  # a third press while waiting: nothing
	dup = guard.prepare() or dup
	var no_dup: bool = types.call() == ["clear_alarm"]
	answer.call("clear_alarm", true)
	var prep_sent: bool = types.call() == ["calibration_prepare"]
	RobotState.machine_state = "IDLE"
	tick.call(2)
	# 7. the alarm again while preparing: the cause is brought up to date, still stopped
	RobotState.machine_state = "ALARM"
	RobotState.robot_error = "limit x"
	tick.call(2)
	var again: bool = int(ctl.robot_fault.count) == 2 and str(ctl.robot_fault.latest.error) == "limit x" \
		and str(ctl.robot_fault.error) == "position lost" and str(ctl.robot_fault.phase) == "PLAYING" and ctl.phase == "STOPPED" \
		and StaffRecoveryPanel.cause_text(ctl.robot_fault, guard.stop_state).contains("limit x")
	answer.call("calibration_prepare", false, {"reason": "alarm"})
	# アラーム解除 alone moves nothing
	game.ws._pending.clear()
	var clear_ok := guard.clear_alarm()
	var clear_only: bool = clear_ok and types.call() == ["clear_alarm"]
	answer.call("clear_alarm", true)
	var no_follow: bool = types.call().is_empty()  # (not the recovery chain: nothing moves after it)
	RobotState.machine_state = "IDLE"
	tick.call(2)
	# what the staff's own steps change (the motors, homing) is not a new fault
	RobotState.motors_enabled = false
	tick.call(2)
	RobotState.motors_enabled = true
	tick.call(2)
	no_follow = no_follow and int(ctl.robot_fault.count) == 2
	# 6. not yet: the backend's answer still shows homing missing -> stays stopped
	guard.finish()
	var st_bad := _fine_state()
	st_bad.erase("link")
	st_bad.homed = false
	answer.call("get_state", true, st_bad)
	var refused: bool = ctl.robot_fault_latched() and not guard.action_ok and guard.action_note.contains("原点")
	# prepared: homed, motors on; the backend's answer says so -> the latch ends, a new game only
	RobotState.homed = true
	RobotState.motors_enabled = true
	RobotState.robot_error = ""
	tick.call(2)
	game._unhandled_input(_key(KEY_F9))  # the crane ready: F9 (the remote's RECOVER) is the check
	var asked_state: bool = types.call() == ["get_state"]
	var st_ok := _fine_state()
	st_ok.erase("link")
	var late: String = answer.call("get_state", true, st_ok)
	var released: bool = asked_state and not ctl.robot_fault_latched() and ctl.phase == "IDLE" and guard.action_note.contains("ふっきした") \
		and not panel.is_open()
	var late_ignored: bool = not guard.on_ack(late, true, {})  # a late answer again: nothing
	game._unhandled_input(_key(KEY_ENTER))
	var new_game: bool = ctl.running() and ctl.score.score == 0
	_ok(mock_untouched and normal and halted and banner and once and held and opened and armed and space_off and still_none
		and cleared_first and not dup and no_dup and prep_sent and again and clear_only and no_follow and refused and released
		and late_ignored and new_game,
		"robot fault #292: an alarm in the round stops the game once (nothing sent on top of the alarm) and latches it: the banner, no start by Enter / T / F6 / F7; F9 opens the staff's screen, まとめて準備 is asked twice (Space takes it back), clear_alarm then the preparation, no double send; a new alarm updates the cause; the latch ends only when the backend's state shows the crane ready, and then a new game (score 0); the mock is never stopped",
		"%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s | %s %s" % [mock_untouched, normal, halted, banner, once, held, opened, armed,
			space_off, still_none, cleared_first, dup, no_dup, prep_sent, again, clear_only, no_follow, refused, released, new_game,
			ctl.robot_fault, guard.action_note])
	# 2. the easy sequence failing without an alarm: soft_stop once, confirmed by a sample after it
	_gm_step(ctl, ctl.countdown_s + 0.2)
	tick.call(3)
	game.ws._pending.clear()
	# #302: a servo command that only failed (the backend stopped with STOP): the game plays on
	RobotState.easy_mode = {"state": "FAULT", "error": "RELEASE failed: SERVO_TURN id=2 result=FAILED reason=feedback_lost",
		"last_result": "fault", "active": false, "servo_fault": true}
	tick.call(2)
	var servo_plays_on: bool = ctl.phase == "PLAYING" and not ctl.robot_fault_latched() and types.call().count("soft_stop") == 0
	RobotState.easy_mode = {"state": "MANUAL_XY", "last_result": "done", "active": false}
	tick.call(2)
	game.ws._pending.clear()
	RobotState.easy_mode = {"state": "FAULT", "error": "servo id=2 did not reach", "last_result": "fault", "active": false}
	tick.call(2)
	var easy_halt: bool = servo_plays_on and ctl.phase == "STOPPED" and str(ctl.robot_fault.code) == "easy_fault" and str(ctl.robot_fault.category) == "claw" \
		and types.call().count("soft_stop") == 1 and guard.stop_state == "requested"
	tick.call(2)
	var not_yet: bool = guard.stop_state == "requested"  # no sample since: not confirmed
	RobotState.pose_updated.emit(0.0, 0.0, 0.0, "IDLE")
	tick.call(1)
	var confirmed: bool = guard.stop_state == "confirmed" and types.call().count("soft_stop") == 1
	# recovered (a stand-in for the staff's steps) -> a new round; 3. the link lost: unconfirmed, nothing sent
	RobotState.easy_mode = {}
	tick.call(1)
	guard.finish()
	answer.call("get_state", true, _fine_state())
	var back: bool = not ctl.robot_fault_latched()
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	tick.call(3)
	game.ws._pending.clear()
	game.backend_link = func() -> bool: return false
	tick.call(2)
	var link_halt: bool = ctl.phase == "STOPPED" and str(ctl.robot_fault.code) == "link_lost" and guard.stop_state == "unconfirmed" \
		and types.call().is_empty() and StaffRecoveryPanel.cause_text(ctl.robot_fault, guard.stop_state).contains("停止未確認")
	var no_move: bool = not guard.prepare() and guard.move_blocked().contains("バックエンド") and not guard.finish()
	# the link back: the stop goes out once (a backend sequence may still run), not again
	game.backend_link = func() -> bool: return true
	tick.call(3)
	var resent: bool = types.call().count("soft_stop") == 1
	answer.call("soft_stop", true)
	tick.call(3)
	resent = resent and types.call().is_empty()
	link_halt = link_halt and resent
	# 3'. homing lost while playing (no alarm), stop never seen: unconfirmed after its time
	tick.call(1)
	guard.finish()
	answer.call("get_state", true, _fine_state())
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	tick.call(3)
	game.ws._pending.clear()
	RobotState.homed = false
	tick.call(2)
	var homing_halt: bool = ctl.phase == "STOPPED" and str(ctl.robot_fault.code) == "homing_lost" and guard.stop_state == "requested"
	tick.call(int(RobotFaultGuard.STOP_CONFIRM_S * 60.0) + 5)
	var unconfirmed: bool = guard.stop_state == "unconfirmed"
	_ok(easy_halt and not_yet and confirmed and back and link_halt and no_move and homing_halt and unconfirmed,
		"robot fault #292: the easy sequence failing without an alarm stops the game with one soft_stop, confirmed only by a state after it; the link lost stops it with nothing sent (stop unconfirmed, the arm may not be moved); homing lost too, unconfirmed when no state shows the stop",
		"%s %s %s %s %s %s %s %s %s" % [easy_halt, not_yet, confirmed, back, link_halt, no_move, homing_halt, unconfirmed, ctl.robot_fault])
	ctl.robot_fault = {}
	game.ws._pending.clear()
	RobotState.easy_mode = {}
	RobotState.calibration_prepare = {}
	RobotState.robot_error = ""
	RobotState.machine_state = "IDLE"
	RobotState.source = "mock"
	game.ws.server_robot = ""
	RobotState.connected = false
	RobotState.motors_enabled = false
	RobotState.homed = false
	_gm_free(game, rs)
