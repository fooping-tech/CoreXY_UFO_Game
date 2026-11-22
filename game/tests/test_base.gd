extends Node
## What every test suite shares (see run_tests.gd): the pass / fail count and the helpers.
## A suite is a Node in the tree (tests add scenes under it) whose _test_* functions the
## runner calls in its own order.

static var _fails := 0
static var _passes := 0

const StudyClientScript := preload("res://scripts/study/study_client.gd")

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_passes += 1
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", detail)

func _make() -> RopeSimulator:
	var s := RopeSimulator.new()
	s.rope_length = 40.0
	s.target_rope_length = 40.0
	s.reset()
	return s

func _max_stretch(s: RopeSimulator) -> float:
	var seg := s.segment_length()
	var worst := 0.0
	for i in range(1, s.points.size()):
		var d := (s.points[i].position - s.points[i - 1].position).length()
		worst = maxf(worst, d / seg)
	return worst

# ------------------------------------------------------------ hand gesture joystick
## A hand_control event (640x480 frame), like the backend sends.
func _hev(seq: int, detected: bool, pinch: bool, x := 0.5, y := 0.5, extra := {}) -> Dictionary:
	var ev := {"event": "hand_control", "camera_ok": true, "detected": detected, "hand_count": 1 if detected else 0,
		"pinch": pinch, "hand_x": x, "hand_y": y, "pinch_ratio": 0.2 if pinch else 0.8, "confidence": 0.95,
		"reason": "" if detected else "no_hand", "frame_w": 640, "frame_h": 480, "sequence": seq, "timestamp": 0, "latency_ms": 30.0}
	ev.merge(extra, true)
	return ev

func _mouse_press() -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	return ev

## Free what queue_free() queued under `n` now (tests run in one frame).
func await_free_now(n: Node) -> void:
	for c in n.get_children():
		if c.is_queued_for_deletion():
			c.free()

## A test scheme: "open" steers +X, "peace" -X, no claw.
class _PoseScheme extends GestureScheme:
	var armed_pose := ""
	func id() -> String:
		return "test_pose"
	func engaged(g, _now_ms: float) -> bool:
		return g.pose in ["open", "peace"]
	func same_engagement(g) -> bool:
		return g.pose == armed_pose
	func on_arm(g, _now_ms: float) -> void:
		armed_pose = g.pose
		g.mode = "xy"
	func velocity(_g, _dt: float) -> Vector3:
		return Vector3(12.0 if armed_pose == "open" else -12.0, 0.0, 0.0)
	func reset(_g) -> void:
		armed_pose = ""

## Advance the study mode's clocks (speech, services, controller timers); the game's
## mock jumps to its targets (it is the virtual crane: the walk only waits for it).
func _study_pump(game: Node, secs: float, until := Callable()) -> bool:
	var ctl: StudyModeController = game.study_mode
	var dt := 0.1
	var t := 0.0
	while t < secs:
		ctl.speech._process(dt)
		ctl.services._process(dt)
		ctl._process(dt)
		game.mock.pos = game.mock.target
		game.mock.vel = Vector3.ZERO
		t += dt
		if until.is_valid() and until.call():
			return true
	return not until.is_valid()

func _study_game(mode := "simulated") -> Node:
	GameConfig.data["study_mode"]["enabled"] = true
	GameConfig.data["study_mode"]["cleanup"]["enabled"] = true  # the tidy-up's own tests (off in the config, #110)
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	RobotState.source = "mock"
	game.mock.enabled = true
	game.study_mode.services.set_mode(mode)
	game.study_mode.speech.voice_on = false
	game.study_mode.sounds.enabled = false
	return game

func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev

func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null

# ---------------------------------------------------------------- game mode (#138)
const GM_L := GameModeDevices.DIAL_1

## Dial 2 was the right portal until #200: the game must never talk to it.
const GM_R := GameModeDevices.DIAL_2

## How many commands the game sent to `device` (the stop key's STOP_ALL goes to everything).
func _gm_sent(hub: MockDialHub, device: int) -> int:
	return hub.executed.filter(func(e): return e[0] == device and e[1] != "STOP_ALL").size()

func _gm_game() -> Node:
	var game: Node = load("res://scenes/main.tscn").instantiate()
	add_child(game)
	RobotState.source = "mock"
	game.mock.enabled = true
	var ctl: GameModeController = game.game_mode
	ctl.trace_to_file = false
	ctl.sounds.enabled = false
	ctl.devices_wanted = "mock"
	ctl.tutorial_auto = false  # these tests are about the round; the practice (#149) has its own
	ctl.set_difficulty("hard")  # the config's default is easy since #179; the easy mode has its own tests
	ctl.ranking.path = ""  # never the real file of high scores
	ctl.ranking_enabled = false  # the ranking (#155) has its own tests
	ctl.mock_kind = "normal"  # the capsule kinds (#266) have their own tests: plain capsules here
	ctl.board_max_s = 1000.0  # the board's own way back to the title (#271) has its own test
	return game

func _gm_step(ctl: GameModeController, secs: float) -> void:
	var n := int(round(secs * 60.0))
	for i in n:
		ctl.tick(1.0 / 60.0)

## The title's third card, then Enter, then the countdown: the lane armed.
func _gm_playing(game: Node) -> GameModeController:
	var ctl: GameModeController = game.game_mode
	game.show_title()
	game._unhandled_input(_key(KEY_3))
	game._unhandled_input(_key(KEY_ENTER))
	_gm_step(ctl, ctl.countdown_s + 0.2)
	return ctl

func _gm_free(game: Node, rs: Node) -> void:
	game.game_mode.close()
	remove_child(game)
	game.free()
	VFXManager.stop_all()
	rs.clear_samples()

## A capsule goes through the field: from the Dial's switch to the exit `goal`.
func _gm_play_capsule(ctl: GameModeController, goal: String) -> String:
	var l: GameModeController.Lane = ctl.lanes["left"]
	ctl.mock_hub.mock_ball(l.device)
	_gm_step(ctl, ctl.absorb_s + ctl.drop_s + 0.05)
	var id := str(l.capsule.get("capsule_id", ""))
	ctl.field.capsule_exited.emit(id, goal, Vector2(640, 660))
	return id

## A hand for the practice's logic: seen, fresh, doing nothing; `more` on top.
func _tut_hand(more: Dictionary = {}) -> Dictionary:
	var h := {"enabled": true, "fresh": true, "camera_ok": true, "detected": true, "pose": "other", "pinch": false,
		"pinch_finger": "", "pos": Vector2(0.5, 0.5), "active": false, "speed": 0.0, "gate": "", "claw_progress": 0.0}
	h.merge(more, true)
	return h

func _tut_run(t: GestureTutorialController, secs: float, hand: Dictionary, world: Dictionary = {}) -> void:
	for i in int(round(secs * 60.0)):
		t.tick(1.0 / 60.0, hand, world)

# ------------------------------------------------------------------ easy mode (#169)
## A stand-in for the backend: records what the easy mode asks for and holds the report.
class EasyBackend:
	var sent: Array = []  # [name, params, rid]
	var status: Dictionary = {}
	var n := 0
	func send(name: String, params: Dictionary) -> String:
		n += 1
		sent.append([name, params, "e%d" % n])
		return "e%d" % n
	func names() -> Array:
		return sent.map(func(s): return s[0])
	func last_rid() -> String:
		return str(sent[-1][2]) if not sent.is_empty() else ""
	func report(state: String, gid: String, extra := {}) -> void:
		status = {"active": state in ["AUTO_GRAB", "WAIT_DESTINATION", "DELIVER_DIAL_1", "DELIVER_DIAL_2"], "state": state,
			"grab_id": gid, "step": "", "destination": 0, "wait_left_s": 12.0, "wait_s": 15.0, "last_result": "", "error": ""}
		status.merge(extra, true)

static func _easy_hand(pose: String, extra := {}) -> Dictionary:
	var h := {"fresh": true, "camera_ok": true, "detected": true, "pose": pose, "pinch": false, "steering": false}
	h.merge(extra, true)
	return h

func _easy_run(e: EasyModeControl, be: EasyBackend, secs: float, hand: Dictionary, world_extra := {}) -> void:
	var world := {"enabled": true, "taking": true, "link": true, "gate": "", "status": be.status}
	world.merge(world_extra, true)
	for i in int(round(secs * 60.0)):
		world["status"] = be.status
		e.tick(1.0 / 60.0, hand, world)

func _easy_new() -> Array:
	var e := EasyModeControl.new()
	var be := EasyBackend.new()
	e.send = be.send
	_easy_run(e, be, 0.1, _easy_hand("other"))
	return [e, be]

func _process_frame(n: Node) -> void:
	n._process(1.0 / 60.0)

## A ranking whose file is cut short as it is written (a full disk).
class CutShortRanking extends RankingManager:
	func _write(tmp: String, text: String) -> String:
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(text.substr(0, text.length() / 2))
		f.close()
		return ""

func _rank_file(name: String) -> String:
	var path := "user://test_ranking/" + name
	for p in [path, path + ".bad", path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	return path

## A round to its result and through the result's show (the ranking is asked in the tick the show ends).
func _gm_finish_round(ctl: GameModeController, with_capsule := true) -> void:
	if with_capsule:
		_gm_play_capsule(ctl, "center")
		_gm_step(ctl, 5.0)
	ctl.time_left = 0.05
	_gm_step(ctl, 3.0)
	var secs := 0.0
	while not ctl.result_show.settled() and secs < 60.0:
		_gm_step(ctl, 0.1)
		secs += 0.1

## #188, the second part: the light follows the state, a MULTI BALL always gives its capsule
## back, the switches, the staff's keys, the music under a pickup.
func _gm_light_modes(hub: MockDialHub) -> Array:
	return hub.executed.filter(func(e): return e[0] == GameModeDevices.ILLUMINATION and e[1] == "SET_LIGHT_MODE").map(func(e): return e[2])
