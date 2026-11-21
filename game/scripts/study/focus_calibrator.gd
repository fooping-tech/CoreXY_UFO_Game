class_name FocusCalibrator
extends RefCounted
## The arm-tip camera's calibration from the 校正 tab (#242), the automatic version of
## tools/calibrate_focus.py: with the arm held over the worksheet at a capture height, it takes
## the arm-tip camera's picture, moves the arm a little (+X, +Y, -X, -Y, STEP_MM each, move_xy),
## waits for it to stop and takes a picture each time, brings the arm back, and sends the
## pictures to the backend (focus_calibrate). The backend works out how the picture shifts per
## mm of the arm and keeps it in calibration.json#focus_camera; HELP uses it to aim the arm at a
## problem (navigate / camera_move).
##
## Only move_xy: the backend checks the soft limits, the motors and homing as for any move.
## Space (soft_stop) or a refused move ends it (cancel / a NACK); nothing is retried.

const STEP_MM := 10.0
const SETTLE_S := 1.2  # after the arm stopped: the rope / camera stop swinging, a new frame arrives
const MOVE_TIMEOUT_S := 20.0
const ARRIVED_MM := 1.0
const MAX_EDGE := 640
const MOVES := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]

const IDLE := "idle"
const MOVING := "moving"
const SETTLING := "settling"
const RETURNING := "returning"
const COMPUTING := "computing"
const DONE := "done"
const FAILED := "failed"

var state := IDLE
var height := "10cm"
var origin := Vector2.ZERO
var result: Dictionary = {}  # the backend's answer when DONE: {A, residual_px, px_per_mm, ...}
var error := ""
## Injected by the 校正 tab (tests give their own): the arm-tip camera's frame now (null when
## none), and the WebSocket send (name, params) -> request id.
var capture: Callable
var send: Callable

var _base := ""
var _shots: Array[Dictionary] = []  # [{image_jpeg_base64, dx, dy}]
var _next := 0
var _target := Vector2.ZERO
var _rid := ""
var _acked := false
var _t := 0.0

func active() -> bool:
	return state in [MOVING, SETTLING, RETURNING, COMPUTING]

## Why it cannot start now ("" when it can).
static func blocker(limits: Dictionary, at: Vector2, homed: bool, motors: bool, machine: String, has_frame: bool) -> String:
	if not motors:
		return "モーターが無効:「モーター有効」を押す"
	if not homed:
		return "原点復帰が必要:「原点復帰」を押す"
	if machine != "IDLE":
		return "アームが止まってから（いま %s）" % machine
	if not has_frame:
		return "先端カメラの映像がない（設定の「先端カメラ」を確かめる）"
	if at.x - STEP_MM < float(limits.get("x_min_mm", 0.0)) or at.x + STEP_MM > float(limits.get("x_max_mm", 390.0)) \
			or at.y - STEP_MM < float(limits.get("y_min_mm", 0.0)) or at.y + STEP_MM > float(limits.get("y_max_mm", 200.0)):
		return "端に近すぎる: 動ける範囲の端から %d mm 以上はなす" % int(STEP_MM)
	return ""

## Starts at the arm's position now. -> "" or why not.
func start(at_height: String) -> String:
	if active():
		return "校正の途中"
	var frame: Image = capture.call() if capture.is_valid() else null
	var why := blocker(GameConfig.robot(), Vector2(RobotState.x_mm, RobotState.y_mm), RobotState.homed,
		RobotState.motors_enabled, RobotState.machine_state, frame != null and not frame.is_empty())
	if why != "":
		return why
	height = at_height
	origin = Vector2(RobotState.x_mm, RobotState.y_mm)
	_base = jpeg64(frame)
	_shots.clear()
	result = {}
	error = ""
	_next = 0
	_go(origin + MOVES[0] * STEP_MM, MOVING)
	return ""

## Space, the tab closed, the link lost: stop here (the arm stays where Space left it).
func cancel(reason: String) -> void:
	if active():
		_fail(reason)

func progress_text() -> String:
	match state:
		MOVING, SETTLING:
			return "先端カメラの校正: %d / %d 枚目を撮っています（Space で止まる）" % [_next + 1, MOVES.size()]
		RETURNING:
			return "先端カメラの校正: もとの位置へ戻っています"
		COMPUTING:
			return "先端カメラの校正: 画像のずれを計算しています"
		DONE:
			return "先端カメラの校正ができました（%s: 1 mm で %.1f px、誤差 %s px）" % [height,
				float(result.get("px_per_mm", 0.0)), str(result.get("residual_px", []))]
		FAILED:
			return "先端カメラの校正をやめました: " + error
	return ""

func on_ack(rid: String, ok: bool, data: Dictionary) -> void:
	if rid != _rid or not active():
		return
	if not ok:
		_fail(str(data.get("reason", "断られました")))
		return
	if state == COMPUTING:
		result = data.duplicate()
		state = DONE
		return
	_acked = true

func tick(dt: float) -> void:
	if not active():
		return
	if RobotState.machine_state in ["ALARM", "ESTOP"]:
		_fail("アラーム・非常停止")
		return
	_t += dt
	match state:
		MOVING, RETURNING:
			var there := Vector2(RobotState.x_mm, RobotState.y_mm).distance_to(_target) <= ARRIVED_MM
			if _acked and there and RobotState.machine_state == "IDLE":
				if state == RETURNING:
					_compute()
				else:
					state = SETTLING
					_t = 0.0
			elif _acked and not there and RobotState.machine_state == "IDLE" and _t > 2.0:
				_fail("アームが目的の位置まで動かなかった（Space で止めた？）")
			elif _t > MOVE_TIMEOUT_S:
				_fail("アームが動き終わらない")
		SETTLING:
			if _t >= SETTLE_S:
				var frame: Image = capture.call() if capture.is_valid() else null
				if frame == null or frame.is_empty():
					_fail("先端カメラの映像が取れない")
					return
				var d: Vector2 = MOVES[_next] * STEP_MM
				_shots.append({"image_jpeg_base64": jpeg64(frame), "dx": d.x, "dy": d.y})
				_next += 1
				if _next < MOVES.size():
					_go(origin + MOVES[_next] * STEP_MM, MOVING)
				else:
					_go(origin, RETURNING)
		COMPUTING:
			if _t > 30.0:
				_fail("バックエンドから返事がない")

func _go(target: Vector2, next_state: String) -> void:
	_target = target
	_acked = false
	_t = 0.0
	state = next_state
	_rid = str(send.call("move_xy", {"x": snappedf(target.x, 0.01), "y": snappedf(target.y, 0.01)}))

func _compute() -> void:
	state = COMPUTING
	_t = 0.0
	_rid = str(send.call("focus_calibrate", {"height": height, "base_jpeg_base64": _base, "moves": _shots.duplicate()}))
	_base = ""
	_shots.clear()

func _fail(reason: String) -> void:
	error = reason
	state = FAILED
	_rid = ""
	_base = ""
	_shots.clear()

## A frame as a JPEG (longest edge MAX_EDGE), base64: what focus_calibrate reads.
static func jpeg64(img: Image) -> String:
	var im := img.duplicate() as Image
	if im.is_compressed():
		im.decompress()
	var k := float(MAX_EDGE) / maxf(im.get_width(), im.get_height())
	if k < 1.0:
		im.resize(maxi(int(im.get_width() * k), 1), maxi(int(im.get_height() * k), 1), Image.INTERPOLATE_BILINEAR)
	im.convert(Image.FORMAT_RGB8)
	return Marshalls.raw_to_base64(im.save_jpg_to_buffer(0.9))
