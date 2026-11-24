class_name RobotFaultWatch
extends RefCounted
## #292: what of the crane went wrong while a score game runs, judged from the backend's state
## (robot_state's shape: the WebSocket's mirror in RobotState, or a get_state answer).
##
## Only changes count: the watch is armed with the state at the start of the watched time and
## reports a fault when it appears afterwards (an alarm or an emergency stop of the firmware,
## homing or the motors lost, a servo that needs its power cut, the easy mode's sequence ending
## in FAULT, the link or the robot gone). What was already wrong when it was armed is not new
## (#275 keeps a game from starting then); a fault reported again is not new either. A busy or
## refused command is not a fault (it is never in the state). With the link gone nothing else
## is judged (the rest of the state is old then).
##
## Pure logic: it sends nothing and stops nothing (RobotFaultGuard does).

## what broke, for the staff (the screen's first line)
const CATEGORIES := {"corexy": "CoreXY（XY 駆動）", "z": "Z（巻き上げサーボ）", "claw": "爪サーボ",
	"sequence": "かんたんモードのシーケンス", "link": "接続", "unknown": "不明"}
const ALARMED := ["ALARM", "ESTOP"]
## what a fault leaves the crane in while it is recovered: these follow the staff's own steps
## (clearing the alarm unhomes, the preparation switches the motors), not a new fault
const RECOVERY_SIDE_EFFECTS := ["homing_lost", "motors_off"]
const MOVING := ["HOMING", "MOVING_XY", "Z_LOWERING", "Z_RAISING", "GRABBING", "RELEASING"]

var armed := false
var _prev := {}

## The state now, from RobotState (robot_state's keys) and the link (`link`: the backend's
## WebSocket is open and its state fresh).
static func live_state(link_ok: bool) -> Dictionary:
	return {"link": link_ok, "connected": RobotState.connected, "state": RobotState.machine_state,
		"homed": RobotState.homed, "motors_enabled": RobotState.motors_enabled, "error": RobotState.robot_error,
		"z_servo_reset": RobotState.z_servo_reset, "z_servo_power_cycle": RobotState.z_servo_power_cycle,
		"arm_servo_power_cycle": RobotState.arm_servo_power_cycle, "easy_mode": RobotState.easy_mode.duplicate(true),
		"calibration_prepare": RobotState.calibration_prepare.duplicate(true), "auto_catch": RobotState.auto_catch.duplicate(true)}

func arm(s: Dictionary) -> void:
	armed = true
	_prev = s.duplicate(true)

func disarm() -> void:
	armed = false
	_prev = {}

## The faults that appeared since the last look: [{category, code, message, error}], the most
## telling first. [] = nothing new (or not armed).
func update(s: Dictionary) -> Array:
	if not armed:
		return []
	var out := []
	var p := _prev
	var err := str(s.get("error", ""))
	if not bool(s.get("link", true)):
		if bool(p.get("link", true)):
			out.append(fault("link", "link_lost", "バックエンドとの通信が切れた（実機が止まったかは分からない）", err))
		_prev = s.duplicate(true)
		_prev.link = false
		return out
	if bool(p.get("connected", true)) and not bool(s.get("connected", true)):
		# the rest of the state is not the robot's any more (reset by the backend): only this
		_prev = s.duplicate(true)
		return [fault("link", "robot_disconnected", "ロボット（Core2）との接続が切れた（実機が止まったかは分からない）", err)]
	if not bool(s.get("connected", true)):
		_prev = s.duplicate(true)
		return []
	var st := str(s.get("state", ""))
	var was := str(p.get("state", ""))
	var alarm_new: bool = st in ALARMED and not was in ALARMED
	if alarm_new:
		out.append(fault(category_of(err, "corexy"), "estop" if st == "ESTOP" else "alarm",
			("非常停止（ESTOP）" if st == "ESTOP" else "アラーム（ALARM）") + (": " + err if err != "" else ""), err))
	if bool(s.get("z_servo_power_cycle", false)) and not bool(p.get("z_servo_power_cycle", false)):
		out.append(fault("z", "z_servo_power_cycle", "巻き上げサーボが回転数を失った（サーボの電源の入れ直しが必要）", err))
	if bool(s.get("arm_servo_power_cycle", false)) and not bool(p.get("arm_servo_power_cycle", false)):
		out.append(fault("claw", "arm_servo_power_cycle", "爪サーボが回転数を失った（サーボの電源の入れ直しが必要）", err))
	if bool(s.get("z_servo_reset", false)) and not bool(p.get("z_servo_reset", false)):
		out.append(fault("z", "z_servo_reset", "巻き上げサーボの電源が切れて 1 回転モードに戻った", err))
	var easy: Dictionary = s.get("easy_mode", {}) if s.get("easy_mode") is Dictionary else {}
	var peasy: Dictionary = p.get("easy_mode", {}) if p.get("easy_mode") is Dictionary else {}
	if str(easy.get("state", "")) == "FAULT" and str(peasy.get("state", "")) != "FAULT" \
			and str(easy.get("last_result", "")) != "stopped":
		var e := str(easy.get("error", ""))
		out.append(fault(category_of(e, "sequence"), "easy_fault", "かんたんモードのシーケンスが止まった" + (": " + e if e != "" else ""), e))
	if not alarm_new and bool(p.get("homed", false)) and not bool(s.get("homed", false)) and st != "HOMING" and not st in ALARMED:
		out.append(fault("corexy", "homing_lost", "原点を失った", err))
	if not alarm_new and bool(p.get("motors_enabled", false)) and not bool(s.get("motors_enabled", false)) and not st in ALARMED:
		out.append(fault("corexy", "motors_off", "モーターがオフになった", err))
	_prev = s.duplicate(true)
	return out

## The line every screen shows while the game is stopped by a fault of `category`.
static func stop_line(category: String) -> String:
	return "ゲーム停止：%s／スタッフを呼んでください" % CATEGORIES.get(category, "不明")

static func fault(category: String, code: String, message: String, error := "") -> Dictionary:
	return {"category": category, "code": code, "message": message, "error": error}

## Which part an error's text is about (the firmware names the servo by its id: 1 = the Z
## drum, 2 = the claw); `fallback` when it does not say.
static func category_of(error: String, fallback: String) -> String:
	var e := error.to_lower()
	if e.contains("id=2") or e.contains("claw") or e.contains("arm_") or e.contains("arm servo"):
		return "claw"
	if e.contains("id=1") or e.contains("drum") or e.contains("z servo") or e.contains("z_") or e.contains("winch"):
		return "z"
	return fallback

## What still keeps the crane from a new game, in the order to do it ([] = nothing):
## [{"code", "text"}]. `s` is robot_state's shape (a get_state answer, or live_state());
## `easy` = the easy mode is played (its backend blockers count too).
static func problems(s: Dictionary, easy := false) -> Array:
	var out := []
	if not bool(s.get("link", true)):
		return [{"code": "link", "text": "バックエンドにつながっていない（./start.sh を確かめる）"}]
	if not bool(s.get("connected", false)):
		return [{"code": "robot", "text": "ロボット（Core2）につながっていない（USB と電源を確かめる）"}]
	var st := str(s.get("state", ""))
	if st == "ESTOP":
		out.append({"code": "estop", "text": "非常停止中: 非常停止ボタンと機械を確かめてから［アラーム解除］"})
	elif st == "ALARM":
		out.append({"code": "alarm", "text": "アラーム中: 機械を確かめてから［アラーム解除］（アームは動かない）"})
	if bool(s.get("z_servo_power_cycle", false)):
		out.append({"code": "z_power", "text": "巻き上げサーボの電源を入れ直す（ソフトでは直らない）"})
	if bool(s.get("arm_servo_power_cycle", false)):
		out.append({"code": "arm_power", "text": "爪サーボの電源を入れ直す（ソフトでは直らない）"})
	if bool(s.get("z_servo_reset", false)):
		out.append({"code": "z_reset", "text": "巻き上げサーボが 1 回転モード: デバッグパネルの「巻き上げサーボを復帰」か電源の入れ直し"})
	var prep: Dictionary = s.get("calibration_prepare", {}) if s.get("calibration_prepare") is Dictionary else {}
	if bool(prep.get("active", false)):
		out.append({"code": "preparing", "text": "準備の途中（終わるまで待つ）"})
	elif st in MOVING:
		out.append({"code": "moving", "text": "アームが動いている（止まるまで待つ）"})
	if not bool(s.get("homed", false)) and not st in ALARMED:
		out.append({"code": "home", "text": "原点復帰が必要: ［まとめて準備］（アームが動く）"})
	if not bool(s.get("motors_enabled", false)) and not st in ALARMED:
		out.append({"code": "motors", "text": "モーターがオフ: ［まとめて準備］（アームが動く）"})
	var em: Dictionary = s.get("easy_mode", {}) if s.get("easy_mode") is Dictionary else {}
	if bool(em.get("active", false)):
		out.append({"code": "easy_active", "text": "かんたんモードのシーケンスが動いている（Space で止める）"})
	var ac: Dictionary = s.get("auto_catch", {}) if s.get("auto_catch") is Dictionary else {}
	if bool(ac.get("active", false)):
		out.append({"code": "auto_catch", "text": "自動キャッチが動いている（Space で止める）"})
	if easy and out.is_empty():
		var bl = em.get("blockers", [])
		if bl is Array:
			for b in bl:
				out.append({"code": "easy_blocker", "text": "かんたんモード: " + EasyModeControl.refusal_text(str(b))})
	return out

## The arm stands still in this state (a stop can be said to have happened).
static func still(s: Dictionary) -> bool:
	var em: Dictionary = s.get("easy_mode", {}) if s.get("easy_mode") is Dictionary else {}
	var ac: Dictionary = s.get("auto_catch", {}) if s.get("auto_catch") is Dictionary else {}
	var prep: Dictionary = s.get("calibration_prepare", {}) if s.get("calibration_prepare") is Dictionary else {}
	return bool(s.get("link", true)) and bool(s.get("connected", false)) and not str(s.get("state", "")) in MOVING \
		and not bool(em.get("active", false)) and not bool(ac.get("active", false)) and not bool(prep.get("active", false))
