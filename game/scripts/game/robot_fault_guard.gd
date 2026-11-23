class_name RobotFaultGuard
extends Node
## #292: the score game stops by itself when the crane goes wrong, and the staff recover it.
##
## While a score game runs on the backend's robot (never the mock, never the demo), a
## RobotFaultWatch looks at the backend's state every physics tick. A new fault:
##   - the game stops once and stays stopped (GameModeController.robot_halt: the latch; Enter,
##     T, a hand, F6 / F7 start nothing until it is cleared)
##   - nothing new is asked of the crane (main.halt_motion_requests: the easy mode, the hand,
##     a parking, the practice's carry) and the keys / the hand do not move it while latched
##   - a stop: soft_stop once when the link is up and the firmware is not in an alarm already
##     (an alarm has stopped the motion itself: nothing more is sent then); with the link gone
##     nothing can be sent. The stop is "confirmed" only when a robot_state sample after it
##     shows the arm standing; otherwise "unconfirmed" (software never cuts the power)
## The faults found while latched bring the cause up to date (stop nothing twice).
##
## The staff (F9 = StaffControl "recover", the staff remote's RECOVER, or the screen's buttons)
## open StaffRecoveryPanel, and from there:
##   clear_alarm()   the alarm cleared, nothing moves (the existing clear_alarm command)
##   prepare()       the arm moves: asked twice (the first only arms a CONFIRM_S confirmation);
##                   main.recover_arm (clear_alarm -> calibration_prepare) or main.prepare_arm
##                   (calibration_prepare), the same commands and gates as the 校正 tab. Refused
##                   while the link / the robot is gone, an emergency stop, a servo that needs
##                   its power cut, or a command still unanswered
##   refresh()       get_state: the backend's state now
##   finish()        get_state, and only when that answer (and the state mirrored now) shows
##                   nothing left to do: the latch ends and the score game's title waits for a
##                   new game (the stopped round is never taken up again)
## Space overtakes all of it (main.stop_key: the recovery's late answers start nothing).
##
## Everything goes to the debug log (and Godot's log file); the fault itself also to the
## round's trace.

## the second press of prepare() must come within this many seconds of the first
const CONFIRM_S := 6.0
## a stop not seen within this many seconds: "unconfirmed"
const STOP_CONFIRM_S := 3.0
const STOP_TEXT := {"": "", "requested": "停止を確認中…", "confirmed": "停止を確認した（アームは止まっている）",
	"alarm": "ファームウェアのアラームで停止（追加の命令は送っていない）",
	"unconfirmed": "停止未確認（実機が止まったか分からない。機械と電源を確かめる）"}

var main: Node
var watch := RobotFaultWatch.new()
## the stop after the fault: "" / requested / confirmed / alarm / unconfirmed
var stop_state := ""
## what the staff did last and how it went, for the screen
var action_note := ""
var action_ok := true
## the last get_state answer and its time (unix s); {} = none yet
var fetched := {}
var fetched_at := 0.0
## the history of this fault (times and lines), the newest last
var history: Array[String] = []
## the second press of prepare() arms until this runs out
var confirm_left := 0.0
var _stop_rid := ""
var _stop_left := 0.0
var _samples := 0
var _samples_at_stop := 0
var _clear_rid := ""
var _state_rid := ""
var _state_for := ""  # "refresh" / "finish"

func setup(m: Node) -> void:
	main = m
	RobotState.pose_updated.connect(func(_x, _y, _z, _s): _samples += 1)

func _game():
	return main.get("game_mode") if main != null else null

func latched() -> bool:
	var gm = _game()
	return gm != null and gm.robot_fault_latched()

func fault() -> Dictionary:
	var gm = _game()
	return gm.robot_fault if gm != null else {}

func link_ok() -> bool:
	return main != null and bool(main.backend_link.call())

func state_now() -> Dictionary:
	return RobotFaultWatch.live_state(link_ok())

## The watch runs while a score game runs on the backend's robot, and while it is latched.
func watching() -> bool:
	var gm = _game()
	if gm == null or not gm.active() or gm.demo or RobotState.source != "websocket":
		return latched()
	return gm.running() or latched()

func _physics_process(dt: float) -> void:
	tick(dt)

func tick(dt: float) -> void:
	if not watching():
		watch.disarm()
	elif not watch.armed:
		watch.arm(state_now())
	else:
		var found := watch.update(state_now())
		if not found.is_empty():
			on_fault(found)
	confirm_left = maxf(confirm_left - dt, 0.0)
	if stop_state == "requested":
		_stop_left -= dt
		if _samples > _samples_at_stop and RobotFaultWatch.still(state_now()):
			_set_stop("confirmed")
		elif _stop_left <= 0.0 or not link_ok():
			_set_stop("unconfirmed")

## New faults (the most telling first): the game stops once; while latched the cause is
## brought up to date.
func on_fault(found: Array) -> void:
	var gm = _game()
	var f: Dictionary = (found[0] as Dictionary).duplicate(true)
	f.at = Time.get_datetime_string_from_system(false, true)
	f.unix = Time.get_unix_time_from_system()
	f.easy_state = str(RobotState.easy_mode.get("state", ""))
	f.easy_step = str(RobotState.easy_mode.get("step", ""))
	f.machine_state = RobotState.machine_state
	# a capsule may hang in the claw or lie in a Dial: the easy mode was carrying, or a lane had one
	f.capsule_risk = f.easy_state in ["AUTO_GRAB", "WAIT_DESTINATION", "DELIVER_DIAL_1"] \
		or (gm != null and gm.lanes.values().any(func(l): return not l.capsule.is_empty()))
	var others := []
	for x in found.slice(1):
		others.append(str(x.code))
	f.also = others
	var first: bool = gm != null and gm.robot_halt(f)
	if first:
		history.clear()  # a new fault: its own story
		stop_state = ""
		action_note = ""
	if first and gm != null and gm.robot_fault_latched():
		gm.robot_fault.capsule_risk = gm.robot_fault.capsule_risk or bool(f.capsule_risk)
	_log("%s %s/%s: %s%s" % ["fault" if first else "fault again", f.category, f.code, f.message,
		(" (also " + ", ".join(others) + ")") if not others.is_empty() else ""])
	if not first:
		return
	main.halt_motion_requests("robot_fault")
	confirm_left = 0.0
	_stop()

## The stop after a fault: never more than one soft_stop, nothing on top of an alarm.
func _stop() -> void:
	if not link_ok():
		_set_stop("unconfirmed")
		return
	if RobotState.machine_state in RobotFaultWatch.ALARMED:
		_set_stop("alarm")
		return
	_stop_rid = main.ws.send_command("soft_stop")
	_samples_at_stop = _samples
	_stop_left = STOP_CONFIRM_S
	_set_stop("requested")

func _set_stop(s: String) -> void:
	if s == stop_state:
		return
	stop_state = s
	_log("stop: " + s)

## Space during the recovery: a confirmation armed is gone; a late answer starts nothing
## (main._stop_recovery holds back the preparation).
func on_stop_key() -> void:
	if confirm_left > 0.0:
		_log("stop key: the confirmation is off")
	confirm_left = 0.0

# ------------------------------------------------------------------ the staff's operations
func pending() -> bool:
	return _clear_rid != "" or _state_rid != "" or (main != null and main.recover_pending())

## Why the arm may not be moved now ("" = it may).
func move_blocked() -> String:
	if not link_ok():
		return "バックエンドにつながっていない"
	if not RobotState.connected:
		return "ロボットにつながっていない"
	if RobotState.machine_state == "ESTOP":
		return "非常停止中（非常停止ボタンと機械を確かめて［アラーム解除］から）"
	if RobotState.z_servo_power_cycle or RobotState.arm_servo_power_cycle:
		return "サーボの電源の入れ直しが先（ソフトでは直らない）"
	if pending():
		return "前の命令の返事を待っている"
	if main.arm_recovering():
		return "準備の途中"
	if RobotState.machine_state in RobotFaultWatch.MOVING:
		return "アームが動いている"
	return ""

## アラーム解除: the alarm cleared; nothing moves.
func clear_alarm() -> bool:
	if not link_ok():
		return _note(false, "アラーム解除できない: バックエンドにつながっていない")
	if not RobotState.machine_state in RobotFaultWatch.ALARMED:
		return _note(false, "アラームではない（解除はいらない）")
	if pending():
		return _note(false, "前の命令の返事を待っている")
	_clear_rid = main.ws.send_command("clear_alarm")
	_log("staff: clear_alarm (" + _clear_rid + ")")
	return _note(true, "アラーム解除を送った（アームは動かない）…")

## まとめて準備: the arm moves. The first call only asks for the confirmation; the second
## (within CONFIRM_S) sends.
func prepare() -> bool:
	var why := move_blocked()
	if why != "":
		confirm_left = 0.0
		return _note(false, "まとめて準備できない: " + why)
	if confirm_left <= 0.0:
		confirm_left = CONFIRM_S
		return _note(true, "アームが動きます（原点復帰・Z・爪）。まわりに人や物がないか確かめて、もう一度押す（F9 でも）")
	confirm_left = 0.0
	var started: bool = main.recover_arm() if main.arm_recovery_reason() != "" else main.prepare_arm()
	if not started:
		return _note(false, "まとめて準備を送れなかった")
	_log("staff: prepare (the arm moves)")
	return _note(true, "まとめて準備を送った（アームが動く）。Space でいつでも止まる")

## 状態を取り直す: get_state.
func refresh() -> bool:
	return _get_state("refresh")

## 確認して新しいゲームへ: get_state, and the latch ends only when that answer (and the
## state now) show nothing left.
func finish() -> bool:
	if not latched():
		return _note(false, "止まっていない")
	return _get_state("finish")

func _get_state(why: String) -> bool:
	if not link_ok():
		return _note(false, "状態を取れない: バックエンドにつながっていない")
	if _state_rid != "":
		return _note(false, "前の命令の返事を待っている")
	_state_rid = main.ws.send_command("get_state")
	_state_for = why
	return _note(true, "状態を確かめている…")

## What still keeps the crane from a new game ([] = nothing), from the state now.
func problems() -> Array:
	var gm = _game()
	return RobotFaultWatch.problems(state_now(), gm != null and gm.easy_on())

## The backend's answers to what this asked. True when the answer was one of them.
func on_ack(rid: String, ok: bool, data: Dictionary) -> bool:
	if rid == "":
		return false
	if rid == _stop_rid:
		_stop_rid = ""
		if not ok:
			_log("soft_stop refused: " + str(data.get("reason", "")))
			if stop_state == "requested":
				_set_stop("unconfirmed")
		return true
	if rid == _clear_rid:
		_clear_rid = ""
		_log("clear_alarm: " + ("ok" if ok else "refused " + str(data.get("reason", ""))))
		_note(ok, "アラーム解除: " + ("済み（次は［まとめて準備］）" if ok else "できなかった（%s）" % str(data.get("reason", ""))))
		return true
	if rid == _state_rid:
		_state_rid = ""
		var why := _state_for
		_state_for = ""
		if not ok:
			_note(false, "状態を取れなかった（%s）" % str(data.get("reason", "")))
			return true
		fetched = data.duplicate(true)
		fetched.link = true
		fetched_at = Time.get_unix_time_from_system()
		if why == "finish":
			_finish_with(fetched)
		else:
			_note(true, "状態を取り直した")
		return true
	return false

func _finish_with(answer: Dictionary) -> void:
	var gm = _game()
	var easy: bool = gm != null and gm.easy_on()
	var left := RobotFaultWatch.problems(answer, easy)
	if left.is_empty():
		left = RobotFaultWatch.problems(state_now(), easy)  # and nothing changed since
	if not left.is_empty():
		_log("finish refused: " + str(left[0].code))
		_note(false, "まだ再開できない: " + str(left[0].text))
		return
	_log("recovered: the latch ends (a new game only)")
	if gm != null:
		gm.clear_robot_fault()
	watch.disarm()
	stop_state = ""
	_note(true, "ふっきした。カプセルが残っていないか確かめてから、あたらしいゲームを はじめる")

func _note(ok: bool, text: String) -> bool:
	action_ok = ok
	action_note = text
	return ok

func _log(text: String) -> void:
	var line := "%s %s" % [Time.get_time_string_from_system(), text]
	history.append(line)
	while history.size() > 30:
		history.remove_at(0)
	if main != null and main.has_signal("debug_log"):
		main.debug_log.emit("robot fault: " + text)
