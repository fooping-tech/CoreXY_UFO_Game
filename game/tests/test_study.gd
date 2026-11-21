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
	ctl.services.inject_navigate = [{"kind": "move"}]
	ctl.request_help()
	_study_pump(game, 60.0, func(): return ctl.state == "STUDYING")
	_ok(ctl.nav_tries == 0 and str(ctl.explanation.get("source", "")) == "demo",
		"study: without d_mm (arm camera not calibrated) the arm does not look again", str(ctl.nav_tries))
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
	_study_pump(game, 30.0, func(): return ctl.state == "GAME_UNLOCKED")
	game.study_hud.refresh()
	_ok(ctl.state == "GAME_UNLOCKED" and not "CLEANUP" in seen and not ctl.services.motion_active()
		and game.study_hud._check_rows[2][1].text.contains("今はなし") and not game.study_hud._sub_banner.text.contains("お片付け"),
		"study: with the tidy-up off the game unlocks after the celebration, no arm motion", str(seen))
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
	var gate_ok: bool = game.gesture_gate().begins_with("勉強モード")
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
	ctl.handle_key(KEY_V)
	var listening: bool = vo.state == StudyVoice.LISTENING and sent.size() == 1 and sent[0].type == "homework_listen_start"
	ctl.handle_key_release(KEY_V)
	var stop_rid := str(sent[-1].get("request_id", ""))
	var hearing: bool = vo.state == StudyVoice.HEARING and sent[-1].type == "homework_listen_stop"
	hw._on_message({"type": "homework_heard", "request_id": stop_rid, "data": {"text": "3ばんが わからない"}})
	var talk: Dictionary = sent[-1]
	var asked: bool = talk.type == "homework_talk" and talk.data.text == "3ばんが わからない" and int(talk.data.target_problem) == 0 \
		and str(talk.data.image_jpeg_base64) != "" and vo.state == StudyVoice.THINKING
	hud.refresh()
	var shown: bool = hud._voice_bar.visible and hud._voice_text.text.contains("「3ばんが わからない」") \
		and hud._voice_text.text.contains("かんがえちゅう")
	_ok(listening and hearing and asked and shown,
		"study voice: held V listens, the release writes it down, the words and the worksheet go to the tutor",
		str([listening, hearing, asked, shown, hud._voice_text.text]))
	# the answer is spoken; the dialogue keeps its problem and turns
	hw._on_message({"type": "homework_talk_result", "request_id": str(talk.request_id), "data": {
		"message": "5こから2こ とると いくつかな？", "speech_lines": ["5こから2こ とると いくつかな？"], "action": "give_hint",
		"target_problem": 3, "hint_level": 1, "need_recapture": false, "ufo_face": "normal"}})
	var spoken: bool = ctl.speech.current.contains("5こから2こ") and vo.state == StudyVoice.IDLE and vo.target_problem == 3 \
		and vo.history == [{"hint_level": 1, "message": "5こから2こ とると いくつかな？"}]
	var busy_why := vo.blocker()
	ctl.speech.clear()
	ctl.handle_key(KEY_V)
	ctl.handle_key_release(KEY_V)
	hw._on_message({"type": "homework_heard", "request_id": str(sent[-1].request_id), "data": {"text": "もっと ヒント"}})
	var follow: Dictionary = sent[-1]
	_ok(spoken and busy_why.contains("話している") and int(follow.data.target_problem) == 3 and follow.data.history.size() == 1,
		"study voice: the answer is said; not while UFOくん speaks; the next turn keeps the problem and the turns",
		str([spoken, busy_why, follow.data.get("target_problem"), vo.history]))
	# a closer look: the usual HELP for that problem after the answer
	hw._on_message({"type": "homework_talk_result", "request_id": str(follow.request_id), "data": {
		"message": "ちかくで みてみるね", "action": "ask_recapture", "target_problem": 2, "hint_level": 0,
		"need_recapture": true}})
	var reset_turns: bool = vo.target_problem == 2 and vo.history.size() == 1
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
	_ok(StudyVoice.mentions_number("3ばん") and StudyVoice.mentions_number("さんばん") and not StudyVoice.mentions_number("ヒントちょうだい"),
		"study voice: a number said picks the problem itself")
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
