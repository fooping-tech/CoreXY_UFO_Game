extends "res://tests/test_base.gd"
## #334: the finger hint after the answer check: the problem's number shown with the fingers, the
## tutor's hint for it (or the worksheet's when the tutor fails), asked again = a stronger one.


## A stand-in for the homework link: records what the study mode sends, sends nothing, "open".
class _HintLinkSpy:
	extends UfoWebSocketClient
	var sent: Array

	func send_aux(msg: Dictionary) -> Error:
		sent.append(msg)
		return OK

	func is_open() -> bool:
		return true


func _test_finger_hint_logic() -> void:
	var f := StudyFingerHint.new()
	f.hold_ms = 1000.0
	f.restart()
	# a count shown when the step begins does not count until the hand changes
	var a := [f.tick(3, "three", 0.0), f.tick(3, "three", 600.0), f.tick(3, "three", 1500.0)]
	var b := [f.tick(-1, "", 1600.0), f.tick(3, "three", 1700.0), f.tick(3, "three", 2300.0)]
	var mid := f.progress
	var got := f.tick(3, "three", 2750.0)
	var again := [f.tick(3, "three", 3000.0), f.tick(3, "three", 5000.0)]  # held on: nothing more
	_ok(a == [-1, -1, -1] and b == [-1, -1, -1] and mid > 0.5 and mid < 0.7 and got == 3 and again == [-1, -1],
		"finger hint: a count held 1 s picks, once; a count already shown at the start waits for a change",
		str([a, b, mid, got, again]))
	# a thumbs-up is never a number (the answer check's いいね, #333); unclear (-1) restarts the hold
	f.restart()
	f.tick(-1, "", 0.0)
	var thumb := [f.tick(1, "thumb", 100.0), f.tick(1, "thumb", 1500.0), f.tick(1, "thumb", 3000.0)]
	var wobble := [f.tick(2, "peace", 3100.0), f.tick(-1, "other", 3600.0), f.tick(2, "peace", 3700.0),
		f.tick(2, "peace", 4500.0)]
	var two := f.tick(2, "peace", 4800.0)
	var fist := [f.tick(0, "fist", 5000.0), f.tick(0, "fist", 6100.0)]
	_ok(thumb == [-1, -1, -1] and wobble == [-1, -1, -1, -1] and two == 2 and fist == [-1, StudyFingerHint.FIST],
		"finger hint: a thumbs-up counts nothing, an unclear frame starts the hold again, a fist (0) is picked too",
		str([thumb, wobble, two, fist]))
	# the hints given per problem, as the tutor's history (the last 6)
	for i in 8:
		f.add(2, i, "h%d" % i, "tutor")
	var given := f.given(2)
	_ok(given.size() == 6 and given[0] == {"hint_level": 2, "message": "h2"} and given[5].hint_level == 3
		and f.count_for(2) == 8 and f.given(1).is_empty(),
		"finger hint: the hints given per problem go as the history (6 at most, level 0..3)", str(given))
	# the hand event's count; an older backend: the poses that name one
	_ok(GestureControl.fingers_of({"fingers": 4, "pose": "open"}) == 4 and GestureControl.fingers_of({"fingers": 9}) == -1
		and GestureControl.fingers_of({"pose": "peace"}) == 2 and GestureControl.fingers_of({"pose": "open"}) == -1,
		"finger hint: the hand event's fingers (else 1 / 2 / 3 from an older backend's pose)")
	# the worksheet's own hints, one after another (never the answer); any problem's on a real print
	var p := {"hints": ["一のくらいから", "くり上がりに 気をつけて"], "answer": "85"}
	var h0 := StudyServices.fallback_hint(p, 2, 0)
	var h5 := StudyServices.fallback_hint(p, 2, 5)
	var any := StudyServices.fallback_hint({}, 4, 1)
	_ok(h0.message == "一のくらいから。" and h5.message == "くり上がりに 気をつけて。" and h0.hint_level == 1 and h5.hint_level == 3
		and not str(h0).contains("85") and any.message.begins_with(StudyServices.ANY_PROBLEM_HINTS[1]),
		"finger hint: the fallback is the worksheet's hints in turn (any problem's on a real print), never the answer",
		str([h0, h5, any]))


## The story in the simulated demo: graded (1 right, 2 to look again, 3 right) -> the summary ->
## "わからない もんだいが あったら…" once -> 2 fingers held -> "2ばん だね！" -> the hint -> again ->
## a stronger one with the history -> a fist -> back to the summary (its prompt given back).
func _test_finger_hint_story(rs: Node) -> void:
	var game := _study_game()
	var ctl: StudyModeController = game.study_mode
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = false
	var said: Array[String] = []
	ctl.speech.line_started.connect(func(t, _f): said.append(t))
	var states: Array[String] = []
	ctl.state_changed.connect(func(_p, c): states.append(c))
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	var asked := _study_pump(game, 60.0, func(): return ctl.state == "HINT_ASK")
	var prompt := "わからない もんだいが あったら、もんだいの ばんごうを ゆびで おしえてね！"
	var once := said.count(prompt) == 1 and "REVIEW_SUMMARY" in states and ctl.adult_prompt == ""
	var hud: StudyHud = game.study_hud
	hud.refresh()
	var shown: bool = hud.hint_panel.visible and hud.hint_panel._title.text.contains("ゆびで おしえてね")
	_ok(asked and once and shown, "finger hint: after the summary UFOくん asks once for a number shown with the fingers (the box shows)",
		str([asked, said, states]))
	_study_pump(game, 10.0, func(): return not ctl.speech.busy())
	# a number not on the sheet: said so, still asking
	var t := 100000.0
	ctl.finger_tick(-1, "", t)
	ctl.finger_tick(5, "open", t + 100.0)
	ctl.finger_tick(5, "open", t + 1200.0)
	var not_there := ctl.state == "HINT_ASK" and ctl.speech.current.contains("5ばんは ないみたい")
	# 2 fingers held 1 s (the gauge fills first)
	ctl.finger_tick(2, "peace", t + 1300.0)
	ctl.finger_tick(2, "peace", t + 1900.0)
	hud.refresh()
	var gauge := ctl.finger_hint.progress > 0.5 and hud.hint_panel._hint.text.contains("2ばん？")
	ctl.finger_tick(2, "peace", t + 2400.0)
	var picked := ctl.state == "HINT_THINKING" and ctl.hint_problem == 2 and ctl.speech.current == "2ばん だね！"
	_study_pump(game, 10.0, func(): return ctl.state == "HINT_GIVING")
	var first_hint := ctl.hint_text
	var ws_hints: Array = WorksheetCatalog.problem(ctl.worksheet, 2).get("hints", [])
	var from_sheet: bool = not ws_hints.is_empty() and first_hint.begins_with(str(ws_hints[0])) and ctl.hint_source == "demo"
	_study_pump(game, 20.0, func(): return ctl.state == "HINT_ASK")
	var answer := str(WorksheetCatalog.problem(ctl.worksheet, 2).get("answer", "@@"))
	_ok(not_there and gauge and picked and from_sheet and ctl.finger_hint.count_for(2) == 1
		and not said.any(func(s): return answer != "" and s.contains("こたえは " + answer)),
		"finger hint: 2 fingers held 1 s -> \"2ばん だね！\" -> the hint said and shown (a number not on the sheet is said so)",
		str([not_there, gauge, picked, first_hint, ws_hints]))
	# the same number again: the history goes, a stronger hint (the worksheet's next one here)
	t += 10000.0
	ctl.finger_tick(2, "peace", t)  # still the 2 from before: not taken again at once
	ctl.finger_tick(2, "peace", t + 1500.0)
	var held_no := ctl.state == "HINT_ASK"
	ctl.finger_tick(-1, "", t + 1600.0)
	ctl.finger_tick(2, "peace", t + 1700.0)
	ctl.finger_tick(2, "peace", t + 2800.0)
	var again := ctl.state == "HINT_THINKING" and ctl.speech.current == "2ばん だね！"
	_study_pump(game, 10.0, func(): return ctl.state == "HINT_GIVING")
	var stronger: bool = ws_hints.size() < 2 or ctl.hint_text.begins_with(str(ws_hints[1]))
	_study_pump(game, 20.0, func(): return ctl.state == "HINT_ASK")
	_ok(held_no and again and stronger and ctl.finger_hint.count_for(2) == 2,
		"finger hint: the same number again (after the hand changed) gives the next, stronger hint", str([held_no, again, ctl.hint_text]))
	# a thumbs-up does nothing here; a fist held ends the step: back to the summary and its prompt
	t += 10000.0
	ctl.finger_tick(1, "thumb", t)
	ctl.finger_tick(1, "thumb", t + 2000.0)
	var thumb_no := ctl.state == "HINT_ASK"
	ctl.finger_tick(0, "fist", t + 2100.0)
	ctl.finger_tick(0, "fist", t + 3200.0)
	var back: bool = ctl.state == "REVIEW_SUMMARY" and ctl.adult_prompt.contains("R") and ctl.hint_text == ""
	_study_pump(game, 15.0)
	_ok(thumb_no and back and ctl.state == "REVIEW_SUMMARY" and said.count(prompt) == 1 and rs.source == "mock"
		and not ctl.blocks_manual_control(),
		"finger hint: a thumbs-up is not a number; a fist ends it, the summary comes back (asked only once, nothing moved)",
		str([thumb_no, back, ctl.state, ctl.adult_prompt]))
	# Enter goes on as at the summary (the reward)
	ctl.advance()
	var reward := _study_pump(game, 20.0, func(): return ctl.state in StudyModeController.REWARD_STATES)
	_ok(reward, "finger hint: after it, Enter goes on to the reward as before", ctl.state)
	# again from the start: no hand for ask_s ends the step by itself; keys 1..5 / Enter work in it
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 60.0, func(): return ctl.state == "HINT_ASK")
	_study_pump(game, 10.0, func(): return not ctl.speech.busy())
	ctl.finger_tick(-1, "", 0.0)
	ctl.finger_tick(-1, "", ctl.hint_ask_s * 1000.0 + 10.0)
	var timed_out := ctl.state == "REVIEW_SUMMARY"
	ctl._hint_offered = false
	ctl._offer_hint()
	ctl.handle_key(KEY_3)
	var by_key := ctl.state == "HINT_THINKING" and ctl.hint_problem == 3
	ctl.handle_key(KEY_ENTER)
	var entered := _study_pump(game, 20.0, func(): return ctl.state in StudyModeController.REWARD_STATES)
	_ok(timed_out and by_key and entered, "finger hint: no hand for a while ends it; 1..5 keys pick, Enter goes on (staff)",
		str([timed_out, by_key, ctl.state]))
	# switched off (study_mode.finger_hint.enabled): the summary as before
	ctl.hint_enabled = false
	ctl.start()
	ctl.debug_skip()
	ctl.debug_skip()
	ctl.tracker.confirm_complete()
	ctl._check_complete()
	_study_pump(game, 60.0, func(): return ctl.state == "REVIEW_SUMMARY" and not ctl.speech.busy())
	_study_pump(game, 3.0)
	_ok(ctl.state == "REVIEW_SUMMARY", "finger hint: off in the config, the summary stays as before", ctl.state)
	ctl.hint_enabled = true
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()


## The camera mode: what goes to the backend (the picture read, the number, the history) and what
## comes back (only the message); the tutor fails -> the worksheet's hint, never a stall.
func _test_finger_hint_request(rs: Node) -> void:
	var game := _study_game("camera")
	var ctl: StudyModeController = game.study_mode
	var sv := ctl.services
	var hw: HomeworkClient = sv.homework
	hw.sheet_settings_path = ""
	var real_link := hw.link
	var spy := _HintLinkSpy.new()
	spy.sent = []
	hw.link = spy
	hw.hint_available = true
	ctl.start()
	ctl.speech.clear()
	sv.graded_image = Image.create(2400, 1800, false, Image.FORMAT_RGB8)  # the answer check's picture
	ctl.grading.reset([1, 2, 3])
	ctl._set_state("HINT_ASK")
	ctl.finger_hint.restart()
	ctl.finger_hint.add(3, 1, "まえの ヒント", "tutor")
	ctl.pick_hint(3)
	var msg: Dictionary = spy.sent[-1] if not spy.sent.is_empty() else {}
	var d: Dictionary = msg.get("data", {})
	var img := Image.new()
	var decoded := img.load_jpg_from_buffer(Marshalls.base64_to_raw(str(d.get("image_jpeg_base64", "")))) == OK
	_ok(msg.get("type", "") == "homework_hint" and int(d.get("problem", 0)) == 3
		and d.get("history", []) == [{"hint_level": 1, "message": "まえの ヒント"}]
		and decoded and maxi(img.get_width(), img.get_height()) <= StudyServices.HINT_IMAGE_EDGE
		and str(msg.get("request_id", "")).begins_with("sm-hint"),
		"finger hint: the request names the problem, the hints given for it, and the picture read (long side <= 1800)",
		str([msg.get("type"), d.get("problem"), d.get("history"), img.get_size()]))
	# the answer: only the message is used (anything else in it is not shown)
	hw._on_message({"type": "homework_hint_result", "request_id": str(msg.request_id), "data": {
		"problem": 3, "message": "ひとつずつ かぞえてみよう。", "hint_level": 2, "solution": "3 + 4 = 7", "correct_answer": "7"}})
	var giving := ctl.state == "HINT_GIVING" and ctl.hint_text == "ひとつずつ かぞえてみよう。" and ctl.hint_source == "tutor"
	var hist: Array = ctl.finger_hint.history.get(3, [])
	_ok(giving and hist.size() == 2 and int(hist[1].hint_level) == 2 and not str(hist).contains("7"),
		"finger hint: the tutor's message is said and shown, kept as history; its answer never", str([ctl.state, ctl.hint_text, hist]))
	# the tutor fails (busy, wrong token, held back...): the worksheet's hint, said the same way
	ctl.speech.clear()
	ctl._set_state("HINT_ASK")
	ctl.pick_hint(1)
	var rid := str(spy.sent[-1].request_id)
	hw._on_message({"type": "homework_hint_error", "request_id": rid, "data": {"problem": 1, "code": "busy",
		"message": "学習支援 AI がエラーを返しました（HTTP 503）"}})
	var fell_back := ctl.state == "HINT_GIVING" and ctl.hint_source == "worksheet" and ctl.hint_text != "" \
		and ctl.hint_note.contains("busy")
	# a late answer for an old request is dropped
	hw._on_message({"type": "homework_hint_result", "request_id": rid, "data": {"problem": 1, "message": "おそい"}})
	# no tutor in the backend / the link down: at once the worksheet's
	ctl._set_state("HINT_ASK")
	hw.hint_available = false
	var n_sent := spy.sent.size()
	ctl.pick_hint(2)
	var no_tutor := ctl.state == "HINT_GIVING" and ctl.hint_source == "worksheet" and spy.sent.size() == n_sent
	_ok(fell_back and ctl.hint_text != "おそい" and no_tutor,
		"finger hint: a failed or missing tutor falls back to the worksheet's hint (late answers dropped)",
		str([fell_back, no_tutor, ctl.hint_text, ctl.hint_note]))
	# the voice off: the words are still shown (the bubble and the box)
	ctl.speech.voice_on = false
	ctl._set_state("HINT_ASK")
	ctl.speech.clear()
	hw.hint_available = true
	ctl.pick_hint(1)
	hw._on_message({"type": "homework_hint_result", "request_id": str(spy.sent[-1].request_id), "data": {
		"problem": 1, "message": "えを かいてみよう。", "hint_level": 1}})
	_study_pump(game, 6.0, func(): return ctl.speech.current == "えを かいてみよう。")
	var hud: StudyHud = game.study_hud
	hud.refresh()
	_ok(ctl.speech.current == "えを かいてみよう。" and hud.hint_panel.visible and hud.hint_panel._hint.text.contains("えを かいてみよう"),
		"finger hint: without the voice the hint is shown in UFOくん's bubble and the box", ctl.speech.current)
	hw.link = real_link
	spy.free()
	ctl.stop()
	remove_child(game)
	game.free()
	rs.clear_samples()
