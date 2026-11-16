class_name GestureTutorialController
extends RefCounted
## The practice before the score game (#149): one step at a time, each ended by what the
## player really did. Pure logic: it is fed a snapshot of the hand and of the practice
## capsule every tick and says what the screen should show. It never sends anything: not
## to the robot, not to the Dials. The score game's controller starts the practice capsule
## and the real round when this says so.
##
## Its state is its own: not RobotState, not GameState, not the round's phase.
##
##   off -> (begin) -> judging -> success -> judging (the next step) ... -> off (finished)
##   a step without a judgement (the spell, the rules; or a hand step when there is no
##   hand camera) is "telling": it goes on by itself and shows no "OK"
##   blocked: the practice capsule failed. Nothing goes on by itself.
##
## The hand snapshot (`hand`):
##   enabled   the hand control is on at all
##   fresh     an event came within the stale time (an old event never counts)
##   camera_ok / detected / pose / pinch / pinch_finger
##   pos       the palm, normalised picture coordinates
##   active    the hand stick is really steering (GestureControl ACTIVE)
##   speed     how fast it asks to go, 0..1 of the scheme's top speed
##   gate      "" when the hand may move the robot now, else why not
## The world snapshot (`world`):
##   speech_busy   UFOくん is still speaking
##   practice      "" / "open" / "closing" / "done" / "fault" (the controller's capsule)
##   devices_ok    the Dials' hub answers

signal step_started(index: int, step: Dictionary)
## The step was really done: the one "OK" of this step.
signal step_succeeded(index: int, step: Dictionary)
## "done" (every step) / "skipped" (a member of staff)
signal finished(how: String)
## Lines for UFOくん to say (also shown as words)
signal say(lines: Array)

## how long the "OK" stays before the next step
var ok_s := 1.4
## a step is shown at least this long before it can succeed
var min_show_s := 0.8
## a gap in the hand shape shorter than this does not restart the hold
var grace_s := 0.2
## no hand in view for this long: "show me your hand"
var lost_s := 1.0
## no fresh hand event for this long: the camera or the link is gone
var camera_s := 1.5
## still not done after this long: "let's try once more"
var retry_s := 8.0
## a step told and not judged stays this long (and until its lines are said)
var tell_s := 4.0
## a step that is told never waits longer than this for the voice to end (the voice is
## decoration: nothing may hang on it)
var tell_max_s := 12.0
## the hand stick must ask for at least this much of its top speed to count as moving
var move_speed := 0.25

var steps: Array = []
var index := -1
var state := "off"
## the hold of the step's sign, 0..1
var progress := 0.0
## a gentle line for the player ("" = none)
var guide := ""
## the step is judged from the hand alone: the robot is not moved by it
var hand_only := false
## why the robot is not moved ("" when it is, or when the step does not move it)
var gate_note := ""
## there is no hand camera: the hand steps are told, not judged
var no_hand := false
## how many steps were really done (one "OK" each)
var oks := 0
var t := 0.0
var _hold := 0.0
var _gap := 0.0
var _lost := 0.0
var _stale := 0.0
var _ok_left := 0.0
var _anchor := Vector2(-1, -1)
var _claws := 0
var _claws_at_start := 0
var _was_pinching := false

func configure(cfg: Dictionary) -> void:
	ok_s = float(cfg.get("ok_s", ok_s))
	min_show_s = float(cfg.get("min_show_s", min_show_s))
	grace_s = float(cfg.get("grace_s", grace_s))
	lost_s = float(cfg.get("lost_s", lost_s))
	camera_s = float(cfg.get("camera_s", camera_s))
	retry_s = float(cfg.get("retry_s", retry_s))
	tell_s = float(cfg.get("tell_s", tell_s))
	move_speed = float(cfg.get("move_speed", move_speed))
	tell_max_s = float(cfg.get("tell_max_s", tell_max_s))

func active() -> bool:
	return state != "off"

func step() -> Dictionary:
	return steps[index] if index >= 0 and index < steps.size() else {}

func kind() -> String:
	return str(step().get("kind", ""))

## A hand step: its end is judged from the hand.
static func is_hand_kind(k: String) -> bool:
	return k in ["pose", "pinch", "move", "grab"]

## The step is being told, not judged (the screen says so, and shows no "OK").
func telling() -> bool:
	return state == "judging" and (kind() in ["summon", "info"] or (no_hand and is_hand_kind(kind())))

func begin(with_steps: Array, hand_enabled: bool) -> void:
	steps = with_steps
	no_hand = not hand_enabled
	oks = 0
	_claws = 0
	if steps.is_empty():
		state = "off"
		finished.emit("done")
		return
	_enter(0)

func cancel() -> void:
	state = "off"
	index = -1
	guide = ""
	progress = 0.0

## The claw was asked for by the hand ("closed" / "open"): the real request, not the shape.
func on_claw(which: String) -> void:
	if which == "closed":
		_claws += 1

## Staff: this step again from its start.
func retry_step() -> void:
	if active() and index >= 0:
		_enter(index)

## Staff: on to the next step without an "OK" (this one was not done).
func skip_step() -> void:
	if active():
		_next()

## Staff: the whole practice is left out.
func skip_all() -> void:
	if active():
		state = "off"
		finished.emit("skipped")

func _enter(i: int) -> void:
	index = i
	state = "judging"
	t = 0.0
	progress = 0.0
	guide = ""
	hand_only = false
	gate_note = ""
	_hold = 0.0
	_gap = 0.0
	_lost = 0.0
	_stale = 0.0
	_anchor = Vector2(-1, -1)
	_claws_at_start = _claws
	_was_pinching = false
	step_started.emit(index, step())
	var lines: Array = step().get("say", [])
	if not lines.is_empty():
		say.emit(lines)

func _next() -> void:
	if index + 1 >= steps.size():
		state = "off"
		finished.emit("done")
	else:
		_enter(index + 1)

func _succeed() -> void:
	state = "success"
	_ok_left = ok_s
	progress = 1.0
	guide = ""
	oks += 1
	step_succeeded.emit(index, step())

func tick(dt: float, hand: Dictionary, world: Dictionary) -> void:
	if state == "off":
		return
	t += dt
	if state == "success":
		_ok_left -= dt
		if _ok_left <= 0.0:
			_next()
		return
	var s := step()
	var k := str(s.get("kind", ""))
	no_hand = not bool(hand.get("enabled", false))
	match k:
		"summon", "info":
			if t >= float(s.get("min_s", tell_s)) and (not bool(world.get("speech_busy", false)) or t >= tell_max_s):
				_next()
		"practice":
			_tick_practice(world)
		_:
			if no_hand:
				# no hand camera: the step is shown and said, and is not called done
				guide = "てのカメラが つかえないので せつめいだけ するね"
				if t >= maxf(tell_s, float(s.get("min_s", 0.0))) and (not bool(world.get("speech_busy", false)) or t >= tell_max_s):
					_next()
			else:
				_tick_hand(dt, s, k, hand)

func _tick_practice(world: Dictionary) -> void:
	var p := str(world.get("practice", ""))
	match p:
		"done":
			_succeed()
		"fault":
			state = "blocked"
			guide = "うまく いかなかったみたい。かかりの ひとを よんでね"
		_:
			if state == "blocked":
				return
			if not bool(world.get("devices_ok", true)):
				guide = "ポータルの じゅんびが できていないよ。かかりの ひとを よんでね"
			elif p == "closing":
				guide = "カプセルを かえしたよ。でてきたかな？"
			elif bool(world.get("capsule", false)):
				guide = "いいね！ カプセルが がめんの なかに はいったよ"
			elif t >= retry_s * 2.5:
				guide = "カプセルを つかんで ポータルに いれてみよう"
			else:
				guide = ""

## The hand is there and its events are fresh; otherwise the guide says what is missing.
func _hand_ready(dt: float, hand: Dictionary) -> bool:
	if not bool(hand.get("fresh", false)) or not bool(hand.get("camera_ok", true)):
		_stale += dt
		if _stale >= camera_s:
			guide = "てのカメラが みつからないよ。かかりの ひとを よんでね"
		return false
	_stale = 0.0
	if not bool(hand.get("detected", false)):
		_lost += dt
		if _lost >= lost_s:
			guide = "てを カメラに みせてね"
		return false
	_lost = 0.0
	return true

## The sign held: true once it has been there for `need_s` (a short gap is forgiven).
func _held(now: bool, dt: float, need_s: float) -> bool:
	if now:
		_hold += dt
		_gap = 0.0
	else:
		_gap += dt
		if _gap > grace_s:
			_hold = 0.0
	progress = clampf(_hold / maxf(need_s, 0.01), 0.0, 1.0)
	return _hold >= need_s

func _tick_hand(dt: float, s: Dictionary, k: String, hand: Dictionary) -> void:
	if not _hand_ready(dt, hand):
		_held(false, dt, 1.0)
		_anchor = Vector2(-1, -1)
		_was_pinching = false
		return
	var shape := str(hand.get("pose", ""))
	var poses: Array = s.get("poses", [])
	var gate := str(hand.get("gate", ""))
	var done := false
	var hint := ""
	match k:
		"pose":
			done = _held(shape in poses, dt, float(s.get("hold_s", 0.6)))
		"pinch":
			var want := str(s.get("finger", "index"))
			var pinching := bool(hand.get("pinch", false))
			var right := pinching and (want == "" or str(hand.get("pinch_finger", "index")) == want)
			done = _held(right, dt, float(s.get("hold_s", 0.5)))
			if pinching and not right:
				hint = "ひとさしゆびで つまんでみよう"
		"move":
			hand_only = gate != ""
			gate_note = gate
			if not hand_only:
				# really steering: the hand stick is ACTIVE (a NEW sign after any stop) and asks for speed
				done = _held(bool(hand.get("active", false)) and float(hand.get("speed", 0.0)) >= move_speed,
					dt, float(s.get("move_s", 0.5)))
			elif str(s.get("by", "hand")) == "pose":
				done = _held(shape in poses, dt, float(s.get("move_s", 0.5)))
			else:
				# the hand alone: a pinch that began in this step, carried across the picture
				var pinching := bool(hand.get("pinch", false))
				var pos: Vector2 = hand.get("pos", Vector2.ZERO)
				if pinching and not _was_pinching:
					_anchor = pos
				if not pinching:
					_anchor = Vector2(-1, -1)
				_was_pinching = pinching
				var far := pinching and _anchor.x >= 0.0 and pos.distance_to(_anchor) >= float(s.get("move_dist", 0.12))
				done = _held(far, dt, 0.15)
				if pinching and _anchor.x >= 0.0 and not far:
					progress = maxf(progress, clampf(pos.distance_to(_anchor) / float(s.get("move_dist", 0.12)), 0.0, 0.9))
				if not pinching:
					hint = "もういちど つまんでから うごかそう"
		"grab":
			hand_only = gate != ""
			gate_note = gate
			if not hand_only:
				# the claw's own request (the hand control asks once per shape, after its hold)
				done = _claws > _claws_at_start
				progress = clampf(float(hand.get("claw_progress", 0.0)), 0.0, 1.0)
				_held(shape in poses, dt, 1.5)
				if not done and _hold >= 1.5:
					hint = "いちど パーに もどしてから もういちど！"
			else:
				done = _held(shape in poses, dt, float(s.get("hold_s", 0.5)))
	if done and t >= min_show_s:
		_succeed()
		return
	if hint != "":
		guide = hint
	elif t >= retry_s:
		guide = "もういちど やってみよう"
	else:
		guide = ""

## A scripted hand for the rehearsal (`--game-mode-demo`) and the tests: it does what step
## `s` asks, `ts` seconds into the step. It is given to the tutorial only (gate "demo"): it
## never reaches the hand control, so it can never move anything.
static func demo_hand(s: Dictionary, ts: float) -> Dictionary:
	var k := str(s.get("kind", ""))
	var poses: Array = s.get("poses", [])
	var h := {"enabled": true, "fresh": true, "camera_ok": true, "detected": ts >= 0.4, "pose": "other", "pinch": false,
		"pinch_finger": "", "pos": Vector2(0.45, 0.55), "active": false, "speed": 0.0, "gate": "デモ", "claw_progress": 0.0, "demo": true}
	if ts < 1.2:
		return h
	match k:
		"pose", "grab":
			h.pose = str(poses[0]) if not poses.is_empty() else "open"
		"pinch":
			h.pinch = true
			h.pinch_finger = str(s.get("finger", "index"))
		"move":
			if str(s.get("by", "hand")) == "pose":
				h.pose = str(poses[0]) if not poses.is_empty() else "point"
			else:
				h.pinch = true
				h.pinch_finger = "index"
				h.pos = Vector2(0.45, 0.55) + Vector2(0.2, -0.08) * clampf((ts - 1.5) / 1.0, 0.0, 1.0)
	return h
