extends Node
## Autoload: single source of truth for what we know about the REAL machine
## (or the MockRobot standing in for it). Physics never writes here; it only
## reads. Both MockRobot and WebSocketClient push samples into this node.
##
## Positions are kept in robot units (mm). Normalised helpers convert to the
## rope world frame. A short sample buffer and a playback clock
## (`playback_pose`) turn irregular status updates into a smooth signal for
## the 60 Hz rope physics.

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
## The backend's current `error` field, mirrored as-is (empty once it clears).
var robot_error: String = ""
## True when the position is the firmware's reported value, false when it is
## estimated by the host from commanded targets.
var position_is_measured: bool = true

## Playback runs behind the newest sample by a delay that covers the longest
## recent gap between samples, so it always interpolates between two real
## samples instead of running dry (hold, then jump = chatter) or
## extrapolating (overshoots on every stop and the rope whips back).
## delay = max(mean interval * DELAY_INTERVALS, recent peak gap * DELAY_PEAK_MARGIN)
## A sample arrives up to one interval after the one before, so more than two
## intervals keep one sample ahead of the playback point; the cubic needs it to
## know the velocity there (30 Hz: ~73 ms, 60 Hz mock: ~37 ms).
const PLAYBACK_DELAY_INTERVALS := 2.2
const PLAYBACK_DELAY_PEAK_MARGIN := 1.3
const PLAYBACK_DELAY_MIN_MS := 20.0
const PLAYBACK_DELAY_MAX_MS := 200.0
## Per-sample decay of the peak gap (0.995 at 30 Hz: half-life ~4.6 s).
const GAP_PEAK_DECAY := 0.995
## Sender clock - local clock is a slow average over samples (per-sample
## weight). Single receive times jitter by a physics tick plus network delay;
## the average does not, and a late sample only shortens the lead for a
## moment. A sample further off than OFFSET_RESET_MS restarts the average.
const OFFSET_SMOOTHING := 0.02
const OFFSET_RESET_MS := 100.0
## Playback slows down smoothly once it gets closer than this fraction of the
## delay to the newest sample (a stalled sender), instead of hitting it.
const PLAYBACK_SOFT_STOP := 0.15
## Max speed-up / slow-down of the playback clock while it steers (fraction).
const PLAYBACK_MAX_SKEW := 0.25
## A gap longer than this (stall, reconnect, sender clock reset) restarts the
## buffer: playback jumps to the new sample instead of gliding across the gap.
const SAMPLE_GAP_RESET_MS := 500.0
const BUFFER_SIZE := 16

# latest raw sample (mm)
var x_mm: float = 195.0
var y_mm: float = 100.0
var z_mm: float = 100.0
# sample buffer, times in the sender's clock (ms)
var _buf_t := PackedFloat64Array()
var _buf_p := PackedVector3Array()
## Local clock (ms) advanced by the physics dt in playback_pose(). Receive
## times and "now" are both read from it, so ticks that Godot batches after a
## slow frame do not look like the sender speeding up or stalling.
var _local_ms: float = 0.0
var _last_recv_ms: float = 0.0
var _offset_ms: float = 0.0 # sender clock - local clock
var _offset_valid := false
var _interval_ms: float = 1000.0 / 30.0
var _gap_peak_ms: float = 1000.0 / 30.0
var _play_ms: float = 0.0
var _play_started := false

func _ready() -> void:
	var r := GameConfig.robot()
	x_mm = (r.x_min_mm + r.x_max_mm) * 0.5
	y_mm = (r.y_min_mm + r.y_max_mm) * 0.5
	z_mm = r.z_max_mm if r.z_up_is_positive else r.z_min_mm

## Push a new sample. `timestamp_ms` is the sender's clock in ms (0 = use the
## local receive time). Only differences between timestamps are used, so the
## sender clock may have any origin.
func push_pose(x: float, y: float, z: float, state: String = "", timestamp_ms: float = 0.0, measured: bool = true) -> void:
	var t := timestamp_ms if timestamp_ms > 0.0 else _local_ms
	var p := Vector3(x, y, z)
	var n := _buf_t.size()
	if n > 0 and absf(t - _buf_t[n - 1]) > SAMPLE_GAP_RESET_MS:
		clear_samples()
		n = 0
	if n > 0 and t <= _buf_t[n - 1]:
		# Same (or older) timestamp: newest value wins, time stays monotonic.
		_buf_p[n - 1] = p
	elif n > 1 and t - _buf_t[n - 1] < 0.3 * _interval_ms:
		# Burst after a stall (samples ms apart): a segment that short makes the
		# cubic's slopes meaningless, so treat it as an update of the newest.
		_buf_t[n - 1] = t
		_buf_p[n - 1] = p
	else:
		if n > 0:
			var gap := t - _buf_t[n - 1]
			_interval_ms = lerpf(_interval_ms, gap, 0.1)
			# The delay has to cover late arrival too, not only irregular
			# sending, so the peak also looks at the local receive gap.
			var recv_gap := _local_ms - _last_recv_ms
			_gap_peak_ms = maxf(maxf(gap, recv_gap), _gap_peak_ms * GAP_PEAK_DECAY)
		_buf_t.append(t)
		_buf_p.append(p)
		var off := t - _local_ms
		if not _offset_valid or absf(off - _offset_ms) > OFFSET_RESET_MS:
			_offset_ms = off
			_offset_valid = true
		else:
			_offset_ms = lerpf(_offset_ms, off, OFFSET_SMOOTHING)
		if _buf_t.size() > BUFFER_SIZE:
			_buf_t.remove_at(0)
			_buf_p.remove_at(0)
	_last_recv_ms = _local_ms
	x_mm = x
	y_mm = y
	z_mm = z
	position_is_measured = measured
	if state != "":
		machine_state = state
	pose_updated.emit(x, y, z, machine_state)

func report_error(msg: String) -> void:
	last_error = msg
	error_reported.emit(msg)

## Drop buffered samples (source switch): playback restarts at the next sample.
func clear_samples() -> void:
	_buf_t.clear()
	_buf_p.clear()
	_play_started = false
	_offset_valid = false

## Smoothed pose for the rope. Call exactly once per physics tick with the
## fixed `dt`. The playback clock advances by `dt` and is only gently steered
## towards "sender's current time - delay", so frame pacing jitter, batched
## physics ticks and network jitter do not reach the anchor (the rope
## differentiates the anchor twice, which turns tiny timing noise into large
## accelerations). If the sender stalls, playback eases to a stop at the
## newest sample rather than stopping dead and jumping when data resumes.
func playback_pose(dt: float) -> Vector3:
	var dt_ms := dt * 1000.0
	_local_ms += dt_ms
	var n := _buf_t.size()
	if n == 0:
		return Vector3(x_mm, y_mm, z_mm)
	var newest := _buf_t[n - 1]
	var delay := playback_delay_ms()
	var sender_now := maxf(_local_ms + _offset_ms, newest)
	var target := sender_now - delay
	if not _play_started or absf(target - _play_ms) > 250.0:
		_play_ms = target
		_play_started = true
	else:
		var skew := clampf((target - _play_ms) * 0.05, -PLAYBACK_MAX_SKEW * dt_ms, PLAYBACK_MAX_SKEW * dt_ms)
		var advance := dt_ms + skew
		var soft := PLAYBACK_SOFT_STOP * delay
		var lead := newest - _play_ms
		if lead < soft:
			advance *= clampf(lead / soft, 0.0, 1.0)
		_play_ms += advance
	return sample_at(_play_ms)

## For the motion log: playback clock, newest sample time, its local receive
## time (all ms) and the current playback delay.
func playback_debug() -> Array:
	var newest := _buf_t[_buf_t.size() - 1] if not _buf_t.is_empty() else 0.0
	return [_play_ms, newest, _last_recv_ms, playback_delay_ms()]

## How far (ms) playback runs behind the newest sample.
func playback_delay_ms() -> float:
	var d := maxf(_interval_ms * PLAYBACK_DELAY_INTERVALS, _gap_peak_ms * PLAYBACK_DELAY_PEAK_MARGIN)
	return clampf(d, PLAYBACK_DELAY_MIN_MS, PLAYBACK_DELAY_MAX_MS)

## Pose at sender time `t_ms` from the buffer. Holds the oldest/newest sample
## outside the buffered range (never extrapolates). Between samples it uses a
## monotone cubic (per axis): velocity stays continuous across samples, so a
## 30 Hz stream does not turn acceleration into 0 / 2x pulses the way linear
## interpolation does, and it never overshoots a sample (a stop stays a stop).
func sample_at(t_ms: float) -> Vector3:
	var n := _buf_t.size()
	if n == 0:
		return Vector3(x_mm, y_mm, z_mm)
	if t_ms >= _buf_t[n - 1]:
		return _buf_p[n - 1]
	if t_ms <= _buf_t[0]:
		return _buf_p[0]
	var i := n - 1
	while i > 1 and t_ms < _buf_t[i - 1]:
		i -= 1
	var t0 := _buf_t[i - 1]
	var t1 := _buf_t[i]
	var h := t1 - t0
	if h <= 0.0:
		return _buf_p[i]
	var p0 := _buf_p[i - 1]
	var p1 := _buf_p[i]
	var slope := (p1 - p0) / h
	var slope_before := (p0 - _buf_p[i - 2]) / (t0 - _buf_t[i - 2]) if i >= 2 and t0 > _buf_t[i - 2] else slope
	var has_after := i + 1 < n and _buf_t[i + 1] > t1
	var slope_after := (_buf_p[i + 1] - p1) / (_buf_t[i + 1] - t1) if has_after else slope
	var s := (t_ms - t0) / h
	var s2 := s * s
	var s3 := s2 * s
	var out := Vector3.ZERO
	for axis in range(3):
		var m0 := _monotone_tangent(slope_before[axis], slope[axis])
		var m1 := _monotone_tangent(slope[axis], slope_after[axis])
		if not has_after:
			# Newest segment (playback ran ahead of the delay): no sample after
			# it yet, so continue the trend of the last two segments instead
			# of falling back to the chord, limited so it cannot reverse or
			# overshoot.
			var trend := 1.5 * slope[axis] - 0.5 * slope_before[axis]
			m1 = clampf(trend, minf(0.0, 3.0 * slope[axis]), maxf(0.0, 3.0 * slope[axis]))
		out[axis] = (2.0 * s3 - 3.0 * s2 + 1.0) * p0[axis] + (s3 - 2.0 * s2 + s) * h * m0 \
			+ (-2.0 * s3 + 3.0 * s2) * p1[axis] + (s3 - s2) * h * m1
	return out

## Tangent at a sample between two segment slopes (Fritsch-Carlson style):
## zero at a turn or a stop, otherwise the mean, limited so the curve cannot
## leave the range of its two samples.
static func _monotone_tangent(a: float, b: float) -> float:
	if a * b <= 0.0:
		return 0.0
	var m := 0.5 * (a + b)
	var limit := 3.0 * minf(absf(a), absf(b))
	return clampf(m, -limit, limit)

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

## World X travel (cm) the robot's full X range maps to: the screen-fitted value
## (world.travel_x_fit_cm, written by the main scene from the play area) when
## world.fit_travel_x_to_screen is on, else the fixed world.travel_x_cm.
func travel_x_cm() -> float:
	var w: Dictionary = GameConfig.data["world"]
	var fitted := float(w.get("travel_x_fit_cm", 0.0))
	if bool(w.get("fit_travel_x_to_screen", false)) and fitted > 0.0:
		return fitted
	return float(w.travel_x_cm)

## Anchor position in the rope world frame for a robot XY (mm).
## Robot X+ = screen right. Robot Y+ = away from the player (into the screen).
func anchor_for_xy(x_value_mm: float, y_value_mm: float) -> Vector3:
	var r := GameConfig.robot()
	var w: Dictionary = GameConfig.data["world"]
	var nx := _norm(x_value_mm, r.x_min_mm, r.x_max_mm)
	var ny := _norm(y_value_mm, r.y_min_mm, r.y_max_mm)
	return Vector3((nx - 0.5) * travel_x_cm(), 0.0, -(ny - 0.5) * w.travel_z_cm)

static func _norm(v: float, lo: float, hi: float) -> float:
	if hi - lo == 0.0:
		return 0.0
	return clampf((v - lo) / (hi - lo), 0.0, 1.0)
