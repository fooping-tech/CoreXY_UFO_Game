extends "res://tests/test_base.gd"
## The hand: the joystick, the gesture states, the pose schemes, with the mock robot.

func _test_hand_joystick() -> void:
	var j := HandJoystick.new()
	j.smoothing_ms = 0.0
	j.set_anchor(Vector2(0.6, 0.5))
	var r := j.radius
	var dead := j.update(Vector2(0.6 + r * 0.1, 0.5), 0.05)
	var right := j.update(Vector2(0.6 + r * 0.5, 0.5), 0.05)
	var away := j.update(Vector2(0.6, 0.5 - r * 0.5), 0.05)  # hand moved up in the image
	var far := j.update(Vector2(0.6 + r * 3.0, 0.5), 0.05)
	var diag := j.update(Vector2(0.6 + r * 2.0, 0.5 - r * 2.0), 0.05)
	var back := j.update(Vector2(0.6, 0.5), 0.05)
	var mid := HandJoystick.shape(Vector2(r * 0.46, 0.0), r, 0.12, 0.8, 1.5).x  # half way between dead and full
	_ok(dead == Vector2.ZERO and right.x > 0.0 and is_zero_approx(right.y) and away.y > 0.0 and is_zero_approx(away.x)
		and is_equal_approx(far.x, j.max_speed) and diag.length() <= j.max_speed + 1e-3 and diag.x > 0.0 and diag.y > 0.0
		and back == Vector2.ZERO and is_equal_approx(mid, pow(0.5, 1.5)),
		"stick: dead zone, +X right, +Y away, curve, max speed, diagonal capped, centre stops",
		"%s %s %s %s %s %s mid %.3f" % [dead, right, away, far, diag, back, mid])
	j.invert_x = true
	j.swap_xy = true
	var swapped := j.update(Vector2(0.6 + r * 3.0, 0.5), 0.05)
	j.smoothing_ms = 80.0
	j.invert_x = false
	j.swap_xy = false
	j.set_anchor(Vector2(0.6, 0.5))
	var first := j.update(Vector2(0.6 + r * 3.0, 0.5), 1.0 / 60.0)
	_ok(is_equal_approx(swapped.y, j.max_speed) and is_zero_approx(swapped.x) and first.x > 0.0 and first.x < j.max_speed * 0.4,
		"stick: axes can be swapped / inverted; the output is smoothed", "%s %s" % [swapped, first])

func _test_gesture_states() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 100.0, "joystick": {"smoothing_ms": 0.0}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var dt := 1.0 / 60.0
	# one tick: the event (if any) arrives now, then the physics tick
	var step := func(ev: Dictionary, gate := "") -> Vector2:
		t[0] += dt * 1000.0
		if not ev.is_empty():
			seq[0] += 1
			ev["sequence"] = seq[0]
			g.on_event(ev, t[0])
		return g.tick(t[0], dt, gate)
	var hold := func(make: Callable, secs: float, gate := "") -> Vector2:
		var v := Vector2.ZERO
		for i in range(int(secs * 60.0)):
			v = step.call(make.call(), gate)
		return v
	var open_hand := func(): return _hev(0, true, false, 0.5, 0.5)
	var pinch_at := func(x: float, y: float): return func(): return _hev(0, true, true, x, y)

	step.call({})
	var waits := g.state == S.WAITING_HAND
	hold.call(open_hand, 0.1)
	var seen := g.state == S.HAND_DETECTED
	step.call(pinch_at.call(0.5, 0.5).call())
	var armed := g.state == S.ARMED and g.joystick.has_anchor
	hold.call(pinch_at.call(0.5, 0.5), 0.15)
	var active := g.state == S.ACTIVE and g.velocity == Vector2.ZERO  # anchor = where it pinched
	var v: Vector2 = hold.call(pinch_at.call(0.62, 0.5), 0.2)
	var moved := v.x > 0.0
	var released: Vector2 = step.call(open_hand.call())
	_ok(waits and seen and armed and active and moved and released == Vector2.ZERO and g.state == S.HAND_DETECTED and g.reason == "released",
		"gesture: hand -> pinch (anchor) -> ARMED -> ACTIVE moves; release = zero velocity",
		"%s %s %s %s %s %s %s" % [waits, seen, armed, active, moved, released, g.state_name()])

	# lost while steering: stops and stays stopped when the hand comes back still pinching
	hold.call(pinch_at.call(0.5, 0.5), 0.3)
	hold.call(pinch_at.call(0.62, 0.5), 0.1)
	var lost_v: Vector2 = step.call(_hev(0, false, false))
	var latched := g.state == S.WAITING_RELEASE and g.reason == "no_hand"
	var back_v: Vector2 = hold.call(pinch_at.call(0.62, 0.5), 0.5)
	var still_latched := g.state == S.WAITING_RELEASE and back_v == Vector2.ZERO
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	var new_anchor := g.state == S.ACTIVE and g.joystick.anchor.is_equal_approx(Vector2(0.3 * 640.0 / 480.0, 0.3)) and g.velocity == Vector2.ZERO
	_ok(lost_v == Vector2.ZERO and latched and still_latched and new_anchor,
		"gesture: losing the hand stops; it does not restart until released, a new pinch sets a new centre",
		"%s %s %s %s %s" % [lost_v, latched, still_latched, new_anchor, g.state_name()])

	# two hands
	hold.call(pinch_at.call(0.42, 0.3), 0.1)
	var two: Vector2 = step.call(_hev(0, false, true, 0.5, 0.5, {"hand_count": 2, "reason": "multiple_hands"}))
	_ok(two == Vector2.ZERO and g.state == S.WAITING_RELEASE and g.reason == "multiple_hands", "gesture: two hands stop it", g.state_name())

	# stale events: nothing for longer than stale_ms
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	hold.call(pinch_at.call(0.42, 0.3), 0.05)
	var moving_before := g.velocity.length() > 0.0
	for i in range(12):  # 200 ms without an event
		step.call({})
	var stale_stop := g.state == S.WAITING_RELEASE and g.reason == "stale" and g.velocity == Vector2.ZERO
	_ok(moving_before and stale_stop, "gesture: events older than stale_ms stop it", "%s %s %s" % [moving_before, g.state_name(), g.reason])

	# old / reordered events are dropped and cannot lift a stop
	var dropped0 := g.dropped
	t[0] += 16.0
	var accepted_old := g.on_event(_hev(1, true, false), t[0])  # sequence 1: long gone
	var dup := g.on_event(_hev(seq[0], true, false), t[0])
	g.tick(t[0], dt, "")
	_ok(not accepted_old and not dup and g.dropped == dropped0 + 2 and g.state == S.WAITING_RELEASE,
		"gesture: old and duplicate events are ignored (a stop stays latched)", "%s %s" % [g.dropped, g.state_name()])

	# camera lost
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	step.call(_hev(0, false, false, 0.5, 0.5, {"camera_ok": false, "reason": "camera_lost"}))
	_ok(g.state == S.WAITING_RELEASE and g.reason == "camera_lost", "gesture: a lost camera stops it", g.reason)

	# WebSocket gone and back: a new stream starting at 1 while still pinching does not restart it
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.reset_stream("ws_disconnect")
	var after_drop := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	seq[0] = 0
	var reconnect_v: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.5)
	_ok(after_drop and reconnect_v == Vector2.ZERO and g.state == S.WAITING_RELEASE,
		"gesture: a disconnect stops it; after reconnecting a held pinch does not restart it", "%s %s" % [reconnect_v, g.state_name()])

	# STOP (Space) and the keyboard: latched until a new pinch
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.stop("stop_key")
	var stop_v: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.3)
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	var again: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.2)
	_ok(stop_v == Vector2.ZERO and again.x > 0.0, "gesture: after STOP it needs a release and a new pinch", "%s %s" % [stop_v, again])
	var kb := ControlArbiter.decide(false, false, Vector3(40, 0, 0), Vector3(-20, 0, 0), true)
	var gs := ControlArbiter.decide(false, false, Vector3.ZERO, Vector3(-20, 5, 0), true)
	var halted := ControlArbiter.decide(true, false, Vector3(40, 0, 0), Vector3(-20, 0, 0), true)
	var latched_stop := ControlArbiter.decide(false, true, Vector3.ZERO, Vector3(-20, 0, 0), true)
	var idle := ControlArbiter.decide(false, false, Vector3.ZERO, Vector3(-20, 0, 0), false)
	_ok(kb.source == "keyboard" and kb.v == Vector3(40, 0, 0) and gs.source == "gesture" and halted.v == Vector3.ZERO
		and halted.source == "halt" and latched_stop.v == Vector3.ZERO and idle.v == Vector3.ZERO,
		"arbiter: alarm > STOP > keyboard > gesture, never both", "%s %s %s" % [kb, gs, halted])

	# not ready (e.g. not homed): a pinch does nothing, and it does not start once ready while held
	hold.call(open_hand, 0.05)
	var blocked: Vector2 = hold.call(pinch_at.call(0.3, 0.3), 0.3, "原点復帰（home）してください")
	var blocked_state := g.state == S.WAITING_RELEASE and g.reason == "原点復帰（home）してください"
	var ready_held: Vector2 = hold.call(pinch_at.call(0.45, 0.3), 0.3)
	var main_script: GDScript = load("res://scripts/game/main.gd")
	var not_homed: String = main_script.real_gesture_gate(true, true, "mock", false, true, false, false)
	var real_off: String = main_script.real_gesture_gate(true, true, "real", false, true, true, false)
	var real_on: String = main_script.real_gesture_gate(true, true, "real", true, true, true, false)
	var no_motors: String = main_script.real_gesture_gate(true, true, "mock", false, false, true, false)
	_ok(blocked == Vector2.ZERO and blocked_state and ready_held == Vector2.ZERO and not_homed.contains("原点復帰")
		and real_off.contains("allow_real_robot") and real_on == "" and no_motors.contains("モーター"),
		"gesture: refused before homing / motors / on the real robot unless allowed; no start while held",
		"%s %s %s | %s | %s | %s" % [blocked, g.state_name(), ready_held, not_homed, real_off, no_motors])

	# gesture mode off
	hold.call(open_hand, 0.05)
	hold.call(pinch_at.call(0.3, 0.3), 0.3)
	g.enabled = false
	var off_v: Vector2 = hold.call(pinch_at.call(0.5, 0.3), 0.2)
	_ok(off_v == Vector2.ZERO and g.state == S.DISABLED, "gesture: switching the mode off stops it", g.state_name())

	# operating region (ROI) on the game side
	g.enabled = true
	g.roi_enabled = true
	g.roi = Rect2(0.0, 0.0, 0.5, 1.0)
	hold.call(func(): return _hev(0, true, false, 0.8, 0.5), 0.1)
	_ok(not g.detected and g.state == S.WAITING_HAND and g.reason == "outside_roi", "gesture: a hand outside the ROI is ignored", g.reason)
	# where in the view: near an edge while seen, "left the view" when it vanishes from there
	var e1 := GestureControl.edge_of(Vector2(0.95, 0.5), 0.1)
	var e2 := GestureControl.edge_of(Vector2(0.05, 0.02), 0.1)
	var e3 := GestureControl.edge_of(Vector2(0.5, 0.5), 0.1)
	g.roi_enabled = false
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	var mid_ok := g.edge == Vector2.ZERO and not g.left_view
	hold.call(func(): return _hev(0, true, false, 0.95, 0.5), 0.05)
	var near_ok := g.edge == Vector2(1, 0)
	step.call(_hev(0, false, false))
	var out_ok := g.left_view and g.last_seen.is_equal_approx(Vector2(0.95, 0.5))
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	var back_ok := not g.left_view and g.edge == Vector2.ZERO
	hold.call(func(): return _hev(0, true, false, 0.5, 0.5), 0.05)
	step.call(_hev(0, false, false))
	var middle_loss := not g.left_view  # vanished in the middle: not "out of the view"
	_ok(e1 == Vector2(1, 0) and e2 == Vector2(-1, -1) and e3 == Vector2.ZERO and mid_ok and near_ok and out_ok and back_ok and middle_loss,
		"gesture: knows when the hand is near the frame edge and when it left the view there",
		"%s %s %s | %s %s %s %s %s" % [e1, e2, e3, mid_ok, near_ok, out_ok, back_ok, middle_loss])
	# the HUD ring shows the hand like the (flipped) camera view does
	var gv := GestureControl.new()
	gv.joystick.set_anchor(Vector2(0.5, 0.5))
	gv.detected = true
	gv.hand = Vector2(0.5 + gv.joystick.radius * 0.5, 0.5 - gv.joystick.radius * 0.5)  # right and up in the image
	var plain := GestureHud.view_offset(gv, false, false)
	var turned := GestureHud.view_offset(gv, true, true)
	_ok(plain.is_equal_approx(Vector2(0.5, -0.5)) and turned.is_equal_approx(Vector2(-0.5, 0.5)),
		"gesture HUD: the ring follows the camera view's flips", "%s %s" % [plain, turned])
	_ok(GestureHud.direction_text(Vector2(20, 15)) == "右奥へ移動" and GestureHud.direction_text(Vector2(-20, 0)) == "左へ移動"
		and GestureHud.direction_text(Vector2(0, -20)) == "手前へ移動" and GestureHud.direction_text(Vector2.ZERO) == "",
		"gesture HUD: direction words")

func _test_gesture_with_mock_robot(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.gesture_require_focus = false
	game.set_gesture_enabled(true)
	game.gesture.joystick.smoothing_ms = 0.0
	game.gesture.arm_delay_ms = 0.0  # real-time delays: this loop runs in a few ms
	game.gesture.joystick.invert_x = false  # the config holds the real camera's calibration
	game.gesture.joystick.invert_y = false
	game.gesture.joystick.swap_xy = false
	var start: Vector3 = game.mock.target
	var dt := 1.0 / 60.0
	var seq := [0]  # lambdas capture ints by value
	var feed := func(ev: Dictionary) -> void:
		seq[0] += 1
		ev["sequence"] = seq[0]
		game.gesture.on_event(ev, float(Time.get_ticks_msec()))
		game._handle_input(dt)
	for i in range(6):
		feed.call(_hev(0, true, false, 0.5, 0.5))
	for i in range(15):
		feed.call(_hev(0, true, true, 0.5, 0.5))
	for i in range(30):
		feed.call(_hev(0, true, true, 0.65, 0.5))
	var moved: Vector3 = game.mock.target - start
	var src: String = game.control_source
	var pinch_cue: String = game.sfx.last_cue
	feed.call(_hev(0, true, false, 0.65, 0.5))
	var after_release: Vector3 = game.mock.target
	var release_cue: String = game.sfx.last_cue
	for i in range(10):
		feed.call(_hev(0, true, false, 0.65, 0.5))
	_ok(moved.x > 5.0 and absf(moved.y) < 1e-3 and src == "gesture" and game.mock.target == after_release,
		"gesture + MockRobot: steering right moves the mock target +X; releasing stops it", "%s %s" % [moved, src])
	for i in range(15):
		feed.call(_hev(0, true, true, 0.5, 0.5))
	feed.call(_hev(0, false, false))  # the hand vanishes while steering
	var lost_cue: String = game.sfx.last_cue
	var blips: AudioStreamWAV = game.sfx.cue_stream("lost")  # synthesised (the hand, the pinch and the release are files, #321 / #332)
	var log_: Array[String] = game.sfx.cue_log
	var first_hand := log_.find("hand")
	_ok(first_hand >= 0 and log_.find("pinch") > first_hand and pinch_cue == "pinch" and release_cue == "release" and lost_cue == "lost"
		and blips != null and blips.data.size() > 4000 and game.sfx.cue_stream("hand") != null and game.sfx.cue_stream("release") != null,
		"gesture sound: hand seen, pinch caught, fingers opened, control cut - each its own sound",
		"%s | %s %s %s" % [log_, pinch_cue, release_cue, lost_cue])
	# #321: the open hand / the pinch are 効果音ラボ's 決定ボタンを押す 1 / 3 (config audio.cue_hand / cue_pinch)
	var hand_snd = game.sfx.cue_stream("hand")
	var pinch_snd = game.sfx.cue_stream("pinch")
	_ok(hand_snd is AudioStreamMP3 and pinch_snd is AudioStreamMP3 and not hand_snd.loop and not pinch_snd.loop
		and str(GameConfig.get_value("audio", "cue_hand", "")) == "decide-button1.mp3"
		and str(GameConfig.get_value("audio", "cue_pinch", "")) == "decide-button3.mp3"
		and is_equal_approx(game.sfx.cue_gain("hand"), -5.0) and is_equal_approx(game.sfx.cue_gain("pinch"), 3.0)
		and is_equal_approx(game.sfx.cue_gain("lost"), Sfx.CUE_GAIN_DB["lost"]),
		"gesture sound: the open hand plays decide-button1.mp3, the pinch decide-button3.mp3, each at its own level",
		str([hand_snd, pinch_snd, game.sfx.cue_gain("hand"), game.sfx.cue_gain("pinch")]))
	# #332: the fingers opened after a pinch play 効果音ラボ's キャンセル4 (it was the synthesised "pon-pi"),
	# the easy mode's fist 決定ボタンを押す23 (it shared the pinch's decide-button3)
	var release_snd = game.sfx.cue_stream("release")
	var catch_snd = game.sfx.cue_stream("catch")
	_ok(release_cue == "release" and release_snd is AudioStreamMP3 and not release_snd.loop
		and catch_snd is AudioStreamMP3 and not catch_snd.loop and catch_snd != pinch_snd and release_snd != catch_snd
		and str(GameConfig.get_value("audio", "cue_release", "")) == "cancel4.mp3"
		and str(GameConfig.get_value("audio", "cue_catch", "")) == "decision23.mp3"
		and FileAccess.file_exists("res://assets/audio/cancel4.mp3") and FileAccess.file_exists("res://assets/audio/decision23.mp3")
		and is_equal_approx(game.sfx.cue_gain("release"), 8.0) and is_equal_approx(game.sfx.cue_gain("catch"), 8.0),
		"gesture sound (#332): pinch -> open hand plays cancel4.mp3, the fist's catch decision23.mp3, each at its own level",
		str([release_cue, release_snd, catch_snd, game.sfx.cue_gain("release"), game.sfx.cue_gain("catch")]))
	var ov := GestureCameraOverlay.new()
	ov.size = Vector2(320, 240)
	var straight := ov.to_px(Vector2(0.25, 0.5))
	ov.flip_h = true
	var mirrored := ov.to_px(Vector2(0.25, 0.5))
	ov.free()
	_ok(straight == Vector2(80, 120) and mirrored == Vector2(240, 120), "gesture overlay: image coords map onto the camera view (mirrored with it)")
	remove_child(game)
	game.free()
	rs.clear_samples()

## After an alarm the game leaves ERROR once the machine reports a normal state
## again (clear_alarm -> home), so the UFO's moods (and the telescope) come back.
func _test_error_clears_when_the_machine_recovers(rs: Node) -> void:
	var was_source: String = rs.source
	var was_connected: bool = rs.connected
	rs.source = "websocket"
	rs.connected = true
	GameState.set_state("READY")
	rs.machine_state = "ALARM"
	var in_error := GameState.state == "ERROR"
	rs.machine_state = "UNKNOWN"
	var still := GameState.state == "ERROR"
	rs.machine_state = "HOMING"
	var homing := GameState.state == "HOMING"
	rs.machine_state = "IDLE"
	var ready := GameState.state == "READY"
	_ok(in_error and still and homing and ready, "game state: ERROR after an alarm ends when the machine is back (HOMING -> READY)",
		"%s %s %s %s" % [in_error, still, homing, GameState.state])
	rs.machine_state = "UNKNOWN"
	rs.connected = was_connected
	rs.source = was_source

## Claw test controls: [ / ] and the debug buttons step the claw; arm_zero makes 0 degrees.
func _test_claw_steps_on_the_mock(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.arm_zero()
	game.arm_step(5.0)
	game.arm_step(5.0)
	game.arm_step(-1.0)
	var after_steps: float = rs.arm_deg
	game.arm_zero()
	var zeroed: float = rs.arm_deg
	var key := InputEventKey.new()
	key.keycode = KEY_BRACKETRIGHT
	key.pressed = true
	game._unhandled_input(key)
	var by_key: float = rs.arm_deg
	_ok(is_equal_approx(after_steps, 9.0) and zeroed == 0.0 and is_equal_approx(by_key, game.arm_step_deg) and rs.arm_reference_set,
		"claw: steps add up, arm_zero makes 0, ] steps by the set amount (mock)", "%.1f %.1f %.1f" % [after_steps, zeroed, by_key])
	# record closed / open, then go back and forth between them
	game.arm_goto("open")  # nothing recorded yet: stays
	var unmoved: float = rs.arm_deg
	game.arm_set("closed")
	game.arm_step(30.0)
	game.arm_set("open")
	game.arm_goto("closed")
	var closed_at: float = rs.arm_deg
	var qa := InputEventKey.new()
	qa.keycode = KEY_Q
	qa.pressed = true
	game._unhandled_input(qa)  # Q opens
	_ok(unmoved == by_key and closed_at == by_key and is_equal_approx(rs.arm_deg, by_key + 30.0) and is_equal_approx(rs.arm_span_deg, 30.0),
		"claw: arm_set records closed / open, arm_goto (and Q) turns there (mock)", "%.1f %.1f %.1f %.1f" % [unmoved, closed_at, rs.arm_deg, rs.arm_span_deg])
	qa.keycode = KEY_A
	game._unhandled_input(qa)  # A closes
	_ok(rs.arm_deg == by_key, "claw: Q opens and A closes to the recorded positions (mock)", "%.1f" % rs.arm_deg)
	remove_child(game)
	game.free()
	rs.clear_samples()

## A palm-down pinch steers Z (up on the shown view = arm up); a held fist /
## peace sign asks for the claw once per pose, never while the robot is gated.
func _test_gesture_z_and_claw() -> void:
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "joystick": {"smoothing_ms": 0.0, "max_speed_z": 15.0}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(ev: Dictionary, gate := "") -> void:
		t[0] += 1000.0 / 60.0
		seq[0] += 1
		ev["sequence"] = seq[0]
		g.on_event(ev, t[0])
		g.tick(t[0], 1.0 / 60.0, gate)
	var mid := func(y: float): return _hev(0, true, true, 0.5, y, {"pinch_finger": "middle", "pose": "open", "palm": "down"})
	var open_hand := func(pose: String): return _hev(0, true, false, 0.5, 0.5, {"pose": pose})
	for i in 6:
		step.call(open_hand.call("open"))
	for i in 6:
		step.call(mid.call(0.5))
	for i in 10:
		step.call(mid.call(0.3))  # hand up in the image
	var up := g.mode == "z" and g.velocity_z > 10.0 and g.velocity == Vector2.ZERO
	g.joystick.view_flip_v = true  # the view is shown upside down: same hand motion = down
	for i in 10:
		step.call(mid.call(0.3))
	var flipped := g.velocity_z < -10.0
	g.joystick.view_flip_v = false
	step.call(open_hand.call("open"))
	var stopped := g.velocity_z == 0.0 and g.state == GestureControl.State.HAND_DETECTED
	_ok(up and flipped and stopped, "gesture: a palm-down pinch steers Z only; follows the shown view; release stops",
		"%s %s %s %.1f %s" % [up, flipped, stopped, g.velocity_z, g.state_name()])

	for i in 20:  # 0.33 s of fist: not yet
		step.call(open_hand.call("fist"))
	var early := claws.is_empty()
	for i in 20:
		step.call(open_hand.call("fist"))
	var once := claws == ["closed"]
	for i in 60:
		step.call(open_hand.call("fist"))  # still the same fist: no repeat
	for i in 40:
		step.call(open_hand.call("peace"))
	var both := claws == ["closed", "open"]
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 40:
		step.call(open_hand.call("fist"), "モーターを有効にしてください")  # gated: nothing
	var gated := claws.size() == 2
	_ok(early and once and both and gated, "gesture: fist 0.5 s closes, peace opens, once per pose, not while gated",
		"%s %s %s %s %s" % [early, once, both, gated, claws])
	# Space while a fist builds up: no claw until the hand changes shape
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 10:
		step.call(open_hand.call("fist"))
	g.stop("stop_key")
	for i in 60:
		step.call(open_hand.call("fist"))
	var held_after_stop := claws.size() == 2
	for i in 3:
		step.call(open_hand.call("open"))
	for i in 40:
		step.call(open_hand.call("fist"))
	_ok(held_after_stop and claws.size() == 3, "gesture: a stop latches a claw pose being held; a new fist works again", str(claws))

## The safety frame runs any GestureScheme: the scheme decides the sign, the
## velocity and the claw poses; the frame keeps the latch and the switch stop.
func _test_gesture_schemes() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pinch_joystick", "joystick": {"smoothing_ms": 0.0}})
	var default_ok := g.scheme.id() == PinchJoystickScheme.ID and GestureControl.SCHEME_IDS.has(PinchJoystickScheme.ID)
	var unknown_kept := not g.set_scheme("no_such_scheme") and g.scheme.id() == PinchJoystickScheme.ID
	_ok(default_ok and unknown_kept, "gesture scheme: the pinch joystick by default; an unknown name keeps the current one",
		"%s %s" % [default_ok, unknown_kept])

	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String) -> void:
		t[0] += 1000.0 / 60.0
		seq[0] += 1
		g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose}), t[0])
		g.tick(t[0], 1.0 / 60.0, "")
	# the pinch joystick steering, then switched to a scheme of the test's own
	for i in 3:
		step.call("open")
	for i in 3:
		g.on_event(_hev(seq[0] + 1, true, true, 0.5, 0.5, {"pose": "open"}), t[0])
		seq[0] += 1
		g.tick(t[0], 1.0 / 60.0, "")
	var was_active := g.is_active()
	var same := g.scheme
	g.configure({"scheme": "pinch_joystick"})  # the same scheme again: settings only
	var reselected := g.set_scheme(PinchJoystickScheme.ID) and g.scheme == same
	g.on_event(_hev(seq[0] + 1, true, true, 0.7, 0.5, {"pose": "open"}), t[0])
	seq[0] += 1
	g.tick(t[0], 1.0 / 60.0, "")
	_ok(reselected and g.is_active() and g.velocity.length() > 1.0,
		"gesture scheme: choosing the current scheme again keeps the steer going", "%s %s %s" % [reselected, g.state_name(), g.velocity])
	var fake := _PoseScheme.new()
	g.use_scheme(fake)
	var switched_stop := g.state == S.WAITING_RELEASE and g.reason == "scheme_changed" and g.velocity == Vector2.ZERO
	_ok(was_active and switched_stop, "gesture scheme: switching while steering is a forced stop", "%s %s %s" % [was_active, g.state_name(), g.reason])

	for i in 5:
		step.call("open")  # the new sign held across the switch: latched
	var latched := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other")
	for i in 3:
		step.call("open")
	var steers := g.is_active() and g.velocity == Vector2(12.0, 0.0) and g.velocity_z == 0.0
	step.call("peace")  # another sign: let go first, never straight into the reverse
	var let_go := g.state == S.HAND_DETECTED and g.velocity == Vector2.ZERO
	for i in 3:
		step.call("peace")  # ARMED, ACTIVE, then the velocity
	var reverse := g.is_active() and g.velocity == Vector2(-12.0, 0.0)
	_ok(latched and steers and let_go and reverse,
		"gesture scheme: a scheme's own sign arms the frame; latched after a stop; another sign lets go before reversing",
		"%s %s %s %s %s" % [latched, steers, let_go, reverse, g.velocity])

	for i in 3:
		step.call("other")
	for i in 60:
		step.call("fist")  # not a claw pose of this scheme
	_ok(claws.is_empty() and g.claw_pose == "", "gesture scheme: only the scheme's claw poses move the claw", str(claws))

## The hand-shape scheme: パー / チョキ move the crane a set way, through the safety frame.
func _test_pose_direction_scheme() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"schemes": {"pose_direction": {"directions": {"open": [1, 0, 0], "peace": [-1, 0, 0]}, "speed_mm_s": 20.0,
			"pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0, "claw": {"fist": "closed", "open": "open"}}}})
	var ps := g.scheme as PoseDirectionScheme
	_ok(ps != null and ps.speed_mm_s == 20.0 and ps.claw_poses() == {"fist": "closed"} and ps.mapping_text() == "パー=右 チョキ=左 グー=爪閉",
		"pose scheme: chosen by config with its settings; a shape used for a direction never moves the claw",
		"%s %s" % [ps.claw_poses() if ps else null, ps.mapping_text() if ps else ""])
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String, n := 1) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	step.call("other", 3)
	step.call("open", 3)  # 50 ms: passing through a shape moves nothing
	var passing := g.state == S.HAND_DETECTED and g.velocity == Vector2.ZERO
	step.call("other", 10)
	step.call("open", 10)  # held past pose_confirm_ms
	var right := g.is_active() and g.velocity == Vector2(20.0, 0.0) and g.velocity_z == 0.0
	_ok(passing and right, "pose scheme: パー held = +X at the set speed; a passing shape does nothing", "%s %s %s" % [passing, g.state_name(), g.velocity])

	step.call("other", 2)  # a flicker shorter than pose_release_ms
	var kept := g.is_active() and g.velocity == Vector2(20.0, 0.0)
	step.call("peace", 1)
	step.call("open", 1)
	kept = kept and g.is_active()
	_ok(kept, "pose scheme: a short flicker of the shape does not stop it", g.state_name())

	var states: Array[int] = []
	var rec := func(_f, to, _w): states.append(to)
	g.state_changed.connect(rec)
	step.call("peace", 20)
	g.state_changed.disconnect(rec)
	var left := g.is_active() and g.velocity == Vector2(-20.0, 0.0)
	_ok(left and states.has(S.HAND_DETECTED) and states.find(S.HAND_DETECTED) < states.find(S.ACTIVE),
		"pose scheme: チョキ = -X; changing shape stops first, then arms the new way", "%s %s" % [states, g.velocity])

	g.stop("stop_key")
	step.call("peace", 30)  # still チョキ: latched
	var latched := g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other", 2)  # a flicker is not letting go
	step.call("peace", 30)
	latched = latched and g.state == S.WAITING_RELEASE and g.velocity == Vector2.ZERO
	step.call("other", 10)  # gone for longer than pose_release_ms
	var lifted := g.state == S.HAND_DETECTED
	step.call("peace", 12)
	_ok(latched and lifted and g.is_active(), "pose scheme: after a stop the same shape does not restart it; letting go does",
		"%s %s %s" % [latched, lifted, g.state_name()])

	# after a stop, going straight to another direction shape also lets go (held, not a misread)
	g.stop("stop_key")
	step.call("peace", 5)
	step.call("open", 1)  # a one-frame misread of another shape
	step.call("peace", 5)
	var misread_kept := g.state == S.WAITING_RELEASE
	step.call("open", 30)
	_ok(misread_kept and g.is_active() and g.velocity == Vector2(20.0, 0.0),
		"pose scheme: after a stop, holding another direction shape lets go and moves that way; a one-frame misread does not",
		"%s %s %s" % [misread_kept, g.state_name(), g.velocity])

	step.call("other", 10)
	step.call("fist", 40)
	_ok(claws == ["closed"], "pose scheme: the claw shape still works (fist = close)", str(claws))

	# switching the scheme while a shape is held: latched even though the new scheme has not confirmed it yet
	g.set_scheme(PinchJoystickScheme.ID)
	step.call("other", 3)
	g.set_scheme(PoseDirectionScheme.ID)
	step.call("open", 30)
	var switch_latched := g.state != S.ACTIVE and g.velocity == Vector2.ZERO
	g.use_scheme(PinchJoystickScheme.new())
	step.call("open", 3)
	var ps2 := PoseDirectionScheme.new()
	ps2.configure({"directions": {"open": [1, 0, 0]}, "pose_confirm_ms": 0.0, "smoothing_ms": 0.0})
	g.use_scheme(ps2)  # a stop while パー is in view
	step.call("open", 30)
	_ok(switch_latched and g.state == S.WAITING_RELEASE and g.reason == "scheme_changed",
		"pose scheme: a shape held across a scheme switch does not move", "%s %s %s" % [switch_latched, g.state_name(), g.reason])
	var main_script: GDScript = load("res://scripts/game/main.gd")
	_ok(main_script.sim_pose(true) == "open" and main_script.sim_pose(false) == "other",
		"pose scheme: the mouse simulation shows no shape unless a key says so (an open hand for the pinch stick)")

## Pointing: the crane goes where the index finger points (any angle), through
## the camera calibration of the stick.
func _test_pose_finger_direction() -> void:
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"joystick": {"invert_x": false, "invert_y": false, "swap_xy": false},
		"schemes": {"pose_direction": {"speed_mm_s": 20.0, "pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0}}})
	var ps := g.scheme as PoseDirectionScheme
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var step := func(pose: String, dir := Vector2.ZERO, n := 1, length := 1.0) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose, "point_dx": dir.x, "point_dy": dir.y, "point_len": length}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	var near := func(a: Vector2, b: Vector2) -> bool: return a.distance_to(b) < 0.05
	step.call("other", Vector2.ZERO, 3)
	step.call("point", Vector2(1, 0), 12)  # pointing right in the image
	var right: Vector2 = g.velocity
	step.call("point", Vector2(0, -1), 1)  # turned to point up in the image: away from the camera's bottom = +Y
	var away: Vector2 = g.velocity
	var d := Vector2(1, -1).normalized()
	step.call("point", d, 1)  # a diagonal
	var diag: Vector2 = g.velocity
	var still_active := g.is_active()
	_ok(near.call(right, Vector2(20, 0)) and near.call(away, Vector2(0, 20)) and near.call(diag, Vector2(14.142, 14.142)) and still_active,
		"pose scheme: pointing moves the crane where the finger points, diagonals too; turning the finger turns it",
		"%s %s %s %s" % [right, away, diag, still_active])
	step.call("point", Vector2(1, 0), 1, 0.2)  # the finger points at the camera: too short to tell
	var unsure: Vector2 = g.velocity
	g.joystick.invert_x = true  # the camera's calibration applies to the finger as to the stick
	step.call("point", Vector2(1, 0), 1)
	var inverted: Vector2 = g.velocity
	g.joystick.invert_x = false
	ps.point_snap_deg = 45.0
	step.call("point", Vector2.from_angle(deg_to_rad(-30.0)), 1)  # 30 deg up from right: snaps to 45
	var snapped: Vector2 = g.velocity
	_ok(unsure == Vector2.ZERO and g.is_active() and near.call(inverted, Vector2(-20, 0)) and near.call(snapped, Vector2(14.142, 14.142)),
		"pose scheme: no motion while the finger points at the camera; follows invert_x; can snap to 8 ways",
		"%s %s %s" % [unsure, inverted, snapped])
	_ok(ps.mapping_text() == "指差し=指の向き いいね↑=上げる いいね↓=下げる パー=爪開 チョキ=爪閉",
		"pose scheme: the default mapping (point, thumbs-up up / down, claw on パー / チョキ)", ps.mapping_text())

## The default hand-shape mapping: a thumbs-up raises / lowers the arm by where
## the thumb points in the shown view; パー opens the claw, チョキ closes it, グー rests.
func _test_pose_thumb_and_claw() -> void:
	var S := GestureControl.State
	var g := GestureControl.new()
	g.configure({"stale_ms": 150.0, "arm_delay_ms": 0.0, "scheme": "pose_direction",
		"joystick": {"invert_z": false},
		"schemes": {"pose_direction": {"speed_z": 10.0, "pose_confirm_ms": 100.0, "pose_release_ms": 100.0, "smoothing_ms": 0.0}}})
	g.enabled = true
	var t := [1000.0]
	var seq := [0]
	var claws: Array[String] = []
	g.claw_requested.connect(func(w): claws.append(w))
	var step := func(pose: String, thumb := Vector2.ZERO, n := 1) -> void:
		for i in n:
			t[0] += 1000.0 / 60.0
			seq[0] += 1
			g.on_event(_hev(seq[0], true, false, 0.5, 0.5, {"pose": pose, "thumb_dx": thumb.x, "thumb_dy": thumb.y}), t[0])
			g.tick(t[0], 1.0 / 60.0, "")
	step.call("other", Vector2.ZERO, 3)
	step.call("thumb", Vector2(0, -1), 12)  # the thumb towards the top of the image
	var up := g.is_active() and g.mode == "z" and is_equal_approx(g.velocity_z, 10.0) and g.velocity == Vector2.ZERO
	var states: Array[int] = []
	var rec := func(_f, to, _w): states.append(to)
	g.state_changed.connect(rec)
	step.call("thumb", Vector2(0, 1), 20)  # turned over: towards the bottom
	g.state_changed.disconnect(rec)
	var down := g.is_active() and is_equal_approx(g.velocity_z, -10.0)
	_ok(up and down and states.has(S.HAND_DETECTED),
		"pose scheme: thumbs-up up = arm up, down = arm down; turning the thumb over stops first",
		"%s %s %s %.1f" % [up, down, states, g.velocity_z])

	step.call("thumb", Vector2(1, 0.2).normalized(), 20)  # sideways: no sign
	var sideways := not g.is_active() and g.velocity_z == 0.0
	g.joystick.view_flip_v = true  # the view is shown upside down: the top of the image is the bottom of the screen
	step.call("thumb", Vector2(0, -1), 20)
	var flipped := g.is_active() and is_equal_approx(g.velocity_z, -10.0)
	g.joystick.view_flip_v = false
	_ok(sideways and flipped, "pose scheme: a sideways thumb does nothing; up / down follow the shown view",
		"%s %s %.1f" % [sideways, flipped, g.velocity_z])

	step.call("other", Vector2.ZERO, 10)
	step.call("open", Vector2.ZERO, 40)  # 0.67 s of パー
	var opened := claws == ["open"] and g.velocity_z == 0.0 and not g.is_active()
	step.call("peace", Vector2.ZERO, 40)
	var closed := claws == ["open", "closed"]
	step.call("fist", Vector2.ZERO, 60)  # resting: nothing
	_ok(opened and closed and claws == ["open", "closed"] and not g.is_active() and g.velocity_z == 0.0,
		"pose scheme: パー opens the claw, チョキ closes it, グー does nothing (none moves the crane)", str(claws))

## The Z pinch is told apart by ear: its own cue, different from the XY pinch.
func _test_gesture_z_has_its_own_sound(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	var S := GestureControl.State
	game.gesture.mode = "xy"
	game._on_gesture_state(S.HAND_DETECTED, S.ARMED, "")
	var xy: String = game.sfx.cue_log[-1] if not game.sfx.cue_log.is_empty() else ""
	game.gesture.mode = "z"
	game._on_gesture_state(S.HAND_DETECTED, S.ARMED, "")
	var z: String = game.sfx.cue_log[-1] if not game.sfx.cue_log.is_empty() else ""
	var notes: Dictionary = game.sfx.CUE_NOTES
	_ok(xy == "pinch" and z == "pinch_z" and notes.pinch_z != notes.pinch, "gesture: the Z pinch plays its own cue", "%s %s" % [xy, z])
	remove_child(game)
	game.free()
	rs.clear_samples()

## The staff remote (M5StopWatch through the device hub): its events' meaning, alone.
func _test_staff_remote_logic() -> void:
	_ok(StaffRemote.staff_action_of({"action": "NEXT"}) == "next" and StaffRemote.staff_action_of({"action": "RECOVER"}) == "recover"
		and StaffRemote.staff_action_of({"action": "STOP"}) == "stop" and StaffRemote.staff_action_of({"action": "DANCE"}) == ""
		and StaffRemote.staff_action_of({}) == "",
		"staff remote: STAFF_ACTION names are StaffControl's operations (anything else: nothing)")
	_ok(StaffRemote.frame_newer(1, 65535) and not StaffRemote.frame_newer(65535, 1) and not StaffRemote.frame_newer(5, 5)
		and StaffRemote.frame_newer(5, -1) and StaffRemote.frame_newer(300, 299),
		"staff remote: frame numbers are 16-bit and wrap")
	var r := StaffRemote.new()
	var a1 := r.accept_frame({"frame": 10}, 0.0)
	var late := r.accept_frame({"frame": 9}, 50.0)
	var same := r.accept_frame({"frame": 10}, 60.0)
	var a2 := r.accept_frame({"frame": 11}, 100.0)
	var present := r.present(600.0) and not r.present(701.0)
	var restart := r.accept_frame({"frame": 1}, 100.0 + r.restart_ms + 1.0)  # rebooted: numbers start over
	_ok(a1 and not late and not same and a2 and present and restart and r.dropped == 2 and r.frames == 3,
		"staff remote: frames in order only (late / repeated dropped), a long pause starts the numbering over; the remote is the hand while its frames come")
	# a new press is staged (open hand, pinch at the centre, then the tilt); a key still held
	# across a lapse of the stream is NOT a new press: the pinch goes on (latched), no fake release
	var q := StaffRemote.new()
	var t0 := 10000.0
	q.accept_frame({"frame": 1, "move": true}, t0)
	var p1 := q.staged({"move": true, "x": 50, "y": 0})
	q.accept_frame({"frame": 2, "move": true}, t0 + 100.0)
	var p2 := q.staged({"move": true, "x": 50, "y": 0})
	q.accept_frame({"frame": 3, "move": true}, t0 + 200.0)
	var p3 := q.staged({"move": true, "x": 50, "y": 0})
	var staged_ok: bool = not p1["move"] and p2["move"] and p2["x"] == 0 and p3["move"] and p3["x"] == 50
	q.accept_frame({"frame": 4, "move": true}, t0 + 200.0 + q.hold_ms + 300.0)  # back after a lapse, still held
	var h1 := q.staged({"move": true, "x": 80, "y": 0})
	q.accept_frame({"frame": 5, "move": true}, t0 + 200.0 + q.hold_ms + 400.0)
	var h2 := q.staged({"move": true, "x": 80, "y": 0})
	var held_ok: bool = q.held_over and h1["move"] and h1["x"] == 0 and h2["move"] and h2["x"] == 0
	q.accept_frame({"frame": 6, "move": false}, t0 + 200.0 + q.hold_ms + 500.0)
	q.staged({"move": false, "x": 0, "y": 0})
	q.accept_frame({"frame": 7, "move": true}, t0 + 200.0 + 2.0 * q.hold_ms + 900.0)  # a real new press after a pause
	var n1 := q.staged({"move": true, "x": 0, "y": 0})
	_ok(staged_ok and held_ok and not q.held_over and not n1["move"],
		"staff remote: a new press is staged; a key held across a lapse stays a latched pinch until a real release (review #263)",
		"%s %s %s %s %s %s" % [p1, p2, p3, h1, h2, n1])
	var none := r.on_message({"type": "devicehub_event", "data": {"name": "BALL_RECEIVED", "data": {"cycle": 1}}}, 0.0)
	var st := r.on_message({"type": "devicehub_event", "data": {"name": "STAFF_ACTION", "source": 48, "data": {"action": "SKIP", "code": 2}}}, 0.0)
	var other := r.on_message({"type": "robot_state", "data": {}}, 0.0)
	_ok(none.is_empty() and st == {"staff": "skip"} and other.is_empty(), "staff remote: only its own events mean something")
	# the remote's stick through every flip / swap of the camera's calibration: right is +X, forward +Y, forward in z raises the arm
	var all_ok := true
	var why := ""
	for ix in [false, true]:
		for iy in [false, true]:
			for sw in [false, true]:
				var j := HandJoystick.new()
				j.smoothing_ms = 0.0
				j.invert_x = ix
				j.invert_y = iy
				j.swap_xy = sw
				var c := Vector2(0.5, 0.5)
				j.set_anchor(c)
				var right := j.update(c + StaffRemote.hand_offset(100, 0, false, j), 1.0)
				var fwd := j.update(c + StaffRemote.hand_offset(0, 100, false, j), 1.0)
				var back_left := j.update(c + StaffRemote.hand_offset(-60, -60, false, j), 1.0)
				var slow := j.update(c + StaffRemote.hand_offset(5, 0, false, j), 1.0)
				var good := right.x > j.max_speed * 0.99 and absf(right.y) < 1e-3 and fwd.y > j.max_speed * 0.99 and absf(fwd.x) < 1e-3 \
					and back_left.x < 0.0 and back_left.y < 0.0 and slow.x > 0.0 and slow.x < j.max_speed * 0.1
				if not good:
					all_ok = false
					why += "[%s %s %s: %s %s %s %s]" % [ix, iy, sw, right, fwd, back_left, slow]
	for iz in [false, true]:
		for fv in [false, true]:
			var j := HandJoystick.new()
			j.smoothing_ms = 0.0
			j.invert_z = iz
			j.view_flip_v = fv
			var c := Vector2(0.5, 0.5)
			j.set_anchor(c)
			var up := j.update_z(c + StaffRemote.hand_offset(0, 100, true, j), 1.0)
			var down := j.update_z(c + StaffRemote.hand_offset(30, -100, true, j), 1.0)
			if not (up > j.max_speed_z * 0.99 and down < -j.max_speed_z * 0.99):
				all_ok = false
				why += "[z %s %s: %s %s]" % [iz, fv, up, down]
	_ok(all_ok, "staff remote: tilt right = +X, forward = +Y, forward in Z mode = arm up, whatever the stick's flips; a small tilt is slow, not nothing", why)
	var ev := StaffRemote.hand_event({"move": true, "z": false, "x": 0, "y": 0, "pose": "OPEN", "frame": 1}, HandJoystick.new(), 7)
	var fist := StaffRemote.hand_event({"move": false, "z": true, "x": 90, "y": 0, "pose": "FIST", "frame": 2}, HandJoystick.new(), 8)
	_ok(ev["pinch"] and ev["detected"] and ev["camera_ok"] and ev["palm"] == "up" and ev["sequence"] == 7 and ev["hand_x"] == 0.5
		and not fist["pinch"] and fist["pose"] == "fist" and fist["palm"] == "up" and fist["hand_x"] == 0.5,
		"staff remote: the move key is a pinch at the stick's centre; z only with the move key; a shape without it is a still hand")

func _remote_msg(name: String, data: Dictionary) -> Dictionary:
	return {"type": "devicehub_event", "data": {"name": name, "source": 48, "data": data}}

## The staff remote through the main scene, on the game's own mock crane.
func _test_staff_remote_game(rs: Node) -> void:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	game.gesture_require_focus = false
	game.set_gesture_enabled(false)
	game.gesture.joystick.smoothing_ms = 0.0
	game.gesture.arm_delay_ms = 0.0
	game.gesture.claw_hold_ms = 0.0  # real-time hold: this loop runs in a few ms
	var claws: Array[String] = []
	game.gesture.claw_requested.connect(func(w): claws.append(w))
	var start: Vector3 = game.mock.target
	var dt := 1.0 / 60.0
	var frame := [0]
	var send := func(d: Dictionary) -> void:
		frame[0] += 1
		d["frame"] = frame[0]
		game._on_remote_message(_remote_msg("REMOTE_INPUT", d))
		game._handle_input(dt)
	for i in range(20):
		send.call({"move": true, "z": false, "x": 100, "y": 0, "pose": "OPEN"})
	var moved: Vector3 = game.mock.target - start
	var src: String = game.control_source
	var turned_on: bool = game.gesture.enabled and game.hand_source == "remote"
	# the camera's hand meanwhile: not used
	game._on_hand_control(_hev(0, true, false, 0.9, 0.9), float(Time.get_ticks_msec()), game.vision_ws)
	var camera_waits: bool = str(game.gesture.last_event.get("source", "")) == "remote"
	send.call({"move": false, "z": false, "x": 0, "y": 0, "pose": "OPEN"})  # the closing frame
	var stopped_at: Vector3 = game.mock.target
	for i in range(5):
		game._handle_input(dt)
	_ok(turned_on and moved.x > 5.0 and absf(moved.y) < 1e-3 and src == "gesture" and camera_waits and game.mock.target == stopped_at,
		"staff remote + MockRobot: the move key + tilt right moves +X (the hand control switched on by it), the camera's hand waits; let go = stop",
		"%s %s %s %s" % [moved, src, turned_on, camera_waits])
	# an old frame (sent before the closing one) never restarts the stick
	game._on_remote_message(_remote_msg("REMOTE_INPUT", {"move": true, "x": 100, "y": 0, "pose": "OPEN", "frame": 3}))
	game._handle_input(dt)
	game._handle_input(dt)
	var late_ok: bool = game.mock.target == stopped_at and game.remote.dropped >= 1
	# a fist shown on the remote closes the claw (the pinch joystick's claw pose), once
	for i in range(4):
		send.call({"move": false, "x": 0, "y": 0, "pose": "FIST"})
	send.call({"move": false, "x": 0, "y": 0, "pose": "OPEN"})
	for i in range(3):
		send.call({"move": false, "x": 0, "y": 0, "pose": "PEACE"})
	_ok(late_ok and claws == ["closed", "open"], "staff remote: a late frame is dropped; fist = claw closed (once), peace = open",
		"%s %s" % [late_ok, claws])
	# Z: the forward tilt with the Z switch raises the arm, the backward one lowers it
	# (GestureControl.velocity_z: + = arm up; the mock arm may already be at an end of its range)
	for i in range(6):
		send.call({"move": true, "z": true, "x": 0, "y": 100, "pose": "OPEN"})
	var vz_up: float = game.gesture.velocity_z
	send.call({"move": false, "x": 0, "y": 0, "pose": "OPEN"})
	game._handle_input(dt)
	for i in range(6):
		send.call({"move": true, "z": true, "x": 40, "y": -100, "pose": "OPEN"})
	var vz_down: float = game.gesture.velocity_z
	var mode: String = game.gesture.mode
	send.call({"move": false, "x": 0, "y": 0, "pose": "OPEN"})
	_ok(vz_up > 1.0 and vz_down < -1.0 and mode == "z", "staff remote: Z mode, forward = the arm up, backward = down",
		"%s %s %s" % [vz_up, vz_down, mode])
	# review #263: the key held across a lapse of the stream (> the remote's hold time): the stick
	# stops on the stale input and does NOT start again until the key is really let go
	for i in range(6):
		send.call({"move": true, "z": false, "x": 100, "y": 0, "pose": "OPEN"})
	OS.delay_msec(int(game.remote.hold_ms) + 150)
	game._handle_input(dt)
	var lapsed_at: Vector3 = game.mock.target
	for i in range(10):
		send.call({"move": true, "z": false, "x": 100, "y": 0, "pose": "OPEN"})
	var still_latched: bool = game.mock.target == lapsed_at and game.gesture.state == GestureControl.State.WAITING_RELEASE
	send.call({"move": false, "x": 0, "y": 0, "pose": "OPEN"})
	for i in range(10):
		send.call({"move": true, "z": false, "x": 100, "y": 0, "pose": "OPEN"})
	var moves_again: bool = game.mock.target.x > lapsed_at.x + 1.0
	send.call({"move": false, "x": 0, "y": 0, "pose": "OPEN"})
	_ok(still_latched and moves_again, "staff remote: a key held across a lapse stays stopped until it is let go, then a new press moves (review #263)",
		"%s %s %s" % [still_latched, moves_again, game.gesture.state_name()])
	# review #263: under the pose_direction scheme the remote's input is not used
	game.gesture.set_scheme(PoseDirectionScheme.ID)
	var before: int = game.gesture.events
	send.call({"move": true, "z": false, "x": 100, "y": 0, "pose": "OPEN"})
	send.call({"move": false, "x": 0, "y": 0, "pose": "PEACE"})
	var refused: bool = game.gesture.events == before
	game.gesture.set_scheme(PinchJoystickScheme.ID)
	_ok(refused, "staff remote: not used under another gesture scheme (its shapes would mean other things)")
	# review #263: the events come on the backend link in use (the game's own mock: the listen-only vision link)
	game.show_title()
	game.ws.message_received.emit(_remote_msg("STAFF_ACTION", {"action": "SWITCH", "code": 5}))
	var ignored_ws: bool = game.title_active()
	game.vision_ws.message_received.emit(_remote_msg("STAFF_ACTION", {"action": "NEXT", "code": 1}))
	var via_vision: bool = game.staff.last[0] == "next"
	_ok(ignored_ws and via_vision, "staff remote: with the game's own mock its events come on the vision link (the other link is not read)",
		"%s %s %s" % [ignored_ws, via_vision, game.staff.last])
	if game.study_mode != null and game.study_mode.active():
		game.study_mode.stop()
	game.show_title()
	# the staff operations: as the keys
	game._on_remote_message(_remote_msg("STAFF_ACTION", {"action": "MENU", "code": 3}))
	var to_menu: bool = game.title_active() and game.staff.last[0] == "menu"
	game._on_remote_message(_remote_msg("STAFF_ACTION", {"action": "STOP", "code": 6}))
	var stop_ok: bool = game.staff.last[0] == "stop"
	game._on_remote_message(_remote_msg("STAFF_ACTION", {"action": "JUMP", "code": 9}))
	_ok(to_menu and stop_ok and game.staff.last[0] == "stop" and game.remote.last_action == "stop",
		"staff remote: STAFF_ACTION runs StaffControl's operation (MENU -> the menu, STOP); an unknown one nothing",
		"%s %s %s" % [to_menu, stop_ok, game.staff.last])
	remove_child(game)
	game.free()
	rs.clear_samples()

## #321: pixel dots on the hand window: a ring around the hand, a burst on a pinch (once, with
## the grab_burst sheet), sparks behind the hand while steering; off with the VFX.
func _test_hand_fx() -> void:
	var fx := HandFx.new()
	fx.size = Vector2(292, 219)
	add_child(fx)
	var dt := 1.0 / 60.0
	var at := Vector2(146, 110)
	fx.step(dt, false, at)
	var none := fx.orbit_points().is_empty() and fx.particles.is_empty()
	for i in 30:
		fx.step(dt, true, at)
	var ring := fx.orbit_points()
	var round_ok := ring.size() == HandFx.ORBIT_N
	for q in ring:
		round_ok = round_ok and absf(q.distance_to(at) - fx.radius) <= fx.radius * 0.2 + 1.5
	var whole := ring.all(func(q: Vector2) -> bool: return q == q.floor())
	_ok(none and round_ok and whole and fx.presence > 0.99 and fx.particles.is_empty(),
		"hand fx: a ring of whole-pixel dots circles the seen hand (nothing without a hand)", str([none, ring.size(), fx.presence]))
	# the pinch: the dots fly outwards, the sheet plays on the hand, the ring goes and comes back
	var before := VFXManager.spawned_log.size()
	fx.step(dt, true, at, true)
	var n := fx.particles.size()
	var d0 := 0.0
	for p in fx.particles:
		d0 += Vector2(p.p).distance_to(at)
	fx.step(dt * 3.0, true, at, true)
	var d1 := 0.0
	for p in fx.particles:
		d1 += Vector2(p.p).distance_to(at)
	var sheet_ok := VFXManager.spawned_log.size() == before + 1 and VFXManager.spawned_log[-1] == HandFx.BURST_SHEET \
		and is_instance_valid(fx.sheet) and fx.sheet.get_parent() == fx
	_ok(fx.bursts == 1 and n == HandFx.ORBIT_N + HandFx.BURST_EXTRA and d1 > d0 * 1.2 and fx.orbit_points().is_empty() and sheet_ok,
		"hand fx: a pinch bursts the ring outwards and plays grab_burst on the hand", str([fx.bursts, n, d0, d1, sheet_ok]))
	# held, flickering within the cooldown: still one burst; after the cooldown a new pinch bursts again
	for i in 10:
		fx.step(dt, true, at, true)
	fx.step(dt, true, at, false)
	fx.step(dt, true, at, true)
	var once := fx.bursts == 1
	for i in 40:
		fx.step(dt, true, at, false)
	var back := fx.presence > 0.99 and fx.particles.is_empty()
	fx.step(dt, true, at, true)
	_ok(once and back and fx.bursts == 2, "hand fx: one burst per pinch (a flicker does not pile them up); the ring forms again",
		str([once, back, fx.bursts]))
	# steering: sparks behind the hand (against the way it goes), more the faster
	for i in 60:
		fx.step(dt, true, at, false)
	fx.particles.clear()
	for i in 30:
		fx.step(dt, true, at, false, 1.0, Vector2(1, 0))
	var fast := fx.particles.size()
	var vx := 0.0
	for p in fx.particles:
		vx += Vector2(p.v).x
	fx.particles.clear()
	for i in 30:
		fx.step(dt, true, at, false, 0.2, Vector2(1, 0))
	var slow := fx.particles.size()
	fx.particles.clear()
	for i in 30:
		fx.step(dt, true, at, false, 0.0, Vector2(1, 0))
	var still := fx.particles.size()
	_ok(fast >= 8 and vx < 0.0 and slow < fast and slow > 0 and still == 0,
		"hand fx: steering streams sparks behind the hand, more when faster, none when still", str([fast, vx, slow, still]))
	# the hand lost: the ring fades away; off (render.vfx): nothing at all
	for i in 40:
		fx.step(dt, false, Vector2.ZERO)
	var gone := fx.orbit_points().is_empty() and fx.particles.is_empty()
	fx.enabled = false
	var b := fx.bursts
	for i in 5:
		fx.step(dt, true, at, i % 2 == 0, 1.0, Vector2(1, 0))
	_ok(gone and fx.particles.is_empty() and fx.orbit_points().is_empty() and fx.bursts == b,
		"hand fx: fades out when the hand is lost; nothing when the VFX are off", str([gone, fx.particles.size(), fx.bursts]))
	fx.queue_free()
	# the HUD feeds it from the GestureControl (read only): the ring on the hand's spot in the picture
	var g := GestureControl.new()
	g.enabled = true
	g.detected = true
	g.hand_norm = Vector2(0.25, 0.5)
	g.state = GestureControl.State.HAND_DETECTED
	var hud := GestureHud.new()
	hud.gesture = g
	add_child(hud)
	for i in 30:
		hud.step(dt)
	var spot := hud._overlay.to_px(g.hand_norm)
	var on_hand := hud.hand_fx.seen and hud.hand_fx.hand.is_equal_approx(spot) and not hud.hand_fx.orbit_points().is_empty() \
		and hud.hand_fx.clip_contents and hud.stick_fx.particles.is_empty()
	g.pinch = true
	hud.step(dt)
	var popped := hud.hand_fx.bursts == 1 and g.state == GestureControl.State.HAND_DETECTED
	hud.hidden_by_study = true
	hud.step(dt)
	_ok(on_hand and popped and hud.hand_fx.particles.is_empty() and hud.hand_fx.orbit_points().is_empty(),
		"hand fx in the HUD: the ring sits on the hand in the camera picture, a pinch bursts it, hidden clears it",
		str([on_hand, popped, spot, hud.hand_fx.hand]))
	hud.queue_free()
