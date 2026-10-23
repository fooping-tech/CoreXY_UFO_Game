extends Node
## Autoload: single source of truth for what we know about the REAL machine
## (or the MockRobot standing in for it). Physics never writes here; it only
## reads. Both MockRobot and WebSocketClient push samples into this node.
##
## Positions are kept in robot units (mm). Normalised helpers convert to the
## rope world frame. A tiny two-sample buffer lets the renderer interpolate
## between status updates that arrive slower than 60 Hz.

signal pose_updated(x: float, y: float, z: float, state: String)
signal machine_state_changed(state: String)
signal connection_changed(connected: bool)
signal source_changed(source: String)
signal error_reported(message: String)

## Machine motion states as the firmware reports them (mapped by the backend).
const STATES := ["UNKNOWN", "IDLE", "HOMING", "MOVING_XY", "Z_LOWERING", "Z_RAISING", "GRABBING", "RELEASING", "ALARM", "ESTOP"]

var source: String = "mock": # "mock" | "websocket"
	set(v):
		if v != source:
			source = v
			source_changed.emit(v)
var connected: bool = false:
	set(v):
		if v != connected:
			connected = v
			connection_changed.emit(v)
var homed: bool = false
var motors_enabled: bool = false
var machine_state: String = "UNKNOWN":
	set(v):
		if v != machine_state:
			machine_state = v
			machine_state_changed.emit(v)
var last_error: String = ""
## True when the position is the firmware's reported value, false when it is
## estimated by the host from commanded targets.
var position_is_measured: bool = true

# raw samples (mm, ms)
var x_mm: float = 195.0
var y_mm: float = 100.0
var z_mm: float = 100.0
var sample_time_ms: int = 0
var _prev_x: float = 195.0
var _prev_y: float = 100.0
var _prev_z: float = 100.0
var _prev_time_ms: int = 0
var _time_offset_ms: int = 0 # remote clock -> local clock

func _ready() -> void:
	var r := GameConfig.robot()
	x_mm = (r.x_min_mm + r.x_max_mm) * 0.5
	y_mm = (r.y_min_mm + r.y_max_mm) * 0.5
	z_mm = r.z_max_mm if r.z_up_is_positive else r.z_min_mm
	_prev_x = x_mm
	_prev_y = y_mm
	_prev_z = z_mm
	sample_time_ms = Time.get_ticks_msec()
	_prev_time_ms = sample_time_ms

## Push a new sample. `timestamp_ms` is the sender's clock (0 = now).
func push_pose(x: float, y: float, z: float, state: String = "", timestamp_ms: int = 0, measured: bool = true) -> void:
	var now := Time.get_ticks_msec()
	var t := now
	if timestamp_ms > 0:
		# Align remote clock to local clock on the first sample, then use it.
		if _time_offset_ms == 0:
			_time_offset_ms = now - timestamp_ms
		t = timestamp_ms + _time_offset_ms
		# Never let a sample land in the future beyond one frame.
		t = mini(t, now + 16)
	_prev_x = x_mm
	_prev_y = y_mm
	_prev_z = z_mm
	_prev_time_ms = sample_time_ms
	x_mm = x
	y_mm = y
	z_mm = z
	sample_time_ms = t
	position_is_measured = measured
	if state != "":
		machine_state = state
	pose_updated.emit(x, y, z, machine_state)

func report_error(msg: String) -> void:
	last_error = msg
	error_reported.emit(msg)

## Interpolated pose for rendering at local time `now_ms`. Extrapolates up to
## `max_extrapolate_ms` so slow status polls still look continuous.
func interpolated_pose(now_ms: int, max_extrapolate_ms: int = 120) -> Vector3:
	var span := sample_time_ms - _prev_time_ms
	if span <= 0:
		return Vector3(x_mm, y_mm, z_mm)
	var t := float(now_ms - _prev_time_ms) / float(span)
	var tmax := 1.0 + float(max_extrapolate_ms) / float(span)
	t = clampf(t, 0.0, tmax)
	return Vector3(
		lerpf(_prev_x, x_mm, t),
		lerpf(_prev_y, y_mm, t),
		lerpf(_prev_z, z_mm, t))

## Normalised 0..1 position along each robot axis.
func normalized(pose_mm: Vector3) -> Vector3:
	var r := GameConfig.robot()
	return Vector3(
		_norm(pose_mm.x, r.x_min_mm, r.x_max_mm),
		_norm(pose_mm.y, r.y_min_mm, r.y_max_mm),
		_norm(pose_mm.z, r.z_min_mm, r.z_max_mm))

## 0 = arm fully down, 1 = arm fully up (independent of firmware sign).
func arm_height_normalized(z_value_mm: float) -> float:
	var r := GameConfig.robot()
	var n := _norm(z_value_mm, r.z_min_mm, r.z_max_mm)
	return n if r.z_up_is_positive else 1.0 - n

## INVERSE mapping (spec 6.4): arm at top -> rope longest -> UFO lowest.
func rope_length_for_z(z_value_mm: float) -> float:
	var w: Dictionary = GameConfig.data["world"]
	var h := arm_height_normalized(z_value_mm)
	return lerpf(w.rope_min_cm, w.rope_max_cm, h)

## Anchor position in the rope world frame for a robot XY (mm).
## Robot X+ = screen right. Robot Y+ = away from the player (into the screen).
func anchor_for_xy(x_value_mm: float, y_value_mm: float) -> Vector3:
	var r := GameConfig.robot()
	var w: Dictionary = GameConfig.data["world"]
	var nx := _norm(x_value_mm, r.x_min_mm, r.x_max_mm)
	var ny := _norm(y_value_mm, r.y_min_mm, r.y_max_mm)
	return Vector3((nx - 0.5) * w.travel_x_cm, 0.0, -(ny - 0.5) * w.travel_z_cm)

static func _norm(v: float, lo: float, hi: float) -> float:
	if hi - lo == 0.0:
		return 0.0
	return clampf((v - lo) / (hi - lo), 0.0, 1.0)
