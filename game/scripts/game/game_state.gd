extends Node
## Autoload: game-level state machine. Kept SEPARATE from the machine's motion
## state (RobotState.machine_state). Transitions are event driven so that
## success/failure can later come from vision or the player, not only from
## the robot's status flags.

signal state_changed(previous: String, current: String)
signal event(name: String, payload: Dictionary)

const STATES := ["BOOT", "DISCONNECTED", "HOMING", "READY", "MOVING", "LOWERING", "GRABBING", "RAISING", "RESULT", "ERROR"]

var state: String = "BOOT"
var result_success: bool = false
var _result_timer: float = 0.0
var result_display_seconds: float = 2.5
## When true the game follows RobotState automatically (MOVING/LOWERING...).
var follow_robot: bool = true

func _ready() -> void:
	RobotState.connection_changed.connect(_on_connection_changed)
	RobotState.machine_state_changed.connect(_on_machine_state_changed)
	RobotState.error_reported.connect(func(m): post_event("error", {"message": m}))
	set_state("DISCONNECTED")

func set_state(s: String) -> void:
	if s == state:
		return
	var prev := state
	state = s
	state_changed.emit(prev, s)

## Generic event entry point (robot, vision, UI).
func post_event(name: String, payload: Dictionary = {}) -> void:
	event.emit(name, payload)
	match name:
		"connected":
			if state in ["DISCONNECTED", "BOOT"]:
				set_state("READY" if RobotState.homed else "HOMING")
		"disconnected":
			set_state("DISCONNECTED")
		"error":
			set_state("ERROR")
		"error_cleared":
			set_state("READY")
		"prize_detected":
			_finish(true)
		"prize_dropped":
			_finish(false)
		"result_success":
			_finish(true)
		"result_failure":
			_finish(false)
		"reset":
			set_state("READY" if RobotState.connected else "DISCONNECTED")

func _finish(success: bool) -> void:
	result_success = success
	_result_timer = result_display_seconds
	set_state("RESULT")

func _process(dt: float) -> void:
	if state == "RESULT":
		_result_timer -= dt
		if _result_timer <= 0.0:
			post_event("reset")

func _on_connection_changed(c: bool) -> void:
	post_event("connected" if c else "disconnected")

func _on_machine_state_changed(ms: String) -> void:
	if not follow_robot:
		return
	# The machine reports a normal state again (after clear_alarm / home): the
	# error is over. Otherwise the game stayed in ERROR (surprised face, no
	# telescope) until someone pressed Clear in the debug panel.
	if state == "ERROR" and ms not in ["ALARM", "ESTOP", "UNKNOWN"] and RobotState.connected:
		post_event("error_cleared")
	if state in ["DISCONNECTED", "ERROR", "RESULT"] and ms not in ["ALARM", "ESTOP"]:
		if state != "RESULT":
			return
	match ms:
		"ALARM", "ESTOP":
			post_event("error", {"machine_state": ms})
		"HOMING":
			set_state("HOMING")
		"MOVING_XY":
			set_state("MOVING")
		"Z_LOWERING":
			set_state("LOWERING")
		"Z_RAISING":
			set_state("RAISING")
		"GRABBING":
			set_state("GRABBING")
		"IDLE":
			if state in ["MOVING", "LOWERING", "GRABBING", "RAISING", "HOMING"]:
				set_state("READY")
