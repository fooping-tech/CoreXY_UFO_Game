class_name VfxDirector
extends Node
## Which VFX go with which moment of the game. Listens to GameState only (its
## state follows what the machine reports; success / failure come only from
## explicit result events, never guessed) and to the "claw_closed" event the
## main scene posts when a claw close is acknowledged. Never touches the
## robot, the rope or the UFO's position.
##
##   game start   (READY after DISCONNECTED / HOMING / BOOT): countdown + energy
##   idle         (READY): a faint glow under the UFO, following it
##   moving       (MOVING): nothing new: the UFO's own motion particles
##                (ufo_fx.gd) already sparkle, and more while jogging was too much
##   lowering     (LOWERING): energy gathering at the UFO
##   grab         (GRABBING, or claw_closed): a small burst
##   success      (RESULT, result_success): confetti + sparkles
##   failure      (RESULT, not success): a puff of smoke
##   round over   (leaving RESULT): cyan motes scattering and fading
##
## The loops (idle / moving / lowering) are one slot each: entering the state
## again replaces, never stacks. One-shots have a cooldown per moment, so a
## state flapping on a slow link or a repeated event cannot pile them up.

const COOLDOWN_S := 1.5
const START_FROM := ["DISCONNECTED", "HOMING", "BOOT"]
## state -> [loop effect id, offset from the UFO body in UFO sprite pixels]
const LOOPS := {"READY": ["idle_glow", Vector2(0, 22)], "LOWERING": ["lower_charge", Vector2(-5, 12)]}

var main: Node
## Effects for each moment, for the debug panel's event buttons.
const MOMENTS := ["start", "idle", "lowering", "grab", "success", "failure", "end"]
var _loop  # AnimatedSprite2D, or a freed one after "stop all" / VFX off: check is_instance_valid
var _loop_state := ""
var _last_s: Dictionary = {}  # moment -> time (s) it last played
## A Node2D that sits on the UFO body (the UFO node is at the rope attachment).
var _body: Node2D

func setup(m: Node) -> void:
	main = m
	_body = Node2D.new()
	_body.name = "VfxUfoBody"
	main.ufo.add_child(_body)
	_body.position = Vector2(0.0, 27.0 * main.ufo.pixel_scale)  # the saucer's centre (main.gd uses the same)
	GameState.state_changed.connect(_on_state)
	GameState.event.connect(_on_event)
	_on_state("", GameState.state)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## True (and remembered) when `moment` may play now.
func _fresh(moment: String) -> bool:
	var t := _now()
	if _last_s.has(moment) and t - float(_last_s[moment]) < COOLDOWN_S:
		return false
	_last_s[moment] = t
	return true

func ufo_body() -> Vector2:
	return _body.global_position if _body != null else Vector2.ZERO

func play_center() -> Vector2:
	return Vector2(main._play_w * 0.5, main.get_viewport_rect().size.y * 0.42)

func _on_state(prev: String, cur: String) -> void:
	if prev == "RESULT" and cur != "RESULT":
		play("end")
	if cur == "READY" and prev in START_FROM:
		play("start")
	elif cur == "GRABBING":
		play("grab")
	elif cur == "RESULT":
		play("success" if GameState.result_success else "failure")
	_set_loop(cur)

func _on_event(name: String, _payload: Dictionary) -> void:
	if name == "claw_closed":
		play("grab")

## The looping effect for `state` (or none), one at a time.
func _set_loop(state: String) -> void:
	if state == _loop_state and is_instance_valid(_loop):
		return
	if is_instance_valid(_loop):
		VFXManager.stop_fx(_loop)
	_loop = null
	_loop_state = state
	if LOOPS.has(state) and _body != null:
		var l: Array = LOOPS[state]
		_loop = VFXManager.spawn_fx(l[0], ufo_body(), {"follow": _body, "offset": l[1] * main.ufo.pixel_scale})

## Play the effects of a moment (also the debug panel's event buttons). Loops
## asked for this way run for `loop_s` seconds.
func play(moment: String, loop_s := 3.0, force := false) -> void:
	if not VFXManager.enabled or main == null or (not _fresh(moment) and not force):
		return
	var p := ufo_body()
	var px: float = main.ufo.pixel_scale
	match moment:
		"start":
			VFXManager.spawn_fx("start_countdown", play_center())
			VFXManager.spawn_fx("start_energy", p, {"follow": _body, "offset": Vector2(0, 10) * px})
		"grab":
			VFXManager.spawn_fx("grab_burst", p + Vector2(0, 7) * px)
		"success":
			VFXManager.spawn_fx("success_confetti", Vector2(p.x, play_center().y))
			VFXManager.spawn_fx("success_sparkle", p + Vector2(0, 8) * px)
		"failure":
			VFXManager.spawn_fx("fail_poof", p + Vector2(0, 26) * px)  # under the saucer: the face stays visible
		"end":
			VFXManager.spawn_fx("end_fade", p + Vector2(0, 8) * px)
		"idle", "lowering":
			var st: String = {"idle": "READY", "lowering": "LOWERING"}[moment]
			var l: Array = LOOPS[st]
			VFXManager.spawn_fx(l[0], p, {"follow": _body, "offset": l[1] * px, "duration": loop_s})
