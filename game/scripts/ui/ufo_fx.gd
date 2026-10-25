class_name UfoFx
extends Node2D
## Over-the-top ("dopamine") particles around the UFO, driven by how it moves.
##
## Presentation only: it reads motion intensities computed from the physics and
## the UFO's screen position, and never writes back to the simulation or robot.
## Uses the Codex effect sheets (sparkles / stars / motion_lines, 16x16 x 4
## frames) so the pixel-art look stays consistent, tinted with a cycling rainbow.
##
##   trail   - while moving: sparkles/stars streaming away opposite the motion
##   thrust  - UFO rising (arm going down): jets spraying out below the saucer
##   sprinkle- UFO sinking (arm going up): glitter floating up above it
##   bursts  - motion starts: a star pop; motion stops: sparkle pop + shock ring
##
## The real robot's speed can drop to zero for a frame or two while a key is
## held (sample jitter), so a stop counts only after STOP_HOLD_S below the
## threshold: holding a key gives one start and one stop, not a burst per dropout.

## Emitted when a real move stops (strength 0..1) so the screen can shake.
signal kicked(strength: float)

const MAX_PARTICLES := 300
const START_THRESHOLD := 0.25
const STOP_THRESHOLD := 0.05
## Below STOP_THRESHOLD this long before the motion counts as stopped.
const STOP_HOLD_S := 0.2
## Only a move that lasted this long shakes the screen when it stops.
const SHAKE_MIN_MOVE_S := 0.4

var enabled := true
var pixel_scale := 3.0
## Scales every emission and burst (config render.particle_amount).
var amount := 1.0
## Particles per second at full intensity.
var trail_rate := 70.0
var jet_rate := 60.0

var _tex: Dictionary = {}
var _parts: Array[Dictionary] = []
var _rings: Array[Dictionary] = []
var _emit_acc := {"trail": 0.0, "jet": 0.0}
var _active := false  # moving in any way (with hysteresis)
var _peak := 0.0  # strongest intensity since the motion started
var _below_s := 0.0  # how long the intensity has been under STOP_THRESHOLD
var _moving_s := 0.0  # how long the current motion has lasted
var _hue := 0.0
var _rng := RandomNumberGenerator.new()
## Motions started / stopped so far (for tests and the debug log).
var start_count := 0
var stop_count := 0

func _ready() -> void:
	for n in ["sparkles", "stars", "motion_lines"]:
		var p := "res://assets/effects/%s.png" % n
		if ResourceLoader.exists(p):
			_tex[n] = load(p)
	_rng.randomize()
	# additive: overlapping sparks add up to a glow
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat

func particle_count() -> int:
	return _parts.size()

func ring_count() -> int:
	return _rings.size()

## Called every render frame. `ufo_px` = UFO body centre on screen, `scale` its
## perspective scale, `screen_vel` its screen velocity (px/s), intensities 0..1.
func update_fx(ufo_px: Vector2, scale: float, screen_vel: Vector2,
		move_i: float, up_i: float, down_i: float, dt: float) -> void:
	_hue = fmod(_hue + dt * 0.9, 1.0)
	# start / stop detection (and the shake kicks) run even with particles off
	_emit(ufo_px, scale, screen_vel, move_i, up_i, down_i, dt)
	_step(dt)
	queue_redraw()

func _emit(ufo_px: Vector2, scale: float, screen_vel: Vector2,
		move_i: float, up_i: float, down_i: float, dt: float) -> void:
	var any := maxf(move_i, maxf(up_i, down_i))
	_peak = maxf(_peak, any) if _active else 0.0
	if not _active and any > START_THRESHOLD:
		_active = true
		_peak = any
		_below_s = 0.0
		_moving_s = 0.0
		start_count += 1
		if enabled:
			_burst(ufo_px, scale, "stars", 14, 160.0, 320.0)
	elif _active:
		_moving_s += dt
		_below_s = _below_s + dt if any < STOP_THRESHOLD else 0.0
		if _below_s >= STOP_HOLD_S:
			_active = false
			stop_count += 1
			if _moving_s - _below_s >= SHAKE_MIN_MOVE_S:  # the stop-confirmation wait is not motion
				kicked.emit(0.25 + 0.35 * _peak)  # a harder stop after a faster move
			if enabled:
				_burst(ufo_px, scale, "sparkles", 20, 120.0, 300.0)
				_burst(ufo_px, scale, "stars", 8, 60.0, 160.0)
				_rings.append({"p": ufo_px, "t": 0.0, "life": 0.45, "r0": 20.0 * scale, "r1": 150.0 * scale})
	if not enabled:
		return
	var s := pixel_scale * scale
	# trail: opposite to the motion, faster when moving faster
	_emit_acc.trail += trail_rate * amount * move_i * dt
	var back := -screen_vel.normalized() if screen_vel.length() > 1.0 else Vector2.UP
	while _emit_acc.trail >= 1.0:
		_emit_acc.trail -= 1.0
		var jitter := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 28.0 * scale
		var v := back.rotated(_rng.randf_range(-0.6, 0.6)) * _rng.randf_range(60.0, 180.0) * (0.6 + move_i)
		_spawn(ufo_px + jitter, v, "sparkles" if _rng.randf() < 0.6 else "stars", _rng.randf_range(0.5, 1.0),
			s * _rng.randf_range(0.8, 1.5), 0.0)
	# vertical jets
	_emit_acc.jet += jet_rate * amount * maxf(up_i, down_i) * dt
	while _emit_acc.jet >= 1.0:
		_emit_acc.jet -= 1.0
		if up_i >= down_i:
			# rising: thrust sprays down from under the saucer
			var p := ufo_px + Vector2(_rng.randf_range(-22, 22) * scale, 26.0 * scale)
			var v := Vector2(_rng.randf_range(-40, 40), _rng.randf_range(160, 320) * (0.5 + up_i))
			_spawn(p, v, "motion_lines" if _rng.randf() < 0.4 else "stars", _rng.randf_range(0.35, 0.7),
				s * _rng.randf_range(0.7, 1.2), 0.0)
		else:
			# sinking: glitter floats up above it
			var p := ufo_px + Vector2(_rng.randf_range(-30, 30) * scale, -30.0 * scale)
			var v := Vector2(_rng.randf_range(-50, 50), -_rng.randf_range(120, 260) * (0.5 + down_i))
			_spawn(p, v, "sparkles", _rng.randf_range(0.5, 0.9), s * _rng.randf_range(0.7, 1.2), 0.0)

func _burst(at: Vector2, scale: float, kind: String, count: int, v_lo: float, v_hi: float) -> void:
	var n := int(roundf(count * amount))
	for i in range(n):
		var ang := TAU * float(i) / float(n) + _rng.randf_range(-0.2, 0.2)
		var v := Vector2(cos(ang), sin(ang)) * _rng.randf_range(v_lo, v_hi) * scale
		_spawn(at, v, kind, _rng.randf_range(0.55, 1.0), pixel_scale * scale * _rng.randf_range(1.0, 1.7), 260.0)

func _spawn(p: Vector2, v: Vector2, kind: String, life: float, size: float, gravity: float) -> void:
	if _parts.size() >= MAX_PARTICLES:
		_parts.pop_front()  # newest wins: keep the effect following the UFO
	_parts.append({"p": p, "v": v, "kind": kind, "t": 0.0, "life": life, "size": size, "g": gravity,
		"hue": fmod(_hue + _rng.randf_range(0.0, 0.35), 1.0), "frame0": _rng.randi_range(0, 3)})

func _step(dt: float) -> void:
	for p in _parts:
		p.t += dt
		p.v.y += p.g * dt
		p.v *= exp(-1.8 * dt)  # air drag: bursts slow down, trails linger
		p.p += p.v * dt
	_parts = _parts.filter(func(p): return p.t < p.life)
	for r in _rings:
		r.t += dt
	_rings = _rings.filter(func(r): return r.t < r.life)

func _draw() -> void:
	for r in _rings:
		if r.t < 0.0:
			continue
		var k: float = r.t / r.life
		var c := Color.from_hsv(fmod(_hue + k * 0.5, 1.0), 0.8, 1.0, 1.0 - k)
		draw_arc(r.p, lerpf(r.r0, r.r1, k), 0.0, TAU, 48, c, pixel_scale * 2.5 * (1.0 - 0.5 * k), false)
	for p in _parts:
		var k: float = p.t / p.life
		var size: float = p.size * (1.0 - 0.6 * k) * 16.0
		var c := Color.from_hsv(p.hue, 0.9, 1.0, 1.0 - k * k)
		var tex: Texture2D = _tex.get(p.kind)
		if tex != null:
			var frame := (int(p.frame0) + int(p.t * 12.0)) % 4
			draw_texture_rect_region(tex, Rect2(p.p - Vector2(size, size) * 0.5, Vector2(size, size)),
				Rect2(frame * 16, 0, 16, 16), c)
		else:
			draw_rect(Rect2(p.p - Vector2(size, size) * 0.25, Vector2(size, size) * 0.5), c)
