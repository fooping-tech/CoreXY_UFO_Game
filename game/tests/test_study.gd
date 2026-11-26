extends "res://tests/test_base.gd"
## The study mode and the homework helper.

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
		and not hud.has_method("_build_checklist")  # #237: no list at the right any more
	_study_pump(game, 15.0, func(): return ctl.state == "WAITING_FOR_WORKSHEET")
	# #283: no grade picker on the screen: , and . do nothing, the help does not offer it
	var before_keys := ctl.grade_label()
	ctl.handle_key(KEY_COMMA)
	ctl.handle_key(KEY_PERIOD)
	var no_picker := ctl.grade_label() == before_keys and not StudyHud.key_help("WAITING_FOR_WORKSHEET", "simulated").contains("学年")
	ctl.change_grade(-1)  # 小学2年 (the settings screen's grade, as before)
	var grade_ok := no_picker and ctl.grade_label() == "小学2年"
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
	var order_ok := captures == ["CAPTURE_10CM"]  # #110: one close-up, 10 cm
	var went_down: bool = game.mock.target != target_before
	_study_pump(game, 40.0, func(): return ctl.state == "STUDYING")
	var explained_ok := ctl.state == "STUDYING" and str(ctl.explanation.get("hint", "")) != "" \
		and str(ctl.explanation.get("source", "")) == "demo"
	_ok(intro_ok and grade_ok and studying_ok and one_ok, "study mock: intro, grade, the sheet is found, a problem filled",
		"%s %s %s %s" % [intro_ok, grade_ok, studying_ok, one_ok])
	_ok(help_ok and moving and halted and order_ok and went_down and explained_ok,
		"study mock: HELP looks at problem 3 with the 10cm close-up, explains, and the jog is held meanwhile",
		"%s %s %s %s %s %s %s" % [help_ok, moving, halted, captures, went_down, explained_ok, ctl.state])
	# #237: every problem written -> the answer check with UFOくん (not the celebration yet)
	ctl.handle_key(KEY_2)
	ctl.handle_key(KEY_3)
	_study_pump(game, 2.0)
	var not_early := ctl.celebrate_count == 0
	var celebrations_before: int = game.vfx.celebrations
	_study_pump(game, 12.0, func(): return ctl.state == "ANSWER_CHECK_READY")
	var check_ok: bool = ctl.state == "ANSWER_CHECK_READY" and events.has("study_complete") and ctl.celebrate_count == 0
	hud.refresh()
	var mission_now: bool = hud.sheet.answer_marks.is_empty() and hud._pop.text == "こたえあわせ！"
	_ok(not_early and check_ok and mission_now, "study mock: the 3 problems written start the answer check, not the celebration",
		"%s %s %s %s" % [not_early, check_ok, mission_now, ctl.state])
	# one reading, shown one problem at a time from 1 (the simulated reading: 1 right, 2 to look at, 3 right)
	var order: Array = []
	var on_shown := func(e: String, d: Dictionary):
		if e in ["study_answer_correct", "study_answer_review"]:
			order.append([int(d.number), e])
	GameState.event.connect(on_shown)
	var mids: Array = []  # a lambda cannot assign an outer local: collect instead
	_study_pump(game, 20.0, func():
		if ctl.state == "GRADING_QUESTION" and ctl.shown.size() == 1 and ctl.shown.has(1):
			mids.append(true)
		return ctl.state == "REVIEW_SUMMARY")
	var mid := not mids.is_empty()
	hud.refresh()
	var am: Dictionary = hud.sheet.answer_marks
	var chips := [str(am.get(1, {}).get("verdict", "")), str(am.get(2, {}).get("verdict", "")), str(am.get(3, {}).get("verdict", ""))]
	var graded_ok: bool = ctl.state == "REVIEW_SUMMARY" and mid and order == [[1, "study_answer_correct"], [2, "study_answer_review"],
		[3, "study_answer_correct"]] and chips == ["correct", "review", "correct"] and hud.sheet.mark_point(1) != Vector2.ZERO \
		and ctl.energy() == 2 and hud._energy.text == "⚡ × 2" and hud._count.text == "せいかい 2 / 3" \
		and ctl.review_waiting() and ctl.speech.current.contains("2ばんは")
	_ok(graded_ok, "study mock: the reading is shown from problem 1, one at a time; ○ for right, ？ (never a cross) and a hint to look at again",
		str([ctl.state, mid, order, chips, ctl.energy(), ctl.speech.current]))
	# rewritten: R reads again; only the one to look at is shown again; the reward is never given twice
	ctl.handle_key(KEY_R)
	var rescanning := ctl.state == "RESCAN" and ctl.adult_prompt == ""
	_study_pump(game, 20.0, func(): return ctl.state == "REWARD_REVEAL")
	hud.refresh()
	var reward_ok: bool = ctl.state == "REWARD_REVEAL" and ctl.grading.all_correct() and order.size() == 4 and order[3] == [2, "study_answer_correct"] \
		and int(ctl.reward.time_bonus_s) == 40 and int(ctl.reward.power_tickets) == 1 and bool(ctl.reward.perfect) \
		and ctl.celebrate_count == 1 and game.vfx.celebrations == celebrations_before + 1 and game._mood() == "SUCCESS" \
		and hud._banner.text == "PERFECT!" and hud._sub_banner.text.contains("TIME +40") and hud._sub_banner.text.contains("POWER TICKET ×1")
	GameState.event.disconnect(on_shown)
	_ok(rescanning and reward_ok, "study mock: R reads the rewritten sheet again; all right: +30 s (the cap) +10 s perfect bonus, a ticket, PERFECT! once",
		str([rescanning, ctl.state, order, ctl.reward, hud._banner.text, hud._sub_banner.text]))
	# the ticket: a roulette goes round the powers and stops on one (here DOUBLE SCORE), once
	ctl.roulette_force = "double"
	_study_pump(game, 20.0, func(): return ctl.state == "POWERUP_SELECT")
	hud.refresh()
	var select_shown: bool = hud._powers.visible and ctl.roulette_spinning
	ctl.handle_key(KEY_1)  # nobody chooses: the keys do nothing here
	var lit: Array = []
	_study_pump(game, 10.0, func():
		if ctl.roulette_index >= 0 and (lit.is_empty() or lit[-1] != ctl.roulette_index):
			lit.append(ctl.roulette_index)
		return not ctl.selected_powerups.is_empty())
	var picked: bool = ctl.selected_powerups == ["double"] and ctl.reward.selected_powerups == ["double"] \
		and lit.size() >= 8 and 0 in lit and 1 in lit and 2 in lit and lit[-1] == 1 and not ctl.roulette_spinning
	_ok(select_shown and picked, "study mock: the power roulette goes round, slows down and stops on one power (no key picks it)",
		str([select_shown, lit.size(), ctl.selected_powerups]))
	# the tidy-up: waits for a grown-up to confirm the grip, then the game is ready with the reward
	_study_pump(game, 20.0, func(): return ctl.adult_prompt != "")
	var frozen := ctl.elapsed_s()
	var grip_wait := ctl.state == "CLEANUP" and ctl.adult_prompt.contains("つかめていたら") and hud._time_panel.visible
	_study_pump(game, 3.0)
	var still := ctl.state == "CLEANUP" and is_equal_approx(ctl.elapsed_s(), frozen)  # never by itself
	ctl.advance()
	_study_pump(game, 40.0, func(): return ctl.state == "GAME_READY_WITH_REWARD")
	hud.refresh()
	var unlocked: bool = ctl.state == "GAME_READY_WITH_REWARD" and ctl.cleanup_ok \
		and hud._play.visible and hud._banner.text == "STUDY POWER LOADED!" and hud._sub_banner.text.contains("TIME +40") \
		and hud._sub_banner.text.contains("DOUBLE SCORE READY")
	_ok(grip_wait and still and unlocked, "study mock: the tidy-up waits for the grip confirmation, then STUDY POWER LOADED!",
		"%s %s %s %s %s" % [grip_wait, still, unlocked, ctl.state, hud._sub_banner.text])
	var handed := []
	var on_reward := func(e: String, d: Dictionary):
		if e == "study_reward":
			handed.append(d)
	GameState.event.connect(on_reward)
	ctl.play_game()
	GameState.event.disconnect(on_reward)
	_ok(ctl.state == "OFF" and not hud.visible and game._mood() != "SUCCESS" and not ctl.blocks_manual_control()
		and handed.size() == 1 and ctl.last_reward.selected_powerups == ["double"] and int(ctl.last_reward.time_bonus_s) == 40,
		"study mock: 'ゲームで遊ぶ' hands the reward over once and leaves the study mode", str(handed))
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
	ctl.services.demo_results = ["correct", "correct", "correct"]
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 40.0, func(): return ctl.state == "POWERUP_SELECT")
	ctl.choose_powerup("speed")
	_study_pump(game, 30.0, func(): return ctl.state == "CLEANUP_FAILED")
	game.study_hud.refresh()
	var failed_ok: bool = ctl.state == "CLEANUP_FAILED" and not ctl.cleanup_ok and ctl.adult_prompt != "" \
		and game.study_hud._banner.visible == false
	ctl.advance()
	_ok(failed_ok and ctl.state == "GAME_READY_WITH_REWARD" and not ctl.cleanup_ok and game.study_hud._sub_banner.text.contains("大人"),
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

## #104: the tutor AI says the problem is not in the picture: the game looks again d_mm
## further (after the arm is back), at most twice, then the worksheet's hints.
func _test_study_mode_looks_again(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	var targets: Array = []
	var helps := func(): return ctl.services.last_help_target.get("xy", Vector2.ZERO)
	ctl.services.inject_navigate = [{"kind": "move", "d_mm": [0.0, 30.0]}]
	ctl.request_help()
	_study_pump(game, 30.0, func(): return ctl.nav_tries == 1 and ctl.state == "HELP_MOVING")
	targets.append(helps.call())
	_study_pump(game, 60.0, func(): return ctl.state == "STUDYING")
	var once: bool = ctl.nav_tries == 1 and str(ctl.explanation.get("source", "")) == "demo" \
		and not ctl.explanation.has("navigate")
	_ok(once and targets[0] != Vector2.ZERO, "study: not in the picture -> looks again 30 mm further, then explains",
		"%s %s %s" % [ctl.nav_tries, ctl.explanation.get("source"), targets])
	# twice "not here": stops looking and gives the worksheet's hints
	ctl.services.inject_navigate = [{"kind": "move", "d_mm": [0.0, 20.0]}, {"kind": "move", "d_mm": [0.0, 20.0]},
		{"kind": "move", "d_mm": [0.0, 20.0]}]
	var first := Vector2.ZERO
	ctl.request_help()
	_study_pump(game, 20.0, func(): return ctl.state == "HELP_MOVING")
	first = helps.call()
	_study_pump(game, 120.0, func(): return ctl.state == "STUDYING")
	var last: Vector2 = helps.call()
	_ok(ctl.nav_tries == StudyModeController.MAX_NAV and ctl.explain_note.contains("見つからなかった")
		and str(ctl.explanation.get("source", "")) == "worksheet" and is_equal_approx(last.y - first.y, 40.0),
		"study: at most two more looks, then the worksheet's hints", "%s %s %s %s" % [ctl.nav_tries, ctl.explain_note, first, last])
	# a step the checks refuse (over 60 mm): no motion, the worksheet's hints
	ctl.services.inject_navigate = [{"kind": "move", "d_mm": [0.0, 70.0]}]
	ctl.request_help()
	_study_pump(game, 60.0, func(): return ctl.state == "RESUME_STUDY" and ctl.notice.contains("もう一度"))
	var refused: String = ctl.notice
	_study_pump(game, 30.0, func(): return ctl.state == "STUDYING")
	_ok(refused.contains("大きすぎ") and str(ctl.explanation.get("source", "")) == "worksheet",
		"study: a refused look-again (over 60 mm) moves nothing and gives the hints", refused)
	# no d_mm (no arm camera calibration): no motion, the AI's own words
	ctl.services.inject_navigate = [{"kind": "move", "error": "先端カメラの校正がまだ"}]
	ctl.request_help()
	_study_pump(game, 60.0, func(): return ctl.state == "STUDYING")
	var said: Array = []
	for l in ctl._explain_lines(ctl.explanation, false):
		said.append(str(l.text))
	_ok(ctl.nav_tries == 0 and str(ctl.explanation.get("source", "")) == "demo"
		and ctl.explain_note.contains("アームは動かしません") and ctl.explain_note.contains("校正がまだ")
		and not " ".join(said).contains("さがしに"),
		"study: without d_mm (arm camera not calibrated) the arm does not look again, and says so (#242)",
		"%s %s" % [ctl.nav_tries, ctl.explain_note])
	# Space while waiting to look again: no looking again
	ctl.services.inject_navigate = [{"kind": "move", "d_mm": [0.0, 30.0]}]
	ctl.request_help()
	_study_pump(game, 30.0, func(): return ctl.nav_tries == 1)
	ctl.on_stop_key()
	_study_pump(game, 5.0, func(): return false)
	_ok(ctl.state == "ERROR" and ctl._pending_nav.is_empty() and not ctl.services.motion_active(),
		"study: Space while about to look again stops it", ctl.state)
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

## The backend route: the sequences' status messages drive the story (holding at a
## stage -> that close-up; the previous run's IDLE / FAULT ignored; NACK and FAULT end it).
## #110: the tidy-up off (study_mode.cleanup.enabled false): the game unlocks after the celebration.
## #116: the real worksheet from the overview camera, straightened by its corner marks.
func _test_focus_stream() -> void:
	# #118: the backend's stabilized arm camera: packet, URL, and CameraHub showing it while live
	var head := JSON.stringify({"seq": 7, "w": 32, "h": 24, "stabilized": true, "dx": 3.0}).to_utf8_buffer()
	var pkt := "FCS1".to_ascii_buffer()
	var n := PackedByteArray()
	n.resize(4)
	n.encode_u32(0, head.size())
	pkt.append_array(n)
	pkt.append_array(head)
	pkt.append_array(PackedByteArray([0xff, 0xd8, 1, 2]))
	var p := FocusStream.parse(pkt)
	_ok(not p.is_empty() and int(p.header.seq) == 7 and p.jpeg == PackedByteArray([0xff, 0xd8, 1, 2])
		and FocusStream.parse("nope".to_ascii_buffer()).is_empty() and FocusStream.parse(pkt.slice(0, 12)).is_empty(),
		"focus stream: the frame packet (magic, header, JPEG)")
	_ok(FocusStream.url_for("ws://127.0.0.1:8765", 8766) == "ws://127.0.0.1:8766"
		and FocusStream.url_for("ws://robot.local:8765/x", 9000) == "ws://robot.local:9000"
		and FocusStream.url_for("ws://[::1]:8765", 8766) == "ws://[::1]:8766",
		"focus stream: next to the backend's address")
	var hub := CameraHub.new()
	add_child(hub)
	var fs := FocusStream.new()
	hub.stream = fs
	hub.add_child(fs)
	var before := hub.external_live("focus")
	var img := Image.create(32, 24, false, Image.FORMAT_RGB8)
	img.fill(Color(1, 0, 0))
	fs.apply_frame(p.header, img)
	hub._process(0.0)
	var live := hub.external_live("focus") and hub.has_feed("focus") and hub.feed_size("focus") == Vector2(32, 24) \
		and hub._mode_for("focus") == 1 and not hub.external_live("overview")
	var shown: bool = hub._convert["focus"].get_shader_parameter("rgb_tex") == fs.texture
	fs._last_frame_ms -= FocusStream.STALE_MS + 10  # frames stopped: back to the direct feed
	hub._process(0.0)
	var back := not hub.external_live("focus") and not hub.has_feed("focus")
	var txt: String = load("res://scripts/ui/debug_ui.gd").stabilize_text(fs)
	_ok(not before and live and shown and back and txt.contains("映像なし"),
		"focus stream: CameraHub shows the stabilized frames while they arrive, its own feed after")
	# review on #119: a Focus camera picked by hand wins over the stream
	fs.apply_frame(p.header, img)
	hub.assign("focus", -1)
	var picked := not fs.active and not hub.external_live("focus") and not hub.has_feed("focus")
	fs._process(0.0)
	var picked_txt: String = load("res://scripts/ui/debug_ui.gd").stabilize_text(fs)
	hub._manual["focus"] = false  # the pick undone (its camera unplugged): the stream again
	hub._apply_feeds()
	_ok(picked and fs.state == "off" and picked_txt.contains("休止中") and fs.active and hub.external_live("focus"),
		"focus stream: a Focus camera picked by hand pauses the stream")
	hub.queue_free()

func _test_study_sheet_photo(rs: Node) -> void:
	# the homography takes the four page points to the image points (and the middle where it belongs)
	var src := [Vector2(0.1, 0.1), Vector2(0.9, 0.1), Vector2(0.1, 0.9), Vector2(0.9, 0.9)]
	var dst := [Vector2(0.3, 0.2), Vector2(0.7, 0.25), Vector2(0.25, 0.8), Vector2(0.75, 0.85)]
	var h = StudyWorksheetView.homography(src, dst)
	var good := h != null
	for i in 4:
		var q: Vector3 = h * Vector3(src[i].x, src[i].y, 1.0)
		good = good and (Vector2(q.x, q.y) / q.z).distance_to(dst[i]) < 1e-4
	_ok(good and StudyWorksheetView.homography([Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2.ONE],
		[Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2.ONE]) != null
		and StudyWorksheetView.homography([Vector2.ZERO, Vector2(0.5, 0.5), Vector2.ONE, Vector2(2, 2)], dst) == null,
		"sheet photo: the homography maps the four marks (and refuses three on a line)")
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	var sv: StudyServices = ctl.services
	sv._on_sheet_found(true, {"found": true, "corners": {"tl": [0.3, 0.2], "tr": [0.7, 0.25], "bl": [0.25, 0.8], "br": [0.75, 0.85]}})
	var view: StudyWorksheetView = game.study_hud.sheet
	view.photo_texture = ImageTexture.create_from_image(Image.create(64, 48, false, Image.FORMAT_RGB8))
	view.marks = sv.sheet_marks()
	view.worksheet = ctl.worksheet
	view.size = Vector2(230, 325)
	view._draw()
	var photo_on: bool = view.showing_photo() and view._photo.visible
	var stale := sv.sheet_marks(Time.get_ticks_msec() + StudyServices.SHEET_FRESH_MS + 100).is_empty()
	sv._on_sheet_found(true, {"found": false})  # not found now: the last ones age out
	view.marks = {}
	view._draw()
	_ok(photo_on and stale and not view._photo.visible and not sv.sheet_marks().is_empty(),
		"sheet photo: the real sheet with fresh marks, the drawn sheet without them")
	# review on #117: a frame in the params never reaches the log; no search after the study mode
	var red = UfoWebSocketClient.redacted({"image_jpeg_base64": "A".repeat(5000), "images": [{"role": "10cm",
		"image_jpeg_base64": "B".repeat(900)}], "u": 0.5})
	var log_ok: bool = str(red.image_jpeg_base64).begins_with("<5000") and str(red.images[0].image_jpeg_base64).begins_with("<900") \
		and is_equal_approx(float(red.u), 0.5)
	sv.watch_stop()
	sv._sheet_left = 0.0
	sv._sheet_tick(0.1)
	_ok(log_ok and sv._sheet_rid == "" and sv.sheet_marks().is_empty(),
		"sheet photo: frames are not logged, no worksheet search outside the study mode")
	# #130: the frame fits the robot link (its send buffer, the backend's 1 MiB per message);
	# a busy 1280x960 camera frame is squeezed under the limit
	var noisy := Image.create(1280, 960, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 130
	for y in range(0, 960, 4):
		for x in range(0, 1280, 4):
			noisy.fill_rect(Rect2i(x, y, 4, 4), Color(rng.randf(), rng.randf(), rng.randf()))
	var jpeg := StudyClient.encode_jpeg(noisy, StudyServices.SHEET_IMAGE_EDGE, StudyServices.SHEET_IMAGE_BYTES)
	var worst := JSON.stringify({"type": "command", "request_id": "g0000000000-000000", "timestamp": 0,
		"data": {"name": "worksheet_find", "params": {"image_jpeg_base64": "A".repeat(int(ceil(StudyServices.SHEET_IMAGE_BYTES / 3.0)) * 4)}}})
	_ok(not jpeg.is_empty() and jpeg.size() <= StudyServices.SHEET_IMAGE_BYTES and worst.length() < 1048576
		and game.ws.outbound_buffer_size >= worst.length(),
		"sheet photo: the camera frame fits the robot link (send buffer, the backend's 1 MiB)", "%d bytes" % jpeg.size())
	# #130: one odd answer does not throw the picture, two that agree move it, a near one is blended
	var base := {"tl": Vector2(0.3, 0.2), "tr": Vector2(0.7, 0.2), "bl": Vector2(0.3, 0.8), "br": Vector2(0.7, 0.8)}
	var far := {"tl": Vector2(0.4, 0.2), "tr": Vector2(0.8, 0.2), "bl": Vector2(0.3, 0.8), "br": Vector2(0.7, 0.8)}
	sv.sheet_corners = {}
	sv.sheet_seen_ms = -1
	sv._sheet_take(base.duplicate(), 1000)
	sv._sheet_take(far.duplicate(), 2000)
	var held: bool = sv.sheet_marks(2000).tl.is_equal_approx(Vector2(0.3, 0.2))
	sv._sheet_take(far.duplicate(), 3000)
	var moved: bool = sv.sheet_marks(3000).tl.is_equal_approx(Vector2(0.4, 0.2))
	var near := far.duplicate()
	near.tl = Vector2(0.41, 0.2)
	sv._sheet_take(near, 4000)
	var blended: bool = sv.sheet_marks(4000).tl.is_equal_approx(Vector2(0.405, 0.2))
	var kept := not sv.sheet_marks(4000 + StudyServices.SHEET_FRESH_MS - 100).is_empty()
	_ok(held and moved and blended and kept,
		"sheet photo: an odd answer is held back, two that agree move it, a near one is blended, kept while unseen",
		str([held, moved, blended, kept]))
	# the study mode's debug log: the sheet search's outcome once per change, why locating failed
	var lines: Array = []
	var grab := func(t): lines.append(t)
	game.debug_log.connect(grab)
	sv._on_sheet_found(false, {"reason": "timeout"})
	sv._on_sheet_found(false, {"reason": "timeout"})
	sv.locate_failed.emit("テスト")
	game.debug_log.disconnect(grab)
	var refused := lines.filter(func(l): return str(l).begins_with("study: sheet search: refused: timeout"))
	_ok(refused.size() == 1 and lines.has("study: locate failed: テスト"),
		"study log: the sheet search's outcome (once per change) and why locating failed", str(lines))
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

func _test_study_mode_without_tidy_up(rs: Node) -> void:
	var game := _study_game()
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = false
	var ctl: StudyModeController = game.study_mode
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	var seen: Array[String] = []
	ctl.state_changed.connect(func(_p, c): seen.append(c))
	_study_pump(game, 60.0, func():
		if ctl.state == "REVIEW_SUMMARY":
			ctl.advance()  # go on without rewriting: what to look at again stays, nothing is taken away
		if ctl.state == "POWERUP_SELECT":
			ctl.choose_powerup("multiball")
		return ctl.state == "GAME_READY_WITH_REWARD")
	game.study_hud.refresh()
	_ok(ctl.state == "GAME_READY_WITH_REWARD" and not "CLEANUP" in seen and not ctl.services.motion_active()
		and "REVIEW_SUMMARY" in seen and int(ctl.reward.confirmed_correct) == 2 and int(ctl.reward.time_bonus_s) == 20
		and ctl.reward.needs_review == [2] and int(ctl.reward.power_tickets) == 1
		and not game.study_hud._sub_banner.text.contains("お片付け"),
		"study: with the tidy-up off the game is ready after the reward, no arm motion; a problem left to look at keeps the rest", str(seen))
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = true
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

func _test_study_mode_backend_messages(rs: Node) -> void:
	var game := _study_game()
	var height: Dictionary = GameConfig.data["study_mode"]["height"]
	var kept := [height.get("capture_heights_cm"), height.get("landing")]
	height["capture_heights_cm"] = [10.0, 5.0]  # three close-ups still work (the config has one since #110)
	height["landing"] = true
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
	height["capture_heights_cm"] = kept[0]
	height["landing"] = kept[1]
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

## #136: 1 / 2 / 3 fingers offer help with that problem, a thumbs-up starts it; the arm
## camera's photo shows while it is explained.
func _test_study_hand_help(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	var studying := ctl.state == "STUDYING"
	var t := 100000.0
	ctl.hand_tick("thumb", t)  # a thumbs-up without an offer does nothing
	ctl.hand_tick("thumb", t + 1000.0)
	var thumb_alone := ctl.state == "STUDYING" and ctl.offer_problem == 0
	ctl.hand_tick("", t + 1100.0)
	ctl.hand_tick("peace", t + 1200.0)
	ctl.hand_tick("peace", t + 1500.0)  # not held long enough yet
	var too_short := ctl.offer_problem == 0
	ctl.hand_tick("peace", t + 1900.0)
	var offered := ctl.offer_problem == 2 and ctl.state == "STUDYING"
	ctl.hand_tick("thumb", t + 2000.0)
	ctl.hand_tick("thumb", t + 2700.0)
	var started := ctl.state == "HELP_LOCATING" and ctl.help_problem == 2 and ctl.offer_problem == 0
	_ok(studying and thumb_alone and too_short and offered and started,
		"study hand help: 2 fingers held offer problem 2, a thumbs-up then starts its HELP (not a thumb alone)",
		str([studying, thumb_alone, too_short, offered, started, ctl.state, ctl.offer_problem]))
	# an offer not answered goes away; 3 fingers offer problem 3; Y stays the configured problem
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.hand_tick("three", t)
	ctl.hand_tick("three", t + 700.0)
	var three := ctl.offer_problem == 3
	ctl.hand_tick("", t + 700.0 + ctl.hand_offer_s * 1000.0 + 10.0)
	var expired := ctl.offer_problem == 0
	ctl.request_help()
	var y_ok := ctl.help_problem == ctl.default_help_problem
	# the arm camera: shown through the explanation, then its photo
	ctl.state = "AI_EXPLAINING"
	var img := Image.create(32, 24, false, Image.FORMAT_RGB8)
	ctl.services.captures["10cm"] = img
	var photo := ctl.explain_photo()
	var scope_ok := ctl.wants_scope() and photo != null and photo.get_width() == 32
	ctl.state = "STUDYING"
	var no_photo := ctl.explain_photo() == null
	var gate_ok: bool = game.gesture_gate().begins_with("学習モード")
	_ok(three and expired and y_ok and scope_ok and no_photo and gate_ok,
		"study hand help: 3 fingers = problem 3, an unanswered offer ends, Y keeps its problem, the arm camera's photo while explaining, no hand jog",
		str([three, expired, y_ok, scope_ok, no_photo, gate_ok]))
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## #232: read locally, the overview frames go cut out and turned upright (the プリント tab's
## settings); the located point comes back on the whole frame.
func _test_study_local_frames(rs: Node) -> void:
	# the turn's direction, and to_frame is prepare's inverse (on real pixels)
	var img := Image.create(400, 300, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color.RED)
	var cw := SheetFrame.prepare(img, 90, Rect2())
	var ccw := SheetFrame.prepare(img, 270, Rect2())
	_ok(cw.get_size() == Vector2i(300, 400) and cw.get_pixel(299, 0) == Color.RED and ccw.get_pixel(0, 399) == Color.RED,
		"sheet frame: 90° turns clockwise (top-left to top-right), 270° the other way")
	var part := Rect2(0.25, 0.1, 0.5, 0.8)
	var spot := Vector2i(230, 70)  # inside the part
	var bad: Array = []
	for deg in SheetFrame.ROTATIONS:
		var src := Image.create(400, 300, false, Image.FORMAT_RGB8)
		src.set_pixel(spot.x, spot.y, Color.WHITE)
		var out := SheetFrame.prepare(src, deg, part)
		var found := Vector2i(-1, -1)
		for y in out.get_height():
			for x in out.get_width():
				if out.get_pixel(x, y).r > 0.5:
					found = Vector2i(x, y)
		var p := (Vector2(found) + Vector2(0.5, 0.5)) / Vector2(out.get_size())
		var back := SheetFrame.to_frame(p, deg, part, Vector2i(400, 300)) * Vector2(400, 300)
		if back.distance_to(Vector2(spot) + Vector2(0.5, 0.5)) > 0.01:
			bad.append([deg, found, back])
	_ok(bad.is_empty(), "sheet frame: a point of the image sent goes back to the same pixel of the frame, at every turn", str(bad))
	# saved per camera, read back
	var path := "user://test_sheet_frame.cfg"
	SheetFrame.save_settings({"overview": {"rotation": 180, "region": part}, "focus": {"rotation": 45, "region": 3}}, path)
	var got := SheetFrame.load_settings(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_ok(got.overview.rotation == 180 and got.overview.region.is_equal_approx(part) and got.focus.rotation == 0
		and got.focus.region == Rect2() and SheetFrame.load_settings("").is_empty(),
		"sheet frame: the settings are kept per camera; a bad turn or region reads as none", str(got))

	# the study mode: only a local session sends the prepared frame, and the located point comes back
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	var hw: HomeworkClient = sv.homework
	path = "user://test_sheet_frame_study.cfg"
	SheetFrame.save_settings({"overview": {"rotation": 180, "region": part}}, path)
	hw.sheet_settings_path = path
	hw.worksheet_id = "mon-elem_1-01"
	hw.study_local = false
	var cloud_same: bool = hw.watch_image(img).get_size() == Vector2i(400, 300) and hw.sheet_settings().rotation == 0
	hw._on_message({"type": "hello", "data": {"homework": true, "study_ai": "local"}})
	var sent := hw.watch_image(img)
	var local_ok := hw.study_local and hw.reads_locally() and sent.get_size() == Vector2i(200, 240)
	hw.advice_available = false
	var blocker := hw.focus_blocker()
	sv._locate_prep = hw.sheet_settings()
	sv._locate_prep["size"] = Vector2i(400, 300)
	var at := sv.located_point(Vector2(0.0, 0.0))  # the top-left of the image sent = the region's bottom-right
	var located: Array = []
	sv.located.connect(func(d): located.append(d))
	sv._locate_rid = "sm-loc-1"
	sv._help_problem = 3
	sv._on_aux({"type": "homework_locate_result", "request_id": "sm-loc-1", "data": {"usable": true, "verified": true,
		"u": 1.0, "v": 1.0, "source": "sheet"}})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_ok(cloud_same and local_ok and not blocker.contains("アシスタント") and at.is_equal_approx(Vector2(0.75, 0.9))
		and located.size() == 1 and Vector2(located[0].u, located[0].v).is_equal_approx(Vector2(0.25, 0.1)),
		"study local: the watch's and the locate's frames go cut and turned; the located point is put back on the frame",
		str([cloud_same, local_ok, blocker, at, located]))
	sv._locate_prep = {}
	_ok(sv.located_point(Vector2(0.3, 0.4)) == Vector2(0.3, 0.4), "study local: an answer about the whole frame stays as it is")
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## #298: the reader's hand-off for a fixed camera: the whole frame upright with roi, quality >= 90,
## sent only once settled and not again while the same; the おく場所 of "ここへおいてね！".
func _test_sheet_roi(rs: Node) -> void:
	# a frame of distinct pixels: the roi's part of the whole upright frame is the part `prepare` cuts
	var img := Image.create(400, 300, false, Image.FORMAT_RGB8)
	for y in 300:
		for x in 400:
			img.set_pixel(x, y, Color(x / 400.0, y / 300.0, 0.5))
	var part := Rect2(0.25, 0.1, 0.5, 0.8)
	var bad: Array = []
	var off := Rect2(0.1, 0.2, 0.5, 0.6)  # off the middle: a wrong turn would cut another part
	for deg in SheetFrame.ROTATIONS:
		var req := SheetFrame.request(img, deg, off)
		var whole: Image = req.image
		var roi: Array = req.roi
		var cut := whole.get_region(SheetCheckPanel.roi_px(roi, whole.get_size()))
		var shown: Image = req.shown
		var far := shown.get_size() - Vector2i(4, 6)
		if roi.size() != 4 or cut.get_size() != shown.get_size() or whole.get_size() != SheetFrame.prepare(img, deg, Rect2()).get_size() \
				or not cut.get_pixel(3, 5).is_equal_approx(shown.get_pixel(3, 5)) \
				or not cut.get_pixel(far.x, far.y).is_equal_approx(shown.get_pixel(far.x, far.y)):
			bad.append([deg, roi, cut.get_size(), shown.get_size()])
	var none := SheetFrame.request(img, 90, Rect2())
	var tiny := SheetFrame.roi_of(Vector2i(400, 300), 0, Rect2(0, 0, 0.04, 0.5))  # 16 px: the whole frame
	var thin := SheetFrame.roi_of(Vector2i(4000, 3000), 0, Rect2(0, 0, 0.04, 0.5))  # 40 of 1000: under the server's 50
	# (review on #300) a region under the server's minimum falls back to the whole frame everywhere:
	# what is sent, what is shown and the way back to the frame (HELP's arm target)
	var narrow := Rect2(0.3, 0.2, 0.04, 0.5)  # 51 px of 1280: past MIN_REGION_PX, under 50/1000
	var big_frame := Image.create(1280, 960, false, Image.FORMAT_RGB8)
	var nreq := SheetFrame.request(big_frame, 0, narrow)
	var same_way: bool = (nreq.roi as Array).is_empty() and (nreq.shown as Image).get_size() == Vector2i(1280, 960) \
		and SheetFrame.prepare(big_frame, 0, narrow).get_size() == Vector2i(1280, 960) \
		and SheetFrame.to_frame(Vector2(0.5, 0.5), 0, narrow, Vector2i(1280, 960)).is_equal_approx(Vector2(0.5, 0.5))
	_ok(same_way and bad.is_empty() and (none.roi as Array).is_empty() and none.shown == none.image and tiny.is_empty() and thin.is_empty()
		and SheetFrame.roi_of(Vector2i(400, 300), 0, part) == [250, 100, 750, 900]
		and SheetFrame.roi_of(Vector2i(400, 300), 90, part) == [100, 250, 900, 750],
		"sheet roi: the whole frame goes upright with the region as roi (0..1000 of it, turned with it), the very part the game shows; none / too small = no roi",
		str(bad))
	# the JPEG: not shrunk, quality >= 90; smaller only when it cannot fit
	var big := Image.create(1280, 960, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in range(0, 960, 4):
		for x in range(0, 1280, 4):
			big.fill_rect(Rect2i(x, y, 4, 4), Color(rng.randf(), rng.randf(), rng.randf()))
	var full := SheetFrame.encode(big, 4000000)
	var back := Image.new()
	back.load_jpg_from_buffer(full)
	var at90 := big.save_jpg_to_buffer(0.9).size()
	var squeezed := SheetFrame.encode(big, at90 / 2)
	var back2 := Image.new()
	back2.load_jpg_from_buffer(squeezed)
	_ok(back.get_size() == Vector2i(1280, 960) and full.size() >= at90 and not squeezed.is_empty() and squeezed.size() <= at90 / 2
		and back2.get_width() < 1280 and SheetFrame.encode(big, 100).is_empty(),
		"sheet roi: the frame goes at its size and JPEG quality >= 90; only when it cannot fit the link it is made smaller",
		str([full.size(), at90, squeezed.size(), back2.get_size()]))
	# the おく場所: the guide shows it (else the 読む範囲); the 読む範囲 = it and 5% more; kept per camera
	var pl := Rect2(0.3, 0.2, 0.4, 0.5)
	var around := SheetFrame.region_around(pl)
	var path := "user://test_sheet_place.cfg"
	SheetFrame.save_settings({"overview": {"rotation": 90, "region": around, "place": pl}}, path)
	var got := SheetFrame.load_settings(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_ok(around.is_equal_approx(Rect2(0.28, 0.175, 0.44, 0.55)) and SheetFrame.region_around(Rect2(0, 0, 1, 1)) == Rect2(0, 0, 1, 1)
		and got.overview.place.is_equal_approx(pl) and SheetFrame.guide_rect(got.overview).is_equal_approx(pl)
		and SheetFrame.guide_rect({"region": part, "place": Rect2()}).is_equal_approx(part)
		and SheetFrame.guide_rect({}) == Rect2() and SheetFrame.for_role("overview", "").place == Rect2(),
		"sheet roi: \"ここへおいてね！\" goes on the おく場所 (else the 読む範囲); the 読む範囲 can be the おく場所 and 5% around it",
		str([around, got]))
	# the settling: the camera's first seconds, a dark picture, a moving one; the same picture once
	var gate := SheetSettle.new()
	var still := Image.create(64, 48, false, Image.FORMAT_RGB8)
	still.fill(Color(0.7, 0.7, 0.7))
	still.fill_rect(Rect2i(10, 10, 20, 20), Color(0.1, 0.1, 0.1))
	var moved := still.duplicate()
	moved.fill_rect(Rect2i(30, 10, 30, 30), Color(0.9, 0.3, 0.2))  # a hand comes in
	var dark := Image.create(64, 48, false, Image.FORMAT_RGB8)
	gate.sample(still, 10.0)
	var w1 := gate.blocker(10.0, 0.5)  # the camera opened half a second ago
	var w2 := gate.blocker(10.5, 5.0)  # still for 0.5 s only
	gate.sample(still, 11.2)
	var ok1 := gate.blocker(11.2, 5.0)
	gate.sample(moved, 11.4)
	var w3 := gate.blocker(11.4, 5.0)
	gate.sample(moved, 12.5)
	var ok2 := gate.blocker(12.5, 5.0)
	gate.mark_sent()
	var same := gate.same_as_sent()
	gate.sample(still, 13.0)
	var other := not gate.same_as_sent()
	gate.sample(moved, 13.2)
	gate.forget_sent()
	var forgot := not gate.same_as_sent()
	var g2 := SheetSettle.new()
	g2.sample(dark, 1.0)
	g2.sample(dark, 3.0)
	_ok(w1 == "warming" and w2 == "moving" and ok1 == "" and w3 == "moving" and ok2 == "" and same and other and forgot
		and g2.blocker(3.0, 5.0) == "dark" and SheetSettle.text("moving").contains("動いて") and gate.due(0.0) and not gate.due(0.1),
		"sheet roi: a frame goes once the camera warmed up and the picture is lit and has not moved for a second; the same picture is known",
		str([w1, w2, ok1, w3, ok2, same, other, forgot]))
	# the camera size: exactly 1280x960, else the largest 4:3 not wider; none = the camera's own
	var formats := [{"width": 640, "height": 480}, {"width": 1280, "height": 720}, {"width": 960, "height": 720},
		{"width": 1280, "height": 960}, {"width": 1600, "height": 1200}]
	_ok(CameraHub.pick_format(formats, Vector2i(1280, 960)) == 3 and CameraHub.pick_format(formats.slice(0, 3), Vector2i(1280, 960)) == 2
		and CameraHub.pick_format([{"width": 1920, "height": 1080}], Vector2i(1280, 960)) == -1
		and CameraHub.pick_format([], Vector2i(1280, 960)) == -1 and CameraHub.format_index(formats, Vector2i(640, 480)) == 0,
		"sheet roi: the overview camera is asked for 1280x960 (else its largest 4:3 up to that; none: its own size)")

	# the watch: settled frames only, the whole frame with the roi, nothing again while the same
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	var hw: HomeworkClient = sv.homework
	path = "user://test_sheet_roi_study.cfg"
	SheetFrame.save_settings({"overview": {"rotation": 180, "region": part, "place": pl}}, path)
	hw.sheet_settings_path = path
	hw.worksheet_id = "mon-elem_1-01"
	hw.study_local = true
	var cams := _FakeCams.new()
	cams.img = img
	var real_cams := hw.cameras
	var real_link := hw.link
	var spy := _VoiceLinkSpy.new()
	hw.cameras = cams
	hw.link = spy
	hw.state = "running"
	hw.session_id = "s1"
	hw.sheet_gate.reset()
	hw.sheet_gate.still_s = 60.0  # the picture "moves" for now
	hw._next_ms = 0
	hw._process(0.1)
	var waited: bool = spy.sent.is_empty() and hw.status_text.contains("動いて") and not hw._waiting
	hw.sheet_gate.still_s = 0.0
	hw._next_ms = 0
	hw._process(0.3)
	var frame: Dictionary = spy.sent[0].data if spy.sent.size() == 1 else {}
	var jpeg := Image.new()
	if frame.has("image_jpeg_base64"):
		jpeg.load_jpg_from_buffer(Marshalls.base64_to_raw(frame.image_jpeg_base64))
	var sent_ok: bool = spy.sent.size() == 1 and spy.sent[0].type == "homework_frame" and frame.get("roi") == [250, 100, 750, 900] \
		and jpeg.get_size() == Vector2i(400, 300)
	hw._on_message({"type": "homework_progress", "data": {"progress_pct": 0.0}})
	hw._next_ms = 0
	hw._process(0.3)
	var skipped: bool = spy.sent.size() == 1 and hw.skipped_same == 1 and hw.status_text.contains("変化なし")
	hw._waiting = true
	hw._on_message({"type": "homework_error", "data": {"code": "busy", "message": "混んでいる"}})
	hw._next_ms = 0
	hw._process(0.3)
	_ok(waited and sent_ok and skipped and spy.sent.size() == 2,
		"sheet roi: the watch waits while the picture moves, sends the whole frame upright with the roi, not again while the same (again after a failure)",
		str([waited, frame.get("roi"), jpeg.get_size(), skipped, spy.sent.size(), hw.status_text]))
	# the answer check and HELP wait for a settled picture a few seconds at most
	var calls := [0, 0]
	hw.sheet_gate.still_s = 60.0
	hw.sheet_gate.sample(img, 100.0)
	sv.when_settled(0.5, func(): return true, func(): calls[0] += 1)
	var before: int = calls[0]
	for i in 4:
		sv._process(0.25)
	hw.sheet_gate.still_s = 0.0
	sv.when_settled(3.0, func(): return true, func(): calls[1] += 1)
	var dropped := [0]
	hw.sheet_gate.still_s = 60.0
	hw.sheet_gate.sample(img, 200.0)
	sv.when_settled(3.0, func(): return false, func(): dropped[0] += 1)
	for i in 20:
		sv._process(0.25)
	_ok(before == 0 and calls[0] == 1 and calls[1] == 1 and dropped[0] == 0,
		"sheet roi: the answer check / HELP wait for a settled picture (at most a few seconds, then anyway; dropped when no longer wanted)",
		str([before, calls, dropped]))
	hw.cameras = real_cams
	hw.link = real_link
	hw.state = "stopped"
	# (review on #300) a new session sends its first picture even when it is the one sent last
	hw.sheet_gate.sample(img, 300.0)
	hw.sheet_gate.mark_sent()
	var was_same := hw.sheet_gate.same_as_sent()
	hw.start()
	var fresh := not hw.sheet_gate.same_as_sent()
	hw.stop()
	_ok(was_same and fresh, "sheet roi: a new watch session forgets the picture sent in the last one",
		str([was_same, fresh]))
	spy.free()
	cams.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## A camera hub with one fixed picture (the tests have no camera).
class _FakeCams:
	extends CameraHub
	var img: Image
	var live := 10.0

	func has_feed(_role: String) -> bool:
		return true

	func texture(_role: String) -> Texture2D:
		return ImageTexture.create_from_image(img)

	func live_s(_role: String) -> float:
		return live

## #233: the voice dialogue: hold V, speak, let go -> the text -> the tutor -> UFOくん says it.
func _test_study_voice(rs: Node) -> void:
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	var hw: HomeworkClient = sv.homework
	var vo := ctl.voice
	var hud: StudyHud = game.study_hud
	hw.sheet_settings_path = ""
	var sent: Array = []
	var real_link := hw.link
	var spy := _VoiceLinkSpy.new()
	spy.sent = sent
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.speech.clear()
	# no voice in the backend: says why, sends nothing
	hw.hello_seen = true
	hw.voice_available = false
	hw.voice_problem = "mlx-whisper を使えません"
	var why := vo.blocker()
	_ok(ctl.state == "STUDYING" and why.contains("mlx-whisper"), "study voice: without the backend's voice it says why", why)
	hw.voice_available = true
	hw.study_local = true
	hw.worksheet_id = str(ctl.current_worksheet().get("worksheet_id", ""))
	hw.link = spy  # what the study mode sends is recorded, nothing goes out
	var overview := Image.create(320, 240, false, Image.FORMAT_RGB8)
	vo.overview_source = func() -> Image: return overview
	_ok(vo.can_talk() and vo.status_text().contains("V を おしながら"), "study voice: while studying it invites to talk",
		vo.status_text())
	# #232: read locally, the sheet shown is the camera's crop that goes to the AI, not the drawing
	hud._crop = ImageTexture.create_from_image(Image.create(200, 240, false, Image.FORMAT_RGB8))
	hud.refresh()
	var crop_shown: bool = hud.sheet.crop_texture != null and hud.sheet.caption.contains("AI に送る")
	hw.study_local = false
	hud.refresh()
	var drawing_back: bool = hud.sheet.crop_texture == null and not hud.sheet.caption.contains("AI に送る")
	hw.study_local = true
	_ok(crop_shown and drawing_back, "study local: the sheet shown is the camera's crop sent to the AI (the drawing otherwise)",
		str([crop_shown, drawing_back, hud.sheet.caption]))
	ctl.handle_key(KEY_V)
	var listening: bool = vo.state == StudyVoice.LISTENING and sent.size() == 1 and sent[0].type == "homework_listen_start"
	ctl.handle_key_release(KEY_V)
	var stop_rid := str(sent[-1].get("request_id", ""))
	var hearing: bool = vo.state == StudyVoice.HEARING and sent[-1].type == "homework_listen_stop"
	hw._on_message({"type": "homework_heard", "request_id": stop_rid, "data": {"text": "ここが わからない"}})
	var talk: Dictionary = sent[-1]
	var asked: bool = talk.type == "homework_talk" and talk.data.text == "ここが わからない" and int(talk.data.target_problem) == 0 \
		and str(talk.data.image_jpeg_base64) != "" and vo.state == StudyVoice.THINKING
	hud.refresh()
	var shown: bool = hud._voice_bar.visible and hud._voice_text.text.contains("「ここが わからない」") \
		and hud._voice_text.text.contains("かんがえちゅう")
	_ok(listening and hearing and asked and shown,
		"study voice: held V listens, the release writes it down, the words and the worksheet go to the tutor",
		str([listening, hearing, asked, shown, hud._voice_text.text]))
	# streamed: the first sentence is said at once, the next queues, the result adds what is left
	hw._on_message({"type": "homework_talk_delta", "request_id": str(talk.request_id), "data": {"text": "いっしょに かんがえよう。"}})
	var at_once: bool = ctl.speech.current == "いっしょに かんがえよう。" and vo.state == StudyVoice.ANSWERING
	hw._on_message({"type": "homework_talk_delta", "request_id": str(talk.request_id), "data": {"text": "5こから2こ とると？"}})
	hw._on_message({"type": "homework_talk_result", "request_id": str(talk.request_id), "data": {
		"message": "いっしょに かんがえよう。5こから2こ とると？のこりを かぞえてね。", "rest": ["のこりを かぞえてね。"],
		"action": "talk", "target_problem": 3, "need_recapture": false}})
	var queued: Array = ctl.speech._queue.map(func(q): return q.text)
	var spoken: bool = at_once and queued == ["5こから2こ とると？", "のこりを かぞえてね。"] and vo.state == StudyVoice.IDLE \
		and vo.target_problem == 3 and vo.history == [{"role": "user", "content": "ここが わからない"},
			{"role": "assistant", "content": "いっしょに かんがえよう。5こから2こ とると？のこりを かぞえてね。"}]
	var busy_why := vo.blocker()
	ctl.speech.clear()
	ctl.handle_key(KEY_V)
	ctl.handle_key_release(KEY_V)
	hw._on_message({"type": "homework_heard", "request_id": str(sent[-1].request_id), "data": {"text": "もっと ヒント"}})
	var follow: Dictionary = sent[-1]
	_ok(spoken and busy_why.contains("話している") and int(follow.data.target_problem) == 3 and follow.data.history.size() == 2,
		"study voice: the first sentence is said as it comes, the rest queues; not while UFOくん speaks; the next turn keeps the problem and the turns",
		str([spoken, queued, busy_why, follow.data.get("target_problem"), vo.history]))
	# a closer look: the usual HELP for that problem after the answer
	hw._on_message({"type": "homework_talk_result", "request_id": str(follow.request_id), "data": {
		"message": "ちかくで みてみるね", "rest": ["ちかくで みてみるね"], "action": "talk", "target_problem": 2,
		"need_recapture": true}})
	var reset_turns: bool = vo.target_problem == 2 and vo.history.size() == 2 and ctl.speech.current == "ちかくで みてみるね"
	var states: Array[String] = []
	ctl.state_changed.connect(func(_p, c): states.append(c))
	_study_pump(game, 6.0)
	_ok(reset_turns and "HELP_LOCATING" in states and ctl.help_problem == 2,
		"study voice: another problem starts its own turns; a closer look starts the HELP for it", str(states))
	# not heard, and Space while listening
	ctl._set_state("STUDYING")
	ctl.speech.clear()
	ctl.handle_key(KEY_V)
	ctl.handle_key_release(KEY_V)
	hw._on_message({"type": "homework_heard_error", "request_id": str(sent[-1].request_id), "data": {"code": "not_heard",
		"message": "声が聞こえませんでした"}})
	var sorry: bool = ctl.speech.current.contains("きこえなかった") and vo.state == StudyVoice.IDLE
	ctl.speech.clear()
	ctl.handle_key(KEY_V)
	ctl.on_stop_key()
	var cancelled: bool = vo.state == StudyVoice.IDLE and sent[-1].type == "homework_listen_cancel"
	_ok(sorry and cancelled, "study voice: not heard says so; Space drops the listening", str([sorry, cancelled]))
	# through the game's own key handling: V down listens, V up ends it (the release reaches the study mode)
	ctl.speech.clear()
	game._unhandled_input(_key(KEY_V))
	var down := vo.state == StudyVoice.LISTENING
	var up_ev := _key(KEY_V)
	up_ev.pressed = false
	game._unhandled_input(up_ev)
	_ok(down and vo.state == StudyVoice.HEARING and sent[-1].type == "homework_listen_stop",
		"study voice: the game's key handling gives the talk key's press and release", vo.state)
	vo.cancel()
	# review on #235: a lost link or an answer that never comes does not leave the voice stuck
	ctl.speech.clear()
	vo.press()
	vo.release()
	hw.link_lost.emit()
	var after_lost: bool = vo.state == StudyVoice.IDLE and vo.note.contains("切れた")
	vo.press()
	vo.release()
	hw._on_message({"type": "homework_heard", "request_id": str(sent[-1].request_id), "data": {"text": "やあ"}})
	var waiting: bool = vo.state == StudyVoice.THINKING
	vo.tick(StudyVoice.WAIT_S + 1.0)
	_ok(after_lost and waiting and vo.state == StudyVoice.IDLE and ctl.speech.current.contains("こたえられない"),
		"study voice: a lost link or no answer in time frees the voice again", str([after_lost, waiting, vo.state]))
	ctl.speech.clear()
	ctl.stop()
	hw.link = real_link
	spy.free()
	remove_child(game)
	game.free()
	rs.clear_samples()


## A stand-in for the homework link (records what the study mode sends, sends nothing).
class _VoiceLinkSpy:
	extends UfoWebSocketClient
	var sent: Array

	func send_aux(msg: Dictionary) -> Error:
		sent.append(msg)
		return OK


## #237: the answer check's rules (StudyGrading) and its failures.
func _test_study_answer_check(rs: Node) -> void:
	var g := StudyGrading.new()
	g.reset([1, 2, 3])
	_ok(StudyGrading.classify("correct") == "correct" and StudyGrading.classify("incorrect") == "review"
		and StudyGrading.classify("partial") == "review" and StudyGrading.classify("unreadable") == "unclear"
		and StudyGrading.classify("blank") == "unclear" and StudyGrading.classify("correct", "partial") == "unclear"
		and StudyGrading.classify("") == "unclear",
		"answer check: right = correct, wrong or half = look again, unreadable / cut off / missing = unclear (never wrong)")
	var first := g.apply([{"number": 1, "answer_status": "correct", "student_answer": "12"},
		{"number": 2, "answer_status": "incorrect"}])
	var r1 := g.reward("ws")
	var again := g.apply([{"number": 1, "answer_status": "incorrect"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "correct"}])
	var r2 := g.reward("ws")
	var third := g.apply([{"number": 1, "answer_status": "correct"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "correct"}])
	_ok(first == [1, 2, 3] and g.verdicts[1] == "correct" and r1.confirmed_correct == 1 and r1.unclear == [3]
		and again == [2, 3] and r2.confirmed_correct == 3 and third.is_empty() and g.reward("ws").confirmed_correct == 3
		and not r2.has("answers") and not r2.has("student_answer") and g.answers[1] == "12",
		"answer check: a right problem stays right, a rescan shows only what changed, the reward never counts twice (and has no answers)",
		str([first, again, third, r2]))
	g.reset([1, 2, 3, 4])
	g.apply([{"number": 1, "answer_status": "correct"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "correct"}, {"number": 4, "answer_status": "correct"}])
	# #338: all right: the perfect bonus (+10 s) on top of the cap
	var capped := g.time_bonus_s() == 40 and g.perfect_bonus() == 10 and g.power_tickets() == 0
	g.checked = true
	g.used_help = true
	var r := g.reward("ws")
	g.reset([1, 2, 3, 4])
	g.apply([{"number": 1, "answer_status": "correct"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "correct"}, {"number": 4, "answer_status": "incorrect"}])
	var three_of_four := g.time_bonus_s() == 30 and g.perfect_bonus() == 0
	_ok(capped and three_of_four and r.power_tickets == 1 and r.time_bonus_s == 40 and r.perfect_bonus_s == 10 and r.perfect and r.used_help,
		"answer check: +10 s a right problem up to +30 s, all right +10 s more (#338), a ticket once all were checked; a HELP takes nothing away", str(r))
	g.reset([1, 2])
	g.apply([{"number": 1, "answer_status": "correct"}])
	_ok(g.fail_all() == [2] and g.verdicts[1] == "correct" and g.verdicts[2] == "unclear" and g.count("review") == 0,
		"answer check: a failed reading leaves only 'unclear', never a wrong one, and keeps what was right")

	# review on #241: the camera path keeps "cut off" (the watch's answers carry visible)
	g.reset([1, 2])
	g.apply([{"number": 1, "answer_status": "correct", "student_answer": "3", "visible": "partial"},
		{"number": 2, "answer_status": "incorrect", "student_answer": "4", "visible": "partial"}])
	_ok(g.verdicts[1] == "unclear" and g.verdicts[2] == "unclear" and g.time_bonus_s() == 0,
		"answer check: a cut-off problem read by the camera is never graded (no ○, no reward)", str(g.verdicts))
	# #237: the moments sound full: the game's sound files layered with the synthesised ones
	var snd := StudySounds.new()
	add_child(snd)
	snd.enabled = false
	snd.cue("correct")
	var layered: bool = snd.last_cue == "correct" and snd.last_played == "gem" and snd._files.has("star") \
		and snd._files.has("jackpot") and snd._streams.has("drum") and snd._streams.has("boom")
	for c in StudySounds.CUES:
		for k in StudySounds.CUES[c]:
			var got := snd.pick(str(k))
			layered = layered and (snd._files.has(got) or snd._streams.has(got))
	snd.music_play("study")  # tests never load this machine's music files: silence, no error
	var game_level := float(GameConfig.get_value("audio", "volume_db", -8.0)) + GameModeSounds.BGM_DB
	_ok(layered and snd.music_track == "" and snd.music_files == {"study": "study.mp3", "check": "study_check.mp3"}
		and is_equal_approx(snd.music_volume_db("study"), game_level - 9.0) and is_equal_approx(snd.music_volume_db("check"), game_level - 4.0),
		"answer check: every cue's sounds exist (files and synthesised); the music: study.mp3, then study_check.mp3 from the check (at the score game's level)", str(snd._files.keys()))
	snd.free()
	# the reading fails in the study mode: unclear, a hint to look again, and the story goes on
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = false
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.services.inject_fail = "grade"
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 30.0, func(): return ctl.state == "REVIEW_SUMMARY")
	var unclear_ok: bool = ctl.state == "REVIEW_SUMMARY" and ctl.grading.count("unclear") == 3 and ctl.grading.count("review") == 0 \
		and ctl.notice.contains("読めなかった")
	ctl.advance()  # go on: nothing right, but checked: the ticket, no time
	_study_pump(game, 20.0, func(): return ctl.state == "POWERUP_SELECT")
	var no_time: bool = int(ctl.reward.time_bonus_s) == 0 and int(ctl.reward.power_tickets) == 1 and ctl.reward.unclear == [1, 2, 3]
	# fingers pick nothing: the roulette does (by chance; any of the three)
	ctl.hand_tick("three", 1000.0)
	ctl.hand_tick("three", 1000.0 + ctl.hand_hold_ms + 10.0)
	var not_by_hand := ctl.selected_powerups.is_empty()
	_study_pump(game, 10.0, func(): return not ctl.selected_powerups.is_empty())
	_ok(unclear_ok and no_time and not_by_hand and ctl.selected_powerups.size() == 1
		and ctl.selected_powerups[0] in ["speed", "double", "multiball"],
		"answer check: a failed reading is 'unclear' (no verdict), the check goes on; the roulette picks a power",
		str([unclear_ok, no_time, ctl.reward, ctl.selected_powerups]))
	# F6 walks through every new state without stopping
	ctl.start()
	var seen: Array[String] = []
	ctl.state_changed.connect(func(_p, c): seen.append(c))
	for i in 20:
		if ctl.state == "GAME_READY_WITH_REWARD":
			break
		ctl.debug_skip()
		_study_pump(game, 0.2)
	var walked := true
	for st in ["ANSWER_CHECK_READY", "SHEET_SCANNING", "GRADING_QUESTION", "REWARD_CALCULATING", "REWARD_REVEAL",
			"POWERUP_SELECT", "GAME_READY_WITH_REWARD"]:
		walked = walked and st in seen
	_ok(walked and ctl.state == "GAME_READY_WITH_REWARD", "answer check: F6 skips through every state of the check and the reward", str(seen))
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = true
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## #237: the problems of a real print come from the reading (any number, any count).
func _test_study_real_print_problems(rs: Node) -> void:
	var t := StudyQuestionTracker.new()
	t.configure({"confirm_readings": 1, "complete_readings": 1})
	t.reset_numbers([], true)
	t.add_numbered([{"number": 5, "filled_prob": 0.05}, {"number": 3, "filled_prob": 0.95}, {"number": 4, "filled_prob": 0.5}], false, "", true)
	var grown := t.numbers == [3, 4, 5] and t.count == 3 and t.is_filled(3) and t.shown_state(4) == "writing"
	t.add_numbered([{"number": 3, "filled_prob": 0.95}, {"number": 4, "filled_prob": 0.95}], false, "", true)
	var kept := t.numbers == [3, 4, 5] and not t.complete  # 5 not seen this time: still there, not written
	t.add_numbered([{"number": 3, "filled_prob": 0.95}, {"number": 4, "filled_prob": 0.95}, {"number": 5, "filled_prob": 0.95}], false, "", true)
	var empty := StudyQuestionTracker.new()
	empty.reset_numbers([], true)
	empty.add_numbered([], false, "", true)
	_ok(grown and kept and t.complete and not empty.complete,
		"real print: the problems are the numbers read (3, 4, 5), a number once seen stays, complete when all are written",
		str([t.numbers, t.states, t.complete]))
	var g := StudyGrading.new()
	g.reset([3, 4])
	var shown := g.apply([{"number": 4, "answer_status": "correct"}, {"number": 6, "answer_status": "incorrect"}], true)
	_ok(g.numbers == [3, 4, 6] and shown == [3, 4, 6] and g.verdicts[3] == "unclear" and g.verdicts[6] == "review",
		"real print: the answer check takes in a problem first read then", str([g.numbers, g.verdicts]))

	# the study mode, camera + local: 5 problems read -> 5 chips; the check reads the cut-out frame once
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	var hw: HomeworkClient = sv.homework
	var hud: StudyHud = game.study_hud
	hw.sheet_settings_path = ""
	hw.study_local = true
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	hw.worksheet_id = str(ctl.current_worksheet().get("worksheet_id", ""))
	var qs: Array = []
	for n in [1, 2, 3, 4, 5]:
		qs.append({"number": n, "filled_prob": 0.05})
	sv.watching = true
	sv.seen = true
	sv._on_progress({"questions": qs, "held": false, "visible_prob": 1.0,
		"answers": [{"number": 1, "answer_status": "blank", "student_answer": "", "visible": "full"}]})
	hud.refresh()
	var five: bool = ctl.tracker.numbers == [1, 2, 3, 4, 5] and hud._count.text == "宿題 0 / 5 問"
	# Y on a real print: the problem the child seems stuck on (being written, else not written), never "3" by itself
	ctl.tracker.confirm_readings = 1
	ctl.tracker.add_numbered([{"number": 1, "filled_prob": 0.95}, {"number": 2, "filled_prob": 0.95},
		{"number": 3, "filled_prob": 0.95}, {"number": 4, "filled_prob": 0.45}], false, "", true)
	var stuck_writing := ctl.stuck_problem()
	ctl.tracker.add_numbered([{"number": 4, "filled_prob": 0.05}], false, "", true)
	var stuck_empty := ctl.stuck_problem()
	var all_written := StudyQuestionTracker.new()
	all_written.configure({"confirm_readings": 1})
	all_written.reset_numbers([], true)
	all_written.add_numbered([{"number": 1, "filled_prob": 0.95}], false, "", true)
	var real_tracker := ctl.tracker
	ctl.tracker = all_written
	ctl.request_help()
	var asked_which: bool = ctl.state == "STUDYING" and ctl.notice.contains("どの問題") and ctl.stuck_problem() == 0
	ctl.tracker = real_tracker
	_ok(stuck_writing == 4 and stuck_empty == 4 and asked_which,
		"real print: Y helps with the problem being written (else the first not written); all written: it asks which, no move",
		str([stuck_writing, stuck_empty, asked_which, ctl.state, ctl.notice]))
	ctl.debug_skip()  # to the answer check
	_study_pump(game, 10.0, func(): return ctl.state in ["SHEET_SCANNING", "GRADING_QUESTION"])
	# no backend in the test: the reader's answer arrives as sheet_read's ack
	sv._grade_rid = "g1"
	game.ws.ack.emit("g1", false, {"reason": "timeout"})  # the link's few seconds: still waiting
	var waiting: bool = sv._grade_rid == "g1"
	sv._on_graded_by_reader(true, {"problems": [
		{"number": 1, "answer_status": "correct", "student_answer": "4", "correct_answer": "4", "visible": "full"},
		{"number": 2, "answer_status": "incorrect", "student_answer": "7", "correct_answer": "9", "visible": "full"},
		{"number": 3, "answer_status": "correct", "student_answer": "5", "visible": "partial"},
		{"number": 4, "answer_status": "correct", "student_answer": "2", "visible": "full"},
		{"number": 5, "answer_status": "correct", "student_answer": "8", "visible": "full", "answer_box": [100, 800, 300, 900]}]})
	_study_pump(game, 30.0, func(): return ctl.state == "REVIEW_SUMMARY")
	hud.refresh()
	_ok(five and waiting and ctl.grading.numbers == [1, 2, 3, 4, 5] and ctl.grading.count("correct") == 3
		and ctl.grading.verdicts[3] == "unclear" and ctl.grading.verdicts[2] == "review" and hud.sheet.answer_marks.size() == 5
		and hud.sheet.mark_boxes.has(5)
		and not str(ctl.grading.answers).contains("9"),
		"real print: 5 problems read are 5 problems; the check reads them once and marks them where they are (the right answers never kept)",
		str([five, waiting, ctl.grading.numbers, ctl.grading.verdicts, ctl.state]))
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## #306: the answer check right after the print was found uses the reading that found it (the
## reader is not called twice for the same picture); a rescan, a changed picture or a reading
## without boxes reads again.
func _test_study_check_reuses_found_reading(rs: Node) -> void:
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv: StudyServices = ctl.services
	var hw: HomeworkClient = sv.homework
	hw.sheet_settings_path = ""
	hw.study_local = true
	hw.worksheet_id = "real"
	var pic := Image.create(40, 30, false, Image.FORMAT_RGB8)
	hw.sent_shown = pic
	hw.sheet_gate._sig = PackedFloat32Array([0.5, 0.5, 0.5])
	hw.sheet_gate.mark_sent()
	sv.watching = true
	sv.seen = true
	var answers := [{"number": 1, "answer_status": "correct", "student_answer": "4", "visible": "full", "answer_box": [100, 100, 300, 200]},
		{"number": 2, "answer_status": "incorrect", "student_answer": "7", "visible": "full", "answer_box": [100, 300, 300, 400]}]
	sv._on_progress({"questions": [], "held": false, "visible_prob": 1.0, "answers": answers})
	var ok_now := sv.reusable_reading()
	var got: Array = []  # appended to (a lambda captures the array, not the variable)
	var on_graded := func(probs: Array): got.append_array(probs)
	sv.graded.connect(on_graded)
	sv.grade(false, true)
	_study_pump(game, 3.0, func(): return not got.is_empty())
	var reused: bool = got.size() == 2 and sv.graded_image == pic and sv._grade_rid == "" and got[0].get("answer_box") == [100, 100, 300, 200]
	# the picture changed since (the sheet moved, a hand over it): read again
	hw.sheet_gate._sig = PackedFloat32Array([0.9, 0.1, 0.9])
	var changed := sv.reusable_reading()
	hw.sheet_gate._sig = PackedFloat32Array([0.5, 0.5, 0.5])
	# a newer frame on its way, or the reading without boxes: read again
	hw.sent_shown = Image.create(40, 30, false, Image.FORMAT_RGB8)
	var newer := sv.reusable_reading()
	hw.sent_shown = pic
	sv._on_progress({"questions": [], "held": false, "visible_prob": 1.0,
		"answers": [{"number": 1, "answer_status": "correct", "student_answer": "4", "visible": "full"}]})
	var no_boxes := sv.reusable_reading()
	# a rescan never takes the old reading (no reader here: the watch's answers as the fallback)
	sv._on_progress({"questions": [], "held": false, "visible_prob": 1.0, "answers": answers})
	got.clear()
	sv.graded_image = null
	sv.grade(true, true)
	_study_pump(game, 3.0, func(): return not got.is_empty())
	# no reader here: the rescan falls back to the watch's reading, and its marks go with its own picture
	var rescan_reads: bool = sv.graded_image == pic and not got.is_empty()
	# review on #307: the reader refused after a newer frame was taken: the watch's reading again
	# with its own picture (never its boxes on the newer one); with no picture, no boxes
	sv.graded_image = Image.create(40, 30, false, Image.FORMAT_RGB8)
	got.clear()
	sv._on_graded_by_reader(false, {"reason": "test"})
	var fallback_pic: bool = sv.graded_image == pic and got.size() == 2 and got[0].has("answer_box")
	sv.last_answers_image = null
	got.clear()
	sv._on_graded_by_reader(false, {"reason": "test"})
	var no_pic_no_boxes: bool = sv.graded_image == null and got.size() == 2 and not got[0].has("answer_box")
	sv.graded.disconnect(on_graded)
	ctl.stop()
	_ok(ok_now == "" and reused and changed == "changed" and newer == "newer_frame" and no_boxes == "no_boxes" and rescan_reads and fallback_pic and no_pic_no_boxes,
		"study #306: the check right after the print is found takes the reading that found it (once, its picture and boxes); a changed picture, a newer frame, no boxes or a rescan read again; the watch's reading as a fallback keeps its own picture",
		str([ok_now, reused, changed, newer, no_boxes, rescan_reads, fallback_pic, no_pic_no_boxes]))
	remove_child(game)
	game.free()
	rs.clear_samples()


## #237: the power items in dots, and the sounds added for the answer check.
func _test_study_power_items(rs: Node) -> void:
	var ok := true
	for kind in ["speed", "double", "multiball", "clock", "ticket", "magnifier"]:
		var rows: Array = PowerItemArt.SPRITES[kind]
		ok = ok and rows.size() == PowerItemArt.SIZE
		for row in rows:
			ok = ok and str(row).length() == PowerItemArt.SIZE
			for ch in str(row):
				ok = ok and (ch == "." or PowerItemArt.PALETTE.has(ch))
	var all_have := true
	for pw in StudyModeController.POWERUPS:
		all_have = all_have and PowerItemArt.SPRITES.has(pw[0])
	_ok(ok and all_have, "power items: each power-up is a 16 x 16 pixel-art item of known colours")
	var snd := StudySounds.new()
	add_child(snd)
	snd.enabled = false
	var don_or_stand_in := snd.pick("don|boom")
	var jan_or_stand_in := snd.pick("jan|fanfare")
	_ok((don_or_stand_in == "don") == snd._files.has("don") and (jan_or_stand_in == "jan") == snd._files.has("jan")
		and snd.pick("nothing|tick") == "tick" and "don|boom" in StudySounds.CUES.correct and "jan|fanfare" in StudySounds.CUES.reward,
		"answer check: don / pico at a right answer and jan as the fanfare when their files are there (else the stand-ins)",
		str([don_or_stand_in, jan_or_stand_in, snd._files.keys()]))
	snd.free()


## #237: the warm pixel-art room, the "put it here" guide, the found show, the voice's "ユーフォー".
func _test_study_scenery(rs: Node) -> void:
	var img := StudyBackdrop.paint()
	var top := img.get_pixel(StudyBackdrop.W / 2, 2)
	var desk := img.get_pixel(StudyBackdrop.W / 2, StudyBackdrop.H - 4)
	_ok(img.get_size() == Vector2i(StudyBackdrop.W, StudyBackdrop.H) and top.r > top.b and top.g > 0.8 and desk.r > desk.b,
		"study scenery: the background is a warm pixel-art scene (light yellow sky, a wooden desk)", str([top, desk]))
	_ok(StudyServices.spoken("UFOくん、こんにちは") == "ユーフォーくん、こんにちは" and StudyServices.spoken("ＵＦＯ") == "ユーフォー",
		"study scenery: the voice says ユーフォー (the bubble keeps UFOくん)")
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hud: StudyHud = game.study_hud
	ctl.services.worksheet_wait_s = 999.0
	game.gesture_hud.hidden_by_study = false
	ctl.start()
	hud.refresh()
	var intro_no_sheet: bool = ctl.state == "INTRO" and not hud.sheet.visible  # no sheet before it is asked for
	ctl.services.set_mode("camera")
	ctl.state = "STUDYING"
	hud.refresh()
	var camera_no_drawing: bool = not hud.sheet.visible  # no camera here: never the sample sheet's drawing
	ctl.services.set_mode("simulated")
	ctl.state = "INTRO"
	var backdrop: Node2D = game.get_node("StudyBackdrop")
	ctl.debug_skip()  # waiting for the sheet
	hud.refresh()
	var waiting: bool = ctl.state == "WAITING_FOR_WORKSHEET" and hud.sheet.guide and backdrop.visible \
		and game.gesture_hud.hidden_by_study
	ctl.services.mark_seen()
	hud.refresh()
	var found_ok: bool = ctl.state == "STUDYING" and not hud.sheet.guide and hud._pop.text == "みつけた！" \
		and ctl.sounds.last_cue == "found"
	ctl.stop()
	_ok(intro_no_sheet and camera_no_drawing, "study scenery: no sheet at the start; the camera mode never draws the sample sheet",
		str([intro_no_sheet, camera_no_drawing]))
	_ok(waiting and found_ok and not backdrop.visible and not game.gesture_hud.hidden_by_study,
		"study scenery: 'ここへおいてね！' until the sheet is found, then みつけた！; the warm room and no gesture camera only in the study mode",
		str([waiting, found_ok, backdrop.visible]))
	remove_child(game)
	game.free()
	rs.clear_samples()


## #287: a real print read by the local server is not the sample sheet: UFOくん never says the sample's
## hints ("2ばんは、7のだんで 56 に なるのは？" on a print where 2 is another problem), and the
## fallback, the close-up's text and a hand's offer do not come from it either.
func _test_study_real_print_not_the_sample(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hw: HomeworkClient = ctl.services.homework
	if hw == null:
		_ok(false, "study real print: the study mode has a HomeworkClient")
		remove_child(game)
		game.free()
		return
	ctl.worksheet = ctl.catalog.for_grade("elem_3")
	ctl.services.worksheet = ctl.worksheet
	var sample_two := WorksheetCatalog.problem(ctl.worksheet, 2)
	var sample_hint := str((sample_two.get("hints", [""]) as Array)[0])
	# the mock demo (the sample sheet on the desk): its own hints, as before
	ctl.services.set_mode("simulated")
	var mock_ok := ctl.review_hint(2) == sample_hint and not ctl.services.sheet_problem(2).is_empty()
	# the camera read by the local server: a real print
	ctl.services.set_mode("camera")
	hw.study_local = true
	hw.worksheet_id = str(ctl.worksheet.get("worksheet_id", ""))
	var real := ctl.services.reads_whole_sheet()
	var hint := ctl.review_hint(2)
	var fb := StudyServices.fallback_explanation(ctl.services.sheet_problem(2), 2)
	var fb_text := str(fb.get("explanation", "")) + str(fb.get("recognized_problem", "")) + " ".join(fb.get("speech_lines", []))
	var none_of_it := not hint.contains("56") and hint != sample_hint and ctl.services.sheet_problem(2).is_empty() \
		and not fb_text.contains("56") and str(fb.recognized_problem) == "" and not (fb.speech_lines as Array).is_empty()
	# a hand's offer: only the problems read on the print (the sample has 1..3, this print 5 only)
	ctl.tracker.reset_numbers([5], true)
	ctl.offer_problem = 0
	ctl.offer_help(2, 0.0)
	var offers_sample_only := ctl.offer_problem == 2
	ctl.offer_help(5, 0.0)
	var offers_print := ctl.offer_problem == 5
	# the close-up's text
	ctl.help_problem = 2
	game.study_hud.refresh()
	var scope_text := str(game.study_hud.scope.problem.get("prompt", ""))
	hw.study_local = false
	hw.worksheet_id = ""
	ctl.stop()
	_ok(mock_ok and real and none_of_it and not offers_sample_only and offers_print and scope_text == "",
		"study real print: no sample sheet's hint, fallback, close-up text or offer on a print read by the local server",
		str([mock_ok, real, hint, none_of_it, offers_sample_only, offers_print, scope_text]))
## #285: the sheet cannot be read (a wrong certificate, no AI, ...): the reason on the "ここへおいてね！"
## screen, not a guide waiting for nothing; gone once a frame is read.
func _test_study_reading_error_shown(rs: Node) -> void:
	var long := StudyWorksheetView.guide_error_text("x".repeat(400))
	_ok(long.begins_with("プリントを よみとれないよ") and long.length() < 240 and long.ends_with("…"),
		"study reading error: a line for the child, then the reason for the adult, cut short", str(long.length()))
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hud: StudyHud = game.study_hud
	var hw: HomeworkClient = ctl.services.homework
	if hw == null:
		_ok(false, "study reading error: the study mode has a HomeworkClient")
		remove_child(game)
		game.free()
		return
	ctl.services.set_mode("camera")
	ctl.services.watching = true
	ctl.state = "WAITING_FOR_WORKSHEET"
	hud.refresh()
	var clean: bool = hud.sheet.guide and hud.sheet.guide_error == ""
	var why := "プリントの読み取り: 証明書を確かめられません（テスト）"
	hw._on_message({"type": "homework_error", "request_id": "homework-1", "data": {"code": "network", "message": why}})
	hud.refresh()
	var shown: bool = hud.sheet.guide_error == why and ctl.services.watch_problem() == why
	ctl.services.set_mode("simulated")  # the mock demo has no camera watch: nothing to show
	hud.refresh()
	var not_simulated: bool = hud.sheet.guide_error == ""
	ctl.services.set_mode("camera")
	hw._on_message({"type": "homework_progress", "request_id": "homework-1",
		"data": {"progress_pct": 0.0, "smoothed_pct": 0.0, "held": true, "held_reason": "not_visible", "visible_prob": 0.0}})
	hud.refresh()
	var cleared: bool = hud.sheet.guide_error == "" and hw.last_error == ""
	ctl.services.watching = false
	ctl.stop()
	_ok(clean and shown and not_simulated and cleared,
		"study reading error: the watch's error under 'ここへおいてね！' (camera mode), gone after a frame is read",
		str([clean, shown, not_simulated, cleared, hud.sheet.guide_error]))
	remove_child(game)
	game.free()
	rs.clear_samples()


## #237: the reward told line by line, its items got one after another, then the score game by itself.
func _test_study_reward_show(rs: Node) -> void:
	var r := {"question_count": 4, "confirmed_correct": 1, "needs_review": [2, 3], "unclear": [4], "time_bonus_s": 10,
		"power_tickets": 1, "selected_powerups": []}
	var text := StudyHud.reward_text("REWARD_REVEAL", r)
	_ok(text == "4もん かくにん\n1もん せいかい　3もん みなおし\nTIME +10\nPOWER TICKET ×1",
		"study reward: one thing a line (the counts, the TIME, the ticket)", text)
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hud: StudyHud = game.study_hud
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = false
	ctl.services.demo_results = ["correct", "correct", "correct"]
	ctl.roulette_force = "speed"
	ctl.start()
	for i in 6:
		if ctl.state == "REWARD_REVEAL":
			break
		ctl.debug_skip()
		_study_pump(game, 0.3)
	_study_pump(game, 20.0, func(): return ctl.state == "REWARD_REVEAL")
	var kinds: Array = []
	_study_pump(game, 8.0, func():
		hud._process(0.1)  # the HUD's own clock (the pump drives the study mode's)
		if hud._get_t >= 0.0 and (kinds.is_empty() or kinds[-1] != hud._get_kind):
			kinds.append(hud._get_kind)
		return ctl.state != "REWARD_REVEAL")
	_ok(kinds == ["clock", "ticket"], "study reward: the clock (TIME) is got, then the ticket", str(kinds))
	_study_pump(game, 30.0, func(): return ctl.state == "GAME_READY_WITH_REWARD")
	hud.refresh()
	var counting: bool = hud._play.text.contains("5") or hud._play.text.contains("4")
	_study_pump(game, 7.0, func(): return ctl.state == "OFF")
	var to_score: bool = ctl.state == "OFF" and ctl.last_reward.selected_powerups == ["speed"] \
		and (game.game_mode == null or game.game_mode.active())
	_ok(counting and to_score, "study reward: 'ゲームで遊ぶ' counts down 5 s, then the score game's title by itself",
		str([counting, hud._play.text, ctl.state, game.game_mode != null and game.game_mode.active()]))
	if game.game_mode != null and game.game_mode.active():
		game.game_mode.close()
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = true
	remove_child(game)
	game.free()
	rs.clear_samples()


## #237: a problem named by voice ("1ばんが わからない") is looked at (the usual HELP), not only talked about.
func _test_study_voice_goes_to_look(rs: Node) -> void:
	var cases := {"1ばんが わからない": 1, "３番おしえて": 3, "(2) がむずかしい": 2, "④": 4, "にばん みて": 2,
		"三番のこたえ": 3, "もんだい 5 が": 5, "ヒントちょうだい": 0, "ごはんたべた": 0}
	var bad := []
	for text in cases:
		if StudyVoice.number_in(text) != int(cases[text]):
			bad.append([text, StudyVoice.number_in(text)])
	_ok(bad.is_empty(), "study voice: the problem a child names is read (1ばん, ３番, (2), ④, にばん, 三番, もんだい 5)", str(bad))
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var vo := ctl.voice
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.speech.clear()
	var states: Array[String] = []
	ctl.state_changed.connect(func(_p, c): states.append(c))
	vo.state = StudyVoice.HEARING
	vo._rid = "sm-lst-9"
	vo._on_aux({"type": "homework_heard", "request_id": "sm-lst-9", "data": {"text": "1ばんが わからない"}})
	_ok("HELP_LOCATING" in states and ctl.help_problem == 1 and vo.state == StudyVoice.IDLE and vo.target_problem == 1,
		"study voice: '1ばんが わからない' goes to look at problem 1 (locate, the arm's camera, the explanation)", str([states, ctl.help_problem]))
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()

## #281: the print found goes straight to the answer check; the voice dialogue needs the
## dialogue mode, entered with a thumbs-up held 3 s before the print is found or at the summary.
func _test_study_check_on_found_and_dialog(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	ctl.check_on_found = true
	ctl.dialog_needs_thumb = true
	ctl.start()
	_study_pump(game, 15.0, func(): return ctl.state == "WAITING_FOR_WORKSHEET")
	var waiting_blocked: bool = ctl.voice.blocker().contains("いいね") \
		and StudyHud.key_help("WAITING_FOR_WORKSHEET", "simulated", "off").contains("👍")
	_study_pump(game, 10.0, func(): return ctl.state not in ["WAITING_FOR_WORKSHEET"])
	var to_check: bool = ctl.state in StudyModeController.CHECK_STATES and ctl.completion_fired and ctl.study_started_ms >= 0
	ctl.stop()
	# a thumbs-up held 3 s while waiting: the dialogue mode, then the homework time as before
	ctl.start()
	_study_pump(game, 15.0, func(): return ctl.state == "WAITING_FOR_WORKSHEET")
	var t0 := 100000.0
	ctl.hand_tick("thumb", t0)
	ctl.hand_tick("thumb", t0 + 1500.0)
	var half: bool = not ctl.dialog_mode and ctl.dialog_progress > 0.4 and ctl.dialog_progress < 0.6
	ctl.hand_tick("open", t0 + 1600.0)  # let go: from the start again
	ctl.hand_tick("thumb", t0 + 1700.0)
	ctl.hand_tick("thumb", t0 + 4600.0)
	var not_yet: bool = not ctl.dialog_mode
	ctl.hand_tick("thumb", t0 + 4800.0)
	var on: bool = ctl.dialog_mode and ctl.voice.blocker() != "" and not ctl.voice.blocker().contains("いいね")
	_study_pump(game, 10.0, func(): return ctl.state != "WAITING_FOR_WORKSHEET")
	var studying: bool = ctl.state == "STUDYING" and not ctl.completion_fired
	# not in the middle of the check
	ctl.stop()
	ctl.state = "GRADING_QUESTION"
	ctl.dialog_mode = false
	ctl.hand_tick("thumb", t0)
	ctl.hand_tick("thumb", t0 + 5000.0)
	var not_in_grading: bool = not ctl.dialog_mode
	# at the summary: on, and talking is allowed there
	ctl.state = "REVIEW_SUMMARY"
	ctl.hand_tick("thumb", t0 + 6000.0)
	ctl.hand_tick("thumb", t0 + 9100.0)
	var at_summary: bool = ctl.dialog_mode and ctl.voice.in_talk_state()
	# review on #282: a problem named at the summary is not the arm's HELP (that runs only in
	# the homework time): the summary stays
	ctl.voice._ask("1ばんが わからない")
	at_summary = at_summary and ctl.state == "REVIEW_SUMMARY" and ctl.voice.target_problem != 1
	# review on #282: nothing read on the print found: the summary (R reads again), no reward
	ctl.state = "GRADING_QUESTION"
	ctl.grading.reset([])
	ctl.reward = {}
	ctl._summary()
	var unread: bool = ctl.state == "REVIEW_SUMMARY" and ctl.reward.is_empty() and not ctl.grading.checked
	at_summary = at_summary and unread
	ctl.state = "OFF"
	_ok(waiting_blocked and to_check and half and not_yet and on and studying and not_in_grading and at_summary,
		"study #281: the print found goes straight to the answer check; talking needs the dialogue mode, a thumbs-up held 3 s while waiting for the print (then the homework time as before) or at the check's summary, never in the middle of the check",
		"%s %s %s %s %s %s %s %s" % [waiting_blocked, to_check, half, not_yet, on, studying, not_in_grading, at_summary])
	_gm_free(game, rs)

## #333: the summary's box at the top, by hand: a thumbs-up held 1 s reads the sheet again (R),
## an open hand held 1 s goes on (Enter); shorter holds do nothing, a held shape never repeats,
## the thumb starts nothing else (the dialogue mode, the help offer); "ここへおいてね！" again.
func _test_study_review_box_by_hand(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	var hud: StudyHud = game.study_hud
	ctl.dialog_needs_thumb = true  # the 3 s thumbs-up of #281 must not start as well
	ctl.start()
	var summary := func() -> void:
		ctl.state = "GRADING_QUESTION"
		ctl.grading.reset([])
		ctl.reward = {}
		ctl._summary()
		hud.refresh()
	summary.call()
	var box_up: bool = ctl.state == "REVIEW_SUMMARY" and ctl.review_waiting() and hud._review.visible \
		and not hud._adult.visible and not ctl.adult_prompt.contains("R ") and not ctl.adult_prompt.contains("Enter")
	# at the top: under the title, above the sheet (the camera's picture)
	var top: bool = hud._review.position.y < 140.0 and hud._review.position.y + hud._review.size.y <= hud.sheet.position.y \
		and hud._review.position.x >= 0.0 and hud._review.position.x + hud._review.size.x <= 720.0
	# "ここへおいてね！" while the rewritten sheet is awaited (as for the first read), gone while read
	var guide_at_summary: bool = hud.sheet.guide and hud.sheet.visible and StudyHud.guide_shown("WAITING_FOR_WORKSHEET") \
		and not StudyHud.guide_shown("RESCAN") and not StudyHud.guide_shown("GRADING_QUESTION") \
		and not StudyHud.guide_shown("STUDYING")
	# a short thumbs-up: nothing; the gauge fills while held
	var t0 := 200000.0
	ctl.hand_tick("thumb", t0)
	ctl.hand_tick("thumb", t0 + 500.0)
	hud.refresh()
	var half: bool = ctl.review_pose == "thumb" and ctl.review_progress > 0.4 and ctl.review_progress < 0.6
	ctl.hand_tick("", t0 + 600.0)  # let go before 1 s
	var short_none: bool = ctl.state == "REVIEW_SUMMARY" and ctl.review_progress == 0.0 and not ctl.dialog_mode
	ctl.hand_tick("open", t0 + 700.0)
	ctl.hand_tick("open", t0 + 1500.0)
	var short_open: bool = ctl.state == "REVIEW_SUMMARY" and ctl.review_waiting()
	ctl.hand_tick("", t0 + 1600.0)
	# thumbs-up held 1 s: read again (RESCAN), nothing else (no dialogue mode, no help offer)
	ctl.hand_tick("thumb", t0 + 2000.0)
	ctl.hand_tick("thumb", t0 + 3000.0)
	var reread: bool = ctl.state == "RESCAN" and not ctl.review_waiting() and not ctl.dialog_mode \
		and ctl.offer_problem == 0 and ctl.adult_prompt == ""
	hud.refresh()
	var guide_gone: bool = not hud.sheet.guide and not hud._review.visible
	# still held when the box comes again: it does not fire until the hand changes
	ctl.hand_tick("thumb", t0 + 3100.0)
	summary.call()
	ctl.hand_tick("thumb", t0 + 3200.0)
	ctl.hand_tick("thumb", t0 + 6500.0)
	var no_repeat: bool = ctl.state == "REVIEW_SUMMARY" and ctl.review_waiting() and ctl.review_progress == 0.0 and not ctl.dialog_mode
	ctl.hand_tick("", t0 + 6600.0)
	ctl.hand_tick("thumb", t0 + 6700.0)
	ctl.hand_tick("thumb", t0 + 7750.0)
	var again: bool = ctl.state == "RESCAN"
	# an open hand held 1 s: on (as Enter: the reward)
	summary.call()
	ctl.hand_tick("", t0 + 8000.0)
	ctl.hand_tick("open", t0 + 8100.0)
	ctl.hand_tick("open", t0 + 9150.0)
	var next_ok: bool = ctl.state == "REWARD_CALCULATING" and not ctl.review_waiting()
	ctl.hand_tick("open", t0 + 9300.0)
	var stays: bool = ctl.state == "REWARD_CALCULATING"
	# the keys still work (the staff): R reads again, Enter goes on
	ctl.stop()
	ctl.start()
	summary.call()
	ctl.handle_key(KEY_R)
	var key_r: bool = ctl.state == "RESCAN"
	summary.call()
	ctl.handle_key(KEY_ENTER)
	var key_enter: bool = ctl.state == "REWARD_CALCULATING"
	# the summary's key line: no "👍 3びょう おはなし" there any more (the thumb reads again)
	var keys_ok: bool = not StudyHud.key_help("REVIEW_SUMMARY", "camera", "off").contains("👍") \
		and StudyHud.key_help("REVIEW_SUMMARY", "camera", "off").contains("R もう一度読む")
	ctl.stop()
	_ok(box_up and top and guide_at_summary,
		"study #333: the summary's box is at the top (above the sheet, not the old box at the bottom) and shows no keys; 「ここへおいてね！」 shows while the rewritten sheet is awaited",
		"%s %s %s" % [box_up, top, guide_at_summary])
	_ok(half and short_none and short_open and reread and guide_gone,
		"study #333: a thumbs-up held 1 s reads again (as R; no dialogue mode, no help offer), shorter holds of either hand do nothing, the mark goes while it is read",
		"%s %s %s %s %s" % [half, short_none, short_open, reread, guide_gone])
	_ok(no_repeat and again and next_ok and stays and key_r and key_enter and keys_ok,
		"study #333: a shape held on does not fire again until the hand changes; an open hand held 1 s goes on (as Enter); R / Enter still work",
		"%s %s %s %s %s %s %s" % [no_repeat, again, next_ok, stays, key_r, key_enter, keys_ok])
	_gm_free(game, rs)


## #338: after the check UFOくん says one line by the result and goes on to the reward by itself;
## the review (見直し) only when the settings screen's 「見直しを有効にする」 is on.
func _test_study_result_lines(rs: Node) -> void:
	# which line: "wrong" is only review (incorrect / half); unclear is never counted as wrong
	var g := StudyGrading.new()
	var kind_of := func(statuses: Array) -> String:
		g.reset(range(1, statuses.size() + 1))
		var ps: Array = []
		for i in statuses.size():
			ps.append({"number": i + 1, "answer_status": statuses[i]})
		g.apply(ps)
		return g.result_kind()
	var kinds := [kind_of.call(["correct", "correct", "correct"]), kind_of.call(["incorrect", "incorrect", "partial"]),
		kind_of.call(["incorrect", "unreadable", "unreadable"]), kind_of.call(["correct", "incorrect", "correct"]),
		kind_of.call(["correct", "unreadable", "correct"]), kind_of.call(["unreadable", "unreadable"]), kind_of.call([])]
	_ok(kinds == ["perfect", "all_review", "all_review", "some_review", "unclear", "unclear", ""],
		"result line: all right = perfect; none right = all_review; some = some_review; only unreadable misses = unclear (never 'wrong')",
		str(kinds))
	# the reward matches the words: all wrong still gets an item (the ticket), all right gets more
	g.reset([1, 2, 3])
	g.apply([{"number": 1, "answer_status": "incorrect"}, {"number": 2, "answer_status": "incorrect"},
		{"number": 3, "answer_status": "incorrect"}])
	g.checked = true
	var none_right := g.reward("ws")
	g.reset([1, 2, 3])
	g.apply([{"number": 1, "answer_status": "correct"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "incorrect"}])
	g.checked = true
	var some_right := g.reward("ws")
	g.reset([1, 2, 3])
	g.apply([{"number": 1, "answer_status": "correct"}, {"number": 2, "answer_status": "correct"},
		{"number": 3, "answer_status": "correct"}])
	g.checked = true
	var all_right := g.reward("ws")
	_ok(int(none_right.power_tickets) == 1 and int(none_right.time_bonus_s) == 0
		and int(all_right.time_bonus_s) == 40 and int(all_right.perfect_bonus_s) == 10
		and int(all_right.time_bonus_s) > int(some_right.time_bonus_s) + 10 and int(all_right.power_tickets) == 1,
		"result line: all wrong still gets an item (a power ticket); all right gets the perfect bonus (+10 s) on top",
		str([none_right, some_right, all_right]))

	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = false
	var said: Array = []
	ctl.speech.line_started.connect(func(text, _f): said.append([text, ctl.state]))
	var states: Array = []
	ctl.state_changed.connect(func(_p, c): states.append(c))
	var run := func(results: Array) -> void:
		ctl.services.demo_results = results
		ctl.start()
		ctl.debug_skip()
		ctl.debug_skip()
		ctl.tracker.confirm_complete()
		ctl._check_complete()
		said.clear()
		states.clear()
		_study_pump(game, 60.0, func(): return ctl.state in ["REWARD_REVEAL", "REVIEW_SUMMARY", "HINT_ASK"])
	# off (the default of the config): each result says its line in REWARD_CALCULATING, then the reward
	ctl.review_enabled = bool(GameConfig.base_value("study_mode.answer_check.review_enabled"))
	var default_off := not ctl.review_enabled
	var cases := [["all_review", ["incorrect", "incorrect", "incorrect"]], ["perfect", ["correct", "correct", "correct"]],
		["some_review", ["correct", "incorrect", "correct"]]]
	for c in cases:
		run.call(c[1])
		var line: String = StudyModeController.RESULT_LINES[c[0]].text
		var said_it := false
		for s in said:
			said_it = said_it or (s[0] == line and s[1] == "REWARD_CALCULATING")
		var no_review := not states.has("REVIEW_SUMMARY") and not states.has("HINT_ASK") and not states.has("RESCAN")
		_ok(ctl.state == "REWARD_REVEAL" and ctl.result_kind == c[0] and said_it and no_review
			and int(ctl.reward.power_tickets) >= 1 and ctl.adult_prompt == "",
			"result line (見直し off): %s says its line and goes on to the reward by itself, no review" % c[0],
			str([ctl.state, ctl.result_kind, said, states]))
	var lines_ok: bool = StudyModeController.RESULT_LINES.perfect.text == "すごい！ よく がんばったね。ごほうび たくさん おまけ しちゃうね！" \
		and StudyModeController.RESULT_LINES.all_review.text.begins_with("ちょっと ぼくの さいてん、まちがえちゃった かもしれない。") \
		and StudyModeController.RESULT_LINES.some_review.text.begins_with("うーん、ぼくの さいてん、まちがえちゃった かも。") \
		and not StudyModeController.RESULT_LINES.unclear.text.contains("まちが")
	_ok(default_off and lines_ok, "result line: 見直し is off by default; the unclear line never says まちがい", str(default_off))
	# the voice never comes: the line ends at result_line_max_s at most, the reward follows
	ctl.result_line_max_s = 2.0
	ctl.services.demo_results = ["correct", "incorrect", "correct"]
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 30.0, func(): return ctl.state == "GRADING_QUESTION")
	ctl.speech.voice_on = true  # from the verdicts on, every line waits 100 s for a voice
	ctl.speech.voice_wait_s = 100.0
	var real_request: Callable = ctl.speech.voice_request
	ctl.speech.voice_request = func(_t): return "never"
	_study_pump(game, 60.0, func(): return ctl.state == "REWARD_CALCULATING")
	var calculating := ctl.state == "REWARD_CALCULATING" and ctl.speech.busy()
	_study_pump(game, 1.5)
	var still := ctl.state == "REWARD_CALCULATING"
	_study_pump(game, 1.0)
	_ok(calculating and still and ctl.state == "REWARD_REVEAL",
		"result line: the voice never comes back: the reward follows after result_line_max_s (never waits on the voice)",
		str([calculating, still, ctl.state]))
	ctl.speech.voice_on = false
	ctl.speech.voice_wait_s = 3.0
	ctl.speech.voice_request = real_request
	ctl.result_line_max_s = 15.0
	# on: the summary and the finger hint as before; the line when it goes on (Enter) to the reward
	ctl.review_enabled = true
	run.call(["correct", "incorrect", "correct"])
	var reviewed: bool = states.has("REVIEW_SUMMARY") and ctl.state in ["REVIEW_SUMMARY", "HINT_ASK"]
	_study_pump(game, 30.0, func(): return ctl.state == "HINT_ASK")
	var hint_asked := ctl.state == "HINT_ASK"
	var line_before := false
	for s in said:
		line_before = line_before or s[0] == StudyModeController.RESULT_LINES.some_review.text
	ctl.handle_key(KEY_ENTER)  # つぎへ
	var calc := ctl.state == "REWARD_CALCULATING" and ctl.speech.current == StudyModeController.RESULT_LINES.some_review.text
	_study_pump(game, 30.0, func(): return ctl.state == "REWARD_REVEAL")
	_ok(reviewed and hint_asked and not line_before and calc and ctl.state == "REWARD_REVEAL" and ctl.result_kind == "some_review",
		"result line (見直し on): the summary and the finger hint as before; the line is said when it goes on to the reward",
		str([reviewed, hint_asked, line_before, calc, ctl.state, states]))
	ctl.stop()
	# the settings screen's switch: saved to local_settings.json, applied on 保存, read back
	var real_path := GameConfig.local_path
	var path := "user://test_local_settings_review.json"
	GameConfig.local_path = path
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var st: SettingsScreen = game.settings
	var item: Dictionary = GameConfig.schema_items(GameConfig.schema).get("study_mode.answer_check.review_enabled", {})
	var in_schema: bool = item.get("type") == "bool" and item.get("label") == "見直しを有効にする" and item.get("apply") == "now"
	ctl.review_enabled = false
	game.show_title()
	game.open_settings()
	st.set_form_value("study_mode.answer_check.review_enabled", true)
	var err := st.save()
	var saved = GameConfig.read_json(path)
	var applied := ctl.review_enabled
	GameConfig.load_local()
	var read_back: bool = GameConfig.local == {"study_mode.answer_check.review_enabled": true}
	game.open_settings()
	var shown: bool = st.form_value("study_mode.answer_check.review_enabled") == true
	st.reset_defaults()
	st.save()
	_ok(in_schema and err == "" and saved == {"study_mode": {"answer_check": {"review_enabled": true}}} and applied and read_back
		and shown and not ctl.review_enabled and GameConfig.read_json(path) == {},
		"result line: 「見直しを有効にする」 in the settings saves, applies on 保存, reads back and goes back to off",
		str([in_schema, err, saved, applied, read_back, shown, ctl.review_enabled]))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameConfig.local_path = real_path
	GameConfig.load_local()
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = true
	remove_child(game)
	game.free()
	rs.clear_samples()
