class_name GestureScheme
extends RefCounted
## One way of reading the hand as a steer ("scheme"): the pinch joystick, a
## hand shape per direction, ... `GestureControl` keeps everything that makes
## the gesture safe (event freshness and order, lost hand / camera, the ROI,
## the forced-stop latch, the gate, the arm delay) and asks the scheme only:
##   - is the hand giving the "steer now" sign (`engaged`)?
##   - is it still the same sign it armed with (`same_engagement`)?
##   - what to do when the steer starts (`on_arm`)?
##   - which velocity it asks for while ACTIVE (`velocity`)?
##   - which hand shapes, held while not steering, move the claw (`claw_poses`)?
## A scheme only turns the hand into a velocity. It never talks to the robot:
## the velocity goes through ControlArbiter and the main scene's jog like any other.
##
## `g` is the GestureControl (untyped here: the two scripts refer to each other).

## The config / debug-panel name of the scheme.
func id() -> String:
	return ""

## Settings from `gesture.schemes.<id>` in the game config.
func configure(_c: Dictionary) -> void:
	pass

## Called once per tick with a fresh, detected hand: true while the hand gives
## the sign to steer. The forced-stop latch waits for this to go false.
func engaged(_g, _now_ms: float) -> bool:
	return false

## While ARMED / ACTIVE: false when the sign changed into another one (the
## steer is let go and has to arm again, so it never reverses on the spot).
func same_engagement(_g) -> bool:
	return true

## The steer starts (HAND_DETECTED -> ARMED). Set `g.mode` ("xy" / "z") here.
func on_arm(_g, _now_ms: float) -> void:
	pass

## Velocity asked for this ACTIVE tick: x, y in mm/s (robot axes), z in z units/s (+ = arm up).
func velocity(_g, _dt: float) -> Vector3:
	return Vector3.ZERO

## Any stop or release: forget the steer (anchor, smoothing).
func reset(_g) -> void:
	pass

## Hand shape -> claw position ("closed" / "open") when held while not steering.
func claw_poses() -> Dictionary:
	return {}
