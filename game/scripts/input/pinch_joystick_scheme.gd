class_name PinchJoystickScheme
extends GestureScheme
## The pinch hand joystick: a pinch (thumb + index, middle or ring finger) is
## the sign to steer; where it started is the stick's centre (`g.joystick`,
## a HandJoystick configured from `gesture.joystick`). The palm picks the axis
## when the pinch starts: palm up (or edge on) steers XY, the back of the hand
## up (palm down) steers Z with the stick's vertical. Not pinching, a fist held
## closes the claw and a peace sign opens it.

const ID := "pinch_joystick"

func id() -> String:
	return ID

func engaged(g, _now_ms: float) -> bool:
	return g.pinch

func sign_seen(g) -> bool:
	return g.pinch  # the backend already confirms the pinch and its release

func on_arm(g, _now_ms: float) -> void:
	g.joystick.set_anchor(g.hand)
	g.mode = "z" if g.palm == "down" else "xy"

func velocity(g, dt: float) -> Vector3:
	if g.mode == "z":
		return Vector3(0.0, 0.0, g.joystick.update_z(g.hand, dt))
	var v: Vector2 = g.joystick.update(g.hand, dt)
	return Vector3(v.x, v.y, 0.0)

func reset(g) -> void:
	g.joystick.reset()

func claw_poses() -> Dictionary:
	# a fist with the thumb out was a fist until the backend told "thumb" apart: keep it closing
	return {"fist": "closed", "thumb": "closed", "peace": "open"}

func max_speed(g) -> float:
	return g.joystick.max_speed

func uses_stick() -> bool:
	return true

func prompt() -> Array[String]:
	return ["🤏 つまんで操縦", "手のひら上=移動 下=上下 グー=閉じる ピース=開く"]

func steer_hint() -> String:
	return "離すと止まるよ"

func release_hint() -> String:
	return "指を離して、もう一度つまんでね"
