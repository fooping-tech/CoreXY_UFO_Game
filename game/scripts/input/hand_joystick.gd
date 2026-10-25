class_name HandJoystick
extends RefCounted
## Relative "virtual stick" for the pinch gesture. The hand position where the
## pinch started is the centre (anchor); the offset of the hand from it gives an
## XY VELOCITY (mm/s), never a position.
##
## Positions are in units of the camera image's short side (x right, y down),
## so the stick is round whatever the image aspect. Shaping:
##   r = |offset| / radius;  0 inside the dead zone;  full speed at `full`;
##   in between ((r - dead) / (full - dead)) ^ curve;  direction kept, so a
##   diagonal never goes faster than max_speed. Then a first-order smoothing.

## Stick radius as a fraction of the image short side.
var radius := 0.15
## Dead zone and full-speed point as fractions of the radius.
var deadzone := 0.12
var full := 0.8
var max_speed := 30.0  # mm/s
var curve := 1.5
## Time constant of the output smoothing (0 = none).
var smoothing_ms := 80.0
## Image -> robot axes: right = +X, up (away from the camera's bottom edge) = +Y
## by default; flip / swap to match the real machine.
var invert_x := false
var invert_y := false
var swap_xy := false

var anchor := Vector2.ZERO
var has_anchor := false
## Shaped stick (-1..1 per axis, length <= 1), in robot axes, before smoothing.
var stick := Vector2.ZERO
## Smoothed output velocity (mm/s, robot X / Y).
var output := Vector2.ZERO

func set_anchor(hand: Vector2) -> void:
	anchor = hand
	has_anchor = true
	stick = Vector2.ZERO
	output = Vector2.ZERO

func reset() -> void:
	has_anchor = false
	stick = Vector2.ZERO
	output = Vector2.ZERO

func configure(c: Dictionary) -> void:
	radius = float(c.get("radius", radius))
	deadzone = float(c.get("deadzone", deadzone))
	full = float(c.get("full", full))
	max_speed = float(c.get("max_speed_mm_s", max_speed))
	curve = float(c.get("curve", curve))
	smoothing_ms = float(c.get("smoothing_ms", smoothing_ms))
	invert_x = bool(c.get("invert_x", invert_x))
	invert_y = bool(c.get("invert_y", invert_y))
	swap_xy = bool(c.get("swap_xy", swap_xy))

## Offset (image short-side units) -> stick vector of length 0..1 (image axes).
static func shape(offset: Vector2, radius_: float, dead: float, full_: float, curve_: float) -> Vector2:
	if radius_ <= 0.0:
		return Vector2.ZERO
	var r := offset.length() / radius_
	if r <= dead:
		return Vector2.ZERO
	var m := clampf((r - dead) / maxf(full_ - dead, 1e-6), 0.0, 1.0)
	return offset.normalized() * pow(m, curve_)

## Image-axes stick -> robot-axes stick.
func to_robot(s: Vector2) -> Vector2:
	var v := Vector2(s.x, -s.y)  # image y grows downwards
	if swap_xy:
		v = Vector2(v.y, v.x)
	if invert_x:
		v.x = -v.x
	if invert_y:
		v.y = -v.y
	return v

## Hand at `hand` this tick -> smoothed velocity (mm/s).
func update(hand: Vector2, dt: float) -> Vector2:
	if not has_anchor:
		return Vector2.ZERO
	stick = to_robot(shape(hand - anchor, radius, deadzone, full, curve))
	var target := stick * max_speed
	var a := 1.0 if smoothing_ms <= 0.0 else 1.0 - exp(-dt * 1000.0 / smoothing_ms)
	output = output.lerp(target, a).limit_length(max_speed)
	if target == Vector2.ZERO and output.length() < 0.5:
		output = Vector2.ZERO  # back in the dead zone: settle to an exact stop
	return output
