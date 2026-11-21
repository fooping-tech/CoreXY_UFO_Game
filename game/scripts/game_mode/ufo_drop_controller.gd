class_name UfoDropController
extends RefCounted
## UFOくん of the game mode (#138): it goes left and right along the top of the field at
## a steady pace (10 % .. 90 % of the field's width, 6 s one way by default) and drops each
## capsule from where it was the moment the Dial reported BALL_RECEIVED. Presentation only:
## this UFO is a picture of the game mode, not the crane (it never reads or writes
## RobotState; the rope UFO of the crane screen is untouched).

var x_min := 96.0
var x_max := 624.0
var one_way_s := 6.0
var y := GameModeLayout.UFO_Y
## 0..1 along the rail and which way it goes
var u := 0.5
var dir := 1.0

func configure(field_left: float, field_right: float, cfg: Dictionary) -> void:
	var w := field_right - field_left
	x_min = field_left + w * clampf(float(cfg.get("min", 0.1)), 0.0, 1.0)
	x_max = field_left + w * clampf(float(cfg.get("max", 0.9)), 0.0, 1.0)
	if x_max < x_min:
		var t := x_min
		x_min = x_max
		x_max = t
	one_way_s = maxf(float(cfg.get("one_way_s", 6.0)), 0.5)

func reset() -> void:
	u = 0.5
	dir = 1.0

func advance(dt: float) -> void:
	u += dir * dt / one_way_s
	while u > 1.0 or u < 0.0:  # turn at the ends (the overshoot comes back)
		if u > 1.0:
			u = 2.0 - u
			dir = -1.0
		else:
			u = -u
			dir = 1.0

func x() -> float:
	return lerpf(x_min, x_max, u)

func position() -> Vector2:
	return Vector2(x(), y)
