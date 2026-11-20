extends "res://tests/test_base.gd"
## The practice (gesture tutorial), the title's hand and the easy mode.

## The easy mode's own state machine: one sign = one request, only in its context.
func _test_easy_mode_logic() -> void:
	var open = _easy_hand("open")
	var fist = _easy_hand("fist")
	var one = _easy_hand("point")
	var two = _easy_hand("peace")
	# --- to the portal (Dial 1, the only destination since #200), to the end
	for dest in [1]:
		var p = _easy_new()
		var e: EasyModeControl = p[0]
		var be: EasyBackend = p[1]
		var delivered = []
		var cues = []
		e.delivered.connect(func(d): delivered.append(d))
		e.cue.connect(func(c): cues.append(c))
		_easy_run(e, be, 1.0, fist)
		var needs_neutral = be.sent.is_empty() and e.state == "MANUAL_XY"  # the fist was there before any neutral hand
		_easy_run(e, be, 0.3, open)
		_easy_run(e, be, 0.5, fist)
		var not_yet = be.sent.is_empty() and e.holding == "grab" and e.progress > 0.5
		_easy_run(e, be, 0.2, fist)
		var asked = be.names() == ["easy_grab"] and e.state == "AUTO_GRAB" and e.busy()
		_easy_run(e, be, 2.0, fist)  # the fist stays closed for the whole catch
		e.on_ack(be.last_rid(), true, {"grab_id": "g%d" % dest})
		be.report("AUTO_GRAB", "g%d" % dest, {"step": "LOWER_TO_CATCH"})
		_easy_run(e, be, 0.5, fist)
		var following = e.state == "AUTO_GRAB" and e.step_text() == "おりる"
		be.report("WAIT_DESTINATION", "g%d" % dest, {"step": "WAIT_DESTINATION"})
		_easy_run(e, be, 0.2, fist)
		var waiting = e.state == "WAIT_DESTINATION" and be.sent.size() == 1
		var sign = one if dest == 1 else two
		_easy_run(e, be, 1.0, sign)  # straight from the fist to the fingers: not read yet
		var neutral_first = be.sent.size() == 1 and e.note.contains("パー")
		_easy_run(e, be, 0.3, open)
		_easy_run(e, be, 1.5, two)  # #200: two fingers mean nothing (there is no right portal)
		var two_nothing = be.sent.size() == 1 and e.state == "WAIT_DESTINATION" and e.holding == "" and e.note == EasyModeControl.TWO_FINGERS_NOTE
		_easy_run(e, be, 0.3, open)
		_easy_run(e, be, 0.7, sign)
		var chose: bool = be.names() == ["easy_grab", "easy_deliver"] and be.sent[1][1] == {"destination": dest, "grab_id": "g%d" % dest} \
			and e.state == "DELIVER_DIAL_%d" % dest
		e.on_ack(be.last_rid(), true, {})
		_easy_run(e, be, 0.3, sign)  # the backend's report still says "waiting" for a moment: nothing
		be.report("DELIVER_DIAL_%d" % dest, "g%d" % dest, {"destination": dest, "step": "MOVE_TO_DIAL"})
		_easy_run(e, be, 1.0, two if dest == 1 else one)  # the other sign while it carries: nothing
		var carrying = be.sent.size() == 2 and delivered.is_empty() and e.state == "DELIVER_DIAL_%d" % dest
		be.report("MANUAL_XY", "g%d" % dest, {"destination": dest, "last_result": "done"})
		_easy_run(e, be, 0.1, sign)
		var done = delivered == [dest] and e.state == "MANUAL_XY" and not e.busy()
		_easy_run(e, be, 2.0, fist if dest == 1 else sign)  # a shape still held after the end: not a new request
		_easy_run(e, be, 2.0, fist)
		var no_repeat = be.sent.size() == 2
		_ok(needs_neutral and not_yet and asked and following and waiting and neutral_first and two_nothing and chose and carrying and done and no_repeat
			and cues == ["grab", "caught", "deliver", "done"] and not EasyModeControl.STATES.has("DELIVER_DIAL_2"),
			"easy mode: fist -> catch -> one finger -> carry to Dial %d -> back to the hand; each sign asks once, and only after a neutral hand; two fingers ask for nothing and the screen says to show one (#200)" % dest,
			"%s %s %s %s %s %s %s %s %s %s %s" % [needs_neutral, not_yet, asked, following, waiting, neutral_first, chose, carrying, done, no_repeat, cues])
	# --- a sign must be held, unbroken, by one fresh hand
	var p2 = _easy_new()
	var e2: EasyModeControl = p2[0]
	var be2: EasyBackend = p2[1]
	_easy_run(e2, be2, 0.3, open)
	for breaker in [_easy_hand("other"), _easy_hand("fist", {"detected": false}), _easy_hand("fist", {"fresh": false}),
			_easy_hand("fist", {"camera_ok": false}), _easy_hand("fist", {"pinch": true})]:
		_easy_run(e2, be2, 0.5, fist)
		_easy_run(e2, be2, 1.0 / 60.0, breaker)  # one tick of another shape / no hand / two hands / a stale event / no camera / a pinch
		_easy_run(e2, be2, 0.5, fist)
		_easy_run(e2, be2, 0.3, open)
	var flicker_ok = be2.sent.is_empty()
	# the fingers mean nothing before a catch; a fist means nothing while something blocks it
	_easy_run(e2, be2, 1.0, one)
	_easy_run(e2, be2, 1.0, two)
	var fingers_nothing = be2.sent.is_empty() and e2.note.contains("グー")
	_easy_run(e2, be2, 0.3, open)
	var blocked = []
	for w in [{"taking": false}, {"link": false}, {"gate": "モーターを有効にしてください"}, {"busy": true}]:
		be2.status = {"active": true} if w.has("busy") else {}  # (another run of the backend is still going)
		_easy_run(e2, be2, 1.0, fist, w)
		blocked.append(be2.sent.is_empty() and e2.note != "" and e2.progress == 0.0)
		_easy_run(e2, be2, 0.3, open)
	be2.status = {}
	_easy_run(e2, be2, 1.0, _easy_hand("fist", {"steering": true}))
	blocked.append(be2.sent.is_empty() and e2.note.contains("とまってから"))
	_ok(flicker_ok and fingers_nothing and not blocked.has(false),
		"easy mode: a sign broken for one tick (another shape, no hand, a stale event, no camera, a pinch) starts over; fingers before a catch and a fist while steering / not playing / no link / not ready ask for nothing",
		"%s %s %s" % [flicker_ok, fingers_nothing, blocked])
	# --- one finger turning into two starts the hold over; an old report is not this catch's
	var p3 = _easy_new()
	var e3: EasyModeControl = p3[0]
	var be3: EasyBackend = p3[1]
	be3.report("MANUAL_XY", "old", {"last_result": "done", "destination": 1})  # the catch before this one
	_easy_run(e3, be3, 0.3, open)
	_easy_run(e3, be3, 0.7, fist)
	_easy_run(e3, be3, 0.5, fist)  # no answer yet: the old "done" must not be read as this catch's
	var old_ignored = e3.state == "AUTO_GRAB"
	e3.on_ack("some-other-request", true, {"grab_id": "zz"})
	var other_ack = e3.grab_id == ""
	e3.on_ack(be3.last_rid(), true, {"grab_id": "g"})
	be3.report("WAIT_DESTINATION", "g")
	_easy_run(e3, be3, 0.3, open)
	_easy_run(e3, be3, 0.4, one)
	_easy_run(e3, be3, 0.4, two)
	var switched = be3.sent.size() == 1 and e3.holding == ""
	_easy_run(e3, be3, 0.4, one)  # the hold starts over: 0.4 s again is not enough
	switched = switched and be3.sent.size() == 1 and e3.holding == "1"
	_easy_run(e3, be3, 0.3, one)
	var took_two: bool = be3.sent.size() == 2 and be3.sent[1][1].destination == 1
	# the backend refuses the choice (it had just given up): back to waiting, then its report decides
	e3.on_ack(be3.last_rid(), false, {"reason": "not waiting for a destination (state EXPIRED)"})
	var back_waiting = e3.state == "WAIT_DESTINATION" and e3.note != "" and e3.destination == 0
	be3.report("EXPIRED", "g", {"last_result": "expired", "error": "no destination chosen within 15 s"})
	_easy_run(e3, be3, 0.1, two)
	var expired = e3.state == "FAULT" and e3.note.contains("えらばなかった") and not e3.busy()
	_easy_run(e3, be3, 0.3, open)
	_easy_run(e3, be3, 2.0, fist)
	var stays = e3.state == "FAULT" and be3.sent.size() == 2  # nothing starts again by itself
	e3.reset()
	_easy_run(e3, be3, 1.0, fist)
	var reset_needs_neutral = e3.state == "MANUAL_XY" and be3.sent.size() == 2
	_ok(old_ignored and other_ack and switched and took_two and back_waiting and expired and stays and reset_needs_neutral,
		"easy mode: another catch's report and another request's answer are not read; one finger broken by another shape starts over; nobody choosing ends in FAULT, which only a reset leaves",
		"%s %s %s %s %s %s %s %s" % [old_ignored, other_ack, switched, took_two, back_waiting, expired, stays, reset_needs_neutral])
	# --- refusals, lost answers, faults, the link
	var results = []
	for case in ["nack", "timeout_ack", "no_answer", "fault", "link", "bad_ack"]:
		var p4 = _easy_new()
		var e4: EasyModeControl = p4[0]
		var be4: EasyBackend = p4[1]
		e4.request_timeout_s = 1.0
		_easy_run(e4, be4, 0.3, open)
		_easy_run(e4, be4, 0.7, fist)
		match case:
			"nack":
				e4.on_ack(be4.last_rid(), false, {"reason": "easy catch refused: not homed"})
				results.append(e4.state == "MANUAL_XY" and e4.note.contains("げんてんふっき"))
			"timeout_ack":
				e4.on_ack(be4.last_rid(), false, {"reason": "timeout"})
				results.append(e4.state == "FAULT")
			"no_answer":
				_easy_run(e4, be4, 1.2, fist)
				results.append(e4.state == "FAULT" and e4.note.contains("へんじ"))
			"fault":
				e4.on_ack(be4.last_rid(), true, {"grab_id": "g"})
				be4.report("FAULT", "g", {"last_result": "fault", "error": "LOWER_TO_CATCH timeout (8 s, Z -> 30)"})
				_easy_run(e4, be4, 0.1, fist)
				results.append(e4.state == "FAULT" and e4.note.contains("うごかなかった"))
			"link":
				e4.on_ack(be4.last_rid(), true, {"grab_id": "g"})
				_easy_run(e4, be4, 0.1, fist, {"link": false})
				results.append(e4.state == "FAULT" and e4.note.contains("つうしん"))
			"bad_ack":
				e4.on_ack(be4.last_rid(), true, {})
				results.append(e4.state == "FAULT")
		_easy_run(e4, be4, 0.3, open)
		_easy_run(e4, be4, 2.0, fist)
		results.append(be4.sent.size() == (2 if case == "nack" else 1))  # a refusal lets a NEW fist ask again; nothing else does
	_ok(not results.has(false),
		"easy mode: a refusal goes back to the hand with its reason (a new fist may ask again); a lost answer, a fault, a lost link or a wrong answer stop in FAULT and nothing is asked again",
		str(results))
	# --- the stop key, leaving in the middle, the round's end
	var p5 = _easy_new()
	var e5: EasyModeControl = p5[0]
	var be5: EasyBackend = p5[1]
	_easy_run(e5, be5, 0.3, open)
	_easy_run(e5, be5, 0.7, fist)
	var grab_rid = be5.last_rid()
	e5.on_stop()  # Space before the answer came
	var stopped = e5.state == "FAULT" and e5.note.contains("ストップ")
	e5.on_ack(grab_rid, true, {"grab_id": "late"})  # it had started after all: stopped again
	var stop_again = be5.names() == ["easy_grab", "soft_stop"] and e5.state == "FAULT"
	e5.reset()
	_easy_run(e5, be5, 0.3, open)
	_easy_run(e5, be5, 0.7, fist)
	e5.on_ack(be5.last_rid(), true, {"grab_id": "h"})
	be5.report("WAIT_DESTINATION", "h")
	_easy_run(e5, be5, 0.3, open)
	_easy_run(e5, be5, 1.5, one, {"taking": false})  # the time ran out while it waited
	var time_up = e5.state == "WAIT_DESTINATION" and not be5.names().has("easy_deliver") and e5.note.contains("じかんぎれ")
	_easy_run(e5, be5, 1.5, one, {"gate": "ゲームのウィンドウを選んでね"})  # the window lost its focus: no carry either
	var gated = e5.state == "WAIT_DESTINATION" and not be5.names().has("easy_deliver") and e5.note.contains("ウィンドウ") and e5.progress == 0.0
	time_up = time_up and gated
	_easy_run(e5, be5, 0.1, open, {"enabled": false})  # back to the title in the middle
	var left = e5.state == "OFF" and be5.names().count("soft_stop") == 2 and not e5.busy()
	_easy_run(e5, be5, 0.1, open, {"enabled": false})
	var once = be5.names().count("soft_stop") == 2
	_ok(stopped and stop_again and time_up and left and once,
		"easy mode: Space ends it at once (a catch that started behind the stop is stopped again); after the time is up nothing new is carried; leaving in the middle stops the backend's run, once",
		"%s %s %s %s %s" % [stopped, stop_again, time_up, left, once])
	# --- a game's start: the arm to its start position (#177)
	var p6 = _easy_new()
	var e6: EasyModeControl = p6[0]
	var be6: EasyBackend = p6[1]
	var asked = e6.request_reset() and be6.names() == ["easy_reset"] and e6.state == "RESET" and e6.busy()
	var not_twice = not e6.request_reset() and be6.sent.size() == 1
	_easy_run(e6, be6, 0.3, open)
	_easy_run(e6, be6, 1.0, fist)  # a fist meanwhile: nothing
	var fist_waits = be6.sent.size() == 1
	e6.on_ack(be6.last_rid(), true, {"grab_id": "r"})
	be6.report("RESET", "r", {"step": "RAISE_EMPTY"})
	_easy_run(e6, be6, 0.5, open)
	var raising = e6.state == "RESET" and e6.title_text().contains("じゅんび")
	be6.report("MANUAL_XY", "r", {"last_result": "done"})
	_easy_run(e6, be6, 0.1, open)
	var ready = e6.state == "MANUAL_XY" and not e6.busy()
	_easy_run(e6, be6, 0.7, fist)  # (the fist held through the reset is not a new sign)
	ready = ready and be6.sent.size() == 1
	_easy_run(e6, be6, 0.3, open)
	_easy_run(e6, be6, 0.7, fist)
	var then_catch = be6.names() == ["easy_reset", "easy_grab"]
	# refused (not calibrated, an alarm): said, and the hand has the crane; a fault: FAULT
	var p7 = _easy_new()
	var e7: EasyModeControl = p7[0]
	var be7: EasyBackend = p7[1]
	e7.request_reset()
	e7.on_ack(be7.last_rid(), false, {"reason": "easy reset refused: not homed"})
	var refused = e7.state == "MANUAL_XY" and e7.note.contains("げんてんふっき")
	e7.request_reset()
	e7.on_ack(be7.last_rid(), true, {"grab_id": "q"})
	be7.report("FAULT", "q", {"last_result": "fault", "error": "RAISE_EMPTY timeout (6 s, Z -> 95)"})
	_easy_run(e7, be7, 0.1, open)
	var reset_fault = e7.state == "FAULT" and not e7.request_reset()
	e7.reset()
	e7.request_reset()
	e7.on_stop()  # Space before its answer
	e7.on_ack(be7.last_rid(), true, {"grab_id": "late"})
	var reset_stopped = e7.state == "FAULT" and be7.names().has("soft_stop")
	_ok(asked and not_twice and fist_waits and raising and ready and then_catch and refused and reset_fault and reset_stopped,
		"easy mode: a game's start asks once for the arm's start position and the hand waits for it; a refusal is only said, a fault or a stop ends in FAULT",
		"%s %s %s %s %s %s %s %s %s" % [asked, not_twice, fist_waits, raising, ready, then_catch, refused, reset_fault, reset_stopped])
	# --- the claw came up empty: an open hand kept up gives the catch up (#179)
	var p8 = _easy_new()
	var e8: EasyModeControl = p8[0]
	var be8: EasyBackend = p8[1]
	var cues8 := []
	e8.cue.connect(func(c): cues8.append(c))
	_easy_run(e8, be8, 0.3, open)
	_easy_run(e8, be8, 0.7, fist)
	e8.on_ack(be8.last_rid(), true, {"grab_id": "k"})
	be8.report("WAIT_DESTINATION", "k")
	_easy_run(e8, be8, 0.2, fist)
	_easy_run(e8, be8, 0.6, open)  # the short open hand before the fingers: not a cancel
	var short_no = be8.sent.size() == 1 and e8.holding == "cancel" and e8.progress > 0.1 and e8.progress < 0.5
	_easy_run(e8, be8, 0.7, one)
	var still_chooses: bool = be8.names() == ["easy_grab", "easy_deliver"]
	e8.on_ack(be8.last_rid(), true, {})
	be8.report("MANUAL_XY", "k", {"destination": 1, "last_result": "done"})
	_easy_run(e8, be8, 0.1, one)
	# again, and this time the open hand is kept up
	_easy_run(e8, be8, 0.3, open)
	_easy_run(e8, be8, 0.7, fist)
	e8.on_ack(be8.last_rid(), true, {"grab_id": "m"})
	be8.report("WAIT_DESTINATION", "m")
	_easy_run(e8, be8, 1.0, _easy_hand("open", {"pinch": true}))  # a pinch is not the open hand
	_easy_run(e8, be8, 1.4, open)
	_easy_run(e8, be8, 1.0 / 60.0, _easy_hand("other"))  # broken for a tick: starts over
	_easy_run(e8, be8, 1.4, open)
	var not_yet8 = not be8.names().has("easy_cancel")
	_easy_run(e8, be8, 0.2, open)
	var cancelled: bool = be8.names().count("easy_cancel") == 1 and be8.sent[-1][1] == {"grab_id": "m"} and e8.state == "CANCEL" and e8.busy()
	_easy_run(e8, be8, 1.0, open)  # still held: asked once
	e8.on_ack(be8.last_rid(), true, {})
	be8.report("MANUAL_XY", "m", {"last_result": "cancelled"})
	_easy_run(e8, be8, 0.1, open)
	var back8 = e8.state == "MANUAL_XY" and be8.names().count("easy_cancel") == 1 and cues8.has("cancelled") and e8.note.contains("もういちど")
	_easy_run(e8, be8, 0.3, open)
	_easy_run(e8, be8, 0.7, fist)
	var again8: bool = be8.names().count("easy_grab") == 3
	# also after the time is up (a way out without the staff); not with the gate closed
	e8.on_ack(be8.last_rid(), true, {"grab_id": "n"})
	be8.report("WAIT_DESTINATION", "n")
	_easy_run(e8, be8, 0.3, _easy_hand("other"))
	_easy_run(e8, be8, 2.0, open, {"gate": "ハンドジェスチャーが オフ"})
	var gate_no = be8.names().count("easy_cancel") == 1
	_easy_run(e8, be8, 2.0, open, {"taking": false})
	var after_time_up = be8.names().count("easy_cancel") == 2
	e8.on_ack(be8.last_rid(), false, {"reason": "not waiting for a destination (state EXPIRED)"})
	var refused8 = e8.state == "WAIT_DESTINATION"
	_ok(short_no and still_chooses and not_yet8 and cancelled and back8 and again8 and gate_no and after_time_up and refused8,
		"easy mode: while it waits for the destination an open hand kept up gives the catch up, once (the short open hand before the fingers does not, nor a pinch, nor with the gate closed); then a new fist catches again",
		"%s %s %s %s %s %s %s %s %s" % [short_no, still_chooses, not_yet8, cancelled, back8, again8, gate_no, after_time_up, refused8])
	_ok(EasyModeControl.sign_of(_easy_hand("thumb")) == "grab" and EasyModeControl.sign_of(_easy_hand("point")) == "1"
		and EasyModeControl.sign_of(_easy_hand("peace")) == "" and EasyModeControl.sign_of(_easy_hand("open")) == "neutral"
		and EasyModeControl.sign_of(_easy_hand("other")) == "" and EasyModeControl.sign_of({}) == "",
		"easy mode: fist (thumb out or not) = catch, one finger = the portal (Dial 1), パー = neutral, anything else (two fingers too, #200) = nothing")

## The easy mode in the score game: the difficulty, the hand's meaning, the mock run, hard as before.
func _test_easy_mode_game(rs: Node) -> void:
	var game = _gm_game()
	var ctl: GameModeController = game.game_mode
	var e: EasyModeControl = game.easy
	var be = EasyBackend.new()
	e.send = be.send
	game.gesture_require_focus = false
	game.set_gesture_enabled(true)
	game.gesture.arm_delay_ms = 0.0
	game.gesture.claw_hold_ms = 0.0
	game.gesture.joystick.smoothing_ms = 0.0
	var claws = []
	game.gesture.claw_requested.connect(func(w): claws.append(w))
	var dt = 1.0 / 60.0
	var seq = [0]
	var feed := func(pose: String, n: int, pinch := false, x := 0.5, extra := {}) -> void:
		for i in n:
			seq[0] += 1
			var more = {"pose": pose}
			more.merge(extra, true)
			game.gesture.on_event(_hev(seq[0], true, pinch, x, 0.5, more), float(Time.get_ticks_msec()))
			RobotState.easy_mode = be.status
			game._handle_input(dt)
			ctl.tick(dt)
	# a game's start asks the backend for the arm's start position (#177): the stand-in answers
	var reset_done := func() -> void:
		feed.call("open", 2)
		if e.state == "RESET":
			game.ws.ack.emit(be.last_rid(), true, {"command": "easy_reset", "grab_id": "r%d" % be.n})
			be.report("MANUAL_XY", "r%d" % be.n, {"last_result": "done"})
			feed.call("open", 2)
		be.sent = be.sent.filter(func(x): return x[0] != "easy_reset")
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	var starts_hard = ctl.difficulty == "hard" and not ctl.easy_on() and ctl.hud.title_showing() \
		and str(GameConfig.value("game_mode.difficulty", "")) == ""  # (#198: not a setting any more)
	game._unhandled_input(_key(KEY_D))  # #198: D switches nothing
	starts_hard = starts_hard and ctl.difficulty == "hard"
	ctl.set_difficulty("easy")  # what a game not made by _gm_game() always plays
	feed.call("open", 2)
	ctl.hud._process(0.016)
	# the game drives its own mock crane: the easy mode is not usable, and says so; hard is played
	var no_backend: bool = ctl.difficulty == "easy" and not ctl.easy_on() and ctl.hud._mode.text.contains("バックエンド") \
		and game.gesture.claw_enabled and not game.gesture.xy_only and not e.enabled()
	# with the backend (a stand-in link): usable
	game.mock.enabled = false
	RobotState.source = "websocket"
	RobotState.connected = true
	RobotState.motors_enabled = true
	RobotState.homed = true
	RobotState.machine_state = "IDLE"
	game.ws.server_robot = "mock"
	game.backend_link = func() -> bool: return true
	feed.call("open", 2)
	ctl.hud._process(0.016)
	var usable: bool = ctl.easy_on() and e.state == "MANUAL_XY" and game.gesture.xy_only and not game.gesture.claw_enabled \
		and ctl.hud._how[0].text.contains("グー") and not ctl.easy_hud.showing()
	game.gesture.set_scheme(PoseDirectionScheme.ID)
	feed.call("open", 2)
	var other_scheme: bool = not ctl.easy_on() and ctl.easy_block.contains("つまんで動かす") and not e.enabled()
	game.gesture.set_scheme(PinchJoystickScheme.ID)
	feed.call("open", 20)
	feed.call("fist", 60)
	var not_before_the_round = be.sent.is_empty() and e.note.contains("ゲームちゅう")  # the title: no catch
	game._unhandled_input(_key(KEY_ENTER))
	feed.call("open", 2)
	# the round starts: the arm is brought to its start, and the hand waits meanwhile
	var start_reset = be.names() == ["easy_reset"] and e.state == "RESET" and e.resets_sent == 1 \
		and game.gesture_gate_reason == game.GATE_EASY_BUSY
	reset_done.call()
	start_reset = start_reset and e.state == "MANUAL_XY" and be.sent.is_empty()
	feed.call("open", int((ctl.countdown_s + 0.3) * 60.0))
	game._unhandled_input(_key(KEY_D))  # D in a round: nothing
	var playing = ctl.phase == "PLAYING" and ctl.difficulty == "easy" and ctl.lanes["left"].state == "READY"
	ctl.easy_hud._process(0.016)
	var strip = ctl.easy_hud.showing() and ctl.easy_hud.view() == "strip"
	# pinch = XY, also with the back of the hand up (never Z); peace opens no claw
	feed.call("open", 4, true, 0.5, {"palm": "down"})
	feed.call("open", 20, true, 0.65, {"palm": "down"})
	var xy: bool = game.control_source == "gesture" and game.gesture.mode == "xy" and is_zero_approx(game.gesture.velocity_z) \
		and game.gesture.velocity.length() > 1.0
	feed.call("open", 6)
	feed.call("peace", 60)
	feed.call("open", 6)
	var no_claw = claws.is_empty() and be.sent.is_empty()
	# the hand control switched off (H): the camera still sees the hand, but no shape asks for anything
	game.set_gesture_enabled(false)
	feed.call("open", 20)
	feed.call("fist", 60)
	var off_nothing = be.sent.is_empty() and e.state == "MANUAL_XY" and e.note.contains("オフ")
	game.set_gesture_enabled(true)
	feed.call("open", 20)
	no_claw = no_claw and off_nothing
	# --- left: fist -> catch -> one finger -> Dial 1 -> the mock Dial takes its capsule
	feed.call("fist", 45)
	var grabbed = be.names() == ["easy_grab"] and e.state == "AUTO_GRAB"
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_grab", "grab_id": "a"})
	be.report("AUTO_GRAB", "a", {"step": "CLOSE_CLAW"})
	feed.call("open", 4, true)
	feed.call("open", 20, true, 0.7)  # a pinch while it catches: the crane is not the hand's
	var locked: bool = game.control_source != "gesture" and game.gesture_gate_reason == game.GATE_EASY_BUSY
	be.report("WAIT_DESTINATION", "a", {"step": "WAIT_DESTINATION"})
	feed.call("open", 20)
	feed.call("other", 2)
	ctl.easy_hud._process(0.016)
	var panel: bool = e.state == "WAIT_DESTINATION" and ctl.easy_hud.view() == "panel" and ctl.easy_hud._title.text == "ゆび 1ぽんで ポータルへ！" \
		and ctl.easy_hud.sub_text().contains("ひだり") and ctl.easy_hud._stop.text.contains("Space")
	game.set_gesture_enabled(false)
	feed.call("point", 60)  # switched off while it waits: the finger carries nothing
	var off_no_carry = be.names() == ["easy_grab"] and e.state == "WAIT_DESTINATION"
	game.set_gesture_enabled(true)
	feed.call("open", 20)
	panel = panel and off_no_carry
	feed.call("point", 45)
	var chose = be.names() == ["easy_grab", "easy_deliver"] and be.sent[1][1] == {"destination": 1, "grab_id": "a"}
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_deliver"})
	be.report("DELIVER_DIAL_1", "a", {"destination": 1, "step": "MOVE_TO_DIAL"})
	feed.call("point", 30)
	var before = str(ctl.lanes["left"].state)
	be.report("MANUAL_XY", "a", {"destination": 1, "last_result": "done"})
	feed.call("point", 6)
	var left_took: bool = before == "READY" and ctl.lanes["left"].state == "ABSORBING" and e.state == "MANUAL_XY"
	# --- #200: there is no right portal: two fingers after a catch carry nothing (and open no claw)
	feed.call("open", 20)
	feed.call("fist", 45)
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_grab", "grab_id": "b"})
	be.report("WAIT_DESTINATION", "b")
	feed.call("open", 20)
	feed.call("peace", 90)
	var two_nothing: bool = be.sent.size() == 3 and e.state == "WAIT_DESTINATION" and claws.is_empty()
	feed.call("open", 20)
	feed.call("point", 45)
	var chose_again: bool = be.sent.size() == 4 and be.sent[3][1] == {"destination": 1, "grab_id": "b"}
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_deliver"})
	be.report("MANUAL_XY", "b", {"destination": 1, "last_result": "done"})
	feed.call("point", 6)
	var no_right: bool = not ctl.lanes.has("right") and _gm_sent(ctl.mock_hub, GM_R) == 0 and claws.is_empty()
	_ok(starts_hard and no_backend and usable and other_scheme and not_before_the_round and playing and strip and start_reset,
		"easy mode in the game: hard at start, D on the title switches; without a backend or with another hand scheme it is not used and says why; no catch before the round",
		"%s %s %s %s %s %s %s" % [starts_hard, no_backend, usable, other_scheme, not_before_the_round, playing, strip])
	_ok(xy and no_claw and grabbed and locked and panel and chose and left_took and two_nothing and chose_again and no_right,
		"easy mode in the game: pinch steers XY only, the shapes ask for no claw; fist -> one finger puts the mock capsule into the left Dial (the only portal, #200); two fingers carry nothing; the hand is locked out meanwhile and the screen says what happens",
		"%s %s %s %s %s %s %s %s %s %s" % [xy, no_claw, grabbed, locked, panel, chose, left_took, two_nothing, chose_again, no_right])
	# --- the real crane: the game never makes up the Dial's capsule
	feed.call("open", 600)  # (the capsule through the field and back out)
	for side in ["left"]:
		var l: GameModeController.Lane = ctl.lanes[side]
		if not l.capsule.is_empty() and l.state == "SIMULATING":
			ctl.field.capsule_exited.emit(l.capsule.capsule_id, "goal_left", Vector2(360, 1000))
	feed.call("open", 600)
	var ready_again: bool = ctl.lanes["left"].state == "READY"
	ctl.easy_delivered("left", false)
	feed.call("open", 6)
	var real_waits: bool = ready_again and ctl.lanes["left"].state == "READY"
	# --- the time runs out while it waits: nothing is carried; Space: FAULT, a new round resets
	feed.call("fist", 45)
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_grab", "grab_id": "c"})
	be.report("WAIT_DESTINATION", "c")
	feed.call("open", 20)
	ctl.time_left = 0.05
	feed.call("open", 20)
	var sent_before = be.sent.size()
	feed.call("point", 60)
	var settling: bool = ctl.phase in ["SETTLING", "RESULT"] and be.sent.size() == sent_before and e.state == "WAIT_DESTINATION"
	game.stop_key()
	var stop_fault: bool = e.state == "FAULT"
	be.report("FAULT", "c", {"last_result": "fault", "error": "stopped (soft_stop) during the easy mode's catch and carry"})
	feed.call("open", 20)
	feed.call("fist", 60)
	var no_restart = be.sent.size() == sent_before and e.state == "FAULT"
	game._unhandled_input(_key(KEY_F9))
	var staff_reset: bool = e.state == "MANUAL_XY"
	_ok(real_waits and settling and stop_fault and no_restart and staff_reset,
		"easy mode in the game: with the real crane the Dial's own report is waited for; after TIME UP nothing new is carried; Space stops it for good until staff (F9) or a new round",
		"%s %s %s %s %s" % [real_waits, settling, stop_fault, no_restart, staff_reset])
	# --- leaving for the title in the middle of a catch stops the backend's run
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	game._unhandled_input(_key(KEY_ENTER))
	reset_done.call()
	feed.call("open", int((ctl.countdown_s + 0.3) * 60.0))
	feed.call("fist", 45)
	game.ws.ack.emit(be.last_rid(), true, {"command": "easy_grab", "grab_id": "d"})
	be.report("AUTO_GRAB", "d")
	feed.call("fist", 6)
	var mid: bool = e.state == "AUTO_GRAB"
	var stops_before = be.names().count("soft_stop")
	game.show_title()
	feed.call("fist", 6)
	var esc_stops: bool = mid and e.state == "OFF" and be.names().count("soft_stop") == stops_before + 1 \
		and game.gesture.claw_enabled and not game.gesture.xy_only
	# --- hard: as before (fist closes, peace opens, palm down steers Z), and nothing of the easy mode
	be.report("MANUAL_XY", "d", {"last_result": "fault"})
	game._unhandled_input(_key(KEY_3))
	ctl.set_difficulty("hard")
	game._unhandled_input(_key(KEY_ENTER))
	feed.call("open", int((ctl.countdown_s + 0.3) * 60.0))
	var n_sent = be.sent.size()
	claws.clear()
	feed.call("fist", 30)
	feed.call("open", 6)
	feed.call("peace", 30)
	feed.call("open", 6)
	feed.call("point", 60)
	feed.call("open", 6)
	feed.call("open", 4, true, 0.5, {"palm": "down"})
	var z_mode: bool = game.gesture.mode == "z"
	feed.call("open", 6)
	ctl.easy_hud._process(0.016)
	_ok(esc_stops and ctl.difficulty == "hard" and ctl.phase == "PLAYING" and claws == ["closed", "open"] and z_mode
		and be.sent.size() == n_sent and not e.enabled() and not ctl.easy_hud.showing(),
		"easy mode in the game: Esc in the middle of a catch stops the backend's run; hard is as it was (fist closes, peace opens, palm down = Z, the fingers carry nothing)",
		"%s %s %s %s %s %s" % [esc_stops, ctl.difficulty, ctl.phase, claws, z_mode, be.sent.size() - n_sent])
	# the practice shows the difficulty that is played
	var easy_steps := GestureTutorialSteps.resolve({}, "easy", "pinch_joystick", PinchJoystickScheme.new().claw_poses()).map(func(s): return s.id)
	_ok(easy_steps.has("easy_one") and not easy_steps.has("easy_two") and CalibrationPanel.easy_state({"dials": {"profile": "dry_run"}}).state == "na"
		and CalibrationPanel.easy_state({"dials": {"profile": "real", "dial_1": [1, 2]}}).text.contains("キャッチの高さ")
		and CalibrationPanel.easy_state({"dials": {"profile": "real", "dial_1": [1, 2], "release_z": 60.0, "catch_z": 20.0, "confirmed": false}}).text.contains("確かめた")
		and CalibrationPanel.easy_state({"dials": {"profile": "real", "dial_1": [1, 2], "release_z": 60.0, "catch_z": 20.0, "stale_z": true}}).text.contains("測り直した")
		and CalibrationPanel.easy_state({"dials": {"profile": "real", "dial_1": [1, 2], "release_z": 60.0, "catch_z": 20.0, "confirmed": true}, "problems": []}).state == "ok"
		and CalibrationPanel.easy_text({"dials": {"profile": "real", "dial_1": [1, 2], "release_z": 60.0, "catch_z": 20.0, "confirmed": true,
			"saved_at": "2026-11-17T10:00:00"}, "problems": []}).contains("2026-11-17 10:00:00 に記録した値")
		and not CalibrationPanel.easy_text({"dials": {"profile": "real", "dial_1": [1, 2], "release_z": 60.0, "catch_z": 20.0}}).contains("Dial 2")
		and CalibrationPanel.EASY_VALUES.map(func(v): return v[0]) == ["dial_1", "catch_z", "release_z"]
		and CalibrationPanel.easy_state({"dials": {"profile": "real"}}).state == "na",
		"easy mode: the practice has the one carry (no Dial 2, #200); the 校正 tab asks for Dial 1 only and says what of the drop points is missing, unconfirmed or done", str(easy_steps))
	RobotState.easy_mode = {}
	RobotState.source = "mock"
	RobotState.connected = false
	RobotState.motors_enabled = false
	RobotState.homed = false
	_gm_free(game, rs)

## #149: the practice's steps as data, and each step ended only by what the hand really did.
func _test_gesture_tutorial_logic() -> void:
	var pinch_claw := PinchJoystickScheme.new().claw_poses()
	var pose_claw := PoseDirectionScheme.new().claw_poses()
	var hard := GestureTutorialSteps.resolve({}, "hard", "pinch_joystick", pinch_claw)
	var ids := hard.map(func(s): return s.id)
	var pose_steps := GestureTutorialSteps.resolve({}, "hard", "pose_direction", pose_claw)
	var pose_grab: Dictionary = pose_steps.filter(func(s): return s.kind == "grab")[0]
	var easy := GestureTutorialSteps.resolve({}, "easy", "pinch_joystick", pinch_claw)
	var changed := GestureTutorialSteps.resolve({"steps": {"open": {"title": "X", "hold_s": 2.0}}, "modes": {"hard": {"pinch_joystick": ["open", "practice"]}}},
		"hard", "pinch_joystick", pinch_claw)
	# (the tests below go through the steps with short holds; the real ones take about 3 s, #171)
	var quick := GestureTutorialSteps.resolve({"steps": {"open": {"hold_s": 0.6}, "pinch": {"hold_s": 0.5}, "move": {"move_s": 0.5}},
		"modes": {"hard": {"pinch_joystick": ["summon", "open", "pinch", "move", "grab", "rules", "practice"]}}}, "hard", "pinch_joystick", pinch_claw)
	var by_id := {}
	for s in hard:
		by_id[s.id] = s
	_ok(ids == ["summon", "open", "pinch", "move", "grab", "release", "z_pinch", "z_move", "rules", "practice"] and GestureTutorialSteps.counted(hard) == 9
		and is_equal_approx(float(by_id.open.hold_s), 3.0) and is_equal_approx(float(by_id.pinch.hold_s), 3.0) and is_equal_approx(float(by_id.move.move_s), 3.0)
		and by_id.release.title == "チョキで はなす！" and by_id.release.poses == ["peace"] and by_id.z_pinch.palm == "down" and by_id.z_move.axis == "z"
		and (by_id.grab.hints as Array).is_empty() and pose_steps.filter(func(s): return s.id == "release")[0].title == "パーで はなす！"
		and GestureTutorialSteps.number_of(hard, 0) == 0 and GestureTutorialSteps.number_of(hard, 2) == 2
		and str(hard[0].title).contains("ベントラベントラスペースピープル") and (hard[0].say as Array)[0] == "ベントラベントラスペースピープル！"
		and hard[4].title == "グーで キャッチ！" and "fist" in hard[4].poses and not "peace" in hard[4].poses
		and pose_steps.map(func(s): return s.id) == ["summon", "open", "point", "point_move", "grab", "release", "rules", "practice"]
		and pose_grab.title == "チョキで キャッチ！" and pose_grab.poses == ["peace"],
		"tutorial steps: the spell, パー, the pinch, moving, the catch, the rule, one capsule; the catch asks for the shape that closes the claw in the hand scheme in use",
		"%s %s %s" % [ids, hard[4].poses, pose_grab.poses])
	var easy_own := easy.filter(func(s): return str(s.id).begins_with("easy_"))
	_ok(easy_own.map(func(s): return s.id) == ["easy_grab", "easy_one"] and easy_own[1].poses == ["point"] and str(easy_own[1].title).contains("ポータル")
		and easy.filter(func(s): return bool(s.get("future", false))).is_empty() and hard.filter(func(s): return bool(s.get("future", false))).is_empty()
		and changed.map(func(s): return s.id) == ["open", "practice"] and changed[0].title == "X" and is_equal_approx(float(changed[0].hold_s), 2.0),
		"tutorial steps: the easy mode teaches the fist and one finger (the left portal; no two fingers, #200), none marked as not built; config overrides a step and the order",
		str(easy.map(func(s): return s.id)))
	# --- the steps, one by one
	var t := GestureTutorialController.new()
	var oks := []
	var ends := []
	var said := []
	t.step_succeeded.connect(func(_i, s): oks.append(s.id))
	t.finished.connect(func(how): ends.append(how))
	t.say.connect(func(lines): said.append(lines))
	t.begin(quick, true)
	var spell_telling := t.telling()
	_tut_run(t, 6.0, _tut_hand({"pose": "open"}), {"speech_busy": true})
	var spell_waits := t.kind() == "summon"
	_tut_run(t, 0.1, _tut_hand(), {"speech_busy": false})
	var never := GestureTutorialController.new()
	never.begin(quick, true)
	_tut_run(never, never.tell_max_s + 0.1, _tut_hand(), {"speech_busy": true})  # a voice that never ends
	_ok(spell_telling and spell_waits and t.kind() == "pose" and oks.is_empty() and said.size() == 2 and never.kind() == "pose",
		"tutorial: the spell is said to the end and goes on by itself, with no OK (nothing was done yet); a voice that never ends is not waited for for ever", "%s %s" % [t.kind(), oks])
	# パー: lost, stale, flickering, then held
	_tut_run(t, 1.3, _tut_hand({"detected": false}))
	var lost_guide := t.guide
	_tut_run(t, 1.8, _tut_hand({"fresh": false}))
	var stale_guide := t.guide
	for i in 6:  # the shape flickers: never long enough
		_tut_run(t, 0.3, _tut_hand({"pose": "open"}))
		_tut_run(t, 0.3, _tut_hand({"pose": "other"}))
	var flicker_ok := oks.is_empty()
	_tut_run(t, 0.3, _tut_hand({"pose": "open"}))
	_tut_run(t, 0.1, _tut_hand({"pose": "other"}))  # a gap shorter than the grace
	_tut_run(t, 0.4, _tut_hand({"pose": "open"}))
	var open_ok := oks == ["open"] and t.state == "success"
	_tut_run(t, 1.0, _tut_hand({"pose": "open"}))  # still held while the OK shows: no second OK
	_ok(lost_guide == "てを カメラに みせてね" and stale_guide.contains("てのカメラが みつからない") and flicker_ok and open_ok and oks == ["open"],
		"tutorial パー: a lost hand and a lost camera are said kindly, a flickering shape does not count, a held one gets one OK",
		"%s | %s | %s" % [lost_guide, stale_guide, oks])
	_tut_run(t, 0.6, _tut_hand())
	# the pinch: the index finger's
	_tut_run(t, 1.5, _tut_hand({"pinch": true, "pinch_finger": "middle"}))
	var wrong_finger := oks.size() == 1 and t.guide.contains("ひとさしゆび")
	_tut_run(t, 0.7, _tut_hand({"pinch": true, "pinch_finger": "index"}))
	_ok(wrong_finger and oks == ["open", "pinch"], "tutorial pinch: the middle finger's pinch is not it, the index finger's held is", str(oks))
	_tut_run(t, 1.5, _tut_hand({"pinch": true, "pinch_finger": "index"}))
	# moving, the robot may be moved: only really steering counts
	_tut_run(t, 2.0, _tut_hand({"pinch": true, "pinch_finger": "index", "pos": Vector2(0.9, 0.2)}))  # a pinch far away, not steering
	var not_steering := oks.size() == 2 and not t.hand_only
	_tut_run(t, 2.0, _tut_hand({"pinch": true, "active": true, "speed": 0.1}))  # steering, but hardly
	var too_slow := oks.size() == 2
	_tut_run(t, 0.6, _tut_hand({"pinch": true, "active": true, "speed": 0.6}))
	_ok(not_steering and too_slow and oks == ["open", "pinch", "move"],
		"tutorial move: with the robot ready only the hand stick really steering counts (not the hand's place, not a crawl)", str(oks))
	_tut_run(t, 1.5, _tut_hand())
	# the catch, the robot may be moved: the claw's own request
	t.on_claw("open")
	_tut_run(t, 2.0, _tut_hand({"pose": "fist", "claw_progress": 1.0}))
	var held_only := oks.size() == 3 and t.guide.contains("パーに もどして")
	t.on_claw("closed")
	_tut_run(t, 0.1, _tut_hand({"pose": "fist"}))
	_ok(held_only and oks == ["open", "pinch", "move", "grab"],
		"tutorial catch: the shape alone is not it while the robot is ready; the hand control's request to close the claw is", str(oks))
	_tut_run(t, 1.5, _tut_hand())
	# the rule (told), then the capsule
	var rules_told := t.kind() == "info" and t.telling()
	_tut_run(t, 7.0, _tut_hand(), {"speech_busy": false})
	var at_practice := t.kind() == "practice" and oks.size() == 4
	_tut_run(t, 3.0, _tut_hand(), {"practice": "open", "devices_ok": false})
	var hub_guide := t.guide
	_tut_run(t, 1.0, _tut_hand(), {"practice": "fault", "devices_ok": true})
	var blocked := t.state == "blocked" and ends.is_empty()
	_tut_run(t, 30.0, _tut_hand(), {"practice": "fault", "devices_ok": true})
	var stays_blocked := t.state == "blocked" and ends.is_empty() and oks.size() == 4
	t.retry_step()
	_tut_run(t, 0.5, _tut_hand(), {"practice": "open", "devices_ok": true})
	var retried := t.state == "judging"
	_tut_run(t, 0.1, _tut_hand(), {"practice": "done", "devices_ok": true})
	var done_ok := oks.size() == 5 and ends.is_empty()
	_tut_run(t, 1.6, _tut_hand(), {"practice": "done", "devices_ok": true})
	_ok(rules_told and at_practice and hub_guide.contains("かかりの") and blocked and stays_blocked and retried and done_ok
		and ends == ["done"] and not t.active() and t.oks == 5,
		"tutorial capsule: a failed practice capsule never counts and never goes on by itself; a done one ends the practice",
		"%s %s %s %s %s" % [at_practice, blocked, stays_blocked, done_ok, ends])
	# --- the robot may not be moved: the hand alone, and the screen is told so
	var t2 := GestureTutorialController.new()
	var oks2 := []
	t2.step_succeeded.connect(func(_i, s): oks2.append(s.id))
	t2.begin(quick.filter(func(s): return s.id in ["move", "grab"]), true)
	var gate := {"gate": "実機のジェスチャー操作は無効"}
	_tut_run(t2, 1.0, _tut_hand(gate.merged({"pinch": true, "pos": Vector2(0.5, 0.5)})))
	for i in 60:  # a trembling hand: never far enough
		_tut_run(t2, 1.0 / 60.0, _tut_hand(gate.merged({"pinch": true, "pos": Vector2(0.5 + 0.03 * sin(i), 0.5)})))
	var tremble := oks2.is_empty() and t2.hand_only
	_tut_run(t2, 0.3, _tut_hand(gate.merged({"pinch": true, "pos": Vector2(0.68, 0.5)})))
	var not_at_once := oks2.is_empty() and t2.progress > 0.3  # carried there: the gauge fills while it is kept there
	_tut_run(t2, 0.4, _tut_hand(gate.merged({"pinch": true, "pos": Vector2(0.68, 0.5)})))
	var moved := not_at_once and oks2 == ["move"]
	_tut_run(t2, 1.5, _tut_hand(gate))
	_tut_run(t2, 0.3, _tut_hand(gate.merged({"pose": "fist"})))
	var too_short := oks2.size() == 1
	_tut_run(t2, 0.6, _tut_hand(gate.merged({"pose": "fist"})))
	_ok(tremble and moved and too_short and oks2 == ["move", "grab"] and t2.hand_only and t2.gate_note != "",
		"tutorial without the robot: the pinch carried across the picture and the held shape count (a tremble does not), and the step knows the robot is not moved",
		"%s %s" % [oks2, t2.gate_note])
	# --- no hand camera: the hand steps are told, not called done
	var t3 := GestureTutorialController.new()
	var oks3 := []
	t3.step_succeeded.connect(func(_i, s): oks3.append(s.id))
	t3.begin(hard, false)
	var told := true
	for i in 40:
		_tut_run(t3, 1.0, {"enabled": false}, {"speech_busy": false})
		if t3.kind() == "practice":
			break
		told = told and t3.telling()
	_ok(t3.kind() == "practice" and oks3.is_empty() and told and t3.no_hand,
		"tutorial with no hand camera: every hand step is shown and said as an explanation, none gets an OK", "%s %s" % [t3.kind(), oks3])
	# --- staff, and the scripted hand
	var t4 := GestureTutorialController.new()
	var ends4 := []
	var oks4 := []
	t4.finished.connect(func(how): ends4.append(how))
	t4.step_succeeded.connect(func(_i, s): oks4.append(s.id))
	t4.begin(hard, true)
	t4.skip_step()
	var skipped_to := t4.kind()
	t4.skip_all()
	var t5 := GestureTutorialController.new()
	var oks5 := []
	t5.step_succeeded.connect(func(_i, s): oks5.append(s.id))
	t5.begin(hard, true)
	var demo_hand_only := false
	for i in 60 * 120:
		if t5.kind() == "practice":
			break
		t5.tick(1.0 / 60.0, GestureTutorialController.demo_hand(t5.step(), t5.t), {"speech_busy": false})
		demo_hand_only = demo_hand_only or t5.hand_only
	_ok(skipped_to == "pose" and ends4 == ["skipped"] and oks4.is_empty() and not t4.active()
		and oks5 == ["open", "pinch", "move", "grab", "release", "z_pinch", "z_move"] and demo_hand_only,
		"tutorial: staff can go on or leave it out (no OK for a step not done); the scripted hand goes through the hand steps without the robot",
		"%s %s %s" % [skipped_to, ends4, oks5])

## #171: the gauges take about 3 s; letting go and the up / down mode have steps of their own.
## #183: the game mode's title by hand (open hand = start, one / two fingers = easy / hard), and today's best.
func _test_game_title_hand(rs: Node) -> void:
	var game = _gm_game()
	var ctl: GameModeController = game.game_mode
	ctl.ranking.path = ""
	game.show_title()
	game._unhandled_input(_key(KEY_2))
	var opened = ctl.active() and ctl.phase == "IDLE"
	var hand := func(pose: String) -> Dictionary: return {"fresh": true, "detected": true, "pose": pose}
	ctl.set_difficulty("easy")
	# the two fingers that chose the mode are still up: they do not switch the difficulty
	for i in 120:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("peace"))
	var carried_over = ctl.difficulty == "easy" and ctl.title_hand == ""
	ctl.tick_title_hand(1.0 / 60.0, hand.call("fist"))
	for i in 60:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("peace"))
	var to_hard = ctl.difficulty == "easy" and ctl.title_hand == ""  # #198: two fingers choose nothing
	for i in 60:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("point"))
	var to_easy = ctl.difficulty == "easy" and ctl.title_hand == ""
	ctl.set_difficulty("hard")
	for i in 60:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("point"))  # nor does one finger
	game._unhandled_input(_key(KEY_D))  # nor the D key
	to_easy = to_easy and ctl.difficulty == "hard"
	ctl.set_difficulty("easy")
	# the open hand: 3 s, shown filling; let go before that = nothing
	for i in 120:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("open"))
	var filling = ctl.title_hand == "start" and ctl.title_hand_progress > 0.6 and ctl.phase == "IDLE"
	ctl.tick_title_hand(1.0 / 60.0, {})
	var let_go = ctl.title_hand == "" and ctl.phase == "IDLE"
	for i in 185:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("open"))
	var started = ctl.phase in ["TUTORIAL", "COUNTDOWN"]
	for i in 240:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("point"))  # not on the title: the hand changes nothing
	var only_title = ctl.difficulty == "easy" and ctl.title_hand == ""
	_ok(opened and carried_over and to_hard and to_easy and filling and let_go and started and only_title,
		"game title (#183, #198): an open hand held 3 s starts (as Enter); one / two fingers and D choose no difficulty; nothing outside the title",
		"%s %s %s %s %s %s %s %s" % [opened, carried_over, to_hard, to_easy, filling, let_go, started, only_title])
	# left on the title and chosen again with two fingers: that shape does not switch it either
	ctl._halt("test")
	game.show_title()
	game._unhandled_input(_key(KEY_2))
	ctl.set_difficulty("easy")
	for i in 30:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("open"))  # armed, a start hold half done
	game.show_title()
	game._unhandled_input(_key(KEY_2))
	for i in 120:
		ctl.tick_title_hand(1.0 / 60.0, hand.call("peace"))
	_ok(ctl.phase == "IDLE" and ctl.difficulty == "easy" and ctl.title_hand == "" and ctl.title_hand_progress == 0.0,
		"game title (#183): every visit needs a fresh shape: back from the top menu with two fingers up, the difficulty stays", "%s %s" % [ctl.phase, ctl.difficulty])
	# today's best: of the ranking's records of today and of rounds that did not get in
	ctl._halt("test")
	var none = ctl.today_best() == 0
	var d := Time.get_date_string_from_system()
	ctl.ranking.entries.assign([{"score": 9000, "timestamp": "2001-01-01T10:00:00", "id": "old"}, {"score": 700, "timestamp": d + "T09:00:00", "id": "a"}])
	var from_board = ctl.today_best() == 700
	ctl._note_today(450)
	var lower_kept = ctl.today_best() == 700
	ctl._note_today(1200)
	_ok(none and from_board and lower_kept and ctl.today_best() == 1200,
		"game title (#183): today's best is the best of today's records and of today's rounds, not an older day's", str(ctl.today_best()))
	ctl.ranking.entries.clear()
	_gm_free(game, rs)

## #183: the easy practice's fist step closes the claw as a show, the next step opens it again.
func _test_tutorial_claw_demo(rs: Node) -> void:
	var claw := PinchJoystickScheme.new().claw_poses()
	var easy = GestureTutorialSteps.resolve({}, "easy", "pinch_joystick", claw)
	var hard = GestureTutorialSteps.resolve({}, "hard", "pinch_joystick", claw)
	var only_easy = easy.filter(func(s): return bool(s.get("claw_demo", false))).map(func(s): return s.id) == ["easy_grab"] \
		and hard.filter(func(s): return bool(s.get("claw_demo", false))).is_empty()
	var game = _gm_game()
	var ctl: GameModeController = game.game_mode
	var asked = []
	ctl.tutorial_claw.connect(func(w): asked.append(w))
	var gotos = []
	ctl.tutorial_goto.connect(func(d): gotos.append(d))
	for st in easy:
		if st.id == "easy_one":
			ctl._on_tutorial_ok(0, st)
	var hard_gotos = hard.filter(func(s): return int(s.get("goto_demo", 0)) != 0).is_empty()
	ctl._on_tutorial_ok(0, {"goto_demo": 2})  # (an older config's step for Dial 2: nothing is asked)
	_ok(gotos == [1] and hard_gotos, "tutorial carry (#183): the easy finger step asks for the arm over Dial 1 (there is no Dial 2, #200); the hard mode's ask nothing", str(gotos))
	game.mock.arm_marks = {"open": 10.0, "closed": 120.0}
	game.mock.arm_deg = 10.0
	var grab = easy.filter(func(s): return s.id == "easy_grab")[0]
	ctl._on_tutorial_ok(0, {"id": "open", "kind": "pose"})
	var none_yet = asked.is_empty()
	ctl._on_tutorial_ok(1, grab)
	var closed = asked == ["closed"] and is_equal_approx(game.mock.arm_deg, 120.0)
	ctl._on_tutorial_step(2, {"id": "easy_one", "kind": "pose"})
	ctl._on_tutorial_step(3, {"id": "rules", "kind": "info"})
	var kept = asked == ["closed"]  # it stays closed through the carry's steps
	ctl._on_tutorial_step(4, {"id": "practice", "kind": "practice"})
	var opened = kept and asked == ["closed", "open"] and is_equal_approx(game.mock.arm_deg, 10.0)
	ctl._on_tutorial_step(5, {"id": "practice", "kind": "practice"})
	var once = asked.size() == 2
	# a stop after the claw closed: nothing more is asked of it
	ctl._on_tutorial_ok(1, grab)
	ctl._halt("test")
	ctl._on_tutorial_step(2, {"id": "practice", "kind": "practice"})
	var stopped = asked == ["closed", "open", "closed"]
	_ok(only_easy and none_yet and closed and opened and once and stopped,
		"tutorial claw (#183): the easy fist step closes the claw (the main scene's own request), the practice capsule's start opens it once; not after a stop; the hard mode's steps ask nothing",
		"%s %s %s %s %s %s %s" % [only_easy, none_yet, closed, opened, once, stopped, asked])
	# #185: the "touch the fingers" step moves nothing; the moving step does
	ctl.open()
	ctl.set_difficulty("easy")
	ctl.start_tutorial()
	var seen := {}
	for i in 12:
		seen[ctl.tutorial.kind()] = ctl.hand_holds_still()
		ctl.tutorial.skip_step()
		if not ctl.tutorial.active():
			break
	ctl._halt("test")
	_ok(seen.get("pinch", false) == true and seen.get("move", true) == false and seen.get("pose", true) == false and not ctl.hand_holds_still(),
		"tutorial (#185): the hand stick moves nothing in the practice's pinch step (only there)", str(seen))
	# the hand camera's picture beside the hand: only in a judged hand step with a camera picture
	var hud: GestureTutorialHud = ctl.tutorial_hud
	var attached = hud._cam != null and hud._cam_overlay.gesture == game.gesture
	var no_feed = not hud.camera_rect().has_area()
	_ok(attached and no_feed, "tutorial camera (#183): the practice has the hand camera's view attached; without a camera picture nothing is shown and the hand stays in the middle",
		"%s %s" % [attached, no_feed])
	_gm_free(game, rs)

## #179: the moving step says its own words when it is done, and the next step waits for them.
func _test_gesture_tutorial_done_say() -> void:
	var claw := PinchJoystickScheme.new().claw_poses()
	var moving = {"pinch": true, "active": true, "speed": 0.6}
	for mode in ["hard", "easy"]:
		var all = GestureTutorialSteps.resolve({}, mode, "pinch_joystick", claw)
		var steps = all.filter(func(s): return s.id in ["move", "rules"])
		var said = []
		var t = GestureTutorialController.new()
		t.say.connect(func(lines): said.append(lines))
		t.begin(steps, true)
		_tut_run(t, 2.5, _tut_hand(moving))
		var before = said.size() == 1 and t.state == "judging"
		_tut_run(t, 0.7, _tut_hand(moving))
		var done = t.state == "success" and said.size() == 2
		var words = "".join(said[1]) if said.size() > 1 else ""
		_ok(before and done and words.contains("こころが つながったよ") and words.contains("ベントラベントラスペースピープル") and words.contains("ハンドパワー"),
			"tutorial done_say (%s): moving the hand says the heart is linked, the spell and the hand power" % mode, words)
		# while the voice is busy the next step does not start (its line would cut this one off)...
		_tut_run(t, 4.0, _tut_hand(moving), {"speech_busy": true})
		var waits = t.state == "success" and t.index == 0
		_tut_run(t, 0.1, _tut_hand(moving), {"speech_busy": false})
		_ok(waits and t.index == 1, "tutorial done_say (%s): the next step waits for the words" % mode, "%s %d" % [t.state, t.index])
	# ...but never for long: a voice that never ends does not hold the practice
	var t2 = GestureTutorialController.new()
	t2.begin(GestureTutorialSteps.resolve({}, "easy", "pinch_joystick", claw).filter(func(s): return s.id in ["move", "rules"]), true)
	_tut_run(t2, 3.2, _tut_hand(moving))
	_tut_run(t2, t2.ok_s + t2.tell_max_s + 0.5, _tut_hand(moving), {"speech_busy": true})
	_ok(t2.index == 1, "tutorial done_say: a voice that never ends does not hold the practice", str(t2.index))
	# a step without done_say goes on after the OK alone, as before
	var t3 = GestureTutorialController.new()
	t3.begin(GestureTutorialSteps.resolve({}, "easy", "pinch_joystick", claw).filter(func(s): return s.id in ["open", "rules"]), true)
	_tut_run(t3, 3.2, _tut_hand({"pose": "open"}))
	_tut_run(t3, t3.ok_s + 0.2, _tut_hand({"pose": "open"}), {"speech_busy": true})
	_ok(t3.index == 1, "tutorial done_say: a step without it does not wait", str(t3.index))

func _test_gesture_tutorial_more_steps() -> void:
	var claw := PinchJoystickScheme.new().claw_poses()
	var hard = GestureTutorialSteps.resolve({}, "hard", "pinch_joystick", claw)
	var pick := func(ids: Array) -> Array: return hard.filter(func(s): return s.id in ids)
	var oks = []
	var t := GestureTutorialController.new()
	t.step_succeeded.connect(func(_i, s): oks.append(s.id))
	# パー, the pinch, moving: the gauge fills in about 3 s, not at once
	t.begin(pick.call(["open", "pinch", "move"]), true)
	_tut_run(t, 2.5, _tut_hand({"pose": "open"}))
	var half = oks.is_empty() and t.progress > 0.7 and t.progress < 0.95
	_tut_run(t, 0.7, _tut_hand({"pose": "open"}))
	var open_done = oks == ["open"]
	_tut_run(t, 1.6, _tut_hand())
	_tut_run(t, 2.5, _tut_hand({"pinch": true, "pinch_finger": "index"}))
	var pinch_half = oks.size() == 1
	_tut_run(t, 0.7, _tut_hand({"pinch": true, "pinch_finger": "index"}))
	_tut_run(t, 1.6, _tut_hand({"pinch": true, "pinch_finger": "index"}))
	_tut_run(t, 2.5, _tut_hand({"pinch": true, "active": true, "speed": 0.6}))
	var move_half = oks == ["open", "pinch"]
	_tut_run(t, 0.7, _tut_hand({"pinch": true, "active": true, "speed": 0.6}))
	# the gauge is heard filling (#179): blips while it grows, higher as it fills, none while it stands
	var gg := _gm_game()
	var gc: GameModeController = gg.game_mode
	gc.sounds.enabled = true
	gc.tutorial.steps = pick.call(["open"])
	gc.tutorial.index = 0
	gc.tutorial.state = "judging"
	gc.tutorial.progress = 0.0
	gc._tick_gauge_sound(0.2)
	var silent_at_rest = gc.sounds.gauge_blips == 0
	var pitches := []
	for i in 30:
		gc.tutorial.progress = (i + 1) / 31.0
		gc._tick_gauge_sound(1.0 / 60.0)
		if gc.sounds.last_played == "gauge":
			pitches.append(gc.sounds.last_pitch)
	var blips = gc.sounds.gauge_blips
	gc._tick_gauge_sound(0.5)  # the gauge stands
	gc._tick_gauge_sound(0.5)
	gc.tutorial.progress = 1.0
	gc._tick_gauge_sound(0.5)  # full: the OK's chime, not a blip
	var gauge_ok = silent_at_rest and blips >= 3 and blips <= 5 and gc.sounds.gauge_blips == blips \
		and pitches[-1] > pitches[0] and not gc.sounds.log.has("gauge")
	_gm_free(gg, RobotState)
	_ok(gauge_ok, "tutorial gauge: it is heard filling (a blip every moment it grows, higher as it fills), silent while it stands and when it is full",
		"%s %s %s" % [silent_at_rest, blips, pitches])
	_ok(half and open_done and pinch_half and move_half and oks == ["open", "pinch", "move"],
		"tutorial gauges: パー, the pinch and moving each take about 3 s of really doing it before the OK", "%s %s %s %s %s" % [half, open_done, pinch_half, move_half, oks])
	# letting go: the claw's own request to open (not the one to close, not the shape alone)
	var t2 := GestureTutorialController.new()
	var oks2 = []
	t2.step_succeeded.connect(func(_i, s): oks2.append(s.id))
	t2.begin(pick.call(["grab", "release"]), true)
	t2.on_claw("closed")
	_tut_run(t2, 1.0, _tut_hand({"pose": "fist"}))
	_tut_run(t2, 1.6, _tut_hand())
	var at_release = t2.step().id == "release" and oks2 == ["grab"]
	t2.on_claw("closed")
	_tut_run(t2, 2.0, _tut_hand({"pose": "peace", "claw_progress": 1.0}))
	var not_by_shape = oks2.size() == 1 and t2.guide.contains("かたちを かえて")
	t2.on_claw("open")
	_tut_run(t2, 0.1, _tut_hand({"pose": "peace"}))
	# without the robot: the shape that opens the claw, held
	var t3 := GestureTutorialController.new()
	var oks3 = []
	t3.step_succeeded.connect(func(_i, s): oks3.append(s.id))
	t3.begin(pick.call(["release"]), true)
	_tut_run(t3, 1.5, _tut_hand({"gate": "x", "pose": "fist"}))
	var fist_no = oks3.is_empty()
	_tut_run(t3, 1.0, _tut_hand({"gate": "x", "pose": "peace"}))
	_ok(at_release and not_by_shape and oks2 == ["grab", "release"] and fist_no and oks3 == ["release"] and t3.hand_only,
		"tutorial letting go: the hand control's request to open the claw ends it (closing does not, the shape alone does not while the robot is ready); without the robot the opening shape held",
		"%s %s %s %s %s" % [at_release, not_by_shape, oks2, fist_no, oks3])
	# the up / down mode: the back of the hand to the camera, pinch, then up or down
	var t4 := GestureTutorialController.new()
	var oks4 = []
	t4.step_succeeded.connect(func(_i, s): oks4.append(s.id))
	t4.begin(pick.call(["z_pinch", "z_move"]), true)
	_tut_run(t4, 4.0, _tut_hand({"pinch": true, "pinch_finger": "index", "palm": "up"}))
	var palm_up_no = oks4.is_empty() and t4.guide.contains("てのこう")
	_tut_run(t4, 3.2, _tut_hand({"pinch": true, "pinch_finger": "index", "palm": "down"}))
	var z_pinched = oks4 == ["z_pinch"]
	_tut_run(t4, 1.6, _tut_hand({"pinch": true, "palm": "down"}))
	_tut_run(t4, 4.0, _tut_hand({"pinch": true, "palm": "up", "active": true, "mode": "xy", "speed": 0.8}))
	var xy_no = oks4.size() == 1 and t4.guide.contains("てのこう")
	_tut_run(t4, 3.2, _tut_hand({"pinch": true, "palm": "down", "active": true, "mode": "z", "speed": 0.8}))
	var z_moved = oks4 == ["z_pinch", "z_move"]
	var t5 := GestureTutorialController.new()
	var oks5 = []
	t5.step_succeeded.connect(func(_i, s): oks5.append(s.id))
	t5.begin(pick.call(["z_move"]), true)
	_tut_run(t5, 0.9, _tut_hand({"gate": "x", "pinch": true, "palm": "down", "pos": Vector2(0.5, 0.5)}))
	_tut_run(t5, 4.0, _tut_hand({"gate": "x", "pinch": true, "palm": "down", "pos": Vector2(0.8, 0.5)}))  # sideways: not up / down
	var sideways_no = oks5.is_empty()
	_tut_run(t5, 3.2, _tut_hand({"gate": "x", "pinch": true, "palm": "down", "pos": Vector2(0.8, 0.3)}))
	_ok(palm_up_no and z_pinched and xy_no and z_moved and sideways_no and oks5 == ["z_move"],
		"tutorial up / down: a pinch with the palm to the camera is not it, with the back of the hand it is; then only the up / down steer counts (without the robot: the pinch carried up or down, not sideways)",
		"%s %s %s %s %s %s" % [palm_up_no, z_pinched, xy_no, z_moved, sideways_no, oks5])

## #149 in the game: Enter goes through the practice, the practice capsule is a real
## transaction of the Dial, nothing of it reaches the round, the stops stay.
func _test_gesture_tutorial_game(rs: Node) -> void:
	var game := _gm_game()
	var ctl: GameModeController = game.game_mode
	ctl.tutorial_auto = true
	ctl.sounds.log.clear()
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	var mock_before: Vector3 = game.mock.target
	game._unhandled_input(_key(KEY_ENTER))
	var in_tutorial := ctl.phase == "TUTORIAL" and ctl.tutorial.kind() == "summon" and ctl.running()
	ctl.demo = true  # the scripted hand (given to the practice only)
	_gm_step(ctl, 2.0)
	game._unhandled_input(_key(KEY_ENTER))  # Enter in the practice: nothing
	var enter_nothing := ctl.phase == "TUTORIAL" and ctl.tutorial.kind() == "summon"
	var hud_on := ctl.tutorial_hud.showing() and ctl.hud.title_showing() == false
	for i in 60 * 150:
		if ctl.tutorial.kind() == "practice":
			break
		ctl.tick(1.0 / 60.0)
	ctl.demo = false
	var oks_before := ctl.sounds.log.count("tutorial_ok")
	_ok(in_tutorial and enter_nothing and hud_on and ctl.tutorial.kind() == "practice" and oks_before == 7
		and ctl.sounds.log.has("summon") and is_equal_approx(ctl.time_left, ctl.duration_s) and ctl.score.score == 0
		and game.mock.target == mock_before and ctl.tutorial_hud.progress_text() == "れんしゅう 9 / 9",
		"tutorial in the game: Enter on the score game's title goes into the practice, not the countdown; the clock stands, Enter skips nothing, each hand step chimes once, the scripted hand moves no robot",
		"%s %s %s %s %.1f" % [ctl.phase, ctl.tutorial.kind(), oks_before, ctl.tutorial_hud.progress_text(), ctl.time_left])
	# the practice capsule: a real transaction of the Dial
	_gm_step(ctl, 0.5)
	var left: GameModeController.Lane = ctl.lanes["left"]
	var armed := ctl.practice == "open" and left.state == "READY" and _gm_sent(ctl.mock_hub, GM_R) == 0
	var n0 := ctl.mock_hub.executed.size()
	game._unhandled_input(_key(KEY_F8))  # staff may leave it out now (no capsule on its way)...
	var closing_first := ctl.phase == "TUTORIAL" and ctl.practice == "closing"  # ...the Dial is closed first
	_gm_step(ctl, 2.0)
	var skipped_idle := closing_first and ctl.phase == "COUNTDOWN" \
		and ctl.mock_hub.executed.slice(n0).filter(func(e): return e[1] == "DISARM_RECEIVER").size() == 1
	ctl._halt("test")
	ctl.tutorial_seen = false
	game._unhandled_input(_key(KEY_ENTER))
	ctl.tutorial.skip_step()  # ...here: back to the practice capsule, by the steps
	while ctl.tutorial.kind() != "practice" and ctl.tutorial.active():
		ctl.tutorial.skip_step()
	_gm_step(ctl, 0.5)
	var chimes_before := ctl.sounds.log.count("tutorial_ok")
	var id := _gm_play_capsule(ctl, "center")
	var practice_score := ctl.score.score
	game._unhandled_input(_key(KEY_F8))  # a capsule is on its way: it is not left behind
	var skip_refused := ctl.phase == "TUTORIAL" and ctl.practice_busy()
	ctl.mock_hub.chatter(left.device, 2)  # the switch bounces
	for i in 60 * 12:  # the Dial's servo sequence, then its status
		if ctl.practice == "done":
			break
		ctl.tick(1.0 / 60.0)
	ctl.tick(1.0 / 60.0)
	var cycle := left.last_cycle
	var came_back := ctl.practice == "done" and left.state == "CLOSED" and ctl.practice_released == 1 \
		and ctl.mock_hub.executed.filter(func(e): return e[1] == "RELEASE_BALL").size() == 1
	var ok_shown := ctl.tutorial.state == "success" and ctl.sounds.log.count("tutorial_ok") == chimes_before + 1
	_gm_step(ctl, ctl.tutorial.ok_s + 0.1)
	_ok(armed and skipped_idle and id != "" and practice_score > 0 and skip_refused and came_back
		and ctl.phase == "COUNTDOWN" and ctl.score.score == 0 and ctl.capsules.finished.is_empty() and is_equal_approx(ctl.time_left, ctl.duration_s)
		and ctl.practice == "" and not ctl.tutorial.active() and ctl.tutorial_seen and left.last_cycle == cycle and cycle >= 1,
		"practice capsule: the Dial armed (Dial 2 is not asked for anything, #200), one capsule taken, played, released once and checked (a bouncing switch is not a second one); then the round starts from zero - no score, no capsule, the full clock",
		"%s %s %s score %d->%d %s %s" % [armed, skip_refused, came_back, practice_score, ctl.score.score, ctl.phase, ctl.practice])
	_ok(ok_shown, "practice capsule: its one OK chimes once", str(ctl.sounds.log.count("tutorial_ok")))
	_gm_step(ctl, ctl.countdown_s + 0.3)
	ctl._on_ball(left, cycle)  # the practice capsule reported once more, in the round
	var old_ignored := ctl.phase == "PLAYING" and left.state == "READY" and left.capsule.is_empty()
	var id2 := _gm_play_capsule(ctl, "center")
	_ok(old_ignored and id2 != "" and id2 != id and ctl.score.score > 0,
		"after the practice: a late report of the practice capsule is old in the round; a new capsule plays and scores", "%s %s" % [old_ignored, ctl.score.score])
	# after a round: Enter starts at once, T is the practice once more
	ctl._halt("test")
	game._unhandled_input(_key(KEY_ENTER))
	var straight := ctl.phase == "COUNTDOWN"
	ctl._halt("test")
	game._unhandled_input(_key(KEY_T))
	var again := ctl.phase == "TUTORIAL" and ctl.tutorial.kind() == "summon"
	# a failed practice capsule: no OK, no round
	while ctl.tutorial.kind() != "practice":
		ctl.tutorial.skip_step()
	_gm_step(ctl, 0.5)
	ctl.mock_hub.fail_release[left.device] = true
	_gm_play_capsule(ctl, "center")
	var chimes := ctl.sounds.log.count("tutorial_ok")
	_gm_step(ctl, 12.0)
	var failed := ctl.phase == "TUTORIAL" and ctl.practice == "fault" and ctl.tutorial.state == "blocked" and left.state == "FAULT" \
		and ctl.sounds.log.count("tutorial_ok") == chimes and ctl.tutorial.guide.contains("かかりの")
	_ok(straight and again and failed,
		"after a round Enter starts at once and T is the practice once more; a practice capsule that fails to come back gets no OK and no round starts",
		"%s %s %s %s %s" % [straight, again, ctl.phase, ctl.practice, ctl.tutorial.state])
	# Space in the practice: STOP_ALL, nothing afterwards
	ctl._halt("test")
	game._unhandled_input(_key(KEY_T))
	while ctl.tutorial.kind() != "practice":
		ctl.tutorial.skip_step()
	_gm_step(ctl, 0.5)
	ctl.mock_hub.fail_release.clear()
	ctl.mock_hub.mock_ball(left.device)
	_gm_step(ctl, 0.3)
	var n := ctl.mock_hub.executed.size()
	game._unhandled_input(_key(KEY_SPACE))
	var stops := ctl.mock_hub.executed.slice(n).filter(func(e): return e[1] == "STOP_ALL").size()
	_gm_step(ctl, 5.0)
	var releases_after := ctl.mock_hub.executed.slice(n).filter(func(e): return e[1] == "RELEASE_BALL").size()
	_ok(ctl.phase == "STOPPED" and stops >= 2 and releases_after == 0 and not ctl.tutorial.active() and ctl.practice == "" and left.state == "FAULT",
		"Space in the practice: STOP_ALL to the Dials, the practice ends, nothing is released afterwards", "%s %d %d %s" % [ctl.phase, stops, releases_after, left.state])
	# Esc from a hand step: the practice is gone, the title is back
	game._unhandled_input(_key(KEY_T))
	ctl.tutorial.skip_step()
	game.show_title()
	_ok(not ctl.active() and not ctl.tutorial.active() and not ctl.tutorial_hud.showing(),
		"Esc in the practice: back to the title, the practice is over", str(ctl.phase))
	_gm_free(game, rs)
