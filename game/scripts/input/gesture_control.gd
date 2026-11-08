class_name GestureControl
extends RefCounted
## The hand gesture's own state machine (separate from GameState and
## RobotState): the safety frame around a GestureScheme. Fed with `hand_control`
## events (backend or simulated) and ticked with the physics; returns the XY
## velocity it asks for (mm/s, 0 unless ACTIVE; Z in `velocity_z`).
##
##   DISABLED -> WAITING_HAND -> HAND_DETECTED --engaged--> ARMED --> ACTIVE
##   ACTIVE --released (or another sign)--> HAND_DETECTED (a normal stop)
##   any forced stop --> WAITING_RELEASE --(hand seen, not engaged)--> HAND_DETECTED
##
## "Engaged" is the scheme's sign to steer (a pinch for the pinch joystick).
## Forced stops (stop()): hand lost, two hands, stale events, camera lost,
## WebSocket gone, window unfocused, Space, alarm, keyboard taking over, the
## robot not ready, gesture mode off, the scheme switched. They latch: a sign
## still held (or held again when tracking comes back) does nothing until the
## hand lets go of it and gives a NEW one. Events are judged by the receive time
## on this side's monotonic clock and by their sequence number; an old or
## reordered event is dropped and can never lift a stop.
##
## Not steering, a hand shape the scheme maps to the claw (`claw_poses`, the
## pinch joystick: fist = close, peace = open) held for claw_hold_ms asks for
## the claw once per pose: the same pose again does nothing until the hand
## shows another shape.

signal state_changed(from: int, to: int, reason: String)
## The claw should turn to its recorded "closed" / "open" position.
signal claw_requested(which: String)

enum State { DISABLED, WAITING_HAND, HAND_DETECTED, ARMED, ACTIVE, WAITING_RELEASE }
const STATE_NAMES := ["DISABLED", "WAITING_HAND", "HAND_DETECTED", "ARMED", "ACTIVE", "WAITING_RELEASE"]

## The pinch joystick's stick (config `gesture.joystick`); kept here so its
## settings and view flips survive switching schemes.
var joystick := HandJoystick.new()
## How the hand is read as a steer (config `gesture.scheme`).
var scheme: GestureScheme = PinchJoystickScheme.new()
## Per-scheme settings (config `gesture.schemes`), applied when switching.
var scheme_configs: Dictionary = {}
## True while the scheme sees its sign to steer (this tick).
var engaged := false
## True while the sign can still be seen (unconfirmed or flickering included):
## what the forced-stop latch waits on.
var sign_seen := false
## An event older than this (receive time) no longer counts: stop.
var stale_ms := 350.0
## How long ARMED shows "操縦開始！" before the stick goes live.
var arm_delay_ms := 120.0
## Operating region (normalised image coords); outside it the hand is ignored.
var roi := Rect2(0.0, 0.0, 1.0, 1.0)
var roi_enabled := false

var enabled := false:
	set(v):
		if v == enabled:
			return
		enabled = v
		if not v:
			_set_state(State.DISABLED, "disabled")
			scheme.reset(self)
			engaged = false
			sign_seen = false
			velocity = Vector2.ZERO
			velocity_z = 0.0
var state: int = State.DISABLED
## Why the last stop / wait happened ("released", "lost", "stale", a gate reason...).
var reason := ""
## Velocity asked for this tick (mm/s, robot X / Y).
var velocity := Vector2.ZERO
## Z velocity asked for this tick (z units/s; + = arm up), palm-down pinch only.
var velocity_z := 0.0
## What the current steer drives: "xy" (palm up / edge on) or "z" (palm down).
var mode := "xy"
## How long a fist / peace sign must be held before the claw moves.
var claw_hold_ms := 500.0

# latest accepted event
var last_event: Dictionary = {}
var hand := Vector2.ZERO  # palm centre, image short-side units
var hand_norm := Vector2.ZERO  # palm centre, normalised image coords
var detected := false
var pinch := false
var camera_ok := false
var pinch_ratio := 0.0
var pinch_finger := ""  # "index" / "middle" / "ring" while pinching
var palm := ""  # "up" / "down" / "side" from the backend
var pose := ""  # "fist" / "peace" / "point" / "open" / "other" from the backend
## Where the index finger points (image axes, unit; zero when unknown) and its
## length over the hand size (short: pointing at the camera), from the backend.
var point_dir := Vector2.ZERO
var point_len := 0.0
## Fist / peace being held now, since when, and the pose that already moved the claw.
var claw_pose := ""
var _claw_since_ms := 0.0
var _claw_fired := ""
var latency_ms := 0.0
var events := 0
var dropped := 0
## Within this distance (normalised image coords) of the frame edge the hand is
## "near the edge" (about to leave the camera's view).
var edge_margin := 0.1
## Image-axes edge flags (-1 / 0 / +1 per axis): while the hand is seen, the
## edges it is near; once it is lost, the edges it was near when last seen.
var edge := Vector2.ZERO
## The hand vanished while near an edge: it most likely left the camera's view.
var left_view := false
var last_seen := Vector2(-1.0, -1.0)
var _last_seq := -1
var _last_recv_ms := -1.0
var _armed_ms := 0.0

func configure(c: Dictionary) -> void:
	stale_ms = float(c.get("stale_ms", stale_ms))
	arm_delay_ms = float(c.get("arm_delay_ms", arm_delay_ms))
	var r = c.get("roi", null)
	if r is Array and r.size() == 4:
		roi = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
	roi_enabled = bool(c.get("roi_enabled", roi_enabled))
	var j = c.get("joystick", {})
	if j is Dictionary:
		joystick.configure(j)
	var sc = c.get("schemes", {})
	if sc is Dictionary:
		scheme_configs = sc.duplicate(true)  # the panel edits these; GameConfig stays as loaded
	set_scheme(str(c.get("scheme", scheme.id())))

## The schemes that can be chosen (config `gesture.scheme`).
const SCHEME_IDS := [PinchJoystickScheme.ID, PoseDirectionScheme.ID]

static func make_scheme(id: String) -> GestureScheme:
	match id:
		PinchJoystickScheme.ID:
			return PinchJoystickScheme.new()
		PoseDirectionScheme.ID:
			return PoseDirectionScheme.new()
	return null

## Switch how the hand is read. Always a forced stop (a sign held across the
## switch must be let go first); an unknown id keeps the current scheme.
## Returns false for an unknown id.
## The current scheme again only takes its settings: a steer in progress goes on.
func set_scheme(id: String) -> bool:
	var cfg = scheme_configs.get(id, {})
	if not cfg is Dictionary:
		cfg = {}
	if id == scheme.id():
		scheme.configure(cfg)
		return true
	var s := make_scheme(id)
	if s == null:
		push_warning("gesture: unknown scheme '%s', keeping '%s'" % [id, scheme.id()])
		return false
	s.configure(cfg)
	use_scheme(s)
	return true

## Install a configured scheme (tests can pass their own). Stops the gesture
## when it is another scheme than the current one.
func use_scheme(s: GestureScheme) -> void:
	var changed := s.id() != scheme.id()
	scheme.reset(self)
	scheme = s
	if changed:
		stop("scheme_changed")

func state_name() -> String:
	return STATE_NAMES[state]

func is_active() -> bool:
	return state == State.ACTIVE

## Milliseconds since the last accepted event (-1 = none yet).
func age_ms(now_ms: float) -> float:
	return -1.0 if _last_recv_ms < 0.0 else now_ms - _last_recv_ms

## A `hand_control` event received at `recv_ms` (this side's monotonic clock).
## Returns false when it was dropped (out of order / duplicate).
func on_event(ev: Dictionary, recv_ms: float) -> bool:
	var seq := int(ev.get("sequence", -1))
	if seq <= _last_seq:
		dropped += 1
		return false
	_last_seq = seq
	_last_recv_ms = recv_ms
	events += 1
	last_event = ev
	camera_ok = bool(ev.get("camera_ok", true))
	pinch_ratio = float(ev.get("pinch_ratio", 0.0))
	latency_ms = float(ev.get("latency_ms", 0.0))
	var w := maxf(float(ev.get("frame_w", 1.0)), 1.0)
	var h := maxf(float(ev.get("frame_h", 1.0)), 1.0)
	var s := minf(w, h)
	hand_norm = Vector2(float(ev.get("hand_x", 0.0)), float(ev.get("hand_y", 0.0)))
	hand = Vector2(hand_norm.x * w / s, hand_norm.y * h / s)
	detected = bool(ev.get("detected", false)) and camera_ok
	var seen := detected or (camera_ok and int(ev.get("hand_count", 0)) == 1 and str(ev.get("reason", "")) == "outside_roi")
	if seen:
		last_seen = hand_norm
		edge = edge_of(hand_norm, edge_margin)
		left_view = false
	elif camera_ok and str(ev.get("reason", "")) == "no_hand":
		left_view = edge != Vector2.ZERO  # gone from next to an edge: out of the view
	if detected and roi_enabled and not roi.has_point(hand_norm):
		detected = false
	pinch = detected and bool(ev.get("pinch", false))
	pinch_finger = str(ev.get("pinch_finger", "index")) if pinch else ""
	if pinch and pinch_finger == "":
		pinch_finger = "index"  # older backends / the simulator only know the index pinch
	pose = str(ev.get("pose", "")) if detected else ""
	palm = str(ev.get("palm", "")) if detected else ""
	point_dir = Vector2(float(ev.get("point_dx", 0.0)), float(ev.get("point_dy", 0.0))) if detected else Vector2.ZERO
	point_len = float(ev.get("point_len", 0.0)) if detected else 0.0
	return true

## 0..1 of the claw-pose hold before the claw moves (0 when none is building up).
func claw_progress(now_ms: float) -> float:
	if claw_pose == "" or claw_pose == _claw_fired:
		return 0.0
	return clampf((now_ms - _claw_since_ms) / maxf(claw_hold_ms, 1.0), 0.0, 1.0)

## Not steering, hand in view: a claw pose of the scheme held long enough asks for the claw.
func _claw_tick(now_ms: float, gate: String) -> void:
	var poses := scheme.claw_poses()
	if not poses.has(pose):
		claw_pose = ""
		_claw_fired = ""  # another shape: the next claw pose counts again
		return
	if pose != claw_pose:
		claw_pose = pose
		_claw_since_ms = now_ms
	if pose == _claw_fired or gate != "":
		return
	if now_ms - _claw_since_ms >= claw_hold_ms:
		_claw_fired = pose
		claw_requested.emit(str(poses[pose]))

## Which frame edges `n` (normalised image coords) is within `margin` of:
## x -1 left / +1 right, y -1 top / +1 bottom.
static func edge_of(n: Vector2, margin: float) -> Vector2:
	var e := Vector2.ZERO
	if n.x <= margin:
		e.x = -1.0
	elif n.x >= 1.0 - margin:
		e.x = 1.0
	if n.y <= margin:
		e.y = -1.0
	elif n.y >= 1.0 - margin:
		e.y = 1.0
	return e

## A new event stream (backend restarted / reconnected): sequence numbers start
## over. Also a forced stop, so a pinch held across it needs a new pinch.
func reset_stream(why: String) -> void:
	_last_seq = -1
	_last_recv_ms = -1.0
	edge = Vector2.ZERO
	left_view = false
	detected = false
	pinch = false
	engaged = false
	sign_seen = false
	stop(why)

## Forced stop: zero velocity and, unless off, wait for the sign to be let go.
## A claw pose being held is latched too: the claw needs a new shape.
func stop(why: String) -> void:
	scheme.reset(self)
	velocity = Vector2.ZERO
	velocity_z = 0.0
	if scheme.claw_poses().has(pose):
		_claw_fired = pose
	claw_pose = ""
	if state == State.DISABLED:
		return
	if state != State.WAITING_RELEASE or reason != why:
		_set_state(State.WAITING_RELEASE, why)

## Advance one physics tick. `gate` is "" when the robot may be moved by the
## gesture, otherwise the reason it may not (shown to the player).
func tick(now_ms: float, dt: float, gate: String) -> Vector2:
	velocity = Vector2.ZERO
	velocity_z = 0.0
	if not enabled:
		return velocity
	if state == State.DISABLED:
		_set_state(State.WAITING_HAND, "")
	var fresh := _last_recv_ms >= 0.0 and now_ms - _last_recv_ms <= stale_ms
	if not fresh or not camera_ok:
		engaged = false
		sign_seen = false
		var why := "camera_lost" if fresh and not camera_ok else ("no_events" if _last_recv_ms < 0.0 else "stale")
		if state in [State.ARMED, State.ACTIVE]:
			stop(why)
		elif state == State.HAND_DETECTED:
			_set_state(State.WAITING_HAND, why)
		elif state == State.WAITING_HAND and reason != why:
			reason = why
		return velocity
	engaged = detected and scheme.engaged(self, now_ms)
	sign_seen = detected and (engaged or scheme.sign_seen(self))
	if not detected or engaged or state != State.HAND_DETECTED:
		claw_pose = ""  # a claw pose only builds up on a seen hand that is not steering
	if not detected:
		var lost := str(last_event.get("reason", "")) if not bool(last_event.get("detected", false)) else "outside_roi"
		if lost == "":
			lost = "no_hand"
		if state in [State.ARMED, State.ACTIVE]:
			stop(lost)
		elif state == State.HAND_DETECTED:
			_set_state(State.WAITING_HAND, lost)
		elif state == State.WAITING_HAND:
			reason = lost
		return velocity
	match state:
		State.WAITING_HAND:
			if sign_seen:
				stop("release_first")  # it was already giving the sign when it came into view
			else:
				_set_state(State.HAND_DETECTED, "")
		State.HAND_DETECTED:
			if engaged:
				if gate != "":
					stop(gate)
				else:
					scheme.on_arm(self, now_ms)
					_armed_ms = now_ms
					_set_state(State.ARMED, "")
			else:
				_claw_tick(now_ms, gate)
		State.ARMED:
			if not engaged or not scheme.same_engagement(self):
				scheme.reset(self)
				_set_state(State.HAND_DETECTED, "released")
			elif gate != "":
				stop(gate)
			elif now_ms - _armed_ms >= arm_delay_ms:
				_set_state(State.ACTIVE, "")
		State.ACTIVE:
			if not engaged or not scheme.same_engagement(self):
				scheme.reset(self)
				_set_state(State.HAND_DETECTED, "released")
			elif gate != "":
				stop(gate)
			else:
				var v := scheme.velocity(self, dt)
				velocity = Vector2(v.x, v.y)
				velocity_z = v.z
		State.WAITING_RELEASE:
			if not sign_seen:
				_set_state(State.HAND_DETECTED, reason)
	return velocity

func _set_state(s: int, why: String) -> void:
	var from := state
	state = s
	reason = why
	if from != s:
		state_changed.emit(from, s, why)
