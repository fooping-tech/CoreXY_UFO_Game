class_name GestureControl
extends RefCounted
## The pinch hand joystick's own state machine (separate from GameState and
## RobotState). Fed with `hand_control` events (backend or simulated) and ticked
## with the physics; returns the XY velocity it asks for (mm/s, 0 unless ACTIVE).
##
##   DISABLED -> WAITING_HAND -> HAND_DETECTED --pinch--> ARMED --> ACTIVE
##   ACTIVE --release--> HAND_DETECTED (a normal stop)
##   any forced stop --> WAITING_RELEASE --(hand seen, not pinching)--> HAND_DETECTED
##
## Forced stops (stop()): hand lost, two hands, stale events, camera lost,
## WebSocket gone, window unfocused, Space, alarm, keyboard taking over, the
## robot not ready, gesture mode off. They latch: a pinch still held (or held
## again when tracking comes back) does nothing until the fingers open and a
## NEW pinch starts. Events are judged by the receive time on this side's
## monotonic clock and by their sequence number; an old or reordered event is
## dropped and can never lift a stop.

signal state_changed(from: int, to: int, reason: String)

enum State { DISABLED, WAITING_HAND, HAND_DETECTED, ARMED, ACTIVE, WAITING_RELEASE }
const STATE_NAMES := ["DISABLED", "WAITING_HAND", "HAND_DETECTED", "ARMED", "ACTIVE", "WAITING_RELEASE"]

var joystick := HandJoystick.new()
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
			joystick.reset()
			velocity = Vector2.ZERO
var state: int = State.DISABLED
## Why the last stop / wait happened ("released", "lost", "stale", a gate reason...).
var reason := ""
## Velocity asked for this tick (mm/s, robot X / Y).
var velocity := Vector2.ZERO

# latest accepted event
var last_event: Dictionary = {}
var hand := Vector2.ZERO  # palm centre, image short-side units
var hand_norm := Vector2.ZERO  # palm centre, normalised image coords
var detected := false
var pinch := false
var camera_ok := false
var pinch_ratio := 0.0
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
	return true

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
	stop(why)

## Forced stop: zero velocity and, unless off, wait for the fingers to open.
func stop(why: String) -> void:
	joystick.reset()
	velocity = Vector2.ZERO
	if state == State.DISABLED:
		return
	if state != State.WAITING_RELEASE or reason != why:
		_set_state(State.WAITING_RELEASE, why)

## Advance one physics tick. `gate` is "" when the robot may be moved by the
## gesture, otherwise the reason it may not (shown to the player).
func tick(now_ms: float, dt: float, gate: String) -> Vector2:
	velocity = Vector2.ZERO
	if not enabled:
		return velocity
	if state == State.DISABLED:
		_set_state(State.WAITING_HAND, "")
	var fresh := _last_recv_ms >= 0.0 and now_ms - _last_recv_ms <= stale_ms
	if not fresh or not camera_ok:
		var why := "camera_lost" if fresh and not camera_ok else ("no_events" if _last_recv_ms < 0.0 else "stale")
		if state in [State.ARMED, State.ACTIVE]:
			stop(why)
		elif state == State.HAND_DETECTED:
			_set_state(State.WAITING_HAND, why)
		elif state == State.WAITING_HAND and reason != why:
			reason = why
		return velocity
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
			if pinch:
				stop("release_first")  # it was already pinching when it came into view
			else:
				_set_state(State.HAND_DETECTED, "")
		State.HAND_DETECTED:
			if pinch:
				if gate != "":
					stop(gate)
				else:
					joystick.set_anchor(hand)
					_armed_ms = now_ms
					_set_state(State.ARMED, "")
		State.ARMED:
			if not pinch:
				_set_state(State.HAND_DETECTED, "released")
				joystick.reset()
			elif gate != "":
				stop(gate)
			elif now_ms - _armed_ms >= arm_delay_ms:
				_set_state(State.ACTIVE, "")
		State.ACTIVE:
			if not pinch:
				joystick.reset()
				_set_state(State.HAND_DETECTED, "released")
			elif gate != "":
				stop(gate)
			else:
				velocity = joystick.update(hand, dt)
		State.WAITING_RELEASE:
			if not pinch:
				_set_state(State.HAND_DETECTED, reason)
	return velocity

func _set_state(s: int, why: String) -> void:
	var from := state
	state = s
	reason = why
	if from != s:
		state_changed.emit(from, s, why)
