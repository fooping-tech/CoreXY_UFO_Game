class_name FocusCalibrator
extends RefCounted
## The arm-tip camera's calibration from the 校正 tab (#242), the automatic version of
## tools/calibrate_focus.py: with the arm held over the worksheet at a capture height, it takes
## the arm-tip camera's picture, moves the arm a little (+X, +Y, -X, -Y, STEP_MM each, move_xy),
## waits for it to stop and for the picture to stand still (the camera swings on the rope)
## and takes a picture each time, brings the arm back, and sends the
## pictures to the backend (focus_calibrate). The backend works out how the picture shifts per
## mm of the arm and keeps it in calibration.json#focus_camera; HELP uses it to aim the arm at a
## problem (navigate / camera_move).
##
## Only move_xy: the backend checks the soft limits, the motors and homing as for any move.
## Space (soft_stop) or a refused move ends it (cancel / a NACK); nothing is retried.

const STEP_MM := 10.0
## The camera hangs on the rope with the claw: after a move it swings for a while. A picture is
## taken only once the picture itself stands still: frames SAMPLE_S apart (small and grey) differ
## by under STILL_DIFF (0..255, the mean) STILL_N times in a row, at least MIN_SETTLE_S after the
## stop (the base picture too: the arm was just moved). Not still after STILL_WAIT_S (the real
## claw swung on for longer than 20 s): BURST_N pictures BURST_S apart instead, smaller
## (BURST_EDGE), and the backend takes the middle of their shifts (a swing goes either side of
## where it rests). Each position's motion goes to the debug log (log).
const MIN_SETTLE_S := 1.0
const STILL_WAIT_S := 4.0
const BURST_N := 6
const BURST_S := 0.5
const BURST_EDGE := 400
const SAMPLE_S := 0.2
const STILL_DIFF := 2.0
const STILL_N := 5
const THUMB := Vector2i(64, 48)
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

var _base_pics: Array[String] = []
var _shots: Array[Dictionary] = []  # [{image_jpeg_base64, dx, dy}]
var _next := 0
var _target := Vector2.ZERO
var _rid := ""
var _acked := false
var _t := 0.0
var _z0 := 0.0  # the height it started at: the pictures are only good for that height
var _sample_t := 0.0
var _thumb: Image
var _still := 0
var last_motion := -1.0  # the last frame-to-frame difference (shown while waiting)
var _burst: Array[String] = []  # pictures in a row while it swings
var bursts := 0  # positions taken as a burst (shown in the result)
## optional: a line for the debug log
var log_line: Callable

func active() -> bool:
	return state in [MOVING, SETTLING, RETURNING, COMPUTING]

## Why it cannot start now ("" when it can).
## home_margin (#339): the backend keeps every XY target this far from X = x_min / Y = y_min (the
## home limit switches) and moves a nearer one out to that line, so the -X / -Y samples need room
## beyond it too (else the arm would not reach the sample's target).
static func blocker(limits: Dictionary, at: Vector2, homed: bool, motors: bool, machine: String, has_frame: bool,
		home_margin := 0.0) -> String:
	if not motors:
		return "モーターが無効:「モーター有効」を押す"
	if not homed:
		return "原点復帰が必要:「原点復帰」を押す"
	if machine != "IDLE":
		return "アームが止まってから（いま %s）" % machine
	if not has_frame:
		return "先端カメラの映像がない（設定の「先端カメラ」を確かめる）"
	var m := maxf(home_margin, 0.0)
	if at.x - STEP_MM < float(limits.get("x_min_mm", 0.0)) + m or at.x + STEP_MM > float(limits.get("x_max_mm", 390.0)) \
			or at.y - STEP_MM < float(limits.get("y_min_mm", 0.0)) + m or at.y + STEP_MM > float(limits.get("y_max_mm", 200.0)):
		return "端に近すぎる: 動ける範囲の端から %d mm 以上（左と手前は %d mm 以上）はなす" % [int(STEP_MM), int(STEP_MM + m)]
	return ""

## Starts at the arm's position now. -> "" or why not.
func start(at_height: String) -> String:
	if active():
		return "校正の途中"
	var frame: Image = capture.call() if capture.is_valid() else null
	var why := blocker(GameConfig.robot(), Vector2(RobotState.x_mm, RobotState.y_mm), RobotState.homed,
		RobotState.motors_enabled, RobotState.machine_state, frame != null and not frame.is_empty(),
		float(GameConfig.get_value("backend", "xy_home_edge_margin_mm", 15.0)))
	if why != "":
		return why
	height = at_height
	origin = Vector2(RobotState.x_mm, RobotState.y_mm)
	_z0 = RobotState.z_mm
	_target = origin
	_base_pics.clear()
	_burst.clear()
	_shots.clear()
	result = {}
	error = ""
	_next = -1  # the base picture first, once the picture stands still
	bursts = 0
	_rid = ""
	_settle()
	return ""

## Space, the tab closed, the link lost: stop here. A move still going is stopped (soft_stop:
## the tab closing does not stop the arm by itself; Space already sent one, another is harmless).
func cancel(reason: String) -> void:
	if not active():
		return
	if state in [MOVING, RETURNING] and send.is_valid():
		send.call("soft_stop", {})
	_fail(reason)

func progress_text() -> String:
	match state:
		MOVING:
			return "先端カメラの校正: %d / %d 枚目へ動いています（Space で止まる）" % [_next + 1, MOVES.size()]
		SETTLING:
			var which := "基準の画像" if _next < 0 else "%d / %d 枚目" % [_next + 1, MOVES.size()]
			if not _burst.is_empty():
				return "先端カメラの校正: %s: 揺れているので続けて撮っています（%d / %d）（Space で止まる）" % [which, _burst.size(), BURST_N]
			return "先端カメラの校正: %s の前に揺れが止まるのを待っています%s（Space で止まる）" % [which,
				"（画像の動き %.1f）" % last_motion if last_motion >= 0.0 else ""]
		RETURNING:
			return "先端カメラの校正: もとの位置へ戻っています"
		COMPUTING:
			return "先端カメラの校正: 画像のずれを計算しています"
		DONE:
			return "先端カメラの校正ができました（%s: 1 mm で %.1f px、誤差 %s px%s）" % [height,
				float(result.get("px_per_mm", 0.0)), str(result.get("residual_px", [])),
				"。揺れていたので %d か所は続けて撮った" % bursts if bursts > 0 else ""]
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
	# #242 review: what it measures is only good at that height and where it moved the arm itself
	if absf(RobotState.z_mm - _z0) > 2.0:
		_fail("アームの高さが変わった（Z %.0f → %.0f）" % [_z0, RobotState.z_mm])
		return
	if state == SETTLING and Vector2(RobotState.x_mm, RobotState.y_mm).distance_to(_target) > ARRIVED_MM * 2.0:
		_fail("アームの位置が変わった")
		return
	match state:
		MOVING, RETURNING:
			var there := Vector2(RobotState.x_mm, RobotState.y_mm).distance_to(_target) <= ARRIVED_MM
			if _acked and there and RobotState.machine_state == "IDLE":
				if state == RETURNING:
					_compute()
				else:
					_settle()
			elif _acked and not there and RobotState.machine_state == "IDLE" and _t > 2.0:
				_fail("アームが目的の位置まで動かなかった（Space で止めた？）")
			elif _t > MOVE_TIMEOUT_S:
				_fail("アームが動き終わらない")
		SETTLING:
			_sample_t += dt
			if _sample_t < (BURST_S if not _burst.is_empty() else SAMPLE_S):
				return
			_sample_t = 0.0
			var frame: Image = capture.call() if capture.is_valid() else null
			if frame == null or frame.is_empty():
				_fail("先端カメラの映像が取れない")
				return
			var th := thumb(frame)
			if _thumb != null:
				last_motion = motion(_thumb, th)
				_still = _still + 1 if last_motion < STILL_DIFF else 0
			_thumb = th
			var pics: Array[String] = []
			if not _burst.is_empty() or (_t >= STILL_WAIT_S and (_still < STILL_N)):
				_burst.append(jpeg64(frame, BURST_EDGE))  # still swinging: pictures in a row
				if _burst.size() < BURST_N:
					return
				pics = _burst.duplicate()
				_burst.clear()
				bursts += 1
			elif _still < STILL_N or _t < MIN_SETTLE_S:
				return
			else:
				pics.append(jpeg64(frame, BURST_EDGE))
			_log("focus calibration: %s %s (motion %.1f)" % ["base" if _next < 0 else "move %d" % (_next + 1),
				"burst of %d" % pics.size() if pics.size() > 1 else "still", last_motion])
			if _next < 0:
				_base_pics = pics
				_next = 0
				_go(origin + MOVES[0] * STEP_MM, MOVING)
				return
			var d: Vector2 = MOVES[_next] * STEP_MM
			_shots.append({"images_jpeg_base64": pics, "dx": d.x, "dy": d.y})
			_next += 1
			if _next < MOVES.size():
				_go(origin + MOVES[_next] * STEP_MM, MOVING)
			else:
				_go(origin, RETURNING)
		COMPUTING:
			if _t > 30.0:
				_fail("バックエンドから返事がない")

func _log(line: String) -> void:
	if log_line.is_valid():
		log_line.call(line)

func _settle() -> void:
	_burst.clear()
	state = SETTLING
	_t = 0.0
	_sample_t = 0.0
	_thumb = null
	_still = 0
	last_motion = -1.0

## A frame small and grey, to see whether the picture still moves.
static func thumb(img: Image) -> Image:
	var im := img.duplicate() as Image
	if im.is_compressed():
		im.decompress()
	im.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	im.convert(Image.FORMAT_L8)
	return im

## The mean difference of two thumbnails (0..255).
static func motion(a: Image, b: Image) -> float:
	var da := a.get_data()
	var db := b.get_data()
	var n := mini(da.size(), db.size())
	if n == 0:
		return 255.0
	var sum := 0
	for i in n:
		sum += absi(int(da[i]) - int(db[i]))
	return float(sum) / n

func _go(target: Vector2, next_state: String) -> void:
	_target = target
	_acked = false
	_t = 0.0
	state = next_state
	_rid = str(send.call("move_xy", {"x": snappedf(target.x, 0.01), "y": snappedf(target.y, 0.01)}))

func _compute() -> void:
	state = COMPUTING
	_t = 0.0
	_rid = str(send.call("focus_calibrate", {"height": height, "base_images_jpeg_base64": _base_pics.duplicate(),
		"moves": _shots.duplicate()}))
	_base_pics.clear()
	_shots.clear()

func _fail(reason: String) -> void:
	error = reason
	state = FAILED
	_rid = ""
	_base_pics.clear()
	_burst.clear()
	_shots.clear()

## A frame as a JPEG (longest edge MAX_EDGE), base64: what focus_calibrate reads.
static func jpeg64(img: Image, edge := MAX_EDGE) -> String:
	var im := img.duplicate() as Image
	if im.is_compressed():
		im.decompress()
	var k := float(edge) / maxf(im.get_width(), im.get_height())
	if k < 1.0:
		im.resize(maxi(int(im.get_width() * k), 1), maxi(int(im.get_height() * k), 1), Image.INTERPOLATE_BILINEAR)
	im.convert(Image.FORMAT_RGB8)
	return Marshalls.raw_to_base64(im.save_jpg_to_buffer(0.9))
