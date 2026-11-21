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
	var blips: AudioStreamWAV = game.sfx.cue_stream("pinch")
	var log_: Array[String] = game.sfx.cue_log
	var first_hand := log_.find("hand")
	_ok(first_hand >= 0 and log_.find("pinch") > first_hand and pinch_cue == "pinch" and release_cue == "release" and lost_cue == "lost"
		and blips != null and blips.data.size() > 4000 and game.sfx.cue_stream("hand") != null and game.sfx.cue_stream("release") != null,
		"gesture sound: hand seen, pinch caught, fingers opened, control cut - each its own blip",
		"%s | %s %s %s" % [log_, pinch_cue, release_cue, lost_cue])
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
