class_name StaffRemote
extends RefCounted
## The staff remote (M5StopWatch, UFO-DeviceHub device 0x30): what its events mean here.
## They come from the backend as `devicehub_event` messages (the device hub's events, #108);
## the remote only reports, this side decides.
##
##   STAFF_ACTION {action}   one of StaffControl's operations (NEXT / SKIP / MENU / RECOVER /
##                           SWITCH / STOP): StaffControl.run(action, "remote"), as F6..F10 / Space.
##   REMOTE_INPUT {move, z, x, y, pose, frame}
##                           the remote as a hand: a `hand_control` event for GestureControl, the
##                           same way the camera's hand and the mouse simulation go. The move key
##                           held = a pinch (its tilt, -100..100, the stick's offset; z = a
##                           palm-down pinch, the forward tilt raises the arm), pose = the hand's
##                           shape (FIST / PEACE / POINT; OPEN = neutral). So the claw, the easy
##                           mode's signs and the practice's steps all work as with the hand, with
##                           all of GestureControl's gates, latches and stale-stops.
##
## A press of the move key is shown as the hand would make it: the first frame an open hand
## (GestureControl latches a pinch that is already there when the hand appears), the second
## the pinch at the stick's centre (where a pinch starts is the stick's centre), then the
## tilt. So the arm starts ~0.2 s after the press, and only from the centre.
##
## The remote sends a frame every 100 ms while anything is held, one closing frame, then
## nothing: its hand goes stale and the stick stops. While its frames come, the camera's hand
## events are not used (present()). Pure logic: nothing here sends anything.

const SOURCE := "remote"
const POSES := {"OPEN": "open", "FIST": "fist", "PEACE": "peace", "POINT": "point"}
## the remote's frames are this recent: it is the hand (the camera's events are not used)
var hold_ms := 600.0
## a frame number not after the last one is dropped (late / repeated), unless the stream
## paused this long (the remote rebooted: its numbers start over)
var restart_ms := 2000.0

var last_frame := -1
var last_frame_ms := -1.0
var frames := 0
var dropped := 0
## what came last, for the debug panel / tests
var last_input: Dictionary = {}
var last_action := ""
## frames in a row with the move key held (0 = not held)
var move_frames := 0

## The remote's input is the hand now.
func present(now_ms: float) -> bool:
	return last_frame_ms >= 0.0 and now_ms - last_frame_ms <= hold_ms

## The staff operation of a STAFF_ACTION event ("" = not one; the names are StaffControl's).
static func staff_action_of(data: Dictionary) -> String:
	var a := str(data.get("action", "")).to_lower()
	return a if a in StaffControl.ACTIONS else ""

## Is this a newer frame than `last` (16-bit numbers that wrap)?
static func frame_newer(frame: int, last: int) -> bool:
	if last < 0:
		return true
	var d := (frame - last) & 0xFFFF
	return d != 0 and d < 0x8000

## A REMOTE_INPUT frame received at `now_ms`: true when it is to be used (in order).
func accept_frame(d: Dictionary, now_ms: float) -> bool:
	var f := int(d.get("frame", -1))
	var restarted := last_frame_ms < 0.0 or now_ms - last_frame_ms > restart_ms
	if f < 0 or (not restarted and not frame_newer(f, last_frame)):
		dropped += 1
		return false
	if not present(now_ms):
		move_frames = 0  # a new stream: a held key starts as a new press
	last_frame = f
	last_frame_ms = now_ms
	frames += 1
	last_input = d.duplicate()
	return true

## The hand offset (image short-side units, image axes: x right, y down) that `joystick`
## (HandJoystick, with its flips and swap) reads as the remote's stick: right = robot +X,
## forward = robot +Y; in z: forward = arm up. -100..100 per axis; 100 = full speed, any
## other value outside the remote's own dead zone moves (the stick's dead zone is skipped).
static func hand_offset(x: float, y: float, z: bool, joystick: HandJoystick) -> Vector2:
	var radius := joystick.radius
	var dead := joystick.deadzone
	var full := joystick.full
	if z:
		var m := clampf(absf(y) / 100.0, 0.0, 1.0)
		if m <= 0.0:
			return Vector2.ZERO
		var stick_z := signf(y)  # + = arm up
		if joystick.invert_z:
			stick_z = -stick_z
		if joystick.view_flip_v:
			stick_z = -stick_z
		var r := (dead + (full - dead) * m) * radius
		return Vector2(0.0, -stick_z * r)  # image y grows downwards
	var v := Vector2(x, y) / 100.0
	var m2 := clampf(v.length(), 0.0, 1.0)
	if m2 <= 0.0:
		return Vector2.ZERO
	# undo HandJoystick.to_robot: the inverts, the swap, then image y down
	var rv := v.normalized()
	if joystick.invert_x:
		rv.x = -rv.x
	if joystick.invert_y:
		rv.y = -rv.y
	if joystick.swap_xy:
		rv = Vector2(rv.y, rv.x)
	var img := Vector2(rv.x, -rv.y)
	return img * ((dead + (full - dead) * m2) * radius)

## The `hand_control` event (GestureControl.on_event) for a REMOTE_INPUT frame. `sequence`
## goes after the gesture's last one, so the two sources never undo each other's order.
static func hand_event(d: Dictionary, joystick: HandJoystick, sequence: int) -> Dictionary:
	var move := bool(d.get("move", false))
	var z := move and bool(d.get("z", false))
	var off := hand_offset(float(d.get("x", 0)), float(d.get("y", 0)), z, joystick) if move else Vector2.ZERO
	var c := Vector2(0.5, 0.5)
	var pose: String = POSES.get(str(d.get("pose", "OPEN")), "open")
	return {"event": "hand_control", "source": SOURCE, "camera_ok": true, "detected": true, "hand_count": 1,
		"pinch": move, "pinch_finger": "index" if move else "", "pose": pose, "palm": "down" if z else "up",
		"hand_x": c.x + off.x, "hand_y": c.y + off.y, "frame_w": 1.0, "frame_h": 1.0,
		"point_dx": 0.0, "point_dy": -1.0 if pose == "point" else 0.0, "point_len": 1.0 if pose == "point" else 0.0,
		"thumb_dx": 0.0, "thumb_dy": 0.0, "pinch_ratio": 0.2 if move else 0.8, "confidence": 1.0, "in_roi": true,
		"reason": "", "sequence": sequence, "latency_ms": 0.0,
		"timestamp": int(Time.get_unix_time_from_system() * 1000.0)}

## The frame as the hand shows it: a new press is an open hand, then a pinch at the centre,
## then the tilt (see above). Counts the frames of the press.
func staged(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	if not bool(d.get("move", false)):
		move_frames = 0
		return out
	move_frames += 1
	if move_frames <= 2:
		out["x"] = 0
		out["y"] = 0
		if move_frames == 1:
			out["move"] = false
	return out

## A backend message. Returns what to do: {"staff": action} / {"hand": d (the REMOTE_INPUT
## data, in order)} / {} (not the remote's, or dropped).
func on_message(msg: Dictionary, now_ms: float) -> Dictionary:
	if str(msg.get("type", "")) != "devicehub_event" or not msg.get("data") is Dictionary:
		return {}
	var ev: Dictionary = msg["data"]
	var d = ev.get("data", {})
	if not d is Dictionary:
		return {}
	match str(ev.get("name", "")):
		"STAFF_ACTION":
			var a := staff_action_of(d)
			if a != "":
				last_action = a
				return {"staff": a}
		"REMOTE_INPUT":
			if accept_frame(d, now_ms):
				return {"hand": staged(d)}
	return {}
