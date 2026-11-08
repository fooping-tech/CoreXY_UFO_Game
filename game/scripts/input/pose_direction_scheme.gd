class_name PoseDirectionScheme
extends GestureScheme
## A hand shape per direction: holding a shape (the backend's `pose`: "open" =
## パー, "peace" = チョキ, "fist" = グー) moves the crane one way at a set speed,
## e.g. open -> +X, peace -> -X. No stick, no anchor: where the hand is does
## not matter, only its shape.
##
##   - a shape counts once it has been held for pose_confirm_ms (a hand passing
##     through it on the way to another shape does not move anything)
##   - a confirmed shape survives a flicker shorter than pose_release_ms (the
##     backend's shape is per frame, not smoothed)
##   - another shape lets go of the steer first (the frame goes back to
##     HAND_DETECTED and arms again after its arm delay): never a reversal on the spot
##   - after a forced stop the shape must be gone for pose_release_ms before
##     anything moves again (`sign_seen`)
##   - a shape used for a direction never moves the claw
## Directions are robot axes: [x, y, z] (+X right, +Y away, +Z arm up).

const ID := "pose_direction"
## Japanese names for the HUD.
const POSE_NAMES := {"open": "パー", "peace": "チョキ", "fist": "グー"}

## pose -> direction (robot axes, any length: normalised per part).
var directions := {"open": Vector3(1, 0, 0), "peace": Vector3(-1, 0, 0)}
var speed_mm_s := 20.0
var speed_z := 10.0  # z units/s
var pose_confirm_ms := 150.0
var pose_release_ms := 150.0
var smoothing_ms := 80.0
## pose -> claw ("closed" / "open"); shapes used by `directions` are dropped.
var claw := {"fist": "closed"}

var _active := ""  # the confirmed shape ("" = none)
var _miss_since := -1.0  # when the confirmed shape stopped showing
var _cand := ""  # a shape waiting for its confirmation
var _cand_since := 0.0
## What the latch watches: the direction shape being shown, when it was last
## seen, and another direction shape taking over from it.
var _shown := ""
var _last_shown_ms := -1.0
var _other := ""
var _other_since := 0.0
var _seen := false
var _armed := ""  # the shape the steer armed with
var _out := Vector3.ZERO  # smoothed output

func id() -> String:
	return ID

func configure(c: Dictionary) -> void:
	var d = c.get("directions", null)
	if d is Dictionary:
		var dirs := {}
		for k in d:
			var v = d[k]
			if v is Array and v.size() == 3:
				dirs[str(k)] = Vector3(float(v[0]), float(v[1]), float(v[2]))
			else:
				push_warning("gesture pose_direction: direction of '%s' must be [x, y, z]" % k)
		directions = dirs
	speed_mm_s = float(c.get("speed_mm_s", speed_mm_s))
	speed_z = float(c.get("speed_z", speed_z))
	pose_confirm_ms = float(c.get("pose_confirm_ms", pose_confirm_ms))
	pose_release_ms = float(c.get("pose_release_ms", pose_release_ms))
	smoothing_ms = float(c.get("smoothing_ms", smoothing_ms))
	var cl = c.get("claw", null)
	if cl is Dictionary:
		claw = cl.duplicate()
	for k in claw.keys():
		if directions.has(k):
			push_warning("gesture pose_direction: '%s' moves the crane, so it does not move the claw" % k)
			claw.erase(k)

func engaged(g, now_ms: float) -> bool:
	var p: String = g.pose if directions.has(g.pose) else ""
	_track_shown(p, now_ms)
	if _active != "":
		if p == _active:
			_miss_since = -1.0
			return true
		if _miss_since < 0.0:
			_miss_since = now_ms
		if now_ms - _miss_since < pose_release_ms:
			return true  # a flicker: keep the shape a moment longer
		_active = ""
		_miss_since = -1.0
	if p == "":
		_cand = ""
		return false
	if p != _cand:
		_cand = p
		_cand_since = now_ms
	if now_ms - _cand_since >= pose_confirm_ms:
		_active = p
		_cand = ""
		_miss_since = -1.0
		return true
	return false

## The sign the latch waits on: the shape shown, kept through a flicker shorter
## than pose_release_ms. It is let go when no direction shape has been seen for
## that long, or when another direction shape has been held for that long (a
## new sign: the latch lifts for that tick, the new shape then confirms as usual).
## A one-frame misread of another shape lifts nothing.
func _track_shown(p: String, now_ms: float) -> void:
	_seen = true
	if p != "" and (_shown == "" or p == _shown):
		_shown = p
		_last_shown_ms = now_ms
		_other = ""
		return
	if p != "":
		if p != _other:
			_other = p
			_other_since = now_ms
		if now_ms - _other_since >= pose_release_ms:
			_shown = p  # held long enough: another sign, not a misread
			_last_shown_ms = now_ms
			_other = ""
			_seen = false
			_active = ""  # the old shape is over too (its flicker grace must not hide this tick)
			_miss_since = -1.0
		return
	_other = ""
	if _shown == "" or now_ms - _last_shown_ms >= pose_release_ms:
		_shown = ""
		_seen = false

func sign_seen(_g) -> bool:
	return _seen

func same_engagement(_g) -> bool:
	return _active == _armed

func on_arm(g, _now_ms: float) -> void:
	_armed = _active
	_out = Vector3.ZERO
	var d: Vector3 = directions.get(_armed, Vector3.ZERO)
	g.mode = "z" if d.z != 0.0 and d.x == 0.0 and d.y == 0.0 else "xy"

## The velocity a shape asks for: XY at speed_mm_s, Z at speed_z.
func target_for(pose: String) -> Vector3:
	var d: Vector3 = directions.get(pose, Vector3.ZERO)
	var xy := Vector2(d.x, d.y)
	if xy.length() > 1e-6:
		xy = xy.normalized() * speed_mm_s
	return Vector3(xy.x, xy.y, signf(d.z) * speed_z)

func velocity(_g, dt: float) -> Vector3:
	var target := target_for(_armed)
	var a := 1.0 if smoothing_ms <= 0.0 else 1.0 - exp(-dt * 1000.0 / smoothing_ms)
	_out = _out.lerp(target, a)
	return _out

## Forgets the steer only. The shape tracking stays: a shape held across a stop
## must still be let go before it counts again.
func reset(_g) -> void:
	_armed = ""
	_out = Vector3.ZERO

func claw_poses() -> Dictionary:
	return claw

func max_speed(_g) -> float:
	return speed_mm_s

## "パー=右 チョキ=左" from the directions.
func mapping_text() -> String:
	var parts: Array[String] = []
	for k in directions:
		parts.append("%s=%s" % [POSE_NAMES.get(k, k), direction_word(directions[k])])
	for k in claw:
		parts.append("%s=爪%s" % [POSE_NAMES.get(k, k), "閉" if claw[k] == "closed" else "開"])
	return " ".join(parts)

static func direction_word(d: Vector3) -> String:
	var w := ""
	if d.x > 0.0:
		w += "右"
	elif d.x < 0.0:
		w += "左"
	if d.y > 0.0:
		w += "奥"
	elif d.y < 0.0:
		w += "手前"
	if d.z > 0.0:
		w += "上"
	elif d.z < 0.0:
		w += "下"
	return w if w != "" else "-"

func prompt() -> Array[String]:
	return ["✋ 手の形で操縦", mapping_text()]

func steer_hint() -> String:
	return "手の形を変えると止まるよ"

func release_hint() -> String:
	return "いったん別の手の形にしてね"
