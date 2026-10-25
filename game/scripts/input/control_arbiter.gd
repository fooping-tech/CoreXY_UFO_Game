class_name ControlArbiter
extends RefCounted
## One place decides who drives the crane, so the keyboard and the hand gesture
## never send jogs of their own. Priority:
##   1. emergency stop / alarm   -> nothing moves
##   2. explicit STOP (Space)    -> nothing moves until the keys are released
##   3. keyboard (arrows, W/S)
##   4. hand gesture (only while it is ACTIVE)
## Both at once is not allowed: when a key is pressed during a gesture, the
## gesture is stopped and needs a new pinch (the main scene does that).

## {"source": "halt" | "stop" | "keyboard" | "gesture" | "none", "v": Vector3}
## `keyboard` and `gesture` are velocities (x, y mm/s; z units/s).
static func decide(halt: bool, stop_latched: bool, keyboard: Vector3, gesture: Vector3, gesture_active: bool) -> Dictionary:
	if halt:
		return {"source": "halt", "v": Vector3.ZERO}
	if stop_latched:
		return {"source": "stop", "v": Vector3.ZERO}
	if keyboard != Vector3.ZERO:
		return {"source": "keyboard", "v": keyboard}
	if gesture_active:
		return {"source": "gesture", "v": gesture}
	return {"source": "none", "v": Vector3.ZERO}
