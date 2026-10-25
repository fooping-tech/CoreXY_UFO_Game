class_name ScopeTrigger
extends RefCounted
## When the telescope / scope view is up. Fed with the presentation motion
## intensities (0..1, from the physics) and whether the game is lowering:
##   - opens once the UFO has come to rest after a sideways move (settle_s),
##     when the arm moves up or down, or while the game is lowering / grabbing
##   - stays open while the arm moves; closes as soon as it moves sideways again
##   - closes after hold_s seconds without any motion (0 = never)
##   - toggle() opens / closes it by hand (V key); a sideways move still closes it,
##     and a hand-closed scope stays shut until the current motion ends

const MOVE_ON := 0.25
const STILL := 0.05

var settle_s := 0.7
var hold_s := 10.0
var is_open := false

var _moved := false
var _still_s := 0.0
var _idle_s := 0.0
var _closed_by_hand := false  # no auto-open until the motion that was going on ends

func step(move_i: float, z_i: float, lowering: bool, dt: float) -> bool:
	var sideways := move_i > MOVE_ON
	var z_moving := z_i > MOVE_ON
	if sideways:
		_moved = true
		_still_s = 0.0
		is_open = false
	elif move_i < STILL:
		_still_s += dt
	if _closed_by_hand and (sideways or (z_i < STILL and not lowering)):
		_closed_by_hand = false
	if not is_open and not sideways and not _closed_by_hand and ((_moved and _still_s >= settle_s) or z_moving or lowering):
		is_open = true
		_moved = false
		_idle_s = 0.0
	if is_open:
		if z_i > STILL or lowering:
			_idle_s = 0.0
		else:
			_idle_s += dt
		if hold_s > 0.0 and _idle_s >= hold_s:
			is_open = false
	return is_open

func toggle() -> void:
	is_open = not is_open
	_closed_by_hand = not is_open
	_moved = false
	_idle_s = 0.0
